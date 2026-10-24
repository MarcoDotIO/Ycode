import Foundation

/// No limit for object queries.
public let HKObjectQueryNoLimit: Int = 0

public typealias HKObserverQueryCompletionHandler = @Sendable () -> Void

/// Base class of all queries (`queries.md` §1). A query is an immutable description
/// that runs once: executing it a second time raises `NSInvalidArgumentException`.
public class HKQuery: NSObject, @unchecked Sendable {
    public let objectType: HKObjectType?
    @available(*, deprecated, renamed: "objectType")
    public var sampleType: HKSampleType? { objectType as? HKSampleType }
    public let predicate: NSPredicate?
    let node: PredicateNode?

    struct RunState {
        var executed = false
        var stopped = false
        var liveID: UUID?
    }
    let state = Locked(RunState())
    /// Long-running results are delivered on a private serial queue per query.
    let handlerQueue = DispatchQueue(label: "dev.ycode.healthkit.query")

    init(objectType: HKObjectType?, predicate: NSPredicate?, node: PredicateNode? = nil) {
        self.objectType = objectType
        self.predicate = predicate
        self.node = node ?? PredicateNode.from(predicate)
        super.init()
    }

    func markExecuted(_ store: HKHealthStore) throws(HKRaise) {
        let first = state.withLock { s -> Bool in
            if s.executed { return false }
            s.executed = true
            return true
        }
        if !first {
            throw .invalidArgument("\(self) has already been executed and cannot be executed again")
        }
    }

    var isStopped: Bool { state.withLock { $0.stopped } }

    /// Start the query (subclasses). Runs on the caller's thread; work goes to the daemon queue.
    func run(on store: HKHealthStore) {}

    func stopRunning(_ store: HKHealthStore) {
        let id = state.withLock { s -> UUID? in
            s.stopped = true
            defer { s.liveID = nil }
            return s.liveID
        }
        if let id { store.daemon.queue.async { store.daemon.unregister(id) } }
    }

    /// Register for change sets (called on the daemon queue).
    func registerLive(_ store: HKHealthStore, onChange: @escaping (ChangeSet) -> Void) {
        let id = UUID()
        let ok = state.withLock { s -> Bool in
            if s.stopped { return false }
            s.liveID = id
            return true
        }
        if ok { store.daemon.register(id, client: store.ycodeClient.bundleIdentifier, onChange: onChange) }
    }

    /// Deliver on the handler queue unless stopped.
    func deliver(_ body: @escaping @Sendable () -> Void) {
        handlerQueue.async { [self] in
            if !isStopped { body() }
        }
    }

    static func sortKeys(_ descriptors: [NSSortDescriptor]?) -> [(SortKey, Bool)] {
        (descriptors ?? []).compactMap { sd in
            #if canImport(ObjectiveC)
            switch sd.key {
            case HKSampleSortIdentifierStartDate?: return (.startDate, sd.ascending)
            case HKSampleSortIdentifierEndDate?: return (.endDate, sd.ascending)
            case HKPredicateKeyPathQuantity?: return (.quantity, sd.ascending)
            case HKWorkoutSortIdentifierDuration?: return (.duration, sd.ascending)
            default: return nil
            }
            #else
            let kp = sd.keyPath
            if kp == \HKSample.startDate || kp == \HKQuantitySample.startDate || kp == \HKCategorySample.startDate
                || kp == \HKWorkout.startDate || kp == \HKCorrelation.startDate { return (.startDate, sd.ascending) }
            if kp == \HKSample.endDate || kp == \HKQuantitySample.endDate || kp == \HKCategorySample.endDate
                || kp == \HKWorkout.endDate || kp == \HKCorrelation.endDate { return (.endDate, sd.ascending) }
            if kp == \HKWorkout.duration { return (.duration, sd.ascending) }
            return nil
            #endif
        }
    }
}

/// A sample type with an optional predicate (multi-type queries, iOS 15).
public final class HKQueryDescriptor: NSObject, NSCopying, @unchecked Sendable {
    public let sampleType: HKSampleType
    public let predicate: NSPredicate?

    public init(sampleType: HKSampleType, predicate: NSPredicate?) {
        self.sampleType = sampleType
        self.predicate = predicate
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }

    /// OR over the descriptors, each restricted to its type.
    static func node(_ descriptors: [HKQueryDescriptor]) -> PredicateNode {
        .or(descriptors.map { d in
            .and([.typeIs(d.sampleType.identifier)] + (PredicateNode.from(d.predicate).map { [$0] } ?? []))
        })
    }
}

/// Opaque position in the store's change sequence (`queries.md` §4).
public final class HKQueryAnchor: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let value: Int64

    init(value: Int64) {
        self.value = value
        super.init()
    }
    public convenience init(fromValue value: Int) { self.init(value: Int64(value)) }

    public override func isEqual(_ object: Any?) -> Bool { (object as? HKQueryAnchor)?.value == value }
    public override var hash: Int { value.hashValue }
    public override var description: String { "<HKQueryAnchor \(value)>" }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(value, forKey: "anchor") }
    public required init?(coder: NSCoder) {
        value = coder.decodeInt64(forKey: "anchor")
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

// MARK: - Sample query

public final class HKSampleQuery: HKQuery, @unchecked Sendable {
    public let limit: Int
    public let sortDescriptors: [NSSortDescriptor]?
    public let queryDescriptors: [HKQueryDescriptor]?
    let types: [String]
    let resultsHandler: @Sendable (HKSampleQuery, [HKSample]?, (any Error)?) -> Void

    public init(sampleType: HKSampleType, predicate: NSPredicate?, limit: Int, sortDescriptors: [NSSortDescriptor]?,
                resultsHandler: @escaping @Sendable (HKSampleQuery, [HKSample]?, (any Error)?) -> Void) {
        self.limit = limit
        self.sortDescriptors = sortDescriptors
        self.queryDescriptors = nil
        self.types = [sampleType.identifier]
        self.resultsHandler = resultsHandler
        super.init(objectType: sampleType, predicate: predicate)
    }

    public init(queryDescriptors: [HKQueryDescriptor], limit: Int, sortDescriptors: [NSSortDescriptor],
                resultsHandler: @escaping @Sendable (HKSampleQuery, [HKSample]?, (any Error)?) -> Void) {
        self.limit = limit
        self.sortDescriptors = sortDescriptors
        self.queryDescriptors = queryDescriptors
        self.types = Array(Set(queryDescriptors.map(\.sampleType.identifier))).sorted()
        self.resultsHandler = resultsHandler
        super.init(objectType: nil, predicate: nil, node: HKQueryDescriptor.node(queryDescriptors))
    }

    public convenience init(queryDescriptors: [HKQueryDescriptor], limit: Int,
                            resultsHandler: @escaping @Sendable (HKSampleQuery, [HKSample]?, (any Error)?) -> Void) {
        self.init(queryDescriptors: queryDescriptors, limit: limit, sortDescriptors: [], resultsHandler: resultsHandler)
    }

    override func run(on store: HKHealthStore) {
        let keys = HKQuery.sortKeys(sortDescriptors)
        let client = store.ycodeClient.bundleIdentifier
        store.daemon.queue.async { [self] in
            let r = store.daemon.samples(types: types, node: node, limit: limit, sort: keys, client: client)
            deliver { [self] in
                switch r {
                case .success(let recs): resultsHandler(self, recs.map { HKObject.make($0) as! HKSample }, nil)
                case .failure(let e): resultsHandler(self, nil, e)
                }
            }
        }
    }
}

// MARK: - Anchored object query

public final class HKAnchoredObjectQuery: HKQuery, @unchecked Sendable {
    public typealias Handler = @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, (any Error)?) -> Void

    let types: [String]
    let anchor: HKQueryAnchor?
    let limit: Int
    let resultsHandler: Handler
    private let update = Locked<Handler?>(nil)

    /// When set before execution, the query keeps running and reports each committed change set.
    public var updateHandler: Handler? {
        get { update.current }
        set { update.withLock { $0 = newValue } }
    }

    public init(type: HKSampleType, predicate: NSPredicate?, anchor: HKQueryAnchor?, limit: Int,
                resultsHandler handler: @escaping Handler) {
        types = [type.identifier]
        self.anchor = anchor
        self.limit = limit
        resultsHandler = handler
        super.init(objectType: type, predicate: predicate)
    }

    public init(queryDescriptors: [HKQueryDescriptor], anchor: HKQueryAnchor?, limit: Int,
                resultsHandler handler: @escaping Handler) {
        types = Array(Set(queryDescriptors.map(\.sampleType.identifier))).sorted()
        self.anchor = anchor
        self.limit = limit
        resultsHandler = handler
        super.init(objectType: nil, predicate: nil, node: HKQueryDescriptor.node(queryDescriptors))
    }

    override func run(on store: HKHealthStore) {
        let client = store.ycodeClient.bundleIdentifier
        let daemon = store.daemon
        daemon.queue.async { [self] in
            let first = daemon.anchored(types: types, node: node, after: anchor?.value ?? 0, limit: limit, client: client)
            switch first {
            case .failure(let e):
                deliver { [self] in resultsHandler(self, nil, nil, nil, e) }
            case .success(let r):
                deliver { [self] in
                    resultsHandler(self, r.added.map { HKObject.make($0) as! HKSample },
                                   r.deleted.map { HKDeletedObject(record: $0) }, HKQueryAnchor(value: r.anchor), nil)
                }
                guard updateHandler != nil else { return }
                var last = r.anchor
                let watched = Set(types)
                registerLive(store) { [self] change in
                    guard !change.types.isDisjoint(with: watched) else { return }
                    guard case .success(let d) = daemon.anchored(types: types, node: node, after: last, limit: 0,
                                                                 client: client) else { return }
                    last = d.anchor
                    guard !(d.added.isEmpty && d.deleted.isEmpty), let h = updateHandler else { return }
                    deliver { [self] in
                        h(self, d.added.map { HKObject.make($0) as! HKSample }, d.deleted.map { HKDeletedObject(record: $0) },
                          HKQueryAnchor(value: d.anchor), nil)
                    }
                }
            }
        }
    }
}

// MARK: - Observer query

public final class HKObserverQuery: HKQuery, @unchecked Sendable {
    let types: [String]
    let handler: @Sendable (HKObserverQuery, Set<HKSampleType>?, @escaping HKObserverQueryCompletionHandler, (any Error)?) -> Void

    public init(sampleType: HKSampleType, predicate: NSPredicate?,
                updateHandler: @escaping @Sendable (HKObserverQuery, @escaping HKObserverQueryCompletionHandler, (any Error)?) -> Void) {
        types = [sampleType.identifier]
        handler = { q, _, done, e in updateHandler(q, done, e) }
        super.init(objectType: sampleType, predicate: predicate)
    }

    public init(queryDescriptors: [HKQueryDescriptor],
                updateHandler: @escaping @Sendable (HKObserverQuery, Set<HKSampleType>?, @escaping HKObserverQueryCompletionHandler, (any Error)?) -> Void) {
        types = Array(Set(queryDescriptors.map(\.sampleType.identifier))).sorted()
        handler = updateHandler
        super.init(objectType: nil, predicate: nil, node: HKQueryDescriptor.node(queryDescriptors))
    }

    override func run(on store: HKHealthStore) {
        let client = store.ycodeClient.bundleIdentifier
        let daemon = store.daemon
        daemon.queue.async { [self] in
            if let missing = types.first(where: { !daemon.determined($0, client: client) }) {
                _ = missing
                deliver { [self] in handler(self, nil, {}, HKError.notDetermined) }
                return
            }
            // once right after start (`queries.md` §5)
            deliver { [self] in handler(self, nil, {}, nil) }
            let watched = Set(types)
            registerLive(store) { [self] change in
                let hit = change.added.filter { watched.contains($0.type) && PredicateEvaluator.matches(node, $0) }
                let gone = change.deleted.filter { watched.contains($0.type) }
                guard !hit.isEmpty || !gone.isEmpty else { return }
                let changed = Set(hit.map(\.type) + gone.map(\.type)).compactMap(TypeRegistry.sampleType)
                deliver { [self] in handler(self, Set(changed), {}, nil) }
            }
        }
    }
}

// MARK: - Correlation query

public final class HKCorrelationQuery: HKQuery, @unchecked Sendable {
    public var correlationType: HKCorrelationType { objectType as! HKCorrelationType }
    public let samplePredicates: [HKSampleType: NSPredicate]?
    let completion: @Sendable (HKCorrelationQuery, [HKCorrelation]?, (any Error)?) -> Void

    public init(type correlationType: HKCorrelationType, predicate: NSPredicate?,
                samplePredicates: [HKSampleType: NSPredicate]?,
                completion: @escaping @Sendable (HKCorrelationQuery, [HKCorrelation]?, (any Error)?) -> Void) {
        self.samplePredicates = samplePredicates
        self.completion = completion
        super.init(objectType: correlationType, predicate: predicate)
    }

    override func run(on store: HKHealthStore) {
        let client = store.ycodeClient.bundleIdentifier
        let sp = UncheckedSendable((samplePredicates ?? [:]).map { ($0.key.identifier, PredicateNode.from($0.value)) })
        store.daemon.queue.async { [self] in
            let r = store.daemon.correlations(type: correlationType.identifier, node: node, samplePredicates: sp.value,
                                              client: client)
            deliver { [self] in
                switch r {
                case .success(let recs): completion(self, recs.map { HKObject.make($0) as! HKCorrelation }, nil)
                case .failure(let e): completion(self, nil, e)
                }
            }
        }
    }
}

// MARK: - Source query

public final class HKSourceQuery: HKQuery, @unchecked Sendable {
    let completion: @Sendable (HKSourceQuery, Set<HKSource>?, (any Error)?) -> Void

    public init(sampleType: HKSampleType, samplePredicate objectPredicate: NSPredicate?,
                completionHandler completion: @escaping @Sendable (HKSourceQuery, Set<HKSource>?, (any Error)?) -> Void) {
        self.completion = completion
        super.init(objectType: sampleType, predicate: objectPredicate)
    }

    override func run(on store: HKHealthStore) {
        let client = store.ycodeClient.bundleIdentifier
        let type = objectType!.identifier
        store.daemon.queue.async { [self] in
            let r = store.daemon.sources(type: type, node: node, client: client)
            deliver { [self] in
                switch r {
                case .success(let s): completion(self, Set(s.map { HKSource(record: $0) }), nil)
                case .failure(let e): completion(self, nil, e)
                }
            }
        }
    }
}

// MARK: - Statistics queries

public final class HKStatisticsQuery: HKQuery, @unchecked Sendable {
    let options: HKStatisticsOptions
    let completion: @Sendable (HKStatisticsQuery, HKStatistics?, (any Error)?) -> Void

    public init(quantityType: HKQuantityType, quantitySamplePredicate: NSPredicate?, options: HKStatisticsOptions = [],
                completionHandler handler: @escaping @Sendable (HKStatisticsQuery, HKStatistics?, (any Error)?) -> Void) {
        hkCheck { () throws(HKRaise) in try StatisticsEngine.validate(options, for: quantityType) }
        self.options = options
        completion = handler
        super.init(objectType: quantityType, predicate: quantitySamplePredicate)
    }

    override func run(on store: HKHealthStore) {
        let client = store.ycodeClient.bundleIdentifier
        let type = objectType as! HKQuantityType
        store.daemon.queue.async { [self] in
            let r = store.daemon.statisticsInput(type: type.identifier, node: node, client: client)
            deliver { [self] in
                switch r {
                case .failure(let e): completion(self, nil, e)
                case .success(let input):
                    guard !input.records.isEmpty else { return completion(self, nil, HKError.noData) }
                    let merged = type.aggregationStyle == .cumulative
                        ? StatisticsEngine.deduplicate(input.records, priority: input.priority) : input.records
                    let result = StatisticsEngine.compute(type: type, all: input.records, merged: merged,
                                                          options: options, window: nil)
                    completion(self, HKStatistics(result: result), nil)
                }
            }
        }
    }
}

public final class HKStatisticsCollectionQuery: HKQuery, @unchecked Sendable {
    public typealias InitialHandler = @Sendable (HKStatisticsCollectionQuery, HKStatisticsCollection?, (any Error)?) -> Void
    public typealias UpdateHandler = @Sendable (HKStatisticsCollectionQuery, HKStatistics?, HKStatisticsCollection?, (any Error)?) -> Void

    public let anchorDate: Date
    public let options: HKStatisticsOptions
    public let intervalComponents: DateComponents
    private let initial = Locked<InitialHandler?>(nil)
    private let updates = Locked<UpdateHandler?>(nil)
    private let calendar = Locked<Calendar>(Calendar.current)

    public var initialResultsHandler: InitialHandler? {
        get { initial.current }
        set { initial.withLock { $0 = newValue } }
    }
    public var statisticsUpdateHandler: UpdateHandler? {
        get { updates.current }
        set { updates.withLock { $0 = newValue } }
    }
    /// Ycode extension: the calendar used to lay out buckets (default: the current calendar).
    public var ycodeCalendar: Calendar {
        get { calendar.current }
        set { calendar.withLock { $0 = newValue } }
    }

    public init(quantityType: HKQuantityType, quantitySamplePredicate: NSPredicate?, options: HKStatisticsOptions = [],
                anchorDate: Date, intervalComponents: DateComponents) {
        hkCheck { () throws(HKRaise) in try StatisticsEngine.validate(options, for: quantityType) }
        self.anchorDate = anchorDate
        self.options = options
        self.intervalComponents = intervalComponents
        super.init(objectType: quantityType, predicate: quantitySamplePredicate)
    }

    override func run(on store: HKHealthStore) {
        let client = store.ycodeClient.bundleIdentifier
        let type = objectType as! HKQuantityType
        let daemon = store.daemon
        let calendar = ycodeCalendar
        daemon.queue.async { [self] in
            let (options, anchorDate, components) = (self.options, self.anchorDate, self.intervalComponents)
            let make = { (input: StatisticsInput) in
                HKStatisticsCollection(type: type, options: options, anchor: anchorDate, components: components,
                                       calendar: calendar, input: input)
            }
            switch daemon.statisticsInput(type: type.identifier, node: node, client: client) {
            case .failure(let e):
                deliver { [self] in initialResultsHandler?(self, nil, e) }
            case .success(let input):
                let c = make(input)
                deliver { [self] in initialResultsHandler?(self, c, nil) }
                guard statisticsUpdateHandler != nil else { return }
                registerLive(store) { [self] change in
                    guard change.types.contains(type.identifier),
                          case .success(let again) = daemon.statisticsInput(type: type.identifier, node: node, client: client)
                    else { return }
                    let c = make(again)
                    deliver { [self] in statisticsUpdateHandler?(self, nil, c, nil) }
                }
            }
        }
    }
}
