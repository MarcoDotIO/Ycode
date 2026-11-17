import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_B4EDITOR=<prefix>: the B4-EDITOR items (1.0.0-beta.4,
// `parity-inventory.md`) on the Linux IDE. Open a workspace with a Swift
// file that has `///` doc comments.
//
//   doc-comments    P-054: the file, doc comments in the comment grey
//   find-menu       P-003: the Find menu's in-file items' states
//                   (`b4editor find …`), then Replace through the menu hook:
//                   the find bar with its replace row
//   ribbon          P-059: a press in the ribbon's column on line 3:
//                   `b4editor ribbon` (caret line, breakpoints)
//   pane-below      P-064: Editor Pane On Right, then Below: the right
//                   column holds two panes (`b4editor lanes`)
//   rename-inline   P-084: Rename… with a language server: the edit box on
//                   the identifier, the other occurrences boxed
//
// Each state writes <prefix>-<state>.png.
extension ShellDriver {
    #if os(Linux)
    static func b4EditorWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("b4editor: no workspace"); return }
        func shot(_ state: String, settle: Double = 0.8) async {
            await pause(settle)
            say("b4editor \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state).png"))
        }
        let files = w.root.allFiles.compactMap(\.path).filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Package.swift") }
        let withDocs = files.first { (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("///") == true }
        guard let path = withDocs ?? files.first else { say("b4editor: no Swift file"); return }
        if let ids = w.root.idPath(to: path) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(path)
        await shot("doc-comments", settle: 1.2)

        // P-003: the in-file items through the editor-action hook.
        let items: [(String, Int)] = [("performFindPanelAction:", 5), ("performFindPanelAction:", 4), ("performFindPanelAction:", 6),
                                      ("replaceAndFindPrevious:", 0), ("useSelectionForReplace:", 0), ("hideFindBar:", 0),
                                      ("findSelectedTextInWorkspace:", 0), ("findSelectedWordsInWorkspace:", 0),
                                      ("findAndSelectNext:", 0), ("performFindPanelAction:", 9)]
        for (a, tag) in items {
            let s = w.editorActionState(a, tag: tag)
            say("b4editor find \(a)\(tag == 0 ? "" : " \(tag)") enabled=\(s?.enabled == true)")
        }
        w.perform(.find)
        w.findBar.query = "func"
        w.findBar.refresh()
        _ = w.performEditorAction("performFindPanelAction:", tag: 5)   // Replace: shows the replace row
        w.editor?.buffer.undo()
        await shot("find-menu")
        _ = w.performEditorAction("hideFindBar:")
        say("b4editor find bar hidden=\(!w.findBar.isShown)")

        // P-059: the ribbon's column.
        if let doc = w.editor {
            let c = SourceEditorController.of(doc)
            let p = CGPoint(x: c.gutterWidth - 4, y: c.lineTop(2) - c.top + c.lineHeight / 2)
            c.pointerChanged(start: p, location: p, time: OpenViewsAutomation.now, shift: false)
            c.pointerEnded()
            await pause(0.3)
            let marks = w.debug.marks(for: doc.path)
            say("b4editor ribbon caretLine=\(doc.buffer.caretLine + 1) inRibbon=\(c.isInRibbonColumn(p.x)) breakpoints=\(marks.breakpoints.count)")
            await shot("ribbon")
        }

        // P-064: a column stacked by Editor Pane Below.
        w.perform(.splitEditor)
        await pause(0.4)
        w.perform(.splitEditorBelow)
        await pause(0.4)
        say("b4editor lanes \(w.panes.panes.map(\.lane)) sideBySide=\(w.panes.sideBySide) groups=\(w.panes.laneGroups.map(\.panes.count))")
        await shot("pane-below")
        while w.panes.isSplit, let last = w.panes.panes.last { w.closePane(last.id) }

        // P-084: rename in place (needs the language server).
        w.open(path)
        if let b = w.editor?.buffer, let r = b.text.range(of: "func ") {
            b.setCaret(b.text.utf16.distance(from: b.text.utf16.startIndex, to: r.upperBound.samePosition(in: b.text.utf16) ?? b.text.utf16.startIndex) + 1)
        }
        w.perform(.renameSymbol)
        for _ in 0..<40 where w.languageFeatures.rename == nil { await pause(0.25) }
        say("b4editor rename request=\(w.languageFeatures.rename != nil) highlights=\(w.languageFeatures.highlights.count)")
        await shot("rename-inline", settle: 1.0)
        w.cancelRename()
    }
    #endif
}
