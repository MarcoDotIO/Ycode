import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_B5EDITOR2=<prefix>: the B5-EDITOR2 items (1.0.0-beta.5,
// `parity-inventory.md`) on the Linux IDE. Open a workspace with a Swift
// file that has `///` doc comments and indented blocks.
//
//   doc-light, doc-dark   P-054: the file, doc comment text in the
//                         proportional face (`b5editor2 doc …` prints the
//                         x of the comment's end, proportional and on the grid)
//   guides                P-065: Scope Guides and Invisibles on
//   no-editor             P-066: Editor Pane On Right, then Close "<file>":
//                         the emptied pane's "No Editor" (`b5editor2 no-editor …`)
//   options               P-065: Editor Options' items and their states
//                         (`b5editor2 option …`)
//
// Each state writes <prefix>-<state>.png.
extension ShellDriver {
    #if os(Linux)
    static func b5Editor2Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("b5editor2: no workspace"); return }
        func shot(_ state: String, settle: Double = 0.8) async {
            await pause(settle)
            say("b5editor2 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let files = w.root.allFiles.compactMap(\.path).filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Package.swift") }
        let withDocs = files.first { (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("///") == true }
        guard let path = withDocs ?? files.first else { say("b5editor2: no Swift file"); return }
        if let ids = w.root.idPath(to: path) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(path)
        let prefs = Preferences.shared
        let saved = (prefs.appearance, prefs.showInvisibles, prefs.scopeGuides)
        defer { (prefs.appearance, prefs.showInvisibles, prefs.scopeGuides) = saved }

        // P-054: the doc comment's text off the grid, in light and dark.
        for mode in [Preferences.Appearance.light, .dark] {
            prefs.appearance = mode
            await shot("doc-\(mode == .dark ? "dark" : "light")", settle: 1.2)
        }
        prefs.appearance = .light
        if let doc = w.editor {
            let c = SourceEditorController.of(doc)
            let d = doc.buffer.document
            for n in 0..<d.lineCount where !c.layout.proportionalRanges(line: n, in: doc.buffer).isEmpty {
                let r = d.lineRange(n)
                let end = c.layout.x(ofOffset: r.upperBound, line: n, in: doc.buffer)
                say("b5editor2 doc line \(n + 1) end x=\(end) grid=\(CGFloat(r.count) * c.layout.advance) runs=\(c.layout.displayLine(n, in: doc.buffer).runs.map { "\($0.proportional ? "P" : "G")\($0.text.count)" })")
                break
            }
        }

        // P-065: Scope Guides and Invisibles.
        prefs.scopeGuides = .lines
        prefs.showInvisibles = true
        await shot("guides")
        prefs.scopeGuides = .none
        prefs.showInvisibles = false

        // P-066: Close "<file>" in a split empties only the focused pane,
        // which says "No Editor" and keeps its half.
        w.perform(.splitEditor)
        await pause(0.5)
        w.perform(.closeDocument)
        await pause(0.5)
        say("b5editor2 no-editor panes=\(w.panes.panes.count) focusedDocument=\(w.document?.path ?? "-") placeholder=\(frame("no editor").map { "\($0)" } ?? "-") panesFrames=\(w.panes.panes.map { frame("editor pane \($0.id)").map { "\($0.width)" } ?? "-" })")
        await shot("no-editor")
        while w.panes.isSplit, let last = w.panes.panes.last { w.closePane(last.id) }
        w.open(path)
        await pause(0.4)

        // P-065: the items' states (EditorOptionsMenu.swift).
        say("b5editor2 option Code Coverage enabled=true on=\(prefs.showCodeCoverage)")
        say("b5editor2 option Invisibles enabled=true on=\(prefs.showInvisibles)")
        say("b5editor2 option Scope Guides enabled=true on=\(prefs.scopeGuides != .none)")
        say("b5editor2 option Choose Workspace Theme… enabled=true")
        say("b5editor2 option Authors enabled=false (no blame column on Linux)")
        say("b5editor2 option Inline/Side By Side Comparison enabled=false (no Code Review on Linux)")
        await click("tb editor options")
        await shot("options")
        OpenViewsAutomation.press(.escape)
    }
    #endif
}
