import Foundation
import HealthKit

/// One observation made during a probe workout.
///
/// Times are seconds from the start of the workout session. The only absolute time is
/// `startEpoch`. It is set on the session-start event so that the phone can limit its
/// HealthKit queries to the session, and the phone removes it before anything leaves the
/// device. Source and device names are never read. For metadata, only key names are kept.
struct ProbeEvent: Codable {
    var v = 1
    var session = ""
    var seq = 0
    /// "watch" or "phone": where the observation was made.
    var origin = "watch"
    /// session, querySample, builderStatistic, workoutEvent, phoneStoreSample, phoneStoreWorkout
    var kind: String
    var type: String?
    var startOffset: Double?
    var endOffset: Double?
    /// When the observing device saw it.
    var deliveredOffset: Double?
    /// When the phone received it from the watch.
    var phoneReceivedOffset: Double?
    var value: Double?
    var sum: Double?
    var unit: String?
    var seriesCount: Int?
    var metadataKeys: [String]?
    var note: String?
    var activity: UInt?
    var location: Int?
    /// "message" or "userInfo": the WatchConnectivity path that carried it.
    var transport: String?
    var startEpoch: Double?

    init(kind: String) { self.kind = kind }
}

enum ProbeTypes {
    /// The only HealthKit types the probe asks to read. Nothing older than the session is queried.
    static let quantities: [HKQuantityTypeIdentifier] = [
        .heartRate, .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning, .stepCount,
    ]

    static func unit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .heartRate: return HKUnit.count().unitDivided(by: .minute())
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        case .distanceWalkingRunning: return .meter()
        default: return .count()
        }
    }

    static var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>(quantities.map { HKQuantityType($0) })
        s.insert(HKObjectType.workoutType())
        return s
    }

    static var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType()] }

    /// Builds the event for one quantity sample (type, offsets, value, metadata key names).
    static func event(for sample: HKQuantitySample, start: Date, kind: String, origin: String) -> ProbeEvent {
        let id = HKQuantityTypeIdentifier(rawValue: sample.quantityType.identifier)
        let unit = unit(for: id)
        var e = ProbeEvent(kind: kind)
        e.origin = origin
        e.type = sample.quantityType.identifier
        e.startOffset = sample.startDate.timeIntervalSince(start)
        e.endOffset = sample.endDate.timeIntervalSince(start)
        e.deliveredOffset = Date().timeIntervalSince(start)
        if sample.quantity.is(compatibleWith: unit) {
            e.value = sample.quantity.doubleValue(for: unit)
            e.unit = unit.unitString
        }
        e.seriesCount = sample.count
        e.metadataKeys = sample.metadata.map { Array($0.keys).sorted() } ?? []
        return e
    }
}
