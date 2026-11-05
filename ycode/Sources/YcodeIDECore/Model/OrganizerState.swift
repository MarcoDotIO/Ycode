import Foundation

/// The Organizer window's state, shared by the macOS IDE
/// (`OrganizerController`) and the Linux IDE (`OrganizerShellModel`): the
/// archives grouped by application, the app picker, the list's rows, the
/// selection and its details, the sidebar page with its back/forward
/// history, and the notifications popover. Each IDE only draws it. See
/// `specs/ide/organizer.md` and `specs/ide/reference-ui-3.md` §6.
public struct OrganizerState: Sendable {
    /// One row of the archive list: an application heading (no archive) or
    /// an archive.
    public struct Row: Equatable, Sendable {
        public var title: String
        public var archive: ArchiveEntry?
    }

    /// A column of the archive list: its identifier, title and width (in
    /// points; together they fit the list's 454 points between the sidebar
    /// and the details, so every column shows without scrolling).
    public struct Column: Equatable, Sendable {
        public var id: String
        public var title: String
        public var width: Double
    }

    /// Name, Creation Date, Version, Status (`organizer.md` §Archives).
    public static let columns: [Column] = [
        Column(id: "name", title: "Name", width: 118), Column(id: "created", title: "Creation Date", width: 170),
        Column(id: "version", title: "Version", width: 70), Column(id: "status", title: "Status", width: 74),
    ]

    public private(set) var groups: [(app: String, archives: [ArchiveEntry])] = []
    public private(set) var rows: [Row] = []
    /// The application whose archives are listed; nil before any archive is
    /// found (the first application is used).
    public private(set) var selectedApp: String?
    public private(set) var selected: ArchiveEntry?
    /// The page shown (sidebar selection) and its section.
    public private(set) var page = "Archives"
    public private(set) var section = "Products"
    /// Visited pages (section, page) and the current position.
    public private(set) var history: [(section: String, page: String)] = []
    public private(set) var historyIndex = -1
    /// Whether the notifications popover is shown (toggled by the bell).
    public var notificationsShown = false
    /// Ycode has no App Store Connect feed, so the list is always empty.
    public static let noNotificationsText = "No Notifications"
    /// The Distribute App button's title.
    public static let distributeTitle = "Distribute App…"
    /// The archive row's menu item that shows the archive in the desktop's
    /// file manager.
    #if os(macOS)
    public static let showInFilesTitle = "Show in Finder"
    #else
    public static let showInFilesTitle = "Show in Files"
    #endif

    /// Opens on Archives, the first page of the history.
    public init() { showPage(page, section: section) }

    // MARK: Archives

    /// Takes a fresh list of archives (`Organizer.archives(in:)`); those
    /// whose standardized paths are in `exported` read "Exported". Keeps the
    /// chosen application and the selection when they are still there.
    public mutating func load(_ archives: [ArchiveEntry], exported: Set<String> = []) {
        groups = Organizer.grouped(archives).map { g in
            var g = g
            for i in g.archives.indices where exported.contains(g.archives[i].url.standardizedFileURL.path) { g.archives[i].status = "Exported" }
            return g
        }
        if let a = selectedApp, !groups.contains(where: { $0.app == a }) { selectedApp = nil }
        if selectedApp == nil { selectedApp = groups.first?.app }
        rebuildRows()
        if let s = selected { selected = rows.first { $0.archive?.url == s.url }?.archive }
    }

    private mutating func rebuildRows() {
        rows = groups.filter { $0.app == selectedApp }.flatMap { g in [Row(title: g.app)] + g.archives.map { Row(title: $0.name, archive: $0) } }
    }

    /// The app picker's titles: one per application ("No App" before any
    /// archive is found).
    public var appPickerTitles: [String] { groups.isEmpty ? ["No App"] : groups.map(\.app) }

    /// Chooses the application whose archives (and pages) are shown; the
    /// selection goes when it belongs to another application.
    public mutating func chooseApp(_ app: String) {
        guard groups.contains(where: { $0.app == app }) else { return }
        selectedApp = app
        if selected.map({ $0.appName != app }) ?? false { selected = nil }
        rebuildRows()
    }

    /// The row of the selection (nil: none).
    public var selectedRow: Int? {
        guard let s = selected else { return nil }
        return rows.firstIndex { $0.archive?.url == s.url }
    }

    /// Selects a row; a heading or a row out of range clears the selection.
    public mutating func selectRow(_ row: Int?) {
        selected = row.flatMap { rows.indices.contains($0) ? rows[$0].archive : nil }
    }

    /// Selects the archive at a path, switching to its application
    /// (Product ▸ Archive opens on the new archive). Returns its row.
    @discardableResult
    public mutating func select(archiveAt url: URL) -> Int? {
        let path = url.standardizedFileURL.path
        if let app = groups.first(where: { $0.archives.contains { $0.url.standardizedFileURL.path == path } })?.app, app != selectedApp {
            selectedApp = app
            rebuildRows()
        }
        guard let i = rows.firstIndex(where: { $0.archive?.url.standardizedFileURL.path == path }) else { return nil }
        selected = rows[i].archive
        return i
    }

    /// Marks an archive "Exported" (after a successful Distribute App).
    public mutating func markExported(_ url: URL) {
        let path = url.standardizedFileURL.path
        func same(_ a: ArchiveEntry?) -> Bool { a?.url.standardizedFileURL.path == path }
        for g in groups.indices {
            for i in groups[g].archives.indices where same(groups[g].archives[i]) { groups[g].archives[i].status = "Exported" }
        }
        for i in rows.indices where same(rows[i].archive) { rows[i].archive?.status = "Exported" }
        if same(selected) { selected?.status = "Exported" }
    }

    // MARK: Texts

    /// The Creation Date column's and detail's format (medium date, short
    /// time, in the user's locale).
    nonisolated(unsafe) public static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static func dateText(_ date: Date?) -> String { date.map(dateFormatter.string(from:)) ?? "" }

    /// What an archive's cell in a column says.
    public static func cellText(_ a: ArchiveEntry, column: String) -> String {
        switch column {
        case "name": a.name
        case "created": dateText(a.created)
        case "version": a.versionText
        default: a.status
        }
    }

    /// Detail rows for the selection: (label, value); "No Selection" alone
    /// without one.
    public var detailRows: [(String, String)] {
        guard let a = selected else { return [("No Selection", "")] }
        return [("Name", a.name), ("Creation Date", Self.dateText(a.created)),
                ("Version", a.versionText), ("Identifier", a.bundleIdentifier ?? ""), ("Type", a.hasApplication ? "macOS App Archive" : "Generic Archive"),
                ("Architectures", a.architectures.joined(separator: ", ")), ("Status", a.status), ("Comment", a.comment.isEmpty ? "No Description" : a.comment)]
    }

    /// Whether Distribute App applies to the selection (an archive with an
    /// application).
    public var canDistribute: Bool { selected?.hasApplication == true }

    // MARK: Pages and history

    /// Whether the page shows the archive list (Products) or an empty state.
    public var showsArchives: Bool { OrganizerSidebar.hasData(section: section) }

    /// The empty state of the page: "No Overview Data" / "There is no
    /// overview data available for version 1.0.".
    public var emptyState: (title: String, message: String) {
        let version = selected?.versionText ?? groups.first(where: { $0.app == selectedApp })?.archives.first?.versionText ?? "1.0"
        return OrganizerSidebar.emptyState(page: page, version: version.isEmpty ? "1.0" : version)
    }

    /// Shows a sidebar page, recording it in the history (a new page drops
    /// the pages ahead of the current one).
    public mutating func showPage(_ page: String, section: String) {
        if !(history.indices.contains(historyIndex) && history[historyIndex] == (section, page)) {
            if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)...) }
            history.append((section, page))
            historyIndex = history.count - 1
        }
        self.page = page
        self.section = section
    }

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex < history.count - 1 }

    /// Moves back (-1) or forward (+1) in the history; false at its ends.
    @discardableResult
    public mutating func moveInHistory(_ step: Int) -> Bool {
        let i = historyIndex + step
        guard history.indices.contains(i) else { return false }
        historyIndex = i
        page = history[i].page
        section = history[i].section
        return true
    }

    /// The sidebar row of the page (`OrganizerSidebar.rows`).
    public var sidebarRow: Int? { OrganizerSidebar.rows.firstIndex { $0.section == section && $0.page == page } }
}
