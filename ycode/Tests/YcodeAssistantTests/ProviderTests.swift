import Foundation
import Testing
@testable import YcodeAssistant

/// Collects a response stream.
func collect(_ s: AsyncThrowingStream<ChatEvent, Error>) async throws -> (text: String, events: [ChatEvent]) {
    var text = ""
    var events: [ChatEvent] = []
    for try await e in s {
        events.append(e)
        if case .text(let t) = e { text += t }
    }
    return (text, events)
}

func ndjson(_ objects: [[String: Any]]) -> [Data] {
    objects.map { (try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) + Data("\n".utf8) }
}

func sse(_ objects: [Any]) -> [Data] {
    objects.map { o in
        if let s = o as? String { return Data("data: \(s)\n\n".utf8) }
        let j = String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
        return Data("data: \(j)\n\n".utf8)
    }
}

/// Requests a stand-in server received.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LoopbackServer.Request] = []
    func add(_ r: LoopbackServer.Request) { lock.lock(); items.append(r); lock.unlock() }
    var requests: [LoopbackServer.Request] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A port nothing listens on.
func closedPort() throws -> String {
    let s = try LoopbackServer { _ in .text("") }
    let url = s.baseURL
    s.stop()
    return url
}

@Suite struct OllamaProviderTests {
    @Test func listsModelsAndReportsEmptyAndStopped() async throws {
        let server = try LoopbackServer { req in
            switch req.path {
            case "/api/tags": .json(["models": [["name": "qwen2.5-coder:latest", "size": 1], ["name": "llama3.2:1b"]]])
            case "/api/show": .json(["model_info": ["general.architecture": "qwen2", "qwen2.context_length": 32768]])
            default: .text("", status: 404)
            }
        }
        let p = OllamaProvider(baseURL: server.baseURL)
        let a = await p.availability()
        #expect(a.models.map(\.id) == ["llama3.2:1b", "qwen2.5-coder:latest"])
        #expect(await p.contextWindow(model: "qwen2.5-coder:latest") == 32768)

        let empty = try LoopbackServer { _ in .json(["models": [Any]()]) }
        guard case .noModels(let hint) = await OllamaProvider(baseURL: empty.baseURL).availability() else { Issue.record("expected noModels"); return }
        #expect(hint.contains("ollama pull qwen2.5-coder"))

        guard case .notRunning(let h) = await OllamaProvider(baseURL: try closedPort()).availability() else { Issue.record("expected notRunning"); return }
        #expect(h.contains("ollama serve"))
    }

    @Test func streamsNDJSONChat() async throws {
        let rec = Recorder()
        let server = try LoopbackServer { req in
            rec.add(req)
            return .init(contentType: "application/x-ndjson", chunks: ndjson([
                ["model": "m", "message": ["role": "assistant", "content": "Hel"], "done": false],
                ["model": "m", "message": ["role": "assistant", "content": "lo"], "done": false],
                ["model": "m", "message": ["role": "assistant", "content": ""], "done": true, "done_reason": "stop",
                 "prompt_eval_count": 12, "eval_count": 2],
            ]), delay: 0.02)
        }
        let r = try await collect(OllamaProvider(baseURL: server.baseURL).send(
            ChatRequest(model: "m", instructions: "Be brief.", messages: [ChatMessage(.user, "Hi")], contextTokens: 8192)))
        #expect(r.text == "Hello")
        #expect(r.events.last == .finished(TokenUsage(inputTokens: 12, outputTokens: 2)))
        let body = try #require(rec.requests.first.flatMap { JSON.object($0.body) })
        #expect(rec.requests.first?.path == "/api/chat")
        #expect(body["stream"] as? Bool == true)
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 8192)
        let msgs = body["messages"] as? [[String: String]]
        #expect(msgs?.map { $0["role"]! } == ["system", "user"])
        #expect(msgs?.first?["content"] == "Be brief.")
    }

    @Test func missingModelAndStreamErrors() async throws {
        let server = try LoopbackServer { req in
            req.body.isEmpty ? .text("") : .json(["error": "model \"nope\" not found, try pulling it first"], status: 404)
        }
        do {
            _ = try await collect(OllamaProvider(baseURL: server.baseURL).send(ChatRequest(model: "nope", instructions: "", messages: [ChatMessage(.user, "x")])))
            Issue.record("expected an error")
        } catch let e as AssistantError {
            #expect(e == .modelNotFound(model: "nope", hint: "Run `ollama pull nope` in Terminal."))
        }
        let midStream = try LoopbackServer { _ in
            .init(contentType: "application/x-ndjson", chunks: ndjson([["message": ["content": "a"], "done": false], ["error": "out of memory"]]))
        }
        await #expect(throws: AssistantError.failed("Ollama: out of memory")) {
            _ = try await collect(OllamaProvider(baseURL: midStream.baseURL).send(ChatRequest(model: "m", instructions: "", messages: [])))
        }
        await #expect(throws: AssistantError.self) {
            _ = try await collect(OllamaProvider(baseURL: try closedPort()).send(ChatRequest(model: "m", instructions: "", messages: [])))
        }
    }

    /// Cancelling the consumer closes the connection; the stream ends at once.
    @Test func cancellationStopsTheRequest() async throws {
        let server = try LoopbackServer { _ in
            .init(contentType: "application/x-ndjson", chunks: ndjson((0..<200).map { _ in ["message": ["content": "x"], "done": false] }), delay: 0.05)
        }
        let started = Date()
        let task = Task { () -> Int in
            var n = 0
            for try await e in OllamaProvider(baseURL: server.baseURL).send(ChatRequest(model: "m", instructions: "", messages: [])) {
                if case .text = e { n += 1 }
            }
            return n
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 3)
        if case .success(let n) = result { #expect(n < 200) }
    }
}

@Suite struct ChatCompletionsProviderTests {
    @Test func modelsPropsAndStreaming() async throws {
        let rec = Recorder()
        let server = try LoopbackServer { req in
            rec.add(req)
            switch req.path {
            case "/v1/models": return .json(["object": "list", "data": [["id": "/models/qwen.gguf", "meta": ["n_ctx_train": 131072]]]])
            case "/props": return .json(["default_generation_settings": ["n_ctx": 8192]])
            case "/v1/chat/completions":
                return .init(contentType: "text/event-stream", chunks: sse([
                    ["choices": [["index": 0, "delta": ["role": "assistant"]]]],
                    ["choices": [["index": 0, "delta": ["content": "Hi"]]]],
                    ["choices": [["index": 0, "delta": ["content": " there"]]]],
                    ["choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]], "usage": ["prompt_tokens": 5, "completion_tokens": 2]],
                    "[DONE]",
                ]), delay: 0.01)
            default: return .text("", status: 404)
            }
        }
        let p = ChatCompletionsProvider(baseURL: server.baseURL, apiKey: "local-key")
        let a = await p.availability()
        #expect(a.models == [ModelInfo(id: "/models/qwen.gguf", displayName: "qwen.gguf", contextWindow: 131072)])
        #expect(await p.contextWindow(model: "x") == 8192)
        let r = try await collect(p.send(ChatRequest(model: "/models/qwen.gguf", instructions: "sys", messages: [ChatMessage(.user, "hello")])))
        #expect(r.text == "Hi there")
        #expect(r.events.last == .finished(TokenUsage(inputTokens: 5, outputTokens: 2)))
        let chat = try #require(rec.requests.first { $0.path == "/v1/chat/completions" })
        #expect(chat.header("authorization") == "Bearer local-key")
        #expect((JSON.object(chat.body)?["messages"] as? [[String: String]])?.first?["role"] == "system")
    }

    @Test func errorsAndNotRunning() async throws {
        let server = try LoopbackServer { _ in .json(["error": ["code": 400, "message": "the request exceeds the available context size", "type": "exceed_context_size_error"]], status: 400) }
        await #expect(throws: AssistantError.http(status: 400, message: "the request exceeds the available context size")) {
            _ = try await collect(ChatCompletionsProvider(baseURL: server.baseURL).send(ChatRequest(model: nil, instructions: "", messages: [])))
        }
        guard case .notRunning(let h) = await ChatCompletionsProvider(baseURL: try closedPort()).availability() else { Issue.record("expected notRunning"); return }
        #expect(h.contains("llama-server"))
        let truncated = try LoopbackServer { _ in .init(contentType: "text/event-stream", chunks: sse([["choices": [["delta": ["content": "a"]]]]])) }
        await #expect(throws: AssistantError.incomplete("the server closed the stream")) {
            _ = try await collect(ChatCompletionsProvider(baseURL: truncated.baseURL).send(ChatRequest(model: nil, instructions: "", messages: [])))
        }
    }
}

@Suite struct OpenAIProviderTests {
    @Test func apiKeyModelsAndResponsesStream() async throws {
        let rec = Recorder()
        let server = try LoopbackServer { req in
            rec.add(req)
            guard req.header("authorization") == "Bearer sk-test" else { return .json(["error": ["message": "bad key", "code": "invalid_api_key"]], status: 401) }
            switch req.path {
            case "/v1/models": return .json(["data": [["id": "text-embedding-x"], ["id": "gpt-6"], ["id": "gpt-6.1"], ["id": "o9-mini"]]])
            case "/v1/responses":
                return .init(contentType: "text/event-stream", chunks: sse([
                    ["type": "response.created", "response": ["id": "r1"]],
                    ["type": "response.output_text.delta", "delta": "Ex"],
                    ["type": "response.output_text.delta", "delta": "plained"],
                    ["type": "response.completed", "response": ["usage": ["input_tokens": 40, "output_tokens": 3]]],
                ]), delay: 0.01)
            default: return .text("", status: 404)
            }
        }
        let p = OpenAIProvider(baseURL: server.baseURL + "/v1", credential: .apiKey("sk-test"))
        let models = await p.availability().models.map(\.id)
        #expect(models == ["gpt-6.1", "gpt-6", "o9-mini"])
        let r = try await collect(p.send(ChatRequest(model: "gpt-6.1", instructions: "rules", messages: [ChatMessage(.user, "q")])))
        #expect(r.text == "Explained")
        #expect(r.events.last == .finished(TokenUsage(inputTokens: 40, outputTokens: 3)))
        let body = try #require(rec.requests.first { $0.path == "/v1/responses" }.flatMap { JSON.object($0.body) })
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "rules")
        #expect((body["input"] as? [[String: String]]) == [["role": "user", "content": "q"]])
        #expect(body["max_output_tokens"] == nil && body["temperature"] == nil)

        guard case .signedOut = await OpenAIProvider(baseURL: server.baseURL + "/v1", credential: .apiKey("wrong")).availability() else {
            Issue.record("expected signedOut"); return
        }
        guard case .signedOut = await OpenAIProvider(credential: .none).availability() else { Issue.record("expected signedOut"); return }
    }

    @Test func planModelListShape() {
        let body = Data(#"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},{"slug":"hidden","display_name":"H","visibility":"hide"}]}"#.utf8)
        #expect(OpenAIProvider.parseModels(body) == [ModelInfo(id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol")])
    }

    @Test func streamedFailuresMapToGuidance() throws {
        #expect(throws: AssistantError.usageLimit("You've reached a usage limit. Check your usage in ChatGPT settings.")) {
            _ = try OpenAIProvider.parseEvent(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}}"#, plan: true)
        }
        #expect(throws: AssistantError.incomplete("max_output_tokens")) {
            _ = try OpenAIProvider.parseEvent(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#, plan: true)
        }
        #expect(throws: AssistantError.failed("boom")) { _ = try OpenAIProvider.parseEvent(#"{"type":"error","code":"server_error","message":"boom"}"#, plan: false) }
        #expect(OpenAIProvider.mapError(status: 503, body: Data(#"{"detail":"routing unavailable"}"#.utf8), plan: true)
                == .temporarilyUnavailable("routing unavailable"))
        #expect(OpenAIProvider.mapError(status: 400, body: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools"}}"#.utf8), plan: true)
                == .unsupported("This request uses a feature that isn't supported with ChatGPT plan usage."))
    }

    /// With a ChatGPT sign-in, a 401 refreshes the token once and retries.
    @Test func accountRefreshesOnUnauthorized() async throws {
        let rec = Recorder()
        let server = try LoopbackServer { req in
            rec.add(req)
            switch req.path {
            case "/oauth/token":
                #expect(req.form["grant_type"] == "refresh_token")
                #expect(req.form["refresh_token"] == "rt-1")
                #expect(req.form["client_id"] == "oaiapp_issued")
                #expect(req.form["resource"] == "https://api.openai.com/v1")
                return .json(["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer", "expires_in": 3600,
                              "scope": "openid offline_access chatgpt.tokens.use.direct"])
            case "/v1/responses":
                guard req.header("authorization") == "Bearer at-2" else {
                    return .json(["error": ["code": "subscription_sharing_invalid_user", "message": "expired"]], status: 401)
                }
                return .init(contentType: "text/event-stream", chunks: sse([["type": "response.output_text.delta", "delta": "ok"],
                                                                             ["type": "response.completed", "response": [String: Any]()]]))
            default: return .text("", status: 404)
            }
        }
        let store = MemorySecretStore()
        try store.writeJSON(OpenAITokens(clientID: "oaiapp_issued", subject: "user-1", email: nil, accessToken: "at-1", refreshToken: "rt-1",
                                         idToken: nil, tokenType: "Bearer", expiresAt: Date().addingTimeInterval(3000),
                                         scopes: ["chatgpt.tokens.use.direct"], savedAt: Date()), for: SecretAccount.openAITokens)
        var config = OpenAIAuthConfiguration()
        config.tokenURL = server.baseURL + "/oauth/token"
        let account = OpenAIAccount(configuration: config, store: store) { _ in false }
        let r = try await collect(OpenAIProvider(baseURL: server.baseURL + "/v1", credential: .account(account))
            .send(ChatRequest(model: "gpt-6.1-sol", instructions: "", messages: [ChatMessage(.user, "q")])))
        #expect(r.text == "ok")
        let saved = try #require(store.readJSON(OpenAITokens.self, SecretAccount.openAITokens))
        #expect(saved.accessToken == "at-2" && saved.refreshToken == "rt-2")
        #expect(rec.requests.filter { $0.path == "/v1/responses" }.count == 2)
    }
}
