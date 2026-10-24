// T-O1 / HK-B14: the identifier catalog equals type-identifiers.md.

import Foundation
import Testing
@testable import HomeKit

@Suite("T-O1 type catalog (type-identifiers.md)")
struct CatalogTests {
    @Test("HK-B14: 255 public constants, all distinct (type-identifiers.md §2–§4)")
    func counts() {
        #expect(YcodeHomeCatalog.serviceTypes.count == 46)
        #expect(YcodeHomeCatalog.characteristicTypes.count == 138)
        #expect(YcodeHomeCatalog.serviceTypes.count + YcodeHomeCatalog.characteristicTypes.count == 184)
        #expect(YcodeHomeCatalog.accessoryCategoryTypes.count == 33)
        #expect(YcodeHomeCatalog.metadataFormats.count == 12)
        #expect(YcodeHomeCatalog.metadataUnits.count == 8)
        #expect(YcodeHomeCatalog.characteristicProperties.count == 5)
        #expect(YcodeHomeCatalog.actionSetTypes.count == 6)
        #expect(YcodeHomeCatalog.significantEvents.count == 2)
        #expect(YcodeHomeCatalog.keyPaths.count == 3)
        let all = YcodeHomeCatalog.allConstants
        #expect(all.count == 255)
        #expect(Set(all.map(\.identifier)).count == 255, "no two public constants share a value (§1)")
        #expect(Set(all.map(\.constantName)).count == 255)
    }

    @Test("§1 UUID scheme: HAP types are 0000XXXX-0000-1000-8000-0026BB765291, uppercase")
    func uuidScheme() {
        for e in YcodeHomeCatalog.serviceTypes + YcodeHomeCatalog.characteristicTypes {
            let short = String(format: "%08X", e.shortID!)
            #expect(e.identifier == short + "-0000-1000-8000-0026BB765291")
            #expect(e.identifier == e.identifier.uppercased())
        }
        for e in YcodeHomeCatalog.accessoryCategoryTypes {
            #expect(UUID(uuidString: e.identifier) != nil)
            #expect(!e.identifier.hasSuffix(YcodeHomeCatalog.hapBaseSuffix), "§1: categories are not HAP numbers")
        }
    }

    @Test("§2–§4 golden values (typed from the spec)")
    func goldenValues() {
        #expect(HMServiceTypeAccessoryInformation == "0000003E-0000-1000-8000-0026BB765291")
        #expect(HMServiceTypeLightbulb == "00000043-0000-1000-8000-0026BB765291")
        #expect(HMServiceTypeThermostat == "0000004A-0000-1000-8000-0026BB765291")
        #expect(HMServiceTypeDoorbell == "00000121-0000-1000-8000-0026BB765291")
        #expect(HMServiceTypeWiFiSatellite == "0000020F-0000-1000-8000-0026BB765291")
        #expect(HMCharacteristicTypeAdminOnlyAccess == "00000001-0000-1000-8000-0026BB765291")
        #expect(HMCharacteristicTypeBrightness == "00000008-0000-1000-8000-0026BB765291")
        #expect(HMCharacteristicTypePowerState == "00000025-0000-1000-8000-0026BB765291")
        #expect(HMCharacteristicTypePM2_5Density == "000000C6-0000-1000-8000-0026BB765291")
        #expect(HMCharacteristicTypeTargetMediaState == "00000137-0000-1000-8000-0026BB765291")
        #expect(HMCharacteristicTypeWiFiSatelliteStatus == "0000021E-0000-1000-8000-0026BB765291")
        #expect(HMAccessoryCategoryTypeBridge == "61102194-9993-48BF-A1EF-6C7DC50F0C01")
        #expect(HMAccessoryCategoryTypeLightbulb == "57D56F4D-3302-41F7-AB34-5365AA180E81")
        #expect(HMAccessoryCategoryTypeOther == "0FBA259B-05AC-46F2-875F-204ABB6D9FE7")
        #expect(HMAccessoryCategoryTypeWindowCovering == "2FB9EE1F-1C21-4D0B-9383-9B65F64DBF0E")
        #expect([HMCharacteristicMetadataFormatArray, HMCharacteristicMetadataFormatBool, HMCharacteristicMetadataFormatData,
                 HMCharacteristicMetadataFormatDictionary, HMCharacteristicMetadataFormatFloat, HMCharacteristicMetadataFormatInt,
                 HMCharacteristicMetadataFormatString, HMCharacteristicMetadataFormatTLV8, HMCharacteristicMetadataFormatUInt16,
                 HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64, HMCharacteristicMetadataFormatUInt8]
            == ["array", "bool", "data", "dict", "float", "int", "string", "tlv8", "uint16", "uint32", "uint64", "uint8"])
        #expect([HMCharacteristicMetadataUnitsArcDegree, HMCharacteristicMetadataUnitsCelsius, HMCharacteristicMetadataUnitsFahrenheit,
                 HMCharacteristicMetadataUnitsLux, HMCharacteristicMetadataUnitsMicrogramsPerCubicMeter,
                 HMCharacteristicMetadataUnitsPartsPerMillion, HMCharacteristicMetadataUnitsPercentage,
                 HMCharacteristicMetadataUnitsSeconds]
            == ["arcdegrees", "celsius", "fahrenheit", "lux", "micrograms/m^3", "ppm", "percentage", "seconds"])
        #expect([HMCharacteristicPropertyHidden, HMCharacteristicPropertyReadable, HMCharacteristicPropertyRequiresAuthorizationData,
                 HMCharacteristicPropertySupportsEventNotification, HMCharacteristicPropertyWritable]
            == ["HMCharacteristicPropertyHidden", "HMCharacteristicPropertyReadable",
                "HMCharacteristicPropertyRequiresAuthorizationData", "HMCharacteristicPropertySupportsEventNotification",
                "HMCharacteristicPropertyWritable"])
        #expect([HMActionSetTypeHomeArrival, HMActionSetTypeHomeDeparture, HMActionSetTypeSleep, HMActionSetTypeTriggerOwned,
                 HMActionSetTypeUserDefined, HMActionSetTypeWakeUp]
            == ["HMActionSetTypeHomeArrival", "HMActionSetTypeHomeDeparture", "HMActionSetTypeSleep",
                "HMActionSetTypeTriggerOwned", "HMActionSetTypeUserDefined", "HMActionSetTypeWakeUp"])
        #expect(HMSignificantEvent.sunrise.rawValue == "sunrise")
        #expect(HMSignificantEvent.sunset.rawValue == "sunset")
        #expect(HMCharacteristicKeyPath == "characteristic")
        #expect(HMCharacteristicValueKeyPath == "characteristicValue")
        #expect(HMPresenceKeyPath == "presence")
        #expect(HMErrorDomain == "HMErrorDomain")
        #expect(HMUserFailedAccessoriesKey == "HMUserFailedAccessoriesKey")
    }

    @Test("§1: four characteristic constants deprecated since iOS 11 still resolve")
    func deprecatedConstants() {
        let deprecated = YcodeHomeCatalog.characteristicTypes.filter { $0.deprecated != nil }
        #expect(Set(deprecated.map(\.name)) == ["Manufacturer", "Model", "SerialNumber", "FirmwareVersion"])
        #expect(deprecated.allSatisfy { $0.deprecated == "11.0" })
        #expect(YcodeHomeCatalog.characteristicType("00000020-0000-1000-8000-0026BB765291")?.name == "Manufacturer")
    }

    @Test("§1: short and full forms are accepted, the full uppercase form is exposed")
    func normalization() {
        #expect(YcodeHomeCatalog.normalizedTypeUUID("43") == HMServiceTypeLightbulb)
        #expect(YcodeHomeCatalog.normalizedTypeUUID("0x25") == HMCharacteristicTypePowerState)
        #expect(YcodeHomeCatalog.normalizedTypeUUID("00000043-0000-1000-8000-0026bb765291") == HMServiceTypeLightbulb)
        #expect(YcodeHomeCatalog.normalizedTypeUUID("not a type") == nil)
        #expect(YcodeHomeCatalog.wireTypeString(HMServiceTypeLightbulb) == "43")
        #expect(YcodeHomeCatalog.wireTypeString(HMServiceTypeWiFiSatellite) == "20F")
        let custom = "E863F10A-079E-48FF-8F27-9C2605A29F52"
        #expect(YcodeHomeCatalog.wireTypeString(custom) == custom, "custom types travel as full UUIDs")
        #expect(YcodeHomeCatalog.serviceType("43")?.constantName == "HMServiceTypeLightbulb")
        #expect(YcodeHomeCatalog.localizedDescription(forType: HMServiceTypeGarageDoorOpener) == "Garage Door Opener")
        #expect(YcodeHomeCatalog.localizedDescription(forType: HMCharacteristicTypePM2_5Density) == "PM2.5 Density")
        #expect(YcodeHomeCatalog.localizedDescription(forType: custom) == nil)
    }

    @Test("accessory-protocols.md §2.5: HAP category numbers map to category strings")
    func hapCategories() {
        #expect(YcodeHomeCatalog.categoryType(forHAPCategory: 2) == HMAccessoryCategoryTypeBridge)
        #expect(YcodeHomeCatalog.categoryType(forHAPCategory: 5) == HMAccessoryCategoryTypeLightbulb)
        #expect(YcodeHomeCatalog.categoryType(forHAPCategory: 6) == HMAccessoryCategoryTypeDoorLock)
        #expect(YcodeHomeCatalog.categoryType(forHAPCategory: 17) == HMAccessoryCategoryTypeIPCamera)
        #expect(YcodeHomeCatalog.categoryType(forHAPCategory: 30) == HMAccessoryCategoryTypeShowerHead)
        #expect(YcodeHomeCatalog.categoryType(forHAPCategory: 18) == HMAccessoryCategoryTypeOther, "not in the ADK enum")
        #expect(Set(YcodeHomeCatalog.hapCategories.keys) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
                                                             19, 20, 21, 22, 23, 28, 29, 30])
    }

    @Test("§5 characteristic value enumerations (60, golden members)")
    func valueEnumerations() {
        #expect(YcodeHomeCatalog.valueEnumerations.count == 60)
        #expect(HMCharacteristicValueDoorState.stopped.rawValue == 4)
        #expect(HMCharacteristicValueLockMechanismState.unknown.rawValue == 3)
        #expect(HMCharacteristicValueRemoteKey.home.rawValue == 16)
        #expect(HMCharacteristicValuePictureMode.custom3.rawValue == 13)
        #expect(HMCharacteristicValueAirParticulateSize.size2_5.rawValue == 0)
        #expect(HMCharacteristicValueAirParticulateSize.size10.rawValue == 1)
        #expect(HMCharacteristicValueInputSourceType.hdmi.rawValue == 3)
        #expect(HMCharacteristicValueInputSourceType.sVideo.rawValue == 5)
        #expect(HMCharacteristicValueInputSourceType.application.rawValue == 10)
        #expect(HMCharacteristicValueInputDeviceType.tv.rawValue == 1)
        #expect(HMCharacteristicValueCurrentVisibilityState.alwaysShown.rawValue == 3)
        #expect(HMCharacteristicValueHeatingCooling.auto.rawValue == 3)
        #expect(HMCharacteristicValueTemperatureUnit.fahrenheit.rawValue == 1)
        #expect(HMCharacteristicValueContactState.detected.rawValue == 0)
        #expect(HMCharacteristicValueContactState.none.rawValue == 1)
        #expect(HMCharacteristicValueLockMechanismLastKnownAction.unsecuredUsingPhysicalMovement.rawValue == 10)
        #expect(HMCharacteristicValueCurrentMediaState.allCases.count == 6)
        #expect(HMCharacteristicValueWiFiSatelliteStatus.notConnected.rawValue == 2)
    }

    /// Path of the spec when this test runs from the repository (not on a
    /// machine that only has the package).
    static var specURL: URL? {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        let spec = u.appendingPathComponent("specs/frameworks/homekit/type-identifiers.md")
        return FileManager.default.fileExists(atPath: spec.path) ? spec : nil
    }

    @Test("T-O1: every row of type-identifiers.md §2–§5 equals the catalog (when the spec is present)")
    func fullComparisonWithSpec() throws {
        guard let url = Self.specURL else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let byName = Dictionary(uniqueKeysWithValues: YcodeHomeCatalog.allConstants.map { ($0.constantName, $0.identifier) })
        let prefixes: [String: String] = [
            "Service types": "HMServiceType", "Characteristic types": "HMCharacteristicType",
            "Accessory category types": "HMAccessoryCategoryType", "Metadata formats": "HMCharacteristicMetadataFormat",
            "Metadata units": "HMCharacteristicMetadataUnits", "Characteristic properties": "HMCharacteristicProperty",
            "Action-set types": "HMActionSetType", "Significant events": "HMSignificantEvent",
        ]
        var section: String?
        var checked = 0
        var enumRows = 0
        var inEnums = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("#### ") {
                section = prefixes.keys.first { line.hasPrefix("#### \($0) (") }
                continue
            }
            if line.hasPrefix("## ") { section = nil; inEnums = line.hasPrefix("## 5."); continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("|"), cells.count >= 3, !cells[0].hasPrefix("-") else { continue }
            if inEnums {
                guard cells[0] != "Enumeration" else { continue }
                enumRows += 1
                let entry = YcodeHomeCatalog.valueEnumerations.first { $0.name == "HMCharacteristicValue" + cells[0] }
                #expect(entry != nil, "enumeration \(cells[0])")
                let pairs = cells[2].split(separator: ",").map { item -> (Int, String) in
                    let parts = item.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                    return (Int(parts[0])!, String(parts[1]))
                }
                #expect(entry?.cases.map(\.value) == pairs.map(\.0), "\(cells[0]) values")
                #expect(entry?.cases.map(\.name) == pairs.map(\.1), "\(cells[0]) names")
                continue
            }
            guard let section, let prefix = prefixes[section] else { continue }
            if cells[0] == "Short ID" || cells[0].hasPrefix("Name") { continue }
            let name: String, value: String
            if section == "Service types" || section == "Characteristic types" {
                name = prefix + cells[1]
                value = String(repeating: "0", count: 8 - cells[0].count) + cells[0] + "-0000-1000-8000-0026BB765291"
            } else {
                name = prefix + cells[0]
                value = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            }
            #expect(byName[name] == value, "\(name)")
            checked += 1
        }
        #expect(checked == 250)
        #expect(enumRows == 60)
    }
}
