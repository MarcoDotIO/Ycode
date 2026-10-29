import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI models through the Responses API (`POST /v1/responses`, streamed
/// as server-sent events), authorized either by a ChatGPT sign-in (plan
/// usage, `OpenAIAccount`) or by an API key the user enters. Models come
/// from `GET /v1/models` at run time; Ycode names none itself.
public struct OpenAIProvider: AssistantProvider {
    public enum Credential: Sendable {
        case apiKey(String)
        case account(OpenAIAccount)
        case none
    }

    public let kind = ProviderKind.openAI
    public var baseURL: String
    public var credential: Credential
    public static let defaultBaseURL = "https://api.openai.com/v1"

    public init(baseURL: String = Self.defaultBaseURL, credential: Credential) {
        self.baseURL = baseURL
        self.credential = credential
    }

    static let signedOutHint = "Sign in with ChatGPT or enter an OpenAI API key in Settings ▸ Coding Assistant."

    func bearer(forceRefresh: Bool = false) async throws -> String {
        switch credential {
        case .apiKey(let k) where !k.isEmpty: return k
        case .account(let a): return try await a.accessToken(forceRefresh: forceRefresh)
        default: throw AssistantError.notSignedIn(hint: Self.signedOutHint)
        }
    }

    var usesPlan: Bool { if case .account = credential { true } else { false } }

    public func availability() async -> ProviderAvailability {
        if case .account(let a) = credential, case .signedIn(_, let plan) = await a.status, !plan {
            return .failed(AssistantError.planUsageNotEnabled.errorDescription! + " " + AssistantError.planUsageNotEnabled.recoverySuggestion!)
        }
        do {
            let models = try await listModels()
            return models.isEmpty ? .noModels(hint: "The account lists no models.") : .ready(models)
        } catch let e as AssistantError {
            switch e {
            case .notSignedIn(let hint): return .signedOut(hint: hint)
            case .unreachable(_, _, let hint): return .notRunning(hint: hint)
            default: return .failed(e.errorDescription ?? "\(e)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        guard let url = HTTP.url(baseURL, "models") else { throw AssistantError.failed("The OpenAI address is not valid.") }
        for attempt in 0..<2 {
            var r = URLRequest(url: url)
            r.setValue("Bearer \(try await bearer(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            let response: HTTP.Response
            do {
                response = try await HTTP.send(r, timeout: 15)
            } catch where HTTP.isUnreachable(error) {
                throw AssistantError.unreachable(service: "OpenAI", url: baseURL, hint: "Check the network connection.")
            }
            if response.status == 401 && usesPlan && attempt == 0 { continue }
            guard response.status == 200 else { throw Self.mapError(status: response.status, body: response.body, plan: usesPlan) }
            return Self.parseModels(response.body)
        }
        throw AssistantError.notSignedIn(hint: Self.signedOutHint)
    }

    /// Both documented shapes: `{"models": [{slug, display_name,
    /// visibility}]}` (plan usage; only `visibility == "list"` is shown) and
    /// `{"data": [{id}]}` (API keys; GPT models first, newest names first).
    static func parseModels(_ body: Data) -> [ModelInfo] {
        guard let o = JSON.object(body) else { return [] }
        if let list = o["models"] as? [[String: Any]] {
            return list.compactMap { m in
                guard let slug = m["slug"] as? String, (m["visibility"] as? String).map({ $0 == "list" }) ?? true else { return nil }
                return ModelInfo(id: slug, displayName: (m["display_name"] as? String) ?? slug, contextWindow: JSON.int(m["context_window"]))
            }
        }
        guard let data = o["data"] as? [[String: Any]] else { return [] }
        let ids = data.compactMap { $0["id"] as? String }
        let chat = ids.filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o") }
        return (chat.isEmpty ? ids : chat).sorted { a, b in
            let ga = a.hasPrefix("gpt-"), gb = b.hasPrefix("gpt-")
            return ga != gb ? ga : a.compare(b, options: .numeric) == .orderedDescending
        }.map { ModelInfo(id: $0) }
    }

    /// The Responses request body: instructions separately (system items
    /// are not accepted with plan usage), the history as `input`, nothing
    /// stored, streamed.
    static func responsesBody(_ request: ChatRequest) -> [String: Any] {
        let input: [[String: Any]] = request.messages.map { ["role": $0.role == .system ? "developer" : $0.role.rawValue, "content": $0.content] }
        return ["model": request.model ?? "", "instructions": request.instructions, "input": input, "store": false, "stream": true]
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let provider = self
        return eventStream { out in
            guard let url = HTTP.url(provider.baseURL, "responses") else { throw AssistantError.failed("The OpenAI address is not valid.") }
            let body = try JSONSerialization.data(withJSONObject: Self.responsesBody(request), options: [.sortedKeys])
            var attempt = 0
            while true {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("Bearer \(try await provider.bearer(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
                req.httpBody = body
                var sse = SSEDecoder()
                var finished = false
                do {
                    try await HTTP.streamLines(req, error: { status, body in
                        RetryableAuth(status: status, body: body)
                    }) { line in
                        guard let e = sse.push(line: line) else { return false }
                        for ev in try Self.parseEvent(e.data, plan: provider.usesPlan) {
                            out.yield(ev)
                            if case .finished = ev { finished = true }
                        }
                        return finished
                    }
                    if !finished, let e = sse.finish() {
                        for ev in try Self.parseEvent(e.data, plan: provider.usesPlan) {
                            out.yield(ev)
                            if case .finished = ev { finished = true }
                        }
                    }
                } catch let r as RetryableAuth {
                    if r.status == 401 && provider.usesPlan && attempt == 0 { attempt += 1; continue }
                    throw Self.mapError(status: r.status, body: r.body, plan: provider.usesPlan)
                } catch where HTTP.isUnreachable(error) {
                    throw AssistantError.unreachable(service: "OpenAI", url: provider.baseURL, hint: "Check the network connection.")
                }
                if !finished { throw AssistantError.incomplete("the connection closed before the response completed") }
                return
            }
        }
    }

    struct RetryableAuth: Error { var status: Int; var body: Data }

    /// The events of one SSE `data:` payload.
    static func parseEvent(_ data: String, plan: Bool) throws -> [ChatEvent] {
        let d = data.trimmingCharacters(in: .whitespaces)
        if d.isEmpty || d == "[DONE]" { return [] }
        guard let o = JSON.object(d) else { throw AssistantError.malformed("OpenAI sent an event that is not JSON.") }
        switch o["type"] as? String {
        case "response.output_text.delta":
            if let t = o["delta"] as? String, !t.isEmpty { return [.text(t)] }
            return []
        case "response.completed":
            let u = (o["response"] as? [String: Any])?["usage"] as? [String: Any]
            return [.finished(u.map { TokenUsage(inputTokens: JSON.int($0["input_tokens"]), outputTokens: JSON.int($0["output_tokens"])) })]
        case "response.failed":
            let e = ((o["response"] as? [String: Any])?["error"] as? [String: Any]) ?? [:]
            throw mapCode(e["code"] as? String, message: (e["message"] as? String) ?? "The response failed.", status: nil, plan: plan)
        case "response.incomplete":
            let reason = (((o["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String) ?? "incomplete"
            throw AssistantError.incomplete(reason)
        case "error":
            let e = (o["error"] as? [String: Any]) ?? o
            throw mapCode(e["code"] as? String, message: (e["message"] as? String) ?? "The request failed.", status: nil, plan: plan)
        default:
            return []
        }
    }

    /// Maps an HTTP error (before the stream opened) to an error with the
    /// recovery the error guide gives.
    static func mapError(status: Int, body: Data, plan: Bool) -> AssistantError {
        let (message, code) = HTTP.errorMessage(body)
        return mapCode(code, message: message, status: status, plan: plan)
    }

    static func mapCode(_ code: String?, message: String, status: Int?, plan: Bool) -> AssistantError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .usageLimit("You've reached a usage limit. Check your usage in ChatGPT settings.")
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .temporarilyUnavailable("Usage status can't be checked right now. Try again shortly.")
        case "subscription_sharing_user_not_eligible":
            return .failed("ChatGPT plan usage isn't available for this account or workspace.")
        case "subscription_sharing_unsupported_capability":
            return .unsupported("This request uses a feature that isn't supported with ChatGPT plan usage.")
        case "subscription_sharing_route_not_supported":
            return .failed("This request route isn't supported for ChatGPT plan usage.")
        case "subscription_sharing_invalid_user":
            return .notSignedIn(hint: "Your ChatGPT session needs to be renewed. " + OpenAIAccount.signInHint)
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .failed("This app isn't authorized for that action. Check the sign-in in Settings ▸ Coding Assistant.")
        case "model_not_found":
            return .modelNotFound(model: "", hint: "Choose another model in the Coding Assistant's model menu.")
        default: break
        }
        switch status {
        case 401?: return .notSignedIn(hint: plan ? "Your ChatGPT session was not accepted. " + OpenAIAccount.signInHint
                                                  : "The API key was not accepted. Check it in Settings ▸ Coding Assistant.")
        case 403?: return .failed(message.isEmpty ? "The request was refused (HTTP 403)." : message)
        case 429?: return .usageLimit(message.isEmpty ? "Rate or usage limit reached." : message)
        case 503?: return .temporarilyUnavailable(message.isEmpty ? "The service is unavailable. Try again shortly." : message)
        case let s?: return .http(status: s, message: message)
        case nil: return .failed(message)
        }
    }
}
