import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A local Ollama server through its native HTTP API (Ollama's public API
/// documentation): `GET /api/tags` lists models, `POST /api/show` reports a
/// model's context length, `POST /api/chat` streams NDJSON.
public struct OllamaProvider: AssistantProvider {
    public let kind = ProviderKind.ollama
    public var baseURL: String
    public static let defaultBaseURL = "http://127.0.0.1:11434"
    /// The model suggested when none is installed.
    public static let suggestedModel = "qwen2.5-coder"

    public init(baseURL: String = Self.defaultBaseURL) { self.baseURL = baseURL }

    var notRunningHint: String {
        "Start Ollama (open the Ollama app, or run `ollama serve` in Terminal), or change its address in Settings ▸ Coding Assistant."
    }
    static var noModelsHint: String {
        "Ollama has no models. Run `ollama pull \(suggestedModel)` in Terminal, then refresh."
    }

    public func availability() async -> ProviderAvailability {
        guard let url = HTTP.url(baseURL, "api/tags") else { return .failed("The Ollama address “\(baseURL)” is not a valid URL.") }
        do {
            let r = try await HTTP.send(URLRequest(url: url), timeout: 3)
            guard r.status == 200 else { return .failed("Ollama answered HTTP \(r.status): \(HTTP.errorMessage(r.body).message)") }
            let models = Self.parseTags(r.body)
            return models.isEmpty ? .noModels(hint: Self.noModelsHint) : .ready(models)
        } catch {
            return HTTP.isUnreachable(error) ? .notRunning(hint: "Ollama is not running at \(baseURL). " + notRunningHint)
                                             : .failed(error.localizedDescription)
        }
    }

    /// Model names from an `/api/tags` body, sorted by name.
    static func parseTags(_ body: Data) -> [ModelInfo] {
        guard let o = JSON.object(body), let list = o["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let name = (m["name"] as? String) ?? (m["model"] as? String) else { return nil }
            return ModelInfo(id: name, displayName: name)
        }.sorted { $0.id < $1.id }
    }

    public func contextWindow(model: String) async -> Int? {
        guard let url = HTTP.url(baseURL, "api/show"), let req = try? HTTP.jsonRequest(url, body: ["model": model]),
              let r = try? await HTTP.send(req, timeout: 5), r.status == 200 else { return nil }
        return Self.parseContextLength(r.body)
    }

    /// The `<architecture>.context_length` entry of `/api/show`'s
    /// `model_info`.
    static func parseContextLength(_ body: Data) -> Int? {
        guard let o = JSON.object(body), let info = o["model_info"] as? [String: Any] else { return nil }
        for (k, v) in info where k.hasSuffix(".context_length") { if let n = JSON.int(v) { return n } }
        return nil
    }

    /// The `/api/chat` request body.
    static func chatBody(_ request: ChatRequest) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": request.instructions]]
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = ["model": request.model ?? "", "messages": messages, "stream": true]
        if let n = request.contextTokens { body["options"] = ["num_ctx": n] }
        return body
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let base = baseURL
        let hint = notRunningHint
        return eventStream { out in
            guard let url = HTTP.url(base, "api/chat") else { throw AssistantError.failed("The Ollama address “\(base)” is not a valid URL.") }
            let req = try HTTP.jsonRequest(url, body: Self.chatBody(request))
            let model = request.model ?? ""
            var finished = false
            do {
                try await HTTP.streamLines(req, error: { status, body in
                    let (message, _) = HTTP.errorMessage(body)
                    if status == 404 && message.contains("not found") {
                        return AssistantError.modelNotFound(model: model, hint: "Run `ollama pull \(model)` in Terminal.")
                    }
                    return AssistantError.http(status: status, message: message)
                }) { line in
                    for event in try Self.parseChatLine(line) {
                        out.yield(event)
                        if case .finished = event { finished = true }
                    }
                    return finished
                }
            } catch where HTTP.isUnreachable(error) {
                throw AssistantError.unreachable(service: "Ollama", url: base, hint: hint)
            }
            if !finished { throw AssistantError.incomplete("the server closed the stream") }
        }
    }

    /// The events in one NDJSON line of a streamed `/api/chat` response.
    static func parseChatLine(_ line: String) throws -> [ChatEvent] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        guard let o = JSON.object(t) else { throw AssistantError.malformed("Ollama sent a line that is not JSON.") }
        if let e = o["error"] as? String { throw AssistantError.failed("Ollama: \(e)") }
        var events: [ChatEvent] = []
        if let m = o["message"] as? [String: Any], let c = m["content"] as? String, !c.isEmpty { events.append(.text(c)) }
        if (o["done"] as? Bool) == true {
            events.append(.finished(TokenUsage(inputTokens: JSON.int(o["prompt_eval_count"]), outputTokens: JSON.int(o["eval_count"]))))
        }
        return events
    }
}
