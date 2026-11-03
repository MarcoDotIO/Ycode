// Samples and workouts of Ycode's health tools (health-simulation.md §8.1
// H-2, §8.3 H-9): the host's model, its validation against the type table
// (HealthTypes.swift) and its encoding for the guest agent's channel
// (HealthChannel.swift).

import Foundation

public enum HealthMetadataValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case date(Date)
    case quantity(Double, String)

    /// The channel's form: a string, a number, seconds since 1970 in a
    /// `{date}` dictionary, or `{value, unit}`.
    var plistObject: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .date(let d): d
        case .quantity(let v, let u): ["value": v, "unit": u] as [String: Any]
        }
    }
}

public struct HealthSample: Sendable, Equatable {
    public var type: String
    public var start: Date
    public var end: Date
    /// Quantities: the value in `unit`; categories: the integer value.
    public var value: Double
    public var unit: String?
    public var metadata: [String: HealthMetadataValue]

    public init(type: String, start: Date, end: Date? = nil, value: Double, unit: String? = nil, metadata: [String: HealthMetadataValue] = [:]) {
        self.type = type
        self.start = start
        self.end = end ?? start
        self.value = value
        self.unit = unit
        self.metadata = metadata
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// The channel's dictionary. Dates are seconds since 1970 as numbers: an
    /// XML property list keeps whole seconds only.
    public var plist: [String: Any] {
        var d: [String: Any] = ["type": type, "start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970]
        if let unit {
            d["value"] = value
            d["unit"] = unit
        } else {
            d["value"] = Int(value)
        }
        if !metadata.isEmpty { d["metadata"] = metadata.mapValues(\.plistObject) }
        return d
    }

    /// The value in the type's store unit (quantities with a known one).
    public func storeValue() -> Double? {
        guard let t = HealthTypes.all[type], t.kind == .quantity, let storeUnit = t.storeUnit, let unit,
              let from = try? HealthUnit(unit), let to = try? HealthUnit(storeUnit) else { return nil }
        return from.convert(value, to: to)
    }
}

public struct HealthWorkout: Sendable, Equatable {
    /// `HKWorkoutActivityType` raw value (identifiers.md).
    public var activity: Int
    public var start: Date
    public var end: Date
    public var indoor: Bool
    public var samples: [HealthSample]
    /// (latitude, longitude, time)
    public var route: [(Double, Double, Date)]
    public var metadata: [String: HealthMetadataValue]

    public init(activity: Int, start: Date, end: Date, indoor: Bool = false, samples: [HealthSample] = [],
                route: [(Double, Double, Date)] = [], metadata: [String: HealthMetadataValue] = [:]) {
        self.activity = activity
        self.start = start
        self.end = end
        self.indoor = indoor
        self.samples = samples
        self.route = route
        self.metadata = metadata
    }

    public static func == (a: HealthWorkout, b: HealthWorkout) -> Bool {
        a.activity == b.activity && a.start == b.start && a.end == b.end && a.indoor == b.indoor && a.samples == b.samples
            && a.metadata == b.metadata && a.route.count == b.route.count
            && zip(a.route, b.route).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
    }

    public var plist: [String: Any] {
        var d: [String: Any] = ["activity": activity, "start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970,
                                "indoor": indoor, "samples": samples.map(\.plist)]
        if !route.isEmpty { d["route"] = route.map { [$0.0, $0.1, $0.2.timeIntervalSince1970] } }
        if !metadata.isEmpty { d["metadata"] = metadata.mapValues(\.plistObject) }
        return d
    }

    /// Activity names (`running`, `HKWorkoutActivityTypeRunning`) → raw values (identifiers.md).
    public static let activities: [String: Int] = [
        "americanfootball": 1, "archery": 2, "badminton": 4, "baseball": 5, "basketball": 6, "bowling": 7, "boxing": 8,
        "climbing": 9, "cricket": 10, "crosstraining": 11, "cycling": 13, "elliptical": 16, "fencing": 18,
        "functionalstrengthtraining": 20, "golf": 21, "gymnastics": 22, "hiking": 24, "hockey": 25, "martialarts": 28,
        "mindandbody": 29, "paddlesports": 31, "rowing": 35, "rugby": 36, "running": 37, "sailing": 38, "skatingsports": 39,
        "snowsports": 40, "soccer": 41, "squash": 43, "stairclimbing": 44, "surfingsports": 45, "swimming": 46, "tabletennis": 47,
        "tennis": 48, "trackandfield": 49, "traditionalstrengthtraining": 50, "volleyball": 51, "walking": 52, "waterfitness": 53,
        "yoga": 57, "barre": 58, "coretraining": 59, "crosscountryskiing": 60, "downhillskiing": 61, "flexibility": 62,
        "highintensityintervaltraining": 63, "hiit": 63, "jumprope": 64, "kickboxing": 65, "pilates": 66, "snowboarding": 67,
        "stairs": 68, "steptraining": 69, "taichi": 72, "mixedcardio": 73, "handcycling": 74, "pickleball": 79, "cooldown": 80,
        "other": 3000,
    ]

    public static func activity(named name: String) -> Int? {
        if let n = Int(name) { return n }
        var key = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if key.hasPrefix("hkworkoutactivitytype") { key = String(key.dropFirst("hkworkoutactivitytype".count)) }
        return activities[key]
    }
}

// MARK: - Validation

public struct HealthValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Where (a line or entry number), and what.
    public let location: String
    public let message: String
    /// The sample's type is read-only for apps (health-simulation.md §3.2).
    public let readOnly: Bool

    public init(_ location: String, _ message: String, readOnly: Bool = false) {
        self.location = location
        self.message = message
        self.readOnly = readOnly
    }

    public var description: String { location.isEmpty ? message : "\(location): \(message)" }
}

public enum HealthValidation {
    /// What a read-only type gets at import.
    public static func readOnlyMessage(_ type: HealthType) -> String {
        "\(type.identifier) is read-only for apps: HealthKit refuses to save it (health-simulation.md §3.2), so Ycode's agent "
            + "cannot write it. Seed it into a shut-down device instead: ycode-sim --device DEV --health seed <file> (HEALTH-3)."
    }

    /// The problems of one sample (empty: valid). `seeding` accepts read-only types.
    public static func check(_ s: HealthSample, seeding: Bool = false) -> [String] {
        guard let t = HealthTypes.all[s.type] else {
            return ["unknown sample type '\(s.type)' (use a HealthKit identifier such as HKQuantityTypeIdentifierHeartRate)"]
        }
        var out: [String] = []
        if !t.writable && !seeding { return [readOnlyMessage(t)] }
        switch t.kind {
        case .quantity:
            guard let unit = s.unit else { return ["\(t.shortName): a quantity needs a unit (\(t.dimension.map { exampleUnit($0) } ?? "?"))"] }
            do {
                let u = try HealthUnit(unit)
                if let d = t.dimension, !u.fits(d) {
                    out.append("\(t.shortName): unit '\(unit)' is not a \(d.rawValue) unit (for example \(exampleUnit(d)))")
                }
            } catch {
                out.append("\(t.shortName): \(error)")
            }
            if !s.value.isFinite { out.append("\(t.shortName): the value is not a number") }
            if t.cumulative && s.value < 0 { out.append("\(t.shortName): a cumulative quantity cannot be negative") }
            if t.identifier == "HKQuantityTypeIdentifierOxygenSaturation" || t.identifier == "HKQuantityTypeIdentifierAtrialFibrillationBurden",
               unit == "%", s.value > 1 {
                out.append("\(t.shortName): percentages are fractions (0.97 for 97 %)")
            }
        case .category:
            if s.unit != nil { out.append("\(t.shortName): a category sample has no unit") }
            if s.value.rounded() != s.value { out.append("\(t.shortName): category values are integers") }
            if let allowed = t.categoryValues, !allowed.contains(Int(s.value)) {
                out.append("\(t.shortName): value \(Int(s.value)) is not one of \(allowed.map(String.init).joined(separator: ", "))")
            }
        case .workout:
            out.append("workouts go in the file's \"workouts\" list, not in \"samples\"")
        case .other:
            if !seeding { out.append("\(t.identifier) cannot be written by import") }
        }
        if s.end < s.start { out.append("\(t.shortName): end is before start") }
        if let m = t.maximumDuration, s.duration > m { out.append("\(t.shortName): longer than its maximum duration (\(Int(m)) s)") }
        if let m = t.minimumDuration, s.duration < m { out.append("\(t.shortName): shorter than its minimum duration (\(m) s)") }
        for key in t.requiredMetadata where s.metadata[key] == nil { out.append("\(t.shortName): missing the required metadata key \(key)") }
        for key in s.metadata.keys where key.isEmpty { out.append("\(t.shortName): an empty metadata key") }
        return out
    }

    public static func check(_ w: HealthWorkout) -> [String] {
        var out: [String] = []
        if w.end <= w.start { out.append("workout: end is not after start") }
        if w.end.timeIntervalSince(w.start) > 345_600 { out.append("workout: longer than 4 days") }
        for (i, s) in w.samples.enumerated() {
            out += check(s).map { "sample \(i + 1): \($0)" }
            if s.start < w.start || s.end > w.end { out.append("sample \(i + 1): outside the workout") }
        }
        for (i, p) in w.route.enumerated() where !(-90...90).contains(p.0) || !(-180...180).contains(p.1) {
            out.append("route point \(i + 1): not a coordinate")
        }
        return out
    }

    static func exampleUnit(_ d: HealthDimension) -> String {
        switch d {
        case .energy: "kcal"
        case .time: "min"
        case .scalar: "count"
        case .temperature: "degC"
        case .massConcentration: "mg/dL"
        case .pressure: "mmHg"
        case .mass: "kg"
        case .speed: "m/s"
        case .frequency: "count/min"
        case .power: "W"
        case .volume: "mL"
        case .length: "m"
        case .conductance: "mcS"
        case .soundPressureLevel: "dBASPL"
        case .effortScore: "appleEffortScore"
        case .pharmacology: "IU"
        case .volumeFlow: "L/min"
        case .energyRatePerMass: "kcal/hr·kg"
        case .vo2Rate: "mL/(kg*min)"
        }
    }
}
