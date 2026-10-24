// Default characteristic definitions for the in-memory test accessory.
//
// Ycode-original table (open-design.md §5 "Characteristic metadata defaults
// per type": HomeKit's own defaults resource is Apple's and must not be used).
// The formats, permissions, ranges and units follow the HAP conventions of
// Apple's HomeKit ADK catalog (Apache-2.0, level 1); they were written from
// our knowledge of that catalog and not re-checked against the ADK source in
// this round (no network) — README "Spec questions" asks for the table to be
// added to type-identifiers.md. They only shape test accessories; validation
// always uses the metadata an accessory reports.

import Foundation

public struct YcodeCharacteristicTemplate: Hashable, Sendable {
    public var type: String
    public var permissions: [YcodeHAPPermission]
    public var metadata: YcodeCharacteristicMetadata
    public var initialValue: YcodeHomeValue?

    public init(type: String, permissions: [YcodeHAPPermission], metadata: YcodeCharacteristicMetadata,
                initialValue: YcodeHomeValue?) {
        self.type = YcodeHomeCatalog.normalizedTypeUUID(type) ?? type
        self.permissions = permissions
        self.metadata = metadata
        self.initialValue = initialValue
    }
}

public enum YcodeCharacteristicDefaults {
    private typealias M = YcodeCharacteristicMetadata
    private static let rw: [YcodeHAPPermission] = [.pairedRead, .pairedWrite, .events]
    private static let ro: [YcodeHAPPermission] = [.pairedRead, .events]

    private static func t(_ type: String, _ perms: [YcodeHAPPermission], _ m: YcodeCharacteristicMetadata,
                          _ v: YcodeHomeValue?) -> YcodeCharacteristicTemplate {
        YcodeCharacteristicTemplate(type: type, permissions: perms, metadata: m, initialValue: v)
    }

    private static func u8(_ lo: Double, _ hi: Double, valid: [Int]? = nil) -> M {
        M(format: HMCharacteristicMetadataFormatUInt8, minimumValue: lo, maximumValue: hi, stepValue: 1, validValues: valid)
    }

    private static let string = M(format: HMCharacteristicMetadataFormatString, maxLength: 64)
    private static let bool = M(format: HMCharacteristicMetadataFormatBool)
    private static let percent = M(format: HMCharacteristicMetadataFormatInt, units: HMCharacteristicMetadataUnitsPercentage,
                                   minimumValue: 0, maximumValue: 100, stepValue: 1)

    /// Templates by full type UUID.
    public static let templates: [String: YcodeCharacteristicTemplate] = {
        let list: [YcodeCharacteristicTemplate] = [
            t(HMCharacteristicTypeIdentify, [.pairedWrite], bool, nil),
            t(HMCharacteristicTypeManufacturer, [.pairedRead], string, .string("Ycode")),
            t(HMCharacteristicTypeModel, [.pairedRead], string, .string("Test Accessory")),
            t(HMCharacteristicTypeName, [.pairedRead], string, .string("Accessory")),
            t(HMCharacteristicTypeSerialNumber, [.pairedRead], string, .string("0001")),
            t(HMCharacteristicTypeFirmwareVersion, [.pairedRead], string, .string("1.0.0")),
            t(HMCharacteristicTypeHardwareVersion, [.pairedRead], string, .string("1.0.0")),
            t(HMCharacteristicTypePowerState, rw, bool, .bool(false)),
            t(HMCharacteristicTypeBrightness, rw, percent, .int(100)),
            t(HMCharacteristicTypeHue, rw, M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsArcDegree,
                                              minimumValue: 0, maximumValue: 360, stepValue: 1), .float(0)),
            t(HMCharacteristicTypeSaturation, rw, M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsPercentage,
                                                     minimumValue: 0, maximumValue: 100, stepValue: 1), .float(0)),
            t(HMCharacteristicTypeColorTemperature, rw, M(format: HMCharacteristicMetadataFormatUInt32,
                                                           minimumValue: 140, maximumValue: 500, stepValue: 1), .uint(370)),
            t(HMCharacteristicTypeOutletInUse, ro, bool, .bool(false)),
            t(HMCharacteristicTypeCurrentTemperature, ro, M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsCelsius,
                                                             minimumValue: 0, maximumValue: 100, stepValue: 0.1), .float(20)),
            t(HMCharacteristicTypeTargetTemperature, rw, M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsCelsius,
                                                            minimumValue: 10, maximumValue: 38, stepValue: 0.1), .float(21)),
            t(HMCharacteristicTypeCurrentHeatingCooling, ro, u8(0, 2, valid: [0, 1, 2]), .uint(0)),
            t(HMCharacteristicTypeTargetHeatingCooling, rw, u8(0, 3, valid: [0, 1, 2, 3]), .uint(0)),
            t(HMCharacteristicTypeTemperatureUnits, rw, u8(0, 1), .uint(0)),
            t(HMCharacteristicTypeCurrentRelativeHumidity, ro, M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsPercentage,
                                                                  minimumValue: 0, maximumValue: 100, stepValue: 1), .float(40)),
            t(HMCharacteristicTypeCurrentLockMechanismState, ro, u8(0, 3), .uint(1)),
            t(HMCharacteristicTypeTargetLockMechanismState, rw, u8(0, 1), .uint(1)),
            t(HMCharacteristicTypeLockManagementControlPoint, [.pairedWrite], M(format: HMCharacteristicMetadataFormatTLV8), nil),
            t(HMCharacteristicTypeVersion, [.pairedRead], M(format: HMCharacteristicMetadataFormatString, maxLength: 64), .string("1.0")),
            t(HMCharacteristicTypeCurrentDoorState, ro, u8(0, 4), .uint(1)),
            t(HMCharacteristicTypeTargetDoorState, rw, u8(0, 1), .uint(1)),
            t(HMCharacteristicTypeObstructionDetected, ro, bool, .bool(false)),
            t(HMCharacteristicTypeMotionDetected, ro, bool, .bool(false)),
            t(HMCharacteristicTypeContactState, ro, u8(0, 1), .uint(0)),
            t(HMCharacteristicTypeBatteryLevel, ro, M(format: HMCharacteristicMetadataFormatUInt8, units: HMCharacteristicMetadataUnitsPercentage,
                                                       minimumValue: 0, maximumValue: 100, stepValue: 1), .uint(100)),
            t(HMCharacteristicTypeStatusLowBattery, ro, u8(0, 1), .uint(0)),
            t(HMCharacteristicTypeChargingState, ro, u8(0, 2), .uint(0)),
            t(HMCharacteristicTypeInputEvent, [.pairedRead, .events], u8(0, 2), nil),
            t(HMCharacteristicTypeRotationSpeed, rw, M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsPercentage,
                                                        minimumValue: 0, maximumValue: 100, stepValue: 1), .float(0)),
            t(HMCharacteristicTypeActive, rw, u8(0, 1), .uint(0)),
            t(HMCharacteristicTypeSetDuration, rw, M(format: HMCharacteristicMetadataFormatUInt32, units: HMCharacteristicMetadataUnitsSeconds,
                                                      minimumValue: 0, maximumValue: 3600, stepValue: 1), .uint(300)),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.type, $0) })
    }()

    public static func template(_ type: String) -> YcodeCharacteristicTemplate? {
        templates[YcodeHomeCatalog.normalizedTypeUUID(type) ?? type]
    }
}
