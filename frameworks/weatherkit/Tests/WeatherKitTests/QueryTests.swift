// C-QUERY (plan.md §2): request composition against a recording backend
// (behavior.md §1–§2, api.md §2.1).
import CoreLocation
import Foundation
import Testing
@testable import WeatherKit

@Suite("C-QUERY: request composition (behavior.md §1)")
struct QueryTests {
    private func request(_ product: WeatherProduct, _ range: WeatherProductRange? = nil) -> WeatherProductRequest {
        WeatherProductRequest(product: product, range: range)
    }

    @Test("behavior.md §1: each query maps to exactly its product, one request per call")
    func singleQueries() async throws {
        let cases: [(String, WeatherProduct, (WeatherService) async throws -> Void)] = [
            ("current", .currentWeather, { _ = try await $0.weather(for: fixtureLocation, including: .current) }),
            ("minute", .forecastNextHour, { _ = try await $0.weather(for: fixtureLocation, including: .minute) }),
            ("hourly", .forecastHourly, { _ = try await $0.weather(for: fixtureLocation, including: .hourly) }),
            ("daily", .forecastDaily, { _ = try await $0.weather(for: fixtureLocation, including: .daily) }),
            ("alerts", .weatherAlerts, { _ = try await $0.weather(for: fixtureLocation, including: .alerts) }),
            ("availability", .availability, { _ = try await $0.weather(for: fixtureLocation, including: .availability) }),
            ("changes", .weatherChanges, { _ = try await $0.weather(for: fixtureLocation, including: .changes) }),
            ("historicalComparisons", .historicalComparisons,
             { _ = try await $0.weather(for: fixtureLocation, including: .historicalComparisons) }),
        ]
        for (name, product, call) in cases {
            let (service, backend) = try makeService()
            try await call(service)
            #expect(backend.requests.count == 1, "\(name)")
            #expect(products(backend) == [request(product)], "\(name)")
        }
    }

    @Test("behavior.md §1: weather(for:) asks for current, daily, hourly, next hour, alerts, changes (+ availability) in one request")
    func fullWeather() async throws {
        let (service, backend) = try makeService()
        let weather = try await service.weather(for: fixtureLocation)
        #expect(backend.requests.count == 1)
        #expect(products(backend) == [
            request(.currentWeather), request(.forecastDaily), request(.forecastHourly), request(.forecastNextHour),
            request(.weatherAlerts), request(.weatherChanges), request(.availability),
        ])
        #expect(weather.minuteForecast?.count == 60)
        #expect(weather.weatherAlerts?.count == 1)
        #expect(weather.availability.alertAvailability == .available)
    }

    @Test("behavior.md §1: query combinations ask for exactly those products, results in argument order")
    func combinations() async throws {
        let (service, backend) = try makeService()
        let (daily, current) = try await service.weather(for: fixtureLocation, including: .daily, .current)
        #expect(products(backend) == [request(.forecastDaily), request(.currentWeather)])
        #expect(daily.count == 10)
        #expect(current.condition == .partlyCloudy)

        let (alerts, hourly, availability) = try await service.weather(
            for: fixtureLocation, including: .alerts, .hourly, .availability)
        #expect(backend.requests.count == 2)
        #expect(products(backend) == [request(.weatherAlerts), request(.forecastHourly), request(.availability)])
        #expect(alerts?.first?.source == "Ycode Fixture Weather Office")
        #expect(hourly.first?.date == fixtureAnchor)
        #expect(availability.minuteAvailability == .available)
    }

    @Test("behavior.md §1: seven or more queries go through the parameter pack, still one request")
    func parameterPack() async throws {
        let (service, backend) = try makeService()
        let start = fixtureAnchor
        let end = fixtureAnchor.addingTimeInterval(6 * 3600)
        let result = try await service.weather(
            for: fixtureLocation, including: .current, .minute, .hourly(startDate: start, endDate: end), .daily,
            .alerts, .availability, .changes, .historicalComparisons)
        #expect(backend.requests.count == 1)
        #expect(products(backend) == [
            request(.currentWeather), request(.forecastNextHour),
            request(.forecastHourly, .dates(start: start, end: end)), request(.forecastDaily),
            request(.weatherAlerts), request(.availability), request(.weatherChanges),
            request(.historicalComparisons),
        ])
        #expect(result.2.count == 6)
    }

    @Test("behavior.md §1: date ranges are passed with exactly the caller's dates; no range sends none")
    func dateRanges() async throws {
        let (service, backend) = try makeService()
        let start = Date(timeIntervalSince1970: 1_768_523_402)  // 2026-01-16T00:30:02Z
        let end = start.addingTimeInterval(3 * 86_400 + 1)
        let daily = try await service.weather(for: fixtureLocation, including: .daily(startDate: start, endDate: end))
        #expect(products(backend) == [request(.forecastDaily, .dates(start: start, end: end))])
        #expect(daily.map(\.date) == [2, 3, 4].map { Date(timeIntervalSince1970: 1_768_435_200 + Double($0) * 86_400) })

        let hourStart = fixtureAnchor.addingTimeInterval(1800)
        let hourEnd = fixtureAnchor.addingTimeInterval(3 * 3600)
        let hourly = try await service.weather(for: fixtureLocation, including: .hourly(startDate: hourStart, endDate: hourEnd))
        #expect(products(backend) == [request(.forecastHourly, .dates(start: hourStart, end: hourEnd))])
        #expect(hourly.count == 2)

        _ = try await service.weather(for: fixtureLocation, including: .hourly)
        #expect(products(backend) == [request(.forecastHourly)])
    }

    @Test("simulator-baseline.md §3: a zero-length range is accepted")
    func zeroLengthRange() async throws {
        let (service, backend) = try makeService()
        let daily = try await service.weather(
            for: fixtureLocation, including: .daily(startDate: fixtureAnchor, endDate: fixtureAnchor))
        #expect(daily.isEmpty)
        let hourly = try await service.weather(
            for: fixtureLocation, including: .hourly(startDate: fixtureAnchor, endDate: fixtureAnchor))
        #expect(hourly.isEmpty)
        #expect(backend.requests.count == 2)
    }

    @Test("api.md §2.1: a daily range whose end precedes its start traps")
    func reversedDailyRangeTraps() async {
        await #expect(processExitsWith: .failure) {
            let start = Date(timeIntervalSince1970: 1_768_478_400)
            _ = WeatherQuery.daily(startDate: start, endDate: start.addingTimeInterval(-1))
        }
    }

    @Test("api.md §2.1: an hourly range whose end precedes its start traps")
    func reversedHourlyRangeTraps() async {
        await #expect(processExitsWith: .failure) {
            let start = Date(timeIntervalSince1970: 1_768_478_400)
            _ = WeatherQuery.hourly(startDate: start, endDate: start.addingTimeInterval(-3600))
        }
    }

    @Test("behavior.md §2: coordinates are rounded to 3 decimal places; only the coordinate is used")
    func coordinateRounding() async throws {
        let (service, backend) = try makeService()
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 12.34549, longitude: -98.76551), altitude: 1234,
            horizontalAccuracy: 3, verticalAccuracy: 4, timestamp: Date(timeIntervalSince1970: 0))
        let current = try await service.weather(for: location, including: .current)
        let sent = try #require(backend.requests.last)
        #expect(sent.latitude == 12.345)
        #expect(sent.longitude == -98.766)
        #expect(current.metadata.location.coordinate.latitude == 12.345)
        #expect(current.metadata.location.coordinate.longitude == -98.766)
        #expect(roundedThousandths(0.0005) == 1)
        #expect(roundedThousandths(-0.0005) == -1)
        #expect(roundedThousandths(.nan) == nil)
    }

    @Test("behavior.md §2: no client-side range check; invalid latitudes reach the backend")
    func invalidLatitude() async throws {
        let (service, backend) = try makeService()
        _ = try await service.weather(for: CLLocation(latitude: 200, longitude: 0), including: .current)
        #expect(backend.requests.last?.latitude == 200)
    }

    @Test("behavior.md §2: the language goes with the request, en-US form")
    func language() async throws {
        let (service, backend) = try makeService(language: "pt_BR")
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.last?.language == "pt-BR")
        #expect(WeatherService.Configuration.normalizedLanguage("en_US.UTF-8") == "en-US")
        #expect(WeatherService.Configuration.normalizedLanguage("C") == "en-US")
    }

    @Test("behavior.md §1: the same query twice in one call is asked for once")
    func duplicatesCollapse() async throws {
        let (service, backend) = try makeService()
        let (a, b) = try await service.weather(for: fixtureLocation, including: .current, .current)
        #expect(a == b)
        #expect(products(backend) == [request(.currentWeather)])
    }

    @Test("api.md §1: statistics ranges are passed as day/hour/month numbers or the caller's interval")
    func statisticsRanges() async throws {
        let (service, backend) = try makeService()
        _ = try await service.dailyStatistics(for: fixtureLocation, startDay: 3, endDay: 9, including: .temperature, .precipitation)
        #expect(products(backend) == [
            request(.dailyTemperatureStatistics, .indices(start: 3, end: 9)),
            request(.dailyPrecipitationStatistics, .indices(start: 3, end: 9)),
        ])
        let interval = DateInterval(start: fixtureAnchor, duration: 86_400)
        _ = try await service.dailySummary(for: fixtureLocation, forDaysIn: interval, including: .precipitation)
        #expect(products(backend) == [
            request(.dailyPrecipitationSummary, .dates(start: interval.start, end: interval.end))
        ])
        _ = try await service.monthlyStatistics(for: fixtureLocation, including: .temperature)
        #expect(products(backend) == [request(.monthlyTemperatureStatistics)])
        #expect(backend.requests.count == 3)
    }
}
