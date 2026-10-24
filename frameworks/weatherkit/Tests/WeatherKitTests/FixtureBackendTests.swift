// The fixture backend (plan.md R3, design.md §2–§3) and the Linux
// CoreLocation shim (design.md §2).
import CoreLocation
import Foundation
import Testing
@testable import WeatherKit

@Suite("Fixture backend (design.md §3)")
struct FixtureBackendTests {
    @Test("design.md §3: fixture attribution names 'Fixture data' with a legal page and marks")
    func attribution() async throws {
        let attribution = try await FixtureWeatherBackend.bundled().attribution(language: "en-US")
        #expect(attribution.serviceName == "Fixture data")
        #expect(attribution.legalPageURL.host == "fixtures.invalid")
        #expect(attribution.squareMarkURL.lastPathComponent == "square-mark.png")
        #expect(attribution.combinedMarkLightURL != attribution.combinedMarkDarkURL)
        #expect(attribution.legalAttributionText.split(separator: "\n").count == 3)
    }

    @Test("Rebase by days: a request a week later sees the same weather shifted to its own day")
    func rebaseDays() async throws {
        let clock = TestClock(fixtureAnchor.addingTimeInterval(7 * 86_400 + 3 * 3600))  // 2026-01-22T15:00Z
        let (service, _) = try makeService(clock: clock)
        let (daily, hourly, minute, current) = try await service.weather(
            for: fixtureLocation, including: .daily, .hourly, .minute, .current)
        let today = Date(timeIntervalSince1970: 1_768_435_200 + 7 * 86_400)
        #expect(daily.first?.date == today)
        #expect(daily.count == 10)
        #expect(hourly.first?.date == clock.now)
        #expect(minute?.first?.date == clock.now)
        #expect(minute?.count == 60)
        #expect(current.date == fixtureAnchor.addingTimeInterval(7 * 86_400))
        #expect(current.metadata.date == clock.now)
        #expect(current.metadata.expirationDate == clock.now.addingTimeInterval(600))
        #expect(daily.metadata.expirationDate == clock.now.addingTimeInterval(3600))
    }

    @Test("Rebase none: dates as written")
    func rebaseNone() async throws {
        let backend = try FixtureWeatherBackend.bundled(rebase: WeatherKit.FixtureWeatherBackend.Rebase.none)
        let request = WeatherBackendRequest(
            latitude: 1, longitude: 2, language: "en-US",
            products: [WeatherProductRequest(product: .forecastDaily, range: .dates(start: .distantPast, end: .distantFuture))],
            requestDate: fixtureAnchor.addingTimeInterval(30 * 86_400))
        let response = try await backend.weather(for: request)
        guard case .forecastDaily(let daily)? = response.values.first?.value else {
            Issue.record("no daily forecast")
            return
        }
        #expect(daily.first?.date == Date(timeIntervalSince1970: 1_768_435_200))
        #expect(daily.metadata.location.coordinate.latitude == 1)
        #expect(daily.metadata.location.coordinate.longitude == 2)
    }

    @Test("Statistics products the set lacks are unsupported (→ WeatherError.unknown)")
    func missingProduct() async throws {
        let source = try FixtureWeatherBackend.bundled().directory
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-weatherkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["weather.json", "attribution.json"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        let manifest = #"{"name": "small", "anchorDate": "2026-01-15T12:00:00Z", "weather": "weather.json", "attribution": "attribution.json"}"#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("fixture.json"))
        let backend = RecordingBackend(try FixtureWeatherBackend(directory: directory))
        let clock = TestClock()
        let service = WeatherService(backend: backend, configuration: .init(language: "en-US", clock: { clock.now }))
        #expect(backend.identifier == "fixtures:small")
        let comparisons = try await service.weather(for: fixtureLocation, including: .historicalComparisons)
        #expect(comparisons == nil)
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.monthlyStatistics(for: fixtureLocation, including: .temperature)
        }
        // Default expiration without an expiration table: one hour.
        let current = try await service.weather(for: fixtureLocation, including: .current)
        #expect(current.metadata.expirationDate == clock.now.addingTimeInterval(3600))
    }

    @Test("A broken fixture directory fails to load")
    func brokenDirectory() {
        #expect(throws: (any Error).self) {
            _ = try FixtureWeatherBackend(directory: URL(fileURLWithPath: "/nonexistent-ycode-fixtures"))
        }
    }

    @Test("design.md §3: WEATHERKIT_BACKEND=fixtures selects the fixture backend; unset or unknown is unconfigured")
    func environmentSelection() throws {
        #expect(WeatherService.environmentBackend([:]) is UnconfiguredWeatherBackend)
        #expect(WeatherService.environmentBackend(["WEATHERKIT_BACKEND": "apple-rest"]) is UnconfiguredWeatherBackend)
        let bundled = WeatherService.environmentBackend(["WEATHERKIT_BACKEND": "fixtures"])
        #expect((bundled as? FixtureWeatherBackend)?.identifier == "fixtures:default")
        let directory = try FixtureWeatherBackend.bundled().directory
        let explicit = WeatherService.environmentBackend(["WEATHERKIT_BACKEND": "fixtures", "WEATHERKIT_FIXTURES": directory.path])
        #expect((explicit as? FixtureWeatherBackend)?.directory.standardizedFileURL == directory.standardizedFileURL)
        let broken = WeatherService.environmentBackend(["WEATHERKIT_BACKEND": "fixtures", "WEATHERKIT_FIXTURES": "/nonexistent-ycode-fixtures"])
        #expect(broken is FailingWeatherBackend)
    }
}

@Suite("CoreLocation shim (design.md §2)")
struct CoreLocationShimTests {
    @Test("CLLocation keeps the values it was made with")
    func values() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 20), altitude: 30, horizontalAccuracy: 5,
            verticalAccuracy: 6, course: 90, speed: 3, timestamp: Date(timeIntervalSince1970: 100))
        #expect(location.coordinate.latitude == 10)
        #expect(location.coordinate.longitude == 20)
        #expect(location.altitude == 30)
        #expect(location.horizontalAccuracy == 5)
        #expect(location.verticalAccuracy == 6)
        #expect(location.course == 90)
        #expect(location.speed == 3)
        #expect(location.timestamp == Date(timeIntervalSince1970: 100))
        #expect(CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: 10, longitude: 20)))
        #expect(!CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: 91, longitude: 0)))
    }

    @Test("CLLocation.distance(from:) is the great-circle distance")
    func distance() {
        let a = CLLocation(latitude: 0, longitude: 0)
        let b = CLLocation(latitude: 0, longitude: 1)
        // One degree of longitude at the equator: about 111.2 km.
        #expect(abs(a.distance(from: b) - 111_195) < 600)
        #expect(a.distance(from: a) == 0)
    }

    #if !canImport(Darwin)
    @Test("Shim defaults: init(latitude:longitude:) leaves motion and vertical accuracy invalid")
    func shimDefaults() {
        let location = CLLocation(latitude: 1, longitude: 2)
        #expect(location.horizontalAccuracy == 0)
        #expect(location.verticalAccuracy == -1)
        #expect(location.speed == -1)
        #expect(location.course == -1)
        #expect(location.floor == nil)
        #expect(kCLLocationAccuracyBest == -1)
        #expect(kCLDistanceFilterNone == -1)
        #expect(!CLLocationCoordinate2DIsValid(kCLLocationCoordinate2DInvalid))
    }
    #endif
}
