import Foundation
import Testing
import YcodeAssistant
import YcodeBuild
import YcodeEditorKit
import YcodeIDECore
@testable import YcodeIDEShell

/// A stand-in model server speaking the OpenAI-compatible API llama-server
/// serves (`/v1/models`, `/props`, `/v1/chat/completions` as server-sent
/// events), run from the test on 127.0.0.1. It answers every chat with
/// `reply`, a few characters per event, and records the requests.
final class StandInModelServer: @unchecked Sendable {
    /// The chat request bodies received.
    final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Data] = []
        func add(_ d: Data) { lock.lock(); items.append(d); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return items }
    }

    let server: LoopbackServer
    let bodies = Bodies()

    init(reply: String, model: String = "standin-coder") throws {
        let chunks = stride(from: 0, to: reply.count, by: 7).map { i -> String in
            let start = reply.index(reply.startIndex, offsetBy: i)
            return String(reply[start..<(reply.index(start, offsetBy: 7, limitedBy: reply.endIndex) ?? reply.endIndex)])
        }
        let events = [["choices": [["index": 0, "delta": ["role": "assistant"]]]]]
            + chunks.map { ["choices": [["index": 0, "delta": ["content": $0]]]] }
            + [["choices": [["index": 0, "delta": [String: String](), "finish_reason": "stop"]]]]
        var sse: [Data] = events.map { e in
            Data(("data: " + String(decoding: try! JSONSerialization.data(withJSONObject: e), as: UTF8.self) + "\n\n").utf8)
        }
        sse.append(Data("data: [DONE]\n\n".utf8))
        let streamed = sse, bodies = bodies
        server = try LoopbackServer { req in
            switch req.path {
            case "/v1/models": return .json(["object": "list", "data": [["id": model]]])
            case "/props": return .json(["default_generation_settings": ["n_ctx": 16384]])
            case "/v1/chat/completions":
                bodies.add(req.body)
                return .init(contentType: "text/event-stream", chunks: streamed, delay: 0.005)
            default: return .text("", status: 404)
            }
        }
    }

    deinit { server.stop() }

    var baseURL: String { server.baseURL }
    /// The messages of each chat request.
    var chats: [[[String: Any]]] {
        bodies.all.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.compactMap { $0["messages"] as? [[String: Any]] }
    }
}

/// The Linux IDE's Coding Assistant pane over the shared model (issue #18):
/// asking with the editor's context, streaming, proposals as diffs,
/// accepting one change and rejecting another, Accept All / Reject All,
/// review, the commands, and the stand-in agent CLI.
@MainActor
@Suite(.serialized) struct ShellAssistantTests {
    static let greetingNew = "public struct Greeting {\n\tpublic var name: String\n    // Greets warmly.\n    public var text: String { \"Hello there, \\(name)!\" }\n}\n"
    static let mainNew = "import DemoCore\nprint(Greeting(name: \"Ycode\").text)\n"

    static let reply = """
    The greeting is built in `Greeting.text`. Here is a **warmer** version:

    ```swift file=Sources/DemoCore/Greeting.swift
    \(greetingNew.dropLast())
    ```

    And the caller with a real name:

    ```swift file=Sources/Demo/main.swift
    \(mainNew.dropLast())
    ```
    """

    /// A workspace whose assistant uses its own settings and an in-memory
    /// secret store, with llama.cpp pointed at `server`.
    func workspace(_ pkg: TempPackage, provider: ProviderKind = .llamaCpp, configure: (inout AssistantSettings) -> Void = { _ in }) throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        let services = CodingAssistantServices(store: MemorySecretStore())
        let prefs = Preferences(defaults: UserDefaults(suiteName: "ycode-assistant-test-\(UUID().uuidString)")!)
        var s = AssistantSettings()
        s.provider = provider
        configure(&s)
        prefs.codingAssistant = s
        services.preferences = prefs
        m.assistant.services = services
        return m
    }

    func contents(_ path: String) -> String { String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self) }

    @Test func asksWithTheEditorsContextStreamsAndAppliesOnlyTheAcceptedChange() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let server = try StandInModelServer(reply: Self.reply)
        let m = try workspace(pkg) { $0.llamaCppURL = server.baseURL }
        let greeting = pkg.path("Sources/DemoCore/Greeting.swift"), main = pkg.path("Sources/Demo/main.swift")
        let greetingBefore = contents(greeting), mainBefore = contents(main)
        m.open(greeting)
        m.editor.map { $0.buffer.selectLine(at: $0.buffer.document.lineStart(3)) }

        // ⌘0 shows the pane; the back ends are checked.
        m.perform(.showCodingAssistant)
        #expect(m.assistant.isShown && m.isAssistantPaneShown && m.menuContext.codingAssistantShown)
        let core = try #require(m.assistant.core)
        await core.refreshAvailability().value
        #expect(m.assistant.status == nil && m.assistant.sourceLabel == "llama.cpp · standin-coder")
        #expect(m.assistant.providerChoices.first { $0.kind == .llamaCpp }?.models.first?.isCurrent == true)

        // Ask: the message carries the file, the selection and the context.
        m.perform(.newConversation)
        m.assistant.draft = "Make the greeting warmer"
        let id = try #require(m.assistant.send())
        #expect(m.assistant.draft.isEmpty && m.assistant.isResponding)
        #expect(!m.isEnabled(.jumpToNextActiveConversation) || core.isRunning(id))
        await core.response(id)?.value
        #expect(!m.assistant.isResponding)
        let conv = try #require(core.conversation(id))
        #expect(conv.title == "Make the greeting warmer")
        let answer = try #require(conv.messages.last)
        #expect(answer.text == Self.reply && answer.error == nil && answer.source == "llama.cpp · standin-coder")
        let sent = try #require(server.chats.last?.last?["content"] as? String)
        #expect(sent.contains("Make the greeting warmer"))
        #expect(sent.contains("Sources/DemoCore/Greeting.swift"))
        #expect(sent.contains("public var text: String"))

        // Two proposals, each a diff of its file.
        let proposals = m.assistant.proposals(in: answer)
        #expect(proposals.map(\.path) == ["Sources/DemoCore/Greeting.swift", "Sources/Demo/main.swift"])
        guard case .ready(let d0) = m.assistant.preview(proposals[0], in: answer) else { Issue.record("no diff"); return }
        #expect(d0.title == "Change Greeting.swift: +2 \u{2212}2 lines")
        #expect(d0.lines.filter { $0.kind == .added }.map(\.text) == ["    // Greets warmly.", "    public var text: String { \"Hello there, \\(name)!\" }"])
        #expect(d0.rows.contains { $0.kind == .changed })
        #expect(m.assistant.undecided(in: answer).count == 2)

        // Nothing is written before review.
        #expect(contents(greeting) == greetingBefore && contents(main) == mainBefore && m.editedPaths.isEmpty)

        // Accept the first change, reject the second.
        #expect(m.assistant.accept(proposals[0], message: answer, conversation: id))
        let afterAccept = try #require(core.conversation(id)?.messages.last)
        m.assistant.reject(proposals[1], message: afterAccept, conversation: id)
        let decided = try #require(core.conversation(id)?.messages.last)
        #expect(decided.resolvedProposals == [0: .accepted, 1: .rejected])
        #expect(m.assistant.undecided(in: decided).isEmpty)

        // The accepted change is in the editor, unsaved and undoable; the
        // files on disk are untouched until the user saves.
        #expect(m.editor?.path == greeting && m.editor?.buffer.text == Self.greetingNew)
        #expect(m.editedPaths == [greeting])
        #expect(contents(greeting) == greetingBefore && contents(main) == mainBefore)
        m.perform(.saveAll)
        #expect(contents(greeting) == Self.greetingNew && contents(main) == mainBefore)
        m.editor?.buffer.undo()
        #expect(m.editor?.buffer.text == greetingBefore)
    }

    @Test func acceptAllRejectAllReviewAndRefusals() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let reply = """
        ```swift selection
        \tpublic var name: String = "World"
        ```

        ```swift file=Sources/DemoCore/Farewell.swift
        public let farewell = "Bye"
        ```

        ```swift file=../outside.swift
        let x = 1
        ```

        ```swift
        let example = 2
        ```
        """
        let server = try StandInModelServer(reply: reply)
        let m = try workspace(pkg) { $0.llamaCppURL = server.baseURL }
        let greeting = pkg.path("Sources/DemoCore/Greeting.swift")
        m.open(greeting)
        // Select line 2 (the name) whole.
        m.editor.map { $0.buffer.selectLine(at: $0.buffer.document.lineStart(1)) }
        let a = m.assistant
        a.show()
        await a.core!.refreshAvailability().value
        a.draft = "Give the name a default"
        let id = try #require(a.send())
        await a.core!.response(id)?.value
        let answer = try #require(a.core!.conversation(id)?.messages.last)
        // `../` paths are not proposals; plain blocks are examples.
        let proposals = a.proposals(in: answer)
        #expect(proposals.map(\.kind) == [.replaceSelection, .wholeFile], "\(proposals) target \(String(describing: answer.target)) text \(answer.text)")
        guard proposals.count == 2 else { return }
        guard case .ready(let newFile) = a.preview(proposals[1], in: answer) else { Issue.record("no preview"); return }
        #expect(newFile.isNewFile && newFile.title == "Create Sources/DemoCore/Farewell.swift")

        // Review… opens the side-by-side sheet; Reject there changes nothing.
        a.openReview(proposals[1], message: answer, conversation: id)
        #expect(a.review?.acceptTitle == "Create File" && a.review?.diff.rows.count == 1)
        a.rejectReview()
        #expect(a.review == nil && !FileManager.default.fileExists(atPath: pkg.path("Sources/DemoCore/Farewell.swift")))
        // Accept All takes the rest: the selection is replaced in the editor.
        let m1 = try #require(a.core!.conversation(id)?.messages.last)
        a.acceptAll(in: m1, conversation: id)
        #expect(a.core!.conversation(id)?.messages.last?.resolvedProposals == [0: .accepted, 1: .rejected])
        #expect(m.editor?.buffer.text.contains("\tpublic var name: String = \"World\"\n") == true)
        #expect(!contents(greeting).contains("World"))

        // A second answer: Reject All.
        a.draft = "Again"
        let id2 = try #require(a.send())
        await a.core!.response(id2)?.value
        let m2 = try #require(a.core!.conversation(id2)?.messages.last)
        a.rejectAll(in: m2, conversation: id2)
        #expect(a.core!.conversation(id2)?.messages.last?.resolvedProposals.values.allSatisfy { $0 == .rejected } == true)

        // A file outside the workspace is refused when reviewed.
        let outside = ChangeProposal(kind: .wholeFile, path: "Sources/../../escape.swift", language: "swift", text: "x", blockIndex: 9)
        if case .failed(let why) = a.preview(outside, in: answer) { #expect(why.contains("outside the workspace")) } else { Issue.record("not refused") }
    }

    @Test func standInAgentCLIAnswersWithAProposal() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        // Claude Code's documented stream-json events, from a script that
        // also records its arguments and standard input.
        let text = "Here is the change.\n\n```swift file=Sources/Demo/main.swift\n\(Self.mainNew)```\n"
        func event(_ t: String) -> String {
            let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: [t], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast()
            return #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"# + escaped + #"}},"parent_tool_use_id":null}"#
        }
        let lines = [#"{"type":"system","subtype":"init","session_id":"s","tools":["Read"],"model":"m"}"#, event(String(text.prefix(20))), event(String(text.dropFirst(20))),
                     #"{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":3,"output_tokens":4},"session_id":"s"}"#]
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(tools.path)/args\"\ncat > \"\(tools.path)/stdin\"\n"
            + lines.map { "printf '%s\\n' '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        let exe = tools.appendingPathComponent("claude")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let m = try workspace(pkg, provider: .claudeCode) {
            $0.toolPaths[ProviderKind.claudeCode.rawValue] = exe.path
            $0.agentMode = false
        }
        m.open(pkg.path("Sources/Demo/main.swift"))
        let a = m.assistant
        a.newConversation()
        await a.core!.refreshAvailability().value
        #expect(a.sourceLabel.hasPrefix("Claude Code"))
        a.draft = "Use a real name"
        let id = try #require(a.send())
        await a.core!.response(id)?.value
        let answer = try #require(a.core!.conversation(id)?.messages.last)
        #expect(answer.error == nil && answer.text == text)
        let stdin = (try? String(contentsOf: tools.appendingPathComponent("stdin"), encoding: .utf8)) ?? ""
        #expect(stdin.contains("Use a real name") && stdin.contains("print(Greeting(name: \"x\").text)"))
        let args = (try? String(contentsOf: tools.appendingPathComponent("args"), encoding: .utf8)) ?? ""
        #expect(args.contains("plan") && args.contains("--no-session-persistence"))
        let p = try #require(a.proposals(in: answer).first)
        #expect(a.accept(p, message: answer, conversation: id))
        #expect(m.editor?.buffer.text == Self.mainNew)
    }

    @Test func commandsAndThePane() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try workspace(pkg) { $0.llamaCppURL = "http://127.0.0.1:9" }
        // The commands are the core's menu items.
        for c in [ShellCommand.showCodingAssistant, .newConversation, .jumpToNextActiveConversation, .codingToolExplain, .codingToolDocument,
                  .codingToolGeneratePlayground, .codingToolGeneratePreview] {
            #expect(c.menuCommand != nil, "\(c)")
        }
        #expect(ShellCommand.showCodingAssistant.title(in: m.menuContext) == "Show Coding Assistant")
        #expect(ShellCommand.showCodingAssistant.shortcut?.key == "0")
        #expect(ShellCommand.newConversation.menu == "File" && ShellCommand.jumpToNextActiveConversation.menu == "Navigate")
        #expect(m.isEnabled(.showCodingAssistant) && m.isEnabled(.newConversation) && !m.isEnabled(.jumpToNextActiveConversation))
        #expect(!m.isEnabled(.codingToolExplain))
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        #expect(m.isEnabled(.codingToolExplain) && m.isEnabled(.codingToolDocument) && !m.isEnabled(.codingToolGeneratePreview))

        // ⌘0 shows the pane; again hides the area; a navigator leaves it.
        m.perform(.showCodingAssistant)
        #expect(m.isAssistantPaneShown && ShellCommand.showCodingAssistant.title(in: m.menuContext) == "Hide Coding Assistant")
        m.perform(.showCodingAssistant)
        #expect(!m.isNavigatorShown)
        m.showLeftPane(assistant: true)
        #expect(m.isAssistantPaneShown)
        m.perform(.showIssueNavigator)
        #expect(!m.assistant.isShown && m.isNavigatorShown && m.navigator == .issues)
        m.showLeftPane(assistant: true)
        m.showLeftPane(assistant: false)
        #expect(!m.assistant.isShown && m.isNavigatorShown)

        // A list: groups, rename, archive, delete.
        let a = m.assistant
        a.newConversation()
        let c = try #require(a.selectedID)
        a.newGroup()
        let g = try #require(a.groups.first)
        #expect(a.renamingID == g.id)
        a.renameText = "Refactors"
        a.commitRename()
        a.move(c, toGroup: g.id)
        guard case .group(let group, let inside) = a.outline.first else { Issue.record("no group"); return }
        #expect(group.title == "Refactors" && inside.map(\.id) == [c])
        a.setArchived(c, true)
        guard case .archive(let archived) = a.outline.last else { Issue.record("no archive"); return }
        #expect(archived.map(\.id) == [c])
        a.delete(c)
        #expect(a.selectedID == nil)

        // The toolbar's prompt starts a conversation in the pane.
        m.showLeftPane(assistant: false)
        a.togglePrompt()
        #expect(a.isPromptShown)
        a.promptDraft = "Hello there"
        let started = try #require(a.sendPrompt())
        #expect(!a.isPromptShown && a.promptDraft.isEmpty && m.isAssistantPaneShown)
        #expect(a.selectedID == started && a.selected?.title == "Hello there")
    }

    @Test func theContextARequestCarries() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try workspace(pkg)
        m.open(pkg.path("README.md"))
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        let b = try #require(m.editor?.buffer)
        b.selectLine(at: b.document.lineStart(2))
        let ctx = m.assistantContext()
        #expect(ctx.workspaceName == "Demo")
        #expect(ctx.currentFile?.path == "Sources/DemoCore/Greeting.swift")
        #expect(ctx.selection?.startLine == 3 && ctx.selection?.endLine == 3 && ctx.selection?.text == "    // Greets.\n")
        #expect(ctx.caretLine != nil && ctx.openFiles.map(\.path) == ["README.md"])
        let (file, sel) = m.assistant.attachmentChoices
        #expect(file?.label == "Greeting.swift" && sel?.label == "Greeting.swift:3")
        m.assistant.attach(try #require(sel))
        m.assistant.attach(try #require(sel))
        #expect(m.assistant.attachments.count == 1)
        m.assistant.removeAttachment(try #require(sel))
        #expect(m.assistant.attachments.isEmpty)
    }

    @Test func inlineMarkdownAndCompactDiffs() {
        let runs = AssistantInline.runs("Call `greet()` for a **warm** _hello_ in snake_case_name.")
        #expect(runs.map(\.text) == ["Call ", "greet()", " for a ", "warm", " ", "hello", " in snake_case_name."])
        #expect(runs[1].code && runs[3].bold && runs[5].italic && !runs[6].italic)
        let ops = LineDiff.diff((1...20).map { "l\($0)" }, (1...20).map { $0 == 2 ? "two" : ($0 == 18 ? "eighteen" : "l\($0)") })
        let lines = AssistantDiffLine.unified(ops)
        #expect(lines.filter { $0.kind == .gap }.count == 1)
        #expect(lines.first?.old == 1 && lines.contains { $0.kind == .added && $0.text == "two" && $0.new == 2 })
    }

    @Test func applyingReplacesOnlyTheChangedPart() {
        let b = EditorBuffer(text: "a😀b\nkeep\n", language: .plain)
        b.setCaret(9)
        WorkspaceShellModel.replaceChangedPart(of: b, with: "a😃b\nkeep\n")
        #expect(b.text == "a😃b\nkeep\n")
        b.undo()
        #expect(b.text == "a😀b\nkeep\n")
    }
}
