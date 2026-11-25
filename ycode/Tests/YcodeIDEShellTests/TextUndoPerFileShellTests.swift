import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodeEditorKit

/// B5-FIX-UNDO on Linux (`specs/ide/source-editor.md`, "Text undo belongs
/// to the file"): each open file keeps its own buffer and undo history.
/// Ctrl+Z after a file switch acts only on the file shown; switching back
/// undoes the file's own edit; a reload after a change on disk and File ▸
/// Close Document clear it; saving keeps it; panes on one file share it; a
/// navigator move keeps it; the navigator's undo is its own. The files are
/// the temporary sample of `NavigatorFileOperationsShellTests`.
@MainActor
@Suite(.serialized) struct TextUndoPerFileShellTests {
    typealias S = ShellNavigatorSample

    func disk(_ s: S, _ rel: String) -> String { (try? String(contentsOfFile: s.path(rel), encoding: .utf8)) ?? "" }

    /// Types at the end of the first line, as one undo step.
    func type(_ text: String, in m: WorkspaceShellModel) throws {
        let b = try #require(m.editor?.buffer)
        b.setCaret((b.text as NSString).range(of: "\n").location)
        b.insertText(text)
        b.breakUndoGroup()
    }

    /// Ctrl+Z in the editor: the shown file's buffer.
    func controlZ(_ m: WorkspaceShellModel) { m.editor?.buffer.undo() }

    @Test func switchingFilesKeepsEachFilesHistory() throws {
        let s = try S()
        defer { s.remove() }
        let m = s.model
        let a = s.path("Nav/Model.swift"), b = s.path("Nav/Helpers.swift")
        let aText = disk(s, "Nav/Model.swift"), bText = disk(s, "Nav/Helpers.swift")
        m.open(a)
        try type(" // edited", in: m)
        let edited = try #require(m.editor?.buffer.text)
        // B has no edits: Undo is disabled, Ctrl+Z changes neither file.
        m.open(b)
        #expect(m.editor?.path == b && m.editor?.buffer.canUndo == false)
        controlZ(m)
        #expect(m.editor?.buffer.text == bText && disk(s, "Nav/Helpers.swift") == bText)
        #expect(disk(s, "Nav/Model.swift") == aText)   // A's edit is unsaved, not undone
        try type(" // b", in: m)
        // Back to A: Ctrl+Z undoes A's edit, and only it.
        m.open(a)
        #expect(m.editor?.buffer.text == edited && m.editor?.buffer.canUndo == true)
        controlZ(m)
        #expect(m.editor?.buffer.text == aText)
        m.goBack()
        #expect(m.editor?.path == b && m.editor?.buffer.text.contains(" // b") == true)
        // Saving does not clear the history.
        m.perform(.save)
        #expect(m.editor?.buffer.canUndo == true)
        controlZ(m)
        #expect(m.editor?.buffer.text == bText)
    }

    @Test func aReloadAfterAChangeOnDiskAndClosingClearTheHistory() throws {
        let s = try S()
        defer { s.remove() }
        let m = s.model
        let a = s.path("Nav/Model.swift"), b = s.path("Nav/Helpers.swift")
        m.open(a)
        try type(" // edited", in: m)
        m.perform(.save)
        #expect(m.editor?.buffer.canUndo == true)
        // Another program rewrites A: the unedited buffer follows, its history goes.
        try "struct Model {\n    var value = 2\n}\n".write(toFile: a, atomically: true, encoding: .utf8)
        m.checkOpenFilesOnDisk()
        #expect(m.editor?.buffer.text.contains("value = 2") == true && m.editor?.buffer.canUndo == false)
        // Changed on disk while B is shown: no history back in A.
        try type(" // second", in: m)
        m.perform(.save)
        m.open(b)
        try "struct Model {\n    var value = 3\n}\n".write(toFile: a, atomically: true, encoding: .utf8)
        m.checkOpenFilesOnDisk()
        m.open(a)
        #expect(m.editor?.buffer.text.contains("value = 3") == true && m.editor?.buffer.canUndo == false)
        // File ▸ Close Document ends the history; reopening starts empty.
        try type(" // third", in: m)
        m.perform(.save)
        m.closeCurrentDocument()
        m.open(a)
        #expect(m.editor?.buffer.text.contains("// third") == true && m.editor?.buffer.canUndo == false)
    }

    @Test func panesOnOneFileShareItsHistory() throws {
        let s = try S()
        defer { s.remove() }
        let m = s.model
        let a = s.path("Nav/Model.swift"), b = s.path("Nav/Helpers.swift")
        let aText = disk(s, "Nav/Model.swift")
        m.open(a)
        try type(" // one", in: m)
        let first = m.panes.focusedPane.id
        m.splitEditor(sideBySide: true)
        let second = m.panes.focusedPane.id
        #expect(first != second && m.panes.focusedPane.path == a)
        guard case .text(let shown)? = m.panes.panes.first(where: { $0.id == first }).map({ m.content(of: $0) }) else {
            Issue.record("the first pane shows no text")
            return
        }
        #expect(shown === m.editor)
        try type(" // two", in: m)
        // Ctrl+Z in the first pane undoes the second pane's edit, then its own.
        m.focusPane(first)
        controlZ(m)
        controlZ(m)
        #expect(m.editor?.buffer.text == aText)
        // The second pane shows B: its history is B's.
        m.focusPane(second)
        m.open(b)
        #expect(m.editor?.buffer.canUndo == false)
        m.focusPane(first)
        #expect(m.editor?.path == a && m.editor?.buffer.canRedo == true)
    }

    @Test func aNavigatorMoveKeepsTheHistoryAndTheNavigatorUndoIsItsOwn() throws {
        let s = try S()
        defer { s.remove() }
        let m = s.model
        m.open(s.path("README.md"))
        try type(" edited", in: m)
        m.perform(.save)
        // The text edit is not the navigator's.
        #expect(m.navigatorUndoTitle == nil)
        s.select("Nav")
        #expect(m.newNavigatorGroup(withFolder: true) != nil)
        #expect(m.navigatorUndoTitle == "Undo New Group")
        #expect(m.undoNavigatorEdit())
        #expect(m.openDocuments[s.path("README.md")]?.buffer.canUndo == true)
        // Drag README into Nav while Model is shown: the moved file opens and
        // Ctrl+Z undoes its edit.
        m.open(s.path("Nav/Model.swift"))
        let readme = try #require(s.row("README.md"))
        let nav = try #require(s.row("Nav"))
        #expect(m.moveNavigatorRows([readme], to: nav, at: 0) != nil)
        #expect(m.editor?.path == s.path("Nav/README.md") && m.editor?.buffer.canUndo == true)
        controlZ(m)
        #expect(m.editor?.buffer.text == "# Nav\n")
        #expect(m.editedPaths == [s.path("Nav/README.md")])
        #expect(m.navigatorUndoTitle == nil)   // the move itself is not undone (P-042)
    }
}
