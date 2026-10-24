import Foundation

// Workout objects (`interface.md` §5.1). The workout builder, routes and live
// sessions are round R7; this file has the object model needed by the store and
// the query engine (activity type, events, duration, totals).

public final class HKWorkoutEvent: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let record: WorkoutEventRecord
    public var type: HKWorkoutEventType { HKWorkoutEventType(rawValue: record.type) ?? .marker }
    public var dateInterval: DateInterval { DateInterval(start: Date(t: record.start), end: Date(t: record.end)) }
    @available(*, deprecated, message: "Use dateInterval")
    public var date: Date { Date(t: record.start) }
    public var metadata: [String: Any]? { record.metadata?.mapValues(\.anyValue) }

    init(record: WorkoutEventRecord) {
        self.record = record
        super.init()
    }

    public convenience init(type: HKWorkoutEventType, dateInterval: DateInterval, metadata: [String: Any]?) {
        let md = hkCheck { () throws(HKRaise) in try Validation.metadata(metadata) }
        self.init(record: WorkoutEventRecord(type: type.rawValue, start: dateInterval.start.t,
                                             end: dateInterval.end.t, metadata: md))
    }
    @available(*, deprecated, message: "Use init(type:dateInterval:metadata:)")
    public convenience init(type: HKWorkoutEventType, date: Date) {
        self.init(type: type, dateInterval: DateInterval(start: date, duration: 0), metadata: nil)
    }

    public override func isEqual(_ object: Any?) -> Bool { (object as? HKWorkoutEvent)?.record == record }
    public override var hash: Int { record.hashValue }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode((try? JSONEncoder().encode(record)) ?? Data(), forKey: "record")
    }
    public required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "record") as Data?,
              let r = try? JSONDecoder().decode(WorkoutEventRecord.self, from: d) else { return nil }
        record = r
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

public final class HKWorkout: HKSample, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    var workoutRecord: WorkoutRecord { record.workout! }

    public var workoutActivityType: HKWorkoutActivityType {
        HKWorkoutActivityType(rawValue: workoutRecord.activityType) ?? .other
    }
    public var workoutEvents: [HKWorkoutEvent]? {
        let e = workoutRecord.events
        return e.isEmpty ? nil : e.map { HKWorkoutEvent(record: $0) }
    }
    #if canImport(ObjectiveC)
    @objc public var duration: TimeInterval { workoutRecord.duration }
    #else
    public var duration: TimeInterval { workoutRecord.duration }
    #endif
    @available(*, deprecated, message: "Use statistics(for:)")
    public var totalEnergyBurned: HKQuantity? { workoutRecord.totalEnergyBurned?.quantity }
    @available(*, deprecated, message: "Use statistics(for:)")
    public var totalDistance: HKQuantity? { workoutRecord.totalDistance?.quantity }
    @available(*, deprecated, message: "Use statistics(for:)")
    public var totalSwimmingStrokeCount: HKQuantity? { workoutRecord.totalSwimmingStrokeCount?.quantity }
    @available(*, deprecated, message: "Use statistics(for:)")
    public var totalFlightsClimbed: HKQuantity? { workoutRecord.totalFlightsClimbed?.quantity }

    /// Per-type statistics; the builder that fills them is round R7.
    public var allStatistics: [HKQuantityType: HKStatistics] { [:] }
    public func statistics(for quantityType: HKQuantityType) -> HKStatistics? { allStatistics[quantityType] }

    public convenience init(activityType: HKWorkoutActivityType, start startDate: Date, end endDate: Date,
                            workoutEvents: [HKWorkoutEvent]?, totalEnergyBurned: HKQuantity?,
                            totalDistance: HKQuantity?, device: HKDevice?, metadata: [String: Any]?) {
        let r = hkCheck { () throws(HKRaise) in
            try HKWorkout.makeRecord(activityType: activityType, start: startDate, end: endDate,
                                     events: workoutEvents ?? [], duration: nil, energy: totalEnergyBurned,
                                     distance: totalDistance, device: device, metadata: metadata)
        }
        self.init(record: r)
    }
    public convenience init(activityType: HKWorkoutActivityType, start startDate: Date, end endDate: Date,
                            workoutEvents: [HKWorkoutEvent]?, totalEnergyBurned: HKQuantity?,
                            totalDistance: HKQuantity?, metadata: [String: Any]?) {
        self.init(activityType: activityType, start: startDate, end: endDate, workoutEvents: workoutEvents,
                  totalEnergyBurned: totalEnergyBurned, totalDistance: totalDistance, device: nil, metadata: metadata)
    }
    public convenience init(activityType: HKWorkoutActivityType, start startDate: Date, end endDate: Date) {
        self.init(activityType: activityType, start: startDate, end: endDate, workoutEvents: nil,
                  totalEnergyBurned: nil, totalDistance: nil, device: nil, metadata: nil)
    }
    public convenience init(activityType: HKWorkoutActivityType, start startDate: Date, end endDate: Date,
                            duration: TimeInterval, totalEnergyBurned: HKQuantity?, totalDistance: HKQuantity?,
                            metadata: [String: Any]?) {
        let r = hkCheck { () throws(HKRaise) in
            try HKWorkout.makeRecord(activityType: activityType, start: startDate, end: endDate, events: [],
                                     duration: duration, energy: totalEnergyBurned, distance: totalDistance,
                                     device: nil, metadata: metadata)
        }
        self.init(record: r)
    }

    /// Duration = end − start minus paused time (pause → resume pairs).
    static func activeDuration(start: Double, end: Double, events: [WorkoutEventRecord]) -> Double {
        var paused = 0.0
        var pauseStart: Double?
        for e in events.sorted(by: { $0.start < $1.start }) {
            if e.type == HKWorkoutEventType.pause.rawValue, pauseStart == nil { pauseStart = e.start }
            if e.type == HKWorkoutEventType.resume.rawValue, let p = pauseStart {
                paused += max(0, min(e.start, end) - max(p, start))
                pauseStart = nil
            }
        }
        if let p = pauseStart { paused += max(0, end - max(p, start)) }
        return max(0, end - start - paused)
    }

    static func makeRecord(activityType: HKWorkoutActivityType, start: Date, end: Date, events: [HKWorkoutEvent],
                           duration: Double?, energy: HKQuantity?, distance: HKQuantity?, device: HKDevice?,
                           metadata: [String: Any]?) throws(HKRaise) -> ObjectRecord {
        if let energy, !energy.is(compatibleWith: .kilocalorie()) {
            throw .validation("Total energy burned requires an energy unit; incompatible unit: \(energy.unit.unitString)")
        }
        if let distance, !distance.is(compatibleWith: .meter()) {
            throw .validation("Total distance requires a length unit; incompatible unit: \(distance.unit.unitString)")
        }
        var r = try baseRecord(kind: .workout, type: HKObjectType.workoutType(), start: start, end: end,
                               device: device, metadata: metadata)
        let ev = events.map(\.record)
        r.workout = WorkoutRecord(activityType: activityType.rawValue,
                                  duration: duration ?? activeDuration(start: start.t, end: end.t, events: ev),
                                  events: ev, totalEnergyBurned: energy.map(QuantityValueRecord.init),
                                  totalDistance: distance.map(QuantityValueRecord.init))
        return r
    }
}

/// Workout configuration (`interface.md` §5.1).
public final class HKWorkoutConfiguration: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public var activityType: HKWorkoutActivityType = .other
    public var locationType: HKWorkoutSessionLocationType = .unknown
    public var swimmingLocationType: HKWorkoutSwimmingLocationType = .unknown
    public var lapLength: HKQuantity?

    public override init() { super.init() }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode(activityType.rawValue, forKey: "activityType")
        coder.encode(locationType.rawValue, forKey: "locationType")
        coder.encode(swimmingLocationType.rawValue, forKey: "swimmingLocationType")
        if let lapLength { coder.encode(lapLength, forKey: "lapLength") }
    }
    public required init?(coder: NSCoder) {
        activityType = HKWorkoutActivityType(rawValue: coder.decodeInteger(forKey: "activityType")) ?? .other
        locationType = HKWorkoutSessionLocationType(rawValue: coder.decodeInteger(forKey: "locationType")) ?? .unknown
        swimmingLocationType = HKWorkoutSwimmingLocationType(rawValue: coder.decodeInteger(forKey: "swimmingLocationType")) ?? .unknown
        lapLength = coder.decodeObject(of: HKQuantity.self, forKey: "lapLength")
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any {
        let c = HKWorkoutConfiguration()
        c.activityType = activityType
        c.locationType = locationType
        c.swimmingLocationType = swimmingLocationType
        c.lapLength = lapLength
        return c
    }
}
