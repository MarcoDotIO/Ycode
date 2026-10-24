import Foundation
import Testing
@testable import HealthKit

/// C-VALIDATE: the exceptions of `errors.md` §3 and the accepted cases. Validation is
/// exercised through the internal throwing entry points; two exit tests check that the
/// public API really traps.
@Suite("C-VALIDATE errors.md §3")
struct ValidationTests {
    let start = T.at(0, 8)

    func expectValidation(_ fragment: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected _HKObjectValidationFailureException (\(fragment))")
        } catch let error as HKRaise {
            #expect(error.name == "_HKObjectValidationFailureException")
            #expect(error.reason.contains(fragment), "\(error.reason)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    func expectInvalidArgument(_ fragment: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected NSInvalidArgumentException (\(fragment))")
        } catch let error as HKRaise {
            #expect(error.name == "NSInvalidArgumentException")
            #expect(error.reason.contains(fragment), "\(error.reason)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("errors.md §3 sample quantity with the wrong dimension")
    func wrongDimension() {
        expectValidation("Incompatible unit: m") {
            _ = try HKQuantitySample.makeRecord(type: T.steps, quantity: HKQuantity(unit: .meter(), doubleValue: 1),
                                                start: start, end: start, device: nil, metadata: nil)
        }
    }

    @Test("errors.md §3 end date before start date")
    func endBeforeStart() {
        expectValidation("startDate cannot occur after endDate") {
            _ = try HKQuantitySample.makeRecord(type: T.steps, quantity: HKQuantity(unit: .count(), doubleValue: 1),
                                                start: start, end: start.addingTimeInterval(-1), device: nil, metadata: nil)
        }
    }

    @Test("errors.md §3 duration above the type maximum (345600 s)")
    func tooLong() {
        expectValidation("345600") {
            _ = try HKQuantitySample.makeRecord(type: T.steps, quantity: HKQuantity(unit: .count(), doubleValue: 1),
                                                start: start, end: start.addingTimeInterval(345_601), device: nil, metadata: nil)
        }
        // exactly the maximum is accepted (the 4-day golden sample)
        #expect((try? HKQuantitySample.makeRecord(type: T.steps, quantity: HKQuantity(unit: .count(), doubleValue: 4),
                                                  start: start, end: start.addingTimeInterval(345_600), device: nil,
                                                  metadata: nil)) != nil)
    }

    @Test("errors.md §3 category value outside the type's enumeration")
    func badCategory() {
        expectValidation("Value 9 is not compatible") {
            _ = try HKCategorySample.makeRecord(type: T.sleep, value: 9, start: start, end: start, device: nil, metadata: nil)
        }
        expectValidation("Value 1 is not compatible") {
            _ = try HKCategorySample.makeRecord(type: T.mindful, value: 1, start: start, end: start, device: nil, metadata: nil)
        }
        #expect((try? HKCategorySample.makeRecord(type: T.c(.headache), value: HKCategoryValueSeverity.severe.rawValue,
                                                  start: start, end: start, device: nil, metadata: nil)) != nil)
    }

    @Test("errors.md §3 metadata value of an unsupported class")
    func badMetadataClass() {
        expectValidation("Invalid metadata value") { _ = try Validation.metadata(["YcodeArray": [1, 2, 3]]) }
    }

    @Test("errors.md §3 known metadata key with the wrong value class")
    func wrongKeyClass() {
        expectValidation("expected NSString") { _ = try Validation.metadata([HKMetadataKeyExternalUUID: 42]) }
    }

    @Test("errors.md §3 sync identifier without sync version")
    func syncWithoutVersion() {
        expectValidation("Sync version must be provided") { _ = try Validation.metadata([HKMetadataKeySyncIdentifier: "x"]) }
    }

    @Test("errors.md §3 blood-pressure correlation needs one systolic and one diastolic")
    func bloodPressureMembers() {
        let sys = T.qs(T.systolic, 120, .millimeterOfMercury(), start)
        let dia = T.qs(T.diastolic, 80, .millimeterOfMercury(), start)
        expectValidation("received 1") {
            _ = try HKCorrelation.makeRecord(type: T.bloodPressure, start: start, end: start, objects: [sys], device: nil, metadata: nil)
        }
        #expect((try? HKCorrelation.makeRecord(type: T.bloodPressure, start: start, end: start, objects: [sys, dia],
                                               device: nil, metadata: nil)) != nil)
    }

    @Test("errors.md §3 statistics option incompatible with the aggregation style")
    func statisticsOptions() {
        expectInvalidArgument("not compatible with cumulative data type") {
            try StatisticsEngine.validate(.discreteAverage, for: T.steps)
        }
        expectInvalidArgument("not compatible with discrete data type") {
            try StatisticsEngine.validate(.cumulativeSum, for: T.heartRate)
        }
        #expect((try? StatisticsEngine.validate([.cumulativeSum, .duration, .mostRecent, .separateBySource], for: T.steps)) != nil)
        #expect((try? StatisticsEngine.validate([.discreteAverage, .discreteMin, .discreteMax, .mostRecent, .duration,
                                                 .separateBySource], for: T.heartRate)) != nil)
        #expect((try? StatisticsEngine.validate([], for: T.steps)) != nil)
    }

    @Test("errors.md §3 authorization requests: empty, non-shareable, non-readable")
    func authorizationRequests() {
        expectInvalidArgument("at least one data type") { try HKHealthStore.validateRequest(share: nil, read: []) }
        // (characteristic types cannot even be passed for sharing in Swift: the share set holds sample types)
        expectInvalidArgument("share the following types is disallowed: HKCorrelationTypeIdentifierBloodPressure") {
            try HKHealthStore.validateRequest(share: [T.bloodPressure], read: nil)
        }
        expectInvalidArgument("read the following types is disallowed: HKCorrelationTypeIdentifierBloodPressure") {
            try HKHealthStore.validateRequest(share: nil, read: [T.bloodPressure])
        }
        expectInvalidArgument("read the following types is disallowed: HKVisionPrescriptionTypeIdentifier") {
            try HKHealthStore.validateRequest(share: nil, read: [HKObjectType.visionPrescriptionType()])
        }
        expectInvalidArgument("share the following types is disallowed: HKCategoryTypeIdentifierAppleStandHour") {
            try HKHealthStore.validateRequest(share: [T.c(.appleStandHour)], read: nil)
        }
        #expect((try? HKHealthStore.validateRequest(share: [HKObjectType.visionPrescriptionType()], read: nil)) != nil)
    }

    @Test("errors.md §3 executing a query twice")
    func executeTwice() throws {
        let store = HKHealthStore(ycodeDaemon: try T.daemon(), client: T.clientA)
        let q = HKSampleQuery(sampleType: T.steps, predicate: nil, limit: 0, sortDescriptors: nil) { _, _, _ in }
        try q.markExecuted(store)
        expectInvalidArgument("has already been executed and cannot be executed again") { try q.markExecuted(store) }
    }

    @Test("errors.md §3 accepted: negative cumulative quantity, unknown HK key, duration on a discrete type")
    func accepted() {
        let neg = T.stepSample(-5, start, start.addingTimeInterval(60))
        #expect(neg.quantity.doubleValue(for: .count()) == -5)
        let md = T.stepSample(1, start, start, ["HKSomethingPrivate": "x"])
        #expect(md.metadata?["HKSomethingPrivate"] as? String == "x")
        let mass = T.qs(T.bodyMass, 70, .gramUnit(with: .kilo), start, start.addingTimeInterval(600))
        #expect(mass.endDate.timeIntervalSince(mass.startDate) == 600)
        #expect(T.q(.heartRate).maximumAllowedDuration == 345600)
        #expect(T.c(.lactation).maximumAllowedDuration == 0)
    }

    @Test("interface.md §3 sample classes, metadata round trip and equality by UUID")
    func objects() throws {
        let s = T.stepSample(10, start, start.addingTimeInterval(60), [
            "s": "text", "i": 42, "d": 2.5, "b": true, "date": T.d0, "q": HKQuantity(unit: .meter(), doubleValue: 3),
        ])
        #expect(s is HKCumulativeQuantitySample)
        #expect(T.qs(T.heartRate, 60, T.bpm, start) is HKDiscreteQuantitySample)
        #expect(s.metadata?["s"] as? String == "text")
        #expect(s.metadata?["i"] as? Int == 42)
        #expect(s.metadata?["d"] as? Double == 2.5)
        #expect(s.metadata?["b"] as? Bool == true)
        #expect(s.metadata?["date"] as? Date == T.d0)
        #expect((s.metadata?["q"] as? HKQuantity)?.description == "3 m")
        #expect(s.count == 1)
        #expect(s.device == nil)
        let data = try NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: true)
        let back = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKCumulativeQuantitySample.self, from: data))
        #expect(back == s)
        #expect(back.uuid == s.uuid)
        #expect(back.quantity == s.quantity)
        #expect(T.stepSample(10, start, start) != T.stepSample(10, start, start))
        let disc = try #require(T.qs(T.heartRate, 72, T.bpm, start) as? HKDiscreteQuantitySample)
        #expect(disc.averageQuantity == disc.quantity && disc.mostRecentQuantityDateInterval.start == start)
    }

    #if !os(Windows)
    @Test("errors.md §3 the public API traps (uncaught exception)")
    func publicAPITraps() async {
        await #expect(processExitsWith: .failure) {
            _ = HKUnit(from: "KG")
        }
        await #expect(processExitsWith: .failure) {
            _ = HKQuantitySample(type: HKQuantityType(.stepCount), quantity: HKQuantity(unit: .meter(), doubleValue: 1),
                                 start: Date(), end: Date())
        }
    }
    #endif
}
