import AppKit
import YcodeIDECore
import YcodeProject
import YcodeWorkspace

/// An editable list with an enable checkbox per row and one or two text
/// columns (arguments; environment variable name and value).
@MainActor
final class EditableListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row: Equatable { var enabled: Bool; var fields: [String] }
    var rows: [Row] = [] { didSet { table.reloadData(); emptyLabel.isHidden = !rows.isEmpty || emptyLabel.stringValue.isEmpty } }
    var onChange: (([Row]) -> Void)?
    let columns: [String]
    let table = NSTableView()
    /// Centered placeholder shown while the list is empty, e.g.
    /// "No Environment Variables" (reference-ui-2.md §7).
    let emptyLabel = NSTextField(labelWithString: "")

    init(title: String, columns: [String], emptyText: String? = nil) {
        self.columns = columns
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 11)
        let check = NSTableColumn(identifier: .init("on"))
        check.width = 22
        check.title = ""
        table.addTableColumn(check)
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: .init("f\(i)"))
            col.title = c
            col.width = columns.count == 1 ? 380 : 180
            table.addTableColumn(col)
        }
        if columns.count == 1 { table.headerView = nil }
        table.rowSizeStyle = .small
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        emptyLabel.stringValue = emptyText ?? ""
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.isHidden = emptyText == nil
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addRow))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeRow))
        for b in [add, remove] { b.bezelStyle = .smallSquare }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 0
        let stack = NSStackView(views: [label, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func addRow() {
        rows.append(Row(enabled: true, fields: columns.map { _ in "" }))
        onChange?(rows)
        table.editColumn(1, row: rows.count - 1, with: nil, select: true)
    }

    @objc func removeRow() {
        guard table.selectedRow >= 0 else { return }
        rows.remove(at: table.selectedRow)
        onChange?(rows)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let id = col?.identifier.rawValue else { return nil }
        if id == "on" {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            b.state = rows[row].enabled ? .on : .off
            b.tag = row
            return b
        }
        let i = Int(id.dropFirst())!
        let f = NSTextField(string: rows[row].fields[i])
        f.isBordered = false
        f.drawsBackground = false
        f.font = .systemFont(ofSize: 11)
        f.tag = row * 10 + i
        f.target = self
        f.action = #selector(edited(_:))
        return f
    }

    @objc func toggled(_ b: NSButton) {
        rows[b.tag].enabled = b.state == .on
        onChange?(rows)
    }

    @objc func edited(_ f: NSTextField) {
        rows[f.tag / 10].fields[f.tag % 10] = f.stringValue
        onChange?(rows)
    }
}

/// The scheme editor sheet (⌘<). See `specs/ide/schemes.md`.
@MainActor
public final class SchemeEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public static let actions: [(title: String, element: String, symbol: String)] = [
        ("Build", "BuildAction", "wrench.and.screwdriver"), ("Run", "LaunchAction", "play"), ("Test", "TestAction", "checkmark.diamond"),
        ("Profile", "ProfileAction", "gauge.with.dots.needle.33percent"), ("Analyze", "AnalyzeAction", "magnifyingglass"),
        ("Archive", "ArchiveAction", "archivebox"),
    ]
    public static let runTabs = ["Info", "Arguments", "Options", "Diagnostics"]

    /// An action's subtitle in the list: its configuration, or for Build
    /// "N targets".
    public func subtitle(forAction a: Int) -> String {
        if a == 0 { let n = scheme.buildEntries.count; return "\(n) target\(n == 1 ? "" : "s")" }
        return scheme.configuration(for: Self.actions[a].element)
    }

    /// One row of the left column. Each action has a disclosure; expanded
    /// it shows Pre-actions, the action itself, then Post-actions.
    public enum ListRow: Equatable {
        case action(Int), preActions(Int), main(Int), postActions(Int)
        public var action: Int {
            switch self { case .action(let a), .preActions(let a), .main(let a), .postActions(let a): return a }
        }
    }
    public private(set) var expandedActions: Set<Int> = []
    public var listRows: [ListRow] {
        Self.actions.indices.flatMap { a -> [ListRow] in
            expandedActions.contains(a) ? [.action(a), .preActions(a), .main(a), .postActions(a)] : [.action(a)]
        }
    }
    public func title(of r: ListRow) -> String {
        switch r {
        case .action(let a), .main(let a): return Self.actions[a].title
        case .preActions: return "Pre-actions"
        case .postActions: return "Post-actions"
        }
    }
    public func setExpanded(_ expanded: Bool, action a: Int) {
        _ = view
        if expanded { expandedActions.insert(a) } else { expandedActions.remove(a) }
        actionList.reloadData()
        selectListRow()
    }
    private func listRowIndex(_ r: ListRow) -> Int? { listRows.firstIndex(of: r) }
    private func selectListRow() {
        let target = expandedActions.contains(selectedAction) ? ListRow.main(selectedAction) : .action(selectedAction)
        if let i = listRowIndex(target), actionList.selectedRow != i { actionList.selectRowIndexes([i], byExtendingSelection: false) }
    }
    @objc private func disclosureToggled(_ b: NSButton) { setExpanded(b.state == .on, action: b.tag) }

    public internal(set) var scheme: Scheme
    let configurations: [String]
    /// Targets the Build table's "+" offers (set by the window).
    public var availableTargets: [Scheme.BuildableReference] = []
    /// Opens a file (a test plan's go-to arrow).
    public var onOpenFile: ((URL) -> Void)?
    /// The folder `container:` paths start from, when the scheme has no file.
    public var containerDirectoryOverride: URL?
    var buildTargetsFilter = ""
    var testPlansFilter = ""
    weak var buildTargetsTable: SchemeTable?
    weak var testPlansTable: SchemeTable?
    public var onClose: ((Scheme) -> Void)?
    public var onManage: (() -> Void)?
    public private(set) var selectedAction = 1
    public private(set) var selectedRunTab = 0

    let actionList = NSTableView()
    private let pane = NSStackView()
    private let tabs = NSSegmentedControl(labels: SchemeEditorController.runTabs, trackingMode: .selectOne, target: nil, action: nil)
    let arguments = EditableListView(title: "Arguments Passed On Launch", columns: ["Argument"], emptyText: "No Arguments")
    let environment = EditableListView(title: "Environment Variables", columns: ["Name", "Value"], emptyText: "No Environment Variables")

    public init(scheme: Scheme, configurations: [String]) {
        self.scheme = scheme
        self.configurations = configurations
        openedText = scheme.serialized()
        isAutocreated = scheme.url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        super.init(nibName: nil, bundle: nil)
    }

    /// The scheme as opened; an autocreated scheme is written only once it
    /// differs from this (P-108).
    let openedText: String
    /// The scheme has no file yet (autocreated for a target, P-108).
    public let isAutocreated: Bool
    /// An autocreated scheme was written for the first time (the window
    /// writes its siblings and reloads the scheme list).
    public var onAutocreatedSaved: ((Scheme) -> Void)?
    /// Duplicate Scheme wrote a copy (the window reloads the schemes).
    public var onDuplicate: ((Scheme) -> Void)?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        // P-110: Escape ends editing first, then closes the sheet.
        let escape = SchemeEditorEscapeView { [weak self] in self?.escapePressed() ?? false }
        root.addSubview(escape)
        let title = NSButton(title: scheme.name, image: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)!, target: nil, action: nil)
        title.isBordered = false
        title.imagePosition = .imageLeading
        title.font = .boldSystemFont(ofSize: 13)

        let col = NSTableColumn(identifier: .init("a"))
        actionList.addTableColumn(col)
        actionList.headerView = nil
        // Plain style: source-list selection uses a material that does not
        // draw in offscreen captures (it showed as a black bar).
        actionList.style = .plain
        actionList.backgroundColor = .clear
        actionList.selectionHighlightStyle = .regular
        actionList.dataSource = self
        actionList.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = actionList
        listScroll.drawsBackground = false

        tabs.target = self
        tabs.action = #selector(tabChosen)
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 10
        pane.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let duplicate = NSButton(title: "Duplicate Scheme", target: self, action: #selector(duplicateClicked))
        let manage = NSButton(title: "Manage Schemes…", target: self, action: #selector(manage))
        sharedCheck.title = "Shared"
        sharedCheck.state = scheme.isShared ? .on : .off
        sharedCheck.target = self
        sharedCheck.action = #selector(sharedToggled(_:))
        sharedCheck.isEnabled = scheme.url != nil
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\r"
        let sep = NSBox(); sep.boxType = .separator
        for v in [title, listScroll, sep, tabs, pane, duplicate, manage, sharedCheck, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            listScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 170),
            listScroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: listScroll.topAnchor),
            sep.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
            tabs.topAnchor.constraint(equalTo: listScroll.topAnchor),
            tabs.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            pane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4),
            pane.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: close.topAnchor, constant: -12),
            duplicate.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            duplicate.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            manage.leadingAnchor.constraint(equalTo: duplicate.trailingAnchor, constant: 8),
            manage.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            sharedCheck.leadingAnchor.constraint(equalTo: manage.trailingAnchor, constant: 12),
            sharedCheck.centerYAnchor.constraint(equalTo: manage.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        arguments.onChange = { [weak self] rows in
            self?.scheme.setLaunchArguments(rows.map { .init($0.fields[0], enabled: $0.enabled) })
        }
        environment.onChange = { [weak self] rows in
            self?.scheme.setLaunchEnvironment(rows.map { .init($0.fields[0], $0.fields[1], enabled: $0.enabled) })
        }
        view = root
        actionList.reloadData()
        select(action: startSelection.action, tab: startSelection.tab)
    }

    // MARK: Selection

    /// The tabs of an action's detail (reference-ui-2.md §7): Run has
    /// Info, Arguments, Options, Diagnostics; Profile Info, Arguments,
    /// Options; the others none.
    public static func tabs(forAction a: Int) -> [String] {
        switch a {
        case 1: runTabs
        case 3: ["Info", "Arguments", "Options"]
        default: []
        }
    }

    /// Where the sheet opens (the window passes the last action and tab
    /// used, so the sheet reopens there); `onSelect` reports changes.
    public var startSelection: (action: Int, tab: Int) = (1, 0)
    public var onSelect: ((Int, Int) -> Void)?

    public func select(action: Int, tab: Int = 0) {
        _ = view
        selectedAction = action
        selectedRunTab = tab
        onSelect?(action, tab)
        selectListRow()
        let names = Self.tabs(forAction: action)
        tabs.segmentCount = names.count
        for (i, n) in names.enumerated() { tabs.setLabel(n, forSegment: i); tabs.setWidth(0, forSegment: i) }
        tabs.isHidden = names.isEmpty
        tabs.selectedSegment = names.isEmpty ? -1 : min(tab, names.count - 1)
        pane.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let element = Self.actions[action].element
        switch (action, names.isEmpty ? "" : names[min(tab, names.count - 1)]) {
        case (0, _): buildPane()
        case (1, "Info"): runInfoPane(element)
        case (_, "Arguments"): argumentsPane()
        case (1, "Options"): runOptionsPane()
        case (1, "Diagnostics"): diagnosticsPane()
        case (2, _): testPane(element)
        case (3, "Info"):
            pane.addArrangedSubview(configurationRow(element))
            pane.addArrangedSubview(row("Executable", scheme.launchTarget?.buildableName ?? "None"))
            // `savedToolIdentifier` empty: Ask on Launch (the only instrument
            // Ycode lists).
            pane.addArrangedSubview(fixedEnabled("Instrument", SchemeOptionPopUp(["Ask on Launch"], selected: 0) { _ in }))
        case (3, "Options"):
            workingDirectoryRows()
        case (5, _):
            pane.addArrangedSubview(configurationRow(element))
            let name = SchemeOptionField(scheme.attribute("customArchiveName", of: element) ?? scheme.name, placeholder: scheme.name) { [weak self] v in
                guard let self else { return }
                self.scheme.setAttribute("customArchiveName", v.isEmpty || v == self.scheme.name ? nil : v, of: element)
            }
            name.widthAnchor.constraint(equalToConstant: 260).isActive = true
            pane.addArrangedSubview(fixedEnabled("Archive Name", name))
            pane.addArrangedSubview(fixedEnabled("Options", boundCheck("Reveal Archive in Organizer", .revealArchive, element: element)))
            pane.addArrangedSubview(fixed("", check("Allow Archiving for Simulator", false)))
        default:
            pane.addArrangedSubview(configurationRow(element))
        }
    }

    // MARK: Panes (reference-ui-2.md §7)

    /// A row whose control Ycode shows with its default but cannot change
    /// (no scheme attribute for it in Ycode's specs): disabled.
    private func fixed(_ label: String, _ control: NSView) -> NSView {
        if let c = control as? NSControl, !((control as? NSTextField).map { $0.isEditable == false && $0.isBezeled == false } ?? false) {
            c.isEnabled = false
        }
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let r = NSStackView(views: [l, control])
        r.alignment = .firstBaseline
        return r
    }

    private func check(_ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        b.isEnabled = false
        return b
    }

    private func popUp(_ items: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.isEnabled = false
        return p
    }

    private func radios(_ titles: [String], selected: Int) -> NSView {
        let views = titles.enumerated().map { i, t -> NSView in
            let r = NSButton(radioButtonWithTitle: t, target: nil, action: nil)
            r.state = i == selected ? .on : .off
            r.isEnabled = false
            return r
        }
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        return s
    }

    private func buildPane() {
        pane.addArrangedSubview(fixedEnabled("Build Order", boundRadios(.buildOrder, element: "BuildAction")))
        let implicit = NSButton(checkboxWithTitle: "Find Implicit Dependencies", target: self, action: #selector(implicitToggled(_:)))
        implicit.state = scheme.buildImplicitDependencies ? .on : .off
        pane.addArrangedSubview(fixedEnabled("Build Options", implicit))
        pane.addArrangedSubview(fixedEnabled("Override Architectures", boundPopUp(.overrideArchitectures, element: "BuildAction")))
        pane.addArrangedSubview(fixed("Build Debugging", check("Task Backtraces", false)))
        pane.addArrangedSubview(fixed("", check("Modules Report", false)))
        // Targets | Analyze | Test | Run | Profile | Archive, with +/−
        // and a filter (reference-ui-5.md §11.3, P11).
        let order: [Scheme.Action] = [.analyzing, .testing, .running, .profiling, .archiving]
        let entries = scheme.buildEntries.filter { buildTargetsFilter.isEmpty || $0.reference.blueprintName.localizedCaseInsensitiveContains(buildTargetsFilter) }
        let rows = entries.map { e -> [NSView] in
            var r: [NSView] = [NSTextField(labelWithString: e.reference.blueprintName)]
            for a in order {
                let c = BuildFlagBox(checkboxWithTitle: "", target: self, action: #selector(buildFlagToggled(_:)))
                c.state = e.actions.contains(a) ? .on : .off
                c.action2 = a
                c.blueprint = e.reference.blueprintIdentifier
                r.append(c)
            }
            return r
        }
        let t = SchemeTable(columns: ["Targets", "Analyze", "Test", "Run", "Profile", "Archive"], rows: rows, ids: entries.map(\.reference.blueprintIdentifier),
                            filter: buildTargetsFilter, empty: "No Targets")
        t.onPlus = { [weak self] b in self?.buildTargetsPlus(b) }
        t.onMinus = { [weak self] id in self?.removeBuildTarget(id) }
        t.onFilter = { [weak self] f in self?.buildTargetsFilter = f; self?.reloadPane() }
        t.plusButton.isEnabled = !addableBuildTargets.isEmpty
        buildTargetsTable = t
        pane.addArrangedSubview(t)
        t.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -32).isActive = true
    }

    final class BuildFlagBox: NSButton {
        var action2: Scheme.Action = .running
        var blueprint = ""
    }

    @objc private func implicitToggled(_ b: NSButton) { scheme.setBuildImplicitDependencies(b.state == .on) }
    @objc private func buildFlagToggled(_ b: BuildFlagBox) { scheme.setBuild(b.action2, b.state == .on, blueprintIdentifier: b.blueprint) }

    private func runInfoPane(_ element: String) {
        pane.addArrangedSubview(configurationRow(element))
        pane.addArrangedSubview(fixedEnabled("Executable", executablePopUp()))
        debuggerRows(element)
        pane.addArrangedSubview(fixedEnabled("Launch", boundRadios(.launchStyle, element: element)))
    }

    /// Debug executable, Debug Process As and LLDB Init File of the Run
    /// and Test actions (P-109).
    private func debuggerRows(_ element: String, label: String = "") {
        let debug = SchemeOptionButton.checkbox("Debug executable", on: scheme.debugsExecutable(element)) { [weak self] on in
            self?.scheme.setDebugsExecutable(on, action: element)
        }
        debug.setAccessibilityIdentifier("\(element).debugExecutable")
        pane.addArrangedSubview(fixedEnabled(label, debug))
        pane.addArrangedSubview(fixedEnabled("Debug Process As", boundRadios(.debugProcessAs(user: NSUserName()), element: element)))
        let lldb = SchemeOptionField(scheme.attribute("customLLDBInitFile", of: element) ?? "", placeholder: "$(SRCROOT)/LLDBInitFile") { [weak self] v in
            self?.scheme.setAttribute("customLLDBInitFile", v.isEmpty ? nil : v, of: element)
        }
        lldb.setAccessibilityIdentifier("\(element).customLLDBInitFile")
        lldb.widthAnchor.constraint(equalToConstant: 260).isActive = true
        pane.addArrangedSubview(fixedEnabled("LLDB Init File", lldb))
    }

    /// Run ▸ Info ▸ Executable: None, the scheme's buildable targets, Ask
    /// on Launch (`askForAppToLaunch`).
    private func executablePopUp() -> NSPopUpButton {
        var refs: [Scheme.BuildableReference] = []
        for r in scheme.buildEntries.map(\.reference) + availableTargets where !refs.contains(where: { $0.blueprintIdentifier == r.blueprintIdentifier }) {
            refs.append(r)
        }
        let titles = ["None"] + refs.map(\.buildableName) + ["Ask on Launch"]
        let current = scheme.attribute("askForAppToLaunch", of: "LaunchAction").map { $0 == "YES" || $0 == "Yes" } == true ? titles.count - 1
            : scheme.launchTarget.flatMap { t in refs.firstIndex { $0.blueprintIdentifier == t.blueprintIdentifier }.map { $0 + 1 } } ?? 0
        let p = SchemeOptionPopUp(titles, selected: current) { [weak self] i in
            guard let self else { return }
            if i == titles.count - 1 {
                self.scheme.setAttribute("askForAppToLaunch", "YES", of: "LaunchAction")
            } else {
                self.scheme.setAttribute("askForAppToLaunch", nil, of: "LaunchAction")
                self.scheme.setRunnable(i == 0 ? nil : refs[i - 1])
            }
        }
        p.setAccessibilityIdentifier("LaunchAction.executable")
        return p
    }

    /// A checkbox bound to an attribute.
    func boundCheck(_ title: String, _ b: SchemeOptionBinding, element: String) -> NSButton {
        let c = SchemeOptionButton.checkbox(title, on: b.isOn(in: scheme, element: element)) { [weak self] on in
            guard let self else { return }
            b.set(on, in: &self.scheme, element: element)
        }
        c.setAccessibilityIdentifier("\(element).\(b.attribute)")
        return c
    }

    /// A pop-up bound to an attribute.
    func boundPopUp(_ b: SchemeOptionBinding, element: String) -> NSPopUpButton {
        guard case .choice(let items) = b.kind else { return NSPopUpButton() }
        let p = SchemeOptionPopUp(items.map(\.title), selected: b.selectedIndex(in: scheme, element: element)) { [weak self] i in
            guard let self else { return }
            b.choose(i, in: &self.scheme, element: element)
        }
        p.setAccessibilityIdentifier("\(element).\(b.attribute)")
        return p
    }

    /// A radio group bound to an attribute.
    func boundRadios(_ b: SchemeOptionBinding, element: String) -> NSView {
        guard case .choice(let items) = b.kind else { return NSView() }
        let selected = b.selectedIndex(in: scheme, element: element)
        var buttons: [NSButton] = []
        for (i, item) in items.enumerated() {
            let r = SchemeOptionButton.radio(item.title, on: i == selected) { [weak self] in
                guard let self else { return }
                b.choose(i, in: &self.scheme, element: element)
                for (j, other) in buttons.enumerated() { other.state = j == i ? .on : .off }
            }
            r.setAccessibilityIdentifier("\(element).\(b.attribute).\(i)")
            buttons.append(r)
        }
        let s = NSStackView(views: buttons)
        s.orientation = .vertical
        s.alignment = .leading
        return s
    }

    private func argumentsPane() {
        arguments.rows = scheme.launchArguments.map { .init(enabled: $0.isEnabled, fields: [$0.value]) }
        environment.rows = scheme.launchEnvironment.map { .init(enabled: $0.isEnabled, fields: [$0.key, $0.value]) }
        for v in [arguments, environment] {
            pane.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -32).isActive = true
        }
        pane.addArrangedSubview(fixedEnabled("Expand Variables Based On", expandVariablesPopUp()))
    }

    /// Run ▸ Arguments ▸ Expand Variables Based On: the `MacroExpansion`
    /// target (none: the runnable).
    private func expandVariablesPopUp() -> NSPopUpButton {
        var refs: [Scheme.BuildableReference] = []
        for r in scheme.buildEntries.map(\.reference) + availableTargets where !refs.contains(where: { $0.blueprintIdentifier == r.blueprintIdentifier }) {
            refs.append(r)
        }
        let shown = scheme.macroExpansion() ?? scheme.launchTarget
        let current = shown.flatMap { t in refs.firstIndex { $0.blueprintIdentifier == t.blueprintIdentifier }.map { $0 + 1 } } ?? 0
        let p = SchemeOptionPopUp(["None"] + refs.map(\.blueprintName), selected: current) { [weak self] i in
            self?.scheme.setMacroExpansion(i == 0 ? nil : refs[i - 1])
        }
        p.setAccessibilityIdentifier("LaunchAction.MacroExpansion")
        return p
    }

    /// Run ▸ Options rows with their defaults; rows with a binding
    /// (`SchemeOptionBinding`) and the working directory edit the scheme.
    public static let runOptionRows: [(String, String)] = [
        ("Core Location", "Allow Location Simulation"), ("App Data", "None"), ("Routing App Coverage File", "None"),
        ("GameKit Configuration", "Enable Debug Mode"), ("StoreKit Configuration", "None"), ("GPU Frame Capture", "Automatically"),
        ("Persistent State", "Launch app without state restoration"), ("Document Versions", "Allow debugging when browsing versions"),
        ("Working Directory", ""), ("Background Asset Packs", "None"), ("Localization Debugging", "Show non-localized strings"),
        ("App Language", "System Language"), ("App Region", "System Region"), ("Distribution", "App Store"),
        ("Simulated Apple Foundation Models Availability", "Off"), ("XPC Services", "Debug XPC services used by app"),
        ("Queue Debugging", "Enable backtrace recording"), ("Console", "Ycode (with Standard Input)"),
    ]
    static let checkedByDefault: Set<String> = ["Allow Location Simulation", "Allow debugging when browsing versions", "Debug XPC services used by app"]
    static let checkboxRows: Set<String> = ["Core Location", "GameKit Configuration", "Persistent State", "Document Versions",
                                            "Localization Debugging", "XPC Services", "Queue Debugging"]

    private func runOptionsPane() {
        let scroll = NSScrollView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let saved = pane
        for (label, value) in Self.runOptionRows {
            if label == "Working Directory" {
                let (c, f) = workingDirectoryControls()
                stack.addArrangedSubview(fixedEnabled(label, NSStackView(views: [c, f])))
            } else if let b = SchemeOptionBinding.checkboxes[value] {
                stack.addArrangedSubview(fixedEnabled(label, boundCheck(value, b, element: "LaunchAction")))
                if label == "Core Location" { stack.addArrangedSubview(fixed("Default Location", popUp(["None"]))) }
            } else if Self.checkboxRows.contains(label) {
                stack.addArrangedSubview(fixed(label, check(value, Self.checkedByDefault.contains(value))))
            } else if let b = SchemeOptionBinding.popUps[label] {
                stack.addArrangedSubview(fixedEnabled(label, boundPopUp(b, element: "LaunchAction")))
            } else {
                stack.addArrangedSubview(fixed(label, popUp([value])))
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        saved.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: saved.widthAnchor, constant: -32).isActive = true
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    }

    private func fixedEnabled(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let r = NSStackView(views: [l, control])
        r.alignment = .firstBaseline
        return r
    }

    private func workingDirectoryControls() -> (NSButton, NSTextField) {
        let check = NSButton(checkboxWithTitle: "Use custom working directory:", target: self, action: #selector(workingDirToggled(_:)))
        check.state = scheme.customWorkingDirectory != nil ? .on : .off
        let field = NSTextField(string: scheme.customWorkingDirectory ?? "")
        field.placeholderString = "$(BUILT_PRODUCTS_DIR)"
        field.isEnabled = check.state == .on
        field.target = self
        field.action = #selector(workingDirEdited(_:))
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return (check, field)
    }

    private func workingDirectoryRows() {
        let (c, f) = workingDirectoryControls()
        pane.addArrangedSubview(fixedEnabled("Working Directory", NSStackView(views: [c, f])))
    }

    /// Run ▸ Diagnostics (reference-ui-2.md §7.3), with defaults. The
    /// sanitizer rows edit the action's attributes (`SchemeDiagnostics`,
    /// schemes.md §Diagnostics); the other rows have no scheme attribute in
    /// Ycode's specs and are shown disabled.
    public static let diagnosticRows: [(section: String, title: String, on: Bool, indent: Bool)] = [
        ("Runtime Sanitization", "Address Sanitizer", false, false), ("", "Detect use of stack after return", false, true),
        ("", "Thread Sanitizer", false, false), ("", "Undefined Behavior Sanitizer", false, false),
        ("Runtime API Checking", "Main Thread Checker", true, false), ("", "Thread Performance Checker", true, false),
        ("Memory Management", "Hardware Memory Tagging", false, false), ("", "Fall back to Guard Malloc", false, true),
        ("", "Malloc Scribble", false, false), ("", "Malloc Guard Edges", false, false), ("", "Zombie Objects", false, false),
        ("", "Malloc Stack Logging", false, false), ("", "Memory Graph on Resource Exception", false, false),
        ("Metal", "API Validation", true, false), ("", "Include load and store actions", false, true), ("", "Log non-fatal actions", false, true),
        ("", "Shader Validation", false, false), ("", "Raise Runtime Issues on Error", true, true), ("", "Abort on Error", false, true),
        ("", "Log allocation stack traces", true, true), ("", "Detect GPU stack overflow", true, true),
        ("", "Metal Performance HUD", false, false), ("", "Log Graphics Overview", false, false),
        ("Core AI", "Include Model Debug Information", false, false),
    ]

    /// The editable sanitizer rows and the attribute each one sets.
    public static let sanitizerRows: [String: WritableKeyPath<SchemeDiagnostics, Bool>] = [
        "Address Sanitizer": \.addressSanitizer, "Detect use of stack after return": \.stackUseAfterReturn,
        "Thread Sanitizer": \.threadSanitizer, "Undefined Behavior Sanitizer": \.undefinedBehaviorSanitizer,
    ]

    /// A sanitizer checkbox of `element`'s Diagnostics.
    private func sanitizerCheck(_ title: String, indent: Bool, element: String) -> NSButton {
        let key = Self.sanitizerRows[title]!
        let d = scheme.diagnostics(for: element)
        let b = SanitizerBox(checkboxWithTitle: (indent ? "    " : "") + title, target: self, action: #selector(sanitizerToggled(_:)))
        b.key = key
        b.element = element
        b.state = d[keyPath: key] ? .on : .off
        b.isEnabled = key != \.stackUseAfterReturn || d.addressSanitizer
        b.setAccessibilityIdentifier("\(element).\(title)")
        return b
    }

    @objc private func sanitizerToggled(_ b: NSButton) {
        guard let b = b as? SanitizerBox, let key = b.key else { return }
        setSanitizer(key, b.state == .on, for: b.element)
    }

    /// Turns a sanitizer of `element` on or off (ASan and TSan exclude each
    /// other) and redraws the pane.
    public func setSanitizer(_ key: WritableKeyPath<SchemeDiagnostics, Bool>, _ on: Bool, for element: String = "LaunchAction") {
        var d = scheme.diagnostics(for: element)
        d.set(key, on)
        scheme.setDiagnostics(d, for: element)
        select(action: selectedAction, tab: selectedRunTab)
    }

    private func diagnosticsPane() {
        for r in Self.diagnosticRows {
            let bound = SchemeOptionBinding.checkboxes[r.title]
            let c = Self.sanitizerRows[r.title] != nil ? sanitizerCheck(r.title, indent: r.indent, element: "LaunchAction")
                : bound.map { boundCheck((r.indent ? "    " : "") + r.title, $0, element: "LaunchAction") } ?? check((r.indent ? "    " : "") + r.title, r.on)
            if r.section == "Runtime Sanitization" {
                let sub = NSTextField(labelWithString: "Requires recompilation")
                sub.font = .systemFont(ofSize: 10)
                sub.textColor = .secondaryLabelColor
                pane.addArrangedSubview(fixed(r.section, NSStackView(views: [c, sub])))
            } else if Self.sanitizerRows[r.title] != nil || bound != nil {
                pane.addArrangedSubview(fixedEnabled(r.section, c))
            } else {
                pane.addArrangedSubview(fixed(r.section, c))
            }
            if r.title == "Fall back to Guard Malloc" {
                pane.addArrangedSubview(fixed("", NSTextField(labelWithString: "Not checking allocations.")))
            }
        }
    }

    private func testPane(_ element: String) {
        pane.addArrangedSubview(configurationRow(element))
        debuggerRows(element, label: "Debugger")
        // The test action's own sanitizers (schemes.md §Diagnostics).
        for (n, r) in Self.diagnosticRows.prefix(4).enumerated() {
            pane.addArrangedSubview(fixedEnabled(n == 0 ? "Diagnostics" : "", sanitizerCheck(r.title, indent: r.indent, element: element)))
        }
        // Test Plans | Default, rows with a subtitle and a go-to arrow,
        // +/− and a filter (§11.3).
        var rows: [[NSView]] = []
        var ids: [String] = []
        for p in scheme.testPlans {
            let name = Self.testPlanName(p.reference)
            guard testPlansFilter.isEmpty || name.localizedCaseInsensitiveContains(testPlansFilter) else { continue }
            let r = NSButton(radioButtonWithTitle: "", target: self, action: #selector(defaultPlanChosen(_:)))
            r.state = p.isDefault ? .on : .off
            r.identifier = .init(p.reference)
            rows.append([testPlanCell(name, subtitle: Self.testPlanSubtitle(p.reference), reference: p.reference), r])
            ids.append(p.reference)
        }
        if scheme.testPlans.isEmpty, !scheme.testables.isEmpty {
            rows.append([testPlanCell("\(scheme.name) (Autocreated)", subtitle: Self.autocreatedSubtitle(scheme.testables.count), reference: nil), NSView()])
            ids.append("")
        }
        let t = SchemeTable(columns: ["Test Plans", "Default"], rows: rows, ids: ids, filter: testPlansFilter, empty: "No Test Plans", rowHeight: 34)
        t.onPlus = { [weak self] _ in self?.testPlanPlus() }
        t.onMinus = { [weak self] ref in if !ref.isEmpty { self?.removeTestPlan(ref) } }
        t.onFilter = { [weak self] f in self?.testPlansFilter = f; self?.reloadPane() }
        testPlansTable = t
        pane.addArrangedSubview(t)
        t.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -32).isActive = true
    }

    private func configurationRow(_ element: String) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: configurations)
        let current = scheme.configuration(for: element)
        if !configurations.contains(current) { popup.addItem(withTitle: current) }
        popup.selectItem(withTitle: current)
        popup.identifier = .init(element)
        popup.target = self
        popup.action = #selector(configurationChosen(_:))
        let label = NSTextField(labelWithString: "Build Configuration")
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return NSStackView(views: [label, popup])
    }

    /// Sets an action's build configuration (the pop-up's action).
    public func setConfiguration(_ name: String, for element: String) {
        scheme.setConfiguration(name, for: element)
    }

    @objc private func configurationChosen(_ p: NSPopUpButton) {
        guard let e = p.identifier?.rawValue, let t = p.titleOfSelectedItem else { return }
        setConfiguration(t, for: e)
        if let a = Self.actions.firstIndex(where: { $0.element == e }) {
            let rows = IndexSet(listRows.indices.filter { [.action(a), .main(a)].contains(listRows[$0]) })
            actionList.reloadData(forRowIndexes: rows, columnIndexes: [0])
        }
    }

    @objc private func workingDirToggled(_ b: NSButton) {
        scheme.setCustomWorkingDirectory(b.state == .on ? (scheme.customWorkingDirectory ?? "") : nil)
        select(action: selectedAction, tab: selectedRunTab)
    }

    @objc private func workingDirEdited(_ f: NSTextField) { scheme.setCustomWorkingDirectory(f.stringValue) }

    @objc private func tabChosen() { select(action: selectedAction, tab: tabs.selectedSegment) }

    /// The bottom bar's Shared checkbox (moves the file; see Manage Schemes).
    public let sharedCheck = NSButton(checkboxWithTitle: "Shared", target: nil, action: nil)
    @objc private func sharedToggled(_ b: NSButton) {
        do {
            // An autocreated scheme gets its file first, then moves.
            if let url = scheme.url, !FileManager.default.fileExists(atPath: url.path) { writeScheme(force: true) }
            try scheme.setShared(b.state == .on)
        } catch { b.state = scheme.isShared ? .on : .off; NSSound.beep() }
    }
    @objc private func manage() { onManage?() }

    /// Close writes the scheme if it changed, then dismisses. An
    /// autocreated scheme is written only when it was changed.
    @objc public func closeSheet() {
        writeScheme(force: false)
        onClose?(scheme)
        if presentingViewController != nil { dismiss(nil) }
    }

    private var autocreatedWritten = false

    private func writeScheme(force: Bool) {
        let firstWrite = isAutocreated && !autocreatedWritten
        if firstWrite && !force && scheme.serialized() == openedText { return }
        guard (try? scheme.save()) == true || !firstWrite else { return }
        if firstWrite {
            autocreatedWritten = true
            onAutocreatedSaved?(scheme)
        }
    }

    /// Duplicate Scheme: a copy named "<name> Copy" (then " Copy 2" …)
    /// next to the scheme's file, shared like it.
    @discardableResult
    public func duplicateScheme() -> Scheme? {
        guard let url = scheme.url else { NSSound.beep(); return nil }
        // An autocreated scheme is written first, so it stays listed.
        if isAutocreated { writeScheme(force: true) }
        let dir = url.deletingLastPathComponent()
        var name = "\(scheme.name) Copy"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).xcscheme").path) {
            name = "\(scheme.name) Copy \(n)"
            n += 1
        }
        var copy = scheme
        copy.name = name
        copy.url = dir.appendingPathComponent("\(name).xcscheme")
        guard (try? copy.save()) == true else { NSSound.beep(); return nil }
        onDuplicate?(copy)
        return copy
    }

    @objc private func duplicateClicked() { duplicateScheme() }

    /// Escape (and ⌘.): ends the text editing in progress, discarding the
    /// typed value; with nothing being edited, closes the sheet (P-110).
    @discardableResult
    public func escapePressed() -> Bool {
        guard isViewLoaded, let w = view.window else { closeSheet(); return true }
        if let editor = w.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            field.abortEditing()
            w.makeFirstResponder(actionList)
            return true
        }
        closeSheet()
        return true
    }

    public override func cancelOperation(_ sender: Any?) { escapePressed() }

    /// Replaces the arguments (as the table would) — for tests and scripting.
    public func setArguments(_ args: [Scheme.Argument]) {
        arguments.rows = args.map { .init(enabled: $0.isEnabled, fields: [$0.value]) }
        arguments.onChange?(arguments.rows)
    }

    private func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 11)
        return l
    }

    private func row(_ k: String, _ v: String) -> NSView {
        let a = NSTextField(labelWithString: k)
        a.alignment = .right
        a.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let b = NSTextField(labelWithString: v)
        b.textColor = .secondaryLabelColor
        return NSStackView(views: [a, b])
    }

    // MARK: Action list

    public func numberOfRows(in tableView: NSTableView) -> Int { listRows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = listRows[row]
        let a = Self.actions[r.action]
        switch r {
        case .action:
            let cell = SchemeActionCell(symbol: a.symbol, title: a.title, detail: subtitle(forAction: r.action))
            cell.disclosure.state = expandedActions.contains(r.action) ? .on : .off
            cell.disclosure.tag = r.action
            cell.disclosure.target = self
            cell.disclosure.action = #selector(disclosureToggled(_:))
            return cell
        case .main:
            return SchemeActionCell(symbol: a.symbol, title: a.title, detail: subtitle(forAction: r.action), indent: true)
        case .preActions, .postActions:
            return SchemeActionCell(symbol: "doc.text", title: title(of: r), detail: "", indent: true)
        }
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SchemeActionRowView() }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 34 }

    public func tableViewSelectionDidChange(_ n: Notification) {
        let i = actionList.selectedRow
        guard i >= 0, i < listRows.count else { return }
        let a = listRows[i].action
        if a != selectedAction { select(action: a, tab: 0) }
    }
}

/// Manage Schemes: name, container and the Shared checkbox.
@MainActor
public final class ManageSchemesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) var schemes: [Scheme]
    private let table = NSTableView()
    public var onClose: (() -> Void)?

    public init(schemes: [Scheme]) {
        self.schemes = schemes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        for (id, title, width) in [("name", "Name", 220.0), ("container", "Container", 220.0), ("shared", "Shared", 60.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\r"
        for v in [scroll, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }

    /// The Shared checkbox: moves the file between shared and user data
    /// (an autocreated scheme is written first, P-108).
    public func setShared(_ shared: Bool, at index: Int, user: String = NSUserName()) throws {
        if let url = schemes[index].url, !FileManager.default.fileExists(atPath: url.path) { try schemes[index].save() }
        try schemes[index].setShared(shared, user: user)
        if isViewLoaded { table.reloadData() }
    }

    @objc private func sharedToggled(_ b: NSButton) {
        do { try setShared(b.state == .on, at: b.tag) } catch { presentError(error) }
    }

    @objc private func closeSheet() {
        onClose?()
        if presentingViewController != nil { dismiss(nil) }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { schemes.count }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let s = schemes[row]
        switch c?.identifier.rawValue {
        case "shared":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(sharedToggled(_:)))
            b.state = s.isShared ? .on : .off
            b.tag = row
            return b
        case "container":
            // …/<Container>.xcodeproj/xcshareddata/xcschemes/X.xcscheme
            let comps = s.url?.pathComponents ?? []
            let container = comps.last { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") } ?? ""
            return NSTextField(labelWithString: container)
        default:
            return NSTextField(labelWithString: s.name)
        }
    }
}

/// A row of the scheme editor's action list. Draws the source-list
/// selection itself (accent color when the list is focused, the
/// unemphasized selection color otherwise) so it never falls back to a
/// dark bar, and tells its cell to use contrasting text.
@MainActor
final class SchemeActionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

/// Icon, bold title and configuration subtitle; colors follow the row's
/// background style.
@MainActor
final class SchemeActionCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let disclosure = NSButton(title: "", target: nil, action: nil)

    init(symbol: String, title t: String, detail d: String, indent: Bool = false) {
        super.init(frame: .zero)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.isHidden = indent
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = t
        title.font = .boldSystemFont(ofSize: 12)
        detail.stringValue = d
        detail.font = .systemFont(ofSize: 10)
        detail.isHidden = d.isEmpty
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: indent ? [icon, text] : [disclosure, icon, text])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent ? 34 : 4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
        imageView = icon
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        detail.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

/// A Diagnostics checkbox that knows its attribute and action element.
final class SanitizerBox: NSButton {
    var key: WritableKeyPath<SchemeDiagnostics, Bool>?
    var element = "LaunchAction"
}

/// A zero-size view in the scheme editor that takes Escape and ⌘. as key
/// equivalents, before the field editor or the window see them (P-110).
@MainActor
final class SchemeEditorEscapeView: NSView {
    let onEscape: () -> Bool

    init(_ onEscape: @escaping () -> Bool) {
        self.onEscape = onEscape
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func isEscape(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.keyCode == 53 && mods.subtracting([.function, .numericPad]).isEmpty { return true }
        return mods == .command && e.charactersIgnoringModifiers == "."
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Self.isEscape(event) ? onEscape() : false
    }
}
