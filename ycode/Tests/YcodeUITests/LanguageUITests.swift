import AppKit
import Foundation
import Testing
import YcodeLanguage
@testable import YcodeUI

@MainActor
@Suite struct CompletionModelTests {
    @Test func filtersAndMoves() {
        var m = CompletionModel()
        let items = ["greet(times:)", "name", "Greeter", "regret"].map { CompletionItem(label: $0, insertText: $0) }
        m.reset(items: items, wordStart: 4, prefix: "gre")
        #expect(m.visible.map(\.label) == ["greet(times:)", "Greeter", "regret"])
        m.move(5)
        #expect(m.current?.label == "regret")
        m.filter("")
        #expect(m.visible.count == 4 && m.selected == 0)
        #expect(CompletionModel.wordStart(in: "print(g.gr", before: 10) == 8)
        let idx = LineIndex("ab\ncde\n")
        #expect(idx.position(at: 5) == Position(line: 1, character: 2))
        #expect(idx.offset(of: Position(line: 1, character: 99)) == 6)
    }

    @Test func popupHeightAndDocLine() {
        let popup = CompletionPopupView(frame: .zero)
        var doc = CompletionItem(label: "greet(times:)", insertText: "greet(times:)")
        doc.documentation = "Returns the greeting."
        var m = CompletionModel()
        m.reset(items: [CompletionItem(label: "name", insertText: "name"), doc], wordStart: 0, prefix: "")
        popup.model = m
        #expect(!popup.hasDoc)
        #expect(CompletionPopupView.height(rows: 2, hasDoc: false) == 46)
        m.move(1)
        popup.model = m
        #expect(popup.hasDoc)
        #expect(CompletionPopupView.height(rows: 20, hasDoc: true) == CGFloat(188))
    }

    @Test func liveIssueConversion() {
        let d = LSPDiagnostic(["range": ["start": ["line": 15, "character": 6], "end": ["line": 15, "character": 13]],
                               "severity": 1, "message": "cannot find 'missing' in scope"])
        let hint = LSPDiagnostic(["severity": 4, "message": "hint"])
        let issues = LanguageService.issues(file: "/a.swift", [d, hint])
        #expect(issues.count == 1)
        #expect(issues[0].location == .init(file: "/a.swift", line: 16, column: 7))
    }
}

/// The editor against the real sourcekit-lsp: live issues, the completion
/// popup, and jump to definition (headless).
@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(3))) struct LanguageWindowTests {
    @Test func liveIssuesCompletionAndDefinition() async throws {
        guard SourceKitLSP.locate() != nil else { return }
        _ = NSApplication.shared
        let snapshots = WindowSnapshotTests()
        let dir = try snapshots.samplePackage()
        let main = dir.appendingPathComponent("Sources/Sample/main.swift").path
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        let window = try #require(wc.window)
        window.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        await wc.connectLanguageService(transport: nil)
        #expect(session.language != nil)

        // Live issue without building.
        #expect(await waitUntil(90) { session.displayedIssues.contains { $0.message.contains("missing") } })
        #expect(wc.editor.textView.issues[16]?.first?.severity == .error)
        #expect(wc.navigator.rows(4).first?.children.first?.children.contains { $0.title.contains("missing") } == true)

        // Completion after `g.` (line 15, `print(g.greet…`): place the caret
        // after `g.` and type `gr`.
        let line15 = wc.editor.textView.lineIndex.range(ofLine: 15)!
        let afterDot = line15.location + ("print(g." as NSString).length
        wc.editor.textView.setSelectedRange(NSRange(location: afterDot, length: 0))
        wc.editor.requestCompletion()
        #expect(await waitUntil(60) { wc.editor.isShowingCompletions })
        #expect(wc.editor.completions.visible.contains { $0.label.hasPrefix("greet(times:") })
        // The popup sits just below the caret line, its label column at the word.
        let caret = try #require(wc.editor.textView.caretRect(at: afterDot))
        let popup = wc.editor.completionFrameInText
        #expect(abs(popup.minY - (caret.maxY + 2)) < 0.5)
        #expect(popup.minX < caret.minX && caret.minX - popup.minX < 40)
        #expect(popup.height == CompletionPopupView.height(rows: wc.editor.completions.visible.count,
                                                           hasDoc: wc.editor.completionPopup.hasDoc))
        wc.editor.textView.insertText("na", replacementRange: wc.editor.textView.selectedRange())
        #expect(wc.editor.completions.visible.first?.label == "name")
        #expect(abs(wc.editor.completionFrameInText.minY - (caret.maxY + 2)) < 0.5)
        #expect(wc.editor.completionPopup.frame.height == CompletionPopupView.height(rows: wc.editor.completions.visible.count,
                                                                                     hasDoc: wc.editor.completionPopup.hasDoc))
        _ = try snapshots.render(window.contentView!.superview!, to: "completion-popup.png")
        wc.editor.acceptCompletion()
        #expect(!wc.editor.isShowingCompletions)
        #expect(wc.editor.text.contains("print(g.namegreet(times: 3))"))

        // Jump to Definition on `Greeter` in line 14 goes to line 2.
        let line14 = wc.editor.textView.lineIndex.range(ofLine: 14)!
        wc.editor.textView.setSelectedRange(NSRange(location: line14.location + 10, length: 0))
        wc.jumpToDefinition(nil)
        #expect(await waitUntil(30) { wc.editor.currentLine == 2 })
        #expect(wc.editor.caretPosition == Position(line: 1, character: 7))
        await session.language?.stop()
    }
}
