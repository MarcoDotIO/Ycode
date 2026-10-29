import Foundation
import Testing
@testable import YcodeAssistant

/// A temporary folder with stand-in executables.
final class StandInTools {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A shell script that saves its arguments and standard input, then
    /// prints `lines` and exits with `status`.
    @discardableResult
    func tool(_ name: String, lines: [String], status: Int = 0, stderr: String = "", readsStdin: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let out = lines.map { "printf '%s\\n' '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(dir.path)/\(name).args"
        pwd > "\(dir.path)/\(name).cwd"
        \(readsStdin ? "cat > \"\(dir.path)/\(name).stdin\"" : ": ")
        \(out)
        \(stderr.isEmpty ? "" : "printf '%s\\n' '\(stderr)' >&2")
        exit \(status)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func recorded(_ name: String, _ kind: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("\(name).\(kind)"), encoding: .utf8)) ?? ""
    }
}

@Suite struct CLIAgentTests {
    let request = ChatRequest(model: nil, instructions: "INSTRUCTIONS", messages: [ChatMessage(.user, "What does main do?")])

    @Test func claudeCodeStreamJSON() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("claude", lines: [
            #"{"type":"system","subtype":"init","session_id":"s","tools":["Read","Grep","Glob"],"model":"m"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It "}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"prints."}},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"It prints."},{"type":"tool_use","name":"Read","input":{"file_path":"/w/main.swift"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sub"}},"parent_tool_use_id":"toolu_1"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"It prints.","usage":{"input_tokens":9,"output_tokens":3},"session_id":"s"}"#,
        ])
        let work = tools.dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var req = request
        req.workingDirectory = work
        req.model = "sonnet"
        let r = try await collect(CLIAgentProvider(agent: .claudeCode, executable: exe).send(req))
        #expect(r.text == "It prints.")
        #expect(r.events.contains(.activity("Read: /w/main.swift")))
        #expect(r.events.last == .finished(TokenUsage(inputTokens: 9, outputTokens: 3)))
        let args = tools.recorded("claude", "args").split(separator: "\n").map(String.init)
        #expect(args.starts(with: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]))
        #expect(args.contains("--permission-mode") && args[args.firstIndex(of: "--permission-mode")! + 1] == "plan")
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "Read,Grep,Glob")
        #expect(args.contains("--safe-mode") && args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"))
        #expect(!args.contains { $0.contains("Edit") || $0.contains("Write") || $0.contains("Bash") || $0.contains("dangerously") })
        #expect(args.suffix(2) == ["--model", "sonnet"])
        #expect(tools.recorded("claude", "stdin").hasPrefix("INSTRUCTIONS"))
        #expect(tools.recorded("claude", "stdin").contains("What does main do?"))
        #expect(tools.recorded("claude", "cwd").trimmingCharacters(in: .newlines).hasSuffix("/work"))
    }

    @Test func claudeCodeErrorResult() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("claude", lines: [#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#], status: 1)
        await #expect(throws: AssistantError.tool(name: "Claude Code", message: "Not logged in · Please run /login")) {
            _ = try await collect(CLIAgentProvider(agent: .claudeCode, executable: exe).send(request))
        }
    }

    @Test func codexJSONL() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("codex", lines: [
            #"{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"reasoning","text":"thinking"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Repo contains docs, sdk, and examples directories."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}"#,
        ])
        var req = request
        req.workingDirectory = tools.dir
        let r = try await collect(CLIAgentProvider(agent: .codex, executable: exe).send(req))
        #expect(r.text == "Repo contains docs, sdk, and examples directories.")
        #expect(r.events.contains(.activity("Running bash -lc ls")))
        #expect(r.events.last == .finished(TokenUsage(inputTokens: 24763, outputTokens: 122)))
        let args = tools.recorded("codex", "args").split(separator: "\n").map(String.init)
        #expect(args.first == "exec" && args.contains("--json") && args.last == "-")
        #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only")
        #expect(args[args.firstIndex(of: "-C")! + 1] == tools.dir.path)
        #expect(args.contains("--ephemeral"))
        #expect(!args.contains { $0.contains("dangerously") || $0 == "workspace-write" || $0 == "--approve-for-me" })
        #expect(tools.recorded("codex", "stdin").contains("What does main do?"))
    }

    @Test func codexTurnFailed() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("codex", lines: [#"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#], status: 1)
        await #expect(throws: AssistantError.tool(name: "Codex", message: "usage limit reached")) {
            _ = try await collect(CLIAgentProvider(agent: .codex, executable: exe).send(request))
        }
    }

    @Test func antigravityStreamJSON() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("agy", lines: [
            #"{"event":"init","init":{"cwd":"/w","tools":["read_file"],"permission_mode":"plan"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"read_file"}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"Main "}}"#,
            #"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"starts the app."}}"#,
            #"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"Main starts the app.","usage":{"input_tokens":30,"output_tokens":5}}}"#,
        ], readsStdin: false)
        let r = try await collect(CLIAgentProvider(agent: .antigravity, executable: exe).send(request))
        #expect(r.text == "Main starts the app.")
        #expect(r.events.contains(.activity("read_file")))
        let args = tools.recorded("agy", "args").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(args.first == "-p")
        #expect(args.contains("--mode") && args[args.firstIndex(of: "--mode")! + 1] == "plan")
        #expect(args.contains("--sandbox") && args.contains("--disable-slash-commands"))
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(tools.recorded("agy", "args").contains("What does main do?"))
    }

    @Test func antigravityErrorStatus() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("agy", lines: [#"{"event":"result","result":{"status":"ERROR","error":"authentication required"}}"#], status: 1, readsStdin: false)
        await #expect(throws: AssistantError.tool(name: "Antigravity", message: "authentication required")) {
            _ = try await collect(CLIAgentProvider(agent: .antigravity, executable: exe).send(request))
        }
    }

    @Test func exitWithoutEventsExplainsSignIn() async throws {
        let tools = try StandInTools()
        let exe = try tools.tool("codex", lines: [], status: 2, stderr: "Error: not logged in. Run codex login.")
        do {
            _ = try await collect(CLIAgentProvider(agent: .codex, executable: exe).send(request))
            Issue.record("expected an error")
        } catch let AssistantError.tool(name, message) {
            #expect(name == "Codex")
            #expect(message.contains("sign in"))
        }
    }

    /// The stop button: cancelling interrupts a tool that keeps running.
    @Test func cancelInterruptsTheTool() async throws {
        let tools = try StandInTools()
        let exe = tools.dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        trap 'echo interrupted > "\(tools.dir.path)/claude.signal"; exit 130' INT
        cat > /dev/null
        echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}}'
        i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
        """.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let started = Date()
        let task = Task { try await collect(CLIAgentProvider(agent: .claudeCode, executable: exe).send(request)) }
        try await Task.sleep(nanoseconds: 600_000_000)
        task.cancel()
        _ = await task.result
        for _ in 0..<50 where tools.recorded("claude", "signal").isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(tools.recorded("claude", "signal").contains("interrupted"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func locatorSearchesPathThenUsualFolders() throws {
        let tools = try StandInTools()
        let home = tools.dir.appendingPathComponent("home")
        let nvmOld = home.appendingPathComponent(".nvm/versions/node/v18.2.0/bin")
        let nvmNew = home.appendingPathComponent(".nvm/versions/node/v22.10.1/bin")
        for d in [nvmOld, nvmNew] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for d in [nvmOld, nvmNew] {
            let f = d.appendingPathComponent("claude")
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        let locator = CLIToolLocator(environment: ["PATH": "/nonexistent"], home: home.path)
        #expect(locator.find("claude")?.path == nvmNew.appendingPathComponent("claude").path)
        #expect(locator.find("definitely-not-a-tool-\(UUID().uuidString)") == nil)
        #expect(locator.find("claude", override: nvmOld.appendingPathComponent("claude").path)?.path == nvmOld.appendingPathComponent("claude").path)
        #expect(locator.find("claude", override: "/nonexistent/claude") == nil)
        let onPath = CLIToolLocator(environment: ["PATH": nvmOld.path], home: home.path)
        #expect(onPath.find("claude")?.path == nvmOld.appendingPathComponent("claude").path)
    }

    @Test func notInstalledAvailability() async {
        guard case .notInstalled(let hint) = await CLIAgentProvider(agent: .antigravity, executable: nil).availability() else {
            Issue.record("expected notInstalled"); return
        }
        #expect(hint.contains("agy"))
    }
}
