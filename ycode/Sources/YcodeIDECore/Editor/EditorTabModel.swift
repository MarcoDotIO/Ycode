import Foundation

/// The view-independent rules of the editor tab bar
/// (specs/ide/reference-ui-2.md §8).
public enum EditorTabPolicy {
    /// Where a file opened from the navigator goes.
    public enum OpenTarget: Equatable, Sendable {
        /// Replace the contents of the current (unpinned) tab.
        case current
        /// Select a tab that already shows the file.
        case select(Int)
        /// Add a new tab to the right of the current one.
        case newTab
    }

    /// - Parameters:
    ///   - path: the file to open.
    ///   - currentPath: the file of the current tab's focused editor.
    ///   - currentPinned: whether the current tab is pinned.
    ///   - openInTabs: open in a new tab (unless a tab shows the file already).
    ///   - tabPaths: the files shown by each tab.
    public static func openTarget(path: String, currentPath: String?, currentPinned: Bool,
                                  openInTabs: Bool, tabPaths: [[String]]) -> OpenTarget {
        guard let currentPath, currentPath != path, currentPinned || openInTabs else { return .current }
        if let i = tabPaths.firstIndex(where: { $0.contains(path) }) { return .select(i) }
        return .newTab
    }

    /// The bar shows with View ▸ Show Editor Tab Bar, or with two or more tabs.
    public static func isBarVisible(shown: Bool, tabCount: Int) -> Bool { shown || tabCount > 1 }

    /// A tab's title: the file name without its extension.
    public static func title(for url: URL?) -> String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// A tab's tooltip: the name, then the group path.
    public static func toolTip(for url: URL, groupPath: String?) -> String {
        url.lastPathComponent + (groupPath.map { $0.isEmpty ? "" : "\n" + $0 } ?? "")
    }

    /// The close "×" shows only on the hovered tab (at its left end).
    public static func showsCloseButton(tab: Int, hovered: Int?) -> Bool { tab == hovered }

    /// The tab selected after closing `index` of `count` tabs, when the
    /// selection was `selected`.
    public static func selectionAfterClosing(_ index: Int, selected: Int, count: Int) -> Int {
        let remaining = count - 1
        guard remaining > 0 else { return 0 }
        let s = index < selected ? selected - 1 : selected
        return min(s, remaining - 1)
    }
}

/// The File menu close commands (reference-ui-2.md §8.5).
public enum EditorCloseCommand: CaseIterable, Sendable {
    case tab, document, editorPane, window, workspace

    /// ⌘ is implied; modifiers given as in a menu ("⌃⌘W").
    public var shortcut: String {
        switch self {
        case .tab: "⌘W"
        case .document: "⌃⌘W"
        case .editorPane: "⌃⇧⌘W"
        case .window: "⇧⌘W"
        case .workspace: "⌃⌥⌘W"
        }
    }

    public func title(fileName: String?, isPackage: Bool) -> String {
        switch self {
        case .tab: "Close Tab"
        case .document: fileName.map { "Close \u{201C}\($0)\u{201D}" } ?? "Close Document"
        case .editorPane: "Close Editor Pane"
        case .window: "Close Window"
        case .workspace: isPackage ? "Close Package" : "Close Project"
        }
    }

    /// Close Editor Pane needs two or more panes.
    public func isEnabled(paneCount: Int) -> Bool { self != .editorPane || paneCount > 1 }
}
