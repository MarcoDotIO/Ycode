import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodeProject

/// B5-FIX-NAV (P-042, `specs/ide/navigators.md` "A drag move and ⌘Z") on
/// Linux: after a drag move the moved file is open with the editor focused,
/// and Ctrl+Z leaves the move in place.
@MainActor
@Suite(.serialized) struct NavigatorDragMoveShellTests {
    typealias S = ShellNavigatorSample

    @Test func dragMoveOpensTheFileAndIsNotUndone() throws {
        let s = try S()
        defer { s.remove() }
        s.select("main.swift")
        #expect(s.model.document?.path.hasSuffix("Nav/main.swift") == true)
        let focus0 = s.model.editorFocusCount
        // README.md (in the main group's folder) onto Nav.
        let readme = try #require(s.row("README.md"))
        let nav = try #require(s.row("Nav"))
        let edit = try #require(s.model.moveNavigatorRows([readme], to: nav, at: 0))
        #expect(edit.actionName == "Move")
        #expect(s.exists("Nav/README.md") && !s.exists("README.md"))
        // The moved file is open, its row selected, the editor focused.
        #expect(s.model.document?.path == s.path("Nav/README.md"))
        #expect(s.model.selection.flatMap { s.model.root.find(id: $0)?.path } == s.path("Nav/README.md"))
        #expect(s.model.editorFocusCount > focus0)
        // Ctrl+Z (the navigator's undo) and nothing to undo: the move stays.
        #expect(s.model.navigatorUndoTitle == nil)
        let after = s.written
        #expect(!s.model.undoNavigatorEdit())
        #expect(s.written == after && s.exists("Nav/README.md"))
        #expect(s.model.navigatorState.lastError == nil)
        #expect(s.model.document?.path == s.path("Nav/README.md"))
    }

    @Test func earlierEntriesOfTheProjectGoAndOtherMovesKeepTheirUndo() throws {
        let s = try S()
        defer { s.remove() }
        // A New Group before the drag: its undo can no longer apply, so it goes
        // (no "The project changed since" refusal).
        s.select("Nav")
        #expect(s.model.newNavigatorGroup(withFolder: true) != nil)
        #expect(s.model.navigatorUndoTitle == "Undo New Group")
        let helpers = try #require(s.row("Helpers.swift"))
        let nav = try #require(s.row("Nav"))
        #expect(s.model.moveNavigatorRows([helpers], to: nav) != nil)
        #expect(s.model.navigatorUndoTitle == nil && s.model.navigatorRedoTitle == nil)
        #expect(!s.model.undoNavigatorEdit())
        #expect(s.model.navigatorState.lastError == nil)
        // Edit ▸ Paste ▸ Move Item Here keeps its undo (OPEN in the spec).
        s.select("Model.swift")
        s.model.cutNavigatorSelection()
        s.select("Support")
        #expect(s.model.moveCutNavigatorItemsHere() != nil)
        #expect(s.model.navigatorUndoTitle == "Undo Move")
        let beforeUndo = s.written
        #expect(s.model.undoNavigatorEdit())
        #expect(s.written != beforeUndo)
    }

    @Test func aDraggedGroupOpensNoFile() throws {
        let s = try S()
        defer { s.remove() }
        s.select("main.swift")
        let support = try #require(s.row("Support"))
        let nav = try #require(s.row("Nav"))
        #expect(s.model.moveNavigatorRows([support], to: nav) != nil)
        // Only a group moved: the editor keeps its file.
        #expect(s.model.document?.path == s.path("Nav/main.swift"))
        #expect(s.model.navigatorUndoTitle == nil)
    }
}
