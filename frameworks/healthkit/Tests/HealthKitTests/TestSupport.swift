import Foundation
import Testing
@testable import HealthKit

// Shared fixtures for the conformance tests. All data is made up (`plan.md` §3.1
// describes the synthetic data set the reference was measured with).

enum T {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// D0 = 2026-10-01T00:00:00Z
    static let d0: Date = utc.date(from: DateComponents(year: 2026, month: 10, day: 1))!
    /// Date relative to D0 (day offset, hour, minute, second), UTC.
    static func at(_ day: Int = 0, _ h: Int = 0, _ m: Int = 0, _ s: Int = 0) -> Date {
        d0.addingTimeInterval(Double(day * 86400 + h * 3600 + m * 60 + s))
    }
    /// A was granted "Past 30 Days and Future Data" at 2026-10-19 23:55:40Z (`plan.md` §3.2).
    static let grantA: Date = utc.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 55, second: 40))!
    static let clientA = YcodeHealthClient(bundleIdentifier: "dev.ycode.healthprobe", name: "HealthProbe", version: "7")
    static let clientB = YcodeHealthClient(bundleIdentifier: "dev.ycode.healthprobe.b", name: "HealthProbe B", version: "7")

    static func q(_ id: HKQuantityTypeIdentifier) -> HKQuantityType { HKQuantityType(id) }
    static func c(_ id: HKCategoryTypeIdentifier) -> HKCategoryType { HKCategoryType(id) }

    static var steps: HKQuantityType { q(.stepCount) }
    static var heartRate: HKQuantityType { q(.heartRate) }
    static var bodyMass: HKQuantityType { q(.bodyMass) }
    static var bodyTemperature: HKQuantityType { q(.bodyTemperature) }
    static var sleep: HKCategoryType { c(.sleepAnalysis) }
    static var mindful: HKCategoryType { c(.mindfulSession) }
    static var systolic: HKQuantityType { q(.bloodPressureSystolic) }
    static var diastolic: HKQuantityType { q(.bloodPressureDiastolic) }
    static var energy: HKQuantityType { q(.activeEnergyBurned) }
    static var distance: HKQuantityType { q(.distanceWalkingRunning) }
    static var bloodPressure: HKCorrelationType { HKCorrelationType(.bloodPressure) }

    static let count = HKUnit.count()
    static let bpm = HKUnit(from: "count/min")

    static func qs(_ type: HKQuantityType, _ value: Double, _ unit: HKUnit, _ s: Date, _ e: Date? = nil,
                   _ md: [String: Any]? = nil) -> HKQuantitySample {
        HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: s, end: e ?? s, metadata: md)
    }
    static func stepSample(_ v: Double, _ s: Date, _ e: Date, _ md: [String: Any]? = nil) -> HKQuantitySample {
        qs(steps, v, count, s, e, md)
    }

    static var allShare: Set<HKSampleType> {
        [steps, heartRate, bodyMass, bodyTemperature, sleep, mindful, systolic, diastolic, energy, distance,
         HKObjectType.workoutType()]
    }
    static var allRead: Set<HKObjectType> {
        Set(allShare.map { $0 as HKObjectType }).union([
            HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex), HKCharacteristicType(.bloodType),
            HKCharacteristicType(.fitzpatrickSkinType), HKCharacteristicType(.wheelchairUse),
            HKCharacteristicType(.activityMoveMode),
        ])
    }

    static func daemon() throws -> YcodeHealthDaemon { try YcodeHealthDaemon(databaseURL: nil) }

    /// A temporary on-disk store location (removed by the caller).
    static func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-healthkit-tests-\(UUID().uuidString)/healthdb.sqlite")
    }
}

// MARK: - async helpers over the callback API

extension HKHealthStore {
    /// Request authorization, answering the consent with `answer` (Select All by default).
    func grant(share: Set<HKSampleType> = T.allShare, read: Set<HKObjectType> = T.allRead,
               range: YcodeHistoricalRange = .allRecordedData, at date: Date? = nil,
               readOff: Set<String> = []) async throws {
        daemon.setConsentResponder { req in
            var a = YcodeConsentAnswer.allowAll(req, historicalRange: range, date: date)
            a.read.subtract(readOff)
            return a
        }
        try await requestAuthorization(toShare: share, read: read)
    }

    func run<Q: HKQuery>(_ make: (@escaping @Sendable () -> Void) -> Q) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let q = make { k.resume() }
            execute(q)
        }
    }

    func samples(_ type: HKSampleType, _ predicate: NSPredicate? = nil, limit: Int = HKObjectQueryNoLimit,
                 sort: [NSSortDescriptor]? = nil) async throws -> [HKSample] {
        let box = Locked<Result<[HKSample], any Error>>(.success([]))
        await run { done in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sort) { _, s, e in
                box.withLock { $0 = e.map { .failure($0) } ?? .success(s ?? []) }
                done()
            }
        }
        return try box.current.get()
    }

    func count(_ type: HKSampleType, _ predicate: NSPredicate? = nil) async throws -> Int {
        try await samples(type, predicate).count
    }

    func statistics(_ type: HKQuantityType, _ predicate: NSPredicate?,
                    _ options: HKStatisticsOptions) async -> (HKStatistics?, (any Error)?) {
        let box = Locked<(HKStatistics?, (any Error)?)>((nil, nil))
        await run { done in
            HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, s, e in
                box.withLock { $0 = (s, e) }
                done()
            }
        }
        return box.current
    }

    func collection(_ type: HKQuantityType, _ predicate: NSPredicate? = nil, _ options: HKStatisticsOptions,
                    anchor: Date, interval: DateComponents) async throws -> HKStatisticsCollection {
        let box = Locked<Result<HKStatisticsCollection?, any Error>>(.success(nil))
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate, options: options,
                                                anchorDate: anchor, intervalComponents: interval)
            q.ycodeCalendar = T.utc
            q.initialResultsHandler = { _, c, e in
                box.withLock { $0 = e.map { .failure($0) } ?? .success(c) }
                k.resume()
            }
            execute(q)
        }
        return try #require(try box.current.get())
    }

    func anchored(_ type: HKSampleType, _ predicate: NSPredicate? = nil, anchor: HKQueryAnchor?,
                  limit: Int = HKObjectQueryNoLimit) async throws -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        let box = Locked<Result<([HKSample], [HKDeletedObject], HKQueryAnchor?), any Error>>(.success(([], [], nil)))
        await run { done in
            HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: limit) { _, s, d, a, e in
                box.withLock { $0 = e.map { .failure($0) } ?? .success((s ?? [], d ?? [], a)) }
                done()
            }
        }
        return try box.current.get()
    }
}

/// Wait until `condition` holds (long-running query callbacks arrive asynchronously).
func eventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Expect an `HKErrorDomain` error with the given code.
func expectCode(_ expected: Int, sourceLocation: SourceLocation = #_sourceLocation,
                _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected HealthKit error code \(expected)", sourceLocation: sourceLocation)
    } catch {
        let ns = error as NSError
        #expect(ns.domain == "com.apple.healthkit" && ns.code == expected, "got \(ns.domain) \(ns.code)",
                sourceLocation: sourceLocation)
    }
}

/// Relative comparison for golden values printed with limited digits.
func close(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-4) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance * max(1, abs(b))
}

// MARK: - The golden data set (`plan.md` §3.1)

struct Golden {
    let daemon: YcodeHealthDaemon
    let a: HKHealthStore
    let b: HKHealthStore?
    var workout: HKWorkout!
    var energySample: HKQuantitySample!
    var correlation: HKCorrelation!

    /// - Parameters:
    ///   - withB: add app B with its two step samples (B granted after A, read of heart rate off).
    ///   - later: add the samples saved "later in the run" (sync 7/8/9, deleted again; 11 @22:00).
    static func make(withB: Bool = false, later: Bool = false) async throws -> Golden {
        let daemon = try T.daemon()
        let a = HKHealthStore(ycodeDaemon: daemon, client: T.clientA)
        try await a.grant(range: .past30Days, at: T.grantA)
        var g = Golden(daemon: daemon, a: a, b: nil)
        try await g.seedA()
        if later { try await g.seedLater() }
        if withB {
            let b = HKHealthStore(ycodeDaemon: daemon, client: T.clientB)
            try await b.grant(range: .allRecordedData, at: T.grantA.addingTimeInterval(3600),
                              readOff: [HKQuantityTypeIdentifier.heartRate.rawValue])
            try await b.save([T.stepSample(400, T.at(0, 8, 0), T.at(0, 8, 10)),
                              T.stepSample(900, T.at(0, 15, 0), T.at(0, 15, 10))])
            g = Golden(daemon: daemon, a: a, b: b, workout: g.workout, energySample: g.energySample,
                       correlation: g.correlation)
        }
        return g
    }

    mutating func seedA() async throws {
        // steps
        try await a.save([
            T.stepSample(1000, T.at(0, 8, 0), T.at(0, 8, 10)),
            T.stepSample(500, T.at(0, 8, 5), T.at(0, 8, 15)),
            T.stepSample(3000, T.at(0, 12, 0), T.at(0, 12, 30), [
                HKMetadataKeyExternalUUID: "ycode-s3", "YcodeProbe": "golden", "YcodeNumber": 42,
                "YcodeQuantity": HKQuantity(unit: .meter(), doubleValue: 3), "YcodeDate": T.d0,
            ]),
            T.stepSample(2000, T.at(1, 9, 0), T.at(1, 9, 30)),
            T.stepSample(600, T.at(0, 23, 50), T.at(1, 0, 10)),
            T.stepSample(1, Date(timeIntervalSince1970: -5e9), Date(timeIntervalSince1970: -5e9 + 60)),
            T.stepSample(61, T.at(-60, 12, 0), T.at(-60, 12, 1)),
            T.stepSample(4, T.at(-10), T.at(-6)),
        ])
        // heart rate (150 @06:15 is the workout's sample)
        try await a.save([
            T.qs(T.heartRate, 60, T.bpm, T.at(0, 8, 0)),
            T.qs(T.heartRate, 70, T.bpm, T.at(0, 8, 30)),
            T.qs(T.heartRate, 90, T.bpm, T.at(0, 9, 0)),
            T.qs(T.heartRate, 80, T.bpm, T.at(0, 13, 0), T.at(0, 13, 10)),
        ])
        // body mass
        try await a.save([
            T.qs(T.bodyMass, 70, .gramUnit(with: .kilo), T.at(0, 7, 0), nil, [HKMetadataKeyWasUserEntered: true]),
            T.qs(T.bodyMass, 155, .pound(), T.at(1, 7, 0)),
        ])
        // sleep and mindful minutes
        try await a.save([
            HKCategorySample(type: T.sleep, value: HKCategoryValueSleepAnalysis.inBed.rawValue, start: T.at(0, 0, 45), end: T.at(0, 6)),
            HKCategorySample(type: T.sleep, value: HKCategoryValueSleepAnalysis.asleepCore.rawValue, start: T.at(0, 1), end: T.at(0, 3)),
            HKCategorySample(type: T.sleep, value: HKCategoryValueSleepAnalysis.awake.rawValue, start: T.at(0, 3), end: T.at(0, 3, 15)),
            HKCategorySample(type: T.sleep, value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue, start: T.at(0, 3, 15), end: T.at(0, 5)),
            HKCategorySample(type: T.mindful, value: HKCategoryValue.notApplicable.rawValue, start: T.at(0, 10), end: T.at(0, 10, 10)),
        ])
        // blood pressure correlation 120/80
        let sys = T.qs(T.systolic, 120, .millimeterOfMercury(), T.at(0, 7, 30))
        let dia = T.qs(T.diastolic, 80, .millimeterOfMercury(), T.at(0, 7, 30))
        correlation = HKCorrelation(type: T.bloodPressure, start: T.at(0, 7, 30), end: T.at(0, 7, 30), objects: [sys, dia])
        try await a.save(correlation)
        // workout: running 06:00–06:30, paused 06:10–06:12, with energy, distance and heart rate
        let events = [HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: T.at(0, 6, 10), duration: 0), metadata: nil),
                      HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: T.at(0, 6, 12), duration: 0), metadata: nil)]
        workout = HKWorkout(activityType: .running, start: T.at(0, 6), end: T.at(0, 6, 30), workoutEvents: events,
                            totalEnergyBurned: nil, totalDistance: nil, metadata: nil)
        try await a.save(workout)
        energySample = T.qs(T.energy, 300, .kilocalorie(), T.at(0, 6), T.at(0, 6, 30))
        let dist = T.qs(T.distance, 5000, .meter(), T.at(0, 6), T.at(0, 6, 30))
        let hr = T.qs(T.heartRate, 150, T.bpm, T.at(0, 6, 15))
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            a.associate([energySample, dist, hr], to: workout) { _, e in if let e { k.resume(throwing: e) } else { k.resume() } }
        }
    }

    /// 7/8/9 @20:00–20:01 with sync versions 1/2/1, then deleted; 11 @22:00–22:01.
    func seedLater() async throws {
        for (v, ver) in [(7.0, 1), (8.0, 2), (9.0, 1)] {
            try await a.save(T.stepSample(v, T.at(0, 20), T.at(0, 20, 1),
                                          [HKMetadataKeySyncIdentifier: "ycode-sync", HKMetadataKeySyncVersion: ver]))
        }
        let n = try await a.deleteObjects(of: T.steps, predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier))
        #expect(n == 1)
        try await a.save(T.stepSample(11, T.at(0, 22), T.at(0, 22, 1)))
    }
}
