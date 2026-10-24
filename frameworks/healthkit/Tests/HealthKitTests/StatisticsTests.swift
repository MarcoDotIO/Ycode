import Foundation
import Testing
@testable import HealthKit

private func value(_ q: HKQuantity?, _ unit: HKUnit) -> Double? { q?.doubleValue(for: unit) }

/// C-STATS: statistics queries against the golden values of `plan.md` §3.2 and `queries.md` §6.2–§6.3.
@Suite("C-STATS plan.md §3.2")
struct StatisticsTests {
    @Test("§6.2 steps: whole-sample sums, result range, strict windows, duration, all time")
    func steps() async throws {
        let g = try await Golden.make()
        let a = g.a
        func sum(_ s: Date?, _ e: Date?, _ o: HKQueryOptions = [], _ opts: HKStatisticsOptions = .cumulativeSum) async -> HKStatistics? {
            await a.statistics(T.steps, HKQuery.predicateForSamples(withStart: s, end: e, options: o), opts).0
        }
        let day = try #require(await sum(T.at(0), T.at(1)))
        #expect(value(day.sumQuantity(), .count()) == 5100)
        #expect(day.startDate == T.at(0, 8) && day.endDate == T.at(1, 0, 10))
        #expect(value(await sum(T.at(0), T.at(1), [.strictStartDate, .strictEndDate])?.sumQuantity(), .count()) == 4500)
        let next = try #require(await sum(T.at(1), T.at(2)))
        #expect(value(next.sumQuantity(), .count()) == 2600)
        #expect(next.startDate == T.at(0, 23, 50) && next.endDate == T.at(1, 9, 30))
        let two = try #require(await sum(T.at(0), T.at(2), [], [.cumulativeSum, .duration]))
        #expect(value(two.sumQuantity(), .count()) == 7100)
        #expect(value(two.duration(), .second()) == 5700)
        // all time, A granted "past 30 days" at 2026-10-19 23:55:40Z
        let all = try #require(await a.statistics(T.steps, nil, [.cumulativeSum, .mostRecent]).0)
        #expect(value(all.sumQuantity(), .count()) == 7104)
        #expect(value(all.mostRecentQuantity(), .count()) == 2000)
        #expect(all.mostRecentQuantityDateInterval() == DateInterval(start: T.at(1, 9), end: T.at(1, 9, 30)))
        // windows inside samples count the whole samples
        let w1 = try #require(await sum(T.at(0, 8), T.at(0, 8, 10)))
        #expect(value(w1.sumQuantity(), .count()) == 1500)
        #expect(w1.startDate == T.at(0, 8) && w1.endDate == T.at(0, 8, 15))
        #expect(value(await sum(T.at(0, 8, 5), T.at(0, 8, 10))?.sumQuantity(), .count()) == 1500)
        let w3 = try #require(await sum(T.at(0, 12), T.at(0, 12, 15)))
        #expect(value(w3.sumQuantity(), .count()) == 3000)
        #expect(w3.startDate == T.at(0, 12) && w3.endDate == T.at(0, 12, 30))
        // option 0: only the date range
        let bare = try #require(await sum(T.at(0), T.at(1), [], []))
        #expect(bare.sumQuantity() == nil && bare.startDate == T.at(0, 8))
    }

    @Test("§6.1 no matching samples: nil statistics and code 11")
    func empty() async throws {
        let g = try await Golden.make()
        let (s, e) = await g.a.statistics(T.steps, HKQuery.predicateForSamples(withStart: T.at(5), end: T.at(6)), .cumulativeSum)
        #expect(s == nil)
        #expect((e as NSError?)?.code == 11 && (e as NSError?)?.domain == HKErrorDomain)
        #expect((e as? HKError)?.code == .errorNoData)
    }

    @Test("§6.3 heart rate (temporally weighted): day D0 and [08:00, 09:00]")
    func heartRate() async throws {
        let g = try await Golden.make()
        let opts: HKStatisticsOptions = [.discreteAverage, .discreteMin, .discreteMax, .mostRecent]
        let day = try #require(await g.a.statistics(T.heartRate, HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(1)), opts).0)
        #expect(close(value(day.averageQuantity(), T.bpm), 82.7273))
        #expect(value(day.minimumQuantity(), T.bpm) == 60)
        #expect(value(day.maximumQuantity(), T.bpm) == 150)
        #expect(value(day.mostRecentQuantity(), T.bpm) == 80)
        #expect(day.mostRecentQuantityDateInterval() == DateInterval(start: T.at(0, 13), end: T.at(0, 13, 10)))
        let morning = try #require(await g.a.statistics(T.heartRate, HKQuery.predicateForSamples(withStart: T.at(0, 8), end: T.at(0, 9)), opts).0)
        #expect(close(value(morning.averageQuantity(), T.bpm), 65))
        #expect(value(morning.minimumQuantity(), T.bpm) == 60)
        #expect(value(morning.maximumQuantity(), T.bpm) == 70)
    }

    @Test("§6.3 body mass, mixed units (70 kg and 155 lb)")
    func bodyMass() async throws {
        let g = try await Golden.make()
        let kg = HKUnit.gramUnit(with: .kilo)
        let s = try #require(await g.a.statistics(T.bodyMass, nil, [.discreteAverage, .discreteMin, .discreteMax, .mostRecent]).0)
        #expect(close(value(s.averageQuantity(), kg), 70.1534))
        #expect(value(s.minimumQuantity(), kg) == 70)
        #expect(close(value(s.maximumQuantity(), kg), 70.3068))
        #expect(close(value(s.mostRecentQuantity(), kg), 70.3068))
        #expect(s.mostRecentQuantityDateInterval()?.start == T.at(1, 7))
    }

    @Test("plan.md §3.2 active energy and distance over all time: 300 kcal / 5 km")
    func workoutTotals() async throws {
        let g = try await Golden.make()
        #expect(value(await g.a.statistics(T.energy, nil, .cumulativeSum).0?.sumQuantity(), .kilocalorie()) == 300)
        #expect(value(await g.a.statistics(T.distance, nil, .cumulativeSum).0?.sumQuantity(), .meterUnit(with: .kilo)) == 5)
    }

    /// Two body-temperature or heart-rate samples (value, start, end) on a fresh store.
    static func pair(_ type: HKQuantityType, _ unit: HKUnit, _ samples: [(Double, Date, Date)]) async throws -> HKStatistics {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant()
        try await store.save(samples.map { T.qs(type, $0.0, unit, $0.1, $0.2) })
        return try #require(await store.statistics(type, nil, [.discreteAverage, .discreteMin, .discreteMax, .mostRecent, .duration]).0)
    }

    @Test("§6.3 arithmetic average: 10 and 20 give 15 in four layouts")
    func arithmetic() async throws {
        let c = HKUnit.degreeCelsius()
        let t = T.at(3, 7)
        let layouts: [[(Double, Date, Date)]] = [
            [(10, t, t), (20, t.addingTimeInterval(1800), t.addingTimeInterval(1800))],          // two instants
            [(10, t, t), (20, t.addingTimeInterval(300), t.addingTimeInterval(900))],             // instant + 10 min
            [(10, t, t.addingTimeInterval(60)), (20, t.addingTimeInterval(120), t.addingTimeInterval(300))],  // 1 + 3 min
            [(10, t, t.addingTimeInterval(600)), (20, t.addingTimeInterval(300), t.addingTimeInterval(900))], // overlapping
        ]
        for l in layouts {
            #expect(close(value(try await Self.pair(T.bodyTemperature, c, l).averageQuantity(), c), 15, 1e-12))
        }
    }

    @Test("§6.3 temporally weighted average: duration + 45 s weights")
    func temporallyWeighted() async throws {
        let t = T.at(4, 7)
        func at(_ m: Double) -> Date { t.addingTimeInterval(m * 60) }
        let cases: [([(Double, Date, Date)], Double)] = [
            ([(60, at(0), at(0)), (120, at(30), at(30))], 90),
            ([(60, at(0), at(0)), (120, at(5), at(15))], 116.087),
            ([(60, at(0), at(1)), (120, at(2), at(5))], 100.909),
            ([(60, at(0), at(10)), (120, at(10), at(20))], 90),
            ([(60, at(0), at(10)), (120, at(15), at(15))], 63.913),
            ([(60, at(0), at(0)), (70, at(10), at(10)), (90, at(20), at(20))], 73.3333),
        ]
        for (samples, expected) in cases {
            #expect(close(value(try await Self.pair(T.heartRate, T.bpm, samples).averageQuantity(), T.bpm), expected))
        }
    }

    @Test("§6.3 day-3 body temperature: avg 15, min 10, max 20, most recent 20 @07:05–07:15, duration 1740 s; [07:00, 07:05] → 10")
    func dayThree() async throws {
        // The spec gives the results, not the layout; this layout reproduces all of them (spec question).
        let c = HKUnit.degreeCelsius()
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant()
        try await store.save([T.qs(T.bodyTemperature, 10, c, T.at(3, 6, 46), T.at(3, 7, 5)),
                              T.qs(T.bodyTemperature, 20, c, T.at(3, 7, 5), T.at(3, 7, 15))])
        let opts: HKStatisticsOptions = [.discreteAverage, .discreteMin, .discreteMax, .mostRecent, .duration]
        let s = try #require(await store.statistics(T.bodyTemperature, HKQuery.predicateForSamples(withStart: T.at(3), end: T.at(4)), opts).0)
        #expect(close(value(s.averageQuantity(), c), 15, 1e-12))
        #expect(value(s.minimumQuantity(), c) == 10 && value(s.maximumQuantity(), c) == 20)
        #expect(close(value(s.mostRecentQuantity(), c), 20, 1e-12))
        #expect(s.mostRecentQuantityDateInterval() == DateInterval(start: T.at(3, 7, 5), end: T.at(3, 7, 15)))
        #expect(value(s.duration(), .second()) == 1740)
        let early = try #require(await store.statistics(T.bodyTemperature, HKQuery.predicateForSamples(withStart: T.at(3, 7), end: T.at(3, 7, 5)), opts).0)
        #expect(close(value(early.averageQuantity(), c), 10, 1e-12))
    }

    @Test("§6.3 equivalent continuous level (audio exposure): energy average with the same weights")
    func equivalentContinuousLevel() async throws {
        let db = HKUnit.decibelAWeightedSoundPressureLevel()
        let type = T.q(.environmentalAudioExposure)
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant(share: [type], read: [type])
        try await store.save([T.qs(type, 60, db, T.at(0, 8), T.at(0, 8, 10)), T.qs(type, 80, db, T.at(0, 9), T.at(0, 9, 10))])
        let s = try #require(await store.statistics(type, nil, .discreteAverage).0)
        let expected = 10 * log10((1e6 + 1e8) / 2.0)   // equal weights → 76.99 dB
        #expect(close(value(s.averageQuantity(), db), expected, 1e-9))
    }
}

/// C-COLLECT: statistics collections (`queries.md` §6.5, `plan.md` §3.2).
@Suite("C-COLLECT plan.md §3.2")
struct CollectionTests {
    func sums(_ c: HKStatisticsCollection, _ dates: [Date]) -> [Double?] {
        dates.map { c.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .count()) }
    }

    @Test("daily buckets from D0 00:00: 4800, 2300, and 1 per day D0−10 … D0−7")
    func daily() async throws {
        let g = try await Golden.make()
        let c = try await g.a.collection(T.steps, nil, .cumulativeSum, anchor: T.d0, interval: DateComponents(day: 1))
        #expect(sums(c, [T.at(0, 12), T.at(1, 12)]) == [4800, 2300])
        for d in -10 ... -7 { #expect(close(sums(c, [T.at(d, 12)])[0], 1, 1e-12)) }
        // only buckets with data are listed; every bucket is enumerable
        #expect(c.statistics().count == 6)
        #expect(c.statistics().first?.startDate == T.at(-10))
        var visited = 0
        c.enumerateStatistics(from: T.at(-2), to: T.at(1)) { s, _ in
            visited += 1
            if s.startDate == T.at(-1) { #expect(s.sumQuantity() == nil) }
        }
        #expect(visited == 4)
        #expect(c.sources().map(\.bundleIdentifier) == ["dev.ycode.healthprobe"])
    }

    @Test("daily buckets anchored at 06:00 (anchor D0−5d 06:00): 5100, 2000")
    func dailyAt6() async throws {
        let g = try await Golden.make()
        let c = try await g.a.collection(T.steps, nil, .cumulativeSum, anchor: T.at(-5, 6), interval: DateComponents(day: 1))
        #expect(sums(c, [T.at(0, 12), T.at(1, 12)]) == [5100, 2000])
        #expect(c.statistics(for: T.at(0, 12))?.startDate == T.at(0, 6))
    }

    @Test("six-hourly from D0: 1500, 3000, 300, 300, 2000; 0.25 per bucket for the 4-day sample")
    func sixHourly() async throws {
        let g = try await Golden.make()
        let c = try await g.a.collection(T.steps, nil, .cumulativeSum, anchor: T.d0, interval: DateComponents(hour: 6))
        #expect(sums(c, [T.at(0, 7), T.at(0, 13), T.at(0, 19), T.at(1, 1), T.at(1, 7)]) == [1500, 3000, 300, 300, 2000])
        for h in stride(from: 0, to: 96, by: 6) {
            #expect(close(sums(c, [T.at(-10, h)])[0], 0.25, 1e-12))
        }
    }

    @Test("five-minute buckets around 08:00: 500, 750, 250 (proration)")
    func fiveMinutes() async throws {
        let g = try await Golden.make()
        let c = try await g.a.collection(T.steps, nil, .cumulativeSum, anchor: T.d0, interval: DateComponents(minute: 5))
        #expect(sums(c, [T.at(0, 8, 1), T.at(0, 8, 6), T.at(0, 8, 11)]) == [500, 750, 250])
    }

    @Test("hourly heart rate: 06:00 150; 08:00 65 (60/70); 09:00 90; 13:00 80")
    func hourlyHeartRate() async throws {
        let g = try await Golden.make()
        let c = try await g.a.collection(T.heartRate, nil, [.discreteAverage, .discreteMin, .discreteMax], anchor: T.d0,
                                         interval: DateComponents(hour: 1))
        func avg(_ d: Date) -> Double? { c.statistics(for: d)?.averageQuantity()?.doubleValue(for: T.bpm) }
        #expect(avg(T.at(0, 6, 30)) == 150)
        #expect(close(avg(T.at(0, 8, 30)), 65))
        #expect(c.statistics(for: T.at(0, 8, 30))?.minimumQuantity()?.doubleValue(for: T.bpm) == 60)
        #expect(c.statistics(for: T.at(0, 8, 30))?.maximumQuantity()?.doubleValue(for: T.bpm) == 70)
        #expect(avg(T.at(0, 9, 30)) == 90)
        #expect(avg(T.at(0, 13, 30)) == 80)
        #expect(avg(T.at(0, 7, 30)) == nil)
        #expect(c.statistics().map(\.startDate) == [T.at(0, 6), T.at(0, 8), T.at(0, 9), T.at(0, 13)])
    }
}

/// C-MERGE: merging across sources (`queries.md` §6.4).
@Suite("C-MERGE queries.md §6.4")
struct MergeTests {
    @Test("cross-source day D0 seen by B: merged 4911; B 1300; A 5111")
    func day() async throws {
        let g = try await Golden.make(withB: true, later: true)
        let b = try #require(g.b)
        let s = try #require(await b.statistics(T.steps, HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(1)),
                                                [.cumulativeSum, .separateBySource]).0)
        #expect(value(s.sumQuantity(), .count()) == 4911)
        #expect(value(s.sumQuantity(for: T.clientB.source), .count()) == 1300)
        #expect(value(s.sumQuantity(for: T.clientA.source), .count()) == 5111)
        #expect(Set(s.sources?.map(\.bundleIdentifier) ?? []) == ["dev.ycode.healthprobe", "dev.ycode.healthprobe.b"])
    }

    @Test("cross-source [08:00, 08:10]: merged 400; A 1500; B 400")
    func window() async throws {
        let g = try await Golden.make(withB: true, later: true)
        let b = try #require(g.b)
        let s = try #require(await b.statistics(T.steps, HKQuery.predicateForSamples(withStart: T.at(0, 8), end: T.at(0, 8, 10)),
                                                [.cumulativeSum, .separateBySource]).0)
        #expect(value(s.sumQuantity(), .count()) == 400)
        #expect(value(s.sumQuantity(for: T.clientA.source), .count()) == 1500)
        #expect(value(s.sumQuantity(for: T.clientB.source), .count()) == 400)
    }

    @Test("hourly collection 08:00–09:00 merged: 400")
    func hourly() async throws {
        let g = try await Golden.make(withB: true, later: true)
        let b = try #require(g.b)
        let c = try await b.collection(T.steps, nil, .cumulativeSum, anchor: T.d0, interval: DateComponents(hour: 1))
        #expect(c.statistics(for: T.at(0, 8, 30))?.sumQuantity()?.doubleValue(for: .count()) == 400)
    }

    @Test("an explicit source order wins over the default (A first → A's samples are kept)")
    func explicitPriority() async throws {
        let g = try await Golden.make(withB: true, later: true)
        let b = try #require(g.b)
        g.daemon.setSourcePriority(["dev.ycode.healthprobe", "dev.ycode.healthprobe.b"], for: T.steps)
        let s = try #require(await b.statistics(T.steps, HKQuery.predicateForSamples(withStart: T.at(0, 8), end: T.at(0, 8, 10)),
                                                .cumulativeSum).0)
        #expect(value(s.sumQuantity(), .count()) == 1500)
    }

    @Test("discrete types are not de-duplicated; B with heart-rate read off gets code 11")
    func discreteAndDenied() async throws {
        let g = try await Golden.make(withB: true)
        let b = try #require(g.b)
        let (s, e) = await b.statistics(T.heartRate, nil, .discreteAverage)
        #expect(s == nil && (e as NSError?)?.code == 11)
        // B sees A's body mass (read granted) plus its own overlapping sample: plain mean of all three
        try await b.save(T.qs(T.bodyMass, 80, .gramUnit(with: .kilo), T.at(0, 7)))
        let m = try #require(await b.statistics(T.bodyMass, nil, .discreteAverage).0)
        #expect(close(value(m.averageQuantity(), .gramUnit(with: .kilo)), (70 + 70.30676 + 80) / 3))
    }
}
