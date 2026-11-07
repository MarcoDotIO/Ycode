import AppKit
import YcodeIDECore

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
    /// reference-ui-6.md §1.4 (W5): the buttons row's widths, height,
    /// spacing and top (from the window's top); the close button's size and
    /// offset from the top left.
    public static let buttonWidths: [CGFloat] = [107, 107, 130]
    public static let buttonHeight: CGFloat = 36
    public static let buttonSpacing: CGFloat = 8
    public static let buttonsTop: CGFloat = 242
    public static let closeButtonSize: CGFloat = 36
    public static let closeButtonInset: CGFloat = 20
    /// liquid-glass.md §2.10: the recent list's box, from the window's top
    /// left (macOS 26 and later).
    public static let recentsBoxFrame = NSRect(x: 60, y: 295, width: 360, height: 277)
    /// metrics.md §13.4: the app name is bold with capitals 13 points
    /// tall; its baseline 38 and the version line's 19 above the buttons.
    public static let nameCapHeight: CGFloat = 13
    public static let nameBaselineAboveButtons: CGFloat = 38
    public static let versionBaselineAboveButtons: CGFloat = 19
    /// metrics.md §16.3 (checklist row 80): the icon's drawn square is 98
    /// points, its bottom 15.5 above the name's capitals. The image keeps
    /// its own margin (the field spans 100–924 of 1024), so its view is
    /// larger by that.
    public static let iconVisibleSide: CGFloat = 98
    public static let iconGapAboveName: CGFloat = 15.5
    static var iconMarginFraction: CGFloat { CGFloat(ProductIconGeometry.fieldMin / ProductIconGeometry.side) }
    public static var iconFrameSide: CGFloat {
        iconVisibleSide / CGFloat((ProductIconGeometry.fieldMax - ProductIconGeometry.fieldMin) / ProductIconGeometry.side)
    }
    /// The icon view's top, from the window's top.
    public static var iconFrameTop: CGFloat {
        let capTop = buttonsTop - nameBaselineAboveButtons - nameCapHeight
        return capTop - iconGapAboveName + iconFrameSide * iconMarginFraction - iconFrameSide
    }
    /// metrics.md §13.4: recent rows on a 47-point pitch; the separators
    /// run under the text (from its leading edge) to 14 points before the
    /// box's right edge.
    public static let recentRowPitch: CGFloat = 47
    public static let recentTextLeading: CGFloat = 56
    public static let recentSeparatorTrailing: CGFloat = 14

    /// The bold system font whose capitals are `capHeight` tall.
    static func nameFont(capHeight: CGFloat = nameCapHeight) -> NSFont {
        let unit = NSFont.systemFont(ofSize: 100, weight: .bold).capHeight / 100
        return .systemFont(ofSize: (capHeight / max(0.01, unit) * 4).rounded() / 4, weight: .bold)
    }

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
    /// The round close button at the top left (no traffic lights, W5).
    public let closeButton: NSButton = RoundButton()
    /// The rounded inset box holding the recent list, and its scroll view.
    public let recentsBox: NSView = RecentsBoxView()
    public let recentsScroll = NSScrollView()
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
    /// Where New Project ▸ App puts its untitled project (W6).
    public var untitledProjectsLocation = UntitledAppProject.defaultLocation
    /// Opens an untitled project on its entry file; the completion reports
    /// success. Tests replace it.
    public var openUntitled: (UntitledAppProject.Created, @escaping (Bool) -> Void) -> Void = { created, done in
        NSDocumentController.shared.openDocument(withContentsOf: created.project, display: true) { doc, _, error in
            if let error { NSApp.presentError(error) }
            for wc in doc?.windowControllers ?? [] { (wc as? WorkspaceWindowController)?.showUntitledProject(entryFile: created.entryFile) }
            done(doc != nil)
        }
    }
    private var recentsObserver: NSObjectProtocol?

    public static var versionText: String { ProductIdentity.versionText }

    public init(recents: RecentProjects = .shared) {
        self.recents = recents
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Self.title  // the accessibility title; no title text is drawn
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // §1.4 (W5): no traffic lights; a round close button of its own.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        super.init(window: window)
        build()
        reload()
        placeOnScreen()
        recentsObserver = NotificationCenter.default.addObserver(forName: RecentProjects.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        iconView.image = ProductIcon.image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = GlassBars.enabled ? Self.nameFont() : .systemFont(ofSize: 34, weight: .bold)
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
        // §1.5 (W6): App, Command Line Tool, Package…, Playground, —,
        // Choose Template….
        for (i, row) in NewProjectPicker.rows.enumerated() {
            if i == NewProjectPicker.chooseTemplateIndex { newProjectButton.menu?.addItem(.separator()) }
            let item = NSMenuItem(title: row.title, action: #selector(newProjectChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.toolTip = row.subtitle
            newProjectButton.menu?.addItem(item)
        }
        // §1.4 (W5): 107, 107 and 130 wide, 36 tall, 8 apart, centered.
        for b in [openButton, cloneButton] { b.bezelStyle = .flexiblePush }
        newProjectButton.bezelStyle = .flexiblePush
        if #available(macOS 26, *) {
            // liquid-glass.md §2.10: flat filled capsules (no bezel shadow).
            for b in [openButton, cloneButton] as [NSButton] { b.bezelStyle = .push; b.borderShape = .capsule }
            newProjectButton.bezelStyle = .push
            newProjectButton.borderShape = .capsule
        }
        let buttons = NSStackView(views: [openButton, cloneButton, newProjectButton])
        buttons.orientation = .horizontal
        buttons.spacing = Self.buttonSpacing
        buttons.distribution = .fill
        for (b, w) in zip([openButton, cloneButton, newProjectButton] as [NSView], Self.buttonWidths) {
            b.widthAnchor.constraint(equalToConstant: w).isActive = true
            b.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        }

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        if #available(macOS 26, *) {
            // A round glass button (liquid-glass-ycode.md §4): the system
            // draws the material, its contrast and its pressed state.
            closeButton.bezelStyle = .glass
            closeButton.borderShape = .circle
            closeButton.isBordered = true
        } else {
            closeButton.isBordered = false
            closeButton.wantsLayer = true
            closeButton.layer?.cornerRadius = Self.closeButtonSize / 2
            closeButton.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityTitle("Close")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recent"))
        table.addTableColumn(column)
        table.headerView = nil
        // metrics.md §13.4: rows on a 47-point pitch (no gap between
        // them), the selection inset 8.
        table.rowHeight = GlassBars.enabled ? Self.recentRowPitch : 44
        if GlassBars.enabled { table.intercellSpacing = NSSize(width: table.intercellSpacing.width, height: 0) }
        // liquid-glass.md §2.10 (macOS 26+): the selection is a rounded
        // rectangle inset 8 with 8-point corners (`RecentRowView`).
        table.style = GlassBars.enabled ? .fullWidth : .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onReturn = { [weak self] in self?.openSelected(nil) }
        table.setAccessibilityLabel(Self.recentProjectsTitle)
        // §1.4 (W5): an inset box with rounded corners, no visible
        // heading ("Recent Projects" is the list's accessibility name), and
        // no permanently visible scroller.
        let scroll = recentsScroll
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        scroll.translatesAutoresizingMaskIntoConstraints = false
        recentsBox.addSubview(scroll)

        for v in [iconView, nameLabel, versionLabel, buttons, recentsBox, emptyLabel, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: GlassBars.enabled ? Self.iconFrameTop : 48),
            iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: GlassBars.enabled ? Self.iconFrameSide : 112),
            iconView.heightAnchor.constraint(equalToConstant: GlassBars.enabled ? Self.iconFrameSide : 112),
            GlassBars.enabled
                ? nameLabel.firstBaselineAnchor.constraint(equalTo: content.topAnchor, constant: Self.buttonsTop - Self.nameBaselineAboveButtons)
                : nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            nameLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            GlassBars.enabled
                ? versionLabel.firstBaselineAnchor.constraint(equalTo: content.topAnchor, constant: Self.buttonsTop - Self.versionBaselineAboveButtons)
                : versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            versionLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.buttonsTop),
            buttons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            // liquid-glass.md §2.10 (macOS 26+): the box spans x 60–420,
            // y 295–572; before, 20 from the sides and the bottom.
            GlassBars.enabled ? recentsBox.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.recentsBoxFrame.minY)
                : recentsBox.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 28),
            recentsBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: GlassBars.enabled ? Self.recentsBoxFrame.minX : 20),
            recentsBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: GlassBars.enabled ? Self.recentsBoxFrame.maxX - Self.size.width : -20),
            GlassBars.enabled ? recentsBox.heightAnchor.constraint(equalToConstant: Self.recentsBoxFrame.height)
                : recentsBox.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: recentsBox.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: recentsBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: recentsBox.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: recentsBox.bottomAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: recentsBox.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: recentsBox.centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.closeButtonInset),
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.closeButtonInset),
            closeButton.widthAnchor.constraint(equalToConstant: Self.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.closeButtonSize),
        ])
    }

    /// Re-reads the recent list; the first row is selected.
    public func reload() {
        entries = recents.urls
        table.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    /// How much lower than AppKit's `center()` the window sits
    /// (`editor-area.md` F.11, checklist row 112: the same 480 × 629
    /// frame, 8 points lower).
    public static let belowSystemCentre: CGFloat = 8

    /// Centres the window as the reference does: AppKit's centring, 8
    /// points lower, kept on the screen.
    func placeOnScreen() {
        guard let window else { return }
        window.center()
        var origin = window.frame.origin
        origin.y -= Self.belowSystemCentre
        if let visible = window.screen?.visibleFrame { origin.y = max(origin.y, visible.minY) }
        window.setFrameOrigin(origin)
    }

    /// Shows the window (centered the first time) and refreshes the list.
    public func present() {
        reload()
        if window?.isVisible != true { placeOnScreen() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard GlassBars.enabled else { return nil }
        let v = RecentRowView()
        v.showsSeparator = row < entries.count - 1
        return v
    }

    /// A row: the container's icon, its name without extension, and its
    /// folder (each text is its own tooltip).
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = entries[row]
        let cell = NSTableCellView()
        // §1.4 (W5): a package has a package glyph, not a folder.
        let icon = NSImageView(image: Self.rowIcon(url))
        let name = NSTextField(labelWithString: RecentProjects.displayName(url))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.toolTip = name.stringValue
        name.lineBreakMode = .byTruncatingTail
        let folder = NSTextField(labelWithString: RecentProjects.folderText(url))
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.toolTip = folder.stringValue
        // metrics.md §13.4: the path keeps its end ("…/captures/…").
        folder.lineBreakMode = .byTruncatingHead
        for v in [icon, name, folder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.textField = name
        cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: GlassBars.enabled ? Self.recentTextLeading - 40 : 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: GlassBars.enabled ? -16 : -4),
            name.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: GlassBars.enabled ? -16 : -4),
            folder.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
        ])
        return cell
    }

    /// A row's icon: a package glyph for a package folder, else the
    /// file's icon.
    static func rowIcon(_ url: URL) -> NSImage {
        if isPackage(url), let glyph = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Package")?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) { return glyph }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// A package entry: a folder (not a project or workspace) holding a
    /// manifest.
    static func isPackage(_ url: URL) -> Bool {
        !["xcodeproj", "xcworkspace"].contains(url.pathExtension)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
    }

    // MARK: Actions

    @objc func closeClicked(_ sender: Any?) { window?.performClose(sender) }

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
        clone(f.stringValue, into: dir)
    }

    /// Clones off the main thread, with a sheet that says so, then opens the
    /// clone's workspace; a repository with none is shown in Finder.
    @discardableResult
    public func clone(_ address: String, into dir: URL) -> Task<Void, Never> {
        let dest = dir.appendingPathComponent(GitRepository.cloneFolderName(for: address))
        let progress = CloneProgressSheet.begin(name: dest.lastPathComponent, on: window)
        return Task { [weak self] in
            let failure: String? = await Task.detached {
                do { try GitRepository.clone(address, into: dest); return nil } catch { return error.localizedDescription }
            }.value
            progress?.end()
            if let failure { NSApp.presentError(NSError(domain: "Ycode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not clone “\(address)”.", NSLocalizedRecoverySuggestionErrorKey: failure])); return }
            if let ws = Self.workspace(in: dest) { self?.open(ws) } else if NSApp.isRunning { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
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

    /// A New Project pull-down row (the compact picker's rows). App makes
    /// an untitled project at once (§1.5, W6); the others keep the sheet.
    @discardableResult
    @objc func newProjectChosen(_ sender: Any?) -> NewProjectSheetController? {
        guard let i = (sender as? NSMenuItem)?.tag else { return nil }
        if NewProjectPicker.template(forRow: i) == .app {
            createUntitledApp()
            return nil
        }
        return NewProjectFlow.start(row: i, defaults: Preferences.shared.defaults, location: newProjectLocation, parent: window,
                                    interactive: window?.isVisible == true,
                                    onCreated: { [weak self] created in
                                        self?.open(created.openURL)
                                        if let entry = created.entryFile { NewProjectFlow.openEntry(entry, of: created.openURL) }
                                    },
                                    onError: { text in
                                        NSApp.presentError(NSError(domain: "Ycode", code: 1, userInfo: [NSLocalizedDescriptionKey: text]))
                                    })
    }
}

extension WelcomeWindowController {
    /// New Project ▸ App: the untitled project, opened on its entry file;
    /// the Welcome window closes once it opens.
    @discardableResult
    public func createUntitledApp() -> UntitledAppProject.Created? {
        do {
            let created = try UntitledAppProject.create(in: untitledProjectsLocation)
            openUntitled(created) { [weak self] ok in if ok { self?.close() } }
            return created
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }
}

/// The sheet shown while `git clone` runs.
@MainActor
final class CloneProgressSheet {
    private let sheet: NSWindow
    private weak var parent: NSWindow?

    private init(sheet: NSWindow, parent: NSWindow) {
        self.sheet = sheet
        self.parent = parent
    }

    /// Nil when there is no visible window to attach it to (tests).
    static func begin(name: String, on parent: NSWindow?) -> CloneProgressSheet? {
        guard let parent, parent.isVisible else { return nil }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 84), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "Cloning “\(name)”…")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(row)
        if let c = w.contentView {
            NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: c.centerXAnchor), row.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
        }
        parent.beginSheet(w)
        return CloneProgressSheet(sheet: w, parent: parent)
    }

    func end() { parent?.endSheet(sheet) }
}

extension WorkspaceWindowController {
    /// An untitled project's first look (reference-ui-6.md §1.5, W6): the
    /// entry file in the editor, the inspector hidden, My Mac as the
    /// destination (remembered for the scheme).
    public func showUntitledProject(entryFile: URL) {
        open(path: entryFile.path, line: nil)
        inspectorItem?.isCollapsed = true
        if let mac = session.model.destinations.first(where: { $0.kind == .mac }) {
            session.destination = mac
            rememberDestination()
            rebuildDestinationMenu()
        }
        updateToolbarState()
    }
}

/// The rounded inset box holding the recent list (§1.4, W5). With the
/// Liquid Glass design (macOS 26 and later) it is a quiet system fill with
/// 12-point continuous corners and no stroke (`specs/ide/liquid-glass.md`
/// §2.10), a stroke only with Increase Contrast; earlier
/// systems keep the stroked box. Layer colors are set in `updateLayer`, so
/// they follow light and dark.
final class RecentsBoxView: NSView {
    /// The corner radius with the Liquid Glass design.
    static let glassCornerRadius: CGFloat = 12
    private var contrastObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        updateLayer()   // the shape before the first display
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        if #available(macOS 26, *) {
            layer.cornerRadius = Self.glassCornerRadius
            layer.cornerCurve = .continuous
            layer.backgroundColor = NSColor.quaternarySystemFill.cgColor
            layer.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        } else {
            layer.cornerRadius = 10
            layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
            layer.borderWidth = 1
        }
        layer.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A borderless button whose frame is its drawn circle (no alignment
/// insets), for the Welcome window's close button.
/// A Welcome recent row with the reference's selection: a rounded
/// rectangle inset 8 from the box's sides, 8-point continuous corners,
/// the system's selection color (accent while the list is focused).
final class RecentRowView: NSTableRowView {
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    /// metrics.md §13.4: a 1-point separator under the text, not under the
    /// icon; none under the last row, and none touching a selected row.
    var showsSeparator = false { didSet { needsDisplay = true } }

    /// The separator's frame in the row (nil: none drawn).
    var separatorRect: NSRect? {
        guard showsSeparator, !isSelected, !isNextRowSelected else { return nil }
        let x = WelcomeWindowController.recentTextLeading
        let w = bounds.width - x - WelcomeWindowController.recentSeparatorTrailing
        guard w > 0 else { return nil }
        return NSRect(x: x, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: w, height: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let r = separatorRect else { return }
        NSColor.separatorColor.setFill()
        r.fill()
    }

    override var isNextRowSelected: Bool { didSet { needsDisplay = true } }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset, dy: 0), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
}

final class RoundButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// The Recent Projects table: Return opens the selected row.
@MainActor
public final class RecentProjectsTable: NSTableView {
    var onReturn: (() -> Void)?
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}
