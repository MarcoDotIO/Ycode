// Queries: api.md §2; product mapping behavior.md §1.
import Foundation

/// A data set to fetch, with the type of its result.
public struct WeatherQuery<T>: Sendable {
    let request: WeatherProductRequest
    let extract: @Sendable (WeatherProductValue) -> T?

    init(_ request: WeatherProductRequest, extract: @escaping @Sendable (WeatherProductValue) -> T?) {
        self.request = request
        self.extract = extract
    }
}

/// Validates a caller's range. A range whose end precedes its start is a
/// programming error and traps (api.md §2.1, simulator-baseline.md §3); a
/// zero-length range is accepted.
func checkedRange(startDate: Date, endDate: Date) -> WeatherProductRange {
    precondition(endDate >= startDate, "WeatherQuery: the end date precedes the start date")
    return .dates(start: startDate, end: endDate)
}

extension WeatherQuery where T == CurrentWeather {
    /// Conditions now (`currentWeather`).
    public static var current: WeatherQuery<CurrentWeather> {
        WeatherQuery(WeatherProductRequest(product: .currentWeather)) {
            if case .currentWeather(let value) = $0 { return value }
            return nil
        }
    }
}

extension WeatherQuery where T == Forecast<MinuteWeather>? {
    /// Next-hour forecast (`forecastNextHour`); nil where unsupported.
    public static var minute: WeatherQuery<Forecast<MinuteWeather>?> {
        WeatherQuery(WeatherProductRequest(product: .forecastNextHour)) {
            if case .forecastNextHour(let value) = $0 { return .some(value) }
            return nil
        }
    }
}

extension WeatherQuery where T == Forecast<HourWeather> {
    /// Hourly forecast with the backend's default range (`forecastHourly`).
    public static var hourly: WeatherQuery<Forecast<HourWeather>> {
        hourly(range: nil)
    }

    /// Hourly forecast for `[startDate, endDate)`. Traps when `endDate`
    /// precedes `startDate`.
    public static func hourly(startDate: Date, endDate: Date) -> WeatherQuery<Forecast<HourWeather>> {
        hourly(range: checkedRange(startDate: startDate, endDate: endDate))
    }

    static func hourly(range: WeatherProductRange?) -> WeatherQuery<Forecast<HourWeather>> {
        WeatherQuery(WeatherProductRequest(product: .forecastHourly, range: range)) {
            if case .forecastHourly(let value) = $0 { return value }
            return nil
        }
    }
}

extension WeatherQuery where T == Forecast<DayWeather> {
    /// Daily forecast with the backend's default range (`forecastDaily`).
    public static var daily: WeatherQuery<Forecast<DayWeather>> {
        daily(range: nil)
    }

    /// Daily forecast for `[startDate, endDate)`. Traps when `endDate`
    /// precedes `startDate`.
    public static func daily(startDate: Date, endDate: Date) -> WeatherQuery<Forecast<DayWeather>> {
        daily(range: checkedRange(startDate: startDate, endDate: endDate))
    }

    static func daily(range: WeatherProductRange?) -> WeatherQuery<Forecast<DayWeather>> {
        WeatherQuery(WeatherProductRequest(product: .forecastDaily, range: range)) {
            if case .forecastDaily(let value) = $0 { return value }
            return nil
        }
    }
}

extension WeatherQuery where T == [WeatherAlert]? {
    /// Active alerts (`weatherAlerts`); nil where unsupported.
    public static var alerts: WeatherQuery<[WeatherAlert]?> {
        WeatherQuery(WeatherProductRequest(product: .weatherAlerts)) {
            if case .weatherAlerts(let value) = $0 { return .some(value) }
            return nil
        }
    }
}

extension WeatherQuery where T == WeatherAvailability {
    /// What the location supports.
    public static var availability: WeatherQuery<WeatherAvailability> {
        WeatherQuery(WeatherProductRequest(product: .availability)) {
            if case .availability(let value) = $0 { return value }
            return nil
        }
    }
}

extension WeatherQuery where T == WeatherChanges? {
    /// Day-over-day changes (`weatherChanges`); nil where unsupported.
    public static var changes: WeatherQuery<WeatherChanges?> {
        WeatherQuery(WeatherProductRequest(product: .weatherChanges)) {
            if case .weatherChanges(let value) = $0 { return .some(value) }
            return nil
        }
    }
}

extension WeatherQuery where T == HistoricalComparisons? {
    /// Comparisons with the historical baseline; nil where unsupported.
    public static var historicalComparisons: WeatherQuery<HistoricalComparisons?> {
        WeatherQuery(WeatherProductRequest(product: .historicalComparisons)) {
            if case .historicalComparisons(let value) = $0 { return .some(value) }
            return nil
        }
    }
}

// MARK: - Statistics and summary queries (api.md §2.2)

/// A daily statistics data set.
public struct DailyWeatherStatisticsQuery<T: Codable & Equatable & Sendable>: Sendable {
    let product: WeatherProduct
    let extract: @Sendable (WeatherProductValue) -> DailyWeatherStatistics<T>?
}

extension DailyWeatherStatisticsQuery where T == DayTemperatureStatistics {
    /// Average high and low temperatures per day of the year.
    public static var temperature: DailyWeatherStatisticsQuery<DayTemperatureStatistics> {
        DailyWeatherStatisticsQuery(product: .dailyTemperatureStatistics) {
            if case .dailyTemperatureStatistics(let value) = $0 { return value }
            return nil
        }
    }
}

extension DailyWeatherStatisticsQuery where T == DayPrecipitationStatistics {
    /// Average precipitation per day of the year.
    public static var precipitation: DailyWeatherStatisticsQuery<DayPrecipitationStatistics> {
        DailyWeatherStatisticsQuery(product: .dailyPrecipitationStatistics) {
            if case .dailyPrecipitationStatistics(let value) = $0 { return value }
            return nil
        }
    }
}

/// An hourly statistics data set.
public struct HourlyWeatherStatisticsQuery<T: Codable & Equatable & Sendable>: Sendable {
    let product: WeatherProduct
    let extract: @Sendable (WeatherProductValue) -> HourlyWeatherStatistics<T>?
}

extension HourlyWeatherStatisticsQuery where T == HourTemperatureStatistics {
    /// Temperature percentiles per hour of the year.
    public static var temperature: HourlyWeatherStatisticsQuery<HourTemperatureStatistics> {
        HourlyWeatherStatisticsQuery(product: .hourlyTemperatureStatistics) {
            if case .hourlyTemperatureStatistics(let value) = $0 { return value }
            return nil
        }
    }
}

/// A monthly statistics data set.
public struct MonthlyWeatherStatisticsQuery<T: Codable & Equatable & Sendable>: Sendable {
    let product: WeatherProduct
    let extract: @Sendable (WeatherProductValue) -> MonthlyWeatherStatistics<T>?
}

extension MonthlyWeatherStatisticsQuery where T == MonthTemperatureStatistics {
    /// Average high and low temperatures per month.
    public static var temperature: MonthlyWeatherStatisticsQuery<MonthTemperatureStatistics> {
        MonthlyWeatherStatisticsQuery(product: .monthlyTemperatureStatistics) {
            if case .monthlyTemperatureStatistics(let value) = $0 { return value }
            return nil
        }
    }
}

extension MonthlyWeatherStatisticsQuery where T == MonthPrecipitationStatistics {
    /// Average precipitation per month.
    public static var precipitation: MonthlyWeatherStatisticsQuery<MonthPrecipitationStatistics> {
        MonthlyWeatherStatisticsQuery(product: .monthlyPrecipitationStatistics) {
            if case .monthlyPrecipitationStatistics(let value) = $0 { return value }
            return nil
        }
    }
}

/// A daily summary data set.
public struct DailyWeatherSummaryQuery<T: Codable & Equatable & Sendable>: Sendable {
    let product: WeatherProduct
    let extract: @Sendable (WeatherProductValue) -> DailyWeatherSummary<T>?
}

extension DailyWeatherSummaryQuery where T == DayTemperatureSummary {
    /// Observed daily temperature extremes.
    public static var temperature: DailyWeatherSummaryQuery<DayTemperatureSummary> {
        DailyWeatherSummaryQuery(product: .dailyTemperatureSummary) {
            if case .dailyTemperatureSummary(let value) = $0 { return value }
            return nil
        }
    }
}

extension DailyWeatherSummaryQuery where T == DayPrecipitationSummary {
    /// Observed daily precipitation totals.
    public static var precipitation: DailyWeatherSummaryQuery<DayPrecipitationSummary> {
        DailyWeatherSummaryQuery(product: .dailyPrecipitationSummary) {
            if case .dailyPrecipitationSummary(let value) = $0 { return value }
            return nil
        }
    }
}
