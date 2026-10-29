import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// llama.cpp's `llama-server` through its OpenAI-compatible endpoints
/// (llama.cpp's server README): `GET /v1/models`, `GET /props` for the
/// running context size, and `POST /v1/chat/completions` streamed as
/// server-sent events ending with `data: [DONE]` (the Chat Completions
/// streaming format). Any server with those endpoints works.
public struct ChatCompletionsProvider: AssistantProvider {
    public let kind = ProviderKind.llamaCpp
    /// The server's address without the `/v1` suffix.
    public var baseURL: String
    /// Sent as `Authorization: Bearer` when the server was started with
    /// `--api-key`.
    public var apiKey: String?
    public static let defaultBaseURL = "http://127.0.0.1:9931"

    public init(baseURL: String = Self.defaultBaseURL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var notRunningHint: String {
        "Start it with `llama-server -m <model>.gguf --port <port>` and set its address in Settings ▸ Coding Assistant."
    }

    func request(_ path: String) -> URLRequest? {
        guard let url = HTTP.url(baseURL, path) else { return nil }
        var r = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func availability() async -> ProviderAvailability {
        guard let req = request("v1/models") else { return .failed("The llama.cpp address “\(baseURL)” is not a valid URL.") }
        do {
            let r = try await HTTP.send(req, timeout: 3)
            if r.status == 503 { return .notRunning(hint: "llama-server is still loading its model. Try again in a moment.") }
            if r.status == 401 { return .signedOut(hint: "llama-server needs an API key. Enter the key it was started with in Settings ▸ Coding Assistant.") }
            guard r.status == 200 else { return .failed("llama-server answered HTTP \(r.status): \(HTTP.errorMessage(r.body).message)") }
            let models = Self.parseModels(r.body)
            return models.isEmpty ? .noModels(hint: "llama-server lists no model. Start it with `-m <model>.gguf`.") : .ready(models)
        } catch {
            return HTTP.isUnreachable(error) ? .notRunning(hint: "llama-server is not running at \(baseURL). " + notRunningHint)
                                             : .failed(error.localizedDescription)
        }
    }

    /// `data[].id` of a `/v1/models` body (with `meta.n_ctx_train` when
    /// llama-server reports it).
    static func parseModels(_ body: Data) -> [ModelInfo] {
        guard let o = JSON.object(body), let list = o["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let ctx = (m["meta"] as? [String: Any]).flatMap { JSON.int($0["n_ctx_train"]) }
            return ModelInfo(id: id, displayName: URL(fileURLWithPath: id).lastPathComponent, contextWindow: ctx)
        }
    }

    public func contextWindow(model: String) async -> Int? {
        guard let req = request("props"), let r = try? await HTTP.send(req, timeout: 3), r.status == 200,
              let o = JSON.object(r.body), let settings = o["default_generation_settings"] as? [String: Any] else { return nil }
        return JSON.int(settings["n_ctx"])
    }

    static func chatBody(_ request: ChatRequest) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": request.instructions]]
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = ["messages": messages, "stream": true]
        if let m = request.model, !m.isEmpty { body["model"] = m }
        return body
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let provider = self
        return eventStream { out in
            guard var req = provider.request("v1/chat/completions") else { throw AssistantError.failed("The llama.cpp address is not a valid URL.") }
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.httpBody = try JSONSerialization.data(withJSONObject: Self.chatBody(request), options: [.sortedKeys])
            var sse = SSEDecoder()
            var finished = false
            var usage: TokenUsage?
            func handle(_ e: SSEDecoder.Event) throws -> Bool {
                switch try Self.parseChunk(e.data) {
                case .text(let t): out.yield(.text(t))
                case .usage(let u): usage = u
                case .done: finished = true; return true
                case .none: break
                }
                return false
            }
            do {
                try await HTTP.streamLines(req, error: { status, body in
                    AssistantError.http(status: status, message: HTTP.errorMessage(body).message)
                }) { line in
                    guard let e = sse.push(line: line) else { return false }
                    return try handle(e)
                }
                if !finished, let e = sse.finish() { _ = try handle(e) }
            } catch where HTTP.isUnreachable(error) {
                throw AssistantError.unreachable(service: "llama-server", url: provider.baseURL, hint: provider.notRunningHint)
            }
            if !finished { throw AssistantError.incomplete("the server closed the stream") }
            out.yield(.finished(usage))
        }
    }

    enum Chunk: Equatable { case text(String), usage(TokenUsage), done, none }

    /// One `data:` payload of a streamed chat completion.
    static func parseChunk(_ data: String) throws -> Chunk {
        let d = data.trimmingCharacters(in: .whitespaces)
        if d == "[DONE]" { return .done }
        guard let o = JSON.object(d) else { throw AssistantError.malformed("The server sent an event that is not JSON.") }
        if o["error"] != nil {
            throw AssistantError.failed(HTTP.errorMessage(Data(d.utf8)).message)
        }
        if let choices = o["choices"] as? [[String: Any]], let first = choices.first,
           let delta = first["delta"] as? [String: Any], let c = delta["content"] as? String, !c.isEmpty {
            return .text(c)
        }
        if let u = o["usage"] as? [String: Any] {
            return .usage(TokenUsage(inputTokens: JSON.int(u["prompt_tokens"]), outputTokens: JSON.int(u["completion_tokens"])))
        }
        return .none
    }
}
