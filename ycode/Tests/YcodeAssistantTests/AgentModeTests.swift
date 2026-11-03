import Foundation
import Testing
@testable import YcodeAssistant

/// A stand-in ACP agent in this process, on a pair of pipes.
final class StandInACPAgent: @unchecked Sendable {
    let toAgent = Pipe(), fromAgent = Pipe()
    let peer: JSONRPCPeer
    let root: URL
    private let lock = NSLock()
    private var log: [String] = []
    var cancelled = false

    init(root: URL) {
        self.root = root
        let out = fromAgent.fileHandleForWriting.fileDescriptor
        peer = JSONRPCPeer { FDWriter.write(out, $0) }
        start()
    }

    private func start() {
        let peer = peer
        peer.onNotification { [weak self] method, _ in
            self?.note(method)
            if method == "session/cancel" { self?.cancelled = true }
        }
        peer.onRequest { [weak self] _, method, params in
            self?.note(method)
            let agent = self
            return {
                guard let self = agent else { return .null }
                switch method {
                case "initialize":
                    #expect(params?["protocolVersion"] == 1 && params?["clientCapabilities"]?["fs"]?["writeTextFile"] == true)
                    return ["protocolVersion": 1, "agentCapabilities": ["loadSession": false, "mcpCapabilities": ["http": true]],
                            "agentInfo": ["name": "stand-in", "version": "1"], "authMethods": []]
                case "session/new":
                    self.note("mcp:" + (params?["mcpServers"]?.text ?? ""))
                    return ["sessionId": "s1"]
                case "session/prompt":
                    return try await self.turn(params?["prompt"]?[0]?["text"]?.string ?? "")
                default:
                    throw JSONRPCError.methodNotFound(method)
                }
            }
        }
        LineReader(fileDescriptor: toAgent.fileHandleForReading.fileDescriptor, onLine: { peer.receive($0) }, onEnd: {}).start()
    }

    func note(_ s: String) { lock.withLock { log.append(s) } }
    var calls: [String] { lock.withLock { log } }

    func update(_ u: AnyJSON) { peer.notify("session/update", ["sessionId": "s1", "update": u]) }

    /// Thinks, plans, reads a file, asks to edit it, writes it, reports.
    func turn(_ prompt: String) async throws -> AnyJSON {
        update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Reading the file.\n\n"]])
        update(["sessionUpdate": "plan", "entries": [["content": "Read a.txt", "priority": "high", "status": "completed"],
                                                     ["content": "Fix a.txt", "priority": "high", "status": "in_progress"]]])
        update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Edit a.txt", "kind": "edit", "status": "pending",
                "locations": [["path": .string(root.appendingPathComponent("a.txt").path), "line": 1]]])
        let file = root.appendingPathComponent("a.txt").path
        let read = try await peer.request("fs/read_text_file", ["sessionId": "s1", "path": .string(file), "line": 1, "limit": 1])
        let permission = try await peer.request("session/request_permission", [
            "sessionId": "s1", "toolCall": ["toolCallId": "t1", "title": "Edit a.txt"],
            "options": [["optionId": "yes", "name": "Allow", "kind": "allow_once"], ["optionId": "no", "name": "Reject", "kind": "reject_once"]],
        ])
        var wrote = "not asked"
        if permission["outcome"]?["optionId"] == "yes" {
            do {
                _ = try await peer.request("fs/write_text_file", ["sessionId": "s1", "path": .string(file), "content": "fixed\n"])
                wrote = "written"
            } catch let e as JSONRPCError {
                wrote = "refused: \(e.message)"
            }
        }
        update(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"])
        update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("Read \"\(read["content"]?.string ?? "")\"; ")]])
        update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("\(wrote). Prompt: \(prompt)")]])
        return ["stopReason": "end_turn"]
    }

    /// The client's end of the connection.
    func connect(_ handlers: ACPClientHandlers) -> ACPConnection {
        ACPConnection(readFrom: fromAgent.fileHandleForReading.fileDescriptor, writeTo: toAgent.fileHandleForWriting.fileDescriptor, handlers: handlers)
    }
}

@Suite struct AgentModeTests {
    static func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "first line\nsecond line\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func anACPSessionStreamsUpdatesAndRoutesFilesAndPermissionsThroughTheClient() async throws {
        let root = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = StandInACPAgent(root: root)
        final class Seen: @unchecked Sendable { var writes: [(String, String)] = []; var asked: [String] = [] }
        let seen = Seen()
        let c = agent.connect(ACPClientHandlers(readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
                                                writeTextFile: { p, t in seen.writes.append((p, t)); return true },
                                                requestPermission: { call, options in
            seen.asked.append("\(call.title ?? ""): \(options.map(\.name).joined(separator: "/"))")
            return options.first { $0.allows }?.id
        }))
        let info = try await c.initialize()
        #expect(info["agentInfo"]?["name"] == "stand-in")
        let session = try await c.newSession(cwd: root, mcp: [AgentAttachment.MCPEndpoint(url: "http://127.0.0.1:9/mcp", token: "T")])
        #expect(session == "s1")
        // The agent supports HTTP MCP servers: Ycode's is passed with its bearer token.
        let mcp = agent.calls.first { $0.hasPrefix("mcp:") } ?? ""
        #expect(mcp.contains("\"type\":\"http\"") && mcp.contains("Bearer T") && mcp.contains("\"name\":\"ycode\""))

        var events: [ACPEvent] = []
        for try await e in c.prompt(session: session, text: "fix it") { events.append(e) }
        #expect(events.first == .thought("Reading the file.\n\n"))
        #expect(events.contains(.plan([ACPPlanEntry(content: "Read a.txt", priority: "high", status: "completed"),
                                       ACPPlanEntry(content: "Fix a.txt", priority: "high", status: "in_progress")])))
        #expect(events.contains(.toolCall(ACPToolCall(id: "t1", title: "Edit a.txt", kind: "edit", status: "pending",
                                                      locations: [root.appendingPathComponent("a.txt").path + ":1"]))))
        #expect(events.contains(.toolCall(ACPToolCall(id: "t1", status: "completed"))))
        let text = events.compactMap { if case .message(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Read \"first line\"; written. Prompt: fix it")
        #expect(events.last == .stopped("end_turn"))
        #expect(seen.asked == ["Edit a.txt: Allow/Reject"])
        #expect(seen.writes.count == 1 && seen.writes[0].0.hasSuffix("/a.txt") && seen.writes[0].1 == "fixed\n")
    }

    @Test func aRejectedWriteIsAnErrorForTheAgentAndReadOnlyHandlersDeclinePermission() async throws {
        let root = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // Allowed, but the proposal is rejected.
        let agent = StandInACPAgent(root: root)
        let c = agent.connect(ACPClientHandlers(readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
                                                writeTextFile: { _, _ in false }, requestPermission: { _, o in o.first?.id }))
        try await c.initialize()
        var text = ""
        for try await e in c.prompt(session: try await c.newSession(cwd: root), text: "x") { if case .message(let t) = e { text += t } }
        #expect(text.contains("refused: The change to a.txt was not accepted in Ycode's review"))
        // Read-only: permission declined, nothing written.
        let agent2 = StandInACPAgent(root: root)
        let c2 = agent2.connect(.readOnly(root: root))
        try await c2.initialize()
        var text2 = ""
        for try await e in c2.prompt(session: try await c2.newSession(cwd: root), text: "x") { if case .message(let t) = e { text2 += t } }
        #expect(text2.contains("not asked"))
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "first line\nsecond line\n")
    }

    @Test func eventsBecomeTranscriptTextAndActivity() {
        var thinking = ""
        #expect(ACPAgentProvider.chatEvents(.message("Hi"), thinking: &thinking) == [.text("Hi")])
        #expect(ACPAgentProvider.chatEvents(.thought("short "), thinking: &thinking).isEmpty)
        #expect(ACPAgentProvider.chatEvents(.thought("idea.\n\n"), thinking: &thinking) == [.activity("Thinking: short idea.")])
        #expect(ACPAgentProvider.chatEvents(.toolCall(ACPToolCall(id: "1", title: "Build", status: "completed", locations: ["/w/a.swift:3"])), thinking: &thinking)
                == [.activity("Build (/w/a.swift:3) ✓")])
        #expect(ACPAgentProvider.chatEvents(.plan([ACPPlanEntry(content: "a", priority: "high", status: "completed"),
                                                   ACPPlanEntry(content: "b", priority: "low", status: "pending")]), thinking: &thinking)
                == [.activity("Plan: ☑ a; ☐ b")])
        #expect(CommandLineWords.split("agent --acp 'a b' \"c\"") == ["agent", "--acp", "a b", "c"])
    }

    /// A shell-script ACP agent (fixed request ids: initialize 0,
    /// session/new 1, session/prompt 2) run as a subprocess.
    @Test func theACPProviderRunsAnAgentProcess() async throws {
        let tools = try StandInTools()
        let script = tools.dir.appendingPathComponent("acp-agent")
        try """
        #!/bin/sh
        read l; echo '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"http":false}}}}'
        read l; printf '%s\\n' "$l" > "\(tools.dir.path)/new.json"; echo '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s9"}}'
        read l; printf '%s\\n' "$l" > "\(tools.dir.path)/prompt.json"
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s9","update":{"sessionUpdate":"tool_call","toolCallId":"a","title":"Search","status":"in_progress"}}}'
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s9","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Answer."}}}}'
        echo '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}'
        read l
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let provider = ACPAgentProvider(command: script.path + " --acp", locator: CLIToolLocator())
        #expect(provider.executable?.path == script.path && provider.arguments == ["--acp"])
        #expect(await provider.availability().isReady)
        var req = ChatRequest(model: nil, instructions: "I", messages: [ChatMessage(.user, "Q?")])
        req.workingDirectory = tools.dir
        let attached = provider.attaching(AgentAttachment(mcp: .init(url: "http://127.0.0.1:1/mcp", token: "tok")))
        let r = try await collect(attached.send(req))
        #expect(r.text == "Answer.")
        #expect(r.events.contains(.activity("Search…")))
        let new = try AnyJSON.parse(tools.recorded("new", "json").trimmingCharacters(in: .whitespacesAndNewlines))
        // The agent does not take HTTP MCP servers: none passed.
        #expect(new["params"]?["mcpServers"] == [] && new["params"]?["cwd"]?.string?.hasSuffix(tools.dir.lastPathComponent) == true)
        let prompt = try AnyJSON.parse(tools.recorded("prompt", "json").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(prompt["params"]?["prompt"]?[0]?["text"]?.string?.contains("Q?") == true)
        #expect(await ACPAgentProvider(command: "", locator: CLIToolLocator()).availability().isReady == false)
    }

    @Test func mcpToolCallsShowAsActivity() throws {
        var claude = ClaudeCodeEventParser()
        #expect(try claude.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__ycode__file_read","input":{"path":"Sources/A.swift"}}]}}"#)
                == [.activity("ycode: file_read Sources/A.swift")])
        var codex = CodexEventParser()
        #expect(try codex.parse(#"{"type":"item.started","item":{"type":"mcp_tool_call","server":"ycode","tool":"build","status":"in_progress"}}"#)
                == [.activity("ycode: build")])
    }

    @Test func agentModeAttachesYcodeMCPToClaudeCodeAndCodex() async throws {
        let tools = try StandInTools()
        // Claude Code: copies its MCP config while it runs.
        let claude = tools.dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(tools.dir.path)/claude.args"
        cat > /dev/null
        prev=""; for a in "$@"; do [ "$prev" = "--mcp-config" ] && cp "$a" "\(tools.dir.path)/mcp.copy" && ls -l "$a" > "\(tools.dir.path)/mcp.mode"; prev="$a"; done
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
        """.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let endpoint = AgentAttachment.MCPEndpoint(url: "http://127.0.0.1:4242/mcp", token: "secret-token")
        var req = ChatRequest(model: nil, instructions: "I", messages: [ChatMessage(.user, "go")])
        req.workingDirectory = tools.dir
        let p = CLIAgentProvider(agent: .claudeCode, executable: claude).attaching(AgentAttachment(mcp: endpoint))
        #expect(try await collect(p.send(req)).text == "ok")
        let args = tools.recorded("claude", "args").split(separator: "\n").map(String.init)
        #expect(args.contains("--mcp-config") && args.contains("--strict-mcp-config") && args.contains("--restricted") && !args.contains("--safe-mode"))
        #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == "mcp__ycode")
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "Read,Grep,Glob" && !args.contains("mcp__*"))
        let config = try AnyJSON.parse(tools.recorded("mcp", "copy"))
        #expect(config["mcpServers"]?["ycode"]?["url"] == "http://127.0.0.1:4242/mcp")
        #expect(config["mcpServers"]?["ycode"]?["headers"]?["Authorization"] == "Bearer secret-token")
        #expect(tools.recorded("mcp", "mode").hasPrefix("-rw-------"))
        // The token is in the file, not on the command line, and the file is gone.
        #expect(!args.joined().contains("secret-token"))
        let configPath = args[args.firstIndex(of: "--mcp-config")! + 1]
        #expect(!FileManager.default.fileExists(atPath: configPath))

        // Codex: -c overrides; the token in the environment.
        let codex = tools.dir.appendingPathComponent("codex")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(tools.dir.path)/codex.args"
        printf '%s' "$YCODE_MCP_TOKEN" > "\(tools.dir.path)/codex.token"
        cat > /dev/null
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}' '{"type":"turn.completed","usage":{}}'
        """.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let cp = CLIAgentProvider(agent: .codex, executable: codex).attaching(AgentAttachment(mcp: endpoint))
        #expect(try await collect(cp.send(req)).text == "done")
        let cargs = tools.recorded("codex", "args").split(separator: "\n").map(String.init)
        #expect(cargs.contains("mcp_servers.ycode.url=\"http://127.0.0.1:4242/mcp\""))
        #expect(cargs.contains("mcp_servers.ycode.bearer_token_env_var=\"YCODE_MCP_TOKEN\""))
        #expect(cargs.contains("read-only") && cargs.last == "-")
        #expect(tools.recorded("codex", "token") == "secret-token")
        // Antigravity documents no MCP configuration: unchanged.
        let agy = CLIAgentProvider(agent: .antigravity, executable: codex).attaching(AgentAttachment(mcp: endpoint))
        #expect((agy as? CLIAgentProvider)?.attachment == nil)
    }
}
