// Apple REST backend (plan.md R4, rest-api.md) against a scripted transport
// and a REST response we wrote ourselves (made-up values shaped per
// rest-api.md §4). No test reaches the network.
import CoreLocation
import Foundation
import Testing
@testable import WeatherKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A made-up REST v1 response for 41.5, −81.5 at 2026-01-15T12:00Z.
let restWeatherJSON = #"""
{
  "currentWeather": {
    "name": "CurrentWeather",
    "metadata": {"attributionURL": "https://example.invalid/attribution", "expireTime": "2026-01-15T12:10:00Z",
                 "latitude": 41.5, "longitude": -81.5, "readTime": "2026-01-15T12:00:00Z",
                 "reportedTime": "2026-01-15T11:55:00Z", "units": "m", "version": 1},
    "asOf": "2026-01-15T12:00:00Z", "cloudCover": 0.82, "conditionCode": "MostlyCloudy", "daylight": true,
    "humidity": 0.71, "precipitationIntensity": 0.0, "pressure": 1015.3, "pressureTrend": "falling",
    "temperature": -1.5, "temperatureApparent": -6.2, "temperatureDewPoint": -5.8, "uvIndex": 1,
    "visibility": 14250.0, "windDirection": 248, "windGust": 41.2, "windSpeed": 22.7
  },
  "forecastHourly": {
    "name": "HourlyForecast",
    "metadata": {"expireTime": "2026-01-15T13:00:00Z", "latitude": 41.5, "longitude": -81.5,
                 "readTime": "2026-01-15T12:00:00Z", "units": "m", "version": 1},
    "hours": [
      {"forecastStart": "2026-01-15T12:00:00Z", "cloudCover": 0.8, "conditionCode": "Cloudy", "daylight": true,
       "humidity": 0.7, "precipitationAmount": 0.0, "precipitationChance": 0.1, "precipitationType": "clear",
       "pressure": 1015.0, "pressureTrend": "falling", "snowfallIntensity": 0.0, "temperature": -1.4,
       "temperatureApparent": -6.0, "temperatureDewPoint": -5.7, "uvIndex": 1, "visibility": 15000.0,
       "windDirection": 250, "windGust": 40.0, "windSpeed": 21.0},
      {"forecastStart": "2026-01-15T13:00:00Z", "cloudCover": 0.9, "conditionCode": "Snow", "daylight": true,
       "humidity": 0.8, "precipitationAmount": 0.3, "precipitationChance": 0.6, "precipitationType": "snow",
       "pressure": 1014.6, "snowfallIntensity": 3.1, "temperature": -1.9, "temperatureApparent": -6.8,
       "uvIndex": 0, "visibility": 4000.0, "windSpeed": 24.0}
    ]
  },
  "forecastDaily": {
    "name": "DailyForecast",
    "metadata": {"expireTime": "2026-01-15T13:00:00Z", "latitude": 41.5, "longitude": -81.5,
                 "readTime": "2026-01-15T12:00:00Z", "units": "m", "version": 1},
    "days": [
      {"forecastStart": "2026-01-15T05:00:00Z", "forecastEnd": "2026-01-16T05:00:00Z", "conditionCode": "Flurries",
       "maxUvIndex": 2, "moonPhase": "thirdQuarter", "moonrise": "2026-01-15T07:10:00Z", "moonset": "2026-01-15T16:40:00Z",
       "precipitationAmount": 1.4, "precipitationChance": 0.55, "precipitationType": "snow", "snowfallAmount": 14.0,
       "solarMidnight": "2026-01-16T05:27:00Z", "solarNoon": "2026-01-15T17:27:00Z",
       "sunrise": "2026-01-15T12:48:00Z", "sunriseAstronomical": "2026-01-15T11:13:00Z",
       "sunriseCivil": "2026-01-15T12:18:00Z", "sunriseNautical": "2026-01-15T11:45:00Z",
       "sunset": "2026-01-15T22:07:00Z", "sunsetAstronomical": "2026-01-15T23:42:00Z",
       "sunsetCivil": "2026-01-15T22:37:00Z", "sunsetNautical": "2026-01-15T23:10:00Z",
       "temperatureMax": 0.4, "temperatureMin": -7.3,
       "daytimeForecast": {"forecastStart": "2026-01-15T12:00:00Z", "forecastEnd": "2026-01-16T00:00:00Z",
                           "cloudCover": 0.85, "conditionCode": "Flurries", "humidity": 0.74,
                           "precipitationAmount": 1.0, "precipitationChance": 0.5, "precipitationType": "snow",
                           "snowfallAmount": 10.0, "windDirection": 245, "windSpeed": 23.0},
       "overnightForecast": {"forecastStart": "2026-01-16T00:00:00Z", "forecastEnd": "2026-01-16T12:00:00Z",
                             "cloudCover": 0.6, "conditionCode": "MostlyCloudy", "humidity": 0.82,
                             "precipitationAmount": 0.4, "precipitationChance": 0.3, "precipitationType": "precipitation",
                             "snowfallAmount": 4.0, "windSpeed": 15.0}},
      {"forecastStart": "2026-01-16T05:00:00Z", "forecastEnd": "2026-01-17T05:00:00Z", "conditionCode": "Clear",
       "maxUvIndex": 3, "moonPhase": "waningCrescent", "precipitationAmount": 0.0, "precipitationChance": 0.0,
       "precipitationType": "clear", "snowfallAmount": 0.0, "temperatureMax": 2.0, "temperatureMin": -9.0}
    ]
  },
  "forecastNextHour": {
    "name": "NextHourForecast",
    "metadata": {"expireTime": "2026-01-15T12:05:00Z", "latitude": 41.5, "longitude": -81.5,
                 "readTime": "2026-01-15T12:00:00Z", "units": "m", "version": 1},
    "forecastStart": "2026-01-15T12:00:00Z", "forecastEnd": "2026-01-15T13:00:00Z",
    "minutes": [
      {"startTime": "2026-01-15T12:00:00Z", "precipitationChance": 0.0, "precipitationIntensity": 0.0},
      {"startTime": "2026-01-15T12:01:00Z", "precipitationChance": 0.1, "precipitationIntensity": 0.0},
      {"startTime": "2026-01-15T12:20:00Z", "precipitationChance": 0.6, "precipitationIntensity": 0.8}
    ],
    "summary": [
      {"startTime": "2026-01-15T12:00:00Z", "endTime": "2026-01-15T12:20:00Z", "condition": "clear",
       "precipitationChance": 0.0, "precipitationIntensity": 0.0},
      {"startTime": "2026-01-15T12:20:00Z", "condition": "snow", "precipitationChance": 0.6,
       "precipitationIntensity": 0.8}
    ]
  },
  "weatherAlerts": {
    "name": "WeatherAlerts",
    "metadata": {"expireTime": "2026-01-15T12:10:00Z", "latitude": 41.5, "longitude": -81.5,
                 "readTime": "2026-01-15T12:00:00Z", "version": 1},
    "detailsUrl": "https://example.invalid/alerts",
    "alerts": [
      {"id": "0B8E9C2A-7D41-4C3A-9F00-1234567890AB", "areaId": "XXZ001", "areaName": "Example County",
       "certainty": "likely", "countryCode": "US", "description": "Winter Weather Advisory",
       "detailsUrl": "https://example.invalid/alerts/0B8E9C2A", "effectiveTime": "2026-01-15T10:00:00Z",
       "eventOnsetTime": "2026-01-15T13:00:00Z", "eventEndTime": "2026-01-16T06:00:00Z",
       "expireTime": "2026-01-16T06:00:00Z", "issuedTime": "2026-01-15T09:58:00Z",
       "responses": ["prepare", "monitor"], "severity": "moderate", "source": "Example Weather Office",
       "urgency": "expected"}
    ]
  }
}
"""#

let restAttributionJSON = #"""
{"serviceName": "Example Weather", "logoDark@1x": "/assets/dark@1x.png", "logoDark@2x": "/assets/dark@2x.png",
 "logoDark@3x": "/assets/dark@3x.png", "logoLight@1x": "/assets/light@1x.png", "logoLight@2x": "/assets/light@2x.png",
 "logoLight@3x": "/assets/light@3x.png", "logoSquare@1x": "/assets/square@1x.png",
 "logoSquare@2x": "/assets/square@2x.png", "logoSquare@3x": "https://cdn.example.invalid/square@3x.png"}
"""#

/// A service on the REST backend with a scripted transport.
func makeRESTService(
    clock: TestClock = TestClock(), context: AppleRESTWeatherBackend.LocationContext = .init(timeZone: "America/New_York", countryCode: "US"),
    handler: @escaping @Sendable (URLRequest) throws -> (Int, Data) = { request in
        request.url!.path.hasPrefix("/attribution") ? (200, Data(restAttributionJSON.utf8)) : (200, Data(restWeatherJSON.utf8))
    }
) -> (WeatherService, MockHTTPClient) {
    let http = MockHTTPClient(handler)
    let backend = AppleRESTWeatherBackend(
        tokenProvider: StaticWeatherTokenProvider(token: "header.claims.signature"),
        baseURL: URL(string: "https://weather.example.invalid")!, httpClient: http,
        locationContext: { _, _ in context })
    let service = WeatherService(backend: backend, configuration: .init(language: "en-US", clock: { clock.now }))
    return (service, http)
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Suite("Apple REST backend (rest-api.md, plan.md R4)")
struct RESTBackendTests {
    @Test("rest-api.md §1: one GET /api/v1/weather/{language}/{lat}/{lon} with dataSets, timezone, countryCode and the bearer token")
    func requestShape() async throws {
        let (service, http) = makeRESTService()
        _ = try await service.weather(for: fixtureLocation, including: .current, .daily, .minute)
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "weather.example.invalid")
        #expect(request.url?.path == "/api/v1/weather/en-US/41.5/-81.5")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer header.claims.signature")
        let items = query(request)
        #expect(items["dataSets"] == "currentWeather,forecastDaily,forecastNextHour")
        #expect(items["timezone"] == "America/New_York")
        #expect(items["countryCode"] == "US")
        #expect(items["dailyStart"] == nil)
        #expect(items["hourlyStart"] == nil)
    }

    @Test("behavior.md §1: ranges are sent as ISO 8601 UTC with seconds, exactly the caller's dates")
    func rangeParameters() async throws {
        let (service, http) = makeRESTService()
        let start = Date(timeIntervalSince1970: 1_768_523_402)  // 2026-01-16T00:30:02Z
        _ = try await service.weather(
            for: fixtureLocation, including: .daily(startDate: start, endDate: start.addingTimeInterval(86_400)),
            .hourly(startDate: start, endDate: start.addingTimeInterval(7200)))
        let items = query(try #require(http.requests.first))
        #expect(items["dailyStart"] == "2026-01-16T00:30:02Z")
        #expect(items["dailyEnd"] == "2026-01-17T00:30:02Z")
        #expect(items["hourlyStart"] == "2026-01-16T00:30:02Z")
        #expect(items["hourlyEnd"] == "2026-01-16T02:30:02Z")
        #expect(items["dataSets"] == "forecastDaily,forecastHourly")
    }

    @Test("behavior.md §1: availability asks for forecastNextHour and weatherAlerts and derives from their presence")
    func availability() async throws {
        let (service, http) = makeRESTService()
        let availability = try await service.weather(for: fixtureLocation, including: .availability)
        #expect(query(try #require(http.requests.first))["dataSets"] == "forecastNextHour,weatherAlerts")
        #expect(availability.minuteAvailability == .available)
        #expect(availability.alertAvailability == .available)

        let (bare, _) = makeRESTService { _ in (200, Data(#"{}"#.utf8)) }
        let (none, minute, alerts) = try await bare.weather(for: fixtureLocation, including: .availability, .minute, .alerts)
        #expect(none.minuteAvailability == .unsupported)
        #expect(none.alertAvailability == .unsupported)
        #expect(minute == nil)
        #expect(alerts == nil)
    }

    @Test("rest-api.md §4–§6: current weather maps with metric units and lowerCamelCase conditions")
    func currentMapping() async throws {
        let (service, _) = makeRESTService()
        let current = try await service.weather(for: fixtureLocation, including: .current)
        #expect(current.date == fixtureAnchor)
        #expect(current.condition == .mostlyCloudy)
        #expect(current.symbolName == "cloud")
        #expect(current.cloudCover == 0.82)
        #expect(current.humidity == 0.71)
        #expect(current.temperature == Measurement(value: -1.5, unit: .celsius))
        #expect(current.apparentTemperature == Measurement(value: -6.2, unit: .celsius))
        #expect(current.dewPoint == Measurement(value: -5.8, unit: .celsius))
        #expect(current.pressure == Measurement(value: 1015.3, unit: .millibars))
        #expect(current.pressureTrend == .falling)
        #expect(current.visibility == Measurement(value: 14250, unit: .meters))
        #expect(current.wind.speed == Measurement(value: 22.7, unit: .kilometersPerHour))
        #expect(current.wind.gust == Measurement(value: 41.2, unit: .kilometersPerHour))
        #expect(current.wind.direction == Measurement(value: 248, unit: .degrees))
        #expect(current.wind.compassDirection == .westSouthwest)
        #expect(current.uvIndex.value == 1)
        #expect(current.uvIndex.category == .low)
        #expect(current.isDaylight)
        #expect(current.precipitationIntensity.unit.symbol == "mm/h")
        #expect(current.metadata.date == fixtureAnchor)
        #expect(current.metadata.expirationDate == fixtureAnchor.addingTimeInterval(600))
        #expect(current.metadata.location.coordinate.latitude == 41.5)
        // The result round-trips through the archive format.
        #expect(try decode(CurrentWeather.self, try encode(current)) == current)
    }

    @Test("rest-api.md §6: hourly mapping (clear → none, missing dew point derived, snowfall from intensity)")
    func hourlyMapping() async throws {
        let (service, _) = makeRESTService()
        let hourly = try await service.weather(for: fixtureLocation, including: .hourly)
        #expect(hourly.count == 2)
        #expect(hourly[0].precipitation == .none)
        #expect(hourly[0].condition == .cloudy)
        #expect(hourly[1].precipitation == .snow)
        #expect(hourly[1].snowfallAmount == Measurement(value: 3.1, unit: .millimeters))
        #expect(hourly[1].precipitationAmount == Measurement(value: 0.3, unit: .millimeters))
        #expect(hourly[1].pressureTrend == .steady)
        let dewPoint = hourly[1].dewPoint.converted(to: .celsius).value
        #expect(dewPoint < -1.9 && dewPoint > -6)
        #expect(hourly.metadata.expirationDate == fixtureAnchor.addingTimeInterval(3600))
    }

    @Test("rest-api.md §6: daily mapping (thirdQuarter → lastQuarter, sun events, day parts, amounts by type)")
    func dailyMapping() async throws {
        let (service, _) = makeRESTService()
        let daily = try await service.weather(for: fixtureLocation, including: .daily)
        #expect(daily.count == 2)
        let day = daily[0]
        #expect(day.condition == .flurries)
        #expect(day.moon.phase == .lastQuarter)
        #expect(day.highTemperature == Measurement(value: 0.4, unit: .celsius))
        #expect(day.lowTemperature == Measurement(value: -7.3, unit: .celsius))
        #expect(day.precipitation == .snow)
        #expect(day.precipitationAmountByType.precipitation == Measurement(value: 1.4, unit: .millimeters))
        #expect(day.precipitationAmountByType.snowfallAmount.amount == Measurement(value: 14, unit: .millimeters))
        #expect(day.uvIndex.value == 2)
        #expect(day.sun.sunrise == Date(timeIntervalSince1970: 1_768_481_280))
        #expect(day.sun.astronomicalDawn != nil && day.sun.civilDusk != nil && day.sun.solarMidnight != nil)
        #expect(day.daytimeForecast.condition == .flurries)
        #expect(day.daytimeForecast.wind.speed == Measurement(value: 23, unit: .kilometersPerHour))
        #expect(day.overnightForecast.precipitation == .rain)  // "precipitation" → rain
        #expect(day.maximumHumidity == 0.82)
        #expect(day.minimumHumidity == 0.74)
        #expect(daily[1].moon.phase == .waningCrescent)
        #expect(daily[1].precipitation == .none)
        #expect(daily[1].sun.sunrise == nil)
        #expect(daily[1].daytimeForecast.condition == .clear)  // synthesized from the day
    }

    @Test("rest-api.md §4.6: next hour minutes, summary periods and the summary sentence")
    func minuteMapping() async throws {
        let (service, _) = makeRESTService()
        let minute = try #require(try await service.weather(for: fixtureLocation, including: .minute))
        #expect(minute.count == 3)
        #expect(minute[0].precipitation == .none)
        #expect(minute[2].precipitation == .snow)
        #expect(minute[2].precipitationIntensity == Measurement(value: 0.8, unit: WeatherUnits.millimetersPerHour))
        #expect(minute.summary == "Snow starting in 20 min.")
        #expect(minute.metadata.expirationDate == fixtureAnchor.addingTimeInterval(300))
    }

    @Test("rest-api.md §4.6, behavior.md §7: alerts keep agency, headline, area, severity and details link")
    func alertMapping() async throws {
        let (service, _) = makeRESTService()
        let alerts = try #require(try await service.weather(for: fixtureLocation, including: .alerts))
        let alert = try #require(alerts.first)
        #expect(alert.source == "Example Weather Office")
        #expect(alert.summary == "Winter Weather Advisory")
        #expect(alert.region == "Example County")
        #expect(alert.severity == .moderate)
        #expect(alert.detailsURL.absoluteString == "https://example.invalid/alerts/0B8E9C2A")
        #expect(alert.metadata.expirationDate == fixtureAnchor.addingTimeInterval(600))
    }

    @Test("rest-api.md §1, §4.7: attribution comes from /attribution/{language} without a token; @3x marks")
    func attribution() async throws {
        let (service, http) = makeRESTService()
        let attribution = try await service.attribution
        let request = try #require(http.requests.first)
        #expect(request.url?.path == "/attribution/en-US")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(attribution.serviceName == "Example Weather")
        #expect(attribution.combinedMarkLightURL.absoluteString == "https://weather.example.invalid/assets/light@3x.png")
        #expect(attribution.combinedMarkDarkURL.absoluteString == "https://weather.example.invalid/assets/dark@3x.png")
        #expect(attribution.squareMarkURL.absoluteString == "https://cdn.example.invalid/square@3x.png")
        #expect(attribution.legalPageURL.absoluteString == "https://weather.example.invalid/legal-attribution.html")
    }

    @Test("rest-api.md §1: 401 → permissionDenied, 400 → unknown, malformed JSON → unknown, URLError passes through")
    func statusCodes() async throws {
        for (status, expected) in [(401, WeatherError.permissionDenied), (403, .permissionDenied), (400, .unknown), (500, .unknown)] {
            let (service, _) = makeRESTService { _ in (status, Data()) }
            await #expect(throws: expected, "status \(status)") {
                _ = try await service.weather(for: fixtureLocation, including: .current)
            }
        }
        let (malformed, _) = makeRESTService { _ in (200, Data("{\"currentWeather\": 5}".utf8)) }
        await #expect(throws: WeatherError.unknown) {
            _ = try await malformed.weather(for: fixtureLocation, including: .current)
        }
        let (missing, _) = makeRESTService { _ in (200, Data("{}".utf8)) }
        await #expect(throws: WeatherError.unknown) {
            _ = try await missing.weather(for: fixtureLocation, including: .current)
        }
        let (offline, _) = makeRESTService { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.weather(for: fixtureLocation, including: .current)
            Issue.record("expected an error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }

    @Test("rest-api.md §3: changes and comparisons are not in v1 (nil, no request); statistics are unsupported")
    func undocumentedProducts() async throws {
        let (service, http) = makeRESTService()
        let (changes, comparisons) = try await service.weather(for: fixtureLocation, including: .changes, .historicalComparisons)
        #expect(changes == nil)
        #expect(comparisons == nil)
        #expect(http.requests.isEmpty)
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.dailyStatistics(for: fixtureLocation, including: .temperature)
        }
    }

    @Test("C-CACHE with REST: the product's expireTime drives the cache")
    func restCache() async throws {
        let clock = TestClock()
        let (service, http) = makeRESTService(clock: clock)
        _ = try await service.weather(for: fixtureLocation, including: .current)
        clock.advance(599)
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(http.requests.count == 1)
        clock.advance(1)
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(http.requests.count == 2)
    }

    @Test("Two different daily ranges in one call need two requests (the API takes one range per data set)")
    func twoRanges() async throws {
        let (service, http) = makeRESTService()
        _ = try await service.weather(
            for: fixtureLocation, including: .daily, .daily(startDate: fixtureAnchor, endDate: fixtureAnchor.addingTimeInterval(86_400)))
        #expect(http.requests.count == 2)
        #expect(query(http.requests[0])["dailyStart"] == nil)
        #expect(query(http.requests[1])["dailyStart"] == "2026-01-15T12:00:00Z")
    }

    @Test("design.md §3: WEATHERKIT_BACKEND=apple-rest uses the configured token; without one it is unconfigured")
    func environment() {
        #expect(WeatherService.environmentBackend(["WEATHERKIT_BACKEND": "apple-rest"]) is UnconfiguredWeatherBackend)
        let withToken = WeatherService.environmentBackend(["WEATHERKIT_BACKEND": "apple-rest", "WEATHERKIT_TOKEN": "t"])
        #expect(withToken is AppleRESTWeatherBackend)
        #expect(withToken.identifier == "apple-rest:weatherkit.apple.com")
        let withURL = WeatherService.environmentBackend(
            ["WEATHERKIT_BACKEND": "apple-rest", "WEATHERKIT_TOKEN_URL": "https://tokens.example.invalid/t"])
        #expect(withURL is AppleRESTWeatherBackend)
        let missingKey = WeatherService.environmentBackend([
            "WEATHERKIT_BACKEND": "apple-rest", "WEATHERKIT_TEAM_ID": "T", "WEATHERKIT_SERVICE_ID": "S",
            "WEATHERKIT_KEY_ID": "K", "WEATHERKIT_KEY_FILE": "/nonexistent-ycode-key.p8",
        ])
        #expect(missingKey is UnconfiguredWeatherBackend)
    }

    @Test("Path coordinates are the rounded values in shortest form")
    func coordinates() {
        #expect(AppleRESTWeatherBackend.coordinate(41.5) == "41.5")
        #expect(AppleRESTWeatherBackend.coordinate(-81.0) == "-81")
        #expect(AppleRESTWeatherBackend.coordinate(12.345) == "12.345")
        #expect(AppleRESTWeatherBackend.coordinate(0.001) == "0.001")
    }
}
