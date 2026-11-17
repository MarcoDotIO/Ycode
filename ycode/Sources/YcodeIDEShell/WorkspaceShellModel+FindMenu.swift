import Foundation
import YcodeEditorKit
import YcodeIDECore

/// The Find menu's in-file items beyond Find… and Find and Replace… (P-003,
/// `specs/ide/parity-inventory.md`), as the macOS IDE enables and performs
/// them: with a source file open, Replace, Replace All, Replace and Find
/// Next / Previous, Use Selection for Replace, Hide Find Bar and Find
/// Selected Text / Words in Workspace act on the focused editor and its
/// find bar. The menu reaches them through the editor-action hook
/// (`editorActionState`, `performEditorAction`), by `CommandTable` action
/// and tag. The items that add to the selection (Find and Select Next /
/// Previous, Select Next / Previous Occurrence, Select All Find Matches,
/// Select Find Matches in Selection) need several selections, which the
/// Linux editor does not have yet: they stay disabled.
extension WorkspaceShellModel {
    /// `performFindPanelAction:` tags handled here (the others are
    /// `ShellCommand`s): Replace All 4, Replace 5, Replace and Find Next 6.
    static let findPanelReplaceTags: Set<Int> = [4, 5, 6]
    /// Selectors of the in-file items handled here.
    static let findMenuSelectors: Set<String> = [
        "replaceAndFindPrevious:", "useSelectionForReplace:", "hideFindBar:",
        "findSelectedTextInWorkspace:", "findSelectedWordsInWorkspace:",
        "findAndSelectNext:", "findAndSelectPrevious:", "selectNextOccurrence:", "selectPreviousOccurrence:",
    ]

    /// Whether a Find menu item applies now; nil = not one of these.
    public func findMenuActionState(_ action: String, tag: Int) -> (enabled: Bool, checked: Bool)? {
        let hasFile = editor != nil && structuredEditor == nil
        let editable = hasFile && editor?.readOnlyReason == nil
        if action == "performFindPanelAction:" {
            switch tag {
            case 4, 5, 6: return (editable, false)
            case 9, 10: return (false, false)   // several selections
            default: return nil
            }
        }
        switch action {
        case "replaceAndFindPrevious:": return (editable, false)
        case "useSelectionForReplace:", "hideFindBar:", "findSelectedTextInWorkspace:", "findSelectedWordsInWorkspace:":
            return (hasFile, false)
        case "findAndSelectNext:", "findAndSelectPrevious:", "selectNextOccurrence:", "selectPreviousOccurrence:":
            return (false, false)   // several selections
        default: return nil
        }
    }

    /// Performs a Find menu item; false when it is not one of these or
    /// does not apply.
    public func performFindMenuAction(_ action: String, tag: Int) -> Bool {
        guard findMenuActionState(action, tag: tag)?.enabled == true, let b = editor?.buffer else { return false }
        switch (action, tag) {
        case ("performFindPanelAction:", 4):
            showFindBarIfHidden(replace: true)
            findBar.replaceAll()
        case ("performFindPanelAction:", 5), ("performFindPanelAction:", 6):
            showFindBarIfHidden(replace: true)
            findBar.replaceCurrent()
        case ("replaceAndFindPrevious:", _):
            showFindBarIfHidden(replace: true)
            findBar.replaceCurrent()
            findBar.step(forward: false)
        case ("useSelectionForReplace:", _):
            guard !b.selection.isEmpty else { return false }
            findBar.replacement = b.selectedText
        case ("hideFindBar:", _):
            findBar.isShown = false
            focusEditor()
        case ("findSelectedTextInWorkspace:", _), ("findSelectedWordsInWorkspace:", _):
            guard let q = selectionOrWordAtCaret(b) else { return false }
            findText = q
            showFindInWorkspace()
            runFind()
        default:
            return false
        }
        return true
    }

    private func showFindBarIfHidden(replace: Bool) {
        guard !findBar.isShown || (replace && !findBar.showsReplace) else { return }
        findBar.isShown = true
        findBar.showsReplace = replace || findBar.showsReplace
        findBar.refresh()
    }

    /// The selection (one line), else the word around the caret.
    func selectionOrWordAtCaret(_ b: EditorBuffer) -> String? {
        if !b.selection.isEmpty { return b.selectedText }
        let ns = b.text as NSString
        var a = min(b.caret, ns.length), z = a
        func isWord(_ c: unichar) -> Bool {
            guard let s = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(s) || c == 95
        }
        while a > 0, isWord(ns.character(at: a - 1)) { a -= 1 }
        while z < ns.length, isWord(ns.character(at: z)) { z += 1 }
        return z > a ? ns.substring(with: NSRange(location: a, length: z - a)) : nil
    }
}
