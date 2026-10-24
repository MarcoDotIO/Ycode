// Collections and containers: api.md §3.1, §3.10, §3.11; archive keys
// codable.md §4–§5.
import Foundation

// MARK: - Forecast

/// A sequence of forecast elements with the metadata of the product.
public struct Forecast<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var forecast: [Element]
    public internal(set) var metadata: WeatherMetadata
    // Non-public optional keys (codable.md §4), preserved.
    var minuteSummary: String?
    var minuteSummaries: [MinuteSummary]?
    var minuteConditions: [MinuteCondition]?
    var marineLocation: MarineLocation?

    init(
        forecast: [Element], metadata: WeatherMetadata, minuteSummary: String? = nil,
        minuteSummaries: [MinuteSummary]? = nil, minuteConditions: [MinuteCondition]? = nil,
        marineLocation: MarineLocation? = nil
    ) {
        self.forecast = forecast
        self.metadata = metadata
        self.minuteSummary = minuteSummary
        self.minuteSummaries = minuteSummaries
        self.minuteConditions = minuteConditions
        self.marineLocation = marineLocation
    }

    public var startIndex: Int { forecast.startIndex }
    public var endIndex: Int { forecast.endIndex }
    public subscript(position: Int) -> Element { forecast[position] }
}

extension Forecast where Element == MinuteWeather {
    /// A sentence describing the next hour's precipitation (derived from the
    /// non-public minute summary; empty when there is none).
    public var summary: String { minuteSummary ?? "" }
}

/// Non-public minute summary period (codable.md §4).
struct MinuteSummary: Codable, Equatable, Sendable {
    var date: Date
    var expirationDate: Date?
    var precipitation: Precipitation
    var precipitationChance: Double
    var precipitationKind: ArchiveValue
    var apparentPrecipitationIntensity: PrecipitationIntensityValue?
}

/// Non-public minute condition (codable.md §4).
struct MinuteCondition: Codable, Equatable, Sendable {
    struct Shift: Codable, Equatable, Sendable {
        var date: Date
        var nextDate: Date
        /// Payload-free enum (`{"clear": {}}` is one accepted case), kept opaque.
        var kind: ArchiveValue
    }

    var date: Date
    var expirationDate: Date?
    var shortDescription: String
    var longDescription: String
    var shift: Shift
}

/// Non-public marine location (codable.md §4).
struct MarineLocation: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

// MARK: - Changes

/// How the coming days compare with the day before each.
public struct WeatherChanges: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var changes: [WeatherChange]
    public internal(set) var metadata: WeatherMetadata

    public var startIndex: Int { changes.startIndex }
    public var endIndex: Int { changes.endIndex }
    public subscript(position: Int) -> WeatherChange { changes[position] }
}

/// Day-over-day change directions.
public struct WeatherChange: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var highTemperature: Direction
    public internal(set) var lowTemperature: Direction
    public internal(set) var dayPrecipitationAmount: Direction
    public internal(set) var nightPrecipitationAmount: Direction

    /// Direction of a change. Archived as `{"increase": {}}`.
    public enum Direction: Codable, Hashable, Sendable {
        case increase
        case decrease
        case steady
    }
}

// MARK: - Historical comparisons

/// How the forecast compares with the historical baseline.
public struct HistoricalComparisons: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var comparisons: [HistoricalComparison]
    public internal(set) var metadata: WeatherMetadata

    public var startIndex: Int { comparisons.startIndex }
    public var endIndex: Int { comparisons.endIndex }
    public subscript(position: Int) -> HistoricalComparison { comparisons[position] }
}

/// One comparison with the baseline. Archived as `{"highTemperature": {"_0": Trend}}`.
public enum HistoricalComparison: Codable, Equatable, Sendable {
    case highTemperature(Trend<UnitTemperature>)
    case lowTemperature(Trend<UnitTemperature>)
    case precipitationAmount(Trend<UnitLength>)
    case snowfallAmount(Trend<UnitLength>)
}

/// A current value compared with a baseline.
public struct Trend<Dimension: Unit>: Codable, Equatable, Sendable {
    public internal(set) var baseline: TrendBaseline<Dimension>
    public internal(set) var currentValue: Measurement<Dimension>
    public internal(set) var deviation: Deviation
}

/// The baseline of a trend.
public struct TrendBaseline<Dimension: Unit>: Codable, Equatable, Sendable {
    public internal(set) var kind: Kind
    public internal(set) var value: Measurement<Dimension>
    /// Start of the baseline period.
    public internal(set) var startDate: Date

    /// How the baseline is computed. Archived as `{"mean": {}}`.
    public enum Kind: Codable, Hashable, Sendable {
        case mean
    }
}

/// How far a value is from its baseline. Archived as `{"muchHigher": {}}`.
public enum Deviation: Codable, Hashable, Sendable {
    case muchHigher
    case higher
    case normal
    case lower
    case muchLower
}

// MARK: - Weather

/// Everything for a location in one value.
///
/// Archive: `currentWeather`, `hourlyForecast`, `dailyForecast`,
/// `availability` required; `minuteForecast`, `weatherAlerts` and the
/// non-public `weatherChanges` optional. Other non-public products are kept
/// as opaque values and written back.
public struct Weather: Codable, Equatable, Sendable {
    public internal(set) var currentWeather: CurrentWeather
    public internal(set) var minuteForecast: Forecast<MinuteWeather>?
    public internal(set) var hourlyForecast: Forecast<HourWeather>
    public internal(set) var dailyForecast: Forecast<DayWeather>
    public internal(set) var weatherAlerts: [WeatherAlert]?
    public internal(set) var availability: WeatherAvailability
    var weatherChanges: WeatherChanges?
    var otherProducts: [String: ArchiveValue] = [:]

    init(
        currentWeather: CurrentWeather, minuteForecast: Forecast<MinuteWeather>?,
        hourlyForecast: Forecast<HourWeather>, dailyForecast: Forecast<DayWeather>,
        weatherAlerts: [WeatherAlert]?, availability: WeatherAvailability, weatherChanges: WeatherChanges?
    ) {
        self.currentWeather = currentWeather
        self.minuteForecast = minuteForecast
        self.hourlyForecast = hourlyForecast
        self.dailyForecast = dailyForecast
        self.weatherAlerts = weatherAlerts
        self.availability = availability
        self.weatherChanges = weatherChanges
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case currentWeather, minuteForecast, hourlyForecast, dailyForecast, weatherAlerts, availability,
            weatherChanges
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentWeather = try container.decode(CurrentWeather.self, forKey: .currentWeather)
        minuteForecast = try container.decodeIfPresent(Forecast<MinuteWeather>.self, forKey: .minuteForecast)
        hourlyForecast = try container.decode(Forecast<HourWeather>.self, forKey: .hourlyForecast)
        dailyForecast = try container.decode(Forecast<DayWeather>.self, forKey: .dailyForecast)
        weatherAlerts = try container.decodeIfPresent([WeatherAlert].self, forKey: .weatherAlerts)
        availability = try container.decode(WeatherAvailability.self, forKey: .availability)
        weatherChanges = try container.decodeIfPresent(WeatherChanges.self, forKey: .weatherChanges)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let all = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in all.allKeys where !known.contains(key.stringValue) {
            otherProducts[key.stringValue] = try all.decode(ArchiveValue.self, forKey: key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentWeather, forKey: .currentWeather)
        try container.encodeIfPresent(minuteForecast, forKey: .minuteForecast)
        try container.encode(hourlyForecast, forKey: .hourlyForecast)
        try container.encode(dailyForecast, forKey: .dailyForecast)
        try container.encodeIfPresent(weatherAlerts, forKey: .weatherAlerts)
        try container.encode(availability, forKey: .availability)
        try container.encodeIfPresent(weatherChanges, forKey: .weatherChanges)
        if !otherProducts.isEmpty {
            var other = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in otherProducts.sorted(by: { $0.key < $1.key }) {
                try other.encode(value, forKey: AnyCodingKey(key))
            }
        }
    }
}
