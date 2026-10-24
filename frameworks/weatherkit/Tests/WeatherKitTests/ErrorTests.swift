// C-ERRORS (plan.md §2): error mapping and cancellation (behavior.md §4–§5,
// plan.md §3).
import CoreLocation
import Foundation
import Testing
@testable import WeatherKit

@Suite("C-ERRORS: errors and cancellation (behavior.md §4–§5)")
struct ErrorTests {
    @Test("behavior.md §4: 401 and 403 become WeatherError.permissionDenied", arguments: [401, 403])
    func unauthorized(status: Int) async throws {
        let (service, backend) = try makeService()
        backend.failure = WeatherBackendError.httpStatus(status)
        await #expect(throws: WeatherError.permissionDenied) {
            _ = try await service.weather(for: fixtureLocation, including: .current)
        }
        await #expect(throws: WeatherError.permissionDenied) {
            _ = try await service.attribution
        }
    }

    @Test("behavior.md §4: authentication failures become permissionDenied")
    func notAuthorized() async throws {
        let (service, backend) = try makeService()
        backend.failure = WeatherBackendError.notAuthorized
        await #expect(throws: WeatherError.permissionDenied) {
            _ = try await service.weather(for: fixtureLocation)
        }
    }

    @Test("behavior.md §4: other service errors become WeatherError.unknown",
          arguments: [
            WeatherBackendError.httpStatus(400), .httpStatus(404), .httpStatus(429), .httpStatus(500),
            .malformedResponse("bad"), .unsupported("x"),
          ])
    func otherServiceErrors(error: WeatherBackendError) async throws {
        let (service, backend) = try makeService()
        backend.failure = error
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.weather(for: fixtureLocation, including: .daily)
        }
    }

    @Test("behavior.md §4: malformed data (decoding failure) becomes unknown")
    func malformedData() async throws {
        let (service, backend) = try makeService()
        backend.failure = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "garbage"))
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.weather(for: fixtureLocation, including: .current)
        }
    }

    @Test("behavior.md §4: a response without a requested product becomes unknown")
    func missingProduct() async throws {
        let (service, backend) = try makeService()
        backend.rewrite = { $0.filter { $0.key.product != .forecastDaily } }
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.weather(for: fixtureLocation, including: .current, .daily)
        }
    }

    @Test("behavior.md §4: transport errors (URLError) pass through unchanged")
    func transportPassThrough() async throws {
        let (service, backend) = try makeService()
        backend.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await service.weather(for: fixtureLocation, including: .current)
            Issue.record("expected an error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }

    @Test("behavior.md §5: a task cancelled before the call throws CancellationError without network access")
    func cancelledBefore() async throws {
        let (service, backend) = try makeService()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.weather(for: fixtureLocation, including: .current)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(backend.requests.isEmpty)
    }

    @Test("behavior.md §5: cancelling during a slow request throws CancellationError and cancels the request")
    func cancelledDuring() async throws {
        let (service, backend) = try makeService()
        backend.delay = .seconds(30)
        let task = Task { try await service.weather(for: fixtureLocation, including: .current) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(backend.cancelledCalls == 1)
        // Nothing was cached; the next call fetches.
        backend.delay = nil
        _ = try await service.weather(for: fixtureLocation, including: .current)
        #expect(backend.requests.count == 2)
    }

    @Test("design.md §6: one cancelled waiter does not cancel a request others still wait for")
    func cancelOneOfTwo() async throws {
        let (service, backend) = try makeService()
        backend.delay = .milliseconds(400)
        let cancelled = Task { try await service.weather(for: fixtureLocation, including: .current) }
        let kept = Task { try await service.weather(for: fixtureLocation, including: .current) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        let value = try await kept.value
        #expect(value.condition == .partlyCloudy)
        #expect(backend.requests.count == 1)
        #expect(backend.cancelledCalls == 0)
    }

    @Test("simulator-baseline.md §1: without a configured backend every call throws permissionDenied")
    func unconfigured() async throws {
        let service = WeatherService(backend: UnconfiguredWeatherBackend())
        await #expect(throws: WeatherError.permissionDenied) {
            _ = try await service.weather(for: fixtureLocation)
        }
        await #expect(throws: WeatherError.permissionDenied) {
            _ = try await service.attribution
        }
    }

    @Test("behavior.md §4: errors of other kinds become unknown; WeatherError passes through")
    func mapping() {
        struct Other: Error {}
        #expect(mapServiceError(Other()) as? WeatherError == .unknown)
        #expect(mapServiceError(WeatherError.permissionDenied) as? WeatherError == .permissionDenied)
        #expect(mapServiceError(CancellationError()) is CancellationError)
        #expect((mapServiceError(URLError(.timedOut)) as? URLError)?.code == .timedOut)
        #expect(mapServiceError(CocoaError(.fileReadNoSuchFile)) as? WeatherError == .unknown)
    }

    @Test("behavior.md §2: a non-finite coordinate fails with unknown before any request")
    func nonFiniteCoordinate() async throws {
        let (service, backend) = try makeService()
        await #expect(throws: WeatherError.unknown) {
            _ = try await service.weather(for: CLLocation(latitude: .nan, longitude: 0), including: .current)
        }
        #expect(backend.requests.isEmpty)
    }
}
