import Foundation
import YcodeAssistant

/// A stand-in model server on 127.0.0.1 for tests (no model, no network):
/// answers the endpoints the three backends use, Ollama's (`/api/tags`,
/// `/api/show`, `/api/generate`), llama-server's `/infill` and the
/// OpenAI-compatible ones (`/v1/models`, `/v1/completions`,
/// `/v1/chat/completions`), streaming what `answer` returns in small
/// pieces.
public final class StandInServer: @unchecked Sendable {
    /// What the server was asked: the endpoint path and the JSON body.
    public struct Received: @unchecked Sendable {
        public var path: String
        public var body: [String: Any]
    }

    public typealias Answer = @Sendable (_ prefix: String, _ suffix: String) -> String

    private let server: LoopbackServer
    private let lock = NSLock()
    private var log: [Received] = []
    /// The model name the server reports.
    public let modelName: String

    /// `answer` gets the prefix and suffix (for `/v1/completions`, the
    /// whole prompt as the prefix); `chunk` characters are sent per piece,
    /// `delay` seconds apart.
    public init(modelName: String = "stand-in-coder", chunk: Int = 4, delay: TimeInterval = 0.005, answer: @escaping Answer) throws {
        self.modelName = modelName
        let box = LogBox()
        server = try LoopbackServer { req in
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            box.add(Received(path: req.path, body: body))
            func pieces(_ s: String) -> [String] {
                var out: [String] = []
                var cur = ""
                for ch in s {
                    cur.append(ch)
                    if cur.count >= chunk { out.append(cur); cur = "" }
                }
                if !cur.isEmpty { out.append(cur) }
                return out
            }
            func lines(_ objects: [Any], sse: Bool) -> LoopbackServer.Response {
                let data = objects.map { o -> Data in
                    if let s = o as? String { return Data("data: \(s)\n\n".utf8) }
                    let j = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
                    return sse ? Data("data: ".utf8) + j + Data("\n\n".utf8) : j + Data("\n".utf8)
                }
                return LoopbackServer.Response(status: 200, contentType: sse ? "text/event-stream" : "application/x-ndjson", chunks: data, delay: delay)
            }
            switch req.path {
            case "/api/tags":
                return .json(["models": [["name": modelName, "model": modelName]]])
            case "/api/show":
                return .json(["capabilities": ["completion", "insert"]])
            case "/api/generate":
                let text = answer(body["prompt"] as? String ?? "", body["suffix"] as? String ?? "")
                return lines(pieces(text).map { ["response": $0, "done": false] } + [["response": "", "done": true, "eval_count": text.count, "done_reason": "stop"]], sse: false)
            case "/infill":
                let text = answer(body["input_prefix"] as? String ?? "", body["input_suffix"] as? String ?? "")
                return lines(pieces(text).map { ["content": $0, "stop": false] } + [["content": "", "stop": true]], sse: true)
            case "/v1/models":
                return .json(["object": "list", "data": [["id": modelName, "object": "model"]]])
            case "/v1/completions":
                let text = answer(body["prompt"] as? String ?? "", "")
                return lines(pieces(text).map { ["choices": [["text": $0, "index": 0]]] } + ["[DONE]"], sse: true)
            case "/v1/chat/completions":
                let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
                let text = answer(user, "")
                return lines(pieces(text).map { ["choices": [["delta": ["content": $0], "index": 0]]] } + ["[DONE]"], sse: true)
            default:
                return .text("not found", status: 404)
            }
        }
        box.owner = self
    }

    final class LogBox: @unchecked Sendable {
        weak var owner: StandInServer?
        func add(_ r: Received) { owner?.append(r) }
    }

    private func append(_ r: Received) {
        lock.lock()
        log.append(r)
        lock.unlock()
    }

    public var baseURL: String { server.baseURL }
    public var received: [Received] { lock.lock(); defer { lock.unlock() }; return log }
    /// The generation requests (not model listing).
    public var generationRequests: [Received] {
        received.filter { ["/api/generate", "/infill", "/v1/completions", "/v1/chat/completions"].contains($0.path) }
    }
    public func stop() { server.stop() }
}
