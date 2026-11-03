import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Ollama's generate, show and pull endpoints (Ollama's public API
// documentation, docs/api.md): fill-in-the-middle for predictive code
// completion (specs/ide/predictive-completion.md) and model downloads the
// user asks for in Settings.

extension OllamaProvider {
    /// Where people get Ollama (shown when nothing answers at the address).
    public static let downloadURL = "https://ollama.com/download"
    /// The one line shown with the link when Ollama is not reachable.
    public static let installHint = "Install Ollama from ollama.com/download and open it (or run `ollama serve`), then choose a model in Settings."

    /// One streamed `/api/generate` line.
    public enum GenerateEvent: Sendable, Equatable {
        case text(String)
        /// The last line: token counts and Ollama's own durations (ns).
        case done(GenerateStats)
    }

    public struct GenerateStats: Sendable, Equatable {
        public var promptTokens: Int?
        public var outputTokens: Int?
        /// `load_duration`, `prompt_eval_duration`, `eval_duration`, `total_duration` (nanoseconds).
        public var loadNanoseconds: Int?
        public var promptNanoseconds: Int?
        public var evalNanoseconds: Int?
        public var totalNanoseconds: Int?
        public var doneReason: String?
        public init(promptTokens: Int? = nil, outputTokens: Int? = nil, loadNanoseconds: Int? = nil, promptNanoseconds: Int? = nil,
                    evalNanoseconds: Int? = nil, totalNanoseconds: Int? = nil, doneReason: String? = nil) {
            self.promptTokens = promptTokens
            self.outputTokens = outputTokens
            self.loadNanoseconds = loadNanoseconds
            self.promptNanoseconds = promptNanoseconds
            self.evalNanoseconds = evalNanoseconds
            self.totalNanoseconds = totalNanoseconds
            self.doneReason = doneReason
        }
    }

    /// A `/api/generate` request. With `suffix`, the model's own template
    /// builds the fill-in-the-middle prompt (only models whose template
    /// handles a suffix, capability `insert`).
    public struct GenerateRequest: Sendable, Equatable {
        public var model: String
        public var prompt: String
        public var suffix: String?
        /// `options`: `num_predict`, `temperature`, `top_p`, `top_k`, `stop`, `num_ctx`.
        public var maxTokens: Int?
        public var temperature: Double?
        public var topP: Double?
        public var topK: Int?
        public var repeatPenalty: Double?
        public var stop: [String]
        public var contextTokens: Int?
        /// `keep_alive` (e.g. "30m"); nil: the server's default.
        public var keepAlive: String?
        public init(model: String, prompt: String, suffix: String? = nil, maxTokens: Int? = nil, temperature: Double? = nil,
                    topP: Double? = nil, topK: Int? = nil, repeatPenalty: Double? = nil, stop: [String] = [], contextTokens: Int? = nil, keepAlive: String? = nil) {
            self.repeatPenalty = repeatPenalty
            self.model = model
            self.prompt = prompt
            self.suffix = suffix
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.stop = stop
            self.contextTokens = contextTokens
            self.keepAlive = keepAlive
        }
    }

    /// The `/api/generate` body (streamed).
    public static func generateBody(_ r: GenerateRequest) -> [String: Any] {
        var body: [String: Any] = ["model": r.model, "prompt": r.prompt, "stream": true]
        if let s = r.suffix { body["suffix"] = s }
        var options: [String: Any] = [:]
        if let n = r.maxTokens { options["num_predict"] = n }
        if let t = r.temperature { options["temperature"] = t }
        if let p = r.topP { options["top_p"] = p }
        if let k = r.topK { options["top_k"] = k }
        if let p = r.repeatPenalty { options["repeat_penalty"] = p }
        if !r.stop.isEmpty { options["stop"] = r.stop }
        if let c = r.contextTokens { options["num_ctx"] = c }
        if !options.isEmpty { body["options"] = options }
        if let k = r.keepAlive { body["keep_alive"] = k }
        return body
    }

    /// Streams `/api/generate`. Errors: `unreachable` (nothing at the
    /// address), `modelNotFound` (HTTP 404), `http`, `malformed`.
    public func generate(_ request: GenerateRequest) -> AsyncThrowingStream<GenerateEvent, Error> {
        let base = baseURL
        let hint = Self.installHint
        return AsyncThrowingStream { out in
            let task = Task {
                do {
                    guard let url = HTTP.url(base, "api/generate") else { throw AssistantError.failed("The Ollama address “\(base)” is not a valid URL.") }
                    let req = try HTTP.jsonRequest(url, body: Self.generateBody(request))
                    var finished = false
                    do {
                        try await HTTP.streamLines(req, error: { status, body in
                            let (message, _) = HTTP.errorMessage(body)
                            if status == 404 { return AssistantError.modelNotFound(model: request.model, hint: "Choose an installed model in Settings ▸ Editing ▸ Completion.") }
                            return AssistantError.http(status: status, message: message)
                        }) { line in
                            for e in try Self.parseGenerateLine(line) {
                                out.yield(e)
                                if case .done = e { finished = true }
                            }
                            return finished
                        }
                    } catch where HTTP.isUnreachable(error) {
                        throw AssistantError.unreachable(service: "Ollama", url: base, hint: hint)
                    }
                    if !finished { throw AssistantError.incomplete("the server closed the stream") }
                    out.finish()
                } catch {
                    out.finish(throwing: HTTP.isCancellation(error) ? CancellationError() : error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    /// The events of one NDJSON line of a streamed `/api/generate` reply.
    public static func parseGenerateLine(_ line: String) throws -> [GenerateEvent] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        guard let o = JSON.object(t) else { throw AssistantError.malformed("Ollama sent a line that is not JSON.") }
        if let e = o["error"] as? String { throw AssistantError.failed("Ollama: \(e)") }
        var events: [GenerateEvent] = []
        if let r = o["response"] as? String, !r.isEmpty { events.append(.text(r)) }
        if (o["done"] as? Bool) == true {
            events.append(.done(GenerateStats(promptTokens: JSON.int(o["prompt_eval_count"]), outputTokens: JSON.int(o["eval_count"]),
                                              loadNanoseconds: JSON.int(o["load_duration"]), promptNanoseconds: JSON.int(o["prompt_eval_duration"]),
                                              evalNanoseconds: JSON.int(o["eval_duration"]), totalNanoseconds: JSON.int(o["total_duration"]),
                                              doneReason: o["done_reason"] as? String)))
        }
        return events
    }

    /// The installed models (`/api/tags`); throws `unreachable` when
    /// nothing answers.
    public func installedModels() async throws -> [ModelInfo] {
        guard let url = HTTP.url(baseURL, "api/tags") else { throw AssistantError.failed("The Ollama address “\(baseURL)” is not a valid URL.") }
        do {
            let r = try await HTTP.send(URLRequest(url: url), timeout: 3)
            guard r.status == 200 else { throw AssistantError.http(status: r.status, message: HTTP.errorMessage(r.body).message) }
            return Self.parseTags(r.body)
        } catch where HTTP.isUnreachable(error) {
            throw AssistantError.unreachable(service: "Ollama", url: baseURL, hint: Self.installHint)
        }
    }

    /// A model's `capabilities` from `/api/show` (e.g. `completion`,
    /// `insert`, `tools`); nil when Ollama does not report them.
    public func capabilities(model: String) async -> [String]? {
        guard let url = HTTP.url(baseURL, "api/show"), let req = try? HTTP.jsonRequest(url, body: ["model": model]),
              let r = try? await HTTP.send(req, timeout: 5), r.status == 200 else { return nil }
        return Self.parseCapabilities(r.body)
    }

    public static func parseCapabilities(_ body: Data) -> [String]? {
        JSON.object(body)?["capabilities"] as? [String]
    }

    /// One `/api/pull` progress line.
    public struct PullProgress: Sendable, Equatable {
        public var status: String
        public var completed: Int?
        public var total: Int?
        public var fraction: Double? { total.flatMap { t in t > 0 ? Double(completed ?? 0) / Double(t) : nil } }
    }

    /// Downloads `model` into Ollama (`/api/pull`, streamed). Only on the
    /// user's explicit request.
    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        let base = baseURL
        return AsyncThrowingStream { out in
            let task = Task {
                do {
                    guard let url = HTTP.url(base, "api/pull") else { throw AssistantError.failed("The Ollama address “\(base)” is not a valid URL.") }
                    let req = try HTTP.jsonRequest(url, body: ["model": model, "stream": true])
                    var success = false
                    try await HTTP.streamLines(req, timeout: 3600, error: { status, body in
                        AssistantError.http(status: status, message: HTTP.errorMessage(body).message)
                    }) { line in
                        guard let p = try Self.parsePullLine(line) else { return false }
                        out.yield(p)
                        if p.status == "success" { success = true }
                        return success
                    }
                    if !success { throw AssistantError.incomplete("the download stopped") }
                    out.finish()
                } catch where HTTP.isUnreachable(error) {
                    out.finish(throwing: AssistantError.unreachable(service: "Ollama", url: base, hint: Self.installHint))
                } catch {
                    out.finish(throwing: HTTP.isCancellation(error) ? CancellationError() : error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    public static func parsePullLine(_ line: String) throws -> PullProgress? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let o = JSON.object(t) else { throw AssistantError.malformed("Ollama sent a line that is not JSON.") }
        if let e = o["error"] as? String { throw AssistantError.failed("Ollama: \(e)") }
        return PullProgress(status: o["status"] as? String ?? "", completed: JSON.int(o["completed"]), total: JSON.int(o["total"]))
    }
}
