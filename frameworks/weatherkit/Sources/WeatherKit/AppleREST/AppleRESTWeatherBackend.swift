// Ycode extension, plan.md R4: a backend on Apple's documented WeatherKit
// REST API v1 (rest-api.md), used with the developer's own key. Only the
// documented endpoints are used (design.md §1 non-goals).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AppleRESTWeatherBackend: WeatherBackend {
    /// What the request needs to know about a coordinate (behavior.md §2):
    /// the IANA time zone that groups hours into days, and the ISO 3166
    /// country code that alerts need.
    public struct LocationContext: Sendable, Equatable {
        public var timeZone: String
        public var countryCode: String?

        public init(timeZone: String, countryCode: String? = nil) {
            self.timeZone = timeZone
            self.countryCode = countryCode
        }
    }

    public static let defaultBaseURL = URL(string: "https://weatherkit.apple.com")!

    let baseURL: URL
    let tokenProvider: any WeatherTokenProvider
    let httpClient: any WeatherHTTPClient
    let locationContext: @Sendable (Double, Double) async -> LocationContext

    /// - Parameters:
    ///   - locationContext: resolves a coordinate's time zone and country.
    ///     Ycode's default, until the offline resolver of design.md §4 exists,
    ///     is the process's time zone and no country (alerts then depend on
    ///     the service's own lookup).
    public init(
        tokenProvider: any WeatherTokenProvider, baseURL: URL = AppleRESTWeatherBackend.defaultBaseURL,
        httpClient: any WeatherHTTPClient = URLSessionWeatherHTTPClient(),
        locationContext: @escaping @Sendable (Double, Double) async -> LocationContext = { _, _ in
            LocationContext(timeZone: TimeZone.current.identifier)
        }
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
        self.locationContext = locationContext
    }

    public var identifier: String { "apple-rest:\(baseURL.host ?? baseURL.absoluteString)" }

    // MARK: Attribution

    public func attribution(language: String) async throws -> WeatherAttribution {
        let url = baseURL.appendingPathComponent("attribution").appendingPathComponent(language)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await send(request)
        let object: REST.Attribution
        do {
            object = try REST.decoder().decode(REST.Attribution.self, from: data)
        } catch {
            throw WeatherBackendError.malformedResponse("attribution: \(error)")
        }
        func resolve(_ text: String?) -> URL? {
            guard let text else { return nil }
            return URL(string: text, relativeTo: baseURL)?.absoluteURL
        }
        guard let light = resolve(object.logoLight3x ?? object.logoLight2x ?? object.logoLight1x),
              let dark = resolve(object.logoDark3x ?? object.logoDark2x ?? object.logoDark1x),
              let square = resolve(object.logoSquare3x ?? object.logoSquare2x ?? object.logoSquare1x)
        else { throw WeatherBackendError.malformedResponse("attribution: missing logos") }
        return WeatherAttribution(
            serviceName: object.serviceName ?? "Apple Weather",
            legalPageURL: baseURL.appendingPathComponent("legal-attribution.html"),
            squareMarkURL: square, combinedMarkLightURL: light, combinedMarkDarkURL: dark)
    }

    // MARK: Weather

    /// REST data sets per planner product (behavior.md §1).
    static func dataSets(for product: WeatherProduct) -> [String] {
        switch product {
        case .currentWeather: return ["currentWeather"]
        case .forecastNextHour: return ["forecastNextHour"]
        case .forecastHourly: return ["forecastHourly"]
        case .forecastDaily: return ["forecastDaily"]
        case .weatherAlerts: return ["weatherAlerts"]
        case .availability: return ["forecastNextHour", "weatherAlerts"]
        default: return []
        }
    }

    public func weather(for request: WeatherBackendRequest) async throws -> [WeatherProductRequest: WeatherProductResult] {
        var results: [WeatherProductRequest: WeatherProductResult] = [:]
        // Products the documented API does not have: changes and historical
        // comparisons are unsupported (nil); statistics cannot be served.
        var remaining: [WeatherProductRequest] = []
        for product in request.products {
            switch product.product {
            case .weatherChanges:
                results[product] = WeatherProductResult(
                    value: .weatherChanges(nil), expirationDate: request.requestDate.addingTimeInterval(3600))
            case .historicalComparisons:
                results[product] = WeatherProductResult(
                    value: .historicalComparisons(nil), expirationDate: request.requestDate.addingTimeInterval(3600))
            case .currentWeather, .forecastNextHour, .forecastHourly, .forecastDaily, .weatherAlerts, .availability:
                remaining.append(product)
            default:
                throw WeatherBackendError.unsupported("\(product.product.rawValue) is not in the REST API v1")
            }
        }
        guard !remaining.isEmpty else { return results }
        let context = await locationContext(request.latitude, request.longitude)

        // One HTTP request normally; another only when one call asks for the
        // same product with two different ranges (the API takes one range each).
        while !remaining.isEmpty {
            var batch: [WeatherProductRequest] = []
            var leftover: [WeatherProductRequest] = []
            var hourlyRange: WeatherProductRange??
            var dailyRange: WeatherProductRange??
            for product in remaining {
                switch product.product {
                case .forecastHourly:
                    if hourlyRange == nil || hourlyRange! == product.range {
                        hourlyRange = .some(product.range)
                        batch.append(product)
                    } else {
                        leftover.append(product)
                    }
                case .forecastDaily:
                    if dailyRange == nil || dailyRange! == product.range {
                        dailyRange = .some(product.range)
                        batch.append(product)
                    } else {
                        leftover.append(product)
                    }
                default:
                    batch.append(product)
                }
            }
            let response = try await fetchWeather(
                request: request, products: batch, context: context, hourlyRange: hourlyRange ?? nil,
                dailyRange: dailyRange ?? nil)
            let mapper = RESTMapper(requestDate: request.requestDate, language: request.language, baseURL: baseURL)
            for product in batch {
                results[product] = try mapper.result(for: product.product, in: response)
            }
            remaining = leftover.filter { results[$0] == nil }
        }
        return results
    }

    /// Builds the `GET /api/v1/weather/{language}/{latitude}/{longitude}` request.
    func weatherRequest(
        request: WeatherBackendRequest, products: [WeatherProductRequest], context: LocationContext,
        hourlyRange: WeatherProductRange?, dailyRange: WeatherProductRange?
    ) -> URLRequest {
        var dataSets: [String] = []
        for product in products {
            for set in Self.dataSets(for: product.product) where !dataSets.contains(set) {
                dataSets.append(set)
            }
        }
        let url = baseURL.appendingPathComponent("api/v1/weather")
            .appendingPathComponent(request.language)
            .appendingPathComponent(Self.coordinate(request.latitude))
            .appendingPathComponent(Self.coordinate(request.longitude))
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "dataSets", value: dataSets.joined(separator: ",")),
            URLQueryItem(name: "timezone", value: context.timeZone),
        ]
        if let country = context.countryCode {
            items.append(URLQueryItem(name: "countryCode", value: country))
        }
        if case .dates(let start, let end)? = dailyRange {
            items.append(URLQueryItem(name: "dailyStart", value: Self.timestamp(start)))
            items.append(URLQueryItem(name: "dailyEnd", value: Self.timestamp(end)))
        }
        if case .dates(let start, let end)? = hourlyRange {
            items.append(URLQueryItem(name: "hourlyStart", value: Self.timestamp(start)))
            items.append(URLQueryItem(name: "hourlyEnd", value: Self.timestamp(end)))
        }
        components.queryItems = items
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        return urlRequest
    }

    private func fetchWeather(
        request: WeatherBackendRequest, products: [WeatherProductRequest], context: LocationContext,
        hourlyRange: WeatherProductRange?, dailyRange: WeatherProductRange?
    ) async throws -> REST.Weather {
        var urlRequest = weatherRequest(
            request: request, products: products, context: context, hourlyRange: hourlyRange, dailyRange: dailyRange)
        urlRequest.setValue("Bearer \(try await tokenProvider.token())", forHTTPHeaderField: "Authorization")
        let data = try await send(urlRequest)
        do {
            return try REST.decoder().decode(REST.Weather.self, from: data)
        } catch {
            throw WeatherBackendError.malformedResponse("weather: \(error)")
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw WeatherBackendError.httpStatus(response.statusCode)
        }
        return data
    }

    /// Coordinates in the path: the rounded value in its shortest form.
    static func coordinate(_ value: Double) -> String {
        let text = "\(value)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// ISO 8601 UTC with seconds, e.g. `2026-01-16T00:30:02Z` (behavior.md §1).
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!))
    }
}

// MARK: - Environment

extension AppleRESTWeatherBackend {
    /// The backend `WEATHERKIT_BACKEND=apple-rest` selects: a token from
    /// `WEATHERKIT_TOKEN`, from `WEATHERKIT_TOKEN_URL`, or signed with the key
    /// in `WEATHERKIT_KEY_FILE` for `WEATHERKIT_TEAM_ID`,
    /// `WEATHERKIT_SERVICE_ID` and `WEATHERKIT_KEY_ID`. Nil when none is set.
    static func fromEnvironment(_ environment: [String: String]) -> AppleRESTWeatherBackend? {
        func value(_ name: String) -> String? {
            guard let text = environment[name], !text.isEmpty else { return nil }
            return text
        }
        let provider: any WeatherTokenProvider
        if let token = value("WEATHERKIT_TOKEN") {
            provider = StaticWeatherTokenProvider(token: token)
        } else if let text = value("WEATHERKIT_TOKEN_URL"), let url = URL(string: text) {
            provider = RemoteWeatherTokenProvider(url: url)
        } else if let team = value("WEATHERKIT_TEAM_ID"), let service = value("WEATHERKIT_SERVICE_ID"),
                  let key = value("WEATHERKIT_KEY_ID"), let file = value("WEATHERKIT_KEY_FILE"),
                  let signing = try? SigningWeatherTokenProvider(
                      teamID: team, serviceID: service, keyID: key, privateKeyFile: URL(fileURLWithPath: file)) {
            provider = signing
        } else {
            return nil
        }
        return AppleRESTWeatherBackend(tokenProvider: provider)
    }
}
