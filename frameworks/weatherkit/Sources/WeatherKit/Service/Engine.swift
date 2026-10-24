// The service engine (design.md §6, behavior.md §1–§5): request planning,
// the product cache with expiry and coordinate rounding, coalescing of
// identical in-flight requests, cancellation and error mapping.
import Foundation

/// Cache key: backend, product with range, coordinate rounded to 3 decimal
/// places (as integer thousandths), language (behavior.md §3).
struct CacheKey: Hashable, Codable, Sendable {
    let backend: String
    let request: WeatherProductRequest
    let latitudeE3: Int
    let longitudeE3: Int
    let language: String

    /// Stable file name for the persistent store (FNV-1a 64 of the key text).
    var fileName: String {
        let text = "\(backend)|\(request)|\(latitudeE3)|\(longitudeE3)|\(language)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// Rounds a coordinate to thousandths of a degree (~110 m), half away from zero.
func roundedThousandths(_ degrees: Double) -> Int? {
    guard degrees.isFinite, abs(degrees) < 1e12 else { return nil }
    return Int((degrees * 1000).rounded(.toNearestOrAwayFromZero))
}

/// Maps a backend or transport failure to what the caller sees
/// (behavior.md §4, plan.md §3).
func mapServiceError(_ error: any Error) -> any Error {
    switch error {
    case let error as WeatherError:
        return error
    case let error as CancellationError:
        return error
    case let error as URLError:
        return error
    case let error as WeatherBackendError:
        switch error {
        case .notAuthorized:
            return WeatherError.permissionDenied
        case .httpStatus(let status) where status == 401 || status == 403:
            return WeatherError.permissionDenied
        default:
            return WeatherError.unknown
        }
    default:
        return WeatherError.unknown
    }
}

actor WeatherEngine {
    typealias Response = [WeatherProductRequest: WeatherProductResult]

    private struct Batch {
        let task: Task<Response, any Error>
        var waiters: Int
    }

    private struct PersistedEntry: Codable {
        let key: CacheKey
        let result: WeatherProductResult
    }

    let backend: any WeatherBackend
    let configuration: WeatherService.Configuration
    private let language: String

    private var memory: [CacheKey: WeatherProductResult] = [:]
    private var inFlight: [CacheKey: Int] = [:]
    private var batches: [Int: Batch] = [:]
    private var nextBatchID = 0
    private var attributions: [String: WeatherAttribution] = [:]
    private var attributionTasks: [String: Task<WeatherAttribution, any Error>] = [:]

    init(backend: any WeatherBackend, configuration: WeatherService.Configuration) {
        self.backend = backend
        self.configuration = configuration
        self.language = configuration.language.map(WeatherService.Configuration.normalizedLanguage)
            ?? WeatherService.Configuration.preferredLanguage()
    }

    // MARK: Products

    /// Answers every request from the cache or from one backend call.
    func fetch(latitude: Double, longitude: Double, requests: [WeatherProductRequest]) async throws
        -> [WeatherProductRequest: WeatherProductValue]
    {
        try Task.checkCancellation()
        guard let latitudeE3 = roundedThousandths(latitude), let longitudeE3 = roundedThousandths(longitude) else {
            throw WeatherError.unknown
        }
        var unique: [WeatherProductRequest] = []
        for request in requests where !unique.contains(request) {
            unique.append(request)
        }

        let now = configuration.clock()
        var values: [WeatherProductRequest: WeatherProductValue] = [:]
        var waits: [Int: [WeatherProductRequest]] = [:]
        var missing: [WeatherProductRequest] = []
        for request in unique {
            let key = CacheKey(
                backend: backend.identifier, request: request, latitudeE3: latitudeE3,
                longitudeE3: longitudeE3, language: language)
            if let hit = cachedResult(for: key, now: now) {
                values[request] = hit.value
            } else if let batchID = inFlight[key] {
                waits[batchID, default: []].append(request)
            } else {
                missing.append(request)
            }
        }

        if !missing.isEmpty {
            // Cancellation is checked before network access (behavior.md §5).
            try Task.checkCancellation()
            let batchID = nextBatchID
            nextBatchID += 1
            let backendRequest = WeatherBackendRequest(
                latitude: Double(latitudeE3) / 1000, longitude: Double(longitudeE3) / 1000,
                language: language, products: missing, requestDate: now)
            let keys = missing.map {
                CacheKey(
                    backend: backend.identifier, request: $0, latitudeE3: latitudeE3,
                    longitudeE3: longitudeE3, language: language)
            }
            let task = Task { try await self.run(batchID: batchID, request: backendRequest, keys: keys) }
            batches[batchID] = Batch(task: task, waiters: 0)
            for key in keys { inFlight[key] = batchID }
            waits[batchID] = missing
        }

        var tasks: [(Int, Task<Response, any Error>, [WeatherProductRequest])] = []
        for (batchID, requests) in waits.sorted(by: { $0.key < $1.key }) {
            guard var batch = batches[batchID] else { continue }
            batch.waiters += 1
            batches[batchID] = batch
            tasks.append((batchID, batch.task, requests))
        }

        for (batchID, task, requests) in tasks {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.release(batchID: batchID) }
            }
            for request in requests {
                guard let result = response[request] else { throw WeatherError.unknown }
                values[request] = result.value
            }
        }
        try Task.checkCancellation()
        return values
    }

    /// A live cache entry; expired entries are dropped, never returned.
    private func cachedResult(for key: CacheKey, now: Date) -> WeatherProductResult? {
        if let hit = memory[key] {
            if now < hit.expirationDate { return hit }
            memory[key] = nil
            removePersisted(key)
            return nil
        }
        if let stored = loadPersisted(key) {
            if now < stored.expirationDate {
                memory[key] = stored
                return stored
            }
            removePersisted(key)
        }
        return nil
    }

    /// One backend call. Successful, unexpired results are cached; errors
    /// are mapped; nothing stale is ever substituted.
    private func run(batchID: Int, request: WeatherBackendRequest, keys: [CacheKey]) async throws -> Response {
        defer {
            for key in keys where inFlight[key] == batchID { inFlight[key] = nil }
            batches[batchID] = nil
        }
        let response: Response
        do {
            try Task.checkCancellation()
            response = try await backend.weather(for: request)
        } catch {
            throw mapServiceError(error)
        }
        let now = configuration.clock()
        for key in keys {
            guard let result = response[key.request] else { throw WeatherError.unknown }
            guard result.value.product == key.request.product else { throw WeatherError.unknown }
            if now < result.expirationDate {
                memory[key] = result
                storePersisted(key, result)
            }
        }
        return response
    }

    /// A waiter was cancelled; the backend call is cancelled when nobody
    /// else waits for it.
    private func release(batchID: Int) {
        guard var batch = batches[batchID] else { return }
        batch.waiters -= 1
        batches[batchID] = batch
        if batch.waiters <= 0 { batch.task.cancel() }
    }

    /// Drops every cached product (memory and persistent store).
    func removeAll() {
        for key in memory.keys { removePersisted(key) }
        memory.removeAll()
        attributions.removeAll()
    }

    // MARK: Persistent store

    private func persistedURL(_ key: CacheKey) -> URL? {
        configuration.cacheDirectory?.appendingPathComponent(key.fileName + ".json")
    }

    private func loadPersisted(_ key: CacheKey) -> WeatherProductResult? {
        guard let url = persistedURL(key), let data = try? Data(contentsOf: url),
            let entry = try? JSONDecoder().decode(PersistedEntry.self, from: data), entry.key == key
        else { return nil }
        return entry.result
    }

    private func storePersisted(_ key: CacheKey, _ result: WeatherProductResult) {
        guard let url = persistedURL(key), let directory = configuration.cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(PersistedEntry(key: key, result: result)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func removePersisted(_ key: CacheKey) {
        guard let url = persistedURL(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Attribution

    /// The backend's attribution, fetched once per language and then kept.
    func attribution() async throws -> WeatherAttribution {
        try Task.checkCancellation()
        if let cached = attributions[language] { return cached }
        let task: Task<WeatherAttribution, any Error>
        if let running = attributionTasks[language] {
            task = running
        } else {
            let backend = self.backend
            let language = self.language
            task = Task {
                do {
                    return try await backend.attribution(language: language)
                } catch {
                    throw mapServiceError(error)
                }
            }
            attributionTasks[language] = task
        }
        do {
            let value = try await task.value
            attributions[language] = value
            attributionTasks[language] = nil
            return value
        } catch {
            attributionTasks[language] = nil
            throw error
        }
    }
}
