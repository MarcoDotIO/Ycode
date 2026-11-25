import AppKit
import ObjectiveC
import YcodeIDECore

/// A drag move in the project navigator and ⌘Z (P-042, `specs/ide/navigators.md`
/// "A drag move and ⌘Z"; the owner's decision of 2026-11-21: match the
/// reference). After a drop that moves rows, the topmost moved file opens in
/// the editor and the editor takes keyboard focus (the moved rows stay
/// selected, in the unfocused grey). The move is not registered with the
/// window's undo manager, so ⌘Z and Edit ▸ Undo leave it in place. The
/// project's earlier navigator undo and redo entries can no longer apply
/// (an undo is refused once the project changed since), so they are dropped
/// with it rather than refused with an alert. Moves made another way (Edit ▸
/// Paste ▸ Move Item Here) and the other file operations keep their undo.
extension WorkspaceWindowController {
    /// The undo target of one project's navigator edits (nil: the package),
    /// so the entries of one project can be dropped on their own.
    final class NavigatorUndoTarget: NSObject {
        weak var controller: WorkspaceWindowController?
        init(_ controller: WorkspaceWindowController) { self.controller = controller }
        nonisolated(unsafe) static var key = 0
    }

    func navigatorUndoTarget(_ project: String?) -> NavigatorUndoTarget {
        var targets = objc_getAssociatedObject(self, &NavigatorUndoTarget.key) as? [String: NavigatorUndoTarget] ?? [:]
        if let t = targets[project ?? ""] { return t }
        let t = NavigatorUndoTarget(self)
        targets[project ?? ""] = t
        objc_setAssociatedObject(self, &NavigatorUndoTarget.key, targets, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return t
    }

    /// After a drop that moved rows: the project's navigator undo history
    /// goes, the topmost moved file opens and the editor takes focus.
    func finishNavigatorDragMove(_ edit: ProjectEdit, project: String?) {
        window?.undoManager?.removeAllActions(withTarget: navigatorUndoTarget(project))
        guard let path = navigator.selectedProjectRows.first(where: { $0.nodeKind == .file && $0.nodePath != nil })?.nodePath else { return }
        open(path: path, line: nil)
        focusEditorAfterNavigatorMove()
    }

    /// The editor's text, or the first focusable view of an editor that
    /// shows something else (an image, a property list, …).
    func focusEditorAfterNavigatorMove() {
        guard let window else { return }
        if hasSourceFile {
            window.makeFirstResponder(editor.textView)
        } else if let aux = editor.auxiliary {
            _ = focus(area: aux, in: window)
        }
    }
}
