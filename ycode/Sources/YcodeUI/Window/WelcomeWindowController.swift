import AppKit

/// The Welcome window (`specs/ide/reference-ui-5.md` §3.1, L1, L2): shown
/// at launch when there is no document to open, and by Window ▸ Welcome to
/// Ycode (⇧⌘1). Ycode's icon, name and version; Open…, Clone… and a New
/// Project pull-down; the Recent Projects list.
@MainActor
public final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let size = NSSize(width: 480, height: 632)
    public static let title = "Welcome to Ycode"
    public static let recentProjectsTitle = "Recent Projects"
    public static let buttonTitles = ["Open…", "Clone…", "New Project"]

    public let recents: RecentProjects
    /// The list's entries, newest first (the same as File ▸ Open Recent).
    public private(set) var entries: [URL] = []

    public let iconView = NSImageView()
    public let nameLabel = NSTextField(labelWithString: "Ycode")
    public let versionLabel = NSTextField(labelWithString: "")
    public let openButton = NSButton(title: "Open…", target: nil, action: nil)
    public let cloneButton = NSButton(title: "Clone…", target: nil, action: nil)
    /// A pull-down: its first item is the button's title.
    public let newProjectButton = NSPopUpButton(frame: .zero, pullsDown: true)
    public let table = RecentProjectsTable()
    let emptyLabel = NSTextField(labelWithString: "No Recent Projects")

    /// Opens a workspace; the completion reports success. Tests replace it.
    public var openWorkspace: (URL, @escaping (Bool) -> Void) -> Void = { url, done in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error { NSApp.presentError(error) }
            done(doc != nil)
        }
    }
    /// Where New Project puts projects when no panel is shown.
    public var newProjectLocation = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
    private var recentsObserver: NSObjectProtocol?

    /// "Version <short version>": the bundle's short version string.
    public static var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return "Version \(v)"
    }

    public init(recents: RecentProjects = .shared) {
        self.recents = recents
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Self.title  // the accessibility title; no title text is drawn
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        build()
        reload()
        window.center()
        recentsObserver = NotificationCenter.default.addObserver(forName: RecentProjects.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        iconView.image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 34, weight: .bold)
        nameLabel.alignment = .center
        versionLabel.stringValue = Self.versionText
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        for (b, action) in [(openButton, #selector(openClicked(_:))), (cloneButton, #selector(cloneClicked(_:)))] {
            b.target = self
            b.action = action
            b.bezelStyle = .push
            b.controlSize = .large
        }
        newProjectButton.controlSize = .large
        newProjectButton.addItem(withTitle: "New Project")  // the pull-down's title item
        for (i, row) in NewProjectPicker.rows.enumerated() {
            let item = NSMenuItem(title: row.title, action: #selector(newProjectChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.toolTip = row.subtitle
            newProjectButton.menu?.addItem(item)
        }
        let buttons = NSStackView(views: [openButton, cloneButton, newProjectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let heading = NSTextField(labelWithString: Self.recentProjectsTitle)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onReturn = { [weak self] in self?.openSelected(nil) }
        table.setAccessibilityLabel(Self.recentProjectsTitle)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        for v in [iconView, nameLabel, versionLabel, buttons, heading, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 112),
            iconView.heightAnchor.constraint(equalToConstant: 112),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            nameLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            versionLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 22),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            heading.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 26),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    /// Re-reads the recent list; the first row is selected.
    public func reload() {
        entries = recents.urls
        table.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    /// Shows the window (centered the first time) and refreshes the list.
    public func present() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    /// A row: the container's icon, its name without extension, and its
    /// folder (each text is its own tooltip).
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = entries[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        let name = NSTextField(labelWithString: RecentProjects.displayName(url))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.toolTip = name.stringValue
        name.lineBreakMode = .byTruncatingTail
        let folder = NSTextField(labelWithString: RecentProjects.folderText(url))
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.toolTip = folder.stringValue
        folder.lineBreakMode = .byTruncatingMiddle
        for v in [icon, name, folder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.textField = name
        cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            name.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            folder.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
        ])
        return cell
    }

    // MARK: Actions

    /// Opening a workspace from here closes the window.
    func open(_ url: URL) {
        openWorkspace(url) { [weak self] ok in if ok { self?.close() } }
    }

    /// Double-click or Return on a row.
    @objc public func openSelected(_ sender: Any?) {
        let row = table.clickedRow >= 0 && sender is NSTableView ? table.clickedRow : table.selectedRow
        guard entries.indices.contains(row) else { return }
        open(entries[row])
    }

    /// "Open…": the Open panel.
    @objc func openClicked(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] r in
            guard r == .OK else { return }
            MainActor.assumeIsolated { for u in panel.urls { self?.open(u) } }
        }
    }

    /// "Clone…": a repository URL, then the folder to clone into; the
    /// clone's workspace opens when it has one.
    @objc func cloneClicked(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Clone"
        a.informativeText = "Enter a repository URL."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        f.placeholderString = "https://…"
        a.accessoryView = f
        a.addButton(withTitle: "Clone")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Clone"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let name = URL(string: f.stringValue)?.deletingPathExtension().lastPathComponent ?? "Repository"
        let dest = dir.appendingPathComponent(name)
        do {
            try GitRepository.clone(f.stringValue, into: dest)
            if let ws = Self.workspace(in: dest) { open(ws) }
        } catch {
            NSApp.presentError(error)
        }
    }

    /// The workspace to open in a folder: a `.xcworkspace` (not one inside
    /// a project), else a `.xcodeproj`, else the folder when it holds a
    /// `Package.swift`.
    public static func workspace(in dir: URL) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        if let w = names.first(where: { $0.hasSuffix(".xcworkspace") }) { return dir.appendingPathComponent(w) }
        if let p = names.first(where: { $0.hasSuffix(".xcodeproj") }) { return dir.appendingPathComponent(p) }
        return names.contains("Package.swift") ? dir : nil
    }

    /// A New Project pull-down row (the compact picker's rows).
    @discardableResult
    @objc func newProjectChosen(_ sender: Any?) -> NewProjectSheetController? {
        guard let i = (sender as? NSMenuItem)?.tag else { return nil }
        return NewProjectFlow.start(row: i, defaults: Preferences.shared.defaults, location: newProjectLocation, parent: window,
                                    interactive: window?.isVisible == true,
                                    onCreated: { [weak self] url in self?.open(url) },
                                    onError: { text in
                                        NSApp.presentError(NSError(domain: "Ycode", code: 1, userInfo: [NSLocalizedDescriptionKey: text]))
                                    })
    }
}

/// The Recent Projects table: Return opens the selected row.
@MainActor
public final class RecentProjectsTable: NSTableView {
    var onReturn: (() -> Void)?
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// New Project from a compact-picker row (`reference-ui-3.md` §5.4): a
/// direct row skips the template step. Used by File ▸ New ▸ Project… and
/// the Welcome window's New Project pull-down.
@MainActor
enum NewProjectFlow {
    /// - Parameters:
    ///   - interactive: present the sheet in its own window and ask for
    ///     the folder; otherwise (tests, headless) create in `location`.
    static func start(row i: Int, defaults: UserDefaults, location: URL, parent: NSWindow?, interactive: Bool,
                      onCreated: @escaping (URL) -> Void, onError: @escaping (String) -> Void) -> NewProjectSheetController {
        let sheet = NewProjectSheetController(defaults: defaults)
        if let t = NewProjectPicker.template(forRow: i) {
            switch t {
            case .app: sheet.setPlatform("iOS"); sheet.select(title: "App")
            case .commandLineTool: sheet.setPlatform("macOS"); sheet.select(title: "Command Line Tool")
            case .swiftPackage: sheet.setPlatform("Other"); sheet.select(title: "Swift Package")
            }
            sheet.nextClicked()
        }
        var host: NSWindow?
        var hostController: WorkspaceWindowController?
        sheet.onCancel = { host?.close(); hostController = nil }
        sheet.onFinish = { [weak sheet] platform, title, options in
            guard let t = ProjectTemplateCatalog.template(platform: platform, title: title) else {
                NSApp.presentError(NSError(domain: "Ycode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ycode cannot create “\(title)” projects yet."]))
                return
            }
            let finish: (URL) -> Void = { dir in
                do {
                    let url = try t.create(platform: platform, options: options, in: dir)
                    sheet?.dismiss(nil); host?.close(); hostController = nil
                    onCreated(url)
                } catch { onError("\(error)") }
            }
            if let w = host ?? parent, w.isVisible {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Create"
                panel.directoryURL = location
                panel.beginSheetModal(for: w) { r in if r == .OK, let u = panel.url { finish(u) } }
            } else {
                finish(location)
            }
        }
        if interactive {
            // A real, empty workspace window behind the sheet (§11.3).
            let wc = emptyWorkspaceWindow()
            hostController = wc
            wc.showWindow(nil)
            host = wc.window
            wc.contentViewController?.presentAsSheet(sheet)
        }
        return sheet
    }
}
