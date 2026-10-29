import AppKit
import YcodeBuild
import YcodeXcodebuild

/// Ycode ▸ Settings ▸ Locations ▸ Build System. See
/// `specs/ide/settings.md`.
public enum BuildSystemPreference: String, CaseIterable, Sendable {
    case xcodebuild
    case swiftBuild = "swift-build"

    public static let defaultsKey = "YcodeBuildSystem"
    /// The default engine: swift-build, now that it builds apps, tools and
    /// packages (it falls back to xcodebuild per request otherwise).
    public static let defaultValue: BuildSystemPreference = .swiftBuild

    public var title: String {
        switch self {
        case .xcodebuild: "xcodebuild"
        case .swiftBuild: "swift-build"
        }
    }

    public static func current(_ defaults: UserDefaults = .standard) -> BuildSystemPreference {
        defaults.string(forKey: defaultsKey).flatMap(BuildSystemPreference.init(rawValue:)) ?? defaultValue
    }

    public func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }

    /// The engine for this preference. swift-build falls back to
    /// xcodebuild when `swbuild` cannot be found, and per request for
    /// containers it cannot describe yet.
    /// xcodebuild for building; its product lookup uses swift-build's
    /// settings through `ycode-swb` when that helper is available.
    static func xcodebuildEngine() -> XcodebuildEngine {
        var e = XcodebuildEngine()
        if let helper = SwiftBuildSettingsSource.locate() { e.settingsSource = SwiftBuildSettingsSource(helper: helper) }
        return e
    }

    public func makeEngine(locateSwiftBuild: () -> String? = { SwiftBuildEngine.locate() }) -> BuildEngine {
        switch self {
        case .xcodebuild: return Self.xcodebuildEngine()
        case .swiftBuild:
            guard let tool = locateSwiftBuild() else { return Self.xcodebuildEngine() }
            // The PIF comes from YcodeXcodebuild's XcodePIF (the reference
            // GUID scheme, every target kind), shared with ycodebuild.
            var engine = SwiftBuildEngine(swbuild: tool)
            engine.pifSource = XcodePIFSource()
            return FallbackEngine(primary: engine, fallback: Self.xcodebuildEngine(), supports: { r in
                if case .package = r.container { return true }
                return (try? XcodePIFSource.container(for: r)) != nil
            })
        }
    }
}

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

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        for p in BuildSystemPreference.allCases {
            buildSystemPopUp.addItem(withTitle: p == BuildSystemPreference.defaultValue ? "\(p.title) (Default)" : p.title)
            buildSystemPopUp.lastItem?.representedObject = p.rawValue
        }
        buildSystemPopUp.selectItem(at: BuildSystemPreference.allCases.firstIndex(of: .current(defaults)) ?? 0)
        buildSystemPopUp.target = self
        buildSystemPopUp.action = #selector(chosen)

        let note = noteLabel
        updateNote()
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label("Build System:"), buildSystemPopUp],
            [NSGridCell.emptyContentView, note],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = root
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
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
            noteLabel.stringValue = "swbuild was not found; set YCODE_SWBUILD or add it to PATH. Builds use xcodebuild until then."
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

/// Ycode ▸ Settings… (⌘,): one shared sidebar window (reference-ui.md §4):
/// the pane list at the left, the selected pane as a form at the right
/// under its title and back/forward buttons.
@MainActor
public final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = SettingsWindowController()
    /// The pane list's width.
    public static let sidebarWidth: CGFloat = 200
    /// The panes (tabless; the sidebar selects).
    public let tabs = NSTabViewController()
    public let sidebar = NSTableView()
    let titleLabel = NSTextField(labelWithString: "")
    let backButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: nil, action: nil)
    let forwardButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!, target: nil, action: nil)
    final class History { var back: [Int] = []; var forward: [Int] = [] }
    let history = History()

    /// Pane titles in order (Simulators is Ycode's own, before Locations).
    public static let paneTitles = ["General", "Appearance", "Accounts", "Coding Assistant", "Behaviors", "Navigation", "Notifications",
                                    "Editing", "Shortcuts", "Source Control", "Components", "Simulators", "Locations"]
    static let paneSymbols = ["gearshape", "paintpalette", "person.crop.circle", "sparkles", "bolt", "arrow.triangle.turn.up.right.diamond",
                              "bell", "text.cursor", "keyboard", "arrow.triangle.branch", "square.stack.3d.up", "server.rack", "externaldrive"]

    public init(prefs: Preferences = .shared, components: [ComponentsSettingsPane.Component]? = nil) {
        tabs.tabStyle = .unspecified
        let locations = SettingsController()
        let panes: [NSViewController] = [
            GeneralSettingsPane(prefs: prefs), ThemesSettingsPane(prefs: prefs), AccountsSettingsPane(prefs: prefs),
            CodingAssistantSettingsPane(prefs: prefs), BehaviorsSettingsPane(prefs: prefs), NavigationSettingsPane(prefs: prefs),
            NotificationsSettingsPane(prefs: prefs), TextEditingSettingsPane(prefs: prefs), KeyBindingsSettingsPane(prefs: prefs),
            SourceControlSettingsPane(prefs: prefs), ComponentsSettingsPane(prefs: prefs, components: components),
            SimulatorsSettingsPane(prefs: prefs), locations,
        ]
        for (i, p) in panes.enumerated() {
            let item = NSTabViewItem(viewController: p)
            item.label = Self.paneTitles[i]
            item.image = NSImage(systemSymbolName: Self.paneSymbols[i], accessibilityDescription: Self.paneTitles[i])
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = 0
        let column = NSTableColumn(identifier: .init("pane"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 26
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.drawsBackground = false
        let bar = NSStackView(views: [backButton, forwardButton, titleLabel])
        titleLabel.font = .boldSystemFont(ofSize: 15)
        for b in [backButton, forwardButton] {
            if #available(macOS 26, *) {
                // Round glass buttons over the pane (liquid-glass-ycode.md §5).
                b.bezelStyle = .glass
                b.borderShape = .circle
            } else {
                b.bezelStyle = .texturedRounded
            }
        }
        // The pane list is the system's sidebar (a floating glass sidebar
        // on macOS 26 and later), 200 points wide; the detail runs under
        // the transparent title bar (liquid-glass-ycode.md §5).
        let sidebarVC = NSViewController()
        sidebarVC.view = scroll
        let detail = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 560))
        for v in [bar, tabs.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 12), bar.topAnchor.constraint(equalTo: detail.topAnchor, constant: 10),
            tabs.view.leadingAnchor.constraint(equalTo: detail.leadingAnchor), tabs.view.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            tabs.view.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), tabs.view.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        let detailVC = NSViewController()
        detailVC.view = detail
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailVC))
        split.view.frame = NSRect(x: 0, y: 0, width: 860, height: 560)
        let window = NSWindow(contentViewController: split)
        window.title = "General"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        // The pane's title row names it; the window title (Window menu,
        // accessibility) is not drawn over the detail's title bar section.
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 860, height: 560))
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
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: Self.paneSymbols[row], accessibilityDescription: nil)!)
        let text = NSTextField(labelWithString: Self.paneTitles[row])
        let s = NSStackView(views: [image, text])
        s.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(s)
        cell.textField = text
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), s.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

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
