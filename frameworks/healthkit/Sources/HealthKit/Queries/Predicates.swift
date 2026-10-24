import Foundation

/// `HKQueryOptions` (raw values in `identifiers.md`).
public struct HKQueryOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let strictStartDate = HKQueryOptions(rawValue: 1)
    public static let strictEndDate = HKQueryOptions(rawValue: 2)
}

enum CompareOp: Int, Codable, Sendable {
    case lt, le, gt, ge, eq, ne

    init?(_ op: NSComparisonPredicate.Operator) {
        switch op {
        case .lessThan: self = .lt
        case .lessThanOrEqualTo: self = .le
        case .greaterThan: self = .gt
        case .greaterThanOrEqualTo: self = .ge
        case .equalTo: self = .eq
        case .notEqualTo: self = .ne
        default: return nil
        }
    }

    func test<T: Comparable>(_ a: T, _ b: T) -> Bool {
        switch self {
        case .lt: return a < b
        case .le: return a <= b
        case .gt: return a > b
        case .ge: return a >= b
        case .eq: return a == b
        case .ne: return a != b
        }
    }
}

/// The structured form of a HealthKit predicate (`queries.md` §2, `design.md` §6.1).
indirect enum PredicateNode: @unchecked Sendable {
    case constant(Bool)
    case typeIs(String)
    case and([PredicateNode])
    case or([PredicateNode])
    case not(PredicateNode)
    case dateInterval(start: Double?, end: Double?, options: HKQueryOptions)
    case startDate(CompareOp, Double)
    case endDate(CompareOp, Double)
    case uuids(Set<UUID>)
    case sources(Set<String>)
    case sourceRevisions([SourceRevisionRecord])
    case devices(Set<DeviceRecord>)
    case deviceProperty(key: String, allowed: Set<String>)
    case metadataExists(String)
    case metadataAllowed(String, [MetadataValue])
    case metadataCompare(String, CompareOp, MetadataValue)
    case quantity(CompareOp, refValue: Double, dimension: Dimension)
    case categoryValue(CompareOp, Int)
    case categoryIn(Set<Int>)
    case noCorrelation
    case workout(UUID)
    case workoutActivityType(Int)
    case workoutDuration(CompareOp, Double)
    /// Any other `NSPredicate` (block, constant): evaluated on the materialized object.
    case opaque(NSPredicate)

    /// The date bounds every match must fall into, for a coarse SQL filter.
    var coarseBounds: (start: Double?, end: Double?) {
        switch self {
        case .dateInterval(let s, let e, _): return (s, e)
        case .and(let parts):
            var lo: Double?, hi: Double?
            for p in parts {
                let b = p.coarseBounds
                if let s = b.start { lo = max(lo ?? s, s) }
                if let e = b.end { hi = min(hi ?? e, e) }
            }
            return (lo, hi)
        default: return (nil, nil)
        }
    }

    /// Convert any NSPredicate into a node.
    static func from(_ predicate: NSPredicate?) -> PredicateNode? {
        guard let predicate else { return nil }
        if let p = predicate as? HKNodePredicate { return p.node }
        if let c = predicate as? NSCompoundPredicate {
            let subs = (c.subpredicates as [Any]).compactMap { from($0 as? NSPredicate) }
            switch c.compoundPredicateType {
            case .and: return .and(subs)
            case .or: return .or(subs)
            case .not: return .not(subs.count == 1 ? subs[0] : .and(subs))
            @unknown default: return .opaque(c)
            }
        }
        #if canImport(ObjectiveC)
        if let c = predicate as? NSComparisonPredicate { return fromComparison(c) }
        #endif
        return .opaque(predicate)
    }

    #if canImport(ObjectiveC)
    /// Plain predicates written by the app over HealthKit key paths (`queries.md` §2).
    static func fromComparison(_ c: NSComparisonPredicate) -> PredicateNode {
        guard c.leftExpression.expressionType == .keyPath, c.rightExpression.expressionType == .constantValue
        else { return .constant(false) }
        let key = c.leftExpression.keyPath
        let value = c.rightExpression.constantValue
        if c.predicateOperatorType == .in, let list = value as? [Any] {
            switch key {
            case HKPredicateKeyPathUUID: return .uuids(Set(list.compactMap { $0 as? UUID }))
            case HKPredicateKeyPathCategoryValue: return .categoryIn(Set(list.compactMap { ($0 as? NSNumber)?.intValue }))
            default: return .constant(false)
            }
        }
        guard let op = CompareOp(c.predicateOperatorType) else { return .constant(false) }
        switch key {
        case HKPredicateKeyPathStartDate: return (value as? Date).map { .startDate(op, $0.t) } ?? .constant(false)
        case HKPredicateKeyPathEndDate: return (value as? Date).map { .endDate(op, $0.t) } ?? .constant(false)
        case HKPredicateKeyPathCategoryValue:
            return (value as? NSNumber).map { .categoryValue(op, $0.intValue) } ?? .constant(false)
        case HKPredicateKeyPathUUID where op == .eq: return (value as? UUID).map { .uuids([$0]) } ?? .constant(false)
        case HKPredicateKeyPathQuantity:
            return (value as? HKQuantity).map { .quantity(op, refValue: $0.referenceValue, dimension: $0.unit.dimension) }
                ?? .constant(false)
        case HKPredicateKeyPathWorkoutDuration:
            return (value as? NSNumber).map { .workoutDuration(op, $0.doubleValue) } ?? .constant(false)
        default:
            if key.hasPrefix(HKPredicateKeyPathMetadata + "."), let v = value.flatMap(MetadataValue.from) {
                return .metadataCompare(String(key.dropFirst(HKPredicateKeyPathMetadata.count + 1)), op, v)
            }
            return .constant(false)
        }
    }
    #endif
}

/// The NSPredicate subclass HealthKit's predicate constructors return. It carries
/// the structured node and also evaluates against HealthKit objects directly.
final class HKNodePredicate: NSPredicate {
    let node: PredicateNode
    let text: String

    init(_ node: PredicateNode, _ text: String) {
        self.node = node
        self.text = text
        #if canImport(ObjectiveC)
        super.init()
        #else
        super.init(value: true)
        #endif
    }

    required init?(coder: NSCoder) { return nil }

    override func evaluate(with object: Any?, substitutionVariables bindings: [String: Any]?) -> Bool {
        guard let o = object as? HKObject else { return false }
        return PredicateEvaluator.matches(node, o.record)
    }
    override var predicateFormat: String { text }
    override var description: String { text }
    override func copy(with zone: NSZone? = nil) -> Any { self }
}

enum PredicateEvaluator {
    /// A missing predicate matches everything.
    static func matches(_ node: PredicateNode?, _ r: ObjectRecord) -> Bool {
        guard let node else { return true }
        return matches(node, r)
    }

    static func matches(_ node: PredicateNode, _ r: ObjectRecord) -> Bool {
        switch node {
        case .constant(let b): return b
        case .typeIs(let t): return r.type == t
        case .and(let parts): return parts.allSatisfy { matches($0, r) }
        case .or(let parts): return parts.contains { matches($0, r) }
        case .not(let p): return !matches(p, r)
        case .dateInterval(let ws, let we, let options):
            return dateInterval(start: r.start, end: r.end, ws: ws, we: we, options: options)
        case .startDate(let op, let t): return op.test(r.start, t)
        case .endDate(let op, let t): return op.test(r.end, t)
        case .uuids(let set): return set.contains(r.uuid)
        case .sources(let ids): return ids.contains(r.sourceBundle)
        case .sourceRevisions(let revs):
            guard let rr = r.revision else { return false }
            return revs.contains { rev in
                rev.source.bundleIdentifier == rr.source.bundleIdentifier
                    && (rev.version == HKSourceRevisionAnyVersion || rev.version == rr.version)
                    && (rev.productType == HKSourceRevisionAnyProductType || rev.productType == rr.productType)
            }
        case .devices(let set): return r.device.map { set.contains($0) } ?? false
        case .deviceProperty(let key, let allowed):
            guard let d = r.device, let v = HKDevice(record: d).value(forProperty: key) else { return false }
            return allowed.contains(v)
        case .metadataExists(let key): return r.metadata?[key] != nil
        case .metadataAllowed(let key, let values):
            guard let v = r.metadata?[key] else { return false }
            return values.contains { compare(v, .eq, $0) }
        case .metadataCompare(let key, let op, let value):
            guard let v = r.metadata?[key] else { return false }
            return compare(v, op, value)
        case .quantity(let op, let ref, let dim):
            guard r.kind == .quantity, let t = TypeRegistry.type(r.type) as? HKQuantityType,
                  t.quantityDimension.dimension == dim else { return false }
            return op.test(r.ref, ref)
        case .categoryValue(let op, let v): return r.kind == .category && op.test(r.categoryValue, v)
        case .categoryIn(let set): return r.kind == .category && set.contains(r.categoryValue)
        case .noCorrelation: return r.correlationParent == nil
        case .workout(let id): return r.workoutParent == id
        case .workoutActivityType(let t): return r.workout?.activityType == t
        case .workoutDuration(let op, let d): return r.workout.map { op.test($0.duration, d) } ?? false
        case .opaque(let p): return p.evaluate(with: HKObject.make(r))
        }
    }

    /// Interval rules of `queries.md` §2.1.
    static func dateInterval(start s: Double, end e: Double, ws: Double?, we: Double?, options: HKQueryOptions) -> Bool {
        let strictStart = options.contains(.strictStartDate)
        let strictEnd = options.contains(.strictEndDate)
        if strictStart && strictEnd {
            if let ws, s < ws { return false }
            if let we, e > we { return false }
            return true
        }
        if let we, !(s < we) { return false }
        if let ws, !(e >= ws) { return false }
        if strictStart, let ws, s < ws { return false }
        if strictEnd, let we, e > we { return false }
        return true
    }

    static func compare(_ a: MetadataValue, _ op: CompareOp, _ b: MetadataValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return op.test(x, y)
        case (.date(let x), .date(let y)): return op.test(x, y)
        case (.quantity(let xv, let xu), .quantity(let yv, let yu)):
            let ux = HKUnit(from: xu), uy = HKUnit(from: yu)
            guard ux.isCompatible(with: uy) else { return false }
            return op.test(ux.toReference(xv), uy.toReference(yv))
        default:
            if let x = a.number, let y = b.number { return op.test(x, y) }
            return op == .ne
        }
    }
}

// MARK: - Predicate constructors (`api-inventory.md`, HKQuery categories)

extension HKQuery {
    static func node(_ n: PredicateNode, _ text: String) -> NSPredicate { HKNodePredicate(n, text) }

    public class func predicateForObjects(withMetadataKey key: String) -> NSPredicate {
        node(.metadataExists(key), "metadata.\(key) != nil")
    }
    public class func predicateForObjects(withMetadataKey key: String, allowedValues: [Any]) -> NSPredicate {
        node(.metadataAllowed(key, allowedValues.compactMap(MetadataValue.from)), "metadata.\(key) IN \(allowedValues)")
    }
    public class func predicateForObjects(withMetadataKey key: String, operatorType: NSComparisonPredicate.Operator,
                                          value: Any) -> NSPredicate {
        guard let op = CompareOp(operatorType), let v = MetadataValue.from(value) else {
            hkRaise(.invalidArgument("Unsupported metadata predicate for key \(key)"))
        }
        return node(.metadataCompare(key, op, v), "metadata.\(key) \(op) \(value)")
    }
    public class func predicateForObjects(from source: HKSource) -> NSPredicate {
        node(.sources([source.bundleIdentifier]), "source == \(source.bundleIdentifier)")
    }
    public class func predicateForObjects(from sources: Set<HKSource>) -> NSPredicate {
        node(.sources(Set(sources.map(\.bundleIdentifier))), "source IN \(sources.map(\.bundleIdentifier).sorted())")
    }
    public class func predicateForObjects(from sourceRevisions: Set<HKSourceRevision>) -> NSPredicate {
        node(.sourceRevisions(sourceRevisions.map(\.record)), "sourceRevision IN (\(sourceRevisions.count))")
    }
    public class func predicateForObjects(from devices: Set<HKDevice>) -> NSPredicate {
        node(.devices(Set(devices.map(\.record))), "device IN (\(devices.count))")
    }
    public class func predicateForObjects(withDeviceProperty key: String, allowedValues: Set<String>) -> NSPredicate {
        node(.deviceProperty(key: key, allowed: allowedValues), "device.\(key) IN \(allowedValues.sorted())")
    }
    public class func predicateForObject(with UUID: UUID) -> NSPredicate {
        node(.uuids([UUID]), "UUID == \(UUID)")
    }
    public class func predicateForObjects(with UUIDs: Set<UUID>) -> NSPredicate {
        node(.uuids(UUIDs), "UUID IN (\(UUIDs.count))")
    }
    public class func predicateForObjectsWithNoCorrelation() -> NSPredicate {
        node(.noCorrelation, "correlation == nil")
    }
    public class func predicateForObjects(from workout: HKWorkout) -> NSPredicate {
        node(.workout(workout.uuid), "workout == \(workout.uuid)")
    }
    public class func predicateForSamples(withStart startDate: Date?, end endDate: Date?,
                                          options: HKQueryOptions = []) -> NSPredicate {
        node(.dateInterval(start: startDate?.t, end: endDate?.t, options: options),
             "startDate/endDate in [\(startDate.map { "\($0)" } ?? "nil"), \(endDate.map { "\($0)" } ?? "nil")] options \(options.rawValue)")
    }
    public class func predicateForQuantitySamples(with operatorType: NSComparisonPredicate.Operator,
                                                  quantity: HKQuantity) -> NSPredicate {
        guard let op = CompareOp(operatorType) else {
            hkRaise(.invalidArgument("Unsupported operator for quantity predicate"))
        }
        return node(.quantity(op, refValue: quantity.referenceValue, dimension: quantity.unit.dimension),
                    "quantity \(op) \(quantity)")
    }
    public class func predicateForCategorySamples(with operatorType: NSComparisonPredicate.Operator,
                                                  value: Int) -> NSPredicate {
        guard let op = CompareOp(operatorType) else {
            hkRaise(.invalidArgument("Unsupported operator for category predicate"))
        }
        return node(.categoryValue(op, value), "value \(op) \(value)")
    }
    public class func predicateForCategorySamples(equalTo values: Set<Int>) -> NSPredicate {
        node(.categoryIn(values), "value IN \(values.sorted())")
    }
    public class func predicateForWorkouts(with workoutActivityType: HKWorkoutActivityType) -> NSPredicate {
        node(.workoutActivityType(workoutActivityType.rawValue), "workoutType == \(workoutActivityType.rawValue)")
    }
    public class func predicateForWorkouts(with operatorType: NSComparisonPredicate.Operator,
                                           duration: TimeInterval) -> NSPredicate {
        guard let op = CompareOp(operatorType) else {
            hkRaise(.invalidArgument("Unsupported operator for workout duration predicate"))
        }
        return node(.workoutDuration(op, duration), "duration \(op) \(duration)")
    }
}

/// The asleep values of sleep analysis (`identifiers.md` "Functions").
public func HKCategoryValueSleepAnalysisAsleepValues() -> Set<HKCategoryValueSleepAnalysis> {
    [.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM]
}
