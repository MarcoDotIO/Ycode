import AppKit
import Foundation
import Testing
@testable import YcodeCompletion
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Predictive completion in the macOS editor (specs/ide/predictive-completion.md
/// §3, §8): real key events into a source editor whose backend is a
/// stand-in server on 127.0.0.1 (no model, no network).
///
/// The editors here share nothing with other suites running at the same
/// time: each has its own settings value (not `Preferences.shared`, which
/// other suites swap), its own backend pointed at its own stand-in, no
/// back-off, and a fixed model (no model pick). Waits are conditions whose
/// deadlines count the main actor's own time (see `waitFor`).
@MainActor
@Suite(.serialized) struct PredictiveCompletionUITests {
    /// A deadline for conditions that need the main actor and a loopback
    /// round trip (in the main actor's own time; alone it takes well under
    /// a second).
    static let deadline: TimeInterval = 60

    func editor(_ name: String, _ text: String, server: StandInServer, debounce: Int = 0) throws -> (SourceEditorController, NSWindow) {
        _ = NSApplication.shared
        var s = PredictiveCompletionSettings()
        s.enabled = true
        s.address = server.baseURL
        s.model = server.modelName
        s.debounceMilliseconds = debounce
        let dir = ycodeDir.appendingPathComponent(".build-ide/predict")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let e = SourceEditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = e
        try e.open(file)
        e.predictionSettingsOverride = s
        let address = server.baseURL
        e.predictionSession.makeBackend = { _, _ in OllamaFIMBackend(address: address) }
        e.predictionSession.unreachableBackoff = 0
        window.makeFirstResponder(e.textView)
        return (e, window)
    }

    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = [], into tv: NSTextView) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        tv.keyDown(with: e)
    }

    func type(_ s: String, into tv: NSTextView) { for ch in s { key(String(ch), code: 0, into: tv) } }
    func tab(_ tv: NSTextView, _ flags: NSEvent.ModifierFlags = []) { key("\t", code: 48, flags: flags, into: tv) }
    func escape(_ tv: NSTextView) { key("\u{1b}", code: 53, into: tv) }

    /// Waits until `cond` holds or `timeout` seconds of the main actor's
    /// own time have passed; returns whether it held.
    ///
    /// The streamed reply is handled on the main actor, and other suites
    /// hold it with synchronous work (a window build, a toolchain call)
    /// for long stretches: 155 s at the start of a full run, during which
    /// dozens of tests finish at the same instant. A wall-clock deadline
    /// expired inside such a stall, and the first check after it failed
    /// while the reply's pieces were still queued behind the stall
    /// ("server saw 1", a partial or no suggestion). As `waitUntil`, time
    /// spent waiting for the main actor counts at most 0.25 s a turn.
    @discardableResult
    func waitFor(_ cond: () -> Bool, timeout: TimeInterval = Self.deadline) async -> Bool {
        var waited = 0.0
        while !cond() {
            if waited > timeout || Task.isCancelled { return false }
            let start = Date()
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += min(Date().timeIntervalSince(start), 0.25)
        }
        return true
    }

    /// What the session did, for failure messages.
    func state(_ e: SourceEditorController, _ server: StandInServer) -> Comment {
        let p = e.predictionSession
        return "status \(p.status), requests \(p.requestCount), busy \(p.isBusy), server saw \(server.generationRequests.count), suggestion \(String(describing: p.suggestion)), text \(e.text.debugDescription)"
    }

    func caretText(_ e: SourceEditorController) -> String {
        (e.text as NSString).replacingCharacters(in: NSRange(location: e.textView.selectedRange().location, length: 0), with: "|")
    }

    @Test func ghostTextAppearsTabAcceptsEscapeDismisses() async throws {
        let server = try StandInServer { _, _ in "items.count\nprint(total)" }
        let (e, _) = try editor("Ghost.swift", "\n", server: server)
        let tv = e.textView
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type("let total =", into: tv)
        type(" ", into: tv)
        let appeared = await waitFor { e.predictionSuggestion?.text == "items.count\nprint(total)" }
        try #require(appeared, state(e, server))
        #expect(e.predictionSuggestion?.anchor == 12)
        // Collapsed: the first line shows (WWDC24 "Xcode essentials": Tab accepts what's shown).
        #expect(e.shownPredictionText == "items.count")
        // The ghost text is drawn (the view's pixels change where it goes).
        #expect(tv.ghostOverlay.superview === tv && tv.subviews.last === tv.ghostOverlay)
        let withGhost = try #require(snapshot(tv))
        let saved = tv.ghostText
        tv.ghostText = nil
        #expect(tv.ghostOverlay.superview == nil)
        let without = try #require(snapshot(tv))
        tv.ghostText = saved
        #expect(withGhost != without)
        if let out = ProcessInfo.processInfo.environment["YCODE_PREDICT_SNAPSHOT"] { try withGhost.write(to: URL(fileURLWithPath: out)) }
        // Holding Option shows every line.
        tv.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                               context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        #expect(e.shownPredictionText == "items.count\nprint(total)")
        let expanded = try #require(snapshot(tv))
        #expect(expanded != withGhost)
        if let out = ProcessInfo.processInfo.environment["YCODE_PREDICT_SNAPSHOT"] { try expanded.write(to: URL(fileURLWithPath: out + ".expanded.tiff")) }
        tv.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                               context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
        // Tab accepts the line shown; the rest stays.
        tab(tv)
        #expect(caretText(e) == "let total = items.count|\n")
        #expect(e.predictionSuggestion?.text == "\nprint(total)")
        // Escape dismisses and leaves the text alone.
        escape(tv)
        #expect(e.predictionSuggestion == nil)
        #expect(e.text == "let total = items.count\n")
        #expect(e.isDirty)
    }

    @Test func typingThroughOptionTabAndControlTab() async throws {
        let server = try StandInServer { _, _ in "compute(value: 42)\nreturn" }
        let (e, _) = try editor("Through.swift", "\n", server: server)
        let tv = e.textView
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type("let r = ", into: tv)
        let appeared = await waitFor { e.predictionSuggestion?.text == "compute(value: 42)\nreturn" && !e.predictionSession.isBusy }
        try #require(appeared, state(e, server))
        let requests = server.generationRequests.count
        // Typing what is suggested keeps the rest without a new request.
        type("comp", into: tv)
        #expect(e.predictionSuggestion?.text == "ute(value: 42)\nreturn")
        #expect(e.predictionSuggestion?.anchor == 12)
        // ⌃Tab takes the next word.
        tab(tv, .control)
        #expect(caretText(e) == "let r = compute|\n")
        #expect(e.predictionSuggestion?.text == "(value: 42)\nreturn")
        // ⌥Tab takes all of it.
        tab(tv, .option)
        #expect(caretText(e) == "let r = compute(value: 42)\nreturn|\n")
        #expect(e.predictionSuggestion == nil)
        #expect(server.generationRequests.count == requests)
    }

    @Test func typingSomethingElseAndMovingTheCaretDrop() async throws {
        let server = try StandInServer { _, _ in "abc" }
        let (e, _) = try editor("Drop.swift", "let a = 1\n\n", server: server)
        let tv = e.textView
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        type("x", into: tv)
        let ready1 = await waitFor { e.predictionSuggestion != nil }
        try #require(ready1, state(e, server))
        type("z", into: tv)
        #expect(e.predictionSuggestion == nil || e.predictionSuggestion?.anchor == 12)
        let ready2 = await waitFor { e.predictionSuggestion?.anchor == 12 }
        try #require(ready2, state(e, server))
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(e.predictionSuggestion == nil)
        // Tab without a suggestion indents as before.
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        let before = e.text
        tab(tv)
        #expect(e.text != before)
        // Escape with nothing to dismiss goes up the responder chain (it
        // used to raise "unrecognized selector" from NSTextView's super).
        let indented = e.text
        escape(tv)
        #expect(e.text == indented && e.predictionSuggestion == nil)
    }

    @Test func showPredictiveCompletionAsksMidLineAndOffDoesNothing() async throws {
        let server = try StandInServer { _, _ in "Int" }
        let (e, _) = try editor("Command.swift", "let n: = 1\n", server: server)
        let tv = e.textView
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        // The menu item's action reaches the text view through the responder chain.
        #expect(NSApp.sendAction(NSSelectorFromString("showPredictiveCompletion:"), to: tv, from: nil))
        let ready3 = await waitFor { e.predictionSuggestion != nil }
        try #require(ready3, state(e, server))
        #expect(e.predictionSuggestion == .init(anchor: 7, text: "Int"))
        // Drawn in the middle of a line: the rest of the line moves right.
        let mid = try #require(snapshot(tv))
        if let out = ProcessInfo.processInfo.environment["YCODE_PREDICT_SNAPSHOT"] { try mid.write(to: URL(fileURLWithPath: out + ".mid.tiff")) }
        escape(tv)
        // Switched off: typing asks nothing.
        var s = try #require(e.predictionSettingsOverride)
        s.enabled = false
        e.predictionSettingsOverride = s
        let n = server.generationRequests.count
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        let asked = e.predictionSession.requestCount
        type("x", into: tv)
        // Off: no request is even scheduled (nothing to wait for).
        #expect(!e.predictionSession.isBusy && e.predictionSession.requestCount == asked && e.predictionSuggestion == nil)
        #expect(server.generationRequests.count == n)
    }

    @Test func settingsRowsAndTest() async throws {
        // Its own Preferences on a test-only defaults suite, never installed as
        // Preferences.shared (other suites' editors keep their own settings).
        let defaults = TestDefaults("predict-settings")
        defer { defaults.remove() }
        let p = Preferences(defaults: defaults.defaults, themesDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ycode-predict-themes-\(UUID().uuidString)"))
        let server = try StandInServer { _, _ in "" }
        let pane = TextEditingSettingsPane(prefs: p)
        _ = pane.view
        #expect(pane.rowTitles.contains("Predictive code completion"))
        pane.toggle("Predictive code completion")
        #expect(p.predictiveCompletion.enabled)
        pane.page = .completion
        for row in ["# Predictive Code Completion", "Backend", "Address", "Model", "Test", "Download a model", "Wait after typing (ms)", "Most tokens", "Temperature"] {
            #expect(pane.rowTitles.contains(row), "\(row)")
        }
        #expect(pane.control(NSPopUpButton.self, inRow: "Backend")?.itemTitles == ["Ollama", "llama.cpp server", "OpenAI-compatible server"])
        let address = try #require(pane.control(NSTextField.self, inRow: "Address"))
        #expect(address.placeholderString == "http://127.0.0.1:11434")
        pane.updatePrediction { $0.address = server.baseURL }
        var done = false
        pane.testPrediction { done = true }
        await waitFor { done }
        #expect(pane.predictionMessage == "Ollama is running: 1 of 1 models can fill in the middle.")
        #expect(pane.control(NSPopUpButton.self, inRow: "Model")?.itemTitles == ["Automatic", "stand-in-coder"])
        pane.choose("stand-in-coder", inRow: "Model")
        #expect(p.predictiveCompletion.model == "stand-in-coder")
        pane.choose("llama.cpp server", inRow: "Backend")
        #expect(p.predictiveCompletion.backend == .llamaServer)
        #expect(p.predictiveCompletion.address == nil && p.predictiveCompletion.model.isEmpty)
        #expect(!pane.rowTitles.contains("Download a model"))
        // Nothing at the address: the install line and the link.
        pane.choose("Ollama", inRow: "Backend")
        pane.updatePrediction { $0.address = "http://127.0.0.1:1" }
        done = false
        pane.testPrediction { done = true }
        await waitFor { done }
        #expect(pane.predictionMessage.contains("ollama.com/download"))
        #expect(pane.control(NSButton.self, inRow: "Get Ollama…") != nil)
    }

    @Test func activityNoticeIsQuiet() {
        #expect(WorkspaceWindowController.predictionActivityText(.unavailable(message: "Ollama is not running at http://127.0.0.1:11434.", hint: nil))
                == "Predictive completion: Ollama is not running at http://127.0.0.1:11434.")
        #expect(WorkspaceWindowController.predictionActivityText(.ready(model: "m")) == nil)
        #expect(WorkspaceWindowController.predictionActivityText(.requesting) == nil)
    }

    /// The first lines of the text view as pixels.
    func snapshot(_ v: NSView) -> Data? {
        v.window?.contentView?.layoutSubtreeIfNeeded()
        // An off-screen window may not have sized the text view yet.
        if v.bounds.width < 100 { v.setFrameSize(NSSize(width: 700, height: max(v.bounds.height, 100))) }
        let r = NSRect(x: 0, y: 0, width: max(1, min(v.bounds.width, 600)), height: 80)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        v.cacheDisplay(in: r, to: rep)
        return rep.tiffRepresentation
    }
}
