import Foundation
import YcodeEditorKit
import YcodeIDECore

/// What the views tell the model about the panes' scrolling, and the lines
/// to scroll to once a restored pane is drawn (W7.1). The views own the
/// scroll offsets; the model asks for them when it saves.
@MainActor
public final class ShellWindowRestore {
    /// The first visible line (1-based) of the pane with this id showing
    /// this file; set by the views.
    public var firstVisibleLine: ((_ pane: Int, _ path: String) -> Int?)?
    /// Lines to scroll to when a pane first draws a file, by "pane|path".
    var pendingTopLines: [String: Int] = [:]

    public init() {}

    /// The line a restored pane should scroll to, once (the views ask when
    /// the pane's editor appears).
    public func takeTopLine(pane: Int, path: String) -> Int? {
        pendingTopLines.removeValue(forKey: "\(pane)|\(path)")
    }
}

/// Restoring the workspace window on reopen in the Linux IDE
/// (`workspace-window.md` W7.1, council row 186), from the same
/// per-workspace user data as the macOS IDE (`WorkspaceUserState`): each
/// pane's file, first visible line and selection, the split's direction,
/// the active pane, the inspector's visibility and tab. The Linux panes
/// always share the split equally (they have no divider to drag), so
/// they save equal shares. Test runs neither read nor write the file.
extension WorkspaceShellModel {
    /// The editors as they are now.
    public var currentEditorLayout: WorkspaceEditorLayout {
        let p = panes
        let list = p.panes.map { pane -> WorkspaceEditorLayout.Pane in
            guard let path = pane.path else { return .init(path: nil) }
            let top = restore.firstVisibleLine?(pane.id, path) ?? 1
            guard let d = openDocuments[path] else { return .init(path: path, topLine: top) }
            let s = d.buffer.selection.nsRange
            return .init(path: path, topLine: top, selectionStart: s.location, selectionLength: s.length)
        }
        return WorkspaceEditorLayout(panes: list, sideBySide: p.sideBySide, focused: p.focused)
    }

    /// The inspector as it is now.
    public var currentInspectorState: WorkspaceInspectorState {
        WorkspaceInspectorState(isShown: isInspectorShown, tab: languageFeatures.inspectorTab.rawValue)
    }

    /// Writes the editors and the inspector into the user data (the app
    /// does when the workspace closes or the app quits).
    public func saveWindowLayout() {
        guard let url = userStateURL else { return }
        Self.save(layout: currentEditorLayout, inspector: currentInspectorState, to: url)
    }

    /// Writes `layout` and `inspector` into the user data at `url`, keeping its other values.
    public static func save(layout: WorkspaceEditorLayout, inspector: WorkspaceInspectorState, to url: URL) {
        var state = WorkspaceUserState.load(from: url)
        state.editorLayout = layout
        state.inspector = inspector
        state.save(to: url)
    }

    /// Brings back the saved editors and inspector from the user data (the
    /// app does when it opens the workspace).
    public func restoreWindowLayout() {
        guard let url = userStateURL else { return }
        restoreWindowLayout(from: WorkspaceUserState.load(from: url))
    }

    /// Brings back the editors and inspector of `state`.
    public func restoreWindowLayout(from state: WorkspaceUserState) {
        if let i = state.inspector {
            isInspectorShown = i.isShown
            languageFeatures.inspectorTab = ShellLanguageFeatures.InspectorTab(rawValue: i.tab(clampedTo: 3)) ?? .file
        }
        guard let saved = state.editorLayout else { return }
        let layout = saved.restorable()
        let p = panes
        p.panes = layout.panes.indices.map { ShellEditorPane(id: $0, path: nil) }
        p.nextID = layout.panes.count
        p.sideBySide = layout.sideBySide
        // Each pane's file opens in turn (so every pane's document is
        // open), then the active pane's is shown.
        for (i, pane) in layout.panes.enumerated() {
            guard let path = pane.path else { continue }
            p.focused = i
            showFile(path)
            if let d = openDocuments[path] {
                d.buffer.setSelection(EditorSelection(pane.selection(clampedTo: d.buffer.length)))
            }
            restore.pendingTopLines["\(i)|\(path)"] = pane.topLine
        }
        p.focused = layout.focused
        showFocusedPane()
    }
}
