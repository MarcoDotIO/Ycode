import Foundation
import YcodeSubprocess

// The Agent Client Protocol (agentclientprotocol.com, protocol version 1,
// Apache-2.0): Ycode is the client (the editor); the agent runs as a
// subprocess and speaks newline-delimited JSON-RPC on its standard input
// and output. See specs/ide/coding-assistant.md, "Ycode implementation".

/// What an ACP agent reports while it works on a prompt.
public enum ACPEvent: Sendable, Equatable {
    case message(String)
    case thought(String)
    /// A tool call starts or changes (`tool_call`, `tool_call_update`).
    case toolCall(ACPToolCall)
    case plan([ACPPlanEntry])
    case mode(String)
    /// A notice or other line worth showing.
    case notice(String)
    /// The turn ended (`stopReason`: end_turn, max_tokens, max_turn_requests, refusal, cancelled).
    case stopped(String)
}

public struct ACPToolCall: Sendable, Equatable {
    public var id: String
    public var title: String?
    /// read, edit, delete, move, search, execute, think, fetch, switch_mode, other.
    public var kind: String?
    /// pending, in_progress, completed, failed.
    public var status: String?
    public var locations: [String]
    public init(id: String, title: String? = nil, kind: String? = nil, status: String? = nil, locations: [String] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.locations = locations
    }

    init(_ u: AnyJSON) {
        id = u["toolCallId"]?.string ?? ""
        title = u["title"]?.string
        kind = u["kind"]?.string
        status = u["status"]?.string
        locations = u["locations"]?.array?.compactMap { l in
            l["path"]?.string.map { p in l["line"]?.int.map { "\(p):\($0)" } ?? p }
        } ?? []
    }
}

public struct ACPPlanEntry: Sendable, Equatable {
    public var content: String
    public var priority: String
    public var status: String
    public init(content: String, priority: String, status: String) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// How the client answers the agent's requests.
public struct ACPClientHandlers: Sendable {
    /// `fs/read_text_file`: the file's text (path absolute; line 1-based).
    public var readTextFile: @Sendable (_ path: String) async throws -> String
    /// `fs/write_text_file`: true when the write happened (the IDE: the
    /// user accepted the proposal).
    public var writeTextFile: @Sendable (_ path: String, _ content: String) async throws -> Bool
    /// `session/request_permission`: the chosen option's id, nil to cancel.
    public var requestPermission: @Sendable (_ toolCall: ACPToolCall, _ options: [AgentAttachment.PermissionOption]) async -> String?

    public init(readTextFile: @escaping @Sendable (String) async throws -> String,
                writeTextFile: @escaping @Sendable (String, String) async throws -> Bool,
                requestPermission: @escaping @Sendable (ACPToolCall, [AgentAttachment.PermissionOption]) async -> String?) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.requestPermission = requestPermission
    }

    /// Reads from disk inside `root`; refuses writes and permissions.
    public static func readOnly(root: URL) -> ACPClientHandlers {
        ACPClientHandlers(readTextFile: { path in
            guard ACPConnection.isInside(path, root: root) else { throw JSONRPCError.invalidParams("\(path) is outside the workspace") }
            do { return try String(contentsOfFile: path, encoding: .utf8) } catch { throw JSONRPCError(code: -32002, message: "cannot read \(path)") }
        }, writeTextFile: { _, _ in false }, requestPermission: { _, options in options.first { !$0.allows }?.id })
    }
}

/// One connection to an ACP agent.
public final class ACPConnection: @unchecked Sendable {
    public static let protocolVersion = 1

    public let peer: JSONRPCPeer
    private let lock = NSLock()
    private var streams: [String: AsyncThrowingStream<ACPEvent, Error>.Continuation] = [:]
    private var handlers: ACPClientHandlers
    private var process: Process?
    private var stderrTail = ""
    private var ended = false
    public private(set) var agentInfo: AnyJSON?
    public private(set) var agentCapabilities: AnyJSON?

    /// Over two file descriptors (tests run an agent in process).
    public init(readFrom input: Int32, writeTo output: Int32, handlers: ACPClientHandlers) {
        // A write to an agent that has exited fails (EPIPE) instead of
        // ending Ycode.
        signal(SIGPIPE, SIG_IGN)
        self.handlers = handlers
        peer = JSONRPCPeer { data in FDWriter.write(output, data) }
        install()
        LineReader(fileDescriptor: input, onLine: { [weak self] in self?.peer.receive($0) }, onEnd: { [weak self] in self?.endOfStream() }).start()
    }

    /// Starts the agent's executable.
    public convenience init(executable: URL, arguments: [String], currentDirectory: URL, environment: [String: String]? = nil,
                            handlers: ACPClientHandlers) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.currentDirectoryURL = currentDirectory
        var env = environment ?? ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        // Node-based agents need `node` next to them.
        env["PATH"] = ([executable.deletingLastPathComponent().path] + (env["PATH"].map { [$0] } ?? ["/usr/bin:/bin"])).joined(separator: ":")
        p.environment = env
        // Close-on-exec pipes (`SpawnPipe`): with `Pipe`s, a child another
        // thread starts at the same moment can hold the agent's input open.
        let toAgent = try SpawnPipe(childReads: true), fromAgent = try SpawnPipe(childReads: false), errors = try SpawnPipe(childReads: false)
        p.standardInput = toAgent.childEnd
        p.standardOutput = fromAgent.childEnd
        p.standardError = errors.childEnd
        defer { [toAgent, fromAgent, errors].forEach { $0.closeChildEnd() } }
        // Unblocked signals, so that `close()` can stop the agent.
        try p.runWithSignalsUnblocked()
        self.init(readFrom: fromAgent.parentEnd.fileDescriptor, writeTo: toAgent.parentEnd.fileDescriptor, handlers: handlers)
        lock.withLock { process = p }
        errors.parentEnd.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { h.readabilityHandler = nil; return }
            self.lock.withLock { self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000)) }
        }
        // Keep the pipes' write ends alive with the process.
        keptPipes = [toAgent, fromAgent, errors]
    }

    private var keptPipes: [SpawnPipe] = []

    /// The agent's last standard-error output (for failure messages).
    public var errorOutput: String { lock.withLock { stderrTail } }

    public func setHandlers(_ h: ACPClientHandlers) { lock.withLock { handlers = h } }

    static func isInside(_ path: String, root: URL) -> Bool {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
            || URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private func install() {
        peer.onNotification { [weak self] method, params in
            guard let self, method == "session/update", let sid = params?["sessionId"]?.string, let u = params?["update"] else { return }
            guard let event = Self.event(u) else { return }
            self.lock.withLock { self.streams[sid] }?.yield(event)
        }
        peer.onRequest { [weak self] _, method, params in
            guard let self else { return { throw JSONRPCError.internalError("gone") } }
            let h = self.lock.withLock { self.handlers }
            switch method {
            case "fs/read_text_file":
                return {
                    guard let path = params?["path"]?.string, path.hasPrefix("/") else { throw JSONRPCError.invalidParams("path must be absolute") }
                    var text = try await h.readTextFile(path)
                    if let line = params?["line"]?.int, line > 1 || params?["limit"]?.int != nil {
                        let lines = text.components(separatedBy: "\n")
                        let start = max(0, line - 1), end = params?["limit"]?.int.map { min(lines.count, start + $0) } ?? lines.count
                        text = start < lines.count ? lines[start..<end].joined(separator: "\n") : ""
                    }
                    return ["content": .string(text)]
                }
            case "fs/write_text_file":
                return {
                    guard let path = params?["path"]?.string, path.hasPrefix("/"), let content = params?["content"]?.string else {
                        throw JSONRPCError.invalidParams("fs/write_text_file needs an absolute path and content")
                    }
                    guard try await h.writeTextFile(path, content) else {
                        throw JSONRPCError(code: -32003, message: "The change to \((path as NSString).lastPathComponent) was not accepted in Ycode's review; nothing was written.")
                    }
                    return [:]
                }
            case "session/request_permission":
                return {
                    let call = ACPToolCall(params?["toolCall"] ?? [:])
                    let options = (params?["options"]?.array ?? []).compactMap { o -> AgentAttachment.PermissionOption? in
                        guard let id = o["optionId"]?.string else { return nil }
                        return AgentAttachment.PermissionOption(id: id, name: o["name"]?.string ?? id, kind: o["kind"]?.string ?? "allow_once")
                    }
                    guard let chosen = await h.requestPermission(call, options) else { return ["outcome": ["outcome": "cancelled"]] }
                    return ["outcome": ["outcome": "selected", "optionId": .string(chosen)]]
                }
            default:
                return { throw JSONRPCError.methodNotFound(method) }
            }
        }
    }

    /// The event a `session/update` carries (nil: not shown).
    static func event(_ u: AnyJSON) -> ACPEvent? {
        switch u["sessionUpdate"]?.string {
        case "agent_message_chunk":
            return u["content"]?["text"]?.string.map { .message($0) }
        case "agent_thought_chunk":
            return u["content"]?["text"]?.string.map { .thought($0) }
        case "tool_call", "tool_call_update":
            return .toolCall(ACPToolCall(u))
        case "plan":
            return .plan((u["entries"]?.array ?? []).map {
                ACPPlanEntry(content: $0["content"]?.string ?? "", priority: $0["priority"]?.string ?? "medium", status: $0["status"]?.string ?? "pending")
            })
        case "current_mode_update":
            return u["currentModeId"]?.string.map { .mode($0) }
        case "notice":
            return .notice([u["title"]?.string, u["description"]?.string].compactMap { $0 }.joined(separator: ": "))
        default:
            return nil
        }
    }

    // MARK: Client → agent

    /// `initialize`: protocol version 1, file reads and writes through the
    /// client, no terminals.
    @discardableResult
    public func initialize() async throws -> AnyJSON {
        let r = try await peer.request("initialize", [
            "protocolVersion": .int(Self.protocolVersion),
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": false],
            "clientInfo": ["name": "ycode", "title": "Ycode", "version": "0.27"],
        ])
        lock.withLock {
            agentInfo = r["agentInfo"]
            agentCapabilities = r["agentCapabilities"]
        }
        if let v = r["protocolVersion"]?.int, v != Self.protocolVersion {
            throw AssistantError.tool(name: "ACP agent", message: "it speaks ACP version \(v); Ycode speaks version \(Self.protocolVersion)")
        }
        return r
    }

    /// `session/new` in `cwd`, with MCP servers for the agent (Ycode's own
    /// over HTTP when it has one; agents that do not support HTTP get none).
    public func newSession(cwd: URL, mcp: [AgentAttachment.MCPEndpoint] = []) async throws -> String {
        let http = agentCapabilities?["mcpCapabilities"]?["http"]?.bool ?? false
        let servers: [AnyJSON] = http ? mcp.map { m in
            ["type": "http", "name": .string(m.name), "url": .string(m.url), "headers": [["name": "Authorization", "value": .string("Bearer \(m.token)")]]]
        } : []
        let r = try await peer.request("session/new", ["cwd": .string(cwd.path), "mcpServers": .array(servers)])
        guard let id = r["sessionId"]?.string else { throw AssistantError.tool(name: "ACP agent", message: "session/new returned no sessionId") }
        return id
    }

    /// `session/prompt` with one text block; the stream carries the
    /// session's updates and ends with `.stopped(reason)`. Ending the
    /// iteration sends `session/cancel`.
    public func prompt(session: String, text: String) -> AsyncThrowingStream<ACPEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ACPEvent, Error>.makeStream()
        lock.withLock { streams[session] = continuation }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.peer.request("session/prompt", ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(text)]]])
                continuation.yield(.stopped(r["stopReason"]?.string ?? "end_turn"))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            _ = self.lock.withLock { self.streams.removeValue(forKey: session) }
        }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                self?.peer.notify("session/cancel", ["sessionId": .string(session)])
                // The agent answers the prompt with stopReason "cancelled";
                // give it a moment, then stop waiting.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    task.cancel()
                }
            }
        }
        return stream
    }

    public func cancel(session: String) { peer.notify("session/cancel", ["sessionId": .string(session)]) }

    private func endOfStream() {
        let open: [AsyncThrowingStream<ACPEvent, Error>.Continuation] = lock.withLock {
            ended = true
            defer { streams = [:] }
            return Array(streams.values)
        }
        let tail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = AssistantError.tool(name: "ACP agent", message: tail.isEmpty ? "the agent exited" : "the agent exited: \(tail.suffix(600))")
        peer.close(error)
        open.forEach { $0.finish(throwing: error) }
    }

    /// Ends the agent process and whatever it started (its process group):
    /// SIGINT, then SIGTERM and SIGKILL two seconds apart while it runs.
    public func close() {
        guard let p = lock.withLock({ process }), p.isRunning else { return }
        let pid = p.processIdentifier
        ChildSignals.send(SIGINT, to: pid)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard p.isRunning else { return }
            ChildSignals.send(SIGTERM, to: pid)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { ChildSignals.send(SIGKILL, to: pid) } }
        }
    }

    deinit { close() }
}
