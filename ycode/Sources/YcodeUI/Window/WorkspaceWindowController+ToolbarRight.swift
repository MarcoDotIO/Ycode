import AppKit

/// The toolbar's right group and the Adjust Editor Options menu
/// (`specs/ide/reference-ui-4.md` §14).
public enum EditorOptionsMenu {
    static let accountID = NSToolbarItem.Identifier("account")
    static let addEditorID = NSToolbarItem.Identifier("addEditor")
    static let editorOptionsID = NSToolbarItem.Identifier("editorOptions")

    /// The right group, left to right, ending with the three-way toggle.
    public static let rightGroup = ["account", "addEditor", "editorOptions", "editorModes"]

    /// Adjust Editor Options, in order. The choices apply to the focused editor.
    static var items: [MenuItemSpec] {
        let u = CommandTable.unavailable
        return [
            .submenu("Layout", [
                .command(.init("Editor Pane On Right", "", [], "splitEditor:")),
                .command(.init("Editor Pane Below", "", [], "splitEditorBelow:")),
            ]),
            .separator,
            .command(.init("Inline Comparison", "", [], "showInlineComparison:")),
            .command(.init("Side By Side Comparison", "", [], "showSideBySideComparison:")),
            .separator,
            .command(.init("Minimap", "", [], "toggleMinimap:")),
            u("Authors"),
            u("Code Coverage"),
            .separator,
            u("Invisibles"),
            u("Scope Guides"),
            .command(.init("Wrap Lines", "", [], "toggleWrapLines:")),
            .separator,
            .command(.init("Choose Workspace Theme…", "", [], "chooseTheme:")),
        ]
    }

    /// Add Editor Tabs or Editor Panes.
    static var addItems: [MenuItemSpec] {
        [
            .command(.init("Add Editor Tab", "", [], "newTab:")),
            .command(.init("Add Editor Pane on Right", "", [], "splitEditor:")),
            .command(.init("Add Editor Pane Below", "", [], "splitEditorBelow:")),
        ]
    }

    @MainActor public static func menu() -> NSMenu { MainMenu.menu("Adjust Editor Options", items) }
    @MainActor public static func addMenu() -> NSMenu { MainMenu.menu("Add Editor Tabs or Editor Panes", addItems) }
}

extension WorkspaceWindowController {
    /// Toolbar items of the right group (nil for other identifiers).
    func rightGroupToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        func menuItem(_ symbol: String, _ label: String, _ menu: NSMenu) -> NSToolbarItem {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.menu = menu
            item.showsIndicator = false
            return item
        }
        switch id {
        case EditorOptionsMenu.accountID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Account")
            item.label = "Account"
            item.toolTip = "Account"
            item.isEnabled = false   // no accounts in Ycode
            return item
        case EditorOptionsMenu.addEditorID:
            return menuItem("plus.rectangle.on.rectangle", "Add Editor Tabs or Editor Panes", EditorOptionsMenu.addMenu())
        case EditorOptionsMenu.editorOptionsID:
            return menuItem("line.3.horizontal", "Adjust Editor Options", EditorOptionsMenu.menu())
        default:
            return nil
        }
    }
}
