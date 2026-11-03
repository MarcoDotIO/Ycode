import Foundation
import Testing
@testable import YcodeSimFeatures

/// HEALTH-1/2 (specs/simulator/health-simulation.md §3, §8.3, "Ycode
/// implementation"): the type table, units, import validation, the
/// scenario generators' statistics and the host channel's frames.
struct HealthTypeTableTests {
    @Test func tableHasTheSpecsTypes() {
        #expect(HealthTypes.quantityRows.count == 121)
        #expect(HealthTypes.categoryRows.count == 72)
        // §3.2's 26, plus the environmental audio event's identifier, which shares
        // its string value with the older audio exposure event (one type at run time).
        #expect(HealthTypes.readOnly.count == 27)
        #expect(Set(HealthTypes.categoryRows.filter { HealthTypes.readOnly.contains($0.0) }.map(\.1)).count == 14)
        // Every read-only identifier is in the table (or is ECG / the activity summary).
        for id in HealthTypes.readOnly where id != "HKActivitySummaryTypeIdentifier" { #expect(HealthTypes.all[id] != nil, "\(id)") }
        let hr = HealthTypes.all["HKQuantityTypeIdentifierHeartRate"]!
        #expect(hr.dimension == .frequency && !hr.cumulative && hr.writable && hr.storeCode == 5 && hr.storeUnit == "count/s")
        #expect(HealthTypes.all["HKQuantityTypeIdentifierStepCount"]!.cumulative)
        #expect(HealthTypes.all["HKQuantityTypeIdentifierAtrialFibrillationBurden"]!.writable == false)
        #expect(HealthTypes.all["HKCategoryTypeIdentifierSleepApneaEvent"]!.storeCode == 276)
        #expect(HealthTypes.all["HKCategoryTypeIdentifierSleepAnalysis"]!.categoryValues == [0, 1, 2, 3, 4, 5])
        #expect(HealthTypes.all["HKCategoryTypeIdentifierHeadache"]!.categoryValues == [0, 1, 2, 3, 4])
        #expect(HealthTypes.all["HKCategoryTypeIdentifierMindfulSession"]!.categoryValues == [0])
        #expect(HealthTypes.all["HKCategoryTypeIdentifierMenstrualFlow"]!.categoryValues == [1, 2, 3, 4, 5])
        #expect(HealthTypes.all["HKQuantityTypeIdentifierEnvironmentalAudioExposure"]!.minimumDuration == 0.001)
    }

    @Test func agentAsksOnlyForWritableTypes() {
        let share = HealthTypes.agentShareTypes
        #expect(share.contains("HKQuantityTypeIdentifierHeartRate") && share.contains("HKWorkoutTypeIdentifier"))
        #expect(share.contains("HKWorkoutRouteTypeIdentifier"))
        #expect(!share.contains { HealthTypes.readOnly.contains($0) })
        #expect(share.count == Set(share).count)
    }

    @Test func namesAndAliases() {
        #expect(HealthTypes.type(named: "HeartRate")?.identifier == "HKQuantityTypeIdentifierHeartRate")
        #expect(HealthTypes.type(named: "spo2")?.identifier == "HKQuantityTypeIdentifierOxygenSaturation")
        #expect(HealthTypes.type(named: "respiratory-rate")?.identifier == "HKQuantityTypeIdentifierRespiratoryRate")
        #expect(HealthTypes.type(named: "nonsense") == nil)
        let sleep = HealthTypes.all["HKCategoryTypeIdentifierSleepAnalysis"]!
        #expect(HealthTypes.categoryValue("HKCategoryValueSleepAnalysisAsleepREM", for: sleep) == 5)
        #expect(HealthTypes.categoryValue("AsleepCore", for: sleep) == 3)
        #expect(HealthTypes.categoryValue("deep", for: sleep) == 4)
        #expect(HealthTypes.categoryValue("inBed", for: sleep) == 0)
        #expect(HealthTypes.categoryValue("2", for: sleep) == 2)
    }
}

struct HealthUnitTests {
    func u(_ s: String) throws -> HealthUnit { try HealthUnit(s) }

    @Test func dimensionsAndConversions() throws {
        #expect(try u("count/min").fits(.frequency))
        #expect(try u("Hz").fits(.frequency))
        #expect(try u("kcal").fits(.energy) && u("Cal").fits(.energy) && u("kJ").fits(.energy))
        #expect(try u("%").fits(.scalar) && u("count").fits(.scalar))
        #expect(try u("mL/(kg*min)").fits(.vo2Rate) && u("mL/min·kg").fits(.vo2Rate))
        #expect(try u("kcal/hr·kg").fits(.energyRatePerMass))
        #expect(try u("mmHg").fits(.pressure) && u("mg/dL").fits(.massConcentration))
        #expect(try u("dBASPL").fits(.soundPressureLevel) && !u("dBASPL").fits(.pressure))
        #expect(try !u("kg").fits(.length))
        #expect(abs(try u("count/min").convert(60, to: u("count/s"))! - 1) < 1e-12)
        #expect(abs(try u("degF").convert(98.6, to: u("degC"))! - 37) < 1e-9)
        #expect(abs(try u("degC").convert(100, to: u("degF"))! - 212) < 1e-9)
        #expect(abs(try u("mi").convert(1, to: u("m"))! - 1609.344) < 1e-9)
        #expect(abs(try u("kcal").convert(1, to: u("kJ"))! - 4.184) < 1e-9)
        #expect(abs(try u("atm").convert(1, to: u("mmHg"))! - 760) < 1e-3)
        #expect(abs(try u("mg/dL").convert(100, to: u("mmol<180.15588000005408>/L"))! - 5.55074860726) < 1e-6)
        #expect(try u("g").convert(1, to: u("m")) == nil)
    }

    @Test func badUnits() {
        #expect(throws: HealthUnit.ParseError.self) { try HealthUnit("KG") }
        #expect(throws: HealthUnit.ParseError.self) { try HealthUnit("kg ") }
        #expect(throws: HealthUnit.ParseError.self) { try HealthUnit("ug") }
        #expect(throws: HealthUnit.ParseError.self) { try HealthUnit("") }
    }
}

struct HealthImportTests {
    let now = Date(timeIntervalSince1970: 1_793_400_000)

    @Test func jsonSamplesAndRelativeTimes() throws {
        let json = """
            {"version": 1, "device": "watch", "samples": [
              {"type": "HKQuantityTypeIdentifierHeartRate", "start": "-8h", "value": 72, "unit": "count/min",
               "metadata": {"HKMetadataKeyHeartRateMotionContext": 1}},
              {"type": "sleep", "start": "2026-10-30T01:00:00Z", "end": "2026-10-30T01:30:00Z", "value": "AsleepDeep"},
              {"type": "StepCount", "start": "now", "end": "+10m", "value": 400, "unit": "count"},
              {"type": "HKQuantityTypeIdentifierOxygenSaturation", "start": 1793390000, "value": 0.97, "unit": "%",
               "metadata": {"HKMetadataKeyBarometricPressure": {"value": 101.3, "unit": "kPa"}}}
            ],
            "workouts": [{"activity": "running", "start": "-1h", "end": "-30m", "energy_kcal": 320, "distance_m": 5000,
                          "route": [[37.77, -122.48, "-1h"], [37.771, -122.481, "-59m"]]}]}
            """
        let f = try HealthImport.read(Data(json.utf8), format: .json, now: now)
        #expect(f.device == "watch")
        #expect(f.samples.count == 4)
        #expect(f.samples[0].start == now.addingTimeInterval(-8 * 3600))
        #expect(f.samples[0].metadata["HKMetadataKeyHeartRateMotionContext"] == .number(1))
        #expect(f.samples[1].value == 4 && f.samples[1].duration == 1800)
        #expect(f.samples[2].end == now.addingTimeInterval(600))
        #expect(f.samples[3].metadata["HKMetadataKeyBarometricPressure"] == .quantity(101.3, "kPa"))
        #expect(f.workouts.count == 1 && f.workouts[0].activity == 37 && f.workouts[0].samples.count == 2 && f.workouts[0].route.count == 2)
        #expect(f.sampleCount == 6)
    }

    @Test func csvWithQuotesCommentsAndNames() throws {
        let csv = """
            # synthetic
            type,start,end,value,unit
            HKQuantityTypeIdentifierHeartRate,-30m,,72,count/min
            "HKCategoryTypeIdentifierSleepAnalysis","2026-10-30 01:00:00 -0400","2026-10-30 01:20:00 -0400",core,
            HKQuantityTypeIdentifierBodyTemperature,-3h,,98.4,degF
            """
        let f = try HealthImport.read(Data(csv.utf8), format: .csv, now: now)
        #expect(f.samples.count == 3)
        #expect(f.samples[1].value == 3 && f.samples[1].unit == nil && f.samples[1].duration == 1200)
        #expect(f.samples[2].unit == "degF")
    }

    @Test func readOnlyTypesAreRefusedWithAPointerToSeeding() throws {
        let csv = """
            type,start,end,value,unit
            HKQuantityTypeIdentifierHeartRate,-10m,,70,count/min
            HKCategoryTypeIdentifierSleepApneaEvent,-30d,-1m,0,
            HKQuantityTypeIdentifierAtrialFibrillationBurden,-7d,-1m,0.03,%
            """
        do {
            _ = try HealthImport.read(Data(csv.utf8), format: .csv, now: now)
            Issue.record("a read-only type was accepted")
        } catch let f as HealthImport.Failure {
            #expect(f.errors.count == 2)
            #expect(f.readOnlyOnly)
            #expect(f.errors[0].location == "line 3")
            #expect(f.description.contains("read-only for apps"))
            #expect(f.description.contains("health seed"))
            #expect(f.description.contains("HEALTH-3"))
        }
        // The same file for seeding: the read-only samples are kept apart.
        let s = try HealthImport.read(Data(csv.utf8), format: .csv, now: now, seeding: true)
        #expect(s.samples.count == 1 && s.readOnly.count == 2)
    }

    @Test func validationErrors() {
        func problems(_ s: HealthSample) -> [String] { HealthValidation.check(s) }
        let t = now
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierHeartRate", start: t, value: 70, unit: "kg"))
            .first?.contains("not a frequency unit") == true)
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierHeartRate", start: t, value: 70)).first?.contains("needs a unit") == true)
        #expect(problems(HealthSample(type: "HKCategoryTypeIdentifierSleepAnalysis", start: t, end: t + 60, value: 9)).first?
            .contains("not one of") == true)
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierStepCount", start: t + 10, end: t, value: 1, unit: "count"))
            .contains { $0.contains("end is before start") })
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierStepCount", start: t, end: t + 5 * 86400, value: 1, unit: "count"))
            .contains { $0.contains("maximum duration") })
        // Audio exposure needs a duration (§3.3).
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierEnvironmentalAudioExposure", start: t, value: 60, unit: "dBASPL"))
            .contains { $0.contains("minimum duration") })
        // Insulin delivery needs its reason (§3.3).
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierInsulinDelivery", start: t, value: 2, unit: "IU"))
            .contains { $0.contains("HKInsulinDeliveryReason") })
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierOxygenSaturation", start: t, value: 97, unit: "%"))
            .contains { $0.contains("fractions") })
        #expect(problems(HealthSample(type: "HKQuantityTypeIdentifierStepCount", start: t, end: t + 60, value: 40, unit: "count")).isEmpty)
    }

    @Test func unreadableFiles() {
        #expect(throws: HealthImport.Failure.self) { try HealthImport.read(Data("[1,2]".utf8), format: .json, now: now) }
        #expect(throws: HealthImport.Failure.self) { try HealthImport.read(Data("a,b\n1,2".utf8), format: .csv, now: now) }
        #expect(throws: HealthImport.Failure.self) { try HealthImport.read(Data("{\"version\":1,\"samples\":[]}".utf8), format: .json, now: now) }
        #expect(throws: HealthImport.Failure.self) {
            try HealthImport.read(Data("{\"version\":2,\"samples\":[]}".utf8), format: .json, now: now)
        }
    }

    @Test func shippedSampleFiles() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/HealthSamples").path
        let hundred = try HealthImport.read(path: dir + "/hundred-samples.json", now: now)
        #expect(hundred.samples.count == 100)
        #expect(try HealthImport.read(path: dir + "/mixed.csv", now: now).samples.count == 9)
        #expect(throws: HealthImport.Failure.self) { try HealthImport.read(path: dir + "/read-only.csv", now: now) }
    }

    @Test func durations() {
        #expect(HealthImport.duration("5s") == 5 && HealthImport.duration("10m") == 600 && HealthImport.duration("1.5h") == 5400)
        #expect(HealthImport.duration("250ms") == 0.25 && HealthImport.duration("x") == nil)
        #expect(HealthImport.relative("-2d") == -172_800 && HealthImport.relative("30m") == nil)
    }
}

struct HealthScenarioTests {
    let utc = TimeZone(identifier: "UTC")!
    var day: Date { HealthCommand.parseDay("2026-10-29", timeZone: utc)! }

    func generate(_ name: String, seed: UInt64 = 1, days: Int = 1, steps: Int? = nil) throws -> HealthScenarioOutput {
        var o = HealthScenarioOptions(date: day, timeZone: utc)
        o.seed = seed
        o.days = days
        o.steps = steps
        o.withReadOnly = true
        return try HealthScenarios.generate(name, o)
    }

    func values(_ out: [HealthSample], _ type: String) -> [Double] { out.filter { $0.type == type }.map(\.value) }
    func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
    func spacing(_ out: [HealthSample], _ type: String) -> [Double] {
        let t = out.filter { $0.type == type }.map(\.start).sorted()
        return zip(t.dropFirst(), t).map { $0.timeIntervalSince($1) }
    }

    @Test func deterministicForASeed() throws {
        let a = try generate("resting-day", seed: 42), b = try generate("resting-day", seed: 42), c = try generate("resting-day", seed: 43)
        #expect(a.samples == b.samples)
        #expect(a.samples != c.samples)
    }

    @Test func everyScenarioIsValid() throws {
        for name in HealthScenarios.writable {
            let out = try generate(name)
            #expect(out.writableCount > 0, "\(name)")
            for s in out.samples { #expect(HealthValidation.check(s).isEmpty, "\(name): \(s) \(HealthValidation.check(s))") }
            for w in out.workouts { #expect(HealthValidation.check(w).isEmpty, "\(name): \(HealthValidation.check(w))") }
            for s in out.seeded where s.type != HealthTypes.ecg { #expect(HealthValidation.check(s, seeding: true).isEmpty, "\(name) seeded \(s)") }
        }
    }

    @Test func restingDayCadenceAndRanges() throws {
        let out = try generate("resting-day")
        let gaps = spacing(out.samples, HealthScenarios.hr)
        #expect((260...340).contains(mean(gaps)), "mean HR spacing \(mean(gaps))")
        #expect(gaps.allSatisfy { (250...350).contains($0) })
        let hr = values(out.samples, HealthScenarios.hr)
        #expect((270...300).contains(hr.count))
        #expect(hr.allSatisfy { (45...100).contains($0) })
        #expect((50...85).contains(mean(hr)))
        let resting = values(out.samples, HealthScenarios.restingHR)
        #expect(resting.count == 1 && (55...80).contains(resting[0]))
        // Asleep (00:00–07:00) lower than the afternoon.
        let night = out.samples.filter { $0.type == HealthScenarios.hr && $0.start < day.addingTimeInterval(6 * 3600) }.map(\.value)
        let afternoon = out.samples.filter { $0.type == HealthScenarios.hr && $0.start >= day.addingTimeInterval(13 * 3600)
            && $0.start < day.addingTimeInterval(17 * 3600) }.map(\.value)
        #expect(mean(night) + 5 < mean(afternoon))
        #expect(values(out.samples, HealthScenarios.spo2).count == 24)
        #expect(values(out.samples, HealthScenarios.spo2).allSatisfy { (0.95...0.99).contains($0) })
        #expect(values(out.samples, HealthScenarios.hrv).allSatisfy { (20...80).contains($0) })
        let rr = values(out.samples, HealthScenarios.respiratory)
        #expect(rr.allSatisfy { (12...16).contains($0) && ($0 * 2).rounded() == $0 * 2 })
        let steps = values(out.samples, HealthScenarios.steps).reduce(0, +)
        #expect((4000...10000).contains(steps))
        let active = values(out.samples, HealthScenarios.activeEnergy).reduce(0, +)
        #expect((290...710).contains(active), "active \(active)")
    }

    @Test func workoutCadenceAndRanges() throws {
        let out = try generate("workout")
        #expect(out.workouts.count == 1)
        let w = out.workouts[0]
        #expect(w.end.timeIntervalSince(w.start) == 1800 && w.activity == 37)
        let hrGaps = spacing(w.samples, HealthScenarios.hr)
        #expect(hrGaps.allSatisfy { $0 == 5 })
        let hr = values(w.samples, HealthScenarios.hr)
        #expect(hr.count == 360)
        #expect(hr.allSatisfy { (120...165).contains($0) })
        // The plateau is reached within about 90 s.
        #expect(hr.dropFirst(24).allSatisfy { $0 >= 125 })
        #expect(spacing(w.samples, HealthScenarios.distance).allSatisfy { abs($0 - 2.56) < 1e-6 })
        let d = values(w.samples, HealthScenarios.distance)
        #expect(d.count == 703 && d.allSatisfy { (6...9.5).contains($0) })
        #expect((4800...6000).contains(d.reduce(0, +)))
        #expect(values(w.samples, HealthScenarios.steps).allSatisfy { (5...8).contains($0) })
        #expect(w.route.count == 1801)
    }

    @Test func nightSleepStageStructure() throws {
        for seed in UInt64(1)...20 {
            let out = try generate("night-sleep", seed: seed)
            let stages = out.samples.filter { $0.type == HealthScenarios.sleep && $0.value != 0 }.sorted { $0.start < $1.start }
            let inBed = out.samples.filter { $0.type == HealthScenarios.sleep && $0.value == 0 }
            #expect(inBed.count == 1)
            // Back to back, no overlaps.
            for (a, b) in zip(stages, stages.dropFirst()) { #expect(a.end == b.start) }
            #expect(stages.first?.value == 3, "the night starts with Core")
            let onset = stages.first!.start
            let firstDeep = stages.first { $0.value == 4 }!.start.timeIntervalSince(onset)
            let firstREM = stages.first { $0.value == 5 }!.start.timeIntervalSince(onset)
            #expect(firstDeep <= 3600, "Deep within the first hour (\(firstDeep))")
            #expect((3600...7200).contains(firstREM), "REM after 1–2 h (\(firstREM))")
            // Transitions.
            for (a, b) in zip(stages, stages.dropFirst()) {
                if a.value == 4 { #expect(b.value == 3 || b.value == 2) }
                if a.value == 2 { #expect(b.value == 3) }
                if a.value == 5 { #expect(b.value == 3 || b.value == 2) }
            }
            // Shares of the time asleep plus awake.
            var total: [Int: Double] = [:]
            for s in stages { total[Int(s.value), default: 0] += s.duration }
            let all = total.values.reduce(0, +)
            let share = { (v: Int) in (total[v] ?? 0) / all }
            #expect((6.5 * 3600...8.5 * 3600).contains(all), "night \(all / 3600) h")
            #expect((0.48...0.62).contains(share(3)), "core \(share(3))")
            #expect((0.12...0.24).contains(share(4)), "deep \(share(4))")
            #expect((0.18...0.28).contains(share(5)), "REM \(share(5))")
            #expect((0.03...0.10).contains(share(2)), "awake \(share(2))")
            // Deep mostly in the first third, REM mostly in the last third.
            let third = all / 3
            let deepEarly = stages.filter { $0.value == 4 && $0.start.timeIntervalSince(onset) < third }.reduce(0) { $0 + $1.duration }
            let remLate = stages.filter { $0.value == 5 && $0.start.timeIntervalSince(onset) >= 2 * third }.reduce(0) { $0 + $1.duration }
            #expect(deepEarly > (total[4] ?? 0) / 2)
            #expect(remLate > (total[5] ?? 0) / 2 - 1)
            // Awake periods are short.
            #expect(stages.filter { $0.value == 2 }.allSatisfy { $0.duration <= 8 * 60 })
            // Overnight vitals.
            let hr = values(out.samples, HealthScenarios.hr)
            #expect(hr.allSatisfy { (42...77).contains($0) })
            #expect(spacing(out.samples, HealthScenarios.spo2).allSatisfy { $0 == 1801 })
        }
    }

    @Test func spo2Dips() throws {
        let out = try generate("spo2-dips", seed: 5)
        let v = out.samples.filter { $0.type == HealthScenarios.spo2 }.sorted { $0.start < $1.start }
        #expect(v.count == 96)
        #expect(spacing(out.samples, HealthScenarios.spo2).allSatisfy { $0 == 300 })
        let low = v.filter { $0.value < 0.90 }
        #expect((3...6).contains(low.count))
        #expect(low.allSatisfy { (0.85...0.89).contains($0.value) })
        #expect(v.filter { $0.value >= 0.95 }.count >= 96 - 18)
        #expect(out.seeded.count == 1 && out.seeded[0].type == HealthScenarios.breathing && out.seeded[0].value >= 11)
    }

    @Test func stepDayHitsItsTarget() throws {
        let out = try generate("step-day", steps: 10000)
        let s = out.samples.filter { $0.type == HealthScenarios.steps }
        #expect(s.reduce(0) { $0 + $1.value } == 10000)
        #expect(s.allSatisfy { $0.duration == 3600 })
        #expect(out.samples.contains { $0.type == HealthScenarios.flights })
        #expect(out.samples.filter { $0.type == HealthScenarios.basalEnergy }.count == 24)
        let d = out.samples.filter { $0.type == HealthScenarios.distance }.reduce(0) { $0 + $1.value }
        #expect((6500...8200).contains(d))
    }

    @Test func readOnlyScenarios() throws {
        let heart = try generate("irregular-heart")
        #expect(heart.samples.isEmpty && heart.workouts.isEmpty)
        #expect(heart.seeded.filter { $0.type == HealthTypes.ecg }.map(\.value) == [1, 2, 1])
        #expect(heart.seeded.contains { $0.type == HealthScenarios.afib })
        let apnea = try generate("sleep-apnea", days: 30)
        let nights = apnea.seeded.filter { $0.type == HealthScenarios.breathing }
        #expect(nights.count == 30)
        #expect(nights.allSatisfy { $0.duration == 30_600 })
        let events = apnea.seeded.filter { $0.type == HealthScenarios.apnea }
        #expect(events.count == nights.filter { $0.value >= 11 }.count)
        #expect(events.count >= 1 && events.count < 20)
    }

    @Test func multipleDays() throws {
        let out = try generate("resting-day", days: 3)
        #expect(values(out.samples, HealthScenarios.restingHR).count == 3)
    }
}

struct HealthCommandTests {
    @Test func parsesCommands() throws {
        #expect(try HealthCommand.parse(["health", "status"]) == .status)
        #expect(try HealthCommand.parse(["import", "a.json", "--open", "dev.x"]) == .importFile(path: "a.json", open: "dev.x"))
        #expect(try HealthCommand.parse(["scenario", "night-sleep", "--date", "2026-10-29", "--seed", "7"])
            == .scenario(name: "night-sleep", date: "2026-10-29", days: 1, seed: 7, steps: nil, start: nil, withReadOnly: false))
        #expect(try HealthCommand.parse(["stream", "heart-rate", "--bpm", "80..150", "--every", "5s", "--for", "10m"])
            == .stream(kind: .heartRate, range: 80...150, every: 5, duration: 600))
        #expect(try HealthCommand.parse(["stream", "spo2", "--range=92..99"]) == .stream(kind: .spo2, range: 0.92...0.99, every: 5, duration: nil))
        #expect(try HealthCommand.parse(["grant", "dev.app"]) == .grant(bundleID: "dev.app"))
        #expect(try HealthCommand.parse(["seed", "scenario", "sleep-apnea", "--days", "30"])
            == .seedScenario(name: "sleep-apnea", date: nil, days: 30, seed: 1))
        #expect(try HealthCommand.parse(["seed", "x.csv"]) == .seedFile(path: "x.csv"))
    }

    @Test func refusesBadCommands() {
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["scenario", "sleep-apnea"]) }
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["scenario", "nope"]) }
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["import", "a.txt2"]) }
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["stream", "heart-rate", "--bpm", "150..80"]) }
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["grant", "dev.ycode.health"]) }
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["frobnicate"]) }
        #expect(throws: HealthCommand.ParseError.self) { try HealthCommand.parse(["scenario", "workout", "--bogus"]) }
        do {
            _ = try HealthCommand.parse(["scenario", "irregular-heart"])
        } catch {
            #expect("\(error)".contains("health seed scenario irregular-heart"))
        }
    }
}

struct HealthChannelTests {
    @Test func framesRoundTripWithSubSecondDates() throws {
        let t = Date(timeIntervalSince1970: 1_793_400_000.56)
        let s = HealthSample(type: "HKQuantityTypeIdentifierHeartRate", start: t, value: 72, unit: "count/min",
                             metadata: ["HKMetadataKeyHeartRateMotionContext": .number(1), "q": .quantity(101.3, "kPa")])
        let reqs = HealthChannel.writes([s])
        #expect(reqs.count == 1)
        var buffer = HealthChannel.frame(reqs[0])!
        buffer += HealthChannel.frame(HealthChannel.ping)!
        let frames = try HealthChannel.takeFrames(&buffer)
        #expect(frames.count == 2 && buffer.isEmpty)
        #expect(frames[0]["op"] as? String == "write" && frames[1]["op"] as? String == "ping")
        let sample = (frames[0]["samples"] as! [[String: Any]])[0]
        #expect((sample["start"] as! NSNumber).doubleValue == t.timeIntervalSince1970)
        #expect((sample["value"] as! NSNumber).doubleValue == 72 && sample["unit"] as? String == "count/min")
        #expect(((sample["metadata"] as! [String: Any])["q"] as! [String: Any])["unit"] as? String == "kPa")
    }

    @Test func partialFramesWait() throws {
        let f = HealthChannel.frame(HealthChannel.status(["a"]))!
        var buffer = Array(f.prefix(10))
        #expect(try HealthChannel.takeFrames(&buffer).isEmpty)
        buffer += f.dropFirst(10)
        #expect(try HealthChannel.takeFrames(&buffer).count == 1)
    }

    @Test func largeRequestsAreSplitAndFit() throws {
        let t = Date(timeIntervalSince1970: 1_793_400_000)
        let samples = (0..<2500).map { HealthSample(type: "HKQuantityTypeIdentifierHeartRate", start: t + Double($0), value: 70, unit: "count/min") }
        let reqs = HealthChannel.writes(samples)
        #expect(reqs.map { ($0["samples"] as! [Any]).count } == [1000, 1000, 500])
        for r in reqs { #expect(HealthChannel.frame(r) != nil) }
        // A whole workout scenario fits in one frame.
        var o = HealthScenarioOptions(date: t, timeZone: TimeZone(identifier: "UTC")!)
        o.seed = 3
        let w = try HealthScenarios.generate("workout", o).workouts[0]
        let frame = HealthChannel.frame(HealthChannel.workout(w))
        #expect(frame != nil && frame!.count < HealthChannel.maximumFrame)
    }

    @Test func oversizedFramesAreRefused() {
        let n = HealthChannel.maximumFrame + 1
        var buffer: [UInt8] = [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        #expect(throws: SettingsChannel.ChannelError.self) { try HealthChannel.takeFrames(&buffer) }
    }
}
