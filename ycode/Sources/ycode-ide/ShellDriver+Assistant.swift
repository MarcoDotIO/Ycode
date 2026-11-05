import Foundation
import SwiftUI
import YcodeAssistant
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_ASSISTANT=<prefix>: the Coding Assistant end to end (issue #18)
// on a Swift package with Sources/DemoCore/Greeting.swift and
// Sources/Demo/main.swift (TempPackage's layout). The walk starts a
// stand-in model server on 127.0.0.1 in this process (the OpenAI-compatible
// API llama-server serves, streaming a fixed answer that proposes a change
// to each file), points Settings ▸ Coding Assistant's llama.cpp at it, then
// with the pointer and keyboard: Ctrl+0, a question with a selection,
// streaming, the two proposals as diffs, Accept on one and Reject on the
// other, File ▸ Save All, the files on disk checked; a second answer's
// Review… sheet; the model menu; Settings ▸ Coding Assistant with a
// stand-in key saved. Writes <prefix>-assistant-<state>.png (window 1 for
// Settings) and prints "check <what>: ok|FAILED".
//
// Run it with XDG_CONFIG_HOME and XDG_DATA_HOME pointing at a scratch
// folder: it changes the assistant's settings and saves a stand-in key.
extension ShellDriver {
    #if os(Linux)
    static let assistantGreeting = "public struct Greeting {\n\tpublic var name: String\n    // Greets warmly.\n    public var text: String { \"Hello there, \\(name)!\" }\n"
        + "    public init(name: String) { self.name = name }\n}\n"

    static let assistantReply = """
    `Greeting.text` builds the message. Here is a **warmer** greeting:

    ```swift file=Sources/DemoCore/Greeting.swift
    \(assistantGreeting.dropLast())
    ```

    And the caller can pass a real name:

    ```swift file=Sources/Demo/main.swift
    import DemoCore
    print(Greeting(name: "Ycode").text)
    ```
    """

    /// The stand-in server: `/v1/models`, `/props`, and the answer as
    /// server-sent events, a few characters every 25 ms. Records the
    /// Authorization header of the chats.
    final class StandInAuth: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
        var last: String? { lock.lock(); defer { lock.unlock() }; return values.last }
    }

    static func standInServer(_ auth: StandInAuth) throws -> LoopbackServer {
        let reply = assistantReply
        var events: [String] = [#"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#]
        var i = reply.startIndex
        while i < reply.endIndex {
            let j = reply.index(i, offsetBy: 6, limitedBy: reply.endIndex) ?? reply.endIndex
            let piece = String(decoding: try JSONSerialization.data(withJSONObject: [String(reply[i..<j])]), as: UTF8.self).dropFirst().dropLast()
            events.append(#"{"choices":[{"index":0,"delta":{"content":"# + piece + "}}]}")
            i = j
        }
        events.append(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":60}}"#)
        events.append("[DONE]")
        let chunks = events.map { Data("data: \($0)\n\n".utf8) }
        return try LoopbackServer { req in
            switch req.path {
            case "/v1/models": return .json(["object": "list", "data": [["id": "standin-coder"]]])
            case "/props": return .json(["default_generation_settings": ["n_ctx": 16384]])
            case "/v1/chat/completions":
                auth.add(req.header("authorization") ?? "")
                return .init(contentType: "text/event-stream", chunks: chunks, delay: 0.025)
            default: return .text("", status: 404)
            }
        }
    }

    static func assistantWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("assistant: no workspace"); return }
        let a = w.assistant
        func shot(_ name: String) async {
            await pause(0.6)
            say("assistant \(name): conversations=\(a.core?.library.conversations.count ?? 0) responding=\(a.isResponding) "
                + "source=\"\(a.sourceLabel)\" " + OpenViewsAutomation.screenshot(to: "\(prefix)-assistant-\(name).png"))
        }
        func check(_ what: String, _ ok: Bool) { say("check \(what): \(ok ? "ok" : "FAILED")") }
        func disk(_ rel: String) -> String { (try? String(contentsOfFile: w.assistantFolder.appendingPathComponent(rel).path, encoding: .utf8)) ?? "" }

        let auth = StandInAuth()
        guard let server = try? standInServer(auth) else { say("assistant: the stand-in server did not start"); return }
        defer { server.stop() }
        var s = Preferences.shared.codingAssistant
        s.provider = .llamaCpp
        s.llamaCppURL = server.baseURL
        s.agentMode = false
        Preferences.shared.codingAssistant = s
        say("assistant: stand-in model server at \(server.baseURL)")

        let greetingPath = "Sources/DemoCore/Greeting.swift", mainPath = "Sources/Demo/main.swift"
        let greetingBefore = disk(greetingPath), mainBefore = disk(mainPath)
        if let p = w.assistantPath(greetingPath) { w.open(p) }
        await pause(0.5)
        // Select the greeting's two lines (3 and 4).
        if let b = w.editor?.buffer {
            b.setSelection(.init(anchor: b.document.lineStart(2), head: b.document.lineStart(4)))
        }

        // Ctrl+0: View ▸ Navigators ▸ Show Coding Assistant.
        OpenViewsAutomation.press(.character("0"), modifiers: [.control])
        for _ in 0..<40 where a.core?.availability.isEmpty ?? true { await pause(0.1) }
        await shot("pane")
        check("Ctrl+0 shows the pane", w.isAssistantPaneShown)
        check("the stand-in is ready", a.status == nil && a.sourceLabel == "llama.cpp · standin-coder")

        // Ask, with the pointer in the field and Return.
        await click("assistant message")
        OpenViewsAutomation.type("Make the greeting warmer")
        await pause(0.3)
        await shot("typed")
        OpenViewsAutomation.press(.return)
        await pause(1.2)
        await shot("streaming")
        check("the answer streams", a.isResponding)
        for _ in 0..<200 where a.isResponding { await pause(0.1) }
        await pause(0.4)
        guard let conv = a.selected, let answer = conv.messages.last else { say("assistant: no answer"); return }
        let proposals = a.proposals(in: answer)
        check("the answer arrived whole", answer.text == assistantReply && answer.error == nil)
        check("two proposals", proposals.map(\.path) == [greetingPath, mainPath])
        await shot("proposals")
        // Scroll the transcript to the second proposal's buttons.
        if let t = frame("assistant transcript") {
            OpenViewsAutomation.scroll(at: CGPoint(x: t.midX, y: t.midY), delta: CGSize(width: 0, height: -20))
            await pause(0.4)
        }
        check("nothing written before review", disk(greetingPath) == greetingBefore && disk(mainPath) == mainBefore && w.editedPaths.isEmpty)

        // Accept the first change and reject the second, with the pointer.
        await click("assistant accept Greeting.swift 0 1")
        await pause(0.4)
        if let t = frame("assistant transcript") {
            OpenViewsAutomation.scroll(at: CGPoint(x: t.midX, y: t.midY), delta: CGSize(width: 0, height: -20))
            await pause(0.4)
        }
        await click("assistant reject main.swift 1 1")
        await pause(0.4)
        await shot("decided")
        let decided = a.selected?.messages.last?.resolvedProposals ?? [:]
        check("accepted one, rejected the other", decided == [0: .accepted, 1: .rejected])
        check("the accepted change is in the editor, unsaved", w.editor?.buffer.text == assistantGreeting && w.editedPaths.count == 1)
        check("disk untouched before saving", disk(greetingPath) == greetingBefore && disk(mainPath) == mainBefore)
        // File ▸ Save All (Ctrl+Alt+S).
        await clickText("File", inPopup: false)
        await clickText("Save All", inPopup: true)
        await pause(0.5)
        if !w.editedPaths.isEmpty { say("assistant: Save All from the menu did not save; saving directly"); w.saveAll() }
        check("on disk: the accepted file changed", disk(greetingPath) == assistantGreeting)
        check("on disk: the rejected file unchanged", disk(mainPath) == mainBefore)
        await shot("saved")

        // A second answer: Review… shows the change side by side.
        a.draft = "And once more"
        a.send()
        for _ in 0..<200 where a.isResponding || a.selected?.messages.last?.isComplete != true { await pause(0.1) }
        await pause(0.5)
        if let t = frame("assistant transcript") {
            OpenViewsAutomation.scroll(at: CGPoint(x: t.midX, y: t.midY), delta: CGSize(width: 0, height: -40))
            await pause(0.4)
        }
        await shot("second-answer")
        await click("assistant review main.swift 1 3")
        await pause(0.5)
        if a.review == nil, let m = a.selected?.messages.last, let p = a.proposals(in: m).last {
            say("assistant: Review… not reached with the pointer; opening it directly")
            a.openReview(p, message: m, conversation: a.selected!.id)
        }
        await shot("review")
        check("the review sheet", a.review?.diff.title.hasPrefix("Change main.swift") == true)
        await click("assistant review reject")
        if a.review != nil { a.rejectReview() }
        await pause(0.4)
        check("Reject in the review leaves the file", disk(mainPath) == mainBefore && w.assistantCurrentText(w.assistantPath(mainPath) ?? "") == mainBefore)
        await shot("after-review")

        // The model pull-down and the New Conversation menu (menus are
        // their own surfaces: their items are listed, not photographed).
        for (target, name) in [("assistant model", "model menu"), ("assistant new conversation menu", "providers menu")] {
            await click(target)
            await pause(0.5)
            let items = OpenViewsAutomation.texts().filter(\.inPopup).map(\.text)
            say("assistant \(name): \(items)")
            check("the \(name) opens", OpenViewsAutomation.openPopupCount > 0 && !items.isEmpty)
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
        }

        // The toolbar's New Conversation prompt: type and Return.
        let before = a.core?.library.conversations.count ?? 0
        await click("tb new conversation")
        await pause(0.6)
        check("the New Conversation prompt opens", a.isPromptShown && OpenViewsAutomation.openPopupCount > 0)
        OpenViewsAutomation.type("Explain Greeting")
        await pause(0.3)
        if a.promptDraft.isEmpty { say("assistant: typing did not reach the prompt; filling it in"); a.promptDraft = "Explain Greeting" }
        OpenViewsAutomation.press(.return)
        await pause(0.5)
        if a.isPromptShown { a.sendPrompt() }
        for _ in 0..<200 where a.isResponding { await pause(0.1) }
        check("the prompt started a conversation", (a.core?.library.conversations.count ?? 0) == before + 1 && a.selected?.title == "Explain Greeting")
        await shot("prompt-conversation")

        // Settings ▸ Coding Assistant, and a stand-in key saved to the
        // secret store (never shown, never in the user defaults).
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        if OpenViewsAutomation.windowCount >= 2 {
            await pause(0.6)
            await SettingsDriver.open(.codingAssistant)
            await SettingsDriver.shot(prefix, "assistant-settings")
            await SettingsDriver.click("settings assistant llamacpp key")
            OpenViewsAutomation.type("standin-local-key", window: 1)
            await pause(0.2)
            await SettingsDriver.click("settings assistant llamacpp key save")
            await pause(0.5)
            await SettingsDriver.shot(prefix, "assistant-settings-key-saved")
            let store = CodingAssistantServices.shared.store
            check("the key is in the secret store", store.readString(SecretAccount.llamaCppKey) == "standin-local-key")
            if let file = store as? FileSecretStore {
                let path = file.directory.appendingPathComponent(SecretAccount.llamaCppKey).path
                let mode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
                check("the key file is 0600", mode & 0o777 == 0o600)
            }
            let defaults = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }.joined()
            check("the key is not in the user defaults", !defaults.contains("standin-local-key"))
            // The next request sends it.
            a.draft = "Is the key sent?"
            a.send()
            for _ in 0..<200 where a.isResponding { await pause(0.1) }
            check("the request carries the saved key", auth.last == "Bearer standin-local-key")
            try? CodingAssistantServices.shared.store.delete(SecretAccount.llamaCppKey)
        } else {
            say("assistant: the Settings window did not open")
        }
        say("assistant walk done")
    }
    #endif
}
