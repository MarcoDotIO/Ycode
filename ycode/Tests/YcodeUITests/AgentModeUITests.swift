import AppKit
import Foundation
import Testing
import YcodeAssistant
@testable import YcodeIDECore
import YcodeMCP
@testable import YcodeUI

/// An agent back end that works like Claude Code in agent mode: it calls
/// the attached Ycode MCP server over HTTP (file_edit), asks for a
/// permission and reports what it got.
final class FakeAgent: AgentAttachable, @unchecked Sendable {
    var kind: ProviderKind { .claudeCode }
    let attachment: AgentAttachment?
    init(_ attachment: AgentAttachment? = nil) { self.attachment = attachment }
    var isAttached: Bool { attachment != nil }
    func availability() async -> ProviderAvailability { .ready([ModelInfo(id: "", displayName: "Default")]) }
    func attaching(_ attachment: AgentAttachment) -> AssistantProvider { FakeAgent(attachment) }

    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let a = attachment
        return AsyncThrowingStream { c in
            let t = Task {
                guard let a, let mcp = a.mcp else {
                    c.yield(.text("no attachment; instructions: \(request.instructions.prefix(40))"))
                    c.finish()
                    return
                }
                var r = URLRequest(url: URL(string: mcp.url)!, timeoutInterval: 120)
                r.httpMethod = "POST"
                r.setValue("Bearer \(mcp.token)", forHTTPHeaderField: "Authorization")
                r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                r.httpBody = AnyJSON.object(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                    "name": "file_edit", "arguments": ["path": "Sources/Demo/Model.swift", "oldText": "var value = 1", "newText": "var value = 2"],
                ]]).data()
                do {
                    let (data, _) = try await URLSession.shared.data(for: r)
                    let reply = try AnyJSON.parse(data)
                    let text = (reply["result"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.first ?? "?"
                    c.yield(.text("edit: \(text)\n"))
                } catch {
                    c.yield(.text("edit failed: \(error)\n"))
                }
                let choice = await a.requestPermission("Run the tests", [.init(id: "yes", name: "Allow", kind: "allow_once"),
                                                                        .init(id: "no", name: "Reject", kind: "reject_once")])
                c.yield(.text("permission: \(choice ?? "cancelled")"))
                c.yield(.finished(nil))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

@MainActor
@Suite(.serialized) struct AgentModeUITests {
    func setUp(_ tag: String) throws -> (CodingAssistantUITests.Env, WorkspaceWindowController) {
        let env = try CodingAssistantUITests.Env(tag, ready: [.claudeCode])
        let fakes = env.fakes
        CodingAssistantServices.shared.providerOverride = { k -> AssistantProvider? in k == .claudeCode ? FakeAgent() : fakes[k] }
        let wc = try env.window()
        return (env, wc)
    }

    func waitForProposal(_ model: CodingAssistantModel) async throws {
        for _ in 0..<400 where model.pendingAgentChangeCount == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(model.pendingAgentChangeCount == 1)
    }

    @Test func anAgentsEditIsAProposalAndTheToolAnswersAfterTheReview() async throws {
        let (env, wc) = try setUp("agent-accept")
        defer { env.restore() }
        let model = wc.codingAssistant.model
        await model.refreshAvailability().value
        model.choose(.claudeCode, model: nil)
        wc.agentPermissionResponder = { title, options in title == "Run the tests" ? options.first { $0.allows }?.id : nil }
        let id = try #require(model.send("Change the value to 2"))
        try await waitForProposal(model)
        #expect(wc.agentEndpoints[id]?.hasPrefix("http://127.0.0.1:") == true)
        let message = try #require(model.conversation(id)?.messages.last)
        #expect(message.activity.contains { $0.hasPrefix("Agent mode:") })
        let proposals = ChangeProposal.parse(message.text, target: nil)
        #expect(proposals.count == 1 && proposals.first?.path == "Sources/Demo/Model.swift")
        // The file is untouched until the review.
        #expect(try String(contentsOf: env.modelURL, encoding: .utf8).contains("var value = 1"))
        let review = try #require(wc.reviewProposal(proposals[0], message: message, conversation: id))
        review.accept()
        await model.response(id)?.value
        let done = try #require(model.conversation(id)?.messages.last)
        #expect(done.text.contains("edit: Edited Sources/Demo/Model.swift."), "\(done.text)")
        #expect(done.text.contains("permission: yes"))
        #expect(done.resolvedProposals[proposals[0].blockIndex] == .accepted)
        #expect(try String(contentsOf: env.modelURL, encoding: .utf8) == "struct Model {\n    var value = 2\n}\n")
        // The agent got Ycode's agent instructions; its endpoint is gone.
        #expect(wc.agentEndpoints.isEmpty && model.pendingAgentChangeCount == 0)
    }

    @Test func aRejectedEditChangesNothing() async throws {
        let (env, wc) = try setUp("agent-reject")
        defer { env.restore() }
        let model = wc.codingAssistant.model
        await model.refreshAvailability().value
        model.choose(.claudeCode, model: nil)
        wc.agentPermissionResponder = { _, _ in nil }
        let id = try #require(model.send("Change the value"))
        try await waitForProposal(model)
        let message = try #require(model.conversation(id)?.messages.last)
        let p = try #require(ChangeProposal.parse(message.text, target: nil).first)
        try #require(wc.reviewProposal(p, message: message, conversation: id)).reject()
        await model.response(id)?.value
        let done = try #require(model.conversation(id)?.messages.last)
        #expect(done.text.contains("edit: The change was rejected in Ycode's review"), "\(done.text)")
        #expect(done.text.contains("permission: cancelled"))
        #expect(try String(contentsOf: env.modelURL, encoding: .utf8).contains("var value = 1"))
    }

    @Test func agentModeOffSendsTheReadOnlyRequest() async throws {
        let (env, wc) = try setUp("agent-off")
        defer { env.restore() }
        let model = wc.codingAssistant.model
        var s = model.prefs.codingAssistant
        s.agentMode = false
        model.prefs.codingAssistant = s
        await model.refreshAvailability().value
        model.choose(.claudeCode, model: nil)
        let id = try #require(model.send("Hi"))
        await model.response(id)?.value
        #expect(model.conversation(id)?.messages.last?.text.hasPrefix("no attachment; instructions: You are the coding assistant") == true)
    }

    @Test func theSkillAndTheSettingsRows() throws {
        let (env, wc) = try setUp("agent-skill")
        defer { env.restore() }
        wc.installYcodeSkill(nil)
        for p in AgentSkill.paths {
            let text = try String(contentsOf: env.dir.appendingPathComponent(p), encoding: .utf8)
            #expect(text.hasPrefix("---\nname: ycode\n") && text.contains("`file_edit` (writes)") && text.contains("`simulator_screenshot`"))
        }
        #expect(CodingAssistantSettingsPane.mcpCommandLine().hasSuffix(" mcp"))
        // The IDE's tools use the window's own session.
        #expect(wc.mcpHost.session === wc.session && wc.mcpHost.server.tools.count == 29)
        #expect(wc.mcpHostText(ofOpenFile: env.modelURL.path) == nil)
    }
}
