// The type catalog (type-identifiers.md): lookups over the generated tables,
// the HAP UUID scheme (§1) and the HAP category-number table
// (accessory-protocols.md §2.5).

import Foundation

/// One public constant of type-identifiers.md.
public struct YcodeHomeCatalogEntry: Hashable, Sendable {
    /// The constant's name, e.g. `HMServiceTypeLightbulb`.
    public let constantName: String
    /// The name after the table prefix, e.g. `Lightbulb`.
    public let name: String
    /// The constant's value (full uppercase UUID for HAP types).
    public let identifier: String
    /// HAP short ID for service and characteristic types.
    public let shortID: UInt32?
    public let introduced: String
    public let deprecated: String?

    public init(constantName: String, name: String, identifier: String, shortID: UInt32?,
                introduced: String, deprecated: String?) {
        self.constantName = constantName
        self.name = name
        self.identifier = identifier
        self.shortID = shortID
        self.introduced = introduced
        self.deprecated = deprecated
    }
}

/// One characteristic value enumeration (type-identifiers.md §5).
public struct YcodeValueEnumerationEntry: Hashable, Sendable {
    public let name: String
    public let introduced: String
    public let cases: [Case]

    public struct Case: Hashable, Sendable {
        public let value: Int
        public let name: String
    }

    public init(name: String, introduced: String, cases: [(Int, String)]) {
        self.name = name
        self.introduced = introduced
        self.cases = cases.map { Case(value: $0.0, name: $0.1) }
    }
}

/// Ycode's view of the identifier catalog. The tables live in
/// `Generated/Catalog.swift`.
public enum YcodeHomeCatalog {
    /// The HAP base UUID suffix (type-identifiers.md §1).
    public static let hapBaseSuffix = "-0000-1000-8000-0026BB765291"

    /// Every public string constant (HK-B14 counts 255).
    public static var allConstants: [YcodeHomeCatalogEntry] {
        serviceTypes + characteristicTypes + accessoryCategoryTypes + metadataFormats + metadataUnits
            + characteristicProperties + actionSetTypes + significantEvents + keyPaths + otherConstants
    }

    private static let servicesByID: [String: YcodeHomeCatalogEntry] =
        Dictionary(uniqueKeysWithValues: serviceTypes.map { ($0.identifier, $0) })
    private static let characteristicsByID: [String: YcodeHomeCatalogEntry] =
        Dictionary(uniqueKeysWithValues: characteristicTypes.map { ($0.identifier, $0) })
    private static let categoriesByID: [String: YcodeHomeCatalogEntry] =
        Dictionary(uniqueKeysWithValues: accessoryCategoryTypes.map { ($0.identifier, $0) })

    public static func serviceType(_ identifier: String) -> YcodeHomeCatalogEntry? {
        servicesByID[normalizedTypeUUID(identifier) ?? identifier]
    }

    public static func characteristicType(_ identifier: String) -> YcodeHomeCatalogEntry? {
        characteristicsByID[normalizedTypeUUID(identifier) ?? identifier]
    }

    public static func accessoryCategoryType(_ identifier: String) -> YcodeHomeCatalogEntry? {
        categoriesByID[identifier.uppercased()]
    }

    /// The full uppercase form of a HAP type: a short hex ID (`"43"`, `"0x43"`)
    /// expands with the HAP base; a full UUID is upper-cased. Nil if neither.
    /// (type-identifiers.md §1: accept both, expose the full uppercase form.)
    public static func normalizedTypeUUID(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { t = String(t.dropFirst(2)) }
        if t.count <= 8, !t.isEmpty, t.allSatisfy(\.isHexDigit) {
            return String(repeating: "0", count: 8 - t.count) + t.uppercased() + hapBaseSuffix
        }
        if let u = UUID(uuidString: t) { return u.uuidString.uppercased() }
        return nil
    }

    /// The short hex form HAP-IP sends for Apple-defined types (no leading
    /// zeros), or the full UUID for anything else.
    public static func wireTypeString(_ identifier: String) -> String {
        let full = normalizedTypeUUID(identifier) ?? identifier
        if full.hasSuffix(hapBaseSuffix) {
            let head = full.prefix(8)
            let trimmed = head.drop(while: { $0 == "0" })
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
        return full
    }

    /// English text for a service or characteristic type (Ycode's own wording,
    /// derived from the catalog name); nil for custom types.
    public static func localizedDescription(forType identifier: String) -> String? {
        guard let entry = serviceType(identifier) ?? characteristicType(identifier) else { return nil }
        return words(entry.name)
    }

    /// English text for an accessory category.
    public static func localizedDescription(forCategory identifier: String) -> String {
        guard let entry = accessoryCategoryType(identifier) else { return "Other" }
        return words(entry.name)
    }

    static func words(_ name: String) -> String {
        let special: [String: String] = [
            "PM2_5Density": "PM2.5 Density", "PM10Density": "PM10 Density",
            "WiFiRouter": "Wi-Fi Router", "WiFiSatellite": "Wi-Fi Satellite",
            "WiFiSatelliteStatus": "Wi-Fi Satellite Status", "WANStatusList": "WAN Status List",
            "IPCamera": "IP Camera", "CameraRTPStreamManagement": "Camera RTP Stream Management",
            "SupportedRTPConfiguration": "Supported RTP Configuration", "AirPort": "AirPort",
        ]
        if let s = special[name] { return s }
        var out = ""
        let chars = Array(name)
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase {
                let prevLower = chars[i - 1].isLowercase || chars[i - 1].isNumber
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prevLower || (chars[i - 1].isUppercase && nextLower) { out.append(" ") }
            }
            out.append(ch)
        }
        return out
    }

    // MARK: HAP category numbers (accessory-protocols.md §2.5)

    /// HAP `ci` category number → HomeKit category type string. Numbers the
    /// ADK does not list (television, speaker, router, doorbell, …) are absent.
    public static let hapCategories: [Int: String] = [
        0: HMAccessoryCategoryTypeOther,  // bridged accessory: no own category
        1: HMAccessoryCategoryTypeOther,
        2: HMAccessoryCategoryTypeBridge,
        3: HMAccessoryCategoryTypeFan,
        4: HMAccessoryCategoryTypeGarageDoorOpener,
        5: HMAccessoryCategoryTypeLightbulb,
        6: HMAccessoryCategoryTypeDoorLock,
        7: HMAccessoryCategoryTypeOutlet,
        8: HMAccessoryCategoryTypeSwitch,
        9: HMAccessoryCategoryTypeThermostat,
        10: HMAccessoryCategoryTypeSensor,
        11: HMAccessoryCategoryTypeSecuritySystem,
        12: HMAccessoryCategoryTypeDoor,
        13: HMAccessoryCategoryTypeWindow,
        14: HMAccessoryCategoryTypeWindowCovering,
        15: HMAccessoryCategoryTypeProgrammableSwitch,
        16: HMAccessoryCategoryTypeRangeExtender,
        17: HMAccessoryCategoryTypeIPCamera,
        19: HMAccessoryCategoryTypeAirPurifier,
        20: HMAccessoryCategoryTypeAirHeater,
        21: HMAccessoryCategoryTypeAirConditioner,
        22: HMAccessoryCategoryTypeAirHumidifier,
        23: HMAccessoryCategoryTypeAirDehumidifier,
        28: HMAccessoryCategoryTypeSprinkler,
        29: HMAccessoryCategoryTypeFaucet,
        30: HMAccessoryCategoryTypeShowerHead,
    ]

    /// The category type string for a HAP category number (`Other` if unknown).
    public static func categoryType(forHAPCategory number: Int) -> String {
        hapCategories[number] ?? HMAccessoryCategoryTypeOther
    }
}
