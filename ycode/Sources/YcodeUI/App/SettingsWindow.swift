import AppKit
import YcodeBuild
import YcodeIDECore
import YcodeXcodebuild

/// The settings window: a toolbar of panes; Locations holds the Build
/// System pop-up.
@MainActor
public final class SettingsController: NSViewController {
    public let buildSystemPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let defaults: UserDefaults
    public var onChange: ((BuildSystemPreference) -> Void)?

    let locateSwiftBuild: () -> String?
    /// The note under the pop-up (swbuild path, or the fallback notice).
    public let noteLabel = NSTextField(wrappingLabelWithString: "")

    public init(defaults: UserDefaults = .standard, locateSwiftBuild: @escaping () -> String? = { SwiftBuildEngine.locate() }) {
        self.defaults = defaults
        self.locateSwiftBuild = locateSwiftBuild
        super.init(nibName: nil, bundle: nil)
        title = "Locations"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The pane's card: Build System and the note under it as its help.
    public private(set) var card: SettingsCardView?

    public override func loadView() {
        let root = SettingsFillView(SettingsColors.detail)
        root.frame = NSRect(x: 0, y: 0, width: SettingsMetrics.windowSize.width - SettingsMetrics.detailX,
                            height: SettingsMetrics.windowSize.height - SettingsMetrics.titleAreaHeight)
        for p in BuildSystemPreference.allCases {
            buildSystemPopUp.addItem(withTitle: p == BuildSystemPreference.defaultValue ? "\(p.title) (Default)" : p.title)
            buildSystemPopUp.lastItem?.representedObject = p.rawValue
        }
        let cell = SettingsCardPopUpCell(textCell: "", pullsDown: false)
        cell.isBordered = false
        cell.menu = buildSystemPopUp.menu
        buildSystemPopUp.cell = cell
        buildSystemPopUp.selectItem(at: BuildSystemPreference.allCases.firstIndex(of: .current(defaults)) ?? 0)
        buildSystemPopUp.target = self
        buildSystemPopUp.action = #selector(chosen)
        updateNote()

        let header = SettingsHeaderView("Build")
        let card = SettingsCardView()
        let row = SettingsRowView(label: "Build System", controls: [buildSystemPopUp])
        row.setHelp(noteLabel.stringValue)
        card.add(row)
        self.card = card
        for v in [header, card] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let inset = SettingsMetrics.cardInset
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: SettingsMetrics.firstHeaderCapTop - SettingsMetrics.titleAreaHeight - 3),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: SettingsMetrics.headerToCard + 3 - 16),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
        ])
        view = root
    }

    /// The engine builds actually use with the current choice.
    public var effectiveEngineName: String {
        BuildSystemPreference.current(defaults).makeEngine(locateSwiftBuild: locateSwiftBuild).name
    }

    /// The note: where swbuild is, or that builds fall back to xcodebuild.
    func updateNote() {
        let choice = BuildSystemPreference.current(defaults)
        if choice == .xcodebuild {
            noteLabel.stringValue = "Builds use xcodebuild."
        } else if let path = locateSwiftBuild() {
            noteLabel.stringValue = "swbuild: \(path)"
        } else {
            noteLabel.stringValue = "The swift-build helper was not found (it ships inside Ycode.app; for a build from source, see the README). Builds use xcodebuild until then."
        }
        // The card shows the note as its row's help text.
        if let row = card?.rowViews.first as? SettingsRowView, let help = row.help {
            help.attributedStringValue = SettingsRowView.helpText(noteLabel.stringValue)
        }
    }

    /// Selects a build system as the pop-up would.
    public func choose(_ p: BuildSystemPreference) {
        _ = view
        buildSystemPopUp.selectItem(at: BuildSystemPreference.allCases.firstIndex(of: p) ?? 0)
        chosen()
    }

    @objc private func chosen() {
        guard let raw = buildSystemPopUp.selectedItem?.representedObject as? String,
              let p = BuildSystemPreference(rawValue: raw) else { return }
        p.save(defaults)
        updateNote()
        onChange?(p)
    }
}

/// Ycode ▸ Settings… (⌘,): one shared sidebar window (reference-ui.md §4,
/// `specs/ide/settings.md` R3.1–R3.3): 710 × 452, the pane list flush at
/// the left (179.5 wide, 32-point rows, accent-tinted symbols), the
/// selected pane's grouped cards at the right under the back/forward
/// capsule and its title.
@MainActor
public final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = SettingsWindowController()
    /// The pane list's width.
    public static let sidebarWidth: CGFloat = SettingsMetrics.sidebarWidth
    /// The panes (tabless; the sidebar selects).
    public let tabs = NSTabViewController()
    public let sidebar = NSTableView()
    let titleLabel = NSTextField(labelWithString: "")
    let capsule = SettingsNavigationCapsule()
    var backButton: NSButton { capsule.back }
    var forwardButton: NSButton { capsule.forward }
    final class History { var back: [Int] = []; var forward: [Int] = [] }
    let history = History()

    /// Pane titles in order: the reference's, then Simulators (Ycode's own).
    public static let paneTitles = SettingsPaneOrder.all
    /// The system's symbols, as the spec describes them (looked up at run
    /// time; none depicts a product).
    static let paneSymbols = ["gearshape", "circle.lefthalf.filled", "at.circle", "sparkles", "rectangle.on.rectangle",
                              "arrow.triangle.turn.up.right.diamond", "bell", "square.and.pencil", "keyboard", "arrow.triangle.branch",
                              "square.3.layers.3d", "externaldrive", "server.rack"]

    public init(prefs: Preferences = .shared, components: [ComponentsSettingsPane.Component]? = nil) {
        tabs.tabStyle = .unspecified
        let locations = SettingsController()
        let panes: [NSViewController] = [
            GeneralSettingsPane(prefs: prefs), ThemesSettingsPane(prefs: prefs), AccountsSettingsPane(prefs: prefs),
            CodingAssistantSettingsPane(prefs: prefs), BehaviorsSettingsPane(prefs: prefs), NavigationSettingsPane(prefs: prefs),
            NotificationsSettingsPane(prefs: prefs), TextEditingSettingsPane(prefs: prefs), KeyBindingsSettingsPane(prefs: prefs),
            SourceControlSettingsPane(prefs: prefs), ComponentsSettingsPane(prefs: prefs, components: components),
            locations, SimulatorsSettingsPane(prefs: prefs),
        ]
        for (i, p) in panes.enumerated() {
            let item = NSTabViewItem(viewController: p)
            item.label = Self.paneTitles[i]
            item.image = NSImage(systemSymbolName: Self.paneSymbols[i], accessibilityDescription: Self.paneTitles[i])
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = 0
        let column = NSTableColumn(identifier: .init("pane"))
        column.width = SettingsMetrics.sidebarWidth
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        sidebar.rowHeight = SettingsMetrics.sidebarRowHeight
        sidebar.intercellSpacing = .zero
        sidebar.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sidebar.focusRingType = .none
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // Thirteen rows are taller than the window: the list scrolls.
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // The window: the sidebar flush from the top edge to the bottom,
        // a 0.5-point divider, the white detail pane with the capsule and
        // the title in its title area and the pane under it.
        let size = SettingsMetrics.windowSize
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let side = SettingsFillView(SettingsColors.sidebar)
        let divider = SettingsFillView(SettingsColors.divider)
        let detail = SettingsFillView(SettingsColors.detail)
        for v in [side, divider, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for v in [scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(v)
        }
        for v in [capsule, titleLabel, tabs.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(v)
        }
        titleLabel.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
        titleLabel.textColor = SettingsColors.title
        let cap = SettingsMetrics.capsuleFrame
        let detailX = SettingsMetrics.detailX
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor), side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor), side.widthAnchor.constraint(equalToConstant: SettingsMetrics.sidebarWidth),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor), divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor), divider.widthAnchor.constraint(equalToConstant: SettingsMetrics.dividerWidth),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor), detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: side.topAnchor, constant: SettingsMetrics.sidebarTop),
            scroll.leadingAnchor.constraint(equalTo: side.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: cap.minX - detailX),
            capsule.topAnchor.constraint(equalTo: detail.topAnchor, constant: cap.minY),
            capsule.widthAnchor.constraint(equalToConstant: cap.width), capsule.heightAnchor.constraint(equalToConstant: cap.height),
            // The title's ink starts about 1.5 points after its alignment rect.
            titleLabel.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: SettingsMetrics.titleX - detailX - 1.5),
            titleLabel.centerYAnchor.constraint(equalTo: detail.topAnchor, constant: SettingsMetrics.titleCenterY),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: detail.trailingAnchor, constant: -SettingsMetrics.cardInset),
            tabs.view.leadingAnchor.constraint(equalTo: detail.leadingAnchor), tabs.view.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            tabs.view.topAnchor.constraint(equalTo: detail.topAnchor, constant: SettingsMetrics.titleAreaHeight),
            tabs.view.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = root
        window.title = "General"
        window.titlebarAppearsTransparent = true
        // The pane's title in the detail names it; the window title (Window
        // menu, accessibility) is not drawn.
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the 52-point title area, with the
        // window buttons at x 19, 42 and 65 on y 26 (R3.1).
        window.toolbar = NSToolbar(identifier: "YcodeSettings")
        window.toolbarStyle = .unified
        window.setContentSize(size)
        // Fixed at 710 × 452 (the size on other panes is open, R3.4).
        window.contentMinSize = size
        window.contentMaxSize = size
        window.isMovableByWindowBackground = true
        super.init(window: window)
        sidebar.dataSource = self
        sidebar.delegate = self
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        sidebar.reloadData()
        sidebar.selectRowIndexes([0], byExtendingSelection: false)
        updateTitle()
        locations.onChange = { p in
            // Open workspaces switch engines for their next build.
            for doc in NSDocumentController.shared.documents {
                for wc in doc.windowControllers {
                    (wc as? WorkspaceWindowController)?.session.engine = p.makeEngine()
                    (wc as? WorkspaceWindowController)?.session.buildSystemPreference = p
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var selectedPane: String { Self.paneTitles[tabs.selectedTabViewItemIndex] }

    /// Selects a pane (recorded for back/forward).
    public func select(_ index: Int, recording: Bool = true) {
        guard Self.paneTitles.indices.contains(index), index != tabs.selectedTabViewItemIndex else { return }
        if recording { history.back.append(tabs.selectedTabViewItemIndex); history.forward = [] }
        tabs.selectedTabViewItemIndex = index
        if sidebar.selectedRow != index { sidebar.selectRowIndexes([index], byExtendingSelection: false) }
        updateTitle()
    }

    @objc public func goBack() {
        guard let i = history.back.popLast() else { return }
        history.forward.append(tabs.selectedTabViewItemIndex)
        select(i, recording: false)
    }

    @objc public func goForward() {
        guard let i = history.forward.popLast() else { return }
        history.back.append(tabs.selectedTabViewItemIndex)
        select(i, recording: false)
    }

    func updateTitle() {
        titleLabel.stringValue = selectedPane
        window?.title = selectedPane
        backButton.isEnabled = !history.back.isEmpty
        forwardButton.isEnabled = !history.forward.isEmpty
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { Self.paneTitles.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        SettingsSidebarCellView(title: Self.paneTitles[row], symbolName: Self.paneSymbols[row])
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SettingsSidebarRowView() }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if sidebar.selectedRow >= 0 { select(sidebar.selectedRow) }
    }

    /// Shows the window on the named pane.
    public func show(pane title: String) {
        if let i = Self.paneTitles.firstIndex(of: title) { select(i) }
        showWindow(nil)
    }

    public func pane<T: NSViewController>(_ type: T.Type) -> T? {
        tabs.tabViewItems.compactMap { $0.viewController as? T }.first
    }
}
