import Foundation

/// An external ACP agent as a coding-assistant back end: one agent process
/// and one session per request (like the agent tools, nothing is kept).
/// The agent's messages stream as text; its thoughts, tool calls and plans
/// show as activity lines; its file reads and writes go through Ycode
/// (writes become proposals the user reviews) and its permission requests
/// are asked in the IDE. Without an attachment it may read files in the
/// workspace only. See specs/ide/coding-assistant.md, "Ycode implementation".
public struct ACPAgentProvider: AgentAttachable {
    public var kind: ProviderKind { .acpAgent }
    /// The located executable (nil: not set up or not found).
    public var executable: URL?
    public var arguments: [String]
    public var attachment: AgentAttachment?

    public init(executable: URL?, arguments: [String], attachment: AgentAttachment? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.attachment = attachment
    }

    /// The provider for a command line typed in Settings ("gemini
    /// --experimental-acp"): its first word found like the agent tools.
    public init(command: String, locator: CLIToolLocator) {
        let words = CommandLineWords.split(command)
        executable = words.first.flatMap { locator.find(($0 as NSString).lastPathComponent, override: $0.contains("/") ? $0 : nil) }
        arguments = Array(words.dropFirst())
    }

    public static let setupHint = "Set an ACP agent's command in Settings ▸ Coding Assistant ▸ ACP Agent (for example an agent CLI started in its ACP mode); sign in to it once in Terminal."

    public func availability() async -> ProviderAvailability {
        guard executable != nil else { return .notInstalled(hint: Self.setupHint) }
        return .ready([ModelInfo(id: "", displayName: "Default")])
    }

    public var isAttached: Bool { attachment != nil }

    public func attaching(_ attachment: AgentAttachment) -> AssistantProvider {
        var p = self
        p.attachment = attachment
        return p
    }

    /// The client handlers: through the attachment, inside `root`.
    func handlers(root: URL) -> ACPClientHandlers {
        guard let a = attachment else { return .readOnly(root: root) }
        return ACPClientHandlers(readTextFile: { path in
            guard ACPConnection.isInside(path, root: root) else { throw JSONRPCError.invalidParams("\(path) is outside the workspace") }
            guard let t = await a.readFile(path) else { throw JSONRPCError(code: -32002, message: "cannot read \(path)") }
            return t
        }, writeTextFile: { path, content in
            guard ACPConnection.isInside(path, root: root) else { throw JSONRPCError.invalidParams("\(path) is outside the workspace") }
            let original = await a.readFile(path)
            return await a.proposeChange(path, original, content, original == nil ? "Create \((path as NSString).lastPathComponent)" : "Change \((path as NSString).lastPathComponent)")
        }, requestPermission: { call, options in
            await a.requestPermission(call.title ?? "The agent asks for permission", options)
        })
    }

    public func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let provider = self
        return eventStream { out in
            guard let exe = provider.executable else { throw AssistantError.tool(name: "ACP agent", message: Self.setupHint) }
            let dir = request.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let connection = try ACPConnection(executable: exe, arguments: provider.arguments, currentDirectory: dir,
                                               handlers: provider.handlers(root: dir))
            defer { connection.close() }
            do {
                try await connection.initialize()
                let session = try await connection.newSession(cwd: dir, mcp: provider.attachment?.mcp.map { [$0] } ?? [])
                var thinking = ""
                for try await e in connection.prompt(session: session, text: request.flattenedPrompt) {
                    for c in Self.chatEvents(e, thinking: &thinking) { out.yield(c) }
                    if case .stopped(let reason) = e {
                        switch reason {
                        case "cancelled": throw CancellationError()
                        case "refusal": throw AssistantError.tool(name: "ACP agent", message: "the agent refused the request")
                        default: break
                        }
                    }
                }
            } catch let e as JSONRPCError {
                let tail = connection.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AssistantError.tool(name: "ACP agent", message: e.message + (tail.isEmpty ? "" : " (\(tail.suffix(400)))"))
            }
            try Task.checkCancellation()
            out.yield(.finished(nil))
        }
    }

    /// Chat events for one ACP event. Thoughts are shown once per
    /// paragraph; tool calls by title and state; plans as a checklist.
    static func chatEvents(_ e: ACPEvent, thinking: inout String) -> [ChatEvent] {
        switch e {
        case .message(let t): return [.text(t)]
        case .thought(let t):
            thinking += t
            guard thinking.contains("\n\n") || thinking.count > 240 else { return [] }
            defer { thinking = "" }
            return [.activity("Thinking: " + thinking.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))]
        case .toolCall(let c):
            let state: String = switch c.status { case "completed": " ✓"; case "failed": " ✗"; case "in_progress": "…"; default: "" }
            return [.activity((c.title ?? c.kind ?? "Tool") + (c.locations.first.map { " (\($0))" } ?? "") + state)]
        case .plan(let entries):
            let marks = entries.map { ($0.status == "completed" ? "☑ " : ($0.status == "in_progress" ? "▸ " : "☐ ")) + $0.content }
            return [.activity("Plan: " + marks.joined(separator: "; "))]
        case .mode(let m): return [.activity("Mode: \(m)")]
        case .notice(let n): return n.isEmpty ? [] : [.activity(n)]
        case .stopped: return []
        }
    }
}

/// Splits a command line into words like a shell (quotes group, no expansion).
public enum CommandLineWords {
    public static func split(_ s: String) -> [String] {
        var words: [String] = []
        var cur = "", quote: Character?, any = false
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                any = true
            } else if c == " " || c == "\t" {
                if any || !cur.isEmpty { words.append(cur); cur = ""; any = false }
            } else {
                cur.append(c)
            }
        }
        if any || !cur.isEmpty { words.append(cur) }
        return words
    }
}
