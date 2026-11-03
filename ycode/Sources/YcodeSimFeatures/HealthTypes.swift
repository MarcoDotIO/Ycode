// The HealthKit type table of Ycode's health tools (specs/simulator/
// health-simulation.md §3, §8.3 H-9): per sample type its kind, unit
// dimension, aggregation, duration limits, whether apps may save it, the
// category values it allows and the metadata it requires. The rows are
// `specs/frameworks/healthkit/identifiers.md`'s quantity and category tables
// (generated from them; identifiers and limits are interop facts), the
// read-only list is health-simulation.md §3.2, the store codes and units are
// §3.1 and §6.3.

import Foundation

/// The unit family a quantity type accepts (identifiers.md "dimension").
public enum HealthDimension: String, Sendable, CaseIterable {
    case energy, time, scalar, temperature, massConcentration, pressure, mass, speed, frequency, power, volume, length
    case conductance, soundPressureLevel, effortScore, pharmacology, volumeFlow, energyRatePerMass, vo2Rate
}

public enum HealthTypeKind: String, Sendable {
    case quantity, category, workout, other
}

public struct HealthType: Sendable, Equatable {
    public let identifier: String
    public let kind: HealthTypeKind
    /// Quantities: the accepted unit family.
    public let dimension: HealthDimension?
    public let cumulative: Bool
    public let maximumDuration: Double?
    public let minimumDuration: Double?
    /// Whether an app may save it (false: the 26 read-only types, §3.2).
    public let writable: Bool
    /// Categories: the allowed values (nil: any integer ≥ 0 is not checked).
    public let categoryValues: [Int]?
    /// Categories: the value names (`HKCategoryValueSleepAnalysisAsleepCore`) → value.
    public let categoryNames: [String: Int]
    /// Metadata keys a sample must carry (§3.3; the public documentation).
    public let requiredMetadata: [String]
    /// The store's type code (§6.3), where known.
    public let storeCode: Int?
    /// The unit the store keeps the quantity in (§3.1), where known.
    public let storeUnit: String?

    /// The identifier without its `HK…TypeIdentifier` prefix (`HeartRate`).
    public var shortName: String {
        for p in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKDataTypeIdentifier"] where identifier.hasPrefix(p) {
            return String(identifier.dropFirst(p.count))
        }
        return identifier
    }
}

public enum HealthTypes {
    // (identifier, dimension, cumulative, maximum duration s, minimum duration s)
    static let quantityRows: [(String, HealthDimension, Bool, Double?, Double?)] = [
        ("HKQuantityTypeIdentifierActiveEnergyBurned", .energy, true, 345600, nil),
        ("HKQuantityTypeIdentifierAppleExerciseTime", .time, true, 345600, nil),
        ("HKQuantityTypeIdentifierAppleMoveTime", .time, true, 345600, nil),
        ("HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierAppleSleepingWristTemperature", .temperature, false, 345600, nil),
        ("HKQuantityTypeIdentifierAppleStandTime", .time, true, 345600, nil),
        ("HKQuantityTypeIdentifierAppleWalkingSteadiness", .scalar, false, 864000, nil),
        ("HKQuantityTypeIdentifierAtrialFibrillationBurden", .scalar, false, 691200, nil),
        ("HKQuantityTypeIdentifierBasalBodyTemperature", .temperature, false, 345600, nil),
        ("HKQuantityTypeIdentifierBasalEnergyBurned", .energy, true, 345600, nil),
        ("HKQuantityTypeIdentifierBloodAlcoholContent", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierBloodGlucose", .massConcentration, false, 345600, nil),
        ("HKQuantityTypeIdentifierBloodPressureDiastolic", .pressure, false, 345600, nil),
        ("HKQuantityTypeIdentifierBloodPressureSystolic", .pressure, false, 345600, nil),
        ("HKQuantityTypeIdentifierBodyFatPercentage", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierBodyMass", .mass, false, 345600, nil),
        ("HKQuantityTypeIdentifierBodyMassIndex", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierBodyTemperature", .temperature, false, 345600, nil),
        ("HKQuantityTypeIdentifierCrossCountrySkiingSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierCyclingCadence", .frequency, false, 345600, nil),
        ("HKQuantityTypeIdentifierCyclingFunctionalThresholdPower", .power, false, 345600, nil),
        ("HKQuantityTypeIdentifierCyclingPower", .power, false, 345600, nil),
        ("HKQuantityTypeIdentifierCyclingSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryBiotin", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryCaffeine", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryCalcium", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryCarbohydrates", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryChloride", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryCholesterol", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryChromium", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryCopper", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryEnergyConsumed", .energy, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryFatMonounsaturated", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryFatPolyunsaturated", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryFatSaturated", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryFatTotal", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryFiber", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryFolate", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryIodine", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryIron", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryMagnesium", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryManganese", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryMolybdenum", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryNiacin", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryPantothenicAcid", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryPhosphorus", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryPotassium", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryProtein", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryRiboflavin", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietarySelenium", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietarySodium", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietarySugar", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryThiamin", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminA", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminB12", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminB6", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminC", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminD", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminE", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryVitaminK", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryWater", .volume, true, 345600, nil),
        ("HKQuantityTypeIdentifierDietaryZinc", .mass, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceCrossCountrySkiing", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceCycling", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceDownhillSnowSports", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistancePaddleSports", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceRowing", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceSkatingSports", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceSwimming", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceWalkingRunning", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierDistanceWheelchair", .length, true, 345600, nil),
        ("HKQuantityTypeIdentifierElectrodermalActivity", .conductance, false, 345600, nil),
        ("HKQuantityTypeIdentifierEnvironmentalAudioExposure", .soundPressureLevel, false, 345600, 0),
        ("HKQuantityTypeIdentifierEnvironmentalSoundReduction", .soundPressureLevel, false, 345600, nil),
        ("HKQuantityTypeIdentifierEstimatedWorkoutEffortScore", .effortScore, false, 345600, nil),
        ("HKQuantityTypeIdentifierFlightsClimbed", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierForcedExpiratoryVolume1", .volume, false, 345600, nil),
        ("HKQuantityTypeIdentifierForcedVitalCapacity", .volume, false, 345600, nil),
        ("HKQuantityTypeIdentifierHeadphoneAudioExposure", .soundPressureLevel, false, 345600, 0),
        ("HKQuantityTypeIdentifierHeartRate", .frequency, false, 345600, nil),
        ("HKQuantityTypeIdentifierHeartRateRecoveryOneMinute", .frequency, false, 345600, nil),
        ("HKQuantityTypeIdentifierHeartRateVariabilityRMSSD", .time, false, 345600, nil),
        ("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", .time, false, 345600, nil),
        ("HKQuantityTypeIdentifierHeight", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierInhalerUsage", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierInsulinDelivery", .pharmacology, true, 345600, nil),
        ("HKQuantityTypeIdentifierLeanBodyMass", .mass, false, 345600, nil),
        ("HKQuantityTypeIdentifierNikeFuel", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierNumberOfAlcoholicBeverages", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierNumberOfTimesFallen", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierOxygenSaturation", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierPaddleSportsSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierPeakExpiratoryFlowRate", .volumeFlow, false, 345600, nil),
        ("HKQuantityTypeIdentifierPeripheralPerfusionIndex", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierPhysicalEffort", .energyRatePerMass, false, 345600, nil),
        ("HKQuantityTypeIdentifierPushCount", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierRespiratoryRate", .frequency, false, 345600, nil),
        ("HKQuantityTypeIdentifierRestingHeartRate", .frequency, false, 345600, nil),
        ("HKQuantityTypeIdentifierRowingSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierRunningGroundContactTime", .time, false, 345600, nil),
        ("HKQuantityTypeIdentifierRunningPower", .power, false, 345600, nil),
        ("HKQuantityTypeIdentifierRunningSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierRunningStrideLength", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierRunningVerticalOscillation", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierSixMinuteWalkTestDistance", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierStairAscentSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierStairDescentSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierStepCount", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierSwimmingStrokeCount", .scalar, true, 345600, nil),
        ("HKQuantityTypeIdentifierTimeInDaylight", .time, true, 345600, nil),
        ("HKQuantityTypeIdentifierUVExposure", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierUnderwaterDepth", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierVO2Max", .vo2Rate, false, 345600, nil),
        ("HKQuantityTypeIdentifierWaistCircumference", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierWalkingAsymmetryPercentage", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierWalkingDoubleSupportPercentage", .scalar, false, 345600, nil),
        ("HKQuantityTypeIdentifierWalkingHeartRateAverage", .frequency, false, 345600, nil),
        ("HKQuantityTypeIdentifierWalkingSpeed", .speed, false, 345600, nil),
        ("HKQuantityTypeIdentifierWalkingStepLength", .length, false, 345600, nil),
        ("HKQuantityTypeIdentifierWaterTemperature", .temperature, false, 345600, nil),
        ("HKQuantityTypeIdentifierWorkoutEffortScore", .effortScore, false, 345600, nil),
    ]
    // (identifier, string value, maximum duration s)
    static let categoryRows: [(String, String, Double?)] = [
        ("HKCategoryTypeIdentifierAbdominalCramps", "HKCategoryTypeIdentifierAbdominalCramps", 1209600),
        ("HKCategoryTypeIdentifierAcne", "HKCategoryTypeIdentifierAcne", 1209600),
        ("HKCategoryTypeIdentifierAppetiteChanges", "HKCategoryTypeIdentifierAppetiteChanges", 1209600),
        ("HKCategoryTypeIdentifierAppleStandHour", "HKCategoryTypeIdentifierAppleStandHour", 345600),
        ("HKCategoryTypeIdentifierAppleWalkingSteadinessEvent", "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent", 864000),
        ("HKCategoryTypeIdentifierAudioExposureEvent", "HKCategoryTypeIdentifierAudioExposureEvent", 345600),
        ("HKCategoryTypeIdentifierBladderIncontinence", "HKCategoryTypeIdentifierBladderIncontinence", 345600),
        ("HKCategoryTypeIdentifierBleedingAfterMenopause", "HKCategoryTypeIdentifierBleedingAfterMenopause", nil),
        ("HKCategoryTypeIdentifierBleedingAfterPregnancy", "HKCategoryTypeIdentifierBleedingAfterPregnancy", nil),
        ("HKCategoryTypeIdentifierBleedingDuringPregnancy", "HKCategoryTypeIdentifierBleedingDuringPregnancy", nil),
        ("HKCategoryTypeIdentifierBloating", "HKCategoryTypeIdentifierBloating", 1209600),
        ("HKCategoryTypeIdentifierBreastPain", "HKCategoryTypeIdentifierBreastPain", 1209600),
        ("HKCategoryTypeIdentifierCervicalMucusQuality", "HKCategoryTypeIdentifierCervicalMucusQuality", 1209600),
        ("HKCategoryTypeIdentifierChestTightnessOrPain", "HKCategoryTypeIdentifierChestTightnessOrPain", 345600),
        ("HKCategoryTypeIdentifierChills", "HKCategoryTypeIdentifierChills", 345600),
        ("HKCategoryTypeIdentifierConstipation", "HKCategoryTypeIdentifierConstipation", 1209600),
        ("HKCategoryTypeIdentifierContraceptive", "HKCategoryTypeIdentifierContraceptive", nil),
        ("HKCategoryTypeIdentifierCoughing", "HKCategoryTypeIdentifierCoughing", 345600),
        ("HKCategoryTypeIdentifierDiarrhea", "HKCategoryTypeIdentifierDiarrhea", 1209600),
        ("HKCategoryTypeIdentifierDizziness", "HKCategoryTypeIdentifierDizziness", 345600),
        ("HKCategoryTypeIdentifierDrySkin", "HKCategoryTypeIdentifierDrySkin", 345600),
        ("HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent", "HKCategoryTypeIdentifierAudioExposureEvent", 345600),
        ("HKCategoryTypeIdentifierFainting", "HKCategoryTypeIdentifierFainting", 345600),
        ("HKCategoryTypeIdentifierFatigue", "HKCategoryTypeIdentifierFatigue", 1209600),
        ("HKCategoryTypeIdentifierFever", "HKCategoryTypeIdentifierFever", 345600),
        ("HKCategoryTypeIdentifierGeneralizedBodyAche", "HKCategoryTypeIdentifierGeneralizedBodyAche", 345600),
        ("HKCategoryTypeIdentifierHairLoss", "HKCategoryTypeIdentifierHairLoss", 345600),
        ("HKCategoryTypeIdentifierHandwashingEvent", "HKCategoryTypeIdentifierHandwashingEvent", 345600),
        ("HKCategoryTypeIdentifierHeadache", "HKCategoryTypeIdentifierHeadache", 1209600),
        ("HKCategoryTypeIdentifierHeadphoneAudioExposureEvent", "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent", 691200),
        ("HKCategoryTypeIdentifierHeartburn", "HKCategoryTypeIdentifierHeartburn", 345600),
        ("HKCategoryTypeIdentifierHighHeartRateEvent", "HKCategoryTypeIdentifierHighHeartRateEvent", 345600),
        ("HKCategoryTypeIdentifierHotFlashes", "HKCategoryTypeIdentifierHotFlashes", 1209600),
        ("HKCategoryTypeIdentifierHypertensionEvent", "HKCategoryTypeIdentifierHypertensionEvent", 2678400),
        ("HKCategoryTypeIdentifierInfrequentMenstrualCycles", "HKCategoryTypeIdentifierInfrequentMenstrualCycles", 31536000),
        ("HKCategoryTypeIdentifierIntermenstrualBleeding", "HKCategoryTypeIdentifierIntermenstrualBleeding", 1209600),
        ("HKCategoryTypeIdentifierIrregularHeartRhythmEvent", "HKCategoryTypeIdentifierIrregularHeartRhythmEvent", 345600),
        ("HKCategoryTypeIdentifierIrregularMenstrualCycles", "HKCategoryTypeIdentifierIrregularMenstrualCycles", 31536000),
        ("HKCategoryTypeIdentifierLactation", "HKCategoryTypeIdentifierLactation", nil),
        ("HKCategoryTypeIdentifierLossOfSmell", "HKCategoryTypeIdentifierLossOfSmell", 345600),
        ("HKCategoryTypeIdentifierLossOfTaste", "HKCategoryTypeIdentifierLossOfTaste", 345600),
        ("HKCategoryTypeIdentifierLowCardioFitnessEvent", "HKCategoryTypeIdentifierLowCardioFitnessEvent", 7344000),
        ("HKCategoryTypeIdentifierLowHeartRateEvent", "HKCategoryTypeIdentifierLowHeartRateEvent", 345600),
        ("HKCategoryTypeIdentifierLowerBackPain", "HKCategoryTypeIdentifierLowerBackPain", 1209600),
        ("HKCategoryTypeIdentifierMemoryLapse", "HKCategoryTypeIdentifierMemoryLapse", 345600),
        ("HKCategoryTypeIdentifierMenopausalState", "HKCategoryTypeIdentifierMenopausalState", 0),
        ("HKCategoryTypeIdentifierMenstrualFlow", "HKCategoryTypeIdentifierMenstrualFlow", nil),
        ("HKCategoryTypeIdentifierMindfulSession", "HKCategoryTypeIdentifierMindfulSession", 2419200),
        ("HKCategoryTypeIdentifierMoodChanges", "HKCategoryTypeIdentifierMoodChanges", 1209600),
        ("HKCategoryTypeIdentifierNausea", "HKCategoryTypeIdentifierNausea", 1209600),
        ("HKCategoryTypeIdentifierNightSweats", "HKCategoryTypeIdentifierNightSweats", 345600),
        ("HKCategoryTypeIdentifierOvulationTestResult", "HKCategoryTypeIdentifierOvulationTestResult", 1209600),
        ("HKCategoryTypeIdentifierPelvicPain", "HKCategoryTypeIdentifierPelvicPain", 1209600),
        ("HKCategoryTypeIdentifierPersistentIntermenstrualBleeding", "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding", 31536000),
        ("HKCategoryTypeIdentifierPregnancy", "HKCategoryTypeIdentifierPregnancy", nil),
        ("HKCategoryTypeIdentifierPregnancyTestResult", "HKCategoryTypeIdentifierPregnancyTestResult", 1209600),
        ("HKCategoryTypeIdentifierProgesteroneTestResult", "HKCategoryTypeIdentifierProgesteroneTestResult", 1209600),
        ("HKCategoryTypeIdentifierProlongedMenstrualPeriods", "HKCategoryTypeIdentifierProlongedMenstrualPeriods", 31536000),
        ("HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat", "HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat", 345600),
        ("HKCategoryTypeIdentifierRunnyNose", "HKCategoryTypeIdentifierRunnyNose", 345600),
        ("HKCategoryTypeIdentifierSexualActivity", "HKCategoryTypeIdentifierSexualActivity", 1209600),
        ("HKCategoryTypeIdentifierShortnessOfBreath", "HKCategoryTypeIdentifierShortnessOfBreath", 345600),
        ("HKCategoryTypeIdentifierSinusCongestion", "HKCategoryTypeIdentifierSinusCongestion", 345600),
        ("HKCategoryTypeIdentifierSkippedHeartbeat", "HKCategoryTypeIdentifierSkippedHeartbeat", 345600),
        ("HKCategoryTypeIdentifierSleepAnalysis", "HKCategoryTypeIdentifierSleepAnalysis", 345600),
        ("HKCategoryTypeIdentifierSleepApneaEvent", "HKCategoryTypeIdentifierSleepApneaEvent", 2678400),
        ("HKCategoryTypeIdentifierSleepChanges", "HKCategoryTypeIdentifierSleepChanges", 1209600),
        ("HKCategoryTypeIdentifierSoreThroat", "HKCategoryTypeIdentifierSoreThroat", 345600),
        ("HKCategoryTypeIdentifierToothbrushingEvent", "HKCategoryTypeIdentifierToothbrushingEvent", 345600),
        ("HKCategoryTypeIdentifierVaginalDryness", "HKCategoryTypeIdentifierVaginalDryness", 345600),
        ("HKCategoryTypeIdentifierVomiting", "HKCategoryTypeIdentifierVomiting", 345600),
        ("HKCategoryTypeIdentifierWheezing", "HKCategoryTypeIdentifierWheezing", 345600),
    ]

    /// The 26 types apps may read but not save (health-simulation.md §3.2).
    public static let readOnly: Set<String> = [
        "HKQuantityTypeIdentifierAppleExerciseTime", "HKQuantityTypeIdentifierAppleMoveTime", "HKQuantityTypeIdentifierAppleStandTime",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature", "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances",
        "HKQuantityTypeIdentifierAppleWalkingSteadiness", "HKQuantityTypeIdentifierAtrialFibrillationBurden",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage", "HKQuantityTypeIdentifierWalkingAsymmetryPercentage", "HKQuantityTypeIdentifierNikeFuel",
        "HKCategoryTypeIdentifierAppleStandHour", "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent",
        "HKCategoryTypeIdentifierAudioExposureEvent", "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent",
        "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent", "HKCategoryTypeIdentifierHighHeartRateEvent",
        "HKCategoryTypeIdentifierLowHeartRateEvent", "HKCategoryTypeIdentifierIrregularHeartRhythmEvent",
        "HKCategoryTypeIdentifierLowCardioFitnessEvent", "HKCategoryTypeIdentifierHypertensionEvent", "HKCategoryTypeIdentifierSleepApneaEvent",
        "HKCategoryTypeIdentifierInfrequentMenstrualCycles", "HKCategoryTypeIdentifierIrregularMenstrualCycles",
        "HKCategoryTypeIdentifierProlongedMenstrualPeriods", "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding",
        ecg, "HKActivitySummaryTypeIdentifier",
    ]

    public static let ecg = "HKDataTypeIdentifierElectrocardiogram"
    public static let workout = "HKWorkoutTypeIdentifier"
    public static let workoutRoute = "HKWorkoutRouteTypeIdentifier"

    /// Store type codes seen (health-simulation.md §6.3).
    public static let storeCodes: [String: Int] = [
        "HKQuantityTypeIdentifierHeartRate": 5, "HKQuantityTypeIdentifierStepCount": 7, "HKQuantityTypeIdentifierDistanceWalkingRunning": 8,
        "HKQuantityTypeIdentifierActiveEnergyBurned": 10, "HKQuantityTypeIdentifierOxygenSaturation": 14,
        "HKCategoryTypeIdentifierSleepAnalysis": 63, workout: 79, "HKCategoryTypeIdentifierHighHeartRateEvent": 140, ecg: 144,
        "HKCategoryTypeIdentifierIrregularHeartRhythmEvent": 156, "HKQuantityTypeIdentifierAtrialFibrillationBurden": 248,
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": 256, "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances": 275,
        "HKCategoryTypeIdentifierSleepApneaEvent": 276,
    ]

    /// Store units (health-simulation.md §3.1 "Kind, store unit"; §6.2: heart rate in count/s).
    public static let storeUnits: [String: String] = [
        "HKQuantityTypeIdentifierHeartRate": "count/s", "HKQuantityTypeIdentifierRestingHeartRate": "count/min",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage": "count/min", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "ms",
        "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD": "ms", "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute": "count/min",
        "HKQuantityTypeIdentifierOxygenSaturation": "%", "HKQuantityTypeIdentifierRespiratoryRate": "count/min",
        "HKQuantityTypeIdentifierStepCount": "count", "HKQuantityTypeIdentifierDistanceWalkingRunning": "m",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "kcal", "HKQuantityTypeIdentifierBasalEnergyBurned": "kcal",
        "HKQuantityTypeIdentifierFlightsClimbed": "count", "HKQuantityTypeIdentifierAppleExerciseTime": "min",
        "HKQuantityTypeIdentifierAppleStandTime": "min", "HKQuantityTypeIdentifierAppleMoveTime": "min",
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances": "count", "HKQuantityTypeIdentifierAtrialFibrillationBurden": "%",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": "degC", "HKQuantityTypeIdentifierBodyTemperature": "degC",
        "HKQuantityTypeIdentifierBasalBodyTemperature": "degC", "HKQuantityTypeIdentifierEnvironmentalAudioExposure": "dBASPL",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure": "dBASPL", "HKQuantityTypeIdentifierVO2Max": "mL/(kg*min)",
    ]

    // Category value sets (identifiers.md "Enumerations"; which enumeration a
    // type takes is the public documentation's).
    static let notApplicable = ["HKCategoryValueNotApplicable": 0]
    static let severity = ["HKCategoryValueSeverityUnspecified": 0, "HKCategoryValueSeverityNotPresent": 1, "HKCategoryValueSeverityMild": 2,
                           "HKCategoryValueSeverityModerate": 3, "HKCategoryValueSeveritySevere": 4]
    static let presence = ["HKCategoryValuePresencePresent": 0, "HKCategoryValuePresenceNotPresent": 1]
    static let vaginalBleeding = ["HKCategoryValueVaginalBleedingUnspecified": 1, "HKCategoryValueVaginalBleedingLight": 2,
                                  "HKCategoryValueVaginalBleedingMedium": 3, "HKCategoryValueVaginalBleedingHeavy": 4,
                                  "HKCategoryValueVaginalBleedingNone": 5]
    public static let sleepValues = ["HKCategoryValueSleepAnalysisInBed": 0, "HKCategoryValueSleepAnalysisAsleepUnspecified": 1,
                                     "HKCategoryValueSleepAnalysisAsleep": 1, "HKCategoryValueSleepAnalysisAwake": 2,
                                     "HKCategoryValueSleepAnalysisAsleepCore": 3, "HKCategoryValueSleepAnalysisAsleepDeep": 4,
                                     "HKCategoryValueSleepAnalysisAsleepREM": 5]
    static let presenceTypes: Set<String> = ["MoodChanges", "SleepChanges"]
    static let notApplicableTypes: Set<String> = [
        "MindfulSession", "SexualActivity", "HandwashingEvent", "ToothbrushingEvent", "HighHeartRateEvent", "LowHeartRateEvent",
        "IrregularHeartRhythmEvent", "IntermenstrualBleeding", "Lactation", "Pregnancy", "InfrequentMenstrualCycles",
        "IrregularMenstrualCycles", "ProlongedMenstrualPeriods", "PersistentIntermenstrualBleeding", "SleepApneaEvent", "HypertensionEvent",
    ]
    static let ownValues: [String: [String: Int]] = [
        "SleepAnalysis": sleepValues,
        "AppleStandHour": ["HKCategoryValueAppleStandHourStood": 0, "HKCategoryValueAppleStandHourIdle": 1],
        "AppetiteChanges": ["HKCategoryValueAppetiteChangesUnspecified": 0, "HKCategoryValueAppetiteChangesNoChange": 1,
                            "HKCategoryValueAppetiteChangesDecreased": 2, "HKCategoryValueAppetiteChangesIncreased": 3],
        "AppleWalkingSteadinessEvent": ["HKCategoryValueAppleWalkingSteadinessEventInitialLow": 1,
                                        "HKCategoryValueAppleWalkingSteadinessEventInitialVeryLow": 2,
                                        "HKCategoryValueAppleWalkingSteadinessEventRepeatLow": 3,
                                        "HKCategoryValueAppleWalkingSteadinessEventRepeatVeryLow": 4],
        "CervicalMucusQuality": ["HKCategoryValueCervicalMucusQualityDry": 1, "HKCategoryValueCervicalMucusQualitySticky": 2,
                                 "HKCategoryValueCervicalMucusQualityCreamy": 3, "HKCategoryValueCervicalMucusQualityWatery": 4,
                                 "HKCategoryValueCervicalMucusQualityEggWhite": 5],
        "Contraceptive": ["HKCategoryValueContraceptiveUnspecified": 1, "HKCategoryValueContraceptiveImplant": 2,
                          "HKCategoryValueContraceptiveInjection": 3, "HKCategoryValueContraceptiveIntrauterineDevice": 4,
                          "HKCategoryValueContraceptiveIntravaginalRing": 5, "HKCategoryValueContraceptiveOral": 6,
                          "HKCategoryValueContraceptivePatch": 7],
        "EnvironmentalAudioExposureEvent": ["HKCategoryValueEnvironmentalAudioExposureEventMomentaryLimit": 1],
        "AudioExposureEvent": ["HKCategoryValueAudioExposureEventLoudEnvironment": 1],
        "HeadphoneAudioExposureEvent": ["HKCategoryValueHeadphoneAudioExposureEventSevenDayLimit": 1],
        "LowCardioFitnessEvent": ["HKCategoryValueLowCardioFitnessEventLowFitness": 1],
        "MenopausalState": ["HKCategoryValueMenopausalStateMenopause": 1, "HKCategoryValueMenopausalStatePerimenopause": 2,
                            "HKCategoryValueMenopausalStateNone": 3],
        "MenstrualFlow": ["HKCategoryValueMenstrualFlowUnspecified": 1, "HKCategoryValueMenstrualFlowLight": 2,
                          "HKCategoryValueMenstrualFlowMedium": 3, "HKCategoryValueMenstrualFlowHeavy": 4, "HKCategoryValueMenstrualFlowNone": 5],
        "OvulationTestResult": ["HKCategoryValueOvulationTestResultNegative": 1, "HKCategoryValueOvulationTestResultLuteinizingHormoneSurge": 2,
                                "HKCategoryValueOvulationTestResultPositive": 2, "HKCategoryValueOvulationTestResultIndeterminate": 3,
                                "HKCategoryValueOvulationTestResultEstrogenSurge": 4],
        "PregnancyTestResult": ["HKCategoryValuePregnancyTestResultNegative": 1, "HKCategoryValuePregnancyTestResultPositive": 2,
                                "HKCategoryValuePregnancyTestResultIndeterminate": 3],
        "ProgesteroneTestResult": ["HKCategoryValueProgesteroneTestResultNegative": 1, "HKCategoryValueProgesteroneTestResultPositive": 2,
                                   "HKCategoryValueProgesteroneTestResultIndeterminate": 3],
        "BleedingAfterPregnancy": vaginalBleeding, "BleedingDuringPregnancy": vaginalBleeding, "BleedingAfterMenopause": vaginalBleeding,
    ]
    /// Required metadata (§3.3 and the public documentation).
    static let requiredMetadata: [String: [String]] = [
        "HKQuantityTypeIdentifierInsulinDelivery": ["HKInsulinDeliveryReason"],
        "HKCategoryTypeIdentifierMenstrualFlow": ["HKMenstrualCycleStart"],
        "HKCategoryTypeIdentifierSexualActivity": [],
    ]

    /// Every type by identifier.
    public static let all: [String: HealthType] = {
        var out: [String: HealthType] = [:]
        for (id, dim, cumulative, maxD, minD) in quantityRows {
            // Audio exposure: "minimum duration … 0.001" (§3.3).
            let minimum = minD == 0 ? 0.001 : minD
            out[id] = HealthType(identifier: id, kind: .quantity, dimension: dim, cumulative: cumulative, maximumDuration: maxD,
                                 minimumDuration: minimum, writable: !readOnly.contains(id), categoryValues: nil, categoryNames: [:],
                                 requiredMetadata: requiredMetadata[id] ?? [], storeCode: storeCodes[id], storeUnit: storeUnits[id])
        }
        for (id, _, maxD) in categoryRows {
            let short = String(id.dropFirst("HKCategoryTypeIdentifier".count))
            let names: [String: Int] = ownValues[short] ?? (presenceTypes.contains(short) ? presence
                : notApplicableTypes.contains(short) || !isSymptom(short) ? notApplicable : severity)
            out[id] = HealthType(identifier: id, kind: .category, dimension: nil, cumulative: false, maximumDuration: maxD,
                                 minimumDuration: nil, writable: !readOnly.contains(id), categoryValues: Array(Set(names.values)).sorted(),
                                 categoryNames: names, requiredMetadata: requiredMetadata[id] ?? [], storeCode: storeCodes[id],
                                 storeUnit: nil)
        }
        out[ecg] = HealthType(identifier: ecg, kind: .other, dimension: nil, cumulative: false, maximumDuration: nil, minimumDuration: nil,
                              writable: false, categoryValues: nil, categoryNames: [:], requiredMetadata: [], storeCode: storeCodes[ecg],
                              storeUnit: nil)
        out[workout] = HealthType(identifier: workout, kind: .workout, dimension: nil, cumulative: false, maximumDuration: nil,
                                  minimumDuration: nil, writable: true, categoryValues: nil, categoryNames: [:], requiredMetadata: [],
                                  storeCode: storeCodes[workout], storeUnit: nil)
        return out
    }()

    /// Symptom types (the severity enumeration): the category types of iOS
    /// 13.6/14.0 that are not in another set.
    static func isSymptom(_ short: String) -> Bool {
        !["AppleStandHour", "SleepAnalysis", "MindfulSession", "ToothbrushingEvent", "HandwashingEvent", "SexualActivity",
          "AppleWalkingSteadinessEvent", "SleepApneaEvent", "HypertensionEvent"].contains(short)
            && !short.hasSuffix("Event") && !short.hasSuffix("Cycles") && !short.hasSuffix("Periods")
    }

    /// A type by its full identifier, its short name (`HeartRate`), or a
    /// lowercase-hyphenated alias (`heart-rate`, `sleep`, `spo2`).
    public static func type(named name: String) -> HealthType? {
        if let t = all[name] { return t }
        let key = name.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        if let alias = aliases[key], let t = all[alias] { return t }
        return all.values.first { $0.shortName.lowercased() == key }
    }

    static let aliases: [String: String] = [
        "hr": "HKQuantityTypeIdentifierHeartRate", "spo2": "HKQuantityTypeIdentifierOxygenSaturation",
        "bloodoxygen": "HKQuantityTypeIdentifierOxygenSaturation", "steps": "HKQuantityTypeIdentifierStepCount",
        "sleep": "HKCategoryTypeIdentifierSleepAnalysis", "hrv": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "distance": "HKQuantityTypeIdentifierDistanceWalkingRunning", "energy": "HKQuantityTypeIdentifierActiveEnergyBurned",
        "ecg": ecg, "workout": workout, "afib": "HKQuantityTypeIdentifierAtrialFibrillationBurden",
        "apnea": "HKCategoryTypeIdentifierSleepApneaEvent",
    ]

    /// A category value given as an integer or a name: the full enumeration
    /// case name, or its suffix after the type's enumeration prefix
    /// (`AsleepCore`, `asleepcore`); sleep also takes `core`, `deep`, `rem`, `awake`, `inbed`, `asleep`.
    public static func categoryValue(_ text: String, for type: HealthType) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return n }
        if let v = type.categoryNames[t] { return v }
        let key = t.lowercased()
        for (name, v) in type.categoryNames {
            let suffix = name.replacingOccurrences(of: "HKCategoryValue", with: "").lowercased()
            if suffix == key || suffix.hasSuffix(key) && key.count >= 3 && type.categoryNames.keys.filter({ $0.lowercased().hasSuffix(key) }).count == 1 {
                return v
            }
        }
        if type.identifier == "HKCategoryTypeIdentifierSleepAnalysis" {
            return ["inbed": 0, "asleep": 1, "unspecified": 1, "awake": 2, "core": 3, "deep": 4, "rem": 5][key]
        }
        return nil
    }

    /// The writable types an agent asks to share (and read): quantities and
    /// categories apps may save, and workouts with their routes.
    public static var agentShareTypes: [String] {
        all.values.filter { $0.writable && ($0.kind == .quantity || $0.kind == .category || $0.kind == .workout) }
            .map(\.identifier).sorted() + [workoutRoute]
    }
}
