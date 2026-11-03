import Foundation
import YcodeAssistant

/// The stdio transport: newline-delimited JSON-RPC on two file
/// descriptors (the client starts the server as a subprocess). Requests
/// run concurrently; `notifications/cancelled` cancels one; progress goes
/// out as `notifications/progress`.
public final class MCPStdioTransport: @unchecked Sendable {
    public let server: MCPServer
    public let peer: JSONRPCPeer
    let connection = MCPServer.Connection()
    private let input: Int32
    private let onClose: @Sendable () -> Void

    public init(server: MCPServer, input: Int32, output: Int32, onClose: @escaping @Sendable () -> Void = {}) {
        self.server = server
        self.input = input
        self.onClose = onClose
        peer = JSONRPCPeer { data in FDWriter.write(output, data) }
        let peer = peer, connection = connection
        peer.onRequest { _, method, params in
            let progress = MCPHTTPTransport.progress(for: params) { note in peer.write(note) }
            return { try await server.handle(method: method, params: params, connection: connection, progress: progress) }
        }
        peer.onNotification { method, params in
            if method == "notifications/cancelled", let id = JSONRPCID(params?["requestId"]) { peer.cancelIncoming(id) }
        }
    }

    /// Starts reading; `onClose` runs at end of input.
    public func start() {
        let peer = peer, onClose = onClose
        LineReader(fileDescriptor: input, onLine: { peer.receive($0) }, onEnd: {
            peer.close()
            onClose()
        }).start()
    }
}

/// The Streamable HTTP transport on 127.0.0.1 only, behind a bearer token
/// (the IDE's agent sessions; `ycode mcp --http`). One POST per message at
/// `/mcp`; a request is answered with one JSON object, or, when it asked
/// for progress and accepts `text/event-stream`, with an SSE stream of its
/// progress notifications and then its response. GET and DELETE: 405 (no
/// standalone stream, no sessions). Origins other than loopback: 403.
public final class MCPHTTPTransport: @unchecked Sendable {
    public let server: MCPServer
    public let token: String
    private var http: LoopbackServer?
    private let lock = NSLock()
    /// Legacy clients that initialized, by the (ignored) session header;
    /// the transport keeps no sessions, so all share one connection.
    let connection = MCPServer.Connection()

    public init(server: MCPServer, token: String = MCPHTTPTransport.newToken(), port: UInt16 = 0) throws {
        self.server = server
        self.token = token
        let handler: LoopbackServer.Handler = { [weak self] request in
            guard let self else { return .text("gone", status: 503) }
            return self.respond(request)
        }
        http = try LoopbackServer(port: port, handler: handler)
    }

    deinit { http?.stop() }

    public func stop() { lock.withLock { http }?.stop() }

    public var port: UInt16 { http?.port ?? 0 }
    /// `http://127.0.0.1:<port>/mcp`.
    public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// 32 random bytes, hex.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// The progress reporter for a request whose `_meta.progressToken` is
    /// set; `emit` sends each notification.
    static func progress(for params: AnyJSON?, emit: @escaping @Sendable (JSONRPCMessage) -> Void) -> MCPProgress {
        guard let token = params?["_meta"]?["progressToken"], token.string != nil || token.int != nil else { return .none }
        return MCPProgress { done, total, message in
            var p: [String: AnyJSON] = ["progressToken": token, "progress": .double(done)]
            if let total { p["total"] = .double(total) }
            if let message { p["message"] = .string(message) }
            emit(.notification(method: "notifications/progress", params: .object(p)))
        }
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Decodes an `Mcp-Name` value in the `=?base64?…?=` form.
    static func headerValue(_ raw: String) -> String {
        guard raw.hasPrefix("=?base64?"), raw.hasSuffix("?="), raw.count >= 11 else { return raw }
        let b64 = String(raw.dropFirst(9).dropLast(2))
        return Data(base64Encoded: b64).map { String(decoding: $0, as: UTF8.self) } ?? raw
    }

    static func errorResponse(_ e: JSONRPCError, id: JSONRPCID?, status: Int) -> LoopbackServer.Response {
        LoopbackServer.Response(status: status, contentType: "application/json", body: JSONRPCMessage.error(id: id, error: e).json.data())
    }

    func respond(_ r: LoopbackServer.Request) -> LoopbackServer.Response {
        if let origin = r.header("origin"), !Self.isLoopbackOrigin(origin) {
            return Self.errorResponse(.init(code: -32600, message: "Forbidden origin"), id: nil, status: 403)
        }
        guard r.path == "/mcp" else { return .text("not found", status: 404) }
        let auth = r.header("authorization") ?? ""
        guard auth.hasPrefix("Bearer "), Self.constantTimeEqual(String(auth.dropFirst(7)), token) else {
            return LoopbackServer.Response(status: 401, contentType: "application/json",
                                           body: JSONRPCMessage.error(id: nil, error: .init(code: -32600, message: "Unauthorized")).json.data(),
                                           headers: ["WWW-Authenticate": "Bearer"])
        }
        guard r.method == "POST" else {
            return LoopbackServer.Response(status: 405, contentType: "text/plain", body: Data("POST only".utf8), headers: ["Allow": "POST"])
        }
        let message: JSONRPCMessage
        do {
            message = try JSONRPCMessage.parse(r.body)
        } catch let e as JSONRPCError {
            return Self.errorResponse(e, id: nil, status: 400)
        } catch {
            return Self.errorResponse(.parseError(), id: nil, status: 400)
        }
        guard case .request(let id, let method, let params) = message else {
            // Notifications and responses: accepted, nothing to answer.
            return LoopbackServer.Response(status: 202, contentType: "text/plain", body: Data())
        }
        // Modern requests: the header must match the body (`HeaderMismatch`).
        let era: MCPServer.Era
        do {
            era = try MCPServer.era(of: params)
        } catch let e as JSONRPCError {
            return Self.errorResponse(e, id: id, status: 400)
        } catch {
            return Self.errorResponse(.internalError("\(error)"), id: id, status: 500)
        }
        if era == .modern {
            let version = params?["_meta"]?[MCPServer.protocolVersionKey]?.string
            let mismatch = JSONRPCError(code: -32020, message: "Header mismatch")
            guard r.header("mcp-protocol-version") == version else {
                return Self.errorResponse(.init(code: -32020, message: "Header mismatch: MCP-Protocol-Version"), id: id, status: 400)
            }
            guard r.header("mcp-method") == method else { return Self.errorResponse(mismatch, id: id, status: 400) }
            if ["tools/call", "prompts/get", "resources/read"].contains(method) {
                let body = method == "resources/read" ? params?["uri"]?.string : params?["name"]?.string
                guard let h = r.header("mcp-name"), Self.headerValue(h) == body else {
                    return Self.errorResponse(.init(code: -32020, message: "Header mismatch: Mcp-Name"), id: id, status: 400)
                }
            }
            if !MCPServer.methods.contains(method) || method == "initialize" {
                return Self.errorResponse(.methodNotFound(method), id: id, status: 404)
            }
        }
        let server = server, connection = connection
        let wantsStream = (r.header("accept") ?? "").contains("text/event-stream") && params?["_meta"]?["progressToken"] != nil
        if wantsStream {
            var response = LoopbackServer.Response(status: 200, contentType: "text/event-stream", body: Data(),
                                                   headers: ["Cache-Control": "no-cache", "X-Accel-Buffering": "no"])
            response.stream = { write in
                @Sendable func event(_ m: JSONRPCMessage) -> Bool { write(Data("event: message\ndata: ".utf8) + m.json.data() + Data("\n\n".utf8)) }
                let progress = Self.progress(for: params) { note in _ = event(note) }
                let reply = Self.wait { () -> JSONRPCMessage in
                    do {
                        return .result(id: id, result: try await server.handle(method: method, params: params, connection: connection, progress: progress))
                    } catch let e as JSONRPCError {
                        return .error(id: id, error: e)
                    } catch {
                        return .error(id: id, error: .internalError("\(error)"))
                    }
                }
                _ = event(reply)
            }
            return response
        }
        let reply = Self.wait { () -> (JSONRPCMessage, Int) in
            do {
                return (.result(id: id, result: try await server.handle(method: method, params: params, connection: connection)), 200)
            } catch let e as JSONRPCError {
                // Legacy clients read errors from 200 responses; modern ones
                // get 400 for protocol errors, 404 for unknown methods.
                let status = era == .legacy ? 200 : (e.code == -32601 ? 404 : 400)
                return (.error(id: id, error: e), status)
            } catch {
                return (.error(id: id, error: .internalError("\(error)")), 500)
            }
        }
        return LoopbackServer.Response(status: reply.1, contentType: "application/json", body: reply.0.json.data())
    }

    /// Runs async work to its end from a connection thread.
    static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = WaitBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

final class WaitBox<T>: @unchecked Sendable { var value: T? }
