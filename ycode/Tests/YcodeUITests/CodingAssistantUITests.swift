import AppKit
import Foundation
import Testing
import YcodeAssistant
@testable import YcodeUI

/// A scripted back end: answers with `reply` (in pieces), or keeps
/// streaming until cancelled when `endless`.
final class FakeProvider: AssistantProvider, @unchecked Sendable {
    let kind: ProviderKind
    let state: ProviderAvailability
    var reply: String
    var endless = false
    private let lock = NSLock()
    private var received: [ChatRequest] = []
    var requests: [ChatRequest] { lock.lock(); defer { lock.unlock() }; return received }

    init(_ kind: ProviderKind, _ state: ProviderAvailability, reply: String = "") {
        self.kind = kind
        self.state = state
        self.reply = reply
    }

    func availability() async -> ProviderAvailability { state }

    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock(); received.append(request); lock.unlock()
        let reply = reply, endless = endless
        return AsyncThrowingStream { c in
            let t = Task {
                if endless {
                    while !Task.isCancelled {
                        c.yield(.text("."))
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    c.finish(throwing: CancellationError())
                    return
                }
                c.yield(.activity("Reading"))
                for piece in reply.split(separator: " ", omittingEmptySubsequences: false).enumerated().map({ $0.offset == 0 ? String($0.element) : " " + $0.element }) {
                    c.yield(.text(piece))
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                c.yield(.finished(TokenUsage(inputTokens: 1, outputTokens: 1)))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

@MainActor
@Suite(.serialized) struct CodingAssistantUITests {
    @MainActor final class Env {
        let dir: URL
        let defaults: TestDefaults
        let prefs: Preferences
        let savedServices: CodingAssistantServices
        var fakes: [ProviderKind: FakeProvider] = [:]
        let store = MemorySecretStore()

        init(_ tag: String, ready: [ProviderKind] = [.ollama], reply: String = "Hello there") throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-assist-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
            let src = dir.appendingPathComponent("Sources/Demo")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\")])\n"
                .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "struct Model {\n    var value = 1\n}\n".write(to: src.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
            try "import SwiftUI\nstruct V: View { var body: some View { Text(\"x\") } }\n".write(to: src.appendingPathComponent("V.swift"), atomically: true, encoding: .utf8)
            defaults = TestDefaults("assist-\(tag)")
            savedServices = CodingAssistantServices.shared
            // Not Preferences.shared: other suites run meanwhile and use it.
            prefs = Preferences(defaults: defaults.defaults)
            for k in ProviderKind.allCases {
                fakes[k] = FakeProvider(k, ready.contains(k) ? .ready([ModelInfo(id: "\(k.rawValue)-model", contextWindow: 8192)])
                                                            : .notRunning(hint: "\(k.displayName) is not running."), reply: reply)
            }
            let services = CodingAssistantServices(store: store) { _ in false }
            let fakes = self.fakes
            services.providerOverride = { fakes[$0] }
            services.preferences = prefs
            CodingAssistantServices.shared = services
        }

        func restore() {
            CodingAssistantServices.shared = savedServices
            defaults.remove()
            try? FileManager.default.removeItem(at: dir)
        }

        var modelURL: URL { dir.appendingPathComponent("Sources/Demo/Model.swift") }

        func window() throws -> WorkspaceWindowController {
            _ = NSApplication.shared
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                               startLanguageService: false, openFirstFile: false)
            wc.applyDefaultLayout()
            return wc
        }
    }

    func item(_ action: String) -> NSMenuItem { NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "") }

    @Test func commandZeroShowsThePaneWithTheBackEnds() async throws {
        let env = try Env("pane", ready: [.ollama, .codex])
        defer { env.restore() }
        let wc = try env.window()
        wc.showCodingAssistant(nil)
        #expect(wc.navigator.showsCodingAssistant && !wc.navigator.assistantContainer.isHidden)
        #expect(wc.leftPanesControl.isSelected(forSegment: 1))
        let pane = wc.codingAssistant
        #expect(pane.view.superview === wc.navigator.assistantContainer)
        await pane.model.refreshAvailability().value
        #expect(pane.model.readyProviders == [.ollama, .codex])
        #expect(pane.model.sourceLabel == "Ollama · ollama-model")
        #expect(pane.modelChoiceTitles.contains("Ollama/ollama-model") && pane.modelChoiceTitles.contains("Codex/codex-model"))
        #expect(pane.statusText == nil)
        // Choosing a back end that is not running explains it and offers the ready ones.
        pane.model.choose(.llamaCpp, model: nil)
        #expect(pane.statusText?.contains("llama.cpp is not running.") == true)
        let titles: [String] = pane.statusButtons.arrangedSubviews.compactMap { v in (v as? NSButton).map(\.title) }
        #expect(titles.contains("Use Ollama"))
        #expect(pane.planLabel.isHidden)
        pane.model.choose(.openAI, model: nil)
        #expect(!pane.planLabel.isHidden)
    }

    @Test func noBackEndShowsTheEmptyState() async throws {
        let env = try Env("empty", ready: [])
        defer { env.restore() }
        let wc = try env.window()
        wc.showCodingAssistant(nil)
        let pane = wc.codingAssistant
        await pane.model.refreshAvailability().value
        #expect(!pane.model.hasUsableBackend)
        #expect(pane.statusText == AssistantBackends.noBackendText)
        // Sending anyway explains instead of calling a server.
        let id = try #require(pane.model.send("Hi"))
        #expect(pane.model.conversation(id)?.messages.last?.error == "No Ollama model is available. Ollama is not running.")
        #expect(env.fakes[.ollama]?.requests.isEmpty == true)
        #expect(AssistantBackends.noBackendText.contains("ollama pull") && AssistantBackends.noBackendText.contains("Claude Code, Codex"))
    }

    @Test func sendStreamsAResponseWithTheEditorContext() async throws {
        let env = try Env("send", reply: "It holds a value.")
        defer { env.restore() }
        let wc = try env.window()
        wc.open(path: env.modelURL.path, line: nil)
        wc.newConversation(nil)
        let pane = wc.codingAssistant
        #expect(wc.shownLeftPane == .codingAssistant)
        await pane.model.refreshAvailability().value
        pane.messageView.string = "What is Model?"
        pane.sendClicked()
        #expect(pane.sendButton.title == "Stop")
        let id = try #require(pane.model.selectedID)
        await pane.model.response(id)?.value
        let c = try #require(pane.model.selected)
        #expect(c.title == "What is Model?")
        #expect(c.messages.map(\.role) == [.user, .assistant])
        #expect(c.messages[1].text == "It holds a value." && c.messages[1].error == nil && c.messages[1].isComplete)
        #expect(c.messages[1].activity == ["Reading"])
        #expect(c.messages[1].source == "Ollama · ollama-model")
        #expect(pane.messageViews.count == 2)
        #expect(pane.sendButton.title == "Send" && pane.messageView.string.isEmpty)
        let request = try #require(env.fakes[.ollama]?.requests.last)
        #expect(request.model == "ollama-model")
        #expect(request.contextTokens == 8192)
        #expect(request.workingDirectory?.path == env.dir.path)
        #expect(request.messages.last?.content.contains("Current file Sources/Demo/Model.swift") == true)
        #expect(request.messages.last?.content.hasSuffix("What is Model?") == true)
        // A follow-up carries the earlier turn.
        pane.messageView.string = "And value?"
        pane.sendClicked()
        await pane.model.response(id)?.value
        #expect(env.fakes[.ollama]?.requests.last?.messages.map(\.role) == [.user, .assistant, .user])
    }

    @Test func stopAndJumpToActiveConversation() async throws {
        let env = try Env("stop")
        defer { env.restore() }
        env.fakes[.ollama]?.endless = true
        let wc = try env.window()
        let pane = wc.codingAssistant
        await pane.model.refreshAvailability().value
        #expect(!wc.validateMenuItem(item("jumpToNextActiveConversation:")))
        let first = try #require(pane.model.send("Keep going"))
        pane.model.newConversation()
        #expect(pane.model.selectedID != first)
        #expect(wc.validateMenuItem(item("jumpToNextActiveConversation:")))
        wc.jumpToNextActiveConversation(nil)
        #expect(pane.model.selectedID == first)
        #expect(pane.sendButton.title == "Stop")
        let running = pane.model.response(first)
        // Stop only once the endless stand-in has streamed something, so the
        // kept partial text below is not a race with the first chunk.
        #expect(await waitUntil(10) { !(pane.model.conversation(first)?.messages.last?.text.isEmpty ?? true) })
        pane.sendClicked()   // Stop
        await running?.value
        #expect(pane.model.conversation(first)?.messages.last?.error == "Stopped.")
        #expect(pane.model.conversation(first)?.messages.last?.text.hasPrefix(".") == true)
        #expect(!wc.validateMenuItem(item("jumpToNextActiveConversation:")))
    }

    @Test func menuEnablement() throws {
        let env = try Env("menus")
        defer { env.restore() }
        let wc = try env.window()
        #expect(wc.validateMenuItem(item("newConversation:")))
        for a in ["codingToolExplain:", "codingToolDocument:", "codingToolGeneratePlayground:", "codingToolGeneratePreview:"] {
            #expect(!wc.validateMenuItem(item(a)), "\(a) without a file")
        }
        wc.open(path: env.modelURL.path, line: nil)
        #expect(wc.validateMenuItem(item("codingToolExplain:")) && wc.validateMenuItem(item("codingToolDocument:")))
        #expect(wc.validateMenuItem(item("codingToolGeneratePlayground:")))
        #expect(!wc.validateMenuItem(item("codingToolGeneratePreview:")))
        wc.open(path: env.dir.appendingPathComponent("Sources/Demo/V.swift").path, line: nil)
        #expect(wc.validateMenuItem(item("codingToolGeneratePreview:")))
        // The menu bar entries send these actions.
        let file = CommandTable.menus.first { $0.0 == "File" }!.1
        guard case .submenu(_, let new)? = file.first, case .command(let conversation)? = new.first else { Issue.record("File ▸ New"); return }
        #expect(conversation.title == "Conversation" && conversation.action == "newConversation:" && conversation.isAvailable)
    }

    /// Document on a selection: a proposal for the selection, reviewed in
    /// the comparison view and applied to the open document only on Accept.
    @Test func documentProposalIsReviewedThenApplied() async throws {
        let env = try Env("document", reply: "Here:\n```swift selection\n/// A model.\nstruct Model {\n    var value = 1\n}\n```")
        defer { env.restore() }
        let wc = try env.window()
        wc.open(path: env.modelURL.path, line: nil)
        let original = wc.editor.text
        wc.editor.textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        let pane = wc.codingAssistant
        await pane.model.refreshAvailability().value
        let id = try #require(wc.runCodingTool(.document))
        await pane.model.response(id)?.value
        let c = try #require(pane.model.conversation(id))
        #expect(c.title == "Document Model.swift:1–3")
        #expect(c.messages[0].attachments.first?.kind == .selection)
        #expect(env.fakes[.ollama]?.requests.last?.messages.last?.content.contains("selection") == true)
        let reply = c.messages[1]
        let proposals = ChangeProposal.parse(reply.text, target: reply.target)
        #expect(proposals.count == 1)
        let proposal = try #require(proposals.first)
        #expect(proposal.kind == .replaceSelection)
        #expect(pane.messageViews.last?.reviewButtons.count == 1)

        // Reject: nothing changes.
        let rejected = try #require(wc.reviewProposal(proposal, message: reply, conversation: id))
        _ = rejected.view
        #expect(rejected.headline == "Change Model.swift: +1 −0 lines")
        #expect(rejected.comparison.rows.contains { $0.kind == .added && $0.right?.text == "/// A model." })
        rejected.reject()
        #expect(wc.editor.text == original)
        #expect(pane.model.conversation(id)?.messages[1].resolvedProposals[0] == .rejected)

        // Accept: the open document changes as one undoable edit; the file on disk does not.
        let accepted = try #require(wc.reviewProposal(proposal, message: reply, conversation: id))
        accepted.accept()
        #expect(wc.editor.text == "/// A model.\n" + original)
        #expect(wc.editor.isDirty)
        #expect(try String(contentsOf: env.modelURL, encoding: .utf8) == original)
        #expect(pane.model.conversation(id)?.messages[1].resolvedProposals[0] == .accepted)
        wc.editor.textView.undoManager?.undo()
        #expect(wc.editor.text == original)
    }

    @Test func newFileProposalAndPathsOutsideTheWorkspace() async throws {
        let env = try Env("newfile")
        defer { env.restore() }
        let wc = try env.window()
        let pane = wc.codingAssistant
        let message = ConversationMessage(role: .assistant, text: "")
        let c = pane.model.newConversation()
        let create = ChangeProposal(kind: .wholeFile, path: "Sources/Demo/Extra.swift", language: "swift", text: "let extra = 1", blockIndex: 0)
        let review = try #require(wc.reviewProposal(create, message: message, conversation: c.id))
        _ = review.view
        #expect(review.original == nil && review.acceptButton.title == "Create File")
        #expect(!FileManager.default.fileExists(atPath: env.dir.appendingPathComponent("Sources/Demo/Extra.swift").path))
        review.accept()
        #expect(try String(contentsOf: env.dir.appendingPathComponent("Sources/Demo/Extra.swift"), encoding: .utf8) == "let extra = 1\n")
        #expect(wc.editor.fileURL?.lastPathComponent == "Extra.swift")
        let escape = ChangeProposal(kind: .wholeFile, path: "Sources/../../outside.swift", language: nil, text: "x", blockIndex: 0)
        #expect(wc.reviewProposal(escape, message: message, conversation: c.id) == nil)
    }

    @Test func settingsPaneKeepsSecretsOutOfDefaults() throws {
        let env = try Env("settings")
        defer { env.restore() }
        let pane = CodingAssistantSettingsPane(prefs: env.prefs, services: CodingAssistantServices.shared)
        _ = pane.view
        for t in ["# Model Provider", "Use", "# Local Models", "Ollama address", "llama.cpp address", "# OpenAI", "Sign-in method", "Account",
                  "# Agent Tools", "Claude Code", "Codex", "Antigravity", "# Context", "Context limit (tokens)", "# Privacy"] {
            #expect(pane.rowTitles.contains(t), "missing row \(t)")
        }
        pane.choose("API key", inRow: "Sign-in method")
        #expect(env.prefs.codingAssistant.openAIAuth == .apiKey)
        #expect(pane.rowTitles.contains("API key") && !pane.rowTitles.contains("Account"))
        // Enter and save a key: it goes to the secret store only.
        let row = try #require(pane.control(NSSecureTextField.self, inRow: "API key"))
        row.stringValue = "sk-test-not-real"
        let save = try #require((row.superview as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Save" })
        save.performClick(nil)
        #expect(env.store.readString(SecretAccount.openAIKey) == "sk-test-not-real")
        let everything = env.prefs.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!everything.contains("sk-test-not-real"))
        if let d = env.prefs.defaults.data(forKey: "Ycode.codingAssistant") {
            #expect(!String(decoding: d, as: UTF8.self).contains("sk-test"))
        }
        pane.choose("Codex", inRow: "Use")
        #expect(env.prefs.codingAssistant.provider == .codex)
        #expect(CodingAssistantSettingsPane.privacyText.contains("not in the workspace"))
    }
}

/// Renders the Coding Assistant pane with a short conversation to a PNG
/// (opt-in: `YCODE_ASSISTANT_SNAPSHOT=<path.png>`), for checking the layout
/// without driving the screen.
@MainActor
@Suite(.serialized) struct CodingAssistantSnapshotTests {
    nonisolated static let path = ProcessInfo.processInfo.environment["YCODE_ASSISTANT_SNAPSHOT"]

    @Test(.enabled(if: path != nil)) func renderPane() async throws {
        let env = try CodingAssistantUITests.Env("snapshot", ready: [.ollama, .claudeCode],
                                                 reply: "`Model` stores one **value**. Here is a documented version:\n\n```swift selection\n/// A model.\nstruct Model {\n    /// The value.\n    var value = 1\n}\n```\n\nAccept it to apply.")
        defer { env.restore() }
        let wc = try env.window()
        wc.open(path: env.modelURL.path, line: nil)
        wc.editor.textView.setSelectedRange(NSRange(location: 0, length: (wc.editor.text as NSString).length))
        wc.showCodingAssistant(nil)
        let pane = wc.codingAssistant
        await pane.model.refreshAvailability().value
        let id = try #require(wc.runCodingTool(.document))
        await pane.model.response(id)?.value
        pane.attach(Attachment(kind: .file, path: "Sources/Demo/Model.swift", text: ""))
        let window = try #require(wc.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = wc.navigator.view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: Self.path!))
    }
}
