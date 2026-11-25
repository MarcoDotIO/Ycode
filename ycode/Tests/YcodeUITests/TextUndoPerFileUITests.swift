import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// B5-FIX-UNDO (`specs/ide/source-editor.md`, "Text undo belongs to the
/// file"): each open file has its own text undo history. ⌘Z after a file
/// switch never changes the other file; switching back undoes the file's
/// own edit; a reload after a change on disk and closing the file's last
/// editor clear it; saving keeps it; two editors on one file share it; the
/// navigator's and Find's Replace All undo keep the window's history. The
/// files are the temporary sample of `ProjectNavigatorOperationsTests`.
/// Offscreen windows only.
@MainActor
@Suite(.serialized) struct TextUndoPerFileUITests {
    typealias Ops = ProjectNavigatorOperationsTests
    static let readme = "0B0000000000000000000003"

    /// Ends the run loop's undo group (each user action is its own event).
    func endEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Types `s` at the end of the first line, as one event.
    func type(_ s: String, in e: SourceEditorController, at offset: Int? = nil) {
        let tv = e.textView
        let at = offset ?? ((e.text as NSString).range(of: "\n").location)
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.insertText(s, replacementRange: tv.selectedRange())
        endEvent()
    }

    /// Edit ▸ Undo (⌘Z) with the editor's text focused: `undo:` up the
    /// responder chain from the text view.
    @discardableResult
    func commandZ(_ wc: WorkspaceWindowController, _ e: SourceEditorController) -> Bool {
        wc.window?.makeFirstResponder(e.textView)
        let done = e.textView.tryToPerform(Selector(("undo:")), with: nil)
        endEvent()
        return done
    }

    func undoItemEnabled(_ e: SourceEditorController) -> Bool {
        e.textView.undoManager?.canUndo == true
    }

    func disk(_ s: Ops.Sample, _ rel: String) -> String { (try? String(contentsOfFile: s.path(rel), encoding: .utf8)) ?? "" }

    func window() throws -> (Ops.Sample, WorkspaceWindowController) {
        try #require(YcodeOffscreenIsActive(), "the offscreen guard is not installed: no window is made")
        let s = try Ops.Sample()
        let wc = try s.window()
        return (s, wc)
    }

    @Test func switchingFilesKeepsEachFilesHistory() throws {
        let (s, wc) = try window()
        defer { s.remove() }
        let a = s.path("Nav/Model.swift"), b = s.path("Nav/Helpers.swift")
        let aText = disk(s, "Nav/Model.swift"), bText = disk(s, "Nav/Helpers.swift")
        wc.open(path: a, line: nil)
        let e = wc.editor
        type(" // edited", in: e)
        let edited = e.text
        #expect(edited != aText && undoItemEnabled(e))
        #expect(e.textView.undoManager?.undoActionName == "Typing")
        // Switch to B: A's edit is saved; B has no edits, so Undo is disabled.
        wc.open(path: b, line: nil)
        #expect(disk(s, "Nav/Model.swift") == edited)
        #expect(!undoItemEnabled(e))
        #expect(e.textView.undoManager !== wc.window?.undoManager)
        commandZ(wc, e)
        #expect(e.text == bText && disk(s, "Nav/Helpers.swift") == bText)
        #expect(disk(s, "Nav/Model.swift") == edited)
        // B's own edit is B's alone.
        type(" // b", in: e)
        let bEdited = e.text
        // Back to A: ⌘Z undoes A's edit, and only it.
        wc.open(path: a, line: nil)
        #expect(undoItemEnabled(e) && e.textView.undoManager?.undoActionName == "Typing")
        #expect(commandZ(wc, e))
        #expect(e.text == aText)
        #expect(disk(s, "Nav/Helpers.swift") == bEdited)
        #expect(!undoItemEnabled(e) && e.textView.undoManager?.canRedo == true)
        // Saving does not clear the history.
        type(" // again", in: e)
        try e.save()
        #expect(undoItemEnabled(e))
        // B's history is still B's: back there, ⌘Z takes its edit back.
        wc.open(path: b, line: nil)
        #expect(commandZ(wc, e))
        #expect(e.text == bText)
        // Go Back / Go Forward keep the histories too.
        wc.goBack(nil)
        #expect(e.fileURL?.path == a && undoItemEnabled(e))
    }

    @Test func aReloadAfterAChangeOnDiskAndClosingClearTheHistory() throws {
        let (s, wc) = try window()
        defer { s.remove() }
        let a = s.path("Nav/Model.swift"), b = s.path("Nav/Helpers.swift")
        wc.open(path: a, line: nil)
        let e = wc.editor
        type(" // edited", in: e)
        try e.save()
        #expect(undoItemEnabled(e))
        // Another program rewrites A: the unedited editor follows and its history goes.
        try "struct Model {\n    var value = 2\n}\n".write(toFile: a, atomically: true, encoding: .utf8)
        #expect(e.followDiskIfUnedited())
        #expect(e.text.contains("value = 2") && !undoItemEnabled(e))
        // Changed on disk while another file is shown: no history on return.
        type(" // second", in: e)
        wc.open(path: b, line: nil)
        try "struct Model {\n    var value = 3\n}\n".write(toFile: a, atomically: true, encoding: .utf8)
        wc.open(path: a, line: nil)
        #expect(e.text.contains("value = 3") && !undoItemEnabled(e))
        // File ▸ Close "Model.swift" ends the history; reopening starts empty.
        type(" // third", in: e)
        #expect(undoItemEnabled(e))
        wc.closeDocument(nil)
        #expect(!wc.editorArea.textUndo.paths.contains(URL(fileURLWithPath: a).standardizedFileURL.path))
        wc.open(path: a, line: nil)
        #expect(e.text.contains("// third") && !undoItemEnabled(e))
    }

    @Test func twoEditorsOnOneFileShareItsTextAndHistory() throws {
        let (s, wc) = try window()
        defer { s.remove() }
        let a = s.path("Nav/Model.swift"), b = s.path("Nav/Helpers.swift")
        let aText = disk(s, "Nav/Model.swift")
        wc.open(path: a, line: nil)
        let first = wc.editor
        type(" // one", in: first)
        wc.splitEditor(nil)
        let second = wc.editor
        #expect(second !== first && second.fileURL?.path == a)
        // The new pane shows the first pane's text (unsaved too) and its history.
        #expect(second.text == first.text)
        #expect(second.textView.undoManager === first.textView.undoManager)
        type(" // two", in: second, at: (second.text as NSString).length)
        #expect(first.text == second.text && first.text.hasSuffix(" // two"))
        // ⌘Z in either pane undoes the file's last edit, in both.
        #expect(commandZ(wc, first))
        #expect(first.text == second.text && !first.text.contains("// two"))
        #expect(commandZ(wc, second))
        #expect(first.text == aText && second.text == aText)
        // A pane that only showed the file shows another one: its history
        // is its own, and the file keeps its history in the other pane.
        wc.editorArea.focus(first)
        wc.splitEditor(nil)
        let third = wc.editor
        #expect(third.fileURL?.path == a)
        type(" // three", in: first)
        wc.open(path: b, line: nil, in: third)
        #expect(third.fileURL?.path == b && !undoItemEnabled(third))
        #expect(first.fileURL?.path == a && undoItemEnabled(first))
        #expect(commandZ(wc, first))
        #expect(first.text == aText && second.text == aText && third.text == disk(s, "Nav/Helpers.swift"))
        // A pane that made entries of the file shows another one: an entry
        // applies to the text of the editor that made it, so the file's
        // history goes with that pane (its text stays).
        type(" // four", in: second)
        wc.open(path: b, line: nil, in: second)
        #expect(second.fileURL?.path == b && !undoItemEnabled(second))
        #expect(first.text.contains(" // four") && !undoItemEnabled(first))
    }

    @Test func theNavigatorKeepsTheWindowsHistoryAndADragMoveKeepsTheFiles() throws {
        let (s, wc) = try window()
        defer { s.remove() }
        let window = try #require(wc.window)
        let um = try #require(window.undoManager)
        wc.open(path: s.path("README.md"), line: nil)
        let e = wc.editor
        type(" edited", in: e)
        // The text edit is not the window's: the navigator's undo is untouched.
        #expect(!um.canUndo)
        Ops().select(wc, ids: [Ops.model])
        #expect(wc.newNavigatorGroup(withFolder: true) != nil)
        endEvent()
        #expect(um.undoActionName == "New Group")
        window.makeFirstResponder(wc.navigator.outlineView)
        #expect(wc.navigator.outlineView.undoManager === um)
        um.undo()
        endEvent()
        #expect(!s.exists("Nav/New Group") && e.text.contains(" edited"))
        // Edit README, show Model, then drag README into the Nav group: the
        // moved file opens and ⌘Z undoes README's edit.
        wc.open(path: s.path("Nav/Model.swift"), line: nil)
        endEvent()
        let readme = try #require(Ops().row(wc, id: Self.readme))
        let nav = try #require(Ops().row(wc, id: Ops.navGroup))
        _ = try #require(wc.moveNavigatorRows([readme], to: nav, at: 0))
        #expect(e.fileURL?.standardizedFileURL.path == s.path("Nav/README.md"))
        #expect(undoItemEnabled(e))
        #expect(commandZ(wc, e))
        #expect(e.text == "# Nav\n")
        #expect(!um.canUndo)   // the move itself is not undone (P-042)
    }

    @Test func findsReplaceAllUndoStaysOneWindowStep() throws {
        let (s, wc) = try window()
        defer { s.remove() }
        let um = try #require(wc.window?.undoManager)
        let a = s.path("Nav/Model.swift")
        wc.open(path: a, line: nil)
        let e = wc.editor
        // The find bar's Replace All is an entry of the file.
        e.showFindBar(replace: true)
        e.setFind("value", replacement: "count")
        e.replaceAll()
        endEvent()
        #expect(e.text.contains("var count = 1"))
        #expect(e.textView.undoManager?.canUndo == true && !um.canUndo)
        commandZ(wc, e)
        #expect(e.text.contains("var value = 1"))
        e.hideFindBar()
        // The Find navigator's Replace All: one step of the window's history
        // for the open editor and the files on disk.
        let nav = wc.navigator
        wc.findAndReplaceInWorkspace(nil)
        nav.setFindOptions(match: FindQuery.Match.matchingWord.rawValue)
        nav.find("Model")
        nav.findReplaceField.stringValue = "Thing"
        nav.replacementChanged()
        let t = try #require(nav.replaceAllFindMatches())
        endEvent()
        #expect(t.changes.count >= 2)
        #expect(e.text.contains("struct Thing") && um.canUndo)
        um.undo()
        endEvent()
        #expect(e.text.contains("struct Model"))
        #expect(disk(s, "Nav/main.swift").contains("Model().value"))
        // The editor's own history has the replace too, as an entry of the file.
        #expect(e.textView.undoManager?.canUndo == true)
    }

    @Test func screenshots() throws {
        let (s, wc) = try window()
        defer { s.remove() }
        let window = try #require(wc.window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        wc.open(path: s.path("Nav/Model.swift"), line: nil)
        type(" // edited in Model", in: wc.editor)
        NavigatorDragMoveUITests().shot(wc, "fixundo-1-model-edited.png")
        wc.open(path: s.path("Nav/Helpers.swift"), line: nil)
        commandZ(wc, wc.editor)
        NavigatorDragMoveUITests().shot(wc, "fixundo-2-helpers-after-cmd-z.png")
        wc.open(path: s.path("Nav/Model.swift"), line: nil)
        commandZ(wc, wc.editor)
        NavigatorDragMoveUITests().shot(wc, "fixundo-3-model-after-cmd-z.png")
        #expect(!wc.editor.text.contains("edited in Model"))
    }
}
