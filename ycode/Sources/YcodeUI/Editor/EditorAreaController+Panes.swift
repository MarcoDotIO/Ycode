import AppKit

/// Split panes' jump bars (`editor-area.md` E.2, checklist row 71): with
/// more than one editor pane (the assistant aside), each pane's bar has its
/// own close button, and only the focused pane draws its path in full
/// colour.
extension EditorAreaController {
    public func updatePaneChrome() {
        guard isViewLoaded else { return }
        let t = tab
        let split = t.editors.count > 1
        // The assistant has its own close button; the primary beside it has none.
        let panes = t.editors.filter { $0 !== t.assistant }.count
        for (i, e) in t.editors.enumerated() {
            e.jumpBar.isActivePane = !split || i == t.focused
            let closable = panes > 1 && t.assistant !== e
            e.jumpBar.showsPaneCloseButton = closable
            if closable { e.jumpBar.onClose = { [weak self, weak e] in if let e { self?.closePane(e) } } }
        }
    }

    /// Closes one pane (its jump bar's close button).
    public func closePane(_ e: SourceEditorController) {
        focus(e)
        closeFocusedEditor()
    }
}
