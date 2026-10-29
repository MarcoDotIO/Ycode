import Foundation
import Testing
@testable import YcodeAssistant

@Suite struct PromptBuilderTests {
    let file = WorkspaceContext.File(path: "Sources/App/Model.swift", text: (1...40).map { "let value\($0) = \($0)" }.joined(separator: "\n"))

    @Test func everythingFitsInALargeBudget() {
        let ctx = WorkspaceContext(workspaceName: "Demo", currentFile: file, caretLine: 3,
                                   selection: .init(path: file.path, startLine: 2, endLine: 3, text: "let value2 = 2\nlet value3 = 3", location: 15, length: 29),
                                   openFiles: [.init(path: "Sources/App/View.swift", text: "struct V {}")],
                                   issues: [.init(severity: "warning", message: "unused", path: "Sources/App/View.swift", line: 1),
                                            .init(severity: "error", message: "cannot find 'x'", path: file.path, line: 7)])
        let p = PromptBuilder.build(history: [ChatMessage(.user, "earlier"), ChatMessage(.assistant, "answer")], prompt: "Why?",
                                    attachments: [], context: ctx, contextTokens: 32_000)
        #expect(p.omitted.isEmpty)
        #expect(p.messages.count == 3)
        #expect(p.messages.last?.role == .user)
        let last = p.messages.last!.content
        #expect(last.hasPrefix("<context>\nWorkspace: Demo"))
        #expect(last.hasSuffix("</context>\n\nWhy?"))
        #expect(last.contains("Selected code, lines 2–3 of Sources/App/Model.swift"))
        #expect(last.contains("```swift\nlet value1 = 1"))
        // Errors are listed before warnings.
        #expect(last.range(of: "- error Sources/App/Model.swift:7")!.lowerBound < last.range(of: "- warning")!.lowerBound)
        #expect(last.contains("Open file Sources/App/View.swift"))
        #expect(p.included.contains("File Model.swift"))
        #expect(p.estimatedTokens < 32_000)
    }

    @Test func smallBudgetKeepsSelectionAndRecentHistoryAndShrinksTheFile() {
        let big = WorkspaceContext.File(path: "Big.swift", text: (1...2000).map { "let line\($0) = \"\(String(repeating: "x", count: 40))\"" }.joined(separator: "\n"))
        let ctx = WorkspaceContext(currentFile: big, caretLine: 1000,
                                   selection: .init(path: "Big.swift", startLine: 1000, endLine: 1000, text: "let line1000 = 1", location: 0, length: 16),
                                   openFiles: [.init(path: "Other.swift", text: String(repeating: "y", count: 20_000))])
        let history = (0..<30).map { ChatMessage($0 % 2 == 0 ? .user : .assistant, "turn \($0) " + String(repeating: "z", count: 400)) }
        let p = PromptBuilder.build(history: history, prompt: "Fix it", attachments: [], context: ctx, contextTokens: 4096, reservedOutput: 1024)
        #expect(p.estimatedTokens <= 4096 - 1024)
        #expect(p.included.contains { $0.hasPrefix("Selection Big.swift") })
        #expect(p.included.contains { $0.hasPrefix("Part of Big.swift (lines") })
        #expect(p.omitted.contains("Open file Other.swift"))
        #expect(p.omitted.contains { $0.hasSuffix("earlier messages") })
        // The kept history is the most recent, in order.
        let kept = p.messages.dropLast()
        if let lastKept = kept.last { #expect(lastKept.content.hasPrefix("turn 29")) }
        #expect(p.messages.last!.content.contains("let line1000"))
    }

    @Test func oversizedMessageIsShortened() {
        let p = PromptBuilder.build(history: [], prompt: String(repeating: "a", count: 100_000), attachments: [], context: .init(),
                                    contextTokens: 2048, reservedOutput: 512)
        #expect(p.estimatedTokens <= 2048)
        #expect(p.omitted == ["End of the message"])
        #expect(p.messages.last!.content.hasSuffix("[…message shortened to fit the model's context…]"))
    }

    @Test func attachmentsComeFirstAndAreNotRepeated() {
        let ctx = WorkspaceContext(currentFile: file)
        let a = Attachment(kind: .file, path: file.path, text: file.text)
        let p = PromptBuilder.build(history: [], prompt: "Review", attachments: [a], context: ctx, contextTokens: 32_000)
        let content = p.messages.last!.content
        #expect(content.components(separatedBy: "let value40 = 40").count == 2)
        #expect(p.included.contains("File Model.swift"))
    }

    @Test func tokenEstimate() {
        #expect(TokenEstimator.estimate("") == 0)
        #expect(TokenEstimator.estimate("abcd") == 1)
        #expect(TokenEstimator.estimate("abcde") == 2)
    }

    @Test func codingToolPrompts() {
        #expect(CodingTool.allCases.map(\.title) == ["Explain", "Document", "Generate a Playground", "Generate a Preview"])
        #expect(CodingTool.document.prompt(path: "A.swift", hasSelection: true).contains("```swift selection```"))
        #expect(CodingTool.document.prompt(path: "A.swift", hasSelection: false).contains("file=A.swift"))
        #expect(CodingTool.generatePlayground.prompt(path: "A.swift", hasSelection: true).contains("#Playground"))
        #expect(CodingTool.generatePreview.applies(toPath: "V.swift", text: "import SwiftUI"))
        #expect(!CodingTool.generatePreview.applies(toPath: "V.swift", text: "import Foundation"))
        #expect(!CodingTool.document.applies(toPath: "notes.txt", text: ""))
        #expect(CodingTool.explain.applies(toPath: "notes.txt", text: ""))
    }
}

@Suite struct ProposalTests {
    @Test func markdownBlocksIncludingUnclosedFence() {
        let text = "Intro\n\n```swift file=A.swift\nlet a = 1\n```\nMiddle\n~~~\nraw\n~~~\n```py\nprint(1)"
        #expect(MarkdownBlocks.parse(text) == [
            .prose("Intro"), .code(info: "swift file=A.swift", text: "let a = 1", closed: true), .prose("Middle"),
            .code(info: "", text: "raw", closed: true), .code(info: "py", text: "print(1)", closed: false),
        ])
        #expect(MarkdownBlocks.parse("````md\n```swift\nx\n```\n````") == [.code(info: "md", text: "```swift\nx\n```", closed: true)])
    }

    @Test func parseKinds() {
        let target = ProposalTarget(path: "Sources/A.swift", selectionLocation: 4, selectionLength: 5, selectionText: "old()")
        let response = """
        Here:
        ```swift file=Sources/B.swift
        struct B {}
        ```
        ```swift selection
        new()
        ```
        ```swift append
        #Preview { V() }
        ```
        ```swift
        // just an example
        ```
        ```swift file=../../etc/passwd
        nope
        ```
        ```swift file=Sources/C.swift
        unfinished
        """
        let p = ChangeProposal.parse(response, target: target)
        #expect(p.map(\.kind) == [.wholeFile, .replaceSelection, .append])
        #expect(p.map(\.path) == ["Sources/B.swift", "Sources/A.swift", "Sources/A.swift"])
        #expect(p.map(\.blockIndex) == [0, 1, 2])
        #expect(ChangeProposal.parse("```swift selection\nx\n```", target: nil).isEmpty)
    }

    @Test func applyKinds() throws {
        let original = "let x = old()\nprint(x)\n"
        let target = ProposalTarget(path: "A.swift", selectionLocation: 8, selectionLength: 5, selectionText: "old()")
        let sel = ChangeProposal(kind: .replaceSelection, path: "A.swift", language: "swift", text: "new()", blockIndex: 0)
        #expect(try sel.apply(to: original, target: target) == "let x = new()\nprint(x)\n")
        // The selection moved: a single exact occurrence still applies.
        #expect(try sel.apply(to: "// header\n" + original, target: target) == "// header\nlet x = new()\nprint(x)\n")
        #expect(throws: ChangeProposal.ApplyError.selectionChanged) { try sel.apply(to: "let y = other()\n", target: target) }
        #expect(throws: ChangeProposal.ApplyError.selectionChanged) { try sel.apply(to: "old() old()", target: target) }
        let whole = ChangeProposal(kind: .wholeFile, path: "A.swift", language: nil, text: "let x = 2", blockIndex: 0)
        #expect(try whole.apply(to: original, target: nil) == "let x = 2\n")
        #expect(try whole.apply(to: nil, target: nil) == "let x = 2\n")
        let add = ChangeProposal(kind: .append, path: "A.swift", language: nil, text: "#Preview {}", blockIndex: 0)
        #expect(try add.apply(to: original, target: nil) == original + "\n#Preview {}\n")
        #expect(try add.apply(to: "a", target: nil) == "a\n\n#Preview {}\n")
    }
}

@Suite struct ConversationTests {
    @Test func titlesAndHistory() {
        #expect(Conversation.title(fromPrompt: "  Explain the build\nmore") == "Explain the build")
        #expect(Conversation.title(fromPrompt: "") == "New Conversation")
        #expect(Conversation.title(fromPrompt: String(repeating: "a", count: 60)).count == 48)
        var c = Conversation()
        c.messages = [ConversationMessage(role: .user, text: "q"), ConversationMessage(role: .assistant, text: "a"),
                      ConversationMessage(role: .user, text: "q2"), ConversationMessage(role: .assistant, text: "partial", error: "Stopped.")]
        #expect(c.history == [ChatMessage(.user, "q"), ChatMessage(.assistant, "a"), ChatMessage(.user, "q2")])
        c.messages.append(ConversationMessage(role: .assistant, text: "", isComplete: false))
        #expect(c.isActive)
    }

    @Test func archiveRoundTripSettlesStreamingResponses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-conv-\(UUID().uuidString)/conversations.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var c = Conversation(title: "T", provider: .ollama, model: "qwen2.5-coder")
        c.messages = [ConversationMessage(role: .user, text: "q", attachments: [Attachment(kind: .selection, path: "A.swift", startLine: 2, endLine: 4, text: "x")]),
                      ConversationMessage(role: .assistant, text: "par", isComplete: false)]
        c.messages[1].resolvedProposals = [0: .accepted]
        try ConversationArchive.save([c], to: url)
        let back = ConversationArchive.load(url)
        #expect(back.count == 1)
        #expect(back[0].messages[0].attachments.first?.label == "A.swift:2–4")
        #expect(back[0].messages[1].isComplete && back[0].messages[1].error == "Interrupted.")
        #expect(back[0].messages[1].resolvedProposals == [0: .accepted])
        #expect(back[0].model == "qwen2.5-coder")
    }

    /// reference-ui-6.md §9.2: groups (oldest first, conversations newest
    /// first), then ungrouped conversations, then Archive, always last.
    @Test func libraryOutlineAndGroups() throws {
        var lib = ConversationLibrary()
        #expect(lib.outline == [.archive([])])
        let g = ConversationGroup(title: "Refactors")
        lib.groups = [g]
        #expect(lib.unusedGroupTitle() == "New Group")
        lib.groups.append(ConversationGroup())
        #expect(lib.unusedGroupTitle() == "New Group 2")
        let a = Conversation(title: "A"), b = Conversation(title: "B", groupID: g.id), c = Conversation(title: "C", isArchived: true)
        let orphan = Conversation(title: "D", groupID: UUID())
        lib.conversations = [a, b, c, orphan]
        let outline = lib.outline
        #expect(outline.count == 5)
        #expect(outline[0] == .group(g, [b]))
        #expect(outline[1] == .group(lib.groups[1], []))
        // Newest first; a conversation whose group is gone is at the top level.
        #expect(outline[2] == .conversation(orphan) && outline[3] == .conversation(a))
        #expect(outline[4] == .archive([c]))
    }

    @Test func libraryFileReadsTheOlderListFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json")
        try ConversationArchive.save([Conversation(title: "Old")], to: old)
        // A file written before groups: a plain list, no group keys.
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: old)) as? [String: Any]
        let plain = try JSONSerialization.data(withJSONObject: (list?["conversations"] as? [[String: Any]] ?? []).map { c -> [String: Any] in
            var c = c
            c["groupID"] = nil
            c["isArchived"] = nil
            return c
        })
        try plain.write(to: old)
        let back = ConversationArchive.loadLibrary(old)
        #expect(back.conversations.map(\.title) == ["Old"] && back.groups.isEmpty && back.conversations[0].isArchived == false)
        // Groups and archive flags round-trip.
        let g = ConversationGroup(title: "G")
        let lib = ConversationLibrary(conversations: [Conversation(title: "In G", groupID: g.id), Conversation(title: "Gone", isArchived: true)], groups: [g])
        let url = dir.appendingPathComponent("new.json")
        try ConversationArchive.save(lib, to: url)
        let again = ConversationArchive.loadLibrary(url)
        #expect(again.groups.map(\.id) == [g.id] && again.groups.map(\.title) == ["G"])
        #expect(again.conversations.map(\.id) == lib.conversations.map(\.id))
        #expect(again.conversations.map(\.groupID) == [g.id, nil] && again.conversations.map(\.isArchived) == [false, true])
        #expect(ConversationArchive.load(url).count == 2)
    }

    @Test func settingsDecodeOlderData() throws {
        let s = try JSONDecoder().decode(AssistantSettings.self, from: Data(#"{"provider":"codex"}"#.utf8))
        #expect(s.provider == .codex)
        #expect(s.ollamaURL == "http://127.0.0.1:11434")
        #expect(s.contextLimit == 32_768)
        var t = AssistantSettings()
        t.setModel("gpt-6.1", for: .openAI)
        let back = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}

@Suite struct SecretStoreTests {
    @Test func fileStoreIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-secrets-\(UUID().uuidString)/secrets")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = FileSecretStore(directory: dir)
        #expect(try s.read("openai.api-key") == nil)
        try s.write(Data("sk-test".utf8), for: "openai.api-key")
        try s.write(Data("sk-test-2".utf8), for: "openai.api-key")
        #expect(s.readString("openai.api-key") == "sk-test-2")
        let fileMode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("openai.api-key").path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["openai.api-key"])
        try s.delete("openai.api-key")
        #expect(try s.read("openai.api-key") == nil)
        try s.delete("openai.api-key")
    }

    @Test func memoryStoreJSON() throws {
        let s = MemorySecretStore()
        let reg = OpenAIRegistration.newHost()
        try s.writeJSON(reg, for: SecretAccount.openAIRegistration)
        #expect(s.readJSON(OpenAIRegistration.self, SecretAccount.openAIRegistration) == reg)
        #expect(UUID(uuidString: String(reg.hostID.dropFirst("urn:uuid:".count))) != nil)
    }

    #if canImport(Security)
    /// The real keychain, under a service name of its own that the test
    /// removes. Opt-in (`YCODE_KEYCHAIN_TESTS=1`): it writes to the login
    /// keychain.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YCODE_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let s = KeychainSecretStore(service: "Ycode Coding Assistant Tests \(UUID().uuidString)")
        defer { try? s.delete("probe") }
        #expect(try s.read("probe") == nil)
        try s.write(Data("one".utf8), for: "probe")
        try s.write(Data("two".utf8), for: "probe")
        #expect(s.readString("probe") == "two")
        try s.delete("probe")
        #expect(try s.read("probe") == nil)
    }
    #endif
}

@Suite struct StreamParsingTests {
    @Test func sseDecoder() {
        var d = SSEDecoder()
        var events: [SSEDecoder.Event] = []
        for l in [": comment", "event: message", "data: a", "data: b", "", "data:c", "", "retry: 5", ""] {
            if let e = d.push(line: l) { events.append(e) }
        }
        #expect(events == [.init(name: "message", data: "a\nb"), .init(name: nil, data: "c")])
    }

    @Test func lineSplitter() {
        var s = LineSplitter()
        #expect(s.push(Data("ab".utf8)).isEmpty)
        #expect(s.push(Data("c\r\nd\ne".utf8)) == ["abc", "d"])
        #expect(s.finish() == "e")
    }

    @Test func urlJoin() {
        #expect(HTTP.url("http://h:1/v1/", "/models")?.absoluteString == "http://h:1/v1/models")
        #expect(HTTP.formEncode([("scope", "a b"), ("x", "1+2/3")]) == "scope=a%20b&x=1%2B2%2F3")
    }
}
