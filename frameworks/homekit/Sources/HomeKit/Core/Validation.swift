// Characteristic metadata and value validation (object-model.md §7,
// plan.md T-O2): format, minimum, maximum, step, maximum length and valid
// values are checked before any accessory I/O and produce errors 43–46.

import Foundation

/// Metadata of one characteristic in wire form (the fields of
/// `HMCharacteristicMetadata`, object-model.md §7).
public struct YcodeCharacteristicMetadata: Codable, Hashable, Sendable {
    public var format: String?
    public var units: String?
    public var minimumValue: Double?
    public var maximumValue: Double?
    public var stepValue: Double?
    public var maxLength: Int?
    public var validValues: [Int]?
    public var manufacturerDescription: String?

    public init(format: String? = nil, units: String? = nil, minimumValue: Double? = nil,
                maximumValue: Double? = nil, stepValue: Double? = nil, maxLength: Int? = nil,
                validValues: [Int]? = nil, manufacturerDescription: String? = nil) {
        self.format = format
        self.units = units
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.stepValue = stepValue
        self.maxLength = maxLength
        self.validValues = validValues
        self.manufacturerDescription = manufacturerDescription
    }
}

/// The validation rules. Ycode's reading of the spec where it is silent
/// (README "Spec questions"): the format check comes first (43), then the
/// minimum (44), maximum (45) and string length (46); a value off the step grid
/// or outside `validValues` is 43; a missing value is 43; strings without a
/// `maxLength` are limited to HAP's default of 64 characters.
public enum YcodeValueValidation {
    /// HAP's default maximum string length.
    public static let defaultMaxLength = 64

    /// Inclusive bounds implied by an integer format.
    public static func formatBounds(_ format: String) -> (min: Double, max: Double)? {
        switch format {
        case HMCharacteristicMetadataFormatUInt8: return (0, 255)
        case HMCharacteristicMetadataFormatUInt16: return (0, 65_535)
        case HMCharacteristicMetadataFormatUInt32: return (0, 4_294_967_295)
        case HMCharacteristicMetadataFormatUInt64: return (0, Double(UInt64.max))
        case HMCharacteristicMetadataFormatInt: return (-2_147_483_648, 2_147_483_647)
        default: return nil
        }
    }

    /// Converts an API value to the wire form for `metadata`, or the error an
    /// app gets from `writeValue` (no I/O happens on failure).
    public static func validate(_ value: Any?, metadata: YcodeCharacteristicMetadata?) -> Result<YcodeHomeValue, HMError> {
        guard let value else { return .failure(HMError(.invalidValueType)) }
        let format = metadata?.format
        let converted: YcodeHomeValue
        switch format {
        case HMCharacteristicMetadataFormatBool:
            if let b = value as? Bool, type(of: value) == Bool.self {
                converted = .bool(b)
            } else if let d = YcodeHomeValue.number(value), d == 0 || d == 1 {
                converted = .bool(d == 1)
            } else {
                return .failure(HMError(.invalidValueType))
            }
        case HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16,
             HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64,
             HMCharacteristicMetadataFormatInt:
            guard type(of: value) != Bool.self, let ints = YcodeHomeValue.integer(value),
                  let d = YcodeHomeValue.number(value) else {
                return .failure(HMError(.invalidValueType))
            }
            if let r = checkBounds(d, metadata) { return .failure(r) }
            let (lo, hi) = formatBounds(format!)!
            if d < lo { return .failure(HMError(.valueLowerThanMinimum)) }
            if d > hi { return .failure(HMError(.valueHigherThanMaximum)) }
            if format == HMCharacteristicMetadataFormatInt {
                converted = .int(ints.signed ?? Int64(d))
            } else {
                converted = .uint(ints.unsigned ?? UInt64(d))
            }
            if let r = checkStepAndValidValues(d, metadata) { return .failure(r) }
        case HMCharacteristicMetadataFormatFloat:
            guard type(of: value) != Bool.self, let d = YcodeHomeValue.number(value), d.isFinite else {
                return .failure(HMError(.invalidValueType))
            }
            if let r = checkBounds(d, metadata) { return .failure(r) }
            if let r = checkStepAndValidValues(d, metadata) { return .failure(r) }
            converted = .float(d)
        case HMCharacteristicMetadataFormatString:
            guard let s = value as? String else { return .failure(HMError(.invalidValueType)) }
            if s.count > (metadata?.maxLength ?? defaultMaxLength) {
                return .failure(HMError(.stringLongerThanMaximum))
            }
            converted = .string(s)
        case HMCharacteristicMetadataFormatTLV8, HMCharacteristicMetadataFormatData:
            guard let d = value as? Data else { return .failure(HMError(.invalidValueType)) }
            converted = .data(d)
        case HMCharacteristicMetadataFormatArray:
            guard value is [Any], let v = YcodeHomeValue(any: value) else { return .failure(HMError(.invalidValueType)) }
            converted = v
        case HMCharacteristicMetadataFormatDictionary:
            guard value is [String: Any], let v = YcodeHomeValue(any: value) else { return .failure(HMError(.invalidValueType)) }
            converted = v
        default:
            // No or unknown format: accept any representable value.
            guard let v = YcodeHomeValue(any: value) else { return .failure(HMError(.invalidValueType)) }
            converted = v
        }
        return .success(converted)
    }

    private static func checkBounds(_ d: Double, _ m: YcodeCharacteristicMetadata?) -> HMError? {
        if let lo = m?.minimumValue, d < lo { return HMError(.valueLowerThanMinimum) }
        if let hi = m?.maximumValue, d > hi { return HMError(.valueHigherThanMaximum) }
        return nil
    }

    private static func checkStepAndValidValues(_ d: Double, _ m: YcodeCharacteristicMetadata?) -> HMError? {
        if let step = m?.stepValue, step > 0 {
            let steps = (d - (m?.minimumValue ?? 0)) / step
            if abs(steps - steps.rounded()) > 1e-6 { return HMError(.invalidValueType) }
        }
        if let valid = m?.validValues, !valid.isEmpty {
            if !valid.contains(where: { Double($0) == d }) { return HMError(.invalidValueType) }
        }
        return nil
    }
}
