import Foundation
import YcodeSubprocess

/// Agent command-line tools the user has installed and signed in to
/// themselves. Ycode only runs each tool's documented headless mode,
/// read-only, in the workspace folder, and reads its documented event
/// stream. It never reads, copies or changes the tool's credentials or
/// configuration; the tool authenticates itself (coding-assistant.md §3.4).
public enum CLIAgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex, antigravity

    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
    }

    public var displayName: String { providerKind.displayName }

    public var providerKind: ProviderKind {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .antigravity: .antigravity
        }
    }

    /// Where to get it, for the empty state.
    public var installHint: String {
        switch self {
        case .claudeCode: "Install Claude Code and sign in once by running `claude` in Terminal."
        case .codex: "Install Codex and sign in once by running `codex` in Terminal."
        case .antigravity: "Install the Antigravity CLI and sign in once by running `agy` in Terminal."
        }
    }

    /// The model names offered besides the tool's own default (Claude
    /// Code's documented aliases; the others take a name typed in Settings).
    public var suggestedModels: [String] {
        switch self {
        case .claudeCode: ["sonnet", "opus", "haiku"]
        case .codex, .antigravity: []
        }
    }

    /// The command line, without the executable. The prompt goes to
    /// standard input except for Antigravity, whose documented print mode
    /// takes it as the `-p` argument.
    ///
    /// - Claude Code: print mode with the stream-json event stream and
    ///   partial messages; plan permission mode; only the read-only Read,
    ///   Grep and Glob tools; no MCP tools; safe mode (no hooks, plugins or
    ///   project MCP servers from the workspace); nothing saved; nothing
    ///   that would prompt.
    /// - Codex: `exec` with JSONL events, the read-only sandbox, no session
    ///   files, working root `-C`.
    /// - Antigravity: print mode with stream-json, plan mode, the terminal
    ///   sandbox, no slash-command expansion.
    public func arguments(model: String?, workingDirectory: String, prompt: String, toolsEnabled: Bool = true) -> [String] {
        let m = model.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .claudeCode:
            var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--permission-mode", "plan", "--tools", toolsEnabled ? "Read,Grep,Glob" : "",
                     "--disallowedTools", "mcp__*", "--strict-mcp-config", "--safe-mode", "--no-session-persistence",
                     "--permission-prompts", "none"]
            if let m { a += ["--model", m] }
            return a
        case .codex:
            var a = ["exec", "--json", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--color", "never",
                     "-C", workingDirectory]
            if let m { a += ["-m", m] }
            return a + ["-"]
        case .antigravity:
            var a = ["-p", prompt, "--output-format", "stream-json", "--mode", "plan", "--sandbox", "--disable-slash-commands"]
            if let m { a += ["--model", m] }
            return a
        }
    }

    /// Whether the prompt is sent on standard input.
    public var promptOnStandardInput: Bool { self != .antigravity }

    public func makeParser() -> CLIEventParser {
        switch self {
        case .claudeCode: ClaudeCodeEventParser()
        case .codex: CodexEventParser()
        case .antigravity: AntigravityEventParser()
        }
    }
}

/// Turns one line of a tool's JSON event stream into chat events.
public protocol CLIEventParser {
    /// Events for one line. Throws when the line reports a failure.
    mutating func parse(_ line: String) throws -> [ChatEvent]
    /// Events at the end of the stream (text that only the final record
    /// carried).
    mutating func finish() -> [ChatEvent]
}

/// Claude Code `--output-format stream-json` (Claude Code's headless and
/// CLI reference): `stream_event` lines carry `content_block_delta` /
/// `text_delta` text; `assistant` messages carry whole content blocks
/// (`text`, `tool_use`); the last line is `result` (`is_error`, `result`,
/// `usage`); `system/api_retry` reports retries. Messages of subagents
/// (`parent_tool_use_id` set) are not shown as text.
public struct ClaudeCodeEventParser: CLIEventParser {
    var sawDelta = false
    var sawText = false
    var finished = false
    public init() {}

    public mutating func parse(_ line: String) throws -> [ChatEvent] {
        guard let o = JSON.object(line) else { return [] }
        let isMain = o["parent_tool_use_id"] == nil || o["parent_tool_use_id"] is NSNull
        switch o["type"] as? String {
        case "stream_event":
            guard isMain, let e = o["event"] as? [String: Any], (e["type"] as? String) == "content_block_delta",
                  let d = e["delta"] as? [String: Any], (d["type"] as? String) == "text_delta", let t = d["text"] as? String else { return [] }
            sawDelta = true
            sawText = true
            return [.text(t)]
        case "assistant":
            guard isMain, let m = o["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { return [] }
            var out: [ChatEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text" where !sawDelta:
                    if let t = block["text"] as? String, !t.isEmpty { out.append(.text(t)); sawText = true }
                case "tool_use":
                    out.append(.activity(Self.describeTool(block["name"] as? String ?? "tool", block["input"] as? [String: Any])))
                default: break
                }
            }
            sawDelta = false
            return out
        case "system":
            if (o["subtype"] as? String) == "api_retry" {
                return [.activity("Retrying (attempt \(JSON.int(o["attempt"]) ?? 1))…")]
            }
            return []
        case "result":
            finished = true
            let text = o["result"] as? String ?? ""
            if (o["is_error"] as? Bool) == true || ((o["subtype"] as? String).map { $0.hasPrefix("error") } ?? false) {
                throw AssistantError.tool(name: "Claude Code", message: text.isEmpty ? (o["subtype"] as? String ?? "error") : text)
            }
            var out: [ChatEvent] = []
            if !sawText && !text.isEmpty { out.append(.text(text)) }
            let u = o["usage"] as? [String: Any]
            out.append(.finished(u.map { TokenUsage(inputTokens: JSON.int($0["input_tokens"]), outputTokens: JSON.int($0["output_tokens"])) }))
            return out
        default:
            return []
        }
    }

    public mutating func finish() -> [ChatEvent] { [] }

    static func describeTool(_ name: String, _ input: [String: Any]?) -> String {
        let target = (input?["file_path"] as? String) ?? (input?["path"] as? String) ?? (input?["pattern"] as? String)
        return target.map { "\(name): \($0)" } ?? name
    }
}

/// Codex `exec --json` (Codex's non-interactive mode): JSON Lines with
/// `thread.started`, `turn.started`, `item.started` / `item.updated` /
/// `item.completed` (items `agent_message`, `reasoning`,
/// `command_execution`, `file_change`, …), `turn.completed` (`usage`),
/// `turn.failed` and `error`. Codex sends the agent's message whole, at
/// `item.completed`.
public struct CodexEventParser: CLIEventParser {
    var messages = 0
    public init() {}

    public mutating func parse(_ line: String) throws -> [ChatEvent] {
        guard let o = JSON.object(line) else { return [] }
        switch o["type"] as? String {
        case "item.started":
            guard let item = o["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "command_execution": return [.activity("Running \((item["command"] as? String) ?? "a command")")]
            case "file_change": return [.activity("Codex tried to change files; the read-only sandbox blocks it.")]
            case "web_search": return [.activity("Searching the web")]
            default: return []
            }
        case "item.completed":
            guard let item = o["item"] as? [String: Any], (item["type"] as? String) == "agent_message",
                  let t = item["text"] as? String, !t.isEmpty else { return [] }
            messages += 1
            return [.text(messages > 1 ? "\n\n" + t : t)]
        case "turn.completed":
            let u = o["usage"] as? [String: Any]
            return [.finished(u.map { TokenUsage(inputTokens: JSON.int($0["input_tokens"]), outputTokens: JSON.int($0["output_tokens"])) })]
        case "turn.failed":
            let e = o["error"] as? [String: Any]
            throw AssistantError.tool(name: "Codex", message: (e?["message"] as? String) ?? "the turn failed")
        case "error":
            throw AssistantError.tool(name: "Codex", message: (o["message"] as? String) ?? ((o["error"] as? [String: Any])?["message"] as? String) ?? "error")
        default:
            return []
        }
    }

    public mutating func finish() -> [ChatEvent] { [] }
}

/// Antigravity CLI `--output-format stream-json` (Antigravity's headless
/// mode): `init`, then `step_update` events (`step_type`, `state`,
/// `text_delta`, `tool_name`), then one `result` (`status`, `response`,
/// `error`, `usage`).
public struct AntigravityEventParser: CLIEventParser {
    var sawText = false
    public init() {}

    public mutating func parse(_ line: String) throws -> [ChatEvent] {
        guard let o = JSON.object(line) else { return [] }
        switch o["event"] as? String {
        case "step_update":
            guard let s = o["step_update"] as? [String: Any] else { return [] }
            if let t = s["text_delta"] as? String, !t.isEmpty, (s["step_type"] as? String).map({ $0 != "user_input" }) ?? true {
                sawText = true
                return [.text(t)]
            }
            if (s["step_type"] as? String) == "tool", (s["state"] as? String) == "ACTIVE", let name = s["tool_name"] as? String {
                return [.activity(name)]
            }
            return []
        case "result":
            let r = (o["result"] as? [String: Any]) ?? [:]
            let status = (r["status"] as? String) ?? "SUCCESS"
            guard status == "SUCCESS" else {
                let e = (r["error"] as? String) ?? ((r["error"] as? [String: Any])?["message"] as? String) ?? status.lowercased()
                throw AssistantError.tool(name: "Antigravity", message: e)
            }
            var out: [ChatEvent] = []
            if !sawText, let t = r["response"] as? String, !t.isEmpty { out.append(.text(t)) }
            let u = r["usage"] as? [String: Any]
            out.append(.finished(u.map { TokenUsage(inputTokens: JSON.int($0["input_tokens"]), outputTokens: JSON.int($0["output_tokens"])) }))
            return out
        default:
            return []
        }
    }

    public mutating func finish() -> [ChatEvent] { [] }
}

/// Finds command-line tools on the search path and in the usual install
/// folders (a GUI app's PATH is minimal, so the usual folders matter).
public struct CLIToolLocator: Sendable {
    public var searchPath: [String]
    public var home: String
    public var isExecutable: @Sendable (String) -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        self.home = home
        self.isExecutable = isExecutable
    }

    /// Folders checked after PATH, in order.
    public func usualFolders() -> [String] {
        var f = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin", "\(home)/.npm-global/bin",
                 "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.claude/local", "\(home)/.codex/bin", "\(home)/.antigravity/bin",
                 "/usr/bin"]
        // nvm installs: newest Node version first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            f += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        return f
    }

    public func find(_ name: String, override: String? = nil) -> URL? {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let p = (o as NSString).expandingTildeInPath
            return isExecutable(p) ? URL(fileURLWithPath: p) : nil
        }
        var seen = Set<String>()
        for dir in searchPath + usualFolders() where seen.insert(dir).inserted {
            let p = (dir as NSString).appendingPathComponent(name)
            if isExecutable(p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}

/// An agent tool as a provider: one subprocess per request.
public struct CLIAgentProvider: AssistantProvider {
    public let agent: CLIAgentKind
    public var kind: ProviderKind { agent.providerKind }
    /// The located executable (nil: not installed).
    public var executable: URL?
    /// Arguments that replace the documented ones (tests).
    public var argumentsOverride: [String]?

    public init(agent: CLIAgentKind, executable: URL?, argumentsOverride: [String]? = nil) {
        self.agent = agent
        self.executable = executable
        self.argumentsOverride = argumentsOverride
    }

    public func availability() async -> ProviderAvailability {
        guard executable != nil else { return .notInstalled(hint: "\(agent.displayName) was not found. " + agent.installHint) }
        return .ready([ModelInfo(id: "", displayName: "Default")] + agent.suggestedModels.map { ModelInfo(id: $0) })
    }

    /// The child's environment: this process's, with the tool's own folder
    /// first on PATH (tools installed with Node need `node` beside them).
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let dir = executable?.deletingLastPathComponent().path {
            env["PATH"] = ([dir] + (env["PATH"].map { [$0] } ?? ["/usr/bin:/bin"])).joined(separator: ":")
        }
        env["NO_COLOR"] = "1"
        return env
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let provider = self
        return eventStream { out in
            guard let exe = provider.executable else {
                throw AssistantError.tool(name: provider.agent.displayName, message: "not installed. " + provider.agent.installHint)
            }
            let dir = request.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let prompt = request.flattenedPrompt
            let args = provider.argumentsOverride ?? provider.agent.arguments(model: request.model, workingDirectory: dir.path, prompt: prompt)
            var parser = provider.agent.makeParser()
            var finished = false
            do {
                for try await line in StreamingSubprocess.lines(exe, args, environment: provider.environment(), currentDirectory: dir,
                                                                input: provider.agent.promptOnStandardInput ? Data(prompt.utf8) : nil) {
                    for e in try parser.parse(line) {
                        out.yield(e)
                        if case .finished = e { finished = true }
                    }
                }
            } catch let e as StreamingSubprocess.ExitError {
                if e.wasInterrupted { throw CancellationError() }
                throw AssistantError.tool(name: provider.agent.displayName, message: Self.explain(e))
            }
            try Task.checkCancellation()
            for e in parser.finish() { out.yield(e) }
            if !finished { out.yield(.finished(nil)) }
        }
    }

    /// The exit message, with the usual cause spelled out.
    static func explain(_ e: StreamingSubprocess.ExitError) -> String {
        let tail = e.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = tail.lowercased()
        if lower.contains("login") || lower.contains("log in") || lower.contains("sign in") || lower.contains("authenticat") {
            return "it needs you to sign in. Run it once in Terminal to sign in, then try again. (\(tail.suffix(300)))"
        }
        return tail.isEmpty ? "exit status \(e.status)" : String(tail.suffix(600))
    }
}
