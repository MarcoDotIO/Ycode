// Ycode's health scenarios (health-simulation.md §8.3 H-8): deterministic
// synthetic data for a seed. Every value comes from published adult
// population norms (resting heart rate 55–80 bpm, sleeping heart rate
// 5–10 bpm below it, moderate workout 110–150 bpm, HRV SDNN 20–80 ms
// log-normal, SpO₂ 95–99 %, respiratory rate 12–20 per minute in half
// steps, 4 000–10 000 steps a day, active energy 300–700 kcal a day, sleep
// 6.5–8 h in about 90-minute cycles with Core 50–60 %, Deep 13–23 %, REM
// 20–25 % and Awake 5–10 % of the time in bed). Cadences and the structure
// of a night (Core first, Deep early, REM late, short Awake periods,
// back-to-back stage segments) are the structural facts of a health export
// that the spec's companion note records; no person's data is used.
//
// A scenario gives samples (and workouts) the guest agent writes, and, for
// the read-only scenarios, samples that only `health seed` can put into a
// shut-down device (HEALTH-3).

import Foundation

/// SplitMix64: a small deterministic generator (same seed, same data).
public struct HealthRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func uniform(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    public mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.upperBound - r.lowerBound + 1)) }
    /// Standard normal (Box–Muller).
    public mutating func normal() -> Double {
        let u = max(unit(), 1e-12), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

public struct HealthScenarioOptions: Sendable {
    /// The day the scenario describes (its local midnight is used).
    public var date: Date
    public var days: Int = 1
    public var seed: UInt64 = 1
    public var steps: Int?
    public var timeZone: TimeZone
    /// Workouts: the start time (default 07:30 local on `date`).
    public var start: Date?
    /// Read-only companions (breathing disturbances with `spo2-dips`).
    public var withReadOnly = false

    public init(date: Date, timeZone: TimeZone = .current) {
        self.date = date
        self.timeZone = timeZone
    }
}

public struct HealthScenarioOutput: Sendable {
    public var samples: [HealthSample] = []
    public var workouts: [HealthWorkout] = []
    /// Read-only types: written only by `health seed` into a shut-down device.
    public var seeded: [HealthSample] = []

    public var writableCount: Int { samples.count + workouts.reduce(0) { $0 + $1.samples.count } }

    /// Count per type identifier (samples, workout samples and seeded samples).
    public var counts: [String: Int] {
        var c: [String: Int] = [:]
        for s in samples + workouts.flatMap(\.samples) + seeded { c[s.type, default: 0] += 1 }
        if !workouts.isEmpty { c[HealthTypes.workout] = workouts.count }
        return c
    }

    mutating func append(_ o: HealthScenarioOutput) {
        samples += o.samples
        workouts += o.workouts
        seeded += o.seeded
    }
}

public enum HealthScenarios {
    public static let writable = ["resting-day", "workout", "night-sleep", "spo2-dips", "step-day"]
    public static let readOnly = ["irregular-heart", "sleep-apnea"]
    public static var all: [String] { writable + readOnly }

    public static let hr = "HKQuantityTypeIdentifierHeartRate"
    public static let restingHR = "HKQuantityTypeIdentifierRestingHeartRate"
    public static let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    public static let spo2 = "HKQuantityTypeIdentifierOxygenSaturation"
    public static let respiratory = "HKQuantityTypeIdentifierRespiratoryRate"
    public static let steps = "HKQuantityTypeIdentifierStepCount"
    public static let distance = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    public static let activeEnergy = "HKQuantityTypeIdentifierActiveEnergyBurned"
    public static let basalEnergy = "HKQuantityTypeIdentifierBasalEnergyBurned"
    public static let flights = "HKQuantityTypeIdentifierFlightsClimbed"
    public static let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    public static let breathing = "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances"
    public static let apnea = "HKCategoryTypeIdentifierSleepApneaEvent"
    public static let afib = "HKQuantityTypeIdentifierAtrialFibrillationBurden"
    public static let irregular = "HKCategoryTypeIdentifierIrregularHeartRhythmEvent"
    public static let wristTemperature = "HKQuantityTypeIdentifierAppleSleepingWristTemperature"

    // Metadata (identifiers.md string values).
    static let motionContext = "HKMetadataKeyHeartRateMotionContext"
    static let timeZoneKey = "HKTimeZone"
    static let indoorKey = "HKIndoorWorkout"
    static let barometric = "HKMetadataKeyBarometricPressure"

    public enum ScenarioError: Error, CustomStringConvertible {
        case unknown(String)
        public var description: String {
            switch self {
            case .unknown(let n): "unknown scenario '\(n)' (scenarios: \(HealthScenarios.all.joined(separator: ", ")))"
            }
        }
    }

    /// One person's stable offsets inside the population ranges (from the seed).
    public struct Profile: Sendable {
        public let restingHR: Double      // 55…80
        public let hrvMedian: Double      // 30…55 ms
        public let respiratory: Double    // 13…17 per minute
        public let spo2: Double           // 0.96…0.98
        public let dailySteps: Int        // 4 000…10 000
        public let activeKcal: Double     // 300…700
        public let basalKcal: Double      // 1 400…1 800 a day
        public let stride: Double         // 0.68…0.80 m
        public let workoutHR: Double      // 135…148 bpm plateau

        public init(seed: UInt64) {
            var r = HealthRandom(seed: seed ^ 0x5EED)
            restingHR = r.uniform(55...80).rounded()
            hrvMedian = r.uniform(30...55)
            respiratory = r.uniform(13...17)
            spo2 = r.uniform(0.96...0.98)
            dailySteps = r.int(4000...10000)
            activeKcal = r.uniform(300...700)
            basalKcal = r.uniform(1400...1800)
            stride = r.uniform(0.68...0.80)
            workoutHR = r.uniform(135...148)
        }
    }

    public static func generate(_ name: String, _ o: HealthScenarioOptions) throws -> HealthScenarioOutput {
        guard all.contains(name) else { throw ScenarioError.unknown(name) }
        var out = HealthScenarioOutput()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = o.timeZone
        let first = cal.startOfDay(for: o.date)
        for day in 0..<max(1, o.days) {
            let midnight = cal.date(byAdding: .day, value: day, to: first)!
            // Each day its own stream, from the seed and the day.
            var r = HealthRandom(seed: o.seed &* 1_000_003 &+ UInt64(day))
            let p = Profile(seed: o.seed)
            let tz = o.timeZone.identifier
            switch name {
            case "resting-day": out.append(restingDay(midnight, p, &r, tz))
            case "workout":
                let start = day == 0 ? (o.start ?? midnight.addingTimeInterval(7.5 * 3600)) : midnight.addingTimeInterval(7.5 * 3600)
                out.append(workout(start, p, &r, tz))
            case "night-sleep": out.append(nightSleep(midnight.addingTimeInterval(23 * 3600), p, &r, tz))
            case "spo2-dips": out.append(spo2Dips(midnight.addingTimeInterval(23 * 3600), p, &r, tz, readOnly: o.withReadOnly))
            case "step-day": out.append(stepDay(midnight, p, &r, target: o.steps ?? p.dailySteps))
            case "irregular-heart": out.append(irregularHeart(midnight, p, &r))
            case "sleep-apnea": out.append(sleepApnea(midnight.addingTimeInterval(23 * 3600), p, &r, day: day, tz))
            default: break
            }
        }
        return out
    }

    static func q(_ type: String, _ start: Date, _ end: Date? = nil, _ value: Double, _ unit: String,
                  _ metadata: [String: HealthMetadataValue] = [:]) -> HealthSample {
        HealthSample(type: type, start: start, end: end ?? start, value: value, unit: unit, metadata: metadata)
    }

    static func round(_ v: Double, _ step: Double) -> Double { (v / step).rounded() * step }

    /// Hours 0–24 that are asleep in a default day (23:00–07:00).
    static func asleep(_ hour: Double) -> Bool { hour < 7 || hour >= 23 }

    // MARK: resting-day

    /// 24 h from local midnight: heart rate about every 5 min (a daytime
    /// curve, lower asleep), one resting heart rate, HRV every ~2 h, SpO₂
    /// hourly, respiratory rate every ~10 min while asleep, steps and active
    /// energy in 10-minute windows while awake, basal energy hourly.
    static func restingDay(_ midnight: Date, _ p: Profile, _ r: inout HealthRandom, _ tz: String) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        var t = 0.0
        while t < 86400 {
            let hour = t / 3600
            let sleeping = asleep(hour)
            // A daytime bump (peak mid-afternoon), 5–10 bpm lower asleep.
            let curve = sleeping ? -7 - 2 * sin(.pi * min(1, max(0, (hour < 12 ? hour + 1 : hour - 23)) / 8))
                : 8 * sin(.pi * (hour - 7) / 16)
            let bpm = min(100, max(45, (p.restingHR + curve + 3 * r.normal()).rounded()))
            out.samples.append(q(hr, midnight.addingTimeInterval(t), nil, bpm, "count/min", [motionContext: .number(1)]))
            t += 300 + r.uniform(-45...45)
        }
        out.samples.append(q(restingHR, midnight, midnight.addingTimeInterval(86399), p.restingHR, "count/min"))
        var h = 1.0 + r.uniform(0...0.5)
        while h < 24 {
            let ms = min(80, max(20, p.hrvMedian * exp(0.25 * r.normal()) * (asleep(h) ? 1.15 : 1)))
            let at = midnight.addingTimeInterval(h * 3600)
            out.samples.append(q(hrv, at, at.addingTimeInterval(60), (ms * 1000).rounded() / 1000, "ms"))
            h += 2 + r.uniform(-0.33...0.33)
        }
        for hour in 0..<24 {
            let at = midnight.addingTimeInterval(Double(hour) * 3600 + r.uniform(0...600))
            let v = min(0.99, max(0.95, round(p.spo2 + 0.008 * r.normal(), 0.01)))
            out.samples.append(q(spo2, at, nil, v, "%", [barometric: .quantity(round(101.3 + 0.3 * r.normal(), 0.1), "kPa")]))
        }
        for slot in stride(from: 0.0, to: 86400, by: 600) where asleep(slot / 3600) {
            let at = midnight.addingTimeInterval(slot + r.uniform(-180...180).clamped(to: -slot...(86399 - slot)))
            out.samples.append(q(respiratory, at, nil, min(16, max(12, round(p.respiratory + 0.8 * r.normal(), 0.5))), "count/min"))
        }
        out.append(activity(midnight, p, &r, target: p.dailySteps, flightsToo: false))
        return out
    }

    /// Steps, distance and active energy in 10-minute windows while awake
    /// (07:00–23:00; weights peak at commute and lunch), basal energy hourly.
    static func activity(_ midnight: Date, _ p: Profile, _ r: inout HealthRandom, target: Int, flightsToo: Bool) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        var slots: [(Double, Double)] = []   // (start s, weight)
        for slot in stride(from: 7.0 * 3600, to: 23.0 * 3600, by: 600) {
            let h = slot / 3600
            var w = 0.4 + r.unit()
            if (8...9).contains(h) || (12...13).contains(h) || (17...18.5).contains(h) { w *= 3 }
            if r.unit() < 0.25 { w *= 0.1 }   // sitting still
            slots.append((slot, w))
        }
        let total = slots.reduce(0) { $0 + $1.1 }
        var left = target
        let kcalPerStep = p.activeKcal / Double(max(1, p.dailySteps))
        for (i, (slot, w)) in slots.enumerated() {
            let n = i == slots.count - 1 ? left : min(left, Int((Double(target) * w / total).rounded()))
            left -= n
            guard n > 0 else { continue }
            let start = midnight.addingTimeInterval(slot), end = start.addingTimeInterval(600)
            out.samples.append(q(steps, start, end, Double(n), "count"))
            out.samples.append(q(distance, start, end, (Double(n) * p.stride * 10).rounded() / 10, "m"))
            out.samples.append(q(activeEnergy, start, end, (Double(n) * kcalPerStep * 100).rounded() / 100, "kcal"))
        }
        for hour in 0..<24 {
            let start = midnight.addingTimeInterval(Double(hour) * 3600)
            out.samples.append(q(basalEnergy, start, start.addingTimeInterval(3600), (p.basalKcal / 24 * 100).rounded() / 100, "kcal"))
        }
        if flightsToo {
            var flightsLeft = r.int(6...14)
            while flightsLeft > 0 {
                let n = min(flightsLeft, r.int(1...3))
                flightsLeft -= n
                let start = midnight.addingTimeInterval(r.uniform(7.5 * 3600...21.5 * 3600))
                out.samples.append(q(flights, start, start.addingTimeInterval(Double(n) * 20), Double(n), "count"))
            }
        }
        return out
    }

    // MARK: step-day

    static func stepDay(_ midnight: Date, _ p: Profile, _ r: inout HealthRandom, target: Int) -> HealthScenarioOutput {
        // Hourly blocks summing to the target.
        var out = HealthScenarioOutput()
        let fine = activity(midnight, p, &r, target: target, flightsToo: true)
        var hourly: [String: [Int: Double]] = [:]
        for s in fine.samples where s.type == steps || s.type == distance || s.type == activeEnergy {
            let h = Int(s.start.timeIntervalSince(midnight) / 3600)
            hourly[s.type, default: [:]][h, default: 0] += s.value
        }
        for type in [steps, distance, activeEnergy] {
            let unit = type == steps ? "count" : type == distance ? "m" : "kcal"
            for (h, v) in (hourly[type] ?? [:]).sorted(by: { $0.key < $1.key }) where v > 0 {
                let start = midnight.addingTimeInterval(Double(h) * 3600)
                out.samples.append(q(type, start, start.addingTimeInterval(3600), type == steps ? v : (v * 10).rounded() / 10, unit))
            }
        }
        out.samples += fine.samples.filter { $0.type == basalEnergy || $0.type == flights }
        return out
    }

    // MARK: workout

    /// A 30-minute outdoor run: the workout, its route (a point a second on
    /// a loop), heart rate every 5 s (a ramp from resting to the plateau in
    /// about 90 s, then a slow wander, 120–165 bpm), and energy, distance and
    /// steps every 2.56 s.
    static func workout(_ start: Date, _ p: Profile, _ r: inout HealthRandom, _ tz: String) -> HealthScenarioOutput {
        let duration = 1800.0
        let end = start.addingTimeInterval(duration)
        var w = HealthWorkout(activity: 37, start: start, end: end, indoor: false,
                              metadata: [indoorKey: .number(0), timeZoneKey: .string(tz)])
        var wander = 0.0
        var t = 0.0
        while t <= duration - 1 {
            let ramp = min(1, t / 90)
            wander = 0.9 * wander + 0.1 * 4 * r.normal()
            let target = p.workoutHR * (1 + 0.04 * sin(t / 300)) + wander
            let bpm = min(165, max(120, (p.restingHR + 25 + (target - p.restingHR - 25) * ramp).rounded()))
            w.samples.append(q(hr, start.addingTimeInterval(t), nil, bpm, "count/min", [motionContext: .number(2)]))
            t += 5
        }
        let step = 2.56
        var at = 0.0
        while at + step <= duration {
            let s = start.addingTimeInterval(at), e = s.addingTimeInterval(step)
            let speed = 3.0 + 0.15 * r.normal()                       // m/s
            w.samples.append(q(distance, s, e, (speed * step * 100).rounded() / 100, "m"))
            w.samples.append(q(steps, s, e, Double(min(8, max(5, Int((2.75 * step + 0.5 * r.normal()).rounded())))), "count"))
            w.samples.append(q(activeEnergy, s, e, (max(0.2, 0.47 + 0.05 * r.normal()) * 1000).rounded() / 1000, "kcal"))
            w.samples.append(q(basalEnergy, s, e, 0.033, "kcal"))
            at += step
        }
        // A loop of about 1 km around a fixed point (a city park), one point a second.
        let center = (37.7694, -122.4862), radius = 160.0
        for sec in stride(from: 0, through: Int(duration), by: 1) {
            let angle = Double(sec) * 3.0 / radius
            let lat = center.0 + radius * cos(angle) / 111_320
            let lon = center.1 + radius * sin(angle) / (111_320 * cos(center.0 * .pi / 180))
            w.route.append(((lat * 1e6).rounded() / 1e6, (lon * 1e6).rounded() / 1e6, start.addingTimeInterval(Double(sec))))
        }
        var out = HealthScenarioOutput()
        out.workouts = [w]
        return out
    }

    // MARK: night-sleep

    /// Sleep stages as back-to-back segments from `bedtime` (23:00 local):
    /// an in-bed sample from 10 min before to the final wake, then 4–6
    /// cycles of about 90 min: Core first, Deep early (mostly in the first
    /// third), REM late (first after 60–120 min, mostly in the last third),
    /// short Awake periods between cycles and inside Core. Plus overnight
    /// heart rate (resting − 5…10, lowest in the second half), respiratory
    /// rate every 5–15 min, SpO₂ every 30 min and HRV every ~2 h.
    static func nightSleep(_ bedtime: Date, _ p: Profile, _ r: inout HealthRandom, _ tz: String) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        let segments = sleepStages(bedtime.addingTimeInterval(r.uniform(300...900)), &r)
        let meta: [String: HealthMetadataValue] = [timeZoneKey: .string(tz)]
        let wake = segments.last!.1
        out.samples.append(HealthSample(type: sleep, start: bedtime.addingTimeInterval(-600), end: wake.addingTimeInterval(300),
                                        value: 0, metadata: meta))
        for (s, e, v) in segments { out.samples.append(HealthSample(type: sleep, start: s, end: e, value: Double(v), metadata: meta)) }
        out.append(overnightVitals(bedtime, wake, p, &r, spo2Every: 1801))
        return out
    }

    /// (start, end, stage value) segments; values 2 awake, 3 core, 4 deep, 5 REM.
    public static func sleepStages(_ onset: Date, _ r: inout HealthRandom) -> [(Date, Date, Int)] {
        let cycles = 5   // cycles of 85–100 min: 7–8.3 h
        let deepShare = [0.38, 0.26, 0.12, 0.05, 0.03, 0.02]
        let remShare = [0.12, 0.20, 0.27, 0.33, 0.38, 0.40]
        var out: [(Date, Date, Int)] = []
        var t = onset
        func add(_ v: Int, _ minutes: Double) {
            let len = max(0.5, minutes) * 60
            let s = t
            t = t.addingTimeInterval(len.rounded())
            if let last = out.last, last.2 == v { out[out.count - 1].1 = t } else { out.append((s, t, v)) }
        }
        for k in 0..<cycles {
            let length = r.uniform(85...100)
            let deep = length * deepShare[k], rem = length * remShare[k]
            let core = length - deep - rem
            let firstCore = k == 0 ? max(15, core * 0.45) : core * 0.35
            add(3, firstCore)
            if deep >= 2 { add(4, deep) }
            // Core between Deep and REM, sometimes broken by a brief awakening.
            let secondCore = core - firstCore
            if r.unit() < 0.35 && secondCore > 8 {
                add(3, secondCore / 2)
                add(2, r.uniform(0.5...2))
                add(3, secondCore / 2)
            } else {
                add(3, secondCore)
            }
            add(5, rem)
            // Between cycles a short Awake (mostly under 5 min); the last one ends the night.
            add(2, k == cycles - 1 ? r.uniform(4...8) : r.uniform(2.5...6.5))
        }
        return out
    }

    static func overnightVitals(_ bedtime: Date, _ wake: Date, _ p: Profile, _ r: inout HealthRandom, spo2Every: Double) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        let night = wake.timeIntervalSince(bedtime)
        var t = 0.0
        while t < night {
            // Lowest in the second half of the night.
            let depth = 5 + 5 * sin(.pi * min(1, t / night * 1.3))
            let bpm = min(p.restingHR - 3, max(42, (p.restingHR - depth + 1.5 * r.normal()).rounded()))
            out.samples.append(q(hr, bedtime.addingTimeInterval(t), nil, bpm, "count/min", [motionContext: .number(1)]))
            t += 300 + r.uniform(-60...60)
        }
        t = r.uniform(120...600)
        while t < night {
            out.samples.append(q(respiratory, bedtime.addingTimeInterval(t), nil,
                                 min(20, max(12, round(p.respiratory - 0.5 + 0.8 * r.normal(), 0.5))), "count/min"))
            t += r.uniform(300...900)
        }
        t = spo2Every / 2
        while t < night {
            out.samples.append(q(spo2, bedtime.addingTimeInterval(t), nil, min(0.99, max(0.95, round(p.spo2 + 0.007 * r.normal(), 0.01))), "%",
                                 [barometric: .quantity(101.3, "kPa")]))
            t += spo2Every
        }
        t = 3600 + r.uniform(0...1200)
        while t < night {
            let at = bedtime.addingTimeInterval(t)
            out.samples.append(q(hrv, at, at.addingTimeInterval(60), (min(80, max(20, p.hrvMedian * 1.15 * exp(0.2 * r.normal()))) * 1000).rounded() / 1000, "ms"))
            t += 7200 + r.uniform(-900...900)
        }
        return out
    }

    // MARK: spo2-dips

    /// A night (23:00–07:00) of SpO₂ every 5 min at 95–99 % with 3–6 dips
    /// to 85–89 % (each a few samples down and back), respiratory rate, and
    /// with `withReadOnly` the night's breathing-disturbances value
    /// (elevated) for `health seed`.
    static func spo2Dips(_ bedtime: Date, _ p: Profile, _ r: inout HealthRandom, _ tz: String, readOnly: Bool) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        let night = 8.0 * 3600
        let n = Int(night / 300)
        var dipStarts = Set<Int>()
        let dips = r.int(3...6)
        while dipStarts.count < dips {
            let i = r.int(6...(n - 8))
            if !dipStarts.contains(where: { abs($0 - i) < 8 }) { dipStarts.insert(i) }
        }
        var dipLeft = 0, bottom = 0.0
        for i in 0..<n {
            var v = min(0.99, max(0.95, round(p.spo2 + 0.007 * r.normal(), 0.01)))
            if dipStarts.contains(i) { dipLeft = 3; bottom = round(r.uniform(0.85...0.89), 0.01) }
            if dipLeft > 0 {
                v = dipLeft == 2 ? bottom : min(0.94, max(0.90, round((bottom + 0.95) / 2, 0.01)))
                dipLeft -= 1
            }
            out.samples.append(q(spo2, bedtime.addingTimeInterval(Double(i) * 300), nil, v, "%", [barometric: .quantity(101.3, "kPa")]))
        }
        var t = r.uniform(120...600)
        while t < night {
            out.samples.append(q(respiratory, bedtime.addingTimeInterval(t), nil, min(20, max(12, round(p.respiratory + 0.8 * r.normal(), 0.5))), "count/min"))
            t += r.uniform(300...900)
        }
        if readOnly {
            out.seeded.append(q(breathing, bedtime, bedtime.addingTimeInterval(night), (r.uniform(11...20)).rounded(), "count"))
        }
        return out
    }

    // MARK: Read-only scenarios (health seed, HEALTH-3)

    /// AFib burden (a weekly value), one irregular-rhythm event and ECG
    /// classifications: sinus rhythm and atrial fibrillation, average heart
    /// rate 60–100 bpm (no waveform: health-simulation.md H-14).
    static func irregularHeart(_ midnight: Date, _ p: Profile, _ r: inout HealthRandom) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        let weekStart = midnight.addingTimeInterval(-6 * 86400)
        out.seeded.append(q(afib, weekStart, midnight.addingTimeInterval(86400 - 1), round(r.uniform(0.02...0.08), 0.01), "%"))
        let ev = midnight.addingTimeInterval(r.uniform(2 * 3600...5 * 3600))
        out.seeded.append(HealthSample(type: irregular, start: ev, end: ev.addingTimeInterval(r.uniform(1800...5400).rounded()), value: 0))
        for (hour, classification) in [(9.0, 1), (14.0, 2), (19.0, 1)] {
            let s = midnight.addingTimeInterval(hour * 3600 + r.uniform(0...1800))
            let bpm = (classification == 2 ? r.uniform(85...100) : r.uniform(62...80)).rounded()
            out.seeded.append(HealthSample(type: HealthTypes.ecg, start: s, end: s.addingTimeInterval(30), value: Double(classification),
                                           unit: nil, metadata: ["averageHeartRate": .number(bpm), "symptomsStatus": .number(1)]))
        }
        return out
    }

    /// For each night: breathing disturbances (8.5 h window; elevated, ≥ 11,
    /// on about one night in four, else 2–9), and on elevated nights a sleep
    /// apnea event (a 30-day notification window ending that morning).
    static func sleepApnea(_ bedtime: Date, _ p: Profile, _ r: inout HealthRandom, day: Int, _ tz: String) -> HealthScenarioOutput {
        var out = HealthScenarioOutput()
        let elevated = r.unit() < 0.25 || day == 0
        let value = elevated ? r.uniform(11...20).rounded() : r.uniform(2...9).rounded()
        out.seeded.append(q(breathing, bedtime, bedtime.addingTimeInterval(30_600), value, "count"))
        if elevated {
            let morning = bedtime.addingTimeInterval(8 * 3600)
            out.seeded.append(HealthSample(type: apnea, start: morning.addingTimeInterval(-30 * 86400 + 1), end: morning, value: 0))
        }
        return out
    }

    // MARK: Streams

    /// The next value of a live stream: a slow random walk inside `range`.
    public static func streamValue(previous: Double?, range: ClosedRange<Double>, _ r: inout HealthRandom) -> Double {
        let mid = (range.lowerBound + range.upperBound) / 2
        let span = range.upperBound - range.lowerBound
        let base = previous ?? mid
        let v = base + 0.08 * span * r.normal() + 0.1 * (mid - base)
        return min(range.upperBound, max(range.lowerBound, v))
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(r.upperBound, Swift.max(r.lowerBound, self)) }
}
