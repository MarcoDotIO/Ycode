import AppKit
import YcodeLanguage

/// Editor menu actions and their enablement/check states
/// (`specs/ide/reference-ui-4.md` §8, §14).
extension WorkspaceWindowController {
    /// Editor ▸ Show Editor Only (⌘↩): hides the canvas, the assistant and
    /// the comparison, leaving the focused editor.
    @objc public func showEditorOnly(_ sender: Any?) {
        if canvas != nil { toggleCanvas(nil) }
        if editorArea.tab.assistant != nil { toggleAssistant(nil) }
        if editor.isShowingComparison { editor.hideComparison() }
        editor.hideInlineComparison()
        updateToolbarState()
    }

    /// Editor ▸ Show Issues / Hide All Issues.
    @objc public func showInlineIssues(_ sender: Any?) { for e in editorArea.allEditors { e.showsInlineIssues = true } }
    @objc public func hideInlineIssues(_ sender: Any?) { for e in editorArea.allEditors { e.showsInlineIssues = false } }

    /// Editor ▸ Wrap Lines (⌃⇧⌘L): the editing preference.
    @objc public func toggleWrapLines(_ sender: Any?) { Preferences.shared.wrapLines.toggle() }

    /// Editor ▸ Refactor ▸ <item>: performs the code action mapped to the
    /// item (`RefactorCatalog`). Returns whether one was found.
    @discardableResult
    @objc public func performRefactorItem(_ sender: Any?) -> Bool {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? -1
        guard let i = RefactorCatalog.actionIndex(forItem: tag, in: cachedCodeActions) else { NSSound.beep(); return false }
        let a = cachedCodeActions[i]
        Task { await perform(a) }
        return true
    }

    /// Enablement and check marks of Editor menu items; nil = not ours.
    func validateEditorMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(performRefactorItem(_:)):
            return RefactorCatalog.actionIndex(forItem: item.tag, in: cachedCodeActions) != nil
        case #selector(toggleCanvas(_:)): item.state = canvas != nil ? .on : .off
        case #selector(toggleAssistant(_:)): item.state = editorArea.tab.assistant != nil ? .on : .off
        case #selector(toggleComparison(_:)): item.state = editor.isShowingComparison || editor.isShowingInlineComparison ? .on : .off
        case NSSelectorFromString("toggleMinimap:"): item.state = editor.showsMinimap ? .on : .off
        case #selector(toggleWrapLines(_:)): item.state = Preferences.shared.wrapLines ? .on : .off
        case NSSelectorFromString("toggleLineNumbers:"): item.state = editor.showsLineNumbers ? .on : .off
        case #selector(showInlineComparison(_:)): item.state = editor.comparisonStyle == .inline ? .on : .off
        case #selector(showSideBySideComparison(_:)): item.state = editor.comparisonStyle == .sideBySide ? .on : .off
        case #selector(showInlineIssues(_:)): return !editor.showsInlineIssues
        case #selector(hideInlineIssues(_:)): return editor.showsInlineIssues
        default: return validateEditorCommandItem(item)
        }
        return true
    }
}
