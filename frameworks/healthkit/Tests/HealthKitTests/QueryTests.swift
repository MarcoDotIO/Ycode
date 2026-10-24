import Foundation
import Testing
@testable import HealthKit

/// C-QUERY: predicates and their boundary rules, sorting, limits (`queries.md` §2–§3),
/// correlation and source queries, own-data visibility (§7), historical range (§6.6).
@Suite("C-QUERY queries.md §2–§3")
struct QueryTests {
    @Test("§2.1 date interval predicate: golden counts on the step samples")
    func dateIntervals() async throws {
        let g = try await Golden.make()
        let cases: [(Date?, Date?, HKQueryOptions, Int)] = [
            (T.at(0), T.at(1), [], 4),
            (T.at(0), T.at(1), .strictStartDate, 4),
            (T.at(0), T.at(1), .strictEndDate, 3),
            (T.at(0), T.at(1), [.strictStartDate, .strictEndDate], 3),
            (T.at(0, 8, 10), T.at(0, 8, 10), [], 2),
            (T.at(0, 8, 15), T.at(0, 9), [], 1),
            (T.at(0, 7), T.at(0, 8), [], 0),
            (nil, T.at(0, 9), [], 5),
        ]
        for (s, e, o, expected) in cases {
            let n = try await g.a.count(T.steps, HKQuery.predicateForSamples(withStart: s, end: e, options: o))
            #expect(n == expected, "window \(String(describing: s))–\(String(describing: e)) options \(o.rawValue)")
        }
        // an instant at 09:00 is not in [08:00, 09:00] but is in [07:59, 09:01]
        let nine = HKCompound.and([HKQuery.predicateForSamples(withStart: T.at(0, 8), end: T.at(0, 9)),
                                   HKQuery.predicateForQuantitySamples(with: .equalTo, quantity: HKQuantity(unit: T.bpm, doubleValue: 90))])
        #expect(try await g.a.count(T.heartRate, nine) == 0)
        let wider = HKCompound.and([HKQuery.predicateForSamples(withStart: T.at(0, 7, 59), end: T.at(0, 9, 1)),
                                    HKQuery.predicateForQuantitySamples(with: .equalTo, quantity: HKQuantity(unit: T.bpm, doubleValue: 90))])
        #expect(try await g.a.count(T.heartRate, wider) == 1)
    }

    @Test("§2.2 other predicates: golden counts")
    func otherPredicates() async throws {
        let g = try await Golden.make()
        let a = g.a
        #expect(try await a.count(T.steps, HKQuery.predicateForObjects(withMetadataKey: "YcodeProbe", allowedValues: ["golden"])) == 1)
        #expect(try await a.count(T.steps, HKQuery.predicateForObjects(withMetadataKey: "YcodeNumber", operatorType: .greaterThan, value: 40)) == 1)
        #expect(try await a.count(T.steps, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID)) == 1)
        #expect(try await a.count(T.steps, HKQuery.predicateForQuantitySamples(with: .greaterThanOrEqualTo,
                                                                               quantity: HKQuantity(unit: .count(), doubleValue: 1000))) == 3)
        #expect(try await a.count(T.sleep, HKQuery.predicateForCategorySamples(with: .equalTo,
                                                                               value: HKCategoryValueSleepAnalysis.asleepCore.rawValue)) == 1)
        #expect(try await a.count(T.sleep, HKQuery.predicateForCategorySamples(equalTo: Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)))) == 2)
        let own = HKQuery.predicateForObjects(from: T.clientA.source)
        #expect(try await a.count(T.steps, own) == 8)
        #expect(try await a.count(T.sleep, own) == 4)
        #expect(try await a.count(T.steps, HKQuery.predicateForObjects(from: [HKDevice.local()])) == 0)
        #expect(try await a.count(T.systolic, HKQuery.predicateForObjectsWithNoCorrelation()) == 0)
        #expect(try await a.count(T.systolic) == 1)
        #expect(try await a.count(T.energy, HKQuery.predicateForObjects(from: g.workout)) == 1)
        #expect(try await a.count(HKObjectType.workoutType(), HKQuery.predicateForWorkouts(with: .running)) == 1)
        #expect(try await a.count(HKObjectType.workoutType(), HKQuery.predicateForWorkouts(with: .walking)) == 0)
        #expect(try await a.count(T.steps, HKQuery.predicateForObject(with: g.energySample.uuid)) == 0)
        #expect(try await a.count(T.energy, HKQuery.predicateForObject(with: g.energySample.uuid)) == 1)
        // metadata values come back with their classes
        let s3 = try #require(try await a.samples(T.steps, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID)).first)
        #expect(s3.metadata?[HKMetadataKeyExternalUUID] as? String == "ycode-s3")
        #expect(s3.metadata?["YcodeNumber"] as? Int == 42)
        #expect((s3.metadata?["YcodeQuantity"] as? HKQuantity)?.description == "3 m")
        #expect(s3.metadata?["YcodeDate"] as? Date == T.d0)
        #expect(try await a.count(T.bodyMass, HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyWasUserEntered,
                                                                           operatorType: .equalTo, value: true)) == 1)
    }

    @Test("§2 compound predicates and block predicates")
    func compound() async throws {
        let g = try await Golden.make()
        let day = HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(1))
        let big = HKQuery.predicateForQuantitySamples(with: .greaterThan, quantity: HKQuantity(unit: .count(), doubleValue: 700))
        #expect(try await g.a.count(T.steps, NSCompoundPredicate(andPredicateWithSubpredicates: [day, big])) == 2)
        #expect(try await g.a.count(T.steps, NSCompoundPredicate(orPredicateWithSubpredicates: [day, big])) == 5)
        #expect(try await g.a.count(T.steps, NSCompoundPredicate(notPredicateWithSubpredicate: day)) == 4)
        let block = NSPredicate { o, _ in ((o as? HKQuantitySample)?.quantity.doubleValue(for: .count()) ?? 0) < 10 }
        #expect(try await g.a.count(T.steps, block) == 2)
        #expect(try await g.a.count(T.steps, NSPredicate(value: false)) == 0)
    }

    #if canImport(ObjectiveC)
    @Test("§2 a plain NSPredicate over HealthKit key paths: startDate > D0 returns 5 step samples")
    func plainPredicate() async throws {
        let g = try await Golden.make()
        #expect(try await g.a.count(T.steps, NSPredicate(format: "startDate > %@", T.d0 as NSDate)) == 5)
        #expect(try await g.a.count(T.sleep, NSPredicate(format: "value == %d", 3)) == 1)
    }
    #endif

    @Test("§3 sorting and limits")
    func sortingAndLimits() async throws {
        let g = try await Golden.make()
        #if canImport(ObjectiveC)
        let byEnd = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let byStart = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let byQuantity = NSSortDescriptor(key: HKPredicateKeyPathQuantity, ascending: true)
        #else
        let byEnd = NSSortDescriptor(keyPath: \HKSample.endDate, ascending: false)
        let byStart = NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)
        let byQuantity = NSSortDescriptor(keyPath: \HKSample.uuid.uuidString, ascending: true)
        #endif
        let latest = try await g.a.samples(T.steps, limit: 2, sort: [byEnd])
        #expect(latest.map { ($0 as! HKQuantitySample).quantity.doubleValue(for: .count()) } == [2000, 600])
        let ordered = try await g.a.samples(T.steps, sort: [byStart])
        #expect(ordered.map(\.startDate) == ordered.map(\.startDate).sorted())
        #expect(try await g.a.samples(T.steps, sort: [byQuantity]).count == 8)   // accepted, returns all
        #expect(try await g.a.samples(T.steps, limit: HKObjectQueryNoLimit).count == 8)
        #expect(try await g.a.samples(T.steps, limit: 3).count == 3)
        // unsorted results come back in start-date order
        let plain = try await g.a.samples(T.steps)
        #expect(plain.map(\.startDate) == plain.map(\.startDate).sorted())
    }

    @Test("§2 multi-type sample query with query descriptors")
    func descriptors() async throws {
        let g = try await Golden.make()
        let box = Locked<[HKSample]>([])
        await g.a.run { done in
            HKSampleQuery(queryDescriptors: [
                HKQueryDescriptor(sampleType: T.steps, predicate: HKQuery.predicateForSamples(withStart: T.at(0), end: T.at(1))),
                HKQueryDescriptor(sampleType: T.sleep, predicate: nil),
            ], limit: 0) { _, s, _ in
                box.withLock { $0 = s ?? [] }
                done()
            }
        }
        #expect(box.current.count == 4 + 4)
    }

    @Test("correlation query with sample predicates (interface.md §3)")
    func correlationQuery() async throws {
        let g = try await Golden.make()
        func run(_ threshold: Double) async -> Int {
            let box = Locked(-1)
            await g.a.run { done in
                HKCorrelationQuery(type: T.bloodPressure, predicate: nil, samplePredicates: [
                    T.systolic: HKQuery.predicateForQuantitySamples(with: .greaterThan,
                                                                     quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: threshold)),
                ]) { _, c, _ in
                    box.withLock { $0 = c?.count ?? -1 }
                    done()
                }
            }
            return box.current
        }
        #expect(await run(110) == 1)
        #expect(await run(130) == 0)
    }

    @Test("source query and own-data visibility with read denied (§7)")
    func sourcesAndVisibility() async throws {
        let g = try await Golden.make(withB: true)
        let b = try #require(g.b)
        func sources(_ store: HKHealthStore, _ type: HKSampleType) async -> Set<String> {
            let box = Locked<Set<String>>([])
            await store.run { done in
                HKSourceQuery(sampleType: type, samplePredicate: nil) { _, s, _ in
                    box.withLock { $0 = Set((s ?? []).map(\.bundleIdentifier)) }
                    done()
                }
            }
            return box.current
        }
        #expect(await sources(b, T.steps) == ["dev.ycode.healthprobe", "dev.ycode.healthprobe.b"])
        #expect(await sources(g.a, T.steps) == ["dev.ycode.healthprobe", "dev.ycode.healthprobe.b"])   // A reads steps too
        #expect(await sources(b, T.sleep) == ["dev.ycode.healthprobe"])
        // B's heart-rate read is off: A's samples are invisible, B's own are visible
        #expect(try await b.count(T.heartRate) == 0)
        try await b.save(T.qs(T.heartRate, 61, T.bpm, T.at(0, 11)))
        #expect(try await b.count(T.heartRate) == 1)
        // B reads A's steps (read granted)
        #expect(try await b.count(T.steps, HKQuery.predicateForObjects(from: T.clientA.source)) == 8)
    }

    @Test("§6.6 historical range: sample queries still return the app's own older samples")
    func historicalRangeSamples() async throws {
        let g = try await Golden.make()
        // A granted "past 30 days" at 2026-10-19 23:55:40Z; the 1811 and D0−60 samples are its own
        #expect(try await g.a.count(T.steps, HKQuery.predicateForSamples(withStart: nil, end: T.at(-30))) == 2)
        let dates = try await g.a.earliestAuthorizedSampleDate(for: [T.steps])
        #expect(dates[T.steps] == T.grantA.addingTimeInterval(-30 * 86400))
    }
}

/// Compound predicate shorthand for the tests.
enum HKCompound {
    static func and(_ p: [NSPredicate]) -> NSPredicate { NSCompoundPredicate(andPredicateWithSubpredicates: p) }
}
