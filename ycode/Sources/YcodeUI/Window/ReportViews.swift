import AppKit
import YcodeBuild

/// What a report shows besides its log: the action, where it ran, and
/// (for test runs) the outcomes. See `specs/ide/reference-ui-2.md` §4–§6.
public struct ReportContext: Equatable, Sendable {
    public var action = "Build"
    public var scheme: String?
    public var containerKind = "Project"
    public var containerName = ""
    public var configuration = "Debug"
    public var destination = ""
    public var duration: TimeInterval = 0
    public var issues: [Diagnostic] = []
    public var tests: [TestOutcome] = []
    /// Test plan name (test runs): the scheme's default plan, else
    /// "<scheme> (Autocreated)".
    public var plan: String?
    public var testTargets = 0
    /// The test target's name, when known.
    public var testTarget: String?
    /// Local or Cloud (the Report navigator's switch).
    public var location: ReportLocation = .local
    /// SDK name and version ("macOS 27.2"), for the build log subtitle.
    public var sdk = ""
    /// Line coverage per target (test runs with coverage enabled).
    public var coverage: [CoverageItem] = []
    /// Seconds from the start of the operation at which each `log` line
    /// arrived (same count as the log when recorded), for step durations.
    public var logTimes: [TimeInterval] = []
    /// Build-log steps of earlier builds of the same scheme (since its last
    /// clean) that this build did not run again: the build log's "All"
    /// scope adds them; "Recent" shows only this build's steps.
    public var carriedOver: [BuildLogSection] = []
    public var kind: ReportKind {
        switch action {
        case "Test": .test
        case "Clean": .clean
        case "Analyze": .analyze
        case "Build": .build
        default: .package
        }
    }
    public init() {}
}

/// Relative day and time: "Today, 3:46 AM".
public enum ReportFormat {
    public static func dayAndTime(_ d: Date) -> String {
        let day = DateFormatter()
        day.dateStyle = .medium
        day.timeStyle = .none
        day.doesRelativeDateFormatting = true
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(day.string(from: d)), \(time.string(from: d))"
    }

    public static func footerDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        let t = DateFormatter()
        t.dateStyle = .none
        t.timeStyle = .short
        return "\(f.string(from: d)), \(t.string(from: d))"
    }

    public static func seconds(_ s: TimeInterval) -> String { String(format: "%.1f", s) }
}

/// A row of the build log outline: a target section, a step, or an issue.
final class BuildLogNode: NSObject {
    let title: String
    var subtitle: String?
    var badge: String?
    var transcript: [String] = []
    var severity: Diagnostic.Severity?
    var isSection = false
    var children: [BuildLogNode] = []
    init(title: String) { self.title = title }

    static func make(_ sections: [BuildLogSection], subtitle: String) -> [BuildLogNode] {
        func step(_ s: BuildLogStep) -> BuildLogNode {
            let n = BuildLogNode(title: s.displayTitle)
            n.badge = s.badge
            n.transcript = s.transcript
            n.children = s.children.map(step) + s.issues.map { d in
                let i = BuildLogNode(title: d.message)
                i.severity = d.severity
                return i
            }
            return n
        }
        return sections.map { sec in
            let n = BuildLogNode(title: sec.title)
            n.isSection = true
            n.subtitle = subtitle
            n.children = sec.steps.map(step)
            return n
        }
    }
}

/// The build log (reference-ui-2.md §5): a scope bar, one section per
/// target with nested steps (badges and transcript buttons), and a footer.
@MainActor
public final class BuildLogView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public let report: BuildReport
    public let scope = NSSegmentedControl(labels: ["All", "Recent"], trackingMode: .selectOne, target: nil, action: nil)
    public let kind = NSSegmentedControl(labels: ["All Messages", "All Issues", "Errors Only"], trackingMode: .selectOne, target: nil, action: nil)
    public let filter = NSSearchField()
    let outline = NSOutlineView()
    let sections: [BuildLogSection]
    var nodes: [BuildLogNode] = []
    /// Steps whose transcript is shown.
    var expandedTranscripts: Set<ObjectIdentifier> = []

    public init(report: BuildReport) {
        self.report = report
        sections = BuildLogModel.sections(report)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        scope.selectedSegment = 0
        kind.selectedSegment = 1
        for c in [scope, kind] as [NSControl] { c.target = self; c.action = #selector(refresh); c.controlSize = .small }
        filter.placeholderString = "Filter"
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(refresh)
        let export = NSButton(title: "Export…", target: self, action: #selector(exportLog))
        export.controlSize = .small
        export.bezelStyle = .push
        let bar = NSStackView(views: [scope, kind, export, filter])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let col = NSTableColumn(identifier: .init("step"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.usesAutomaticRowHeights = true
        outline.dataSource = self
        outline.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        let footer = footerView()
        for v in [bar, scroll, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The first section's title and every section's subtitle (§5.2).
    public var sectionTitle: String { sections.first?.title ?? "Build target \(report.schemeName)" }
    public var sectionSubtitle: String { BuildLogModel.subtitle(report.context) }
    /// The footer's two lines (§5.4).
    public var footerLines: (String, String) { BuildLogModel.footer(report) }

    /// Sections the bar's settings show: All adds the steps carried over
    /// from earlier builds; Recent is this build's steps only.
    public var shownSections: [BuildLogSection] {
        let base = scope.selectedSegment == 1 ? sections : BuildLogModel.merge(sections, report.context.carriedOver)
        return BuildLogModel.filter(base, messages: BuildLogModel.Messages(rawValue: kind.selectedSegment) ?? .issues, text: filter.stringValue)
    }
    /// The shown outline as indented text (tests, Export).
    public var shownLines: [String] { BuildLogModel.outline(shownSections) }

    @objc func refresh() {
        nodes = BuildLogNode.make(shownSections, subtitle: sectionSubtitle)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? BuildLogNode)?.children.count ?? nodes.count }
    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? BuildLogNode)?.children[index] ?? nodes[index] }
    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? BuildLogNode)?.children.isEmpty ?? true) }

    public func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? BuildLogNode else { return nil }
        let title = NSTextField(labelWithString: n.title)
        title.font = n.isSection ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        var left: [NSView] = []
        if let sev = n.severity {
            let icon = NSImageView(image: NSImage(systemSymbolName: sev == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
            icon.contentTintColor = sev == .error ? Theme.errorColor : .systemYellow
            left.append(icon)
        }
        left.append(title)
        let row = NSStackView(views: left)
        row.spacing = 4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        if let b = n.badge {
            let badge = NSTextField(labelWithString: b)
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = Theme.errorColor
            row.addArrangedSubview(badge)
        }
        if !n.transcript.isEmpty {
            let t = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Transcript")!, target: self, action: #selector(toggleTranscript(_:)))
            t.isBordered = false
            t.toolTip = "Show the transcript"
            t.identifier = .init("\(o.row(forItem: n))")
            row.addArrangedSubview(t)
        }
        let col = NSStackView(views: [row])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        if let s = n.subtitle {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            col.addArrangedSubview(l)
        }
        if expandedTranscripts.contains(ObjectIdentifier(n)) {
            let l = NSTextField(wrappingLabelWithString: n.transcript.joined(separator: "\n"))
            l.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            l.textColor = .secondaryLabelColor
            col.addArrangedSubview(l)
        }
        row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    @objc func toggleTranscript(_ sender: NSButton) {
        let r = outline.row(for: sender)
        guard r >= 0, let n = outline.item(atRow: r) as? BuildLogNode else { return }
        let id = ObjectIdentifier(n)
        if expandedTranscripts.contains(id) { expandedTranscripts.remove(id) } else { expandedTranscripts.insert(id) }
        outline.reloadItem(n, reloadChildren: false)
    }

    func footerView() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: report.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = report.succeeded ? .systemGreen : Theme.errorColor
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        let (a, b) = footerLines
        let l1 = NSTextField(labelWithString: a)
        l1.font = .boldSystemFont(ofSize: 12)
        let l2 = NSTextField(labelWithString: b)
        l2.textColor = .secondaryLabelColor
        let col = NSStackView(views: [l1, l2])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        return NSStackView(views: [icon, col])
    }

    @objc func exportLog() {
        guard let w = window, w.isVisible else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(report.title).txt"
        let text = (report.log + [""] + shownLines).joined(separator: "\n")
        p.beginSheetModal(for: w) { r in
            if r == .OK, let u = p.url { try? text.write(to: u, atomically: true, encoding: .utf8) }
        }
    }
}

/// A test run's report pages (reference-ui-2.md §6): Summary (Insights),
/// Tests, Coverage.
@MainActor
public final class TestReportView: NSView {
    public enum Page: String { case summary = "Insights", tests = "Tests", coverage = "Coverage" }
    public let report: BuildReport
    public let page: Page
    let stack = NSStackView()
    /// Tests page: the Failed Tests filter, and the text filter (both pages).
    public var failedOnly = false { didSet { rebuild() } }
    /// Tests page: the other filter pop-ups (reference-ui-5.md §11.3, P12).
    public var filters = TestReportFilters() { didSet { rebuild() } }
    /// Tests page: the filter pop-ups, in order (tests).
    public private(set) var filterPopUps: [NSPopUpButton] = []
    /// Coverage page: targets shown expanded to their files.
    public var expandedCoverage: Set<String> = [] { didSet { rebuild() } }
    public let filter = NSSearchField()
    /// Coverage page: Show Test Bundles.
    public let showTestBundles = NSButton(checkboxWithTitle: "Show Test Bundles", target: nil, action: nil)

    public var passed: Int { TestReportModel.summary(report).passed }
    public var failed: Int { TestReportModel.summary(report).failed }
    public var planTitle: String { TestReportModel.title(report) }

    public init(report: BuildReport, page: Page) {
        self.report = report
        self.page = page
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        filter.placeholderString = "Filter"
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(filterChanged)
        showTestBundles.target = self
        showTestBundles.action = #selector(filterChanged)
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lines of text the page shows (tests).
    public private(set) var lines: [String] = []

    @objc func filterChanged() { rebuild() }

    func rebuild() {
        lines = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch page {
        case .summary: summary(into: stack)
        case .tests: tests(into: stack)
        case .coverage: coverage(into: stack)
        }
    }

    private func label(_ s: String, bold: Bool = false, size: CGFloat = 12, secondary: Bool = false, mono: Bool = false) -> NSTextField {
        lines.append(s)
        let l = NSTextField(labelWithString: s)
        l.font = mono ? .monospacedSystemFont(ofSize: size - 1, weight: .regular) : (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        if secondary { l.textColor = .secondaryLabelColor }
        return l
    }

    private func spaced(_ a: NSView, _ b: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [a, spacer, b])
        return s
    }

    private func summary(into s: NSStackView) {
        let m = TestReportModel.summary(report)
        let head = NSStackView(views: [label(m.title, bold: true, size: 16), label(m.builtWith, secondary: true)])
        head.orientation = .vertical
        head.alignment = .leading
        let top = spaced(head, label(m.started, secondary: true))
        s.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -40).isActive = true
        lines.append(m.total)
        let legend = NSStackView(views: [label("Passed  \(m.passed)"), label("Failure  \(m.failed)")])
        legend.orientation = .vertical
        legend.alignment = .leading
        let card = NSStackView(views: [label("Tests", bold: true), NSStackView(views: [RingView(passed: m.passed, failed: m.failed), legend])])
        card.orientation = .vertical
        card.alignment = .leading
        s.addArrangedSubview(card)
        var rows: [[NSView]] = [[label("Devices & Configurations", bold: true), label("Passed", bold: true), label("Failure", bold: true)]]
        for r in m.configurations {
            rows.append([label((r.isDevice ? "" : "    ") + r.name),
                         ShareBar(share: r.passedShare, text: "\(r.passed)", color: .systemGreen),
                         ShareBar(share: r.failedShare, text: "\(r.failed)", color: Theme.errorColor)])
            lines += ["\(r.passed)", "\(r.failed)"]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 24
        s.addArrangedSubview(grid)
        s.addArrangedSubview(label(m.failuresHeader, bold: true))
        for f in m.failures { s.addArrangedSubview(label(f)) }
    }

    private func tests(into s: NSStackView) {
        let c = report.context
        s.addArrangedSubview(label(c.plan ?? planTitle, bold: true, size: 14))
        s.addArrangedSubview(label(TestReportModel.testsHeader(report), secondary: true))
        filterPopUps = TestReportFilters.menus(report).enumerated().map { i, m -> NSPopUpButton in
            let p = NSPopUpButton(frame: .zero, pullsDown: true)
            p.controlSize = .small
            p.addItem(withTitle: m.title)
            for (j, title) in m.items.enumerated() {
                let item = NSMenuItem(title: title, action: #selector(filterItemPicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i * 100 + j
                item.state = selectedFilterItem(i) == j ? .on : .off
                p.menu?.addItem(item)
            }
            return p
        }
        s.addArrangedSubview(NSStackView(views: filterPopUps + [filter]))
        var rows: [[NSView]] = [[label("Test", bold: true), label("Duration", bold: true)]]
        for r in filters.rows(report, failedOnly: failedOnly, text: filter.stringValue) {
            let indent = String(repeating: "    ", count: r.depth)
            let title = label(indent + r.title, bold: r.kind == .target, secondary: r.kind == .expansion, mono: r.kind == .expansion)
            if r.kind == .failure { title.textColor = Theme.errorColor }
            var mark = NSView()
            if r.kind == .test, let st = r.status {
                let dia = NSImageView(image: NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: st.rawValue)!)
                dia.contentTintColor = st == .passed ? .systemGreen : (st == .failed ? Theme.errorColor : .secondaryLabelColor)
                mark = NSStackView(views: [dia, title])
            }
            rows.append([r.kind == .test ? mark : title, r.duration.map { label($0, secondary: true) } ?? NSView()])
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 24
        s.addArrangedSubview(grid)
    }

    @objc func failedFilterPicked(_ sender: NSMenuItem) { failedOnly = sender.tag == 1 }

    /// The checked item of filter pop-up `i`.
    func selectedFilterItem(_ i: Int) -> Int {
        switch i {
        case 0: failedOnly ? 1 : 0
        case 1: filters.failedRunsOnly ? 1 : 0
        case 2: filters.device == nil ? 0 : 1
        case 3: filters.configuration == nil ? 0 : 1
        default: filters.tag == nil ? 0 : 1
        }
    }

    /// Picks item `item` of filter pop-up `menu` (as a click would).
    public func pickFilter(menu: Int, item: Int) {
        let menus = TestReportFilters.menus(report)
        guard menus.indices.contains(menu), menus[menu].items.indices.contains(item) else { return }
        let on = item == 1
        switch menu {
        case 0: failedOnly = on
        case 1: filters.failedRunsOnly = on
        case 2: filters.device = on ? menus[menu].items[1] : nil
        case 3: filters.configuration = on ? menus[menu].items[1] : nil
        default: filters.tag = on ? menus[menu].items[1] : nil
        }
    }

    @objc func filterItemPicked(_ sender: NSMenuItem) { pickFilter(menu: sender.tag / 100, item: sender.tag % 100) }

    /// Expands or collapses a target row of the Coverage page.
    public func toggleCoverage(_ target: String) {
        if expandedCoverage.contains(target) { expandedCoverage.remove(target) } else { expandedCoverage.insert(target) }
    }

    @objc func coverageDisclosureClicked(_ b: NSButton) { if let t = b.identifier?.rawValue { toggleCoverage(t) } }

    private func coverage(into s: NSStackView) {
        lines.append("Show Test Bundles")
        s.addArrangedSubview(NSStackView(views: [showTestBundles, filter]))
        var rows: [[NSView]] = [[label("Name", bold: true), label("Coverage", bold: true), label("Executable Lines", bold: true)]]
        let items = CoverageModel.rows(report.context.coverage, showTestBundles: showTestBundles.state == .on, filter: filter.stringValue)
        // Target rows expand to their files (a filter shows matches open).
        for t in items {
            let open = expandedCoverage.contains(t.name) || (!filter.stringValue.isEmpty && !t.name.localizedCaseInsensitiveContains(filter.stringValue))
            for (item, depth) in [(t, 0)] + (open ? t.files.map { ($0, 1) } : []) {
                let name: NSView
                if depth == 0 {
                    let d = NSButton(title: open ? "\u{25BE}" : "\u{25B8}", target: self, action: #selector(coverageDisclosureClicked(_:)))
                    d.isBordered = false
                    d.identifier = .init(t.name)
                    d.isEnabled = !t.files.isEmpty
                    d.setAccessibilityLabel(open ? "Collapse \(t.name)" : "Expand \(t.name)")
                    name = NSStackView(views: [d, label(item.name, bold: true)])
                } else {
                    name = label("        " + item.name)
                }
                rows.append([name, ShareBar(share: item.fraction, text: CoverageModel.percent(item.fraction), color: .systemBlue),
                             label("\(item.executableLines)", secondary: true)])
                lines.append(CoverageModel.percent(item.fraction))
            }
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 40
        s.addArrangedSubview(grid)
        if report.context.coverage.isEmpty {
            s.addArrangedSubview(label("No coverage data: enable code coverage in the scheme's test action.", secondary: true))
        }
    }
}

/// A proportional bar with its value (summary table, coverage column).
final class ShareBar: NSView {
    let share: Double, color: NSColor
    init(share: Double, text: String, color: NSColor) {
        self.share = share
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 16))
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .medium)
        l.frame = NSRect(x: 4, y: 0, width: 112, height: 15)
        addSubview(l)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        color.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(1, share))), height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

/// The Tests card's ring: passed and failed shares around the total.
final class RingView: NSView {
    let passed: Int, failed: Int
    init(passed: Int, failed: Int) {
        self.passed = passed
        self.failed = failed
        super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
        widthAnchor.constraint(equalToConstant: 72).isActive = true
        heightAnchor.constraint(equalToConstant: 72).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let total = max(1, passed + failed)
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        var start: CGFloat = 90
        for (n, color) in [(passed, NSColor.systemGreen), (failed, Theme.errorColor)] where n > 0 {
            let sweep = 360 * CGFloat(n) / CGFloat(total)
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: 30, startAngle: start, endAngle: start - sweep, clockwise: true)
            p.lineWidth = 8
            color.setStroke()
            p.stroke()
            start -= sweep
        }
        let t = NSAttributedString(string: "\(passed + failed) Tests", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
        t.draw(at: NSPoint(x: c.x - t.size().width / 2, y: c.y - t.size().height / 2))
    }
}

/// The Tests page's filter pop-ups besides Failed Tests (reference-ui-2.md
/// §6.4; reference-ui-5.md §11.3, P12): Failed Runs, the run destination,
/// the configuration and the tags. A run is one test on one destination in
/// one configuration; Ycode's runs use a single destination and the scheme's
/// test action, and its runners report no tags, so every test is untagged.
public struct TestReportFilters: Equatable, Sendable {
    public var failedRunsOnly = false
    /// nil = all destinations.
    public var device: String?
    /// nil = all configurations.
    public var configuration: String?
    /// nil = all tags.
    public var tag: String?
    public init() {}

    public static let untagged = "Untagged Tests"
    public static let configurationTitle = "Test Scheme Action"

    /// Each pop-up's title and items (the first item means "all").
    public static func menus(_ r: BuildReport) -> [(title: String, items: [String])] {
        let titles = TestReportModel.filterTitles(r)
        let device = r.context.destination.isEmpty ? "My Mac" : r.context.destination
        return [(titles[0], ["All Tests", "Failed Tests Only"]), (titles[1], ["All Runs", "Failed Runs Only"]),
                (titles[2], ["All Run Destinations", device]), (titles[3], ["All Configurations", configurationTitle]),
                (titles[4], ["All Tags", untagged])]
    }

    /// The Tests page rows under every filter.
    public func rows(_ r: BuildReport, failedOnly: Bool, text: String) -> [TestReportModel.TestRow] {
        let device = r.context.destination.isEmpty ? "My Mac" : r.context.destination
        if let d = self.device, d != device { return [] }
        if let c = configuration, c != Self.configurationTitle { return [] }
        if let t = tag, t != Self.untagged { return [] }
        return TestReportModel.testRows(r, failedOnly: failedOnly || failedRunsOnly, text: text)
    }
}
