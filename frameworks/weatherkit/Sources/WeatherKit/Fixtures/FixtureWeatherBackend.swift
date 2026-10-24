// Ycode extension (design.md §2–§3, plan.md R3): a backend that serves
// weather from JSON fixtures in the `Codable` archive format of codable.md.
//
// A fixture set is a directory with a manifest, `fixture.json`:
//
//     {
//       "name": "default",                       identifier part
//       "anchorDate": "2026-01-15T12:00:00Z",    the "now" the data was written for
//       "timeZone": "UTC",                       how days are delimited
//       "rebase": "days",                        "days" or "none"
//       "defaultExpiration": 3600,               seconds
//       "expiration": { "currentWeather": 600 }, seconds per product
//       "weather": "weather.json",               a `Weather` archive
//       "attribution": "attribution.json",       a `WeatherAttribution` archive
//       "legalAttributionText": "…",             optional
//       "products": { "historicalComparisons": "…json", "dailyTemperatureStatistics": "…json", … }
//     }
//
// Dates in fixture files may be ISO 8601 strings or numbers (seconds since
// 2001-01-01, Foundation's default). With `rebase: days` every date is
// shifted by whole days so that the anchor's day becomes the request's day
// (in the fixture time zone), and the minute forecast is shifted to start at
// the request's minute. Every product's metadata is set to the request
// coordinate, `date` = request time and `expirationDate` = request time +
// the product's expiration.
import Foundation

public struct FixtureWeatherBackend: WeatherBackend {
    /// How fixture dates relate to the request time.
    public enum Rebase: String, Codable, Sendable {
        /// Dates as written.
        case none
        /// Shifted by whole days to the request's day.
        case days
    }

    struct Manifest: Codable, Sendable {
        var name: String
        var anchorDate: String
        var timeZone: String?
        var rebase: Rebase?
        var defaultExpiration: Double?
        var expiration: [String: Double]?
        var weather: String
        var attribution: String
        var legalAttributionText: String?
        var products: [String: String]?
    }

    let directory: URL
    let manifest: Manifest
    let anchor: Date
    let timeZone: TimeZone
    let rebase: Rebase

    /// Loads the fixture set in `directory`. `rebase` overrides the manifest.
    public init(directory: URL, rebase: Rebase? = nil) throws {
        self.directory = directory
        let data = try Data(contentsOf: directory.appendingPathComponent("fixture.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        self.manifest = manifest
        guard let anchor = FixtureWeatherBackend.parseDate(manifest.anchorDate) else {
            throw WeatherBackendError.malformedResponse("fixture.json: anchorDate is not ISO 8601")
        }
        self.anchor = anchor
        guard let timeZone = TimeZone(identifier: manifest.timeZone ?? "UTC") else {
            throw WeatherBackendError.malformedResponse("fixture.json: unknown time zone")
        }
        self.timeZone = timeZone
        self.rebase = rebase ?? manifest.rebase ?? .days
    }

    /// The fixture set shipped with the package: made-up data written by
    /// Ycode for tests and demos ("Fixture data").
    public static func bundled(rebase: Rebase? = nil) throws -> FixtureWeatherBackend {
        guard let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw WeatherBackendError.malformedResponse("bundled fixtures missing")
        }
        return try FixtureWeatherBackend(directory: root.appendingPathComponent("default"), rebase: rebase)
    }

    public var identifier: String { "fixtures:\(manifest.name)" }

    /// The anchor date of the set (the "now" its data was written for).
    public var anchorDate: Date { anchor }

    // MARK: WeatherBackend

    public func attribution(language: String) async throws -> WeatherAttribution {
        var attribution = try decode(WeatherAttribution.self, file: manifest.attribution, offset: 0)
        attribution.legalText = manifest.legalAttributionText
        return attribution
    }

    public func weather(for request: WeatherBackendRequest) async throws -> [WeatherProductRequest: WeatherProductResult] {
        let now = request.requestDate
        let offset = dayOffset(for: now)
        var weather: Weather?
        func loadWeather() throws -> Weather {
            if let weather { return weather }
            let loaded = try decode(Weather.self, file: manifest.weather, offset: offset)
            weather = loaded
            return loaded
        }

        var results: [WeatherProductRequest: WeatherProductResult] = [:]
        for productRequest in request.products {
            try Task.checkCancellation()
            let expiration = now.addingTimeInterval(expirationInterval(productRequest.product))
            let metadata = WeatherMetadata(
                date: now, expirationDate: expiration, latitude: request.latitude, longitude: request.longitude)
            let value: WeatherProductValue
            switch productRequest.product {
            case .currentWeather:
                var current = try loadWeather().currentWeather
                current.metadata = refreshed(current.metadata, metadata)
                value = .currentWeather(current)
            case .forecastNextHour:
                var minutes = try loadWeather().minuteForecast
                if var forecast = minutes {
                    if rebase == .days { forecast = shiftedToMinute(forecast, now: now) }
                    forecast.metadata = refreshed(forecast.metadata, metadata)
                    minutes = forecast
                }
                value = .forecastNextHour(minutes)
            case .forecastHourly:
                var forecast = try loadWeather().hourlyForecast
                forecast.forecast = select(forecast.forecast, by: \.date, range: productRequest.range,
                                           defaultStart: floor(now, to: 3600))
                forecast.metadata = refreshed(forecast.metadata, metadata)
                value = .forecastHourly(forecast)
            case .forecastDaily:
                var forecast = try loadWeather().dailyForecast
                forecast.forecast = select(forecast.forecast, by: \.date, range: productRequest.range,
                                           defaultStart: calendar.startOfDay(for: now))
                forecast.metadata = refreshed(forecast.metadata, metadata)
                value = .forecastDaily(forecast)
            case .weatherAlerts:
                let alerts = try loadWeather().weatherAlerts?.map { alert -> WeatherAlert in
                    var alert = alert
                    alert.metadata = refreshed(alert.metadata, metadata)
                    return alert
                }
                value = .weatherAlerts(alerts)
            case .availability:
                value = .availability(try loadWeather().availability)
            case .weatherChanges:
                var changes = try loadWeather().weatherChanges
                if let old = changes?.metadata { changes?.metadata = refreshed(old, metadata) }
                value = .weatherChanges(changes)
            case .historicalComparisons:
                if let file = manifest.products?[WeatherProduct.historicalComparisons.rawValue] {
                    var comparisons = try decode(HistoricalComparisons.self, file: file, offset: offset)
                    comparisons.metadata = refreshed(comparisons.metadata, metadata)
                    value = .historicalComparisons(comparisons)
                } else {
                    value = .historicalComparisons(nil)
                }
            case .dailyTemperatureStatistics:
                var statistics = try decode(
                    DailyWeatherStatistics<DayTemperatureStatistics>.self, product: .dailyTemperatureStatistics, offset: offset)
                statistics.days = selectIndexed(statistics.days, by: \.day, range: productRequest.range, unit: .day)
                statistics.metadata = refreshed(statistics.metadata, metadata)
                value = .dailyTemperatureStatistics(statistics)
            case .dailyPrecipitationStatistics:
                var statistics = try decode(
                    DailyWeatherStatistics<DayPrecipitationStatistics>.self, product: .dailyPrecipitationStatistics, offset: offset)
                statistics.days = selectIndexed(statistics.days, by: \.day, range: productRequest.range, unit: .day)
                statistics.metadata = refreshed(statistics.metadata, metadata)
                value = .dailyPrecipitationStatistics(statistics)
            case .hourlyTemperatureStatistics:
                var statistics = try decode(
                    HourlyWeatherStatistics<HourTemperatureStatistics>.self, product: .hourlyTemperatureStatistics, offset: offset)
                statistics.hours = selectIndexed(statistics.hours, by: \.hour, range: productRequest.range, unit: .hour)
                statistics.metadata = refreshed(statistics.metadata, metadata)
                value = .hourlyTemperatureStatistics(statistics)
            case .monthlyTemperatureStatistics:
                var statistics = try decode(
                    MonthlyWeatherStatistics<MonthTemperatureStatistics>.self, product: .monthlyTemperatureStatistics, offset: offset)
                statistics.months = selectIndexed(statistics.months, by: \.month, range: productRequest.range, unit: .month)
                statistics.metadata = refreshed(statistics.metadata, metadata)
                value = .monthlyTemperatureStatistics(statistics)
            case .monthlyPrecipitationStatistics:
                var statistics = try decode(
                    MonthlyWeatherStatistics<MonthPrecipitationStatistics>.self, product: .monthlyPrecipitationStatistics, offset: offset)
                statistics.months = selectIndexed(statistics.months, by: \.month, range: productRequest.range, unit: .month)
                statistics.metadata = refreshed(statistics.metadata, metadata)
                value = .monthlyPrecipitationStatistics(statistics)
            case .dailyTemperatureSummary:
                var summary = try decode(
                    DailyWeatherSummary<DayTemperatureSummary>.self, product: .dailyTemperatureSummary, offset: offset)
                summary.days = select(summary.days, by: \.date, range: productRequest.range, defaultStart: nil)
                summary.metadata = refreshed(summary.metadata, metadata)
                value = .dailyTemperatureSummary(summary)
            case .dailyPrecipitationSummary:
                var summary = try decode(
                    DailyWeatherSummary<DayPrecipitationSummary>.self, product: .dailyPrecipitationSummary, offset: offset)
                summary.days = select(summary.days, by: \.date, range: productRequest.range, defaultStart: nil)
                summary.metadata = refreshed(summary.metadata, metadata)
                value = .dailyPrecipitationSummary(summary)
            }
            results[productRequest] = WeatherProductResult(value: value, expirationDate: expiration)
        }
        return results
    }

    // MARK: Helpers

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Seconds to add to fixture dates for a request at `now`.
    func dayOffset(for now: Date) -> TimeInterval {
        guard rebase == .days else { return 0 }
        return calendar.startOfDay(for: now).timeIntervalSince(calendar.startOfDay(for: anchor))
    }

    func expirationInterval(_ product: WeatherProduct) -> TimeInterval {
        manifest.expiration?[product.rawValue] ?? manifest.defaultExpiration ?? 3600
    }

    func refreshed(_ old: WeatherMetadata, _ new: WeatherMetadata) -> WeatherMetadata {
        var metadata = new
        metadata.attribution = old.attribution
        return metadata
    }

    func floor(_ date: Date, to seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / seconds).rounded(.down) * seconds)
    }

    /// Elements in `[start, end)` for a date range; from `defaultStart` on
    /// without one.
    func select<E>(_ elements: [E], by date: KeyPath<E, Date>, range: WeatherProductRange?, defaultStart: Date?) -> [E] {
        switch range {
        case .dates(let start, let end)?:
            return elements.filter { $0[keyPath: date] >= start && $0[keyPath: date] < end }
        case .indices?:
            return elements
        case nil:
            guard let defaultStart else { return elements }
            return elements.filter { $0[keyPath: date] >= defaultStart }
        }
    }

    /// Statistics elements whose day/hour/month number is in `[start, end)`,
    /// or touched by a date interval.
    func selectIndexed<E>(_ elements: [E], by index: KeyPath<E, Int>, range: WeatherProductRange?, unit: Calendar.Component) -> [E] {
        switch range {
        case nil:
            return elements
        case .indices(let start, let end)?:
            return elements.filter { $0[keyPath: index] >= start && $0[keyPath: index] < end }
        case .dates(let start, let end)?:
            var wanted = Set<Int>()
            let step: Calendar.Component = unit == .month ? .month : (unit == .hour ? .hour : .day)
            let container: Calendar.Component = .year
            var cursor = calendar.dateInterval(of: unit, for: start)?.start ?? start
            var guardCount = 0
            while cursor < end, guardCount < 10_000 {
                if let ordinal = calendar.ordinality(of: unit, in: container, for: cursor) { wanted.insert(ordinal) }
                guard let next = calendar.date(byAdding: step, value: 1, to: cursor) else { break }
                cursor = next
                guardCount += 1
            }
            return elements.filter { wanted.contains($0[keyPath: index]) }
        }
    }

    /// Shifts the minute forecast so that its first minute is the request's minute.
    func shiftedToMinute(_ forecast: Forecast<MinuteWeather>, now: Date) -> Forecast<MinuteWeather> {
        guard let first = forecast.forecast.first?.date else { return forecast }
        let shift = floor(now, to: 60).timeIntervalSince(first)
        var shifted = forecast
        shifted.forecast = forecast.forecast.map { minute in
            var minute = minute
            minute.date += shift
            return minute
        }
        shifted.minuteSummaries = forecast.minuteSummaries?.map { summary in
            var summary = summary
            summary.date += shift
            summary.expirationDate = summary.expirationDate.map { $0 + shift }
            return summary
        }
        shifted.minuteConditions = forecast.minuteConditions?.map { condition in
            var condition = condition
            condition.date += shift
            condition.expirationDate = condition.expirationDate.map { $0 + shift }
            condition.shift.date += shift
            condition.shift.nextDate += shift
            return condition
        }
        return shifted
    }

    func decode<T: Decodable>(_ type: T.Type, product: WeatherProduct, offset: TimeInterval) throws -> T {
        guard let file = manifest.products?[product.rawValue] else {
            throw WeatherBackendError.unsupported("fixture set has no \(product.rawValue)")
        }
        return try decode(type, file: file, offset: offset)
    }

    func decode<T: Decodable>(_ type: T.Type, file: String, offset: TimeInterval) throws -> T {
        let data = try Data(contentsOf: directory.appendingPathComponent(file))
        return try FixtureWeatherBackend.decoder(offset: offset).decode(type, from: data)
    }

    /// A decoder that reads ISO 8601 or numeric dates and adds `offset`.
    static func decoder(offset: TimeInterval) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard let date = parseDate(text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 date: \(text)")
                }
                return date.addingTimeInterval(offset)
            }
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self)).addingTimeInterval(offset)
        }
        return decoder
    }

    static func parseDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
