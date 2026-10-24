// C-CACHE (plan.md §2): caching and expiry (behavior.md §3, design.md §6).
import CoreLocation
import Foundation
import Testing
@testable import WeatherKit

@Suite("C-CACHE: caching and expiry (behavior.md §3)")
struct CacheTests {
    @Test("behavior.md §3: a repeated call before expiry is answered from the cache")
    func hitBeforeExpiry() async throws {
        let clock = TestClock()
        let (service, backend) = try makeService(clock: clock)
        let first = try await service.weather(for: fixtureLocation, including: .current)
        clock.advance(599)  // currentWeather expires after 600 s in the bundled set
        let second = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.count == 1)
        #expect(first == second)
        #expect(first.metadata.expirationDate == fixtureAnchor.addingTimeInterval(600))
    }

    @Test("behavior.md §3: at and after expiry the product is fetched again")
    func refetchAfterExpiry() async throws {
        let clock = TestClock()
        let (service, backend) = try makeService(clock: clock)
        _ = try await service.weather(for: fixtureLocation, including: .current)
        clock.advance(600)
        let again = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.count == 2)
        #expect(again.metadata.date == fixtureAnchor.addingTimeInterval(600))
    }

    @Test("behavior.md §3: a failing refresh after expiry throws; expired data is never returned")
    func noStaleFallback() async throws {
        let clock = TestClock()
        let (service, backend) = try makeService(clock: clock)
        _ = try await service.weather(for: fixtureLocation, including: .current)
        clock.advance(601)
        backend.failure = WeatherBackendError.httpStatus(503)
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.weather(for: fixtureLocation, including: .current)
        }
        #expect(backend.requests.count == 2)
        backend.failure = nil
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.count == 3)
    }

    @Test("design.md §6: concurrent identical calls share one backend request")
    func coalescing() async throws {
        let (service, backend) = try makeService()
        backend.delay = .milliseconds(200)
        let results = try await withThrowingTaskGroup(of: CurrentWeather.self) { group in
            for _ in 0..<8 {
                group.addTask { try await service.weather(for: fixtureLocation, including: .current) }
            }
            var results: [CurrentWeather] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 8)
        #expect(Set(results.map(\.date)).count == 1)
        #expect(backend.requests.count == 1)
    }

    @Test("design.md §6: a call overlapping an in-flight one waits for it and asks only for what is missing")
    func partialOverlap() async throws {
        let (service, backend) = try makeService()
        backend.delay = .milliseconds(300)
        async let first = service.weather(for: fixtureLocation, including: .current)
        try await Task.sleep(for: .milliseconds(50))
        async let second = service.weather(for: fixtureLocation, including: .current, .daily)
        _ = try await (first, second)
        #expect(backend.requests.count == 2)
        #expect(backend.requests.map(\.products).contains([WeatherProductRequest(product: .forecastDaily)]))
    }

    @Test("behavior.md §3: a partial hit requests only the missing products")
    func partialHit() async throws {
        let (service, backend) = try makeService()
        _ = try await service.weather(for: fixtureLocation, including: .current)
        _ = try await service.weather(for: fixtureLocation, including: .current, .daily, .alerts)
        #expect(backend.requests.count == 2)
        #expect(products(backend) == [
            WeatherProductRequest(product: .forecastDaily), WeatherProductRequest(product: .weatherAlerts),
        ])
        _ = try await service.weather(for: fixtureLocation, including: .alerts, .current, .daily)
        #expect(backend.requests.count == 2)
    }

    @Test("behavior.md §2–§3: locations that round to the same 3-decimal coordinate share the cache")
    func roundedKey() async throws {
        let (service, backend) = try makeService()
        _ = try await service.weather(for: CLLocation(latitude: 41.5004, longitude: -81.4996), including: .current)
        _ = try await service.weather(for: CLLocation(latitude: 41.4996, longitude: -81.5004), including: .current)
        #expect(backend.requests.count == 1)
        _ = try await service.weather(for: CLLocation(latitude: 41.5006, longitude: -81.5), including: .current)
        #expect(backend.requests.count == 2)
    }

    @Test("behavior.md §3: the key includes language and requested range")
    func keyParts() async throws {
        let clock = TestClock()
        let english = try makeService(clock: clock, language: "en-US")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-weatherkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await english.0.weather(for: fixtureLocation, including: .daily)
        _ = try await english.0.weather(
            for: fixtureLocation, including: .daily(startDate: fixtureAnchor, endDate: fixtureAnchor.addingTimeInterval(86_400)))
        _ = try await english.0.weather(
            for: fixtureLocation, including: .daily(startDate: fixtureAnchor, endDate: fixtureAnchor.addingTimeInterval(86_400)))
        #expect(english.1.requests.count == 2)

        // Two services sharing one persistent store, different languages.
        let backend = RecordingBackend(try FixtureWeatherBackend.bundled())
        let french = WeatherService(backend: backend, configuration: .init(language: "fr-FR", cacheDirectory: directory, clock: { clock.now }))
        let german = WeatherService(backend: backend, configuration: .init(language: "de-DE", cacheDirectory: directory, clock: { clock.now }))
        _ = try await french.weather(for: fixtureLocation, including: .current)
        _ = try await german.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.map(\.language) == ["fr-FR", "de-DE"])
    }

    @Test("design.md §6: the cache persists across instances when a directory is configured; expiry still applies")
    func persistence() async throws {
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-weatherkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, firstBackend) = try makeService(clock: clock, cacheDirectory: directory)
        let original = try await first.weather(for: fixtureLocation)
        #expect(firstBackend.requests.count == 1)

        let (second, secondBackend) = try makeService(clock: clock, cacheDirectory: directory)
        let restored = try await second.weather(for: fixtureLocation)
        #expect(secondBackend.requests.isEmpty)
        #expect(restored == original)

        clock.advance(601)
        let (third, thirdBackend) = try makeService(clock: clock, cacheDirectory: directory)
        _ = try await third.weather(for: fixtureLocation)
        // current (600 s), minute (300 s) and alerts (600 s) expired; the rest did not.
        #expect(thirdBackend.requests.count == 1)
        #expect(Set(products(thirdBackend).map(\.product)) == [.currentWeather, .forecastNextHour, .weatherAlerts])
    }

    @Test("behavior.md §3: results that arrive already expired are returned but not cached")
    func expiredOnArrival() async throws {
        let clock = TestClock()
        let (service, backend) = try makeService(clock: clock)
        backend.rewrite = { response in
            response.mapValues { WeatherProductResult(value: $0.value, expirationDate: Date(timeIntervalSince1970: 0)) }
        }
        _ = try await service.weather(for: fixtureLocation, including: .current)
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.count == 2)
    }

    @Test("design.md §6: removeCachedData empties the cache")
    func removeAll() async throws {
        let (service, backend) = try makeService()
        _ = try await service.weather(for: fixtureLocation, including: .current)
        await service.removeCachedData()
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.count == 2)
    }

    @Test("simulator-baseline.md §2: attribution is fetched once and then served from memory")
    func attributionCached() async throws {
        let (service, backend) = try makeService()
        let first = try await service.attribution
        let second = try await service.attribution
        #expect(first == second)
        #expect(backend.attributionCalls == 1)
        #expect(first.legalAttributionText.contains("Fixture data"))
    }
}
