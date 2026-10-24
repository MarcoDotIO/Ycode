import Foundation

// MARK: - Characteristic wrappers (`interface.md` §6)

public final class HKBiologicalSexObject: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public let biologicalSex: HKBiologicalSex
    init(_ v: HKBiologicalSex) { biologicalSex = v; super.init() }
    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(biologicalSex.rawValue, forKey: "v") }
    public required init?(coder: NSCoder) { biologicalSex = HKBiologicalSex(rawValue: coder.decodeInteger(forKey: "v")) ?? .notSet }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}
public final class HKBloodTypeObject: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public let bloodType: HKBloodType
    init(_ v: HKBloodType) { bloodType = v; super.init() }
    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(bloodType.rawValue, forKey: "v") }
    public required init?(coder: NSCoder) { bloodType = HKBloodType(rawValue: coder.decodeInteger(forKey: "v")) ?? .notSet }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}
public final class HKFitzpatrickSkinTypeObject: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public let skinType: HKFitzpatrickSkinType
    init(_ v: HKFitzpatrickSkinType) { skinType = v; super.init() }
    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(skinType.rawValue, forKey: "v") }
    public required init?(coder: NSCoder) { skinType = HKFitzpatrickSkinType(rawValue: coder.decodeInteger(forKey: "v")) ?? .notSet }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}
public final class HKWheelchairUseObject: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public let wheelchairUse: HKWheelchairUse
    init(_ v: HKWheelchairUse) { wheelchairUse = v; super.init() }
    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(wheelchairUse.rawValue, forKey: "v") }
    public required init?(coder: NSCoder) { wheelchairUse = HKWheelchairUse(rawValue: coder.decodeInteger(forKey: "v")) ?? .notSet }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}
public final class HKActivityMoveModeObject: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public let activityMoveMode: HKActivityMoveMode
    init(_ v: HKActivityMoveMode) { activityMoveMode = v; super.init() }
    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(activityMoveMode.rawValue, forKey: "v") }
    public required init?(coder: NSCoder) {
        activityMoveMode = HKActivityMoveMode(rawValue: coder.decodeInteger(forKey: "v")) ?? .activeEnergy
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

// MARK: - The health store

/// Access point for all health data (`interface.md` §1). All asynchronous members
/// complete on a private serial queue, never the caller's.
public final class HKHealthStore: NSObject, @unchecked Sendable {
    let daemon: YcodeHealthDaemon
    /// Ycode extension: the identity this store acts as (the app's source).
    public let ycodeClient: YcodeHealthClient
    let callbackQueue = DispatchQueue(label: "dev.ycode.healthkit.store")

    /// The process-wide store, acting as this process's own client.
    public override convenience init() {
        self.init(ycodeDaemon: .shared, client: .processDefault)
    }

    /// Ycode extension: a store bound to a given engine and client identity (tests, tools).
    public init(ycodeDaemon daemon: YcodeHealthDaemon, client: YcodeHealthClient) {
        self.daemon = daemon
        self.ycodeClient = client
        super.init()
    }

    private var client: String { ycodeClient.bundleIdentifier }

    /// Run `body` on the engine, then hand its result to `completion` on the store's queue.
    private func call<T: Sendable>(_ body: @escaping @Sendable (YcodeHealthDaemon) -> T,
                                   _ completion: @escaping @Sendable (T) -> Void) {
        let daemon = self.daemon, cq = callbackQueue
        daemon.queue.async {
            let r = body(daemon)
            cq.async { completion(r) }
        }
    }

    // MARK: availability

    public class func isHealthDataAvailable() -> Bool { true }
    public func supportsHealthRecords() -> Bool { false }
    /// Year 1, no limit (`simulator-baseline.md` §2).
    public func earliestPermittedSampleDate() -> Date { Date(timeIntervalSinceReferenceDate: -63_113_904_000) }

    // MARK: authorization (minimal; the full model is round R6)

    public func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        let row = daemon.queue.sync { daemon.authRow(client, type.identifier) }
        switch row.shareStatus {
        case 2: return .sharingAuthorized
        case 1: return .sharingDenied
        default: return row.readStatus != 0 ? .sharingDenied : .notDetermined
        }
    }

    static func validateRequest(share: Set<HKSampleType>?, read: Set<HKObjectType>?) throws(HKRaise) {
        let s = share ?? [], r = read ?? []
        if s.isEmpty && r.isEmpty { throw .invalidArgument("Must request authorization for at least one data type") }
        let badShare = s.filter { !$0.info.shareable }.map(\.identifier).sorted()
        if !badShare.isEmpty {
            throw .invalidArgument("Authorization to share the following types is disallowed: \(badShare.joined(separator: ", "))")
        }
        let badRead = r.filter { !$0.info.readable || $0.info.perObject || $0.info.kind == .clinical }
            .map(\.identifier).sorted()
        if !badRead.isEmpty {
            throw .invalidArgument("Authorization to read the following types is disallowed: \(badRead.joined(separator: ", "))")
        }
    }

    public func requestAuthorization(toShare typesToShare: Set<HKSampleType>?, read typesToRead: Set<HKObjectType>?,
                                     completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        hkCheck { () throws(HKRaise) in try HKHealthStore.validateRequest(share: typesToShare, read: typesToRead) }
        let share = Array(typesToShare ?? []), read = Array(typesToRead ?? [])
        let c = ycodeClient
        call({ $0.requestAuthorization(client: c, share: share, read: read) }) { e in
            completion(e == nil, e)
        }
    }

    public func getRequestStatusForAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>,
                                                 completion: @escaping @Sendable (HKAuthorizationRequestStatus, (any Error)?) -> Void) {
        let share = Array(typesToShare), read = Array(typesToRead), c = client
        call({ $0.requestStatus(client: c, share: share, read: read) }) { s in
            completion(HKAuthorizationRequestStatus(rawValue: s) ?? .unknown, nil)
        }
    }

    /// Earliest sample date each type may be read from (`authorization.md` §5).
    public func getEarliestAuthorizedSampleDate(for types: Set<HKSampleType>,
                                                completion: @escaping @Sendable ([HKSampleType: Date], (any Error)?) -> Void) {
        let ids = types.map(\.identifier), c = client
        let floor = earliestPermittedSampleDate()
        call({ $0.earliestDates(ids, client: c) }) { dates in
            var out: [HKSampleType: Date] = [:]
            for (id, d) in dates { if let t = TypeRegistry.sampleType(id) { out[t] = d.map { Date(t: $0) } ?? floor } }
            completion(out, nil)
        }
    }

    // MARK: saving and deleting

    public func save(_ object: HKObject, withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        save([object], withCompletion: completion)
    }

    /// Atomic: one call is one change set.
    public func save(_ objects: [HKObject], withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let recs = objects.map(\.record), c = ycodeClient
        call({ $0.save(recs, client: c) }) { e in completion(e == nil, e) }
    }

    public func delete(_ object: HKObject, withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        delete([object], withCompletion: completion)
    }

    public func delete(_ objects: [HKObject], withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let ids = objects.map(\.uuid), c = client
        call({ $0.delete(ids, client: c) }) { e in completion(e == nil, e) }
    }

    public func deleteObjects(of objectType: HKObjectType, predicate: NSPredicate,
                              withCompletion completion: @escaping @Sendable (Bool, Int, (any Error)?) -> Void) {
        let node = UncheckedSendable(PredicateNode.from(predicate)), c = client, id = objectType.identifier
        call({ $0.deleteObjects(type: id, node: node.value, client: c) }) { r in
            switch r {
            case .success(let n): completion(true, n, nil)
            case .failure(let e): completion(false, 0, e)
            }
        }
    }

    /// Associate samples with a saved workout (saves them first).
    @available(*, deprecated, message: "Use HKWorkoutBuilder")
    public func add(_ samples: [HKSample], to workout: HKWorkout,
                    completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        associate(samples, to: workout, completion: completion)
    }

    func associate(_ samples: [HKSample], to workout: HKWorkout,
                   completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let recs = samples.map(\.record), c = ycodeClient, w = workout.uuid
        call({ $0.associate(recs, workout: w, client: c) }) { e in completion(e == nil, e) }
    }

    // MARK: queries

    public func execute(_ query: HKQuery) {
        hkCheck { () throws(HKRaise) in try query.markExecuted(self) }
        query.run(on: self)
    }

    public func stop(_ query: HKQuery) { query.stopRunning(self) }

    // MARK: characteristics (synchronous; `interface.md` §6)

    private func characteristic(_ id: HKCharacteristicTypeIdentifier) throws -> String? {
        let c = client
        switch daemon.queue.sync(execute: { daemon.characteristic(id.rawValue, client: c) }) {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    public func biologicalSex() throws -> HKBiologicalSexObject {
        HKBiologicalSexObject(try characteristic(.biologicalSex).flatMap(Int.init).flatMap(HKBiologicalSex.init) ?? .notSet)
    }
    public func bloodType() throws -> HKBloodTypeObject {
        HKBloodTypeObject(try characteristic(.bloodType).flatMap(Int.init).flatMap(HKBloodType.init) ?? .notSet)
    }
    public func fitzpatrickSkinType() throws -> HKFitzpatrickSkinTypeObject {
        HKFitzpatrickSkinTypeObject(try characteristic(.fitzpatrickSkinType).flatMap(Int.init)
            .flatMap(HKFitzpatrickSkinType.init) ?? .notSet)
    }
    public func wheelchairUse() throws -> HKWheelchairUseObject {
        HKWheelchairUseObject(try characteristic(.wheelchairUse).flatMap(Int.init).flatMap(HKWheelchairUse.init) ?? .notSet)
    }
    public func activityMoveMode() throws -> HKActivityMoveModeObject {
        HKActivityMoveModeObject(try characteristic(.activityMoveMode).flatMap(Int.init)
            .flatMap(HKActivityMoveMode.init) ?? .activeEnergy)
    }
    /// Date of birth as calendar components (empty when not set).
    public func dateOfBirthComponents() throws -> DateComponents {
        guard let s = try characteristic(.dateOfBirth) else { return DateComponents() }
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return DateComponents() }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: p[0], month: p[1], day: p[2])
    }
    @available(*, deprecated, message: "Use dateOfBirthComponents()")
    public func dateOfBirth() throws -> Date {
        guard let d = try dateOfBirthComponents().date else { throw HKError(.errorNoData) }
        return d
    }

    // MARK: background delivery (registry only; launch on change is round R8)

    public func enableBackgroundDelivery(for type: HKObjectType, frequency: HKUpdateFrequency,
                                         withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let c = client, id = type.identifier
        call({ $0.setBackgroundDelivery(id, frequency: frequency.rawValue, client: c) }) { completion(true, nil) }
    }
    public func disableBackgroundDelivery(for type: HKObjectType,
                                          withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let c = client, id = type.identifier
        call({ $0.setBackgroundDelivery(id, frequency: nil, client: c) }) { completion(true, nil) }
    }
    public func disableAllBackgroundDelivery(completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let c = client
        call({ $0.setBackgroundDelivery(nil, frequency: nil, client: c) }) { completion(true, nil) }
    }

    // MARK: preferred units (`units.md` §7; en_US only, regions are round R8)

    public func preferredUnits(for quantityTypes: Set<HKQuantityType>,
                               completion: @escaping @Sendable ([HKQuantityType: HKUnit], (any Error)?) -> Void) {
        let ids = quantityTypes.map(\.identifier), c = client
        call({ d in ids.allSatisfy { d.determined($0, client: c) } }) { ok in
            guard ok else {
                return completion([:], HKError(.errorAuthorizationNotDetermined,
                                               message: "Authorization is not determined for all types provided."))
            }
            var out: [HKQuantityType: HKUnit] = [:]
            for t in quantityTypes { out[t] = PreferredUnits.enUS(t) }
            completion(out, nil)
        }
    }
}

enum PreferredUnits {
    static func enUS(_ t: HKQuantityType) -> HKUnit {
        switch t.identifier {
        case HKQuantityTypeIdentifier.height.rawValue, HKQuantityTypeIdentifier.waistCircumference.rawValue:
            return HKUnit(from: "ft")
        case HKQuantityTypeIdentifier.heartRate.rawValue: return HKUnit(from: "count/min")
        default: break
        }
        switch t.quantityDimension {
        case .scalar: return HKUnit(from: t.identifier.hasSuffix("Percentage") || t.identifier.hasSuffix("Saturation") ? "%" : "count")
        case .mass: return t.identifier.hasPrefix("HKQuantityTypeIdentifierDietary") ? HKUnit(from: "g") : HKUnit(from: "lb")
        case .length: return HKUnit(from: "mi")
        case .volume: return HKUnit(from: "fl_oz_us")
        case .time: return HKUnit(from: "min")
        case .energy: return HKUnit(from: "Cal")
        case .temperature: return HKUnit(from: "degF")
        case .pressure: return HKUnit(from: "mmHg")
        case .speed: return HKUnit(from: "mi/hr")
        case .frequency: return HKUnit(from: "count/min")
        case .power: return HKUnit(from: "W")
        case .conductance: return HKUnit(from: "mcS")
        case .soundPressureLevel: return HKUnit(from: "dBASPL")
        case .effortScore: return HKUnit(from: "appleEffortScore")
        case .pharmacology: return HKUnit(from: "IU")
        case .volumeFlow: return HKUnit(from: "L/min")
        case .energyRatePerMass: return HKUnit(from: "kcal/(kg*hr)")
        case .vo2Rate: return HKUnit(from: "mL/(kg*min)")
        case .massConcentration: return HKUnit(from: "mg/dL")
        }
    }
}

// MARK: - Swift concurrency variants (`interface.md` §9)

extension HKHealthStore {
    public func requestAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            requestAuthorization(toShare: typesToShare, read: typesToRead) { ok, e in
                if let e { k.resume(throwing: e) } else { k.resume() }
            }
        }
    }

    public func statusForAuthorizationRequest(toShare typesToShare: Set<HKSampleType>,
                                              read typesToRead: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { k in
            getRequestStatusForAuthorization(toShare: typesToShare, read: typesToRead) { s, e in
                if let e { k.resume(throwing: e) } else { k.resume(returning: s) }
            }
        }
    }

    public func save(_ object: HKObject) async throws { try await save([object]) }

    public func save(_ objects: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            save(objects) { _, e in if let e { k.resume(throwing: e) } else { k.resume() } }
        }
    }

    public func delete(_ object: HKObject) async throws { try await delete([object]) }

    public func delete(_ objects: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            delete(objects) { _, e in if let e { k.resume(throwing: e) } else { k.resume() } }
        }
    }

    public func deleteObjects(of objectType: HKObjectType, predicate: NSPredicate) async throws -> Int {
        try await withCheckedThrowingContinuation { k in
            deleteObjects(of: objectType, predicate: predicate) { _, n, e in
                if let e { k.resume(throwing: e) } else { k.resume(returning: n) }
            }
        }
    }

    public func preferredUnits(for quantityTypes: Set<HKQuantityType>) async throws -> [HKQuantityType: HKUnit] {
        try await withCheckedThrowingContinuation { k in
            preferredUnits(for: quantityTypes) { u, e in if let e { k.resume(throwing: e) } else { k.resume(returning: u) } }
        }
    }

    public func enableBackgroundDelivery(for type: HKObjectType, frequency: HKUpdateFrequency) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            enableBackgroundDelivery(for: type, frequency: frequency) { _, e in
                if let e { k.resume(throwing: e) } else { k.resume() }
            }
        }
    }

    public func earliestAuthorizedSampleDate(for types: Set<HKSampleType>) async throws -> [HKSampleType: Date] {
        try await withCheckedThrowingContinuation { k in
            getEarliestAuthorizedSampleDate(for: types) { d, e in if let e { k.resume(throwing: e) } else { k.resume(returning: d) } }
        }
    }
}

extension HKCategoryValueSleepAnalysis {
    /// The asleep stages (unspecified, core, deep, REM).
    public static var allAsleepValues: Set<HKCategoryValueSleepAnalysis> { HKCategoryValueSleepAnalysisAsleepValues() }
}
