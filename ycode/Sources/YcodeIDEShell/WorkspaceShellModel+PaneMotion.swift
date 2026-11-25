import Foundation
import YcodeIDECore

/// The panes' slides as the model sees them (P-190–P-192; the slides are
/// drawn by the window, `ycode-ide/InspectorSlide.swift`).
extension WorkspaceShellModel {
    /// View ▸ Inspectors ▸ <inspector> (⌥⌘1, ⌥⌘2): on the inspector
    /// already shown it hides the inspector, and the next press shows it
    /// again (P-192: the reference toggles), on the selector's own curves.
    public func toggleInspector(bySelector tab: ShellLanguageFeatures.InspectorTab) {
        if isInspectorShown, languageFeatures.inspectorTab == tab {
            PaneMotion.noteInspectorSelector()
            isInspectorShown = false
            return
        }
        if !isInspectorShown { PaneMotion.noteInspectorSelector() }
        showInspector(tab)
    }
}

/// Which curve the next inspector slide takes: ⌥⌘1/2's (`Motion.inspector(
/// show:bySelector:)`) after `toggleInspector(bySelector:)`.
@MainActor
public enum PaneMotion {
    private static var inspectorBySelector = false

    public static func noteInspectorSelector() { inspectorBySelector = true }

    /// Whether the change just made came from ⌥⌘1/2 (read once).
    public static func takeInspectorSelector() -> Bool {
        defer { inspectorBySelector = false }
        return inspectorBySelector
    }

    private static var navigatorByClick = false

    /// The next navigator slide comes from a click on the toolbar's
    /// Navigators / Coding Assistant group (`Motion.navigator(show:trigger:)`:
    /// a click starts later than a key, `window-layout.md` §6.1).
    public static func noteNavigatorClick() { navigatorByClick = true }

    /// The trigger of the navigator change just made (read once).
    public static func takeNavigatorTrigger() -> Motion.NavigatorTrigger {
        defer { navigatorByClick = false }
        return navigatorByClick ? .click : .key
    }
}
