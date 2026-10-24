// Supporting value types: api.md §3.7, §3.8; archive keys codable.md §2–§3.
import Foundation

/// Wind at a point in time.
public struct Wind: Codable, Equatable, Sendable {
    /// The 16-point compass direction the wind blows from.
    public internal(set) var compassDirection: CompassDirection
    /// Degrees from which the wind blows.
    public internal(set) var direction: Measurement<UnitAngle>
    public internal(set) var speed: Measurement<UnitSpeed>
    public internal(set) var gust: Measurement<UnitSpeed>?

    package init(
        compassDirection: CompassDirection, direction: Measurement<UnitAngle>,
        speed: Measurement<UnitSpeed>, gust: Measurement<UnitSpeed>?
    ) {
        self.compassDirection = compassDirection
        self.direction = direction
        self.speed = speed
        self.gust = gust
    }

    /// The 16 compass points.
    public enum CompassDirection: String, CaseIterable, Codable, Hashable, Sendable, CustomStringConvertible {
        case north
        case northNortheast
        case northeast
        case eastNortheast
        case east
        case eastSoutheast
        case southeast
        case southSoutheast
        case south
        case southSouthwest
        case southwest
        case westSouthwest
        case west
        case westNorthwest
        case northwest
        case northNorthwest

        /// N, NNE, NE, … (behavior.md §6).
        public var abbreviation: String {
            switch self {
            case .north: return "N"
            case .northNortheast: return "NNE"
            case .northeast: return "NE"
            case .eastNortheast: return "ENE"
            case .east: return "E"
            case .eastSoutheast: return "ESE"
            case .southeast: return "SE"
            case .southSoutheast: return "SSE"
            case .south: return "S"
            case .southSouthwest: return "SSW"
            case .southwest: return "SW"
            case .westSouthwest: return "WSW"
            case .west: return "W"
            case .westNorthwest: return "WNW"
            case .northwest: return "NW"
            case .northNorthwest: return "NNW"
            }
        }

        /// "North Northeast" style (behavior.md §6).
        public var description: String {
            // "northNortheast" → "North Northeast", "northeast" → "Northeast".
            CaseName.words(rawValue).map(CaseName.capitalized).joined(separator: " ")
        }

        /// Same as `description`.
        public var accessibilityDescription: String { description }

        /// The point whose 22.5° sector (centred on the point, north at 0°)
        /// contains `degrees` (design.md §5).
        package static func from(degrees: Double) -> CompassDirection {
            guard degrees.isFinite else { return .north }
            var normalized = degrees.truncatingRemainder(dividingBy: 360)
            if normalized < 0 { normalized += 360 }
            let index = Int((normalized / 22.5).rounded(.toNearestOrAwayFromZero)) % 16
            return allCases[index]
        }
    }
}

/// UV index value and exposure category.
public struct UVIndex: Codable, Equatable, Sendable {
    public internal(set) var value: Int
    public internal(set) var category: ExposureCategory

    package init(value: Int, category: ExposureCategory) {
        self.value = value
        self.category = category
    }

    /// A UV index whose category follows the ranges of api.md §3.8.
    package init(value: Int) {
        self.init(value: value, category: ExposureCategory.category(for: value))
    }

    /// Exposure risk bands.
    public enum ExposureCategory: String, CaseIterable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
        case low
        case moderate
        case high
        case veryHigh
        case extreme

        /// The UV index values in the band: 0…2, 3…5, 6…7, 8…10, 11…Int.max.
        public var rangeValue: ClosedRange<Int> {
            switch self {
            case .low: return 0...2
            case .moderate: return 3...5
            case .high: return 6...7
            case .veryHigh: return 8...10
            case .extreme: return 11...Int.max
            }
        }

        public var description: String {
            switch self {
            case .low: return "Low"
            case .moderate: return "Moderate"
            case .high: return "High"
            case .veryHigh: return "Very High"
            case .extreme: return "Extreme"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        /// The band containing `value` (negative values count as low).
        package static func category(for value: Int) -> ExposureCategory {
            allCases.first { $0.rangeValue.contains(value) } ?? .low
        }
    }
}

/// Solar events of a day; nil when an event does not occur that day.
public struct SunEvents: Codable, Equatable, Sendable {
    public internal(set) var astronomicalDawn: Date?
    public internal(set) var nauticalDawn: Date?
    public internal(set) var civilDawn: Date?
    public internal(set) var sunrise: Date?
    public internal(set) var solarNoon: Date?
    public internal(set) var sunset: Date?
    public internal(set) var civilDusk: Date?
    public internal(set) var nauticalDusk: Date?
    public internal(set) var astronomicalDusk: Date?
    public internal(set) var solarMidnight: Date?

    package init(
        astronomicalDawn: Date? = nil, nauticalDawn: Date? = nil, civilDawn: Date? = nil,
        sunrise: Date? = nil, solarNoon: Date? = nil, sunset: Date? = nil, civilDusk: Date? = nil,
        nauticalDusk: Date? = nil, astronomicalDusk: Date? = nil, solarMidnight: Date? = nil
    ) {
        self.astronomicalDawn = astronomicalDawn
        self.nauticalDawn = nauticalDawn
        self.civilDawn = civilDawn
        self.sunrise = sunrise
        self.solarNoon = solarNoon
        self.sunset = sunset
        self.civilDusk = civilDusk
        self.nauticalDusk = nauticalDusk
        self.astronomicalDusk = astronomicalDusk
        self.solarMidnight = solarMidnight
    }
}

/// Lunar events of a day.
public struct MoonEvents: Codable, Equatable, Sendable {
    public internal(set) var phase: MoonPhase
    public internal(set) var moonrise: Date?
    public internal(set) var moonset: Date?

    package init(phase: MoonPhase, moonrise: Date?, moonset: Date?) {
        self.phase = phase
        self.moonrise = moonrise
        self.moonset = moonset
    }
}

/// Cloud cover fractions (0…1) by altitude band.
public struct CloudCoverByAltitude: Codable, Equatable, Sendable {
    public internal(set) var low: Double
    public internal(set) var medium: Double
    public internal(set) var high: Double

    package init(low: Double, medium: Double, high: Double) {
        self.low = low
        self.medium = medium
        self.high = high
    }
}

/// Snowfall amount with its range and liquid equivalents.
public struct SnowfallAmount: Codable, Equatable, Sendable {
    public internal(set) var amount: Measurement<UnitLength>
    public internal(set) var maximum: Measurement<UnitLength>
    public internal(set) var minimum: Measurement<UnitLength>
    public internal(set) var amountLiquidEquivalent: Measurement<UnitLength>
    public internal(set) var maximumLiquidEquivalent: Measurement<UnitLength>
    public internal(set) var minimumLiquidEquivalent: Measurement<UnitLength>

    package init(
        amount: Measurement<UnitLength>, maximum: Measurement<UnitLength>, minimum: Measurement<UnitLength>,
        amountLiquidEquivalent: Measurement<UnitLength>, maximumLiquidEquivalent: Measurement<UnitLength>,
        minimumLiquidEquivalent: Measurement<UnitLength>
    ) {
        self.amount = amount
        self.maximum = maximum
        self.minimum = minimum
        self.amountLiquidEquivalent = amountLiquidEquivalent
        self.maximumLiquidEquivalent = maximumLiquidEquivalent
        self.minimumLiquidEquivalent = minimumLiquidEquivalent
    }
}

/// Precipitation amounts split by type.
public struct PrecipitationAmountByType: Codable, Equatable, Sendable {
    public internal(set) var hail: Measurement<UnitLength>
    public internal(set) var mixed: Measurement<UnitLength>
    public internal(set) var rainfall: Measurement<UnitLength>
    public internal(set) var sleet: Measurement<UnitLength>
    /// Total precipitation.
    public internal(set) var precipitation: Measurement<UnitLength>
    public internal(set) var snowfallAmount: SnowfallAmount

    package init(
        hail: Measurement<UnitLength>, mixed: Measurement<UnitLength>, rainfall: Measurement<UnitLength>,
        sleet: Measurement<UnitLength>, precipitation: Measurement<UnitLength>, snowfallAmount: SnowfallAmount
    ) {
        self.hail = hail
        self.mixed = mixed
        self.rainfall = rainfall
        self.sleet = sleet
        self.precipitation = precipitation
        self.snowfallAmount = snowfallAmount
    }
}

/// What a location supports.
public struct WeatherAvailability: Codable, Equatable, Sendable {
    public internal(set) var minuteAvailability: AvailabilityKind
    public internal(set) var alertAvailability: AvailabilityKind
    /// Non-public key (codable.md §2), preserved. Ycode default: `unknown`.
    var airQualityAvailability: AvailabilityKind

    package init(
        minuteAvailability: AvailabilityKind, alertAvailability: AvailabilityKind,
        airQualityAvailability: AvailabilityKind = .unknown
    ) {
        self.minuteAvailability = minuteAvailability
        self.alertAvailability = alertAvailability
        self.airQualityAvailability = airQualityAvailability
    }

    /// Availability of a data set at a location.
    public enum AvailabilityKind: String, Codable, Hashable, Sendable {
        case available
        case temporarilyUnavailable
        case unsupported
        case unknown
    }
}

/// Non-public intensity object `{"category", "value"}` (codable.md §2).
struct PrecipitationIntensityValue: Codable, Equatable, Sendable {
    var category: String
    var value: Double

    static let none = PrecipitationIntensityValue(category: "none", value: 0)
}
