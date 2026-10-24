import Foundation
import Testing
@testable import HealthKit

private func code(_ e: (any Error)?) -> Int? { (e as NSError?)?.code }
private func domain(_ e: (any Error)?) -> String? { (e as NSError?)?.domain }

/// C-STORE: `simulator-baseline.md` §3–§4 (save, resave, delete, delete twice,
/// delete of type, authorization gates, persistence across a restart).
@Suite("C-STORE simulator-baseline.md §4")
struct StoreTests {
    @Test("§4.1 save, resave without duplicate, completion off the caller's thread")
    func saveAndResave() async throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant()
        let s = T.stepSample(100, T.at(0, 8), T.at(0, 8, 5))
        let thread = Locked<Bool?>(nil)
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            store.save(s) { ok, e in
                thread.withLock { $0 = Thread.isMainThread }
                #expect(ok && e == nil)
                k.resume()
            }
        }
        #expect(thread.current == false)
        try await store.save(s)                     // same object again: success, no duplicate
        #expect(try await store.count(T.steps) == 1)
        let back = try #require(try await store.samples(T.steps).first as? HKQuantitySample)
        #expect(back.uuid == s.uuid)
        #expect(back.sourceRevision.source.bundleIdentifier == "dev.ycode.healthprobe")
        #expect(back.sourceRevision.source.name == "HealthProbe")
        #expect(back.sourceRevision.version == "7")
        #expect(back.device == nil)
        #expect(back.quantity.doubleValue(for: .count()) == 100)
        // a sample older than 1900 is accepted
        try await store.save(T.stepSample(1, Date(timeIntervalSince1970: -5e9), Date(timeIntervalSince1970: -5e9 + 60)))
        #expect(try await store.count(T.steps) == 2)
    }

    @Test("§4.5 delete; delete twice and other apps' objects fail with code 3; delete of type")
    func deletion() async throws {
        let daemon = try T.daemon()
        let a = HKHealthStore(ycodeDaemon: daemon, client: T.clientA)
        let b = HKHealthStore(ycodeDaemon: daemon, client: T.clientB)
        try await a.grant()
        try await b.grant()
        let s1 = T.stepSample(1, T.at(0, 8), T.at(0, 8, 1)), s2 = T.stepSample(2, T.at(0, 9), T.at(0, 9, 1))
        try await a.save([s1, s2])
        // B cannot delete A's sample (code 3), nor a never-saved one
        await expectCode(3) { try await b.delete(s1) }
        await expectCode(3) { try await a.delete(T.stepSample(9, T.at(0), T.at(0))) }
        try await a.delete(s1)
        await expectCode(3) { try await a.delete(s1) }   // already deleted
        #expect(try await a.count(T.steps) == 1)
        // delete of type with an empty match: success, 0; then a match
        #expect(try await a.deleteObjects(of: T.steps, predicate: HKQuery.predicateForObjects(withMetadataKey: "nothing")) == 0)
        #expect(try await a.deleteObjects(of: T.steps, predicate: HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(1))) == 1)
        #expect(try await a.count(T.steps) == 0)
    }

    @Test("§3.1 before authorization: save, query, statistics, delete answer code 5; background delivery succeeds")
    func notDetermined() async throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        await expectCode(5) { try await store.save(T.stepSample(1, T.at(0), T.at(0))) }
        await expectCode(5) { _ = try await store.samples(T.steps) }
        let (stats, error) = await store.statistics(T.steps, nil, .cumulativeSum)
        #expect(stats == nil && code(error) == 5)
        await expectCode(5) { _ = try await store.deleteObjects(of: T.steps, predicate: NSPredicate(value: true)) }
        #expect(throws: (any Error).self) { try store.biologicalSex() }
        try await store.enableBackgroundDelivery(for: T.steps, frequency: .immediate)
        #expect(store.authorizationStatus(for: T.steps) == .notDetermined)
        #expect(try await store.statusForAuthorizationRequest(toShare: [T.steps], read: [T.steps]) == .shouldRequest)
    }

    @Test("§3.3 after the grant: statuses, request status, read-only types, a second request needs no consent")
    func afterGrant() async throws {
        let daemon = try T.daemon()
        let store = HKHealthStore(ycodeDaemon: daemon, client: T.clientA)
        try await store.grant(share: [T.steps], read: [T.steps, T.heartRate])
        #expect(store.authorizationStatus(for: T.steps) == .sharingAuthorized)
        #expect(store.authorizationStatus(for: T.heartRate) == .sharingDenied)      // read-only: never disclosed
        #expect(try await store.statusForAuthorizationRequest(toShare: [T.steps], read: [T.heartRate]) == .unnecessary)
        // saving a type granted for reading only: code 4
        await expectCode(4) { try await store.save(T.qs(T.heartRate, 60, T.bpm, T.at(0, 8))) }
        // a second request for the same set completes without asking
        let asked = Locked(0)
        daemon.setConsentResponder { _ in
            asked.withLock { $0 += 1 }
            return nil   // cancel
        }
        try await store.requestAuthorization(toShare: [T.steps], read: [T.steps, T.heartRate])
        #expect(asked.current == 0)
        // a new type asks; cancelling completes with code 7
        await expectCode(7) { try await store.requestAuthorization(toShare: [T.bodyMass], read: []) }
        #expect(asked.current == 1)
    }

    @Test("interface.md §6 characteristics after the grant")
    func characteristics() async throws {
        let daemon = try T.daemon()
        let store = HKHealthStore(ycodeDaemon: daemon, client: T.clientA)
        try await store.grant()
        #expect(try store.dateOfBirthComponents() == DateComponents())
        #expect(try store.biologicalSex().biologicalSex == .notSet)
        #expect(try store.bloodType().bloodType == .notSet)
        #expect(try store.fitzpatrickSkinType().skinType == .notSet)
        #expect(try store.wheelchairUse().wheelchairUse == .notSet)
        #expect(try store.activityMoveMode().activityMoveMode == .activeEnergy)
        daemon.setCharacteristic(.bloodType, value: "\(HKBloodType.oNegative.rawValue)")
        daemon.setCharacteristic(.dateOfBirth, value: "1990-02-03")
        #expect(try store.bloodType().bloodType == .oNegative)
        #expect(try store.dateOfBirthComponents().year == 1990)
    }

    @Test("queries.md §8 correlations: members saved with it, survive its deletion")
    func correlations() async throws {
        let g = try await Golden.make()
        #expect(try await g.a.count(T.systolic) == 1)
        #expect(try await g.a.count(T.systolic, HKQuery.predicateForObjectsWithNoCorrelation()) == 0)
        let stored = try #require(try await g.a.samples(T.bloodPressure).first as? HKCorrelation)
        #expect(stored.objects.count == 2)
        #expect(stored.objects(for: T.systolic).first.map { ($0 as! HKQuantitySample).quantity.doubleValue(for: .millimeterOfMercury()) } == 120)
        try await g.a.delete(stored)
        #expect(try await g.a.count(T.bloodPressure) == 0)
        #expect(try await g.a.count(T.systolic) == 1)
        #expect(try await g.a.count(T.diastolic) == 1)
    }

    @Test("simulator-baseline.md §8 P1: data and grants persist across a restart")
    func persistence() async throws {
        let url = T.tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var counts: [String: Int] = [:]
        do {
            let daemon = try YcodeHealthDaemon(databaseURL: url)
            let store = HKHealthStore(ycodeDaemon: daemon, client: T.clientA)
            try await store.grant()
            try await store.save([T.stepSample(1, T.at(0, 8), T.at(0, 8, 1)), T.stepSample(2, T.at(0, 9), T.at(0, 9, 1)),
                                  T.qs(T.heartRate, 60, T.bpm, T.at(0, 8),
                                       nil, [HKMetadataKeyExternalUUID: "persist"])])
            counts = daemon.objectCounts()
            daemon.close()
        }
        let daemon = try YcodeHealthDaemon(databaseURL: url)
        daemon.setConsentResponder { _ in nil }   // grants must be remembered, not re-asked
        let store = HKHealthStore(ycodeDaemon: daemon, client: T.clientA)
        #expect(daemon.objectCounts() == counts)
        #expect(counts[T.steps.identifier] == 2)
        #expect(store.authorizationStatus(for: T.steps) == .sharingAuthorized)
        let hr = try await store.samples(T.heartRate)
        #expect(hr.first?.metadata?[HKMetadataKeyExternalUUID] as? String == "persist")
        daemon.close()
    }
}

/// C-ANCHOR: `queries.md` §4 and §9.
@Suite("C-ANCHOR queries.md §4 §9")
struct AnchorTests {
    @Test("§4 fresh store, limit 2: the first two samples in insertion order (1000, 500)")
    func freshLimit() async throws {
        let g = try await Golden.make()
        let (added, deleted, anchor) = try await g.a.anchored(T.steps, anchor: nil, limit: 2)
        #expect(added.map { ($0 as! HKQuantitySample).quantity.doubleValue(for: .count()) } == [1000, 500])
        #expect(deleted.isEmpty)
        // continuing from the returned anchor yields the rest
        let (rest, _, _) = try await g.a.anchored(T.steps, anchor: anchor)
        #expect(rest.count == 6)
    }

    @Test("§4 tombstones carry UUID and metadata; the limit counts them (29 deletions, then 8 samples)")
    func tombstones() async throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant()
        let doomed = (0..<29).map { T.stepSample(Double($0), T.at(-1, 0, $0), T.at(-1, 0, $0), ["n": $0]) }
        try await store.save(doomed)
        for s in doomed { try await store.delete(s) }
        try await store.save((0..<8).map { T.stepSample(Double($0), T.at(0, 1, $0), T.at(0, 1, $0)) })
        let (all, gone, _) = try await store.anchored(T.steps, anchor: nil)
        #expect(all.count == 8 && gone.count == 29)
        #expect(Set(gone.map(\.uuid)) == Set(doomed.map(\.uuid)))
        #expect(gone.first?.metadata?["n"] as? Int == 0)
        let (two, twoGone, _) = try await store.anchored(T.steps, anchor: nil, limit: 2)
        #expect(two.isEmpty && twoGone.count == 2)
    }

    @Test("§4 anchorFromValue builds an anchor from an integer; anchors grow and round-trip secure coding")
    func anchorValues() async throws {
        let g = try await Golden.make()
        let (_, _, a1) = try await g.a.anchored(T.steps, anchor: nil)
        let anchor = try #require(a1)
        let (none, _, a2) = try await g.a.anchored(T.steps, anchor: HKQueryAnchor(fromValue: Int(anchor.value)))
        #expect(none.isEmpty && a2 == anchor)
        try await g.a.save(T.stepSample(5, T.at(2), T.at(2)))
        let (one, _, a3) = try await g.a.anchored(T.steps, anchor: anchor)
        #expect(one.count == 1 && a3!.value > anchor.value)
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        #expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) == anchor)
    }

    @Test("§9 sync identifier v1 → v2 → v1: stored v2 (8); live updates +1, then +1/−1, nothing for v1")
    func syncReplacement() async throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        try await store.grant()
        let events = Locked<[(Int, Int)]>([])
        let started = Locked(false)
        let q = HKAnchoredObjectQuery(type: T.steps, predicate: nil, anchor: nil, limit: 0) { _, _, _, _, _ in
            started.withLock { $0 = true }
        }
        q.updateHandler = { _, added, deleted, _, _ in
            events.withLock { $0.append((added?.count ?? 0, deleted?.count ?? 0)) }
        }
        store.execute(q)
        #expect(await eventually { started.current })
        func sync(_ v: Double, _ version: Int) -> HKQuantitySample {
            T.stepSample(v, T.at(0, 20), T.at(0, 20, 1), [HKMetadataKeySyncIdentifier: "ycode-sync", HKMetadataKeySyncVersion: version])
        }
        try await store.save(sync(7, 1))
        #expect(await eventually { events.current.count == 1 })
        try await store.save(sync(8, 2))
        #expect(await eventually { events.current.count == 2 })
        try await store.save(sync(9, 1))       // lower version: success, ignored
        try await store.save(T.stepSample(1, T.at(0), T.at(0)))   // a marker change set
        #expect(await eventually { events.current.count == 3 })
        store.stop(q)
        let e = events.current
        #expect(e[0] == (1, 0))
        #expect(e[1] == (1, 1))
        #expect(e[2] == (1, 0))      // the marker; the v1 save produced no update
        let stored = try await store.samples(T.steps, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier))
        #expect(stored.count == 1)
        #expect((stored.first as? HKQuantitySample)?.quantity.doubleValue(for: .count()) == 8)
        #expect(stored.first?.metadata?[HKMetadataKeySyncVersion] as? Int == 2)
    }
}
