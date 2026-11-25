import AppKit
import YcodeIDECore

/// The Project navigator's context menus and "+" menu, built from the
/// shared `ProjectRowMenu` (P-040, P-041). The window's actions do the
/// work; a right click does not change the selection: the menu's commands
/// act on the clicked row when it is outside the selection (the row only
/// gets the context-click ring), else on the selection.
@MainActor
final class NavigatorContextRows {
    /// The rows a context menu acts on while it is open (and while its
    /// command runs); empty otherwise.
    var rows: [OutlineItem] = []
    /// The file Open in New Tabs is opening (each in turn).
    var openingPath: String?
}

extension NavigatorAreaController {
    /// Where the window's actions are (the workspace window's controller).
    var commandTarget: AnyObject? { isViewLoaded ? view.window?.windowController : nil }

    /// The window's selector for a command; nil for the navigator's own
    /// actions and for commands Ycode does not have.
    static func windowSelector(_ c: ProjectRowMenu.Command) -> Selector? {
        switch c {
        case .showInFinder: Selector(("showNavigatorSelectionInFinder:"))
        case .openInNewTab: Selector(("openInNewTab:"))
        case .newEmptyFile: Selector(("newEmptyFile:"))
        case .newFileFromTemplate: Selector(("newFile:"))
        case .addFiles: Selector(("addFiles:"))
        case .addPackageDependencies: Selector(("addPackageDependencies:"))
        case .delete: Selector(("deleteNavigatorSelection:"))
        case .newGroup: Selector(("newGroup:"))
        case .newGroupWithoutFolder: Selector(("newGroupWithoutFolder:"))
        case .newGroupFromSelection: Selector(("newGroupFromSelection:"))
        case .newGroupFromSelectionWithoutFolder: Selector(("newGroupFromSelectionWithoutFolder:"))
        case .newFolder: Selector(("newFolder:"))
        case .newFolderFromSelection: Selector(("newFolderFromSelection:"))
        case .sortByName: Selector(("sortByName:"))
        case .sortByType: Selector(("sortByType:"))
        case .migrateToStringCatalog: Selector(("convertToStringCatalogs:"))
        case .findInSelected: Selector(("findInSelectedGroups:"))
        case .scmCommit: Selector(("showCommitSheet:"))
        case .scmRefreshStatus: Selector(("refreshFileStatus:"))
        case .scmAdd: Selector(("scmAddSelected:"))
        case .scmMarkResolved: Selector(("scmMarkResolved:"))
        case .openTerminalAtLocation, .openInNewTabs, .openWithExternalEditor, .bookmark, .openInNewWindow: nil
        }
    }

    /// The navigator's own action for a command, if it has one.
    static func ownSelector(_ c: ProjectRowMenu.Command) -> Selector? {
        switch c {
        case .openTerminalAtLocation: #selector(navigatorOpenTerminal(_:))
        case .openInNewTabs: #selector(navigatorOpenInNewTabs(_:))
        case .openWithExternalEditor: #selector(navigatorOpenWithExternalEditor(_:))
        case .bookmark: #selector(navigatorBookmark(_:))
        default: nil
        }
    }

    /// The project the menus name (Add Files to “<name>”…).
    var menuProjectName: String? {
        guard let root = rows(0).first, root.nodeKind == .container else { return nil }
        return root.nodePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? root.title
    }

    /// Menu items for entries, with the window's or the navigator's
    /// actions, enabled as the target validates them.
    func projectMenuItems(_ entries: [ProjectRowMenu.Entry], kind: ProjectRowMenu.RowKind) -> [NSMenuItem] {
        entries.map { e in
            switch e {
            case .separator: return .separator()
            case .submenu(let title, let kids):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: title)
                for k in projectMenuItems(kids, kind: kind) { sub.addItem(k) }
                sub.autoenablesItems = false
                item.submenu = sub
                return item
            case .command(let c):
                let item = NSMenuItem(title: ProjectRowMenu.title(c, projectName: menuProjectName, kind: kind), action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(c.rawValue)
                if let own = Self.ownSelector(c) {
                    item.action = own
                    item.target = self
                    item.isEnabled = validateOwnCommand(c)
                } else if let sel = Self.windowSelector(c), let target = commandTarget, target.responds(to: sel) {
                    item.action = sel
                    item.target = target
                    item.isEnabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
                } else {
                    item.isEnabled = false
                }
                return item
            }
        }
    }

    // MARK: The context menu

    /// The rows a right click on `clicked` acts on: the selection when it
    /// holds the row, else the row alone.
    func contextRows(for clicked: OutlineItem?) -> [OutlineItem] {
        let selected = projectOutlineSelection
        guard let clicked else { return selected }
        return selected.contains { $0 === clicked } ? selected : [clicked]
    }

    /// The project outline's selected rows, ignoring an open context menu.
    var projectOutlineSelection: [OutlineItem] {
        guard isViewLoaded, selectedIndex == 0 else { return [] }
        return navigatorOutline.selectedRowIndexes.compactMap { navigatorOutline.item(atRow: $0) as? OutlineItem }
    }

    /// Fills the context menu for the clicked row (the outline's
    /// `clickedRow`), leaving the selection as it is.
    func rebuildProjectRowMenu(_ menu: NSMenu) {
        let clicked = navigatorOutline.clickedRow >= 0 ? navigatorOutline.item(atRow: navigatorOutline.clickedRow) as? OutlineItem : nil
        fillProjectContextMenu(menu, rows: contextRows(for: clicked))
    }

    func fillProjectContextMenu(_ menu: NSMenu, rows: [OutlineItem]) {
        menu.removeAllItems()
        contextRowState.rows = rows
        guard let first = rows.first else { return }
        let kind = ProjectRowMenu.kind(of: first.nodeKind ?? .file)
        menu.autoenablesItems = false
        menu.minimumWidth = CGFloat(ProjectRowMenu.minimumWidth)
        for item in projectMenuItems(ProjectRowMenu.entries(for: kind), kind: kind) { menu.addItem(item) }
    }

    /// The context menu a right click on `row` opens (tests): its items
    /// act on the row (or the selection holding it) until `endContextMenu`.
    public func projectContextMenu(for row: OutlineItem) -> NSMenu {
        let menu = NSMenu(title: "Row")
        fillProjectContextMenu(menu, rows: contextRows(for: row))
        return menu
    }

    /// The context menu is done: its rows stop standing in for the selection.
    public func endContextMenu() { contextRowState.rows = [] }

    /// The context menu closed: its rows stand in for the selection until
    /// the chosen command (sent after the menu closes) has run.
    func contextMenuDidClose() {
        DispatchQueue.main.async { [weak self] in self?.endContextMenu() }
    }

    // MARK: The navigator's own commands

    func validateOwnCommand(_ c: ProjectRowMenu.Command) -> Bool {
        let rows = selectedProjectRows
        switch c {
        case .openTerminalAtLocation: return rows.first.flatMap(directoryOf) != nil
        case .openInNewTabs: return !filePaths(under: rows).isEmpty
        case .openWithExternalEditor, .bookmark: return rows.count == 1 && rows.first?.nodeKind == .file && rows.first?.path != nil
        default: return false
        }
    }

    /// A row's folder: its own for a group or folder, its file's otherwise.
    func directoryOf(_ row: OutlineItem) -> URL? {
        guard let p = row.nodePath else { return nil }
        let url = URL(fileURLWithPath: p)
        return row.nodeKind == .file || p.hasSuffix(".xcodeproj") ? url.deletingLastPathComponent() : url
    }

    /// The files under rows, in row order.
    func filePaths(under rows: [OutlineItem]) -> [String] {
        rows.flatMap { r -> [String] in
            if r.nodeKind == .file { return r.path.map { [$0] } ?? [] }
            return filePaths(under: r.children)
        }
    }

    /// Open Terminal at Location: the row's folder in the Terminal.
    @objc func navigatorOpenTerminal(_ sender: Any?) {
        guard view.window?.isVisible == true, let dir = selectedProjectRows.first.flatMap(directoryOf),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return NSSound.beep() }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Open in New Tabs (a group or folder): each file under it in a new tab.
    @objc func navigatorOpenInNewTabs(_ sender: Any?) {
        guard let target = commandTarget else { return }
        let paths = filePaths(under: selectedProjectRows)
        for p in paths {
            contextRowState.openingPath = p
            _ = target.perform(Selector(("openInNewTab:")), with: nil)
        }
        contextRowState.openingPath = nil
    }

    /// Open with External Editor: the row's file in its default application.
    @objc func navigatorOpenWithExternalEditor(_ sender: Any?) {
        guard view.window?.isVisible == true, let p = selectedProjectRows.first?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    /// Bookmark: a file bookmark on the row's file (opened first).
    @objc func navigatorBookmark(_ sender: Any?) {
        guard let p = selectedProjectRows.first?.path, let target = commandTarget else { return }
        onOpen?(p, nil)
        _ = target.perform(Selector(("bookmarkFile:")), with: nil)
    }
}
