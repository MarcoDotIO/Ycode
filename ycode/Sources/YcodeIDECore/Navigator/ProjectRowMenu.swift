import Foundation

/// The Project navigator's menus that both IDEs build from one list
/// (P-040, P-041; `navigators.md` §Commands): the rows' context menu by
/// row kind, and the bottom bar's "+" menu. Each IDE maps a `Command` to
/// its own action and decides whether it is enabled.
public enum ProjectRowMenu {
    /// What was right-clicked.
    public enum RowKind: Equatable, Sendable {
        /// The project (or package, or workspace) row.
        case project
        /// A group (`PBXGroup`).
        case group
        /// A folder: a synchronized folder, or a directory on disk.
        case folder
        case file
    }

    public enum Command: String, CaseIterable, Sendable {
        case showInFinder, openTerminalAtLocation, openInNewTab, openInNewTabs, openInNewWindow, openWithExternalEditor
        case newEmptyFile, newFileFromTemplate, addFiles, addPackageDependencies
        case delete
        case newGroup, newGroupWithoutFolder, newGroupFromSelection, newGroupFromSelectionWithoutFolder
        case newFolder, newFolderFromSelection
        case sortByName, sortByType
        case migrateToStringCatalog
        case bookmark
        case findInSelected
        // Source Control ›
        case scmCommit, scmRefreshStatus, scmAdd, scmMarkResolved
    }

    public indirect enum Entry: Equatable, Sendable {
        case command(Command)
        case separator
        case submenu(String, [Entry])
    }

    /// The context menu's width (the reference's measured 240 points).
    public static let minimumWidth = 240.0

    /// The Source Control submenu.
    public static let sourceControlTitle = "Source Control"
    static let sourceControl: Entry = .submenu(sourceControlTitle, [
        .command(.scmCommit), .separator, .command(.scmAdd), .command(.scmMarkResolved), .separator, .command(.scmRefreshStatus),
    ])

    /// The context menu for a row of `kind` (the reference's items and
    /// order, P-041). Ycode adds no Rename: Return renames in place. The
    /// project row has no Delete.
    public static func entries(for kind: RowKind) -> [Entry] {
        let open: [Entry] = [.command(.showInFinder), .command(.openTerminalAtLocation), .command(.openInNewTab)]
            + (kind == .group || kind == .folder ? [.command(.openInNewTabs)] : [])
            + [.command(.openInNewWindow), .command(.openWithExternalEditor), .separator]
        let new: [Entry] = [.command(.newEmptyFile), .command(.newFileFromTemplate), .command(.addFiles), .command(.addPackageDependencies),
                            .separator]
        let find: [Entry] = [.command(.findInSelected), .separator, sourceControl]
        switch kind {
        case .project:
            return open + new + [
                .command(.newGroup), .command(.newGroupWithoutFolder), .command(.newGroupFromSelection),
                .command(.newGroupFromSelectionWithoutFolder), .command(.newFolder), .command(.newFolderFromSelection), .separator,
                .command(.sortByName), .command(.sortByType), .separator,
                .command(.migrateToStringCatalog), .separator,
            ] + find
        case .group, .folder, .file:
            return open + new + [
                .command(.delete), .separator,
                .command(.newFolder), .command(.newFolderFromSelection), .separator,
                .command(.bookmark),
            ] + find
        }
    }

    /// The bottom bar's "+" menu (P-040): New Empty File, New File from
    /// Template…, a separator, Add Files to “<project>”….
    public static let addMenu: [Entry] = [.command(.newEmptyFile), .command(.newFileFromTemplate), .separator, .command(.addFiles)]

    /// A command's title. `projectName` names Add Files' project; a file
    /// row's Find is "Find in Selected File…".
    public static func title(_ c: Command, projectName: String?, kind: RowKind = .file) -> String {
        switch c {
        case .showInFinder: OrganizerState.showInFilesTitle
        case .openTerminalAtLocation: "Open Terminal at Location"
        case .openInNewTab: "Open in New Tab"
        case .openInNewTabs: "Open in New Tabs"
        case .openInNewWindow: "Open in New Window"
        case .openWithExternalEditor: "Open with External Editor"
        case .newEmptyFile: "New Empty File"
        case .newFileFromTemplate: "New File from Template…"
        case .addFiles: projectName.map { "Add Files to \u{201C}\($0)\u{201D}…" } ?? "Add Files…"
        case .addPackageDependencies: "Add Package Dependencies…"
        case .delete: "Delete"
        case .newGroup: "New Group"
        case .newGroupWithoutFolder: "New Group without Folder"
        case .newGroupFromSelection: "New Group from Selection"
        case .newGroupFromSelectionWithoutFolder: "New Group from Selection without Folder"
        case .newFolder: "New Folder"
        case .newFolderFromSelection: "New Folder from Selection"
        case .sortByName: "Sort by Name"
        case .sortByType: "Sort by Type"
        case .migrateToStringCatalog: "Migrate to String Catalog…"
        case .bookmark: "Bookmark"
        case .findInSelected: kind == .file ? "Find in Selected File…" : "Find in Selected Groups…"
        case .scmCommit: "Commit…"
        case .scmRefreshStatus: "Refresh File Status"
        case .scmAdd: "Add"
        case .scmMarkResolved: "Mark as Resolved"
        }
    }

    /// Every command's title in a list of entries, depth first, with "-"
    /// for separators and "Title ›" for submenus (tests, parity tables).
    public static func titles(_ entries: [Entry], projectName: String?, kind: RowKind) -> [String] {
        entries.flatMap { e -> [String] in
            switch e {
            case .command(let c): [title(c, projectName: projectName, kind: kind)]
            case .separator: ["-"]
            case .submenu(let t, let kids): ["\(t) ›"] + titles(kids, projectName: projectName, kind: kind).map { "  " + $0 }
            }
        }
    }

    /// The row kind of a navigator node.
    public static func kind(of node: NavigatorNode.Kind) -> RowKind {
        switch node {
        case .container: .project
        case .group: .group
        case .folder: .folder
        case .file: .file
        }
    }
}

/// The navigators' empty state as drawn (P-039): the first line ≈ 16
/// points medium in #9D9FA1 (dark; the secondary label colour in light),
/// its ink top 4.5 points above where Ycode had it; a second line in the
/// small secondary text.
public enum NavigatorEmptyStyle {
    public static let titleSize = 16.0
    public static let detailSize = 11.0
    public static let titleColorDark: UInt32 = 0x9D9FA1
    public static let titleColorLight: UInt32 = 0x86868A
    /// How far the empty state sits above the navigator's centre.
    public static let raise = 4.5
}
