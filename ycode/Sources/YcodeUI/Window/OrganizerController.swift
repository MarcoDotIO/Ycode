import AppKit

/// The Organizer sidebar (specs/ide/reference-ui-3.md §6): sections and
/// pages, and the empty state of pages without data.
public enum OrganizerSidebar {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var pages: [String]
    }

    public static let sections: [Section] = [
        Section(title: "Products", pages: ["Archives"]),
        Section(title: "Insights", pages: ["Overview"]),
        Section(title: "Reports", pages: ["Crashes", "Disk Writes", "Energy", "Feedback", "Hangs", "Launches"]),
        Section(title: "Metrics", pages: ["Battery Usage", "Disk Writes", "Hang Rate", "Hitches", "Launch Time", "Memory", "Storage", "Terminations"]),
    ]

    /// Flattened rows: a section heading (page nil) or a page.
    public static var rows: [(section: String, page: String?)] {
        sections.flatMap { s in [(s.title, nil)] + s.pages.map { (s.title, $0) } }
    }

    /// Insights, Reports and Metrics need App Store Connect data, which
    /// Ycode does not fetch: they always show the empty state.
    public static func hasData(section: String) -> Bool { section == "Products" }

    /// Empty-state title and message for a page, e.g. "No Overview Data" /
    /// "There is no overview data available for version 1.0.".
    public static func emptyState(page: String, version: String) -> (title: String, message: String) {
        ("No \(page) Data", "There is no \(page.lowercased()) data available for version \(version).")
    }
}

/// The Organizer (Window ▸ Organizer): Archives grouped by application,
/// the selected archive's details, and Distribute App…. See
/// `specs/ide/organizer.md`.
@MainActor
public final class OrganizerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let archivesDirectory: URL
    public private(set) var groups: [(app: String, archives: [ArchiveEntry])] = []
    /// Rows: an application heading, or an archive.
    public private(set) var rows: [(title: String, archive: ArchiveEntry?)] = []
    public private(set) var selected: ArchiveEntry?
    /// The last Distribute App result (status, output).
    public private(set) var lastExport: (status: Int32, output: String)?
    let table = NSTableView()
    let sidebarTable = NSTableView()
    let emptyTitle = NSTextField(labelWithString: "")
    let emptyMessage = NSTextField(labelWithString: "")
    var emptyView: NSView?
    var archivesViews: [NSView] = []
    /// The page shown (sidebar selection) and its section.
    public private(set) var page = "Archives"
    public private(set) var pageSection = "Products"

    /// Shows a sidebar page: Archives shows the archive list; the others
    /// show their empty state.
    public func showPage(_ page: String, section: String) {
        _ = view
        if !navigatingHistory, !(history.indices.contains(historyIndex) && history[historyIndex] == (section, page)) {
            if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)...) }
            history.append((section, page))
            historyIndex = history.count - 1
        }
        self.page = page
        pageSection = section
        let has = OrganizerSidebar.hasData(section: section)
        archivesViews.forEach { $0.isHidden = !has }
        emptyView?.isHidden = has
        let version = selected?.versionText ?? groups.first(where: { $0.app == selectedApp })?.archives.first?.versionText ?? "1.0"
        let e = OrganizerSidebar.emptyState(page: page, version: version)
        emptyTitle.stringValue = e.title
        emptyMessage.stringValue = e.message
        view.window?.title = page
        pageTitle.stringValue = page
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        if let i = OrganizerSidebar.rows.firstIndex(where: { $0.section == section && $0.page == page }), sidebarTable.selectedRow != i {
            sidebarTable.selectRowIndexes([i], byExtendingSelection: false)
        }
    }
    // MARK: Toolbar: back/forward, page title, notifications (§6)

    /// Visited pages (section, page) and the current position.
    public private(set) var history: [(section: String, page: String)] = []
    public private(set) var historyIndex = -1
    private var navigatingHistory = false
    public let backButton = NSButton()
    public let forwardButton = NSButton()
    public let bellButton = NSButton()
    let pageTitle = NSTextField(labelWithString: "Archives")
    /// Whether the notifications popover is shown (toggled by the bell).
    public private(set) var notificationsShown = false
    private var notificationsPopover: NSPopover?
    /// Ycode has no App Store Connect feed, so the list is always empty.
    public static let noNotificationsText = "No Notifications"

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex < history.count - 1 }

    @objc public func goBack() { moveInHistory(-1) }
    @objc public func goForward() { moveInHistory(1) }

    private func moveInHistory(_ step: Int) {
        let i = historyIndex + step
        guard history.indices.contains(i) else { return }
        historyIndex = i
        navigatingHistory = true
        defer { navigatingHistory = false }
        showPage(history[i].page, section: history[i].section)
    }

    @objc public func toggleNotifications() {
        notificationsShown.toggle()
        if notificationsShown, view.window?.isVisible == true {
            let vc = NSViewController()
            let l = NSTextField(labelWithString: Self.noNotificationsText)
            l.textColor = .secondaryLabelColor
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
            l.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(l)
            l.centerXAnchor.constraint(equalTo: box.centerXAnchor).isActive = true
            l.centerYAnchor.constraint(equalTo: box.centerYAnchor).isActive = true
            vc.view = box
            let pop = NSPopover()
            pop.contentViewController = vc
            pop.behavior = .transient
            pop.show(relativeTo: bellButton.bounds, of: bellButton, preferredEdge: .maxY)
            notificationsPopover = pop
        } else {
            notificationsPopover?.close()
            notificationsPopover = nil
        }
    }

    /// Toolbar item identifiers, in order.
    public static let toolbarItems: [NSToolbarItem.Identifier] = [
        .init("organizer.back"), .init("organizer.forward"), .init("organizer.title"), .flexibleSpace, .init("organizer.bell"),
    ]

    /// The Organizer window's toolbar: back/forward, page title, bell.
    public private(set) lazy var toolbar: NSToolbar = {
        for (b, sym, desc, sel) in [(backButton, "chevron.left", "Back", #selector(goBack)), (forwardButton, "chevron.right", "Forward", #selector(goForward)),
                                    (bellButton, "bell", "Notifications", #selector(toggleNotifications))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: desc)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.target = self
            b.action = sel
            b.toolTip = desc
        }
        pageTitle.font = .boldSystemFont(ofSize: 13)
        let t = NSToolbar(identifier: "OrganizerToolbar")
        t.delegate = toolbarDelegate
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        return t
    }()

    private lazy var toolbarDelegate = OrganizerToolbarDelegate(owner: self)

    func toolbarView(for id: NSToolbarItem.Identifier) -> NSView? {
        switch id.rawValue {
        case "organizer.back": return backButton
        case "organizer.forward": return forwardButton
        case "organizer.title": return pageTitle
        case "organizer.bell": return bellButton
        default: return nil
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        installToolbar()
    }

    /// Puts the toolbar on the window the Organizer is shown in.
    public func installToolbar() {
        guard let w = view.window, w.toolbar !== toolbar else { return }
        w.toolbar = toolbar
        w.toolbarStyle = .unified
    }

    let details = NSStackView()
    let distributeButton = NSButton(title: "Distribute App…", target: nil, action: nil)

    public init(archivesDirectory: URL = Organizer.defaultArchivesDirectory) {
        self.archivesDirectory = archivesDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        appPicker.target = self
        appPicker.action = #selector(appPicked(_:))
        let sideCol = NSTableColumn(identifier: .init("side"))
        sidebarTable.addTableColumn(sideCol)
        sidebarTable.headerView = nil
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.style = .sourceList
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebarTable
        let sidebar = NSStackView(views: [appPicker, sideScroll])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        emptyTitle.font = .boldSystemFont(ofSize: 17)
        emptyMessage.textColor = .secondaryLabelColor
        let empty = NSStackView(views: [emptyTitle, emptyMessage])
        empty.orientation = .vertical
        emptyView = empty
        for (id, title, w) in [("name", "Name", 260.0), ("created", "Creation Date", 170.0), ("version", "Version", 90.0), ("status", "Status", 90.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        distributeButton.target = self
        distributeButton.action = #selector(distributeClicked)
        distributeButton.bezelStyle = .rounded
        let side = NSStackView(views: [details, distributeButton])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 14
        side.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        archivesViews = [scroll, side]
        _ = toolbar
        for v in [sidebar, scroll, side, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 180),
            sideScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor, constant: 125), empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor), scroll.trailingAnchor.constraint(equalTo: side.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor), side.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            side.widthAnchor.constraint(equalToConstant: 250),
        ])
        view = root
        reload()
        showPage("Archives", section: "Products")
    }

    /// Archives distributed in this run of Ycode (their status stays
    /// "Exported" when the list is re-read).
    static var exportedPaths: Set<String> = []

    // MARK: App picker (§6: at the top of the sidebar)

    /// The sidebar's app picker: one item per application with archives
    /// ("No App", disabled, before any archive is found).
    public let appPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The application whose archives are listed; nil = none chosen yet
    /// (the first application is used).
    public private(set) var selectedApp: String?

    /// The picker's titles for the current archives.
    public var appPickerTitles: [String] { groups.map(\.app).ifEmpty(["No App"]) }

    /// Chooses the application whose archives (and pages) are shown.
    public func chooseApp(_ app: String) {
        guard groups.contains(where: { $0.app == app }) else { return }
        selectedApp = app
        if selected.map({ $0.appName != app }) ?? false { selected = nil }
        reload()
    }

    @objc func appPicked(_ p: NSPopUpButton) { if let t = p.titleOfSelectedItem { chooseApp(t) } }

    func refreshAppPicker() {
        let titles = appPickerTitles
        if appPicker.itemTitles != titles {
            appPicker.removeAllItems()
            appPicker.addItems(withTitles: titles)
        }
        appPicker.isEnabled = !groups.isEmpty
        if let a = selectedApp { appPicker.selectItem(withTitle: a) } else { appPicker.selectItem(at: 0) }
    }

    public func reload() {
        groups = Organizer.grouped(Organizer.archives(in: archivesDirectory)).map { g in
            var g = g
            for i in g.archives.indices where Self.exportedPaths.contains(g.archives[i].url.standardizedFileURL.path) { g.archives[i].status = "Exported" }
            return g
        }
        if let a = selectedApp, !groups.contains(where: { $0.app == a }) { selectedApp = nil }
        if selectedApp == nil { selectedApp = groups.first?.app }
        rows = groups.filter { $0.app == selectedApp }.flatMap { g in [(g.app, nil)] + g.archives.map { ($0.name, $0) } }
        refreshAppPicker()
        guard isViewLoaded else { return }
        table.reloadData()
        if let s = selected, let i = rows.firstIndex(where: { $0.archive?.url == s.url }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        showDetails()
    }

    /// Selects the archive at a path (Product ▸ Archive opens on the new one).
    public func select(archiveAt url: URL) {
        _ = view
        reload()
        if let app = groups.first(where: { $0.archives.contains { $0.url.standardizedFileURL.path == url.standardizedFileURL.path } })?.app,
           app != selectedApp {
            selectedApp = app
            reload()
        }
        if let i = rows.firstIndex(where: { $0.archive?.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            selected = rows[i].archive
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        showDetails()
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Detail rows for the selection: (label, value).
    public var detailRows: [(String, String)] {
        guard let a = selected else { return [("No Selection", "")] }
        return [("Name", a.name), ("Creation Date", a.created.map(Self.dateFormatter.string(from:)) ?? ""),
                ("Version", a.versionText), ("Identifier", a.bundleIdentifier ?? ""), ("Type", a.hasApplication ? "macOS App Archive" : "Generic Archive"),
                ("Architectures", a.architectures.joined(separator: ", ")), ("Status", a.status), ("Comment", a.comment.isEmpty ? "No Description" : a.comment)]
    }

    func showDetails() {
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (l, v) in detailRows {
            let label = NSTextField(labelWithString: l)
            label.font = .boldSystemFont(ofSize: 11)
            let value = NSTextField(wrappingLabelWithString: v)
            value.font = .systemFont(ofSize: 11)
            value.preferredMaxLayoutWidth = 220
            details.addArrangedSubview(label)
            if !v.isEmpty { details.addArrangedSubview(value) }
        }
        distributeButton.isEnabled = selected?.hasApplication == true
    }

    /// Distribute App → Copy App into `folder`. Returns the exported app.
    @discardableResult
    public func distribute(to folder: URL) -> URL? {
        guard let a = selected, a.hasApplication else { return nil }
        let result = Organizer.exportCopy(a.url, to: folder)
        lastExport = result
        guard result.status == 0 else { return nil }
        Self.exportedPaths.insert(a.url.standardizedFileURL.path)
        if let i = rows.firstIndex(where: { $0.archive?.url == a.url }) {
            rows[i].archive?.status = "Exported"
            selected = rows[i].archive
        }
        showDetails()
        table.reloadData()
        return folder.appendingPathComponent(a.appName + ".app")
    }

    @objc private func distributeClicked() {
        guard view.window?.isVisible == true, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to copy the app (Copy App: mac-application)."
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let url = panel.url { self?.distribute(to: url) }
        }
    }

    // MARK: Table

    public func numberOfRows(in t: NSTableView) -> Int { t === sidebarTable ? OrganizerSidebar.rows.count : rows.count }
    public func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool {
        t === sidebarTable ? OrganizerSidebar.rows[row].page == nil : rows[row].archive == nil
    }
    public func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
        t === sidebarTable ? OrganizerSidebar.rows[row].page != nil : rows[row].archive != nil
    }

    public func tableViewSelectionDidChange(_ n: Notification) {
        if (n.object as? NSTableView) === sidebarTable {
            let i = sidebarTable.selectedRow
            if i >= 0, let p = OrganizerSidebar.rows[i].page { showPage(p, section: OrganizerSidebar.rows[i].section) }
            return
        }
        let r = table.selectedRow
        selected = r >= 0 ? rows[r].archive : nil
        showDetails()
    }

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        if t === sidebarTable {
            let s = OrganizerSidebar.rows[row]
            let l = NSTextField(labelWithString: s.page ?? s.section)
            if s.page == nil { l.font = .boldSystemFont(ofSize: 11); l.textColor = .secondaryLabelColor }
            return l
        }
        let r = rows[row]
        guard let a = r.archive else {
            let l = NSTextField(labelWithString: r.title)
            l.font = .boldSystemFont(ofSize: 12)
            return l
        }
        let text: String = switch c?.identifier.rawValue {
        case "name": a.name
        case "created": a.created.map(Self.dateFormatter.string(from:)) ?? ""
        case "version": a.versionText
        default: a.status
        }
        return NSTextField(labelWithString: text)
    }
}

private extension Array {
    func ifEmpty(_ other: [Element]) -> [Element] { isEmpty ? other : self }
}

@MainActor
final class OrganizerToolbarDelegate: NSObject, NSToolbarDelegate {
    weak var owner: OrganizerController?
    init(owner: OrganizerController) { self.owner = owner }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { OrganizerController.toolbarItems }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { OrganizerController.toolbarItems }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar f: Bool) -> NSToolbarItem? {
        guard let v = owner?.toolbarView(for: id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = v
        item.label = (v as? NSButton)?.toolTip ?? ""
        if id.rawValue == "organizer.back" || id.rawValue == "organizer.forward" { item.isNavigational = true }
        return item
    }
}
