import Foundation
import Testing
@testable import YcodeAssistant

/// Opt-in checks against real back ends on the developer's machine. They
/// are off unless `YCODE_LIVE_ASSISTANT` names them (comma-separated:
/// `ollama`, `claude`, `codex`, `agy`). Each sends one short prompt; the
/// agent tools run read-only in an empty temporary folder, Claude Code with
/// no tools at all. They use the tools' own sign-ins and never read them.
@Suite struct LiveSmokeTests {
    static let enabled = Set((ProcessInfo.processInfo.environment["YCODE_LIVE_ASSISTANT"] ?? "").split(separator: ",").map(String.init))
    static let prompt = "Reply with exactly one word: pong"

    func run(_ provider: AssistantProvider, model: String?, timeout: TimeInterval = 180) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let request = ChatRequest(model: model, instructions: "You are a test probe. Do not use tools.", messages: [ChatMessage(.user, Self.prompt)],
                                  contextTokens: 4096, workingDirectory: dir)
        let task = Task { try await collect(provider.send(request)) }
        let watchdog = Task { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); task.cancel() }
        defer { watchdog.cancel() }
        let r = try await task.value
        print("LIVE \(provider.kind.displayName): \(r.events)")
        return r.text
    }

    @Test(.enabled(if: enabled.contains("ollama"))) func ollama() async throws {
        let p = OllamaProvider()
        let a = await p.availability()
        let model = try #require(a.models.first { $0.id.hasPrefix("qwen2.5-coder") }?.id)
        print("LIVE Ollama context window:", await p.contextWindow(model: model) as Any)
        let text = try await run(p, model: model)
        #expect(text.lowercased().contains("pong"))
    }

    func cli(_ agent: CLIAgentKind) async throws {
        let exe = try #require(CLIToolLocator().find(agent.executableName))
        var args: [String]?
        if agent == .claudeCode {
            args = agent.arguments(model: nil, workingDirectory: "", prompt: "", toolsEnabled: false)
        }
        let text = try await run(CLIAgentProvider(agent: agent, executable: exe, argumentsOverride: args), model: nil)
        #expect(text.lowercased().contains("pong"))
    }

    @Test(.enabled(if: enabled.contains("claude"))) func claudeCode() async throws { try await cli(.claudeCode) }
    @Test(.enabled(if: enabled.contains("codex"))) func codex() async throws { try await cli(.codex) }
    @Test(.enabled(if: enabled.contains("agy"))) func antigravity() async throws { try await cli(.antigravity) }
}
