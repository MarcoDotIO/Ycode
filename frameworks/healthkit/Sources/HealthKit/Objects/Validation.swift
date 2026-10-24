import Foundation

/// Object validation (`errors.md` §3, `interface.md` §3–§4). All failures throw
/// the exception HealthKit raises; constructors turn them into a trap.
enum Validation {
    /// Value class required by HealthKit-defined metadata keys. The spec measured
    /// only the external-UUID key; the rest follows the public documentation (level 1).
    static let keyClasses: [String: String] = {
        var m: [String: String] = [:]
        for k in [HKMetadataKeyExternalUUID, HKMetadataKeyTimeZone, HKMetadataKeyDeviceSerialNumber,
                  HKMetadataKeyUDIDeviceIdentifier, HKMetadataKeyUDIProductionIdentifier,
                  HKMetadataKeyDigitalSignature, HKMetadataKeyDeviceName, HKMetadataKeyDeviceManufacturerName,
                  HKMetadataKeyWorkoutBrandName, HKMetadataKeyFoodType, HKMetadataKeySyncIdentifier,
                  HKMetadataKeyGlassesPrescriptionDescription, HKMetadataKeyAppleFitnessPlusCatalogIdentifier] {
            m[k] = "NSString"
        }
        for k in [HKMetadataKeyWasUserEntered, HKMetadataKeyWasTakenInLab, HKMetadataKeyIndoorWorkout,
                  HKMetadataKeyCoachedWorkout, HKMetadataKeyGroupFitness, HKMetadataKeyMenstrualCycleStart,
                  HKMetadataKeySexualActivityProtectionUsed, HKMetadataKeySyncVersion,
                  HKMetadataKeyBodyTemperatureSensorLocation, HKMetadataKeyHeartRateSensorLocation,
                  HKMetadataKeyHeartRateMotionContext, HKMetadataKeyInsulinDeliveryReason,
                  HKMetadataKeyBloodGlucoseMealTime, HKMetadataKeySwimmingStrokeStyle,
                  HKMetadataKeySwimmingLocationType, HKMetadataKeyVO2MaxTestType, HKMetadataKeyWeatherCondition,
                  HKMetadataKeyUserMotionContext, HKMetadataKeyDevicePlacementSide, HKMetadataKeyWaterSalinity,
                  HKMetadataKeyAppleDeviceCalibrated, HKMetadataKeySessionEstimate,
                  HKMetadataKeyQuantityClampedToLowerBound, HKMetadataKeyQuantityClampedToUpperBound,
                  HKMetadataKeyAppleFitnessPlusSession, HKMetadataKeyActivityType,
                  HKMetadataKeyPhysicalEffortEstimationType, HKMetadataKeyHeartRateRecoveryTestType,
                  HKMetadataKeyHeartRateRecoveryActivityType, HKMetadataKeyCyclingFunctionalThresholdPowerTestType] {
            m[k] = "NSNumber"
        }
        for k in [HKMetadataKeyAverageSpeed, HKMetadataKeyMaximumSpeed, HKMetadataKeyElevationAscended,
                  HKMetadataKeyElevationDescended, HKMetadataKeyLapLength, HKMetadataKeyWeatherTemperature,
                  HKMetadataKeyWeatherHumidity, HKMetadataKeyAverageMETs, HKMetadataKeyAlpineSlopeGrade,
                  HKMetadataKeyCrossTrainerDistance, HKMetadataKeyIndoorBikeDistance,
                  HKMetadataKeyFitnessMachineDuration, HKMetadataKeyHeartRateEventThreshold,
                  HKMetadataKeyVO2MaxValue, HKMetadataKeyAudioExposureLevel, HKMetadataKeyAudioExposureDuration,
                  HKMetadataKeyBarometricPressure, HKMetadataKeyHeadphoneGain,
                  HKMetadataKeyLowCardioFitnessEventThreshold, HKMetadataKeyMaximumLightIntensity,
                  HKMetadataKeyHeartRateRecoveryActivityDuration,
                  HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate] {
            m[k] = "HKQuantity"
        }
        m[HKMetadataKeyDateOfEarliestDataUsedForEstimate] = "NSDate"
        return m
    }()

    static func metadata(_ metadata: [String: Any]?) throws(HKRaise) -> [String: MetadataValue]? {
        guard let metadata else { return nil }
        var out: [String: MetadataValue] = [:]
        for (key, raw) in metadata {
            guard let v = MetadataValue.from(raw) else {
                throw .validation("Invalid metadata value \(raw) of class \(type(of: raw)) for key \(key)")
            }
            if let expected = keyClasses[key], expected != v.className {
                throw .validation("Invalid class \(v.className) for metadata key \(key); expected \(expected)")
            }
            out[key] = v
        }
        if out[HKMetadataKeySyncIdentifier] != nil, out[HKMetadataKeySyncVersion] == nil {
            throw .validation("Sync version must be provided if sync identifier is provided")
        }
        return out
    }

    static func interval(_ type: HKSampleType, start: Date, end: Date) throws(HKRaise) {
        guard start <= end else { throw .validation("startDate cannot occur after endDate") }
        let d = end.timeIntervalSince(start)
        if let max = type.info.maximumDuration, d > max {
            throw .validation("Samples of type \(type.identifier) exceed the maximum allowed duration. "
                              + "Maximum duration for type \(type.identifier) is \(Int(max))")
        }
        if let min = type.info.minimumDuration, d <= min {
            throw .validation("Samples of type \(type.identifier) must have a duration greater than \(min)")
        }
    }

    static func quantity(_ type: HKQuantityType, _ quantity: HKQuantity) throws(HKRaise) {
        guard type.is(compatibleWith: quantity.unit) else {
            throw .validation("\(type.identifier) requires unit of type \(type.quantityDimension.rawValue). "
                              + "Incompatible unit: \(quantity.unit.unitString)")
        }
    }

    static func category(_ type: HKCategoryType, _ value: Int) throws(HKRaise) {
        guard type.info.allowedValues?.contains(value) ?? (value == 0) else {
            throw .validation("Value \(value) is not compatible with type \(type.identifier)")
        }
    }

    static func correlation(_ type: HKCorrelationType, _ objects: Set<HKSample>) throws(HKRaise) {
        for o in objects where !(o is HKQuantitySample || o is HKCategorySample) {
            throw .validation("\(type.identifier) cannot contain objects of class \(Swift.type(of: o))")
        }
        if type.identifier == HKCorrelationTypeIdentifier.bloodPressure.rawValue {
            let sys = objects.filter { $0.sampleType.identifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue }
            let dia = objects.filter { $0.sampleType.identifier == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue }
            guard objects.count == 2, sys.count == 1, dia.count == 1 else {
                throw .validation("\(type.identifier) must have 2 objects (one systolic and one diastolic "
                                  + "blood pressure sample); received \(objects.count)")
            }
        } else if type.identifier == HKCorrelationTypeIdentifier.food.rawValue {
            for o in objects where !o.sampleType.identifier.hasPrefix("HKQuantityTypeIdentifierDietary") {
                throw .validation("\(type.identifier) may only contain dietary samples; received \(o.sampleType.identifier)")
            }
        }
    }
}
