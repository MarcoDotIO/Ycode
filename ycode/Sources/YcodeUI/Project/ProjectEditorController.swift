import AppKit
import YcodePlist
import YcodeProject

/// The project editor: PROJECT / TARGETS list, tabs, and the tab content.
/// Every edit goes through `ProjectEditorModel` and is reported with
/// `onChange` (the window then writes the project). See
/// `specs/ide/project-editor.md`.
@MainActor
public final class ProjectEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    public enum Tab: String, CaseIterable { case general = "General", signing = "Signing & Capabilities", resourceTags = "Resource Tags", info = "Info",
                                             buildSettings = "Build Settings", buildPhases = "Build Phases", buildRules = "Build Rules",
                                             packageDependencies = "Package Dependencies" }
    public enum SettingsView: Int { case combined, levels }

    public internal(set) var model: ProjectEditorModel
    public var onChange: ((PBXProj) -> Void)?
    /// nil = the project.
    public private(set) var selectedTarget: String?
    public private(set) var tab: Tab = .general
    public private(set) var configuration = "Debug"
    /// The user picked a configuration; until then the list's
    /// `defaultConfigurationName` is shown (project-editor.md §Layout).
    private var configurationChosen = false
    public var filter: ProjectEditorModel.Filter = .basic { didSet { if isViewLoaded && tab == .buildSettings { showTab() } } }
    public var settingsView: SettingsView = .combined { didSet { showTab() } }
    public var search = "" { didSet { reloadSettings() } }
    public internal(set) var settingRows: [ProjectEditorModel.SettingRow] = []

    /// Collapsed sections of General, Info and Build Phases (by title
    /// without its count). The Info type sections start collapsed.
    public var collapsedSections: Set<String> = ["Document Types", "Exported Type Identifiers", "Imported Type Identifiers", "URL Types"]
    /// Expanded entry rows of the Info type sections ("<plist key>#<index>").
    public var expandedInfoEntries: Set<String> = []
    /// Expanded container rows of the Info table (raw key paths), and the
    /// path of each shown row.
    public var expandedInfoKeys: Set<String> = []
    public internal(set) var infoRowPaths: [String] = []
    /// The shown tab's collapsible sections and tables (tests).
    var sectionViews: [String: CollapsibleSection] = [:]
    var tables: [String: StaticTable] = [:]
    /// Filter fields of Resource Tags and Build Rules, by tab key.
    public var tabFilters: [String: String] = [:]
    /// Resource Tags scope (All, Prefetched) and Build Rules scope (All, Custom).
    public internal(set) var resourceTagScope = "All"
    public internal(set) var buildRuleScope = "All"
    /// Expanded rows of Project ▸ Info's Configurations table.
    public var expandedConfigurations: Set<String> = []
    /// Signing & Capabilities scope: All, or one configuration.
    public internal(set) var signingScope = "All"
    /// Build Settings view state (reference-ui-3.md §1.8).
    public var showsTitles = true { didSet { reloadSettings() } }
    public var showsDefinitions = false { didSet { reloadSettings() } }
    public var collapsedSettingSections: Set<String> = [] { didSet { reloadSettings() } }
    public var expandedSettings: Set<String> = [] { didSet { reloadSettings() } }
    public enum SettingsLine: Equatable { case section(String), setting(String), configuration(setting: String, name: String) }
    public internal(set) var settingsLines: [SettingsLine] = []
    var rowByName: [String: ProjectEditorModel.SettingRow] = [:]
    var perConfiguration: [String: [String: ProjectEditorModel.SettingRow]] = [:]
    var configurationNames: [String] = []
    var levelColumns: [(id: String, title: String)] = []
    let sidebar = NSTableView()
    var sidebarWidth = NSLayoutConstraint()
    private let tabs = NSSegmentedControl()
    let configPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let content = NSView()
    let settingsTable = NSTableView()
    var sidebarRows: [(title: String, target: String?, isHeader: Bool)] = []

    public init(model: ProjectEditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public static func tabs(forTarget: Bool) -> [Tab] {
        forTarget ? [.general, .signing, .resourceTags, .info, .buildSettings, .buildPhases, .buildRules] : [.info, .buildSettings, .packageDependencies]
    }

    /// The Package Dependencies tab's + button (the window shows the Add Package sheet).
    public var onAddPackage: (() -> Void)?

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let col = NSTableColumn(identifier: .init("s"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        let sideScroll = NSScrollView()
        sidebarWidth = sideScroll.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        // The column's collapse button and its +/−/Filter footer (§11.1.2).
        collapseButton.target = self
        collapseButton.action = #selector(collapseClicked)
        collapseButton.isBordered = false
        collapseButton.toolTip = "Hide the project and targets list"
        let addTarget = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a target")!, target: self,
                                 action: #selector(addTargetClicked))
        addTarget.toolTip = "Add a target"
        removeTargetButton.target = self
        removeTargetButton.action = #selector(removeTargetClicked)
        removeTargetButton.toolTip = "Delete the selected target"
        for b in [addTarget, removeTargetButton] { b.bezelStyle = .smallSquare; b.isBordered = false }
        sidebarFilter.placeholderString = "Filter"
        sidebarFilter.controlSize = .small
        sidebarFilter.target = self
        sidebarFilter.action = #selector(sidebarFilterChanged)
        sidebarFilter.sendsSearchStringImmediately = true
        sidebarFooter.setViews([addTarget, removeTargetButton, sidebarFilter], in: .leading)
        sidebarFooter.spacing = 2
        sidebarFooter.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 4, right: 4)
        tabs.segmentStyle = .rounded
        tabs.target = self
        tabs.action = #selector(tabChosen)
        configPopUp.target = self
        configPopUp.action = #selector(configChosen)
        configPopUp.controlSize = .small
        let sep = NSBox(); sep.boxType = .separator
        sideScroll.identifier = .init("projectEditorSidebar")
        self.sideScroll = sideScroll
        for v in [collapseButton, sideScroll, sidebarFooter, sep, tabs, configPopUp, content] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            collapseButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            collapseButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            sideScroll.topAnchor.constraint(equalTo: collapseButton.bottomAnchor, constant: 4),
            sideScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: sidebarFooter.topAnchor),
            sidebarWidth,
            sidebarFooter.leadingAnchor.constraint(equalTo: sideScroll.leadingAnchor),
            sidebarFooter.trailingAnchor.constraint(equalTo: sideScroll.trailingAnchor),
            sidebarFooter.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.topAnchor.constraint(equalTo: root.topAnchor), sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor), sep.widthAnchor.constraint(equalToConstant: 1),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            configPopUp.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
            configPopUp.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: configPopUp.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        reloadSidebar()
        select(target: model.targets.first?.string("name"), tab: .general)
    }

    // MARK: Selection

    func reloadSidebar() {
        let q = sidebarFilter.stringValue.trimmingCharacters(in: .whitespaces)
        let names = model.targets.compactMap { $0.string("name") }.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
        sidebarRows = [("PROJECT", nil, true), (model.projectName, nil, false), ("TARGETS", nil, true)] + names.map { ($0, $0, false) }
        sidebar.reloadData()
        let row = sidebarRows.firstIndex { !$0.isHeader && ($0.target == selectedTarget) && (selectedTarget != nil || $0.title == model.projectName) }
        if let row { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
        removeTargetButton.isEnabled = selectedTarget != nil
    }

    // MARK: Target list (reference-ui-5.md §11.1.2, P2)

    static let sidebarWidth: CGFloat = 180
    let collapseButton = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Hide the project and targets list")!,
                                  target: nil, action: nil)
    let removeTargetButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete the selected target")!,
                                      target: nil, action: nil)
    let sidebarFilter = NSSearchField()
    let sidebarFooter = NSStackView()
    weak var sideScroll: NSScrollView?

    /// The project and targets list is collapsed (its button stays).
    public private(set) var isSidebarCollapsed = false

    public func setSidebarCollapsed(_ c: Bool) {
        _ = view
        isSidebarCollapsed = c
        sidebarWidth.constant = c ? 0 : Self.sidebarWidth
        sideScroll?.isHidden = c
        sidebarFooter.isHidden = c
        collapseButton.toolTip = c ? "Show the project and targets list" : "Hide the project and targets list"
    }

    @objc func collapseClicked() { setSidebarCollapsed(!isSidebarCollapsed) }

    /// Filters the TARGETS rows by name.
    public func setSidebarFilter(_ text: String) {
        _ = view
        sidebarFilter.stringValue = text
        reloadSidebar()
    }

    @objc func sidebarFilterChanged() { reloadSidebar() }

    /// The target-template sheet; shown when the window is visible.
    @discardableResult
    public func newTargetSheet() -> NewTargetSheetController {
        let names = model.targets.compactMap { $0.string("name") }
        let apps = model.targets.filter { $0.string("productType") == "com.apple.product-type.application" }.compactMap { $0.string("name") }
        let platform = model.targets.first.flatMap { t in t.string("name").map { model.supportedDestinations(target: $0, configuration: configuration) } }?
            .first?.sdk == "macOS" ? "macOS" : "iOS"
        let sheet = NewTargetSheetController(platform: platform, hostTargets: apps + names.filter { !apps.contains($0) })
        sheet.onFinish = { [weak self] platform, template, name, host in
            guard let self else { return nil }
            do {
                try self.addTarget(template: template, platform: platform, name: name, hostTarget: host)
                return nil
            } catch { return "\(error)" }
        }
        if let w = view.window, w.isVisible { presentAsSheet(sheet) }
        return sheet
    }

    @objc func addTargetClicked() { newTargetSheet() }

    /// Adds a target from a template and selects it.
    @discardableResult
    public func addTarget(template: String, platform: String, name: String, hostTarget: String?) throws -> String {
        let n = try model.addTarget(template: template, platform: platform, name: name, hostTarget: hostTarget)
        onChange?(model.proj)
        reloadSidebar()
        select(target: n, tab: .general)
        return n
    }

    public static func deleteTargetMessage(_ name: String) -> (String, String) {
        ("Delete the target \u{201C}\(name)\u{201D}?", "Its build settings, build phases and product are removed from the project. Its files stay on disk.")
    }

    @objc func removeTargetClicked() {
        guard let t = selectedTarget else { return }
        guard let w = view.window, w.isVisible else { return }
        let (title, info) = Self.deleteTargetMessage(t)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.deleteTarget(t) }
        }
    }

    /// Deletes a target (after the confirmation) and selects the first
    /// remaining one, or the project.
    public func deleteTarget(_ name: String) {
        model.removeTarget(named: name)
        onChange?(model.proj)
        let next = model.targets.first?.string("name")
        selectedTarget = next
        reloadSidebar()
        select(target: next, tab: next == nil ? .info : .general)
    }

    public func select(target: String?, tab: Tab? = nil) {
        _ = view
        selectedTarget = target
        let available = Self.tabs(forTarget: target != nil)
        self.tab = tab.flatMap { available.contains($0) ? $0 : nil } ?? (available.contains(self.tab) ? self.tab : available[0])
        tabs.segmentCount = available.count
        for (i, t) in available.enumerated() { tabs.setLabel(t.rawValue, forSegment: i); tabs.setWidth(0, forSegment: i) }
        tabs.selectedSegment = available.firstIndex(of: self.tab) ?? 0
        let (names, def) = model.configurations(of: target)
        configPopUp.removeAllItems()
        configPopUp.addItems(withTitles: names)
        configuration = configurationChosen && names.contains(configuration) ? configuration : (def ?? names.first ?? "Debug")
        configPopUp.selectItem(withTitle: configuration)
        // Build Phases has no configuration pop-up (§11.1.4).
        configPopUp.isHidden = self.tab == .buildPhases
        let row = sidebarRows.firstIndex { !$0.isHeader && ($0.target == target) && (target != nil || $0.title == model.projectName) }
        if let row { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
        removeTargetButton.isEnabled = target != nil
        showTab()
    }

    public func select(tab: Tab) { select(target: selectedTarget, tab: tab) }

    @objc private func tabChosen() { select(tab: Self.tabs(forTarget: selectedTarget != nil)[tabs.selectedSegment]) }
    @objc private func configChosen() { configuration = configPopUp.titleOfSelectedItem ?? configuration; configurationChosen = true; showTab() }

    // MARK: Content

    func showTab() {
        content.subviews.forEach { $0.removeFromSuperview() }
        sectionViews = [:]
        tables = [:]
        let v: NSView
        switch (selectedTarget, tab) {
        case (nil, .info): v = projectInfoView()
        case (_, .buildSettings): v = buildSettingsView()
        case (let t?, .general): v = generalView(t)
        case (let t?, .signing): v = signingView(t)
        case (let t?, .resourceTags): v = resourceTagsView(t)
        case (let t?, .info): v = infoView(t)
        case (let t?, .buildPhases): v = phasesView(t)
        case (nil, .packageDependencies): v = packageDependenciesView()
        case (let t?, .buildRules): v = buildRulesView(t)
        default: v = NSView()
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    /// A form row: label, value, and the setting it edits (nil = read-only).
    typealias FormRow = (label: String, value: String, setting: String?)

    func resolved(_ name: String, target: String?) -> String {
        model.resolve(target: target, configuration: configuration)?.settings[name] ?? ""
    }

    func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    @objc func autoSigningToggled(_ b: NSButton) { setAutomaticSigning(b.state == .on) }

    public func setAutomaticSigning(_ on: Bool) {
        guard let t = selectedTarget else { return }
        if signingScope != "All" {
            model.setSetting("CODE_SIGN_STYLE", on ? "Automatic" : "Manual", target: t, configuration: signingScope)
        } else {
            model.setAutomaticSigning(on, target: t)
        }
        onChange?(model.proj)
        showTab()
    }

    public func addCapability(_ c: Capability) throws {
        guard let t = selectedTarget else { return }
        try model.addCapability(c, target: t, configuration: signingConfiguration)
        onChange?(model.proj)
        showTab()
    }

    public func removeCapability(_ c: Capability) throws {
        guard let t = selectedTarget else { return }
        try model.removeCapability(c, target: t, configuration: signingConfiguration)
        onChange?(model.proj)
        showTab()
    }

    @objc func addCapabilityClicked() { capabilityLibrary() }
    @objc func removeCapabilityClicked(_ b: NSButton) {
        if let c = Capability(rawValue: b.identifier?.rawValue ?? "") { try? removeCapability(c) }
    }

    /// Package Dependencies rows: per package its location, rule and the
    /// products targets use.
    public var packageRows: [PackageDependencyModel.Row] {
        PackageDependencyModel(proj: model.proj, xcodeprojURL: model.xcodeprojURL, checkoutsDirectory: URL(fileURLWithPath: "/")).rows
    }

    /// Replaces the project (after the window adds or resolves packages).
    public func reload(proj: PBXProj) {
        model.proj = proj
        if isViewLoaded { showTab() }
    }

    /// Removes a package and the product dependencies on it.
    public func removePackage(_ id: String) {
        model.proj.removePackage(id)
        onChange?(model.proj)
        if isViewLoaded && tab == .packageDependencies { showTab() }
    }

    final class PhaseButton: NSButton { var value = "" }

    @objc func removePhaseItem(_ b: PhaseButton) { removeBuildFile(b.value) }

    @objc func addPhaseItem(_ b: PhaseButton) {
        guard let w = view.window, w.isVisible else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        let dir = model.proj.projectDirectory(xcodeprojURL: model.xcodeprojURL)
        panel.directoryURL = dir
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let self else { return }
            for u in panel.urls {
                let path = u.standardizedFileURL.path
                let base = dir.standardizedFileURL.path + "/"
                self.addFile(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path, toPhase: b.value)
            }
        }
    }

    /// Rows as a two-column form; rows with an empty value and no setting
    /// are section headings.
    func form(_ rows: [FormRow]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 16, right: 24)
        for r in rows {
            if r.value.isEmpty && r.setting == nil {
                let h = NSTextField(labelWithString: r.label)
                h.font = .boldSystemFont(ofSize: 12)
                stack.addArrangedSubview(h)
                continue
            }
            let l = NSTextField(labelWithString: r.label)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            l.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let value: NSTextField
            if let key = r.setting {
                value = NSTextField(string: r.value)
                value.identifier = .init(key)
                value.delegate = self
                value.widthAnchor.constraint(equalToConstant: 320).isActive = true
            } else {
                value = NSTextField(wrappingLabelWithString: r.value)
                value.font = r.label == "Shell script" ? Theme.font : .systemFont(ofSize: 12)
                value.preferredMaxLayoutWidth = 480
            }
            let row = NSStackView(views: [l, value])
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }
        let flipped = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor), stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor), stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    /// A form field ended editing: write its setting.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let key = f.identifier?.rawValue, f.isEditable else { return }
        if key.hasPrefix("tag:") {
            renameResourceTag(String(key.dropFirst(4)), to: f.stringValue)
            return
        }
        // A per-configuration row of the Levels view: "cfg:<configuration>:<setting>".
        let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.count == 3, parts[0] == "cfg" {
            model.setSetting(parts[2], f.stringValue, target: selectedTarget, configuration: parts[1])
            onChange?(model.proj)
            reloadSettings()
            return
        }
        setSetting(key, f.stringValue)
    }

    /// The Team combo box: choosing a listed team writes it at once.
    public func comboBoxSelectionDidChange(_ n: Notification) {
        guard let c = n.object as? NSComboBox, let key = c.identifier?.rawValue, c.indexOfSelectedItem >= 0,
              let v = c.objectValueOfSelectedItem as? String else { return }
        setSetting(key, v)
    }

    @objc func filterChosen(_ s: NSSegmentedControl) { filter = ProjectEditorModel.Filter.allCases[s.selectedSegment] }
    @objc func viewChosen(_ s: NSSegmentedControl) { settingsView = SettingsView(rawValue: s.selectedSegment) ?? .combined }
    @objc func searchChanged(_ f: NSSearchField) { search = f.stringValue }

    /// Writes a setting at the selected level (target, or project) in every
    /// configuration, then reports the change.
    public func setSetting(_ name: String, _ value: String) {
        if tab == .signing, signingScope != "All" {
            model.setSetting(name, value, target: selectedTarget, configuration: signingScope)
        } else {
            model.setSetting(name, value, target: selectedTarget)
        }
        onChange?(model.proj)
        // The signing boxes' status depends on the team.
        if tab == .signing, name == "DEVELOPMENT_TEAM", isViewLoaded { showTab() }
        reloadSettings()
    }

    /// Adds a file (relative to the project directory) to a target's phase.
    @discardableResult
    public func addFile(_ path: String, toPhase phase: String) -> String {
        let id = model.addFile(path, toPhase: phase)
        onChange?(model.proj)
        if tab == .buildPhases { showTab() }
        return id
    }

    public func removeBuildFile(_ id: String) {
        model.removeBuildFile(id)
        onChange?(model.proj)
        if tab == .buildPhases { showTab() }
    }
}

extension ProjectEditorController {
    var sidebarRowCount: Int { sidebarRows.count }
    func sidebarIsHeader(_ row: Int) -> Bool { sidebarRows[row].isHeader }

    func sidebarSelected(_ row: Int) {
        let r = sidebarRows[row]
        if r.target != selectedTarget { select(target: r.target) }
    }

    func sidebarCell(_ row: Int) -> NSView {
        let r = sidebarRows[row]
        let l = NSTextField(labelWithString: r.title)
        l.font = r.isHeader ? .boldSystemFont(ofSize: 10) : .systemFont(ofSize: 12)
        l.textColor = r.isHeader ? .secondaryLabelColor : .labelColor
        return l
    }
}

/// A flipped container so forms start at the top of their scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
