import Foundation
import YcodeIDECore

/// A drag move in the project navigator and Ctrl+Z (P-042,
/// `specs/ide/navigators.md` "A drag move and ⌘Z"; the owner's decision of
/// 2026-11-21: match the reference), as the macOS window's
/// `WorkspaceWindowController+NavigatorDragMove`. After a drop that moves
/// rows, the topmost moved file opens in the editor and the editor takes
/// keyboard focus (the moved rows stay selected). The move is not put on
/// the undo stack, so Ctrl+Z leaves it in place. The project's earlier
/// navigator undo and redo entries can no longer apply (an undo is refused
/// once the project changed since), so they are dropped with it. Moves made
/// another way (Edit ▸ Paste ▸ Move Item Here) and the other file
/// operations keep their undo.
extension WorkspaceShellModel {
    func finishNavigatorDragMove(_ edit: ProjectEdit, project: String?) {
        navigatorState.undoStack.removeAll { $0.project == project }
        navigatorState.redoStack.removeAll { $0.project == project }
        navigatorState.undoRevision += 1
        let file = selectedProjectRowIDs.lazy.compactMap { self.root.find(id: $0) }.first { $0.isFile && $0.path != nil }
        guard let path = file?.path else { return }
        open(path)   // shows the file and focuses the editor
        focusEditor()
    }
}
