import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

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
