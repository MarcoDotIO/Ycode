// T-O2: value validation per format, min/max/step/maxLength/validValues →
// errors 43–46 before I/O (object-model.md §7).

import Foundation
import Testing
@testable import HomeKit

private typealias M = YcodeCharacteristicMetadata

private func code(_ value: Any?, _ m: M) -> Int? {
    if case .failure(let e) = YcodeValueValidation.validate(value, metadata: m) { return e.code.rawValue }
    return nil
}

private func value(_ v: Any?, _ m: M) -> YcodeHomeValue? {
    try? YcodeValueValidation.validate(v, metadata: m).get()
}

@Suite("T-O2 value validation (object-model.md §7)")
struct ValidationTests {
    @Test("bool: Bool, NSNumber 0/1 and integers 0/1; anything else is 43")
    func bool() {
        let m = M(format: HMCharacteristicMetadataFormatBool)
        #expect(value(true, m) == .bool(true))
        #expect(value(NSNumber(value: false), m) == .bool(false))
        #expect(value(1, m) == .bool(true))
        #expect(code(2, m) == 43)
        #expect(code("true", m) == 43)
        #expect(code(nil, m) == 43)
    }

    @Test("integer formats: type, minimum (44), maximum (45), format bounds, step and valid values (43)")
    func integers() {
        let brightness = M(format: HMCharacteristicMetadataFormatInt, units: HMCharacteristicMetadataUnitsPercentage,
                           minimumValue: 0, maximumValue: 100, stepValue: 1)
        #expect(value(50, brightness) == .int(50))
        #expect(value(NSNumber(value: 75), brightness) == .int(75))
        #expect(value(Int8(3), brightness) == .int(3))
        #expect(value(25.0, brightness) == .int(25), "an integral double is accepted")
        #expect(code(25.5, brightness) == 43, "non-integral")
        #expect(code(true, brightness) == 43, "a Swift Bool is not a number")
        #expect(code("50", brightness) == 43)
        #expect(code(-1, brightness) == 44)
        #expect(code(101, brightness) == 45)

        let u8 = M(format: HMCharacteristicMetadataFormatUInt8)
        #expect(value(255, u8) == .uint(255))
        #expect(code(256, u8) == 45, "format bound")
        #expect(code(-1, u8) == 44, "format bound")
        let u64 = M(format: HMCharacteristicMetadataFormatUInt64)
        #expect(value(UInt64.max, u64) == .uint(UInt64.max), "64-bit values stay exact")
        let i32 = M(format: HMCharacteristicMetadataFormatInt)
        #expect(code(Int(Int32.max) + 1, i32) == 45)

        let stepped = M(format: HMCharacteristicMetadataFormatUInt32, minimumValue: 140, maximumValue: 500, stepValue: 10)
        #expect(value(150, stepped) == .uint(150))
        #expect(code(155, stepped) == 43, "off the step grid from the minimum")

        let mode = M(format: HMCharacteristicMetadataFormatUInt8, minimumValue: 0, maximumValue: 3, stepValue: 1, validValues: [0, 1, 3])
        #expect(value(3, mode) == .uint(3))
        #expect(code(2, mode) == 43, "not a valid value")
        #expect(code(4, mode) == 45, "bounds come before valid values")
    }

    @Test("float: bounds and step with tolerance")
    func float() {
        let temp = M(format: HMCharacteristicMetadataFormatFloat, units: HMCharacteristicMetadataUnitsCelsius,
                     minimumValue: 10, maximumValue: 38, stepValue: 0.1)
        #expect(value(21.5, temp) == .float(21.5))
        #expect(value(Float(20), temp) == .float(20))
        #expect(value(NSNumber(value: 22.3), temp) == .float(22.3))
        #expect(code(9.9, temp) == 44)
        #expect(code(38.1, temp) == 45)
        #expect(code(21.55, temp) == 43)
        #expect(code(Double.nan, temp) == 43)
    }

    @Test("string: type and maximum length (46); default maximum 64")
    func string() {
        let m = M(format: HMCharacteristicMetadataFormatString, maxLength: 5)
        #expect(value("Lamp", m) == .string("Lamp"))
        #expect(value(NSString(string: "Lamp2"), m) == .string("Lamp2"))
        #expect(code("Lamps!", m) == 46)
        #expect(code(5, m) == 43)
        let unbounded = M(format: HMCharacteristicMetadataFormatString)
        #expect(value(String(repeating: "a", count: 64), unbounded) != nil)
        #expect(code(String(repeating: "a", count: 65), unbounded) == 46)
    }

    @Test("tlv8 and data take Data; array and dict take collections")
    func dataAndCollections() {
        let tlv = M(format: HMCharacteristicMetadataFormatTLV8)
        #expect(value(Data([1, 2, 3]), tlv) == .data(Data([1, 2, 3])))
        #expect(code("0102", tlv) == 43)
        let array = M(format: HMCharacteristicMetadataFormatArray)
        #expect(value([1, 2], array) == .array([.int(1), .int(2)]))
        #expect(code(1, array) == 43)
        let dict = M(format: HMCharacteristicMetadataFormatDictionary)
        #expect(value(["a": "b"], dict) == .dictionary(["a": .string("b")]))
    }

    @Test("API form: numbers and booleans as NSNumber, strings as String, data as Data")
    func apiForm() {
        #expect(YcodeHomeValue.bool(true).apiValue as? Bool == true)
        #expect(YcodeHomeValue.bool(true).apiValue is NSNumber)
        #expect(YcodeHomeValue.int(42).apiValue as? Int == 42)
        #expect(YcodeHomeValue.uint(7).apiValue as? NSNumber == NSNumber(value: 7))
        #expect(YcodeHomeValue.float(1.5).apiValue as? Double == 1.5)
        #expect(YcodeHomeValue.string("x").apiValue as? String == "x")
        #expect(YcodeHomeValue.data(Data([9])).apiValue as? Data == Data([9]))
    }
}
