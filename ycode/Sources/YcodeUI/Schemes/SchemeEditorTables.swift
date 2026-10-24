import AppKit
import YcodeProject
import YcodeWorkspace

/// A scheme-editor table with column headers, prebuilt cell views, an
/// empty text, and a footer with +, − and a filter field (the Build
/// targets and Test plans tables, reference-ui-5.md §11.3, P11).
@MainActor
final class SchemeTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let rows: [[NSView]]
    /// One ID per row (a blueprint identifier, a test plan reference).
    let ids: [String]
    let plusButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: nil, action: nil)
    let minusButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: nil, action: nil)
    let filterField = NSSearchField()
    let emptyLabel: NSTextField
    var onPlus: ((NSButton) -> Void)?
    var onMinus: ((String) -> Void)?
    var onFilter: ((String) -> Void)?

    init(columns: [String], rows: [[NSView]], ids: [String], filter: String, empty: String, rowHeight: CGFloat = 22) {
        self.rows = rows
        self.ids = ids
        emptyLabel = NSTextField(labelWithString: empty)
        super.init(frame: .zero)
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: .init("c\(i)"))
            col.title = c
            col.width = i == 0 ? 220 : 60
            table.addTableColumn(col)
        }
        table.rowHeight = rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        plusButton.target = self
        plusButton.action = #selector(plusClicked(_:))
        minusButton.target = self
        minusButton.action = #selector(minusClicked)
        for b in [plusButton, minusButton] { b.bezelStyle = .smallSquare }
        filterField.placeholderString = "Filter"
        filterField.controlSize = .small
        filterField.stringValue = filter
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged)
        let footer = NSStackView(views: [plusButton, minusButton, filterField])
        footer.spacing = 0
        footer.setCustomSpacing(8, after: minusButton)
        let stack = NSStackView(views: [scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: max(120, CGFloat(rows.count) * (rowHeight + 2) + 30)),
            filterField.widthAnchor.constraint(equalToConstant: 160),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        guard let c, let i = tableView.tableColumns.firstIndex(of: c), i < rows[row].count else { return nil }
        return rows[row][i]
    }

    @objc func plusClicked(_ b: NSButton) { onPlus?(b) }
    @objc func minusClicked() {
        let r = table.selectedRow
        if r >= 0, r < ids.count { onMinus?(ids[r]) }
    }
    @objc func filterChanged() { onFilter?(filterField.stringValue) }

    /// The first column's text of every row (tests).
    var titles: [String] {
        rows.map { r in
            if let f = r.first as? NSTextField { return f.stringValue }
            return (r.first.map { all($0) } ?? []).compactMap { ($0 as? NSTextField)?.stringValue }.first ?? ""
        }
    }

    private func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
}

extension SchemeEditorController {
    // MARK: Build targets

    /// The project targets a scheme can add (from the workspace's projects).
    public static func buildableTargets(projects: [String: PBXProj], container: URL) -> [Scheme.BuildableReference] {
        projects.keys.sorted().flatMap { path -> [Scheme.BuildableReference] in
            guard let proj = projects[path] else { return [] }
            let u = URL(fileURLWithPath: path)
            let base = container.pathExtension == "xcworkspace" ? container.deletingLastPathComponent() : u.deletingLastPathComponent()
            let rel = u.path.hasPrefix(base.path + "/") ? String(u.path.dropFirst(base.path.count + 1)) : u.lastPathComponent
            return proj.targets.map { t in
                Scheme.BuildableReference(blueprintIdentifier: t.id,
                                          buildableName: t.string("productReference").flatMap { proj[$0]?.string("path") } ?? t.string("name") ?? "",
                                          blueprintName: t.string("name") ?? "", referencedContainer: "container:" + rel)
            }
        }
    }

    /// Targets "+" can add: the available ones not in the scheme.
    public var addableBuildTargets: [Scheme.BuildableReference] {
        let have = Set(scheme.buildEntries.map(\.reference.blueprintIdentifier))
        return availableTargets.filter { !have.contains($0.blueprintIdentifier) }
    }

    func buildTargetsPlus(_ b: NSButton) {
        guard view.window?.isVisible == true else { return }
        let menu = NSMenu()
        for t in addableBuildTargets {
            let item = NSMenuItem(title: t.blueprintName, action: #selector(buildTargetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.blueprintIdentifier
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func buildTargetChosen(_ i: NSMenuItem) {
        if let id = i.representedObject as? String, let t = availableTargets.first(where: { $0.blueprintIdentifier == id }) { addBuildTarget(t) }
    }

    /// Adds a target to Build: every action on, except Test only for test
    /// bundles (".xctest").
    public func addBuildTarget(_ ref: Scheme.BuildableReference) {
        let tests = ref.buildableName.hasSuffix(".xctest")
        scheme.addBuildEntry(ref, actions: tests ? [.testing] : Set(Scheme.Action.allCases))
        reloadPane()
    }

    public func removeBuildTarget(_ blueprintIdentifier: String) {
        scheme.removeBuildEntry(blueprintIdentifier: blueprintIdentifier)
        reloadPane()
    }

    // MARK: Test plans

    static func testPlanName(_ reference: String) -> String {
        URL(fileURLWithPath: reference.replacingOccurrences(of: "container:", with: "")).deletingPathExtension().lastPathComponent
    }

    /// A plan row's subtitle: its location inside the container.
    static func testPlanSubtitle(_ reference: String) -> String { reference.replacingOccurrences(of: "container:", with: "") }

    static func autocreatedSubtitle(_ n: Int) -> String { "\(n) test target\(n == 1 ? "" : "s") \u{2014} from the scheme" }

    func testPlanCell(_ name: String, subtitle: String, reference: String?) -> NSView {
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 12)
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let arrow = NSButton(image: NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Show the test plan")!,
                             target: self, action: #selector(goToTestPlan(_:)))
        arrow.isBordered = false
        arrow.identifier = .init(reference ?? "")
        arrow.isEnabled = reference != nil
        arrow.toolTip = "Show the test plan"
        return NSStackView(views: [text, arrow])
    }

    /// The file a `container:` reference names.
    public func testPlanURL(_ reference: String) -> URL? {
        guard let dir = containerDirectory else { return nil }
        return dir.appendingPathComponent(reference.replacingOccurrences(of: "container:", with: ""))
    }

    @objc func goToTestPlan(_ b: NSButton) {
        guard let ref = b.identifier?.rawValue, !ref.isEmpty, let u = testPlanURL(ref) else { return }
        onOpenFile?(u)
    }

    @objc func defaultPlanChosen(_ b: NSButton) { if let r = b.identifier?.rawValue { setDefaultTestPlan(r) } }

    func testPlanPlus() {
        guard let w = view.window, w.isVisible else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.directoryURL = containerDirectory
        panel.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = panel.url, u.pathExtension == "xctestplan" { self?.addTestPlan(file: u) }
        }
    }

    /// Adds an existing `.xctestplan` (a `container:` path relative to the
    /// folder that holds the container).
    public func addTestPlan(file: URL) {
        let path = file.standardizedFileURL.path
        let base = containerDirectory?.standardizedFileURL.path ?? ""
        let rel = !base.isEmpty && path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent
        scheme.addTestPlan(reference: "container:" + rel)
        reloadPane()
    }

    public func removeTestPlan(_ reference: String) {
        scheme.removeTestPlan(reference: reference)
        reloadPane()
    }

    public func setDefaultTestPlan(_ reference: String) {
        scheme.setDefaultTestPlan(reference: reference)
        reloadPane()
    }

    /// The folder `container:` paths are relative to: the one holding the
    /// `.xcodeproj` / `.xcworkspace` the scheme belongs to.
    public var containerDirectory: URL? {
        if let explicit = containerDirectoryOverride { return explicit }
        var u = scheme.url
        while let cur = u, !["xcodeproj", "xcworkspace"].contains(cur.pathExtension), cur.path != "/" { u = cur.deletingLastPathComponent() }
        return u.flatMap { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) ? $0.deletingLastPathComponent() : nil }
    }

    func reloadPane() { select(action: selectedAction, tab: selectedRunTab) }
}
