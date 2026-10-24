// Statistics and summaries: api.md §3.11; archive codable.md §4
// (`{baselineStartDate, days|hours|months, metadata}`; summaries have no
// baseline date).
import Foundation

/// Historical daily statistics.
public struct DailyWeatherStatistics<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var days: [T]
    /// Start of the baseline period.
    public internal(set) var baselineStartDate: Date
    public internal(set) var metadata: WeatherMetadata

    public var startIndex: Int { days.startIndex }
    public var endIndex: Int { days.endIndex }
    public subscript(position: Int) -> T { days[position] }
}

/// Historical hourly statistics.
public struct HourlyWeatherStatistics<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var hours: [T]
    public internal(set) var baselineStartDate: Date
    public internal(set) var metadata: WeatherMetadata

    public var startIndex: Int { hours.startIndex }
    public var endIndex: Int { hours.endIndex }
    public subscript(position: Int) -> T { hours[position] }
}

/// Historical monthly averages.
public struct MonthlyWeatherStatistics<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var months: [T]
    public internal(set) var baselineStartDate: Date
    public internal(set) var metadata: WeatherMetadata

    public var startIndex: Int { months.startIndex }
    public var endIndex: Int { months.endIndex }
    public subscript(position: Int) -> T { months[position] }
}

/// Observed daily values for past days.
public struct DailyWeatherSummary<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, RandomAccessCollection {
    public internal(set) var days: [T]
    public internal(set) var metadata: WeatherMetadata

    public var startIndex: Int { days.startIndex }
    public var endIndex: Int { days.endIndex }
    public subscript(position: Int) -> T { days[position] }
}

/// Average temperatures of a day of the year.
public struct DayTemperatureStatistics: Codable, Equatable, Sendable {
    /// Day of the year.
    public internal(set) var day: Int
    public internal(set) var averageLowTemperature: Measurement<UnitTemperature>
    public internal(set) var averageHighTemperature: Measurement<UnitTemperature>
}

/// Average precipitation of a day of the year.
public struct DayPrecipitationStatistics: Codable, Equatable, Sendable {
    public internal(set) var day: Int
    public internal(set) var averagePrecipitationProbability: Double
    public internal(set) var averagePrecipitationAmount: Measurement<UnitLength>
    public internal(set) var averageSnowfallAmount: Measurement<UnitLength>
}

/// Temperature percentiles of an hour of the year.
public struct HourTemperatureStatistics: Codable, Equatable, Sendable {
    /// Hour of the year.
    public internal(set) var hour: Int
    public internal(set) var percentiles: Percentiles<UnitTemperature>
}

/// 10th, 50th and 90th percentiles.
public struct Percentiles<Dimension: Unit>: Codable, Equatable, Sendable {
    public internal(set) var p10: Measurement<Dimension>
    public internal(set) var p50: Measurement<Dimension>
    public internal(set) var p90: Measurement<Dimension>
}

/// Average temperatures of a month.
public struct MonthTemperatureStatistics: Codable, Equatable, Sendable {
    /// Month, 1…12.
    public internal(set) var month: Int
    public internal(set) var averageLowTemperature: Measurement<UnitTemperature>
    public internal(set) var averageHighTemperature: Measurement<UnitTemperature>
}

/// Average precipitation of a month.
public struct MonthPrecipitationStatistics: Codable, Equatable, Sendable {
    public internal(set) var month: Int
    public internal(set) var averagePrecipitationProbability: Double
    public internal(set) var averagePrecipitationAmount: Measurement<UnitLength>
    public internal(set) var averageSnowfallAmount: Measurement<UnitLength>
}

/// Observed temperature extremes of a past day.
public struct DayTemperatureSummary: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var lowTemperature: Measurement<UnitTemperature>
    public internal(set) var highTemperature: Measurement<UnitTemperature>
}

/// Observed precipitation of a past day.
public struct DayPrecipitationSummary: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var precipitationAmount: Measurement<UnitLength>
    public internal(set) var snowfallAmount: Measurement<UnitLength>
}
