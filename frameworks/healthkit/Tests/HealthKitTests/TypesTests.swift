import Foundation
import Testing
@testable import HealthKit

/// C-TYPES: every identifier of `identifiers.md` (value, class, aggregation, dimension,
/// duration limits, per-object flag) and the interning rules of `interface.md` §2.
@Suite("C-TYPES identifiers.md")
struct TypesTests {
    @Test("identifiers.md Quantity types (121): class, style, dimension, limits")
    func quantityTypes() {
        #expect(quantityTypeTable.count == 121)
        for spec in quantityTypeTable {
            guard let t = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: spec.identifier)) else {
                Issue.record("missing \(spec.identifier)")
                continue
            }
            #expect(t.identifier == spec.identifier)
            #expect(t.description == spec.identifier)
            #expect(t.aggregationStyle == spec.style)
            #expect(t.isMaximumDurationRestricted == (spec.maximumDuration != nil))
            #expect(t.maximumAllowedDuration == (spec.maximumDuration ?? 0))
            #expect(t.isMinimumDurationRestricted == (spec.minimumDuration != nil))
            #expect(!t.requiresPerObjectAuthorization())
        }
        let steps = HKQuantityType(.stepCount)
        #expect(steps.aggregationStyle == .cumulative)
        #expect(steps.is(compatibleWith: .count()))
        #expect(!steps.is(compatibleWith: .meter()))
        #expect(HKQuantityType(.heartRate).aggregationStyle == .discreteTemporallyWeighted)
        #expect(HKQuantityType(.heartRate).is(compatibleWith: HKUnit(from: "count/min")))
        #expect(HKQuantityType(.bodyTemperature).aggregationStyle == .discreteArithmetic)
        #expect(HKQuantityType(.environmentalAudioExposure).aggregationStyle == .discreteEquivalentContinuousLevel)
        #expect(HKQuantityType(.environmentalAudioExposure).isMinimumDurationRestricted)
        #expect(HKQuantityType(.bloodGlucose).is(compatibleWith: HKUnit(from: "mg/dL")))
        #expect(HKQuantityType(.bloodGlucose).is(compatibleWith: HKUnit(from: "mmol<180.15588000005408>/L")))
        #expect(HKQuantityType(.vo2Max).is(compatibleWith: HKUnit(from: "mL/(kg*min)")))
        #expect(HKQuantityType(.physicalEffort).is(compatibleWith: HKUnit(from: "kcal/(kg*hr)")))
        #expect(HKQuantityType(.walkingSpeed).is(compatibleWith: HKUnit(from: "m/s")))
        #expect(HKQuantityType(.peakExpiratoryFlowRate).is(compatibleWith: HKUnit(from: "L/min")))
        #expect(HKQuantityType(.atrialFibrillationBurden).maximumAllowedDuration == 691200)
    }

    @Test("identifiers.md every quantity dimension accepts its reference unit")
    func dimensions() {
        let reference: [QuantityDimension: String] = [
            .scalar: "count", .mass: "g", .length: "m", .volume: "L", .time: "s", .energy: "kcal", .temperature: "degC",
            .pressure: "mmHg", .speed: "m/s", .frequency: "count/min", .power: "W", .conductance: "S",
            .soundPressureLevel: "dBASPL", .effortScore: "appleEffortScore", .pharmacology: "IU", .volumeFlow: "L/min",
            .energyRatePerMass: "kcal/(kg*hr)", .vo2Rate: "mL/(kg*min)", .massConcentration: "mg/dL",
        ]
        for spec in quantityTypeTable {
            let t = HKQuantityType(HKQuantityTypeIdentifier(rawValue: spec.identifier))
            #expect(t.is(compatibleWith: HKUnit(from: reference[spec.dimension]!)), "\(spec.identifier)")
        }
    }

    @Test("identifiers.md other kinds: class, string value, limits, per-object")
    func otherTypes() {
        #expect(HKCategoryType(.environmentalAudioExposureEvent).identifier == "HKCategoryTypeIdentifierAudioExposureEvent")
        for spec in otherTypeTable {
            let t = TypeRegistry.type(spec.identifier)
            switch spec.kind {
            case .category: #expect(t is HKCategoryType)
            case .characteristic: #expect(t is HKCharacteristicType)
            case .correlation: #expect(t is HKCorrelationType)
            case .document: #expect(t is HKDocumentType)
            case .clinical: #expect(t is HKClinicalType)
            case .scoredAssessment: #expect(t is HKScoredAssessmentType)
            default: Issue.record("unexpected kind")
            }
            #expect(t?.requiresPerObjectAuthorization() == spec.perObject)
            if let s = t as? HKSampleType {
                #expect(s.isMaximumDurationRestricted == (spec.maximumDuration != nil))
                #expect(s.maximumAllowedDuration == (spec.maximumDuration ?? 0))
            }
        }
        #expect(HKCategoryType(.menopausalState).maximumAllowedDuration == 0)
        #expect(HKCategoryType(.menopausalState).isMaximumDurationRestricted)
        #expect(!HKCategoryType(.pregnancy).isMaximumDurationRestricted)
        #expect(HKCategoryType(.pregnancy).maximumAllowedDuration == 0)   // reading it does not raise
        #expect(HKCategoryType(.mindfulSession).maximumAllowedDuration == 2_419_200)
        #expect(HKObjectType.documentType(forIdentifier: .CDA)?.requiresPerObjectAuthorization() == true)
        #expect(HKObjectType.visionPrescriptionType().requiresPerObjectAuthorization())
        #expect(HKObjectType.userAnnotatedMedicationType().requiresPerObjectAuthorization())
        #expect(!HKObjectType.workoutType().requiresPerObjectAuthorization())
    }

    @Test("interface.md §2 duration-limit census: 166 identifiers at 4 days, 21 at 14 days, 7 unrestricted categories")
    func durationCensus() {
        let sampleTypes = TypeRegistry.all.values.compactMap { $0 as? HKSampleType }
        // 166 identifier rows; the deprecated audio-exposure-event alias shares its string value, so 165 types.
        #expect(sampleTypes.filter { $0.isMaximumDurationRestricted && $0.maximumAllowedDuration == 345600 }.count == 165)
        #expect(sampleTypes.filter { $0.maximumAllowedDuration == 1_209_600 }.count == 21)
        #expect(otherTypeTable.filter { $0.kind == .category && $0.maximumDuration == nil }.count == 7)
        #expect(otherTypeTable.filter { $0.kind == .category }.count == 71)
    }

    @Test("interface.md §2 interning and nil for unknown or wrong-kind identifiers")
    func interning() {
        let a = HKObjectType.quantityType(forIdentifier: .stepCount)
        let b = HKObjectType.quantityType(forIdentifier: .stepCount)
        #expect(a === b)
        #expect(a?.hash == b?.hash)
        #expect(HKQuantityType(.stepCount) === a)
        #expect(HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifierBogus")) == nil)
        #expect(HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: HKQuantityTypeIdentifier.stepCount.rawValue)) == nil)
        #expect(HKObjectType.workoutType().identifier == "HKWorkoutTypeIdentifier")
        #expect(HKObjectType.workoutType() === HKWorkoutType())
        #expect(HKSeriesType.workoutRoute().identifier == "HKWorkoutRouteTypeIdentifier")
        #expect(HKSeriesType.heartbeat().identifier == "HKDataTypeIdentifierHeartbeatSeries")
        #expect(HKObjectType.stateOfMindType().identifier == "HKDataTypeStateOfMind")
        #expect(HKObjectType.seriesType(forIdentifier: HKWorkoutRouteTypeIdentifier) === HKSeriesType.workoutRoute())
        #expect(HKObjectType.characteristicType(forIdentifier: .biologicalSex) != nil)
        #expect(HKObjectType.correlationType(forIdentifier: .bloodPressure)?.identifier == "HKCorrelationTypeIdentifierBloodPressure")
    }

    @Test("identifiers.md string constants and enumeration raw values")
    func constants() {
        #expect(HKMetadataKeyExternalUUID == "HKExternalUUID")
        #expect(HKMetadataKeySyncIdentifier == "HKMetadataKeySyncIdentifier")
        #expect(HKMetadataKeyWasUserEntered == "HKWasUserEntered")
        #expect(HKPredicateKeyPathStartDate == "startDate")
        #expect(HKPredicateKeyPathCategoryValue == "value")
        #expect(HKSampleSortIdentifierEndDate == "endDate")
        #expect(HKErrorDomain == "com.apple.healthkit")
        #expect(HKDevicePropertyKeyName == "HKDevicePropertyName")
        #expect(HKCategoryValueSleepAnalysis.asleepREM.rawValue == 5)
        #expect(HKCategoryValueSleepAnalysis.inBed.rawValue == 0)
        #expect(HKBloodType.abNegative.rawValue == 6)
        #expect(HKFitzpatrickSkinType.VI.rawValue == 6)
        #expect(HKWorkoutActivityType.running.rawValue == 37)
        #expect(HKWorkoutActivityType.walking.rawValue == 52)
        #expect(HKWorkoutActivityType.other.rawValue == 3000)
        #expect(HKWorkoutActivityType.allCases.count == 84)   // 86 cases, two unavailable on iOS
        #expect(HKWorkoutEventType.pauseOrResumeRequest.rawValue == 8)
        #expect(HKStatisticsOptions.duration.rawValue == 64)
        #expect(HKStatisticsOptions.mostRecent.rawValue == 32)
        #expect(HKQueryOptions.strictEndDate.rawValue == 2)
        #expect(HKUpdateFrequency.weekly.rawValue == 4)
        #expect(HKAuthorizationRequestStatus.unnecessary.rawValue == 2)
        #expect(HKError.Code.errorNoData.rawValue == 11)
        #expect(HKWorkoutSessionState.prepared.rawValue == 5)
        #expect(HKCategoryValueSleepAnalysis.allAsleepValues == [.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM])
    }

    @Test("interface.md §2 secure coding keeps the type")
    func coding() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: HKQuantityType(.heartRate), requiringSecureCoding: true)
        let back = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQuantityType.self, from: data))
        #expect(back == HKQuantityType(.heartRate))
        #expect(back.aggregationStyle == .discreteTemporallyWeighted)
    }
}
