import Foundation
import Testing
@testable import HealthKit

/// C-SWIFT (subset, round R10): the Swift query descriptors give the same results as
/// the callback queries (`interface.md` §9).
@Suite("C-SWIFT interface.md §9 (descriptor subset)")
struct DescriptorTests {
    @Test("sample descriptor: predicates, SortDescriptor, limit")
    func samples() async throws {
        let g = try await Golden.make()
        let d = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: T.steps, predicate: HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(2)))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 2)
        let latest = try await d.result(for: g.a)
        #expect(latest.map { $0.quantity.doubleValue(for: .count()) } == [2000, 600])
        let sleep = try await HKSampleQueryDescriptor(predicates: [.categorySample(type: T.sleep)],
                                                      sortDescriptors: [SortDescriptor(\.startDate)]).result(for: g.a)
        #expect(sleep.map(\.value) == [0, 3, 2, 4])
        let workouts = try await HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForWorkouts(with: .running))],
                                                         sortDescriptors: []).result(for: g.a)
        #expect(workouts.count == 1 && workouts[0].duration == 1680)   // paused 06:10–06:12
    }

    @Test("statistics descriptor: day D0 = 5100; no data → nil")
    func statistics() async throws {
        let g = try await Golden.make()
        let day = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: T.steps, predicate: HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(1))),
            options: .cumulativeSum)
        #expect(try await day.result(for: g.a)?.sumQuantity()?.doubleValue(for: .count()) == 5100)
        let none = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: T.steps, predicate: HKQuery.predicateForSamples(withStart: T.at(5), end: T.at(6))),
            options: .cumulativeSum)
        #expect(try await none.result(for: g.a) == nil)
    }

    @Test("collection descriptor: daily 4800 / 2300, then an update")
    func collection() async throws {
        let g = try await Golden.make()
        var d = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: T.steps), options: .cumulativeSum,
                                                      anchorDate: T.d0, intervalComponents: DateComponents(day: 1))
        d.ycodeCalendar = T.utc
        let c = try await d.result(for: g.a)
        #expect(c.statistics(for: T.at(0, 1))?.sumQuantity()?.doubleValue(for: .count()) == 4800)
        #expect(c.statistics(for: T.at(1, 1))?.sumQuantity()?.doubleValue(for: .count()) == 2300)
        var seen: [Double] = []
        for try await r in d.results(for: g.a) {
            seen.append(r.statisticsCollection.statistics(for: T.at(0, 1))?.sumQuantity()?.doubleValue(for: .count()) ?? -1)
            if seen.count == 1 { try await g.a.save(T.stepSample(100, T.at(0, 14), T.at(0, 14, 1))) }
            if seen.count == 2 { break }
        }
        #expect(seen == [4800, 4900])
    }

    @Test("anchored descriptor: result, then a live sequence")
    func anchored() async throws {
        let g = try await Golden.make()
        let first = try await HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: T.steps)], anchor: nil, limit: 2)
            .result(for: g.a)
        #expect(first.addedSamples.map { $0.quantity.doubleValue(for: .count()) } == [1000, 500])
        let d = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: T.steps)], anchor: first.newAnchor)
        var counts: [(Int, Int)] = []
        let extra = T.stepSample(9, T.at(0, 21), T.at(0, 21, 1))
        for try await r in d.results(for: g.a) {
            counts.append((r.addedSamples.count, r.deletedObjects.count))
            if counts.count == 1 { try await g.a.save(extra) }
            if counts.count == 2 { try await g.a.delete(extra) }
            if counts.count == 3 { break }
        }
        #expect(counts.count == 3)
        #expect(counts[0] == (6, 0) && counts[1] == (1, 0) && counts[2] == (0, 1))
    }

    @Test("source descriptor")
    func sources() async throws {
        let g = try await Golden.make(withB: true)
        let s = try await HKSourceQueryDescriptor(predicate: .quantitySample(type: T.steps)).result(for: g.a)
        #expect(s.map(\.bundleIdentifier) == ["dev.ycode.healthprobe", "dev.ycode.healthprobe.b"])
    }
}
