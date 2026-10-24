import Foundation
import Testing
@testable import HealthKit

/// C-OBSERVE: observer timing and counts, long-running anchored updates, stop
/// (`queries.md` §1, §4, §5).
@Suite("C-OBSERVE queries.md §5")
struct ObserveTests {
    @Test("§5 observer: once at start, then once per committed change set; none after stop")
    func observer() async throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant()
        let calls = Locked(0)
        let offMain = Locked(true)
        let q = HKObserverQuery(sampleType: T.steps, predicate: nil) { _, done, error in
            #expect(error == nil)
            if Thread.isMainThread { offMain.withLock { $0 = false } }
            calls.withLock { $0 += 1 }
            done()
        }
        store.execute(q)
        #expect(await eventually { calls.current == 1 })
        let s = T.stepSample(10, T.at(0, 8), T.at(0, 8, 1))
        try await store.save(s)
        #expect(await eventually { calls.current == 2 })
        // one save of three objects is one change set
        try await store.save((1...3).map { T.stepSample(Double($0), T.at(0, 9, $0), T.at(0, 9, $0)) })
        #expect(await eventually { calls.current == 3 })
        // other types do not fire
        try await store.save(T.qs(T.heartRate, 60, T.bpm, T.at(0, 8)))
        try await store.delete(s)
        #expect(await eventually { calls.current == 4 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(calls.current == 4)
        store.stop(q)
        try await store.save(T.stepSample(5, T.at(0, 10), T.at(0, 10)))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(calls.current == 4)
        #expect(offMain.current)
        // a stopped query cannot run again
        #expect(throws: HKRaise.self) { try q.markExecuted(store) }
    }

    @Test("§5 observer before authorization reports code 5")
    func observerNotDetermined() async throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        let code = Locked<Int?>(nil)
        store.execute(HKObserverQuery(sampleType: T.steps, predicate: nil) { _, done, e in
            code.withLock { $0 = (e as NSError?)?.code }
            done()
        })
        #expect(await eventually { code.current == 5 })
    }

    @Test("§4 long-running anchored query: initial delta, then 1 added, 1 added + 1 deleted, 1 deleted")
    func liveAnchored() async throws {
        let g = try await Golden.make()
        let initial = Locked<(Int, Int)?>(nil)
        let updates = Locked<[(Int, Int)]>([])
        let q = HKAnchoredObjectQuery(type: T.steps, predicate: nil, anchor: nil, limit: HKObjectQueryNoLimit) { _, a, d, _, _ in
            initial.withLock { $0 = (a?.count ?? 0, d?.count ?? 0) }
        }
        q.updateHandler = { _, a, d, _, _ in updates.withLock { $0.append((a?.count ?? 0, d?.count ?? 0)) } }
        g.a.execute(q)
        #expect(await eventually { initial.current != nil })
        #expect(initial.current! == (8, 0))
        let v1 = T.stepSample(7, T.at(0, 20), T.at(0, 20, 1), [HKMetadataKeySyncIdentifier: "s", HKMetadataKeySyncVersion: 1])
        let v2 = T.stepSample(8, T.at(0, 20), T.at(0, 20, 1), [HKMetadataKeySyncIdentifier: "s", HKMetadataKeySyncVersion: 2])
        try await g.a.save(v1)
        #expect(await eventually { updates.current.count == 1 })
        try await g.a.save(v2)
        #expect(await eventually { updates.current.count == 2 })
        try await g.a.delete(v2)
        #expect(await eventually { updates.current.count == 3 })
        g.a.stop(q)
        let u = updates.current
        #expect(u[0] == (1, 0) && u[1] == (1, 1) && u[2] == (0, 1))
    }

    @Test("§6.5 statistics collection update handler re-delivers after a change")
    func collectionUpdates() async throws {
        let g = try await Golden.make()
        let latest = Locked<HKStatisticsCollection?>(nil)
        let q = HKStatisticsCollectionQuery(quantityType: T.steps, quantitySamplePredicate: nil, options: .cumulativeSum,
                                            anchorDate: T.d0, intervalComponents: DateComponents(day: 1))
        q.ycodeCalendar = T.utc
        q.initialResultsHandler = { _, c, _ in latest.withLock { $0 = c } }
        q.statisticsUpdateHandler = { _, _, c, _ in latest.withLock { $0 = c } }
        g.a.execute(q)
        #expect(await eventually { latest.current != nil })
        #expect(latest.current?.statistics(for: T.at(0, 12))?.sumQuantity()?.doubleValue(for: .count()) == 4800)
        try await g.a.save(T.stepSample(200, T.at(0, 14), T.at(0, 14, 10)))
        #expect(await eventually {
            latest.current?.statistics(for: T.at(0, 12))?.sumQuantity()?.doubleValue(for: .count()) == 5000
        })
        g.a.stop(q)
    }
}
