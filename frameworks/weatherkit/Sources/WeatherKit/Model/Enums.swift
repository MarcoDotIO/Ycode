// WeatherKit enumerations: api.md §3.8, display strings behavior.md §6.
//
// String-backed enums use the case name as raw value (codable.md §1) and
// are CaseIterable and CustomStringConvertible. The English labels are the
// observed output values of behavior.md §6; the tables are Ycode's own.
import Foundation

/// The weather condition of a period.
public enum WeatherCondition: String, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
    case blizzard
    case blowingDust
    case blowingSnow
    case breezy
    case clear
    case cloudy
    case drizzle
    case flurries
    case foggy
    case freezingDrizzle
    case freezingRain
    case frigid
    case hail
    case haze
    case heavyRain
    case heavySnow
    case hot
    case hurricane
    case isolatedThunderstorms
    case mostlyClear
    case mostlyCloudy
    case partlyCloudy
    case rain
    case scatteredThunderstorms
    case sleet
    case smoky
    case snow
    case strongStorms
    case sunFlurries
    case sunShowers
    case thunderstorms
    case tropicalStorm
    case windy
    case wintryMix

    /// Title-case label (behavior.md §6): the case name in words, with the
    /// listed exceptions.
    public var description: String {
        switch self {
        case .blowingDust: return "Dust"
        case .foggy: return "Fog"
        case .frigid: return "Cold"
        case .smoky: return "Smoke"
        case .strongStorms: return "Severe Thunderstorm"
        case .thunderstorms: return "Thunderstorm"
        default: return CaseName.words(rawValue).map(CaseName.capitalized).joined(separator: " ")
        }
    }

    /// The description in lower case (behavior.md §6).
    public var accessibilityDescription: String { description.lowercased() }
}

/// The kind of precipitation.
public enum Precipitation: String, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
    case none
    case hail
    case mixed
    case rain
    case sleet
    case snow

    /// Lower-case label; `mixed` reads "wintry mix", `none` is empty
    /// (behavior.md §6).
    public var description: String {
        switch self {
        case .none: return ""
        case .mixed: return "wintry mix"
        default: return rawValue
        }
    }

    /// Same as `description` (the spec gives one label set).
    public var accessibilityDescription: String { description }
}

/// Direction of the pressure change.
public enum PressureTrend: String, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
    case rising
    case falling
    case steady

    public var description: String {
        switch self {
        case .rising: return "Rising"
        case .falling: return "Falling"
        case .steady: return "Steady"
        }
    }

    /// Same as `description` (the spec gives one label set).
    public var accessibilityDescription: String { description }
}

/// Severity of a weather alert.
public enum WeatherSeverity: String, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
    case minor
    case moderate
    case severe
    case extreme
    case unknown

    /// The case name (behavior.md §6).
    public var description: String { rawValue }

    /// Same as `description`.
    public var accessibilityDescription: String { description }
}

/// Phase of the moon.
public enum MoonPhase: String, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
    case new
    case waxingCrescent
    case firstQuarter
    case waxingGibbous
    case full
    case waningGibbous
    case lastQuarter
    case waningCrescent

    public var description: String {
        switch self {
        case .new: return "New Moon"
        case .waxingCrescent: return "Waxing Crescent"
        case .firstQuarter: return "First Quarter"
        case .waxingGibbous: return "Waxing Gibbous"
        case .full: return "Full Moon"
        case .waningGibbous: return "Waning Gibbous"
        case .lastQuarter: return "Last Quarter"
        case .waningCrescent: return "Waning Crescent"
        }
    }

    /// Same as `description`.
    public var accessibilityDescription: String { description }

    /// `moonphase.` followed by the description's words in lower case,
    /// separated by dots (behavior.md §6).
    public var symbolName: String {
        "moonphase." + description.lowercased().split(separator: " ").joined(separator: ".")
    }
}

/// Splits lowerCamelCase case names into words.
enum CaseName {
    static func words(_ name: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.lowercased() }
    }

    static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
