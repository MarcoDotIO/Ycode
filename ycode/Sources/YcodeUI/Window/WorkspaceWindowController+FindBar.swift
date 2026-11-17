import AppKit
import YcodeIDECore

/// The Find menu's in-file items when the editor does not have the keyboard
/// (P-003, `specs/ide/parity-inventory.md`): with a file open and the
/// navigator focused, Find… (⌘F), Find and Replace… (⌥⌘F) and the rest
/// act on the focused editor, and ⌘F opens its find bar, as the reference
/// does. The editor's own text view handles them while it is focused.
extension WorkspaceWindowController {
    /// Find…, Find and Replace…, Find Next / Previous, Replace…, Use
    /// Selection for Find, Select All Find Matches: the editor's
    /// `performFind(tag:)`; the bar takes the keyboard when it opens.
    @objc public func performFindPanelAction(_ sender: Any?) {
        guard canUseEditorFindBar else { NSSound.beep(); return }
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 1
        editor.performFind(tag: tag)
    }

    @objc public func findAndSelectNext(_ sender: Any?) { editor.findAndSelectNext(sender) }
    @objc public func findAndSelectPrevious(_ sender: Any?) { editor.findAndSelectPrevious(sender) }
    @objc public func replaceAndFindPrevious(_ sender: Any?) { editor.replaceAndFindPrevious(sender) }
    @objc public func useSelectionForReplace(_ sender: Any?) { editor.useSelectionForReplace(sender) }
    @objc public func selectNextOccurrence(_ sender: Any?) { editor.selectNextOccurrence(sender) }
    @objc public func selectPreviousOccurrence(_ sender: Any?) { editor.selectPreviousOccurrence(sender) }
    // Editor ▸ Minimap (⌃⇧⌘M) and Editor Options ▸ Minimap (P-065) are
    // the window's `toggleMinimap(_:)` in +MenuParity.swift (P-007).

    /// Whether the focused editor shows a source file its find bar can search.
    var canUseEditorFindBar: Bool { editor.canUseFindBar }

    /// Enablement of the items above; nil = not one of them.
    func validateFindBarItem(_ item: NSMenuItem) -> Bool? {
        editor.validateFindItem(item)
    }
}
