import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

@MainActor
@Suite(.serialized) struct FoldingTests {
    @Test func foldingHidesLines() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        let ed = wc.editor
        #expect(ed.foldRegions.map(\.startLine) == [2, 5, 7])
        func shown() -> [Int] { ed.gutter.visibleLines().map(\.line) }
        #expect(shown() == Array(1...16))

        // ⌥⌘← on line 6 folds the function (lines 6–10 hidden).
        ed.reveal(line: 6)
        ed.fold(nil)
        #expect(ed.hiddenLines == Set(6...10))
        #expect(shown() == [1, 2, 3, 4, 5, 11, 12, 13, 14, 15, 16])
        #expect(ed.gutter.foldStarts[5] == true && ed.gutter.foldStarts[2] == false)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "editor-folded.png")

        // The ribbon toggles the struct; Unfold All restores everything.
        ed.toggleFold(at: 2)
        #expect(shown() == [1, 2, 12, 13, 14, 15, 16])
        ed.unfold(nil) // insertion point is inside both
        #expect(ed.hiddenLines.isEmpty && shown() == Array(1...16))
        ed.foldAll(nil)
        #expect(shown() == [1, 2, 12, 13, 14, 15, 16])
        ed.unfoldAll(nil)
        #expect(shown() == Array(1...16))
        // Folding never changes the text.
        #expect(ed.text.components(separatedBy: "\n").count == 16)
    }
}
