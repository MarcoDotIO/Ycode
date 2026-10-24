// Ycode extension (design.md §2–§3, §6): the backend interface the service
// engine plans requests for. Not part of Apple's API; apps that only use
// `WeatherService.shared` never see it.
import Foundation

/// One data product a backend can be asked for. The first five are the
/// REST data sets (behavior.md §1); `availability` is derived by the
/// backend from minute-forecast and alert support; the rest are the
/// non-public products and the statistics/summary products.
public enum WeatherProduct: String, Codable, Hashable, Sendable, CaseIterable {
    case currentWeather
    case forecastNextHour
    case forecastHourly
    case forecastDaily
    case weatherAlerts
    case availability
    case weatherChanges
    case historicalComparisons
    case dailyTemperatureStatistics
    case dailyPrecipitationStatistics
    case hourlyTemperatureStatistics
    case monthlyTemperatureStatistics
    case monthlyPrecipitationStatistics
    case dailyTemperatureSummary
    case dailyPrecipitationSummary
}

/// The range a product is requested for.
public enum WeatherProductRange: Codable, Hashable, Sendable {
    /// Half-open date interval `[start, end)`, exactly the caller's dates.
    case dates(start: Date, end: Date)
    /// Day-, hour- or month-of-year numbers `[start, end)` (statistics).
    case indices(start: Int, end: Int)
}

/// A product with its optional range. Without a range the backend's
/// defaults apply (behavior.md §1: no range parameters are sent).
public struct WeatherProductRequest: Codable, Hashable, Sendable, CustomStringConvertible {
    public let product: WeatherProduct
    public let range: WeatherProductRange?

    public init(product: WeatherProduct, range: WeatherProductRange? = nil) {
        self.product = product
        self.range = range
    }

    public var description: String {
        switch range {
        case nil: return product.rawValue
        case .dates(let start, let end)?:
            return "\(product.rawValue)[\(start.timeIntervalSinceReferenceDate),\(end.timeIntervalSinceReferenceDate))"
        case .indices(let start, let end)?:
            return "\(product.rawValue)[#\(start),#\(end))"
        }
    }
}

/// One backend call: all products of one `WeatherService` call that were
/// not answered from the cache.
public struct WeatherBackendRequest: Sendable, Equatable {
    /// Latitude rounded to 3 decimal places.
    public let latitude: Double
    /// Longitude rounded to 3 decimal places.
    public let longitude: Double
    /// BCP-47 language tag, `en-US` form.
    public let language: String
    /// The products, in the order the caller asked for them, without duplicates.
    public let products: [WeatherProductRequest]
    /// The service clock's time when the request was made.
    public let requestDate: Date

    public init(latitude: Double, longitude: Double, language: String, products: [WeatherProductRequest], requestDate: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.language = language
        self.products = products
        self.requestDate = requestDate
    }
}

/// A product value. Optional payloads are nil where the product is not
/// supported at the location (minute forecasts, alerts, changes, comparisons).
public enum WeatherProductValue: Codable, Equatable, Sendable {
    case currentWeather(CurrentWeather)
    case forecastNextHour(Forecast<MinuteWeather>?)
    case forecastHourly(Forecast<HourWeather>)
    case forecastDaily(Forecast<DayWeather>)
    case weatherAlerts([WeatherAlert]?)
    case availability(WeatherAvailability)
    case weatherChanges(WeatherChanges?)
    case historicalComparisons(HistoricalComparisons?)
    case dailyTemperatureStatistics(DailyWeatherStatistics<DayTemperatureStatistics>)
    case dailyPrecipitationStatistics(DailyWeatherStatistics<DayPrecipitationStatistics>)
    case hourlyTemperatureStatistics(HourlyWeatherStatistics<HourTemperatureStatistics>)
    case monthlyTemperatureStatistics(MonthlyWeatherStatistics<MonthTemperatureStatistics>)
    case monthlyPrecipitationStatistics(MonthlyWeatherStatistics<MonthPrecipitationStatistics>)
    case dailyTemperatureSummary(DailyWeatherSummary<DayTemperatureSummary>)
    case dailyPrecipitationSummary(DailyWeatherSummary<DayPrecipitationSummary>)

    /// The product this value answers.
    public var product: WeatherProduct {
        switch self {
        case .currentWeather: return .currentWeather
        case .forecastNextHour: return .forecastNextHour
        case .forecastHourly: return .forecastHourly
        case .forecastDaily: return .forecastDaily
        case .weatherAlerts: return .weatherAlerts
        case .availability: return .availability
        case .weatherChanges: return .weatherChanges
        case .historicalComparisons: return .historicalComparisons
        case .dailyTemperatureStatistics: return .dailyTemperatureStatistics
        case .dailyPrecipitationStatistics: return .dailyPrecipitationStatistics
        case .hourlyTemperatureStatistics: return .hourlyTemperatureStatistics
        case .monthlyTemperatureStatistics: return .monthlyTemperatureStatistics
        case .monthlyPrecipitationStatistics: return .monthlyPrecipitationStatistics
        case .dailyTemperatureSummary: return .dailyTemperatureSummary
        case .dailyPrecipitationSummary: return .dailyPrecipitationSummary
        }
    }
}

/// A product value with the time it must be refreshed.
public struct WeatherProductResult: Codable, Equatable, Sendable {
    public let value: WeatherProductValue
    /// After this instant the value is never returned from the cache.
    public let expirationDate: Date

    public init(value: WeatherProductValue, expirationDate: Date) {
        self.value = value
        self.expirationDate = expirationDate
    }
}

/// A weather data source.
///
/// A backend answers one `WeatherBackendRequest` per service call with a
/// result for every requested product. It reports failures with
/// `WeatherBackendError`, `URLError` (passed through to the caller
/// unchanged), `CancellationError` or `WeatherError`; anything else becomes
/// `WeatherError.unknown`.
public protocol WeatherBackend: Sendable {
    /// Distinguishes backends in cache keys.
    var identifier: String { get }

    /// Fetches the requested products.
    func weather(for request: WeatherBackendRequest) async throws -> [WeatherProductRequest: WeatherProductResult]

    /// The provider's attribution.
    func attribution(language: String) async throws -> WeatherAttribution
}

/// Failures a backend reports; mapped to `WeatherError` by the service
/// (behavior.md §4, plan.md §3).
public enum WeatherBackendError: Error, Sendable, Equatable {
    /// Authentication or authorization failed → `WeatherError.permissionDenied`.
    case notAuthorized
    /// HTTP status: 401 and 403 → `permissionDenied`, others → `unknown`.
    case httpStatus(Int)
    /// The response could not be read → `unknown`.
    case malformedResponse(String)
    /// The backend cannot serve a product → `unknown`.
    case unsupported(String)
}

/// The backend used when none is configured: every data call and the
/// attribution throw `WeatherError.permissionDenied`, the way an app without
/// WeatherKit access fails (simulator-baseline.md §1).
public struct UnconfiguredWeatherBackend: WeatherBackend {
    public init() {}

    public var identifier: String { "unconfigured" }

    public func weather(for request: WeatherBackendRequest) async throws -> [WeatherProductRequest: WeatherProductResult] {
        throw WeatherBackendError.notAuthorized
    }

    public func attribution(language: String) async throws -> WeatherAttribution {
        throw WeatherBackendError.notAuthorized
    }
}
