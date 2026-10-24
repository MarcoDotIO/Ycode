import Foundation

// Value-type records: the form objects take in the store and on the (future)
// client↔daemon wire. Public classes are thin immutable wrappers over them.

struct SourceRecord: Codable, Hashable, Sendable {
    var bundleIdentifier: String
    var name: String
}

struct SourceRevisionRecord: Codable, Hashable, Sendable {
    var source: SourceRecord
    var version: String?
    var productType: String?
    var osMajor: Int
    var osMinor: Int
    var osPatch: Int
}

struct DeviceRecord: Codable, Hashable, Sendable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var hardwareVersion: String?
    var firmwareVersion: String?
    var softwareVersion: String?
    var localIdentifier: String?
    var udiDeviceIdentifier: String?
}

/// A metadata value: the four value classes HealthKit accepts (`interface.md` §4),
/// with numbers kept as integer, floating point or boolean so they round-trip.
enum MetadataValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Double)
    case quantity(value: Double, unit: String)

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return Int(i)
        case .double(let d): return d
        case .bool(let b): return b
        case .date(let t): return Date(t: t)
        case .quantity(let v, let u): return HKQuantity(unit: HKUnit(from: u), doubleValue: v)
        }
    }

    var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var className: String {
        switch self {
        case .string: return "NSString"
        case .int, .double, .bool: return "NSNumber"
        case .date: return "NSDate"
        case .quantity: return "HKQuantity"
        }
    }

    /// Classify an app-supplied value; nil when its class is not allowed.
    static func from(_ value: Any) -> MetadataValue? {
        let t = type(of: value)
        if t == Bool.self { return .bool(value as! Bool) }
        if t == Int.self { return .int(Int64(value as! Int)) }
        if t == Int64.self { return .int(value as! Int64) }
        if t == Int32.self { return .int(Int64(value as! Int32)) }
        if t == Int16.self { return .int(Int64(value as! Int16)) }
        if t == Int8.self { return .int(Int64(value as! Int8)) }
        if t == UInt.self { return .int(Int64(value as! UInt)) }
        if t == UInt32.self { return .int(Int64(value as! UInt32)) }
        if t == Double.self { return .double(value as! Double) }
        if t == Float.self { return .double(Double(value as! Float)) }
        if let q = value as? HKQuantity { return .quantity(value: q.value, unit: q.unit.unitString) }
        if let d = value as? Date { return .date(d.t) }
        if let s = value as? String { return .string(s) }
        if let n = value as? NSNumber {
            #if canImport(ObjectiveC)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            #endif
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 9.0e15, d == Double(n.int64Value) { return .int(n.int64Value) }
            return .double(d)
        }
        return nil
    }
}

enum RecordKind: Int, Codable, Sendable {
    case quantity = 1, category = 2, correlation = 3, workout = 4
}

struct WorkoutEventRecord: Codable, Hashable, Sendable {
    var type: Int
    var start: Double
    var end: Double
    var metadata: [String: MetadataValue]?
}

struct QuantityValueRecord: Codable, Hashable, Sendable {
    var value: Double
    var unit: String
    var quantity: HKQuantity { HKQuantity(unit: HKUnit(from: unit), doubleValue: value) }
    init(value: Double, unit: String) { self.value = value; self.unit = unit }
    init(_ q: HKQuantity) { value = q.value; unit = q.unit.unitString }
}

struct WorkoutRecord: Codable, Hashable, Sendable {
    var activityType: Int
    var duration: Double
    var events: [WorkoutEventRecord]
    var totalEnergyBurned: QuantityValueRecord?
    var totalDistance: QuantityValueRecord?
    var totalSwimmingStrokeCount: QuantityValueRecord?
    var totalFlightsClimbed: QuantityValueRecord?
}

/// One stored object (sample).
struct ObjectRecord: Codable, Hashable, Sendable {
    var uuid: UUID
    var kind: RecordKind
    var type: String
    var start: Double
    var end: Double
    /// Assigned by the store when saved.
    var revision: SourceRevisionRecord?
    var device: DeviceRecord?
    var metadata: [String: MetadataValue]?

    // quantity samples
    var value: Double = 0          // in `unit`
    var unit: String = ""
    var ref: Double = 0            // in the reference unit of the type's dimension
    var count: Int = 1
    // category samples
    var categoryValue: Int = 0
    // correlations
    var members: [ObjectRecord]?
    // workouts
    var workout: WorkoutRecord?

    // assigned by the store
    var anchor: Int64 = 0
    var correlationParent: UUID?
    var workoutParent: UUID?

    var duration: Double { end - start }
    var sourceBundle: String { revision?.source.bundleIdentifier ?? "" }

    var syncIdentifier: String? {
        if case .string(let s)? = metadata?[HKMetadataKeySyncIdentifier] { return s }
        return nil
    }
    var syncVersion: Double? { metadata?[HKMetadataKeySyncVersion]?.number }

    /// Every record in this object (itself plus correlation members).
    var flattened: [ObjectRecord] { [self] + (members ?? []).flatMap(\.flattened) }
}

/// A deletion record (`queries.md` §4): UUID, the deleted object's metadata.
struct TombstoneRecord: Codable, Hashable, Sendable {
    var anchor: Int64
    var uuid: UUID
    var type: String
    var sourceBundle: String
    var metadata: [String: MetadataValue]?
}
