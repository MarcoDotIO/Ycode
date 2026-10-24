import AppKit
import Foundation
import Testing
@testable import YcodeUI

@Suite struct EditorFindTests {
    @Test func matchesStepsAndReplaces() {
        var f = EditorFind()
        f.query = "ab"
        f.update(text: "ab xab AB", from: 2)
        #expect(f.matches == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2), NSRange(location: 7, length: 2)])
        #expect(f.current == 1) // first match at or after the caret
        f.step(true); f.step(true)
        #expect(f.current == 0) // wraps
        f.step(false)
        #expect(f.current == 2)
        f.options.wholeWord = true
        f.update(text: "ab xab AB")
        #expect(f.matches.count == 2)
        f.options = .init(regularExpression: true, ignoreCase: false)
        f.query = "(\\w)b"
        f.replacement = "<$1>"
        f.update(text: "ab xab AB")
        #expect(f.replacingAll(in: "ab xab AB").0 == "<a> x<a> AB")
        #expect(f.replacementText(in: "ab xab AB", range: NSRange(location: 4, length: 2)) == "<a>")
        // Text mode treats `$` literally in the replacement.
        var t = EditorFind()
        t.query = "a"
        t.replacement = "$1"
        #expect(t.replacingAll(in: "aa").0 == "$1$1")
    }
}

@MainActor
@Suite(.serialized) struct FindBarTests {
    @Test func findBarInEditor() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        let ed = wc.editor
        #expect(ed.performFind(tag: 1) && ed.isShowingFindBar)
        ed.setFind("lines")
        #expect(ed.find.matches.count == 3)
        #expect(ed.findBar.countLabel.stringValue.hasSuffix("of 3"))
        #expect(ed.textView.findMatches.count == 3)
        ed.findStep(forward: true)
        let sel = ed.textView.selectedRange()
        #expect((ed.text as NSString).substring(with: sel) == "lines")
        #expect(!ed.textView.segmentRects(sel).isEmpty)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "editor-find-bar.png")

        // ⌘E: the selection becomes the query.
        let g = (ed.text as NSString).range(of: "Greeter")
        ed.textView.setSelectedRange(g)
        ed.performFind(tag: 7)
        #expect(ed.findBar.queryField.stringValue == "Greeter" && ed.find.matches.count == 2)

        // Find and Replace.
        ed.performFind(tag: 12)
        ed.setFind("Greeter", replacement: "Welcomer")
        ed.replaceAll()
        #expect(!ed.text.contains("Greeter") && ed.text.components(separatedBy: "Welcomer").count == 3)
        ed.hideFindBar()
        #expect(!ed.isShowingFindBar && ed.textView.findMatches.isEmpty)
    }
}
