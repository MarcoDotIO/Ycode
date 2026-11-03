import AppKit
import YcodeIDECore
import YcodeProfiler

/// Gauge's window (`specs/ide/profiler.md` §6): the toolbar (Record/Stop,
/// target, elapsed time, sample rate), the track timeline, and below it the
/// call tree, flame graph or source annotation with an inspector.
@MainActor
public final class GaugeWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSToolbarDelegate {
    public let model = GaugeModel()
    public let timeline: GaugeTimelineView
    public let flameView: GaugeFlameView
    public let outline = NSOutlineView()
    public let sourceView = NSTextView()
    public let inspectorView = NSTextView()
    public let contentPicker = NSSegmentedControl(labels: GaugeModel.Content.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    public let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    public let threadButton = NSPopUpButton(frame: .zero, pullsDown: false)
    public let searchField = NSSearchField()
    public let recordButton = NSButton()
    public let targetLabel = NSTextField(labelWithString: "")
    public let timeLabel = NSTextField(labelWithString: "")
    public let rateLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let timelineScroll = NSScrollView()
    let treeScroll = NSScrollView()
    let flameScroll = NSScrollView()
    let sourceScroll = NSScrollView()
    let mainSplit = NSSplitView()
    let lowerSplit = NSSplitView()
    let recordingView = NSTextField(labelWithString: "")

    /// Record (start again) and Stop, set by whoever started the recording.
    public var onRecord: (() -> Void)?
    public var onStop: (() -> Void)?
    private var clock: Timer?
    private var sampleRate = 1000

    /// Open windows (they stay alive while shown).
    static var windows: [GaugeWindowController] = []

    public init(title: String = "Gauge") {
        timeline = GaugeTimelineView(model: model)
        flameView = GaugeFlameView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.subtitle = ExperimentalNotice.label
        window.minSize = NSSize(width: 820, height: 560)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        model.onChange = { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Opening

    /// Opens a window for a trace file.
    @discardableResult
    public static func show(traceAt url: URL) throws -> GaugeWindowController {
        let w = GaugeWindowController(title: url.lastPathComponent)
        try w.model.load(url: url)
        w.present()
        return w
    }

    public func present() {
        if !Self.windows.contains(where: { $0 === self }) { Self.windows.append(self) }
        window?.center()
        showWindow(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        clock?.invalidate()
        Self.windows.removeAll { $0 === self }
    }

    /// Recording has started (the trace arrives when it ends).
    public func beginRecording(target: String, rate: Int) {
        sampleRate = rate
        window?.title = "Gauge — \(target)"
        model.phase = .recording(target: target, since: Date())
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        refresh()
    }

    public func load(url: URL) {
        clock?.invalidate()
        do {
            try model.load(url: url)
            window?.title = url.lastPathComponent
            window?.representedURL = url
        } catch {
            model.phase = .failed("\(error)")
        }
    }

    public func fail(_ message: String) {
        clock?.invalidate()
        model.phase = .failed(message)
    }

    private func updateClock() {
        if case .recording(_, let since) = model.phase {
            let s = Date().timeIntervalSince(since)
            timeLabel.stringValue = String(format: "%02d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
        }
    }

    // MARK: Layout

    private func build() {
        guard let window, let content = window.contentView else { return }
        let toolbar = NSToolbar(identifier: "GaugeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        recordButton.bezelStyle = .texturedRounded
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        recordButton.target = self
        recordButton.action = #selector(recordOrStop(_:))
        targetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rateLabel.font = .systemFont(ofSize: 11)
        rateLabel.textColor = .secondaryLabelColor

        // Timeline.
        timelineScroll.documentView = timeline
        timelineScroll.hasVerticalScroller = true
        timelineScroll.drawsBackground = false
        timeline.frame = NSRect(x: 0, y: 0, width: 1200, height: timeline.preferredHeight)
        timeline.autoresizingMask = [.width]

        // Call tree.
        for (id, title, width) in [("weight", "Weight", 120.0), ("self", "Self Weight", 90.0), ("symbol", "Symbol Name", 600.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            outline.addTableColumn(c)
            if id == "symbol" { outline.outlineTableColumn = c }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.rowHeight = 20
        outline.target = self
        outline.doubleAction = #selector(openSource(_:))
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true

        flameScroll.documentView = flameView
        flameScroll.hasVerticalScroller = true
        flameView.autoresizingMask = [.width]

        for tv in [sourceView, inspectorView] {
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.isVerticallyResizable = true
            tv.autoresizingMask = [.width]
        }
        inspectorView.font = .systemFont(ofSize: 11.5)
        sourceScroll.documentView = sourceView
        sourceScroll.hasVerticalScroller = true
        let inspectorScroll = NSScrollView()
        inspectorScroll.documentView = inspectorView
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.drawsBackground = false
        inspectorView.drawsBackground = false

        // The bar over the lower area.
        contentPicker.target = self
        contentPicker.action = #selector(contentChosen(_:))
        contentPicker.selectedSegment = 0
        optionsButton.addItem(withTitle: "Call Tree")
        for (title, tag) in [("Separate by Thread", 1), ("Invert Call Tree", 2), ("Hide System Libraries", 3), ("Flatten Recursion", 4),
                             ("All States (include waiting)", 5)] {
            let item = NSMenuItem(title: title, action: #selector(optionChosen(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            optionsButton.menu?.addItem(item)
        }
        optionsButton.menu?.addItem(.separator())
        for (title, tag) in [("Charge Function to Callers", 10), ("Charge Library to Callers", 11), ("Restore Charged Symbols", 12)] {
            let item = NSMenuItem(title: title, action: #selector(optionChosen(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            optionsButton.menu?.addItem(item)
        }
        threadButton.target = self
        threadButton.action = #selector(threadChosen(_:))
        searchField.placeholderString = "Find Symbol"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [contentPicker, optionsButton, threadButton, searchField, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        threadButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSView()
        for v in [bar, treeScroll, flameScroll, sourceScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: left.topAnchor), bar.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: left.trailingAnchor),
        ])
        for s in [treeScroll, flameScroll, sourceScroll] {
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: bar.bottomAnchor), s.leadingAnchor.constraint(equalTo: left.leadingAnchor),
                s.trailingAnchor.constraint(equalTo: left.trailingAnchor), s.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            ])
        }

        lowerSplit.isVertical = true
        lowerSplit.dividerStyle = .thin
        lowerSplit.addArrangedSubview(left)
        lowerSplit.addArrangedSubview(inspectorScroll)
        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thin
        mainSplit.addArrangedSubview(timelineScroll)
        mainSplit.addArrangedSubview(lowerSplit)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        recordingView.translatesAutoresizingMaskIntoConstraints = false
        recordingView.font = .systemFont(ofSize: 15)
        recordingView.textColor = .secondaryLabelColor
        recordingView.alignment = .center
        content.addSubview(mainSplit)
        content.addSubview(recordingView)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            recordingView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            recordingView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.layoutIfNeeded()
        mainSplit.setPosition(min(260, timeline.preferredHeight + 4), ofDividerAt: 0)
        lowerSplit.setPosition(window.frame.width - 300, ofDividerAt: 0)
        refresh()
    }

    // MARK: Toolbar

    static let recordItem = NSToolbarItem.Identifier("gauge.record")
    static let targetItem = NSToolbarItem.Identifier("gauge.target")
    static let timeItem = NSToolbarItem.Identifier("gauge.time")
    static let rateItem = NSToolbarItem.Identifier("gauge.rate")

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.recordItem, Self.targetItem, .flexibleSpace, Self.timeItem, Self.rateItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.recordItem:
            item.view = recordButton
            item.label = "Record"
        case Self.targetItem:
            item.view = targetLabel
            item.label = "Target"
        case Self.timeItem:
            item.view = timeLabel
            item.label = "Time"
        case Self.rateItem:
            item.view = rateLabel
            item.label = "Sample Rate"
        default: return nil
        }
        return item
    }

    // MARK: Actions

    @objc func recordOrStop(_ sender: Any?) {
        if case .recording = model.phase { onStop?() } else { onRecord?() }
    }

    @objc func contentChosen(_ c: NSSegmentedControl) {
        model.content = GaugeModel.Content(rawValue: c.selectedSegment) ?? .callTree
    }

    @objc func optionChosen(_ item: NSMenuItem) {
        switch item.tag {
        case 1: model.options.separateByThread.toggle()
        case 2: model.options.invert.toggle()
        case 3: model.options.hideSystemLibraries.toggle()
        case 4: model.options.flattenRecursion.toggle()
        case 5: model.allStates.toggle()
        case 10: model.chargeSelectedToCallers(wholeImage: false)
        case 11: model.chargeSelectedToCallers(wholeImage: true)
        case 12: model.clearCharges()
        default: break
        }
    }

    @objc func threadChosen(_ p: NSPopUpButton) {
        let id = p.selectedItem?.representedObject as? UInt64
        model.threads = id.map { [$0] }
    }

    @objc func searchChanged(_ f: NSSearchField) {
        model.searchText = f.stringValue
        if !f.stringValue.isEmpty, let n = model.tree?.root.find(f.stringValue) { model.selectedPath = n.path }
    }

    @objc func openSource(_ sender: Any?) {
        guard outline.clickedRow >= 0 else { return }
        model.content = .source
    }

    // MARK: Refresh

    private var lastTreeIdentity: ObjectIdentifier?

    func refresh() {
        let recording: Bool
        switch model.phase {
        case .recording(let target, _):
            recording = true
            targetLabel.stringValue = target
            recordingView.stringValue = "Recording \(target)…\nThe trace opens here when the run stops."
        case .failed(let message):
            recording = false
            recordingView.stringValue = "No trace: \(message)"
        case .loaded:
            recording = false
            recordingView.stringValue = ""
        }
        recordButton.image = NSImage(systemSymbolName: recording ? "stop.fill" : "record.circle", accessibilityDescription: recording ? "Stop" : "Record")
        recordButton.isEnabled = recording ? onStop != nil : onRecord != nil
        let hasTrace = model.trace != nil && !recording
        mainSplit.isHidden = !hasTrace
        recordingView.isHidden = hasTrace
        guard let t = model.trace, hasTrace else { return }

        if case .loaded = model.phase {
            let target = t.processes.first(where: \.isTarget)?.name ?? t.recording.command
            targetLabel.stringValue = t.recording.device.isEmpty ? target : "\(target) on \(t.recording.device)"
            timeLabel.stringValue = String(format: "%.2f s", Double(t.recording.durationNs) / 1e9)
            rateLabel.stringValue = String(format: "%.0f Hz · %d samples", 1e9 / Double(max(1, t.recording.sampleIntervalNs)), t.samples.count)
        }
        // Option check marks.
        for item in optionsButton.menu?.items ?? [] {
            switch item.tag {
            case 1: item.state = model.options.separateByThread ? .on : .off
            case 2: item.state = model.options.invert ? .on : .off
            case 3: item.state = model.options.hideSystemLibraries ? .on : .off
            case 4: item.state = model.options.flattenRecursion ? .on : .off
            case 5: item.state = model.allStates ? .on : .off
            default: break
            }
        }
        // Threads.
        if threadButton.numberOfItems == 0 {
            threadButton.addItem(withTitle: "All Threads")
            for c in model.threadChoices {
                threadButton.addItem(withTitle: c.title)
                threadButton.lastItem?.representedObject = c.id
            }
        }
        contentPicker.selectedSegment = model.content.rawValue
        treeScroll.isHidden = model.content != .callTree
        flameScroll.isHidden = model.content != .flameGraph
        sourceScroll.isHidden = model.content != .source

        timeline.frame.size.height = timeline.preferredHeight
        timeline.needsDisplay = true
        if let tree = model.tree, ObjectIdentifier(tree.root) != lastTreeIdentity {
            lastTreeIdentity = ObjectIdentifier(tree.root)
            outline.reloadData()
            // The heaviest path open.
            var n: CallTreeNode? = tree.root.children.first
            var depth = 0
            while let node = n, depth < 12 {
                outline.expandItem(node)
                n = node.children.first
                depth += 1
            }
        }
        selectInOutline()
        flameView.frame.size = NSSize(width: max(400, flameScroll.contentSize.width), height: max(flameScroll.contentSize.height, flameView.preferredHeight))
        flameView.needsDisplay = true
        if model.content == .source { renderSource() }
        renderInspector()
        let tree = model.tree
        statusLabel.stringValue = (model.range.map { String(format: "%.1f–%.1f ms · ", Double($0.lowerBound) / 1e6, Double($0.upperBound) / 1e6) } ?? "")
            + String(format: "%.1f ms in %d samples", tree.map { $0.milliseconds($0.sampleCount) } ?? 0, tree?.sampleCount ?? 0)
    }

    private func selectInOutline() {
        guard let node = model.selectedNode else { return }
        var chain: [CallTreeNode] = []
        var n: CallTreeNode? = node
        while let c = n, c.key != .root { chain.append(c); n = c.parent }
        for c in chain.reversed().dropLast() { outline.expandItem(c) }
        let row = outline.row(forItem: node)
        if row >= 0, outline.selectedRow != row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    private func renderSource() {
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let out = NSMutableAttributedString()
        guard let node = model.selectedNode, node.function != nil else {
            sourceView.textStorage?.setAttributedString(NSAttributedString(string: "Select a function in the call tree or the flame graph.",
                                                                            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            return
        }
        guard let a = model.annotation, let file = a.file else {
            sourceView.textStorage?.setAttributedString(NSAttributedString(string: "\(node.name): no line information (the trace has no dSYM lines for \(node.imageName)).",
                                                                            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            return
        }
        out.append(NSAttributedString(string: "\(node.name) — \(file)\n\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        let peak = max(1, a.lines.map(\.total).max() ?? 1)
        let by = Dictionary(uniqueKeysWithValues: a.lines.map { ($0.line, $0) })
        if let text = try? String(contentsOfFile: file, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n")
            let first = max(1, (a.lines.first?.line ?? 1) - 6), last = min(lines.count, (a.lines.last?.line ?? 1) + 6)
            for n in first...max(first, last) {
                let c = by[n]
                let head = c.map { String($0.selfCount) } ?? ""
                let prefix = String(repeating: " ", count: max(0, 7 - head.count)) + head
                    + String(repeating: " ", count: max(0, 8 - (c.map { String($0.total).count } ?? 0))) + (c.map { String($0.total) } ?? "")
                    + String(repeating: " ", count: max(0, 6 - String(n).count)) + String(n) + "  "
                var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor]
                if let c, c.total > 0 {
                    attrs[.backgroundColor] = NSColor.systemOrange.withAlphaComponent(0.12 + 0.5 * CGFloat(c.total) / CGFloat(peak))
                }
                out.append(NSAttributedString(string: prefix + (n - 1 < lines.count ? lines[n - 1] : "") + "\n", attributes: attrs))
            }
        } else {
            for c in a.lines {
                out.append(NSAttributedString(string: String(format: "%7d %7d  line %d\n", c.selfCount, c.total, c.line), attributes: [.font: mono]))
            }
        }
        sourceView.textStorage?.setAttributedString(out)
    }

    private func renderInspector() {
        let out = NSMutableAttributedString()
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor]
        guard let tree = model.tree, let t = model.trace else { return }
        let node = model.selectedNode ?? tree.root.children.first
        if let node {
            out.append(NSAttributedString(string: "HEAVIEST STACK\n", attributes: head))
            for n in node.heaviestPath.prefix(40) {
                let pct = tree.sampleCount > 0 ? 100 * Double(n.total) / Double(tree.sampleCount) : 0
                out.append(NSAttributedString(string: String(format: "%5.1f %%  ", pct), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
                out.append(NSAttributedString(string: n.name, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: n.imageKind == .app ? .semibold : .regular), .foregroundColor: NSColor.labelColor]))
                if !n.imageName.isEmpty {
                    out.append(NSAttributedString(string: "  \(n.imageName)", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor]))
                }
                out.append(NSAttributedString(string: "\n", attributes: body))
            }
            out.append(NSAttributedString(string: "\nSELECTION\n", attributes: head))
            out.append(NSAttributedString(string: (model.selectedNode != nil ? model.selectionSummary : "Nothing selected") + "\n", attributes: body))
            if let f = node.function, let img = t.image(f.image) {
                out.append(NSAttributedString(string: "\(img.path)\nUUID \(img.uuid ?? "unknown")\n", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        if !t.signposts.isEmpty {
            out.append(NSAttributedString(string: "\nSIGNPOSTS\n", attributes: head))
            for s in GaugeTimeline.summarize(t.signposts).prefix(10) {
                out.append(NSAttributedString(string: String(format: "%@  %d×, mean %.1f ms, max %.1f ms\n", s.name, s.count, Double(s.meanNs) / 1e6, Double(s.maxNs) / 1e6), attributes: body))
            }
        }
        out.append(NSAttributedString(string: "\nHANGS\n", attributes: head))
        out.append(NSAttributedString(string: model.hangs.isEmpty ? "None\n" : model.hangs.prefix(8).map {
            String(format: "%@ %.0f ms at %.2f s", GaugeTimeline.severity($0, threshold: t.recording.hangThresholdNs), Double($0.duration) / 1e6, Double($0.begin) / 1e9)
        }.joined(separator: "\n") + "\n", attributes: body))
        out.append(NSAttributedString(string: "\nRECORDING\n", attributes: head))
        out.append(NSAttributedString(string: "\(t.recording.recorder)\n\(t.recording.host)\n" + t.recording.notes.map { $0 + "\n" }.joined(), attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
        inspectorView.textStorage?.setAttributedString(out)
    }

    // MARK: Outline data source

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree = model.tree else { return 0 }
        return ((item as? CallTreeNode) ?? tree.root).children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? CallTreeNode) ?? model.tree?.root)?.children[index] as Any
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? CallTreeNode)?.children.isEmpty ?? true)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? CallTreeNode, let tree = model.tree, let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("gauge." + id), owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = NSUserInterfaceItemIdentifier("gauge." + id)
            let f = NSTextField(labelWithString: "")
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            c.addSubview(f)
            c.textField = f
            NSLayoutConstraint.activate([f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                         f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                                         f.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            return c
        }()
        let total = max(1, tree.sampleCount)
        switch id {
        case "weight":
            cell.textField?.stringValue = String(format: "%.1f ms  %5.1f%%", tree.milliseconds(n.total), 100 * Double(n.total) / Double(total))
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            cell.textField?.alignment = .right
        case "self":
            cell.textField?.stringValue = n.selfCount > 0 ? String(format: "%.1f ms", tree.milliseconds(n.selfCount)) : ""
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            cell.textField?.alignment = .right
        default:
            let s = NSMutableAttributedString(string: n.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: n.imageKind == .app ? .semibold : .regular),
                                                                           .foregroundColor: n.imageKind == .app || n.imageName.isEmpty ? NSColor.labelColor : NSColor.secondaryLabelColor])
            if !n.imageName.isEmpty {
                s.append(NSAttributedString(string: "   \(n.imageName)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if !model.searchText.isEmpty, n.name.localizedCaseInsensitiveContains(model.searchText) {
                s.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.5), range: NSRange(location: 0, length: (n.name as NSString).length))
            }
            cell.textField?.attributedStringValue = s
        }
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = outline.item(atRow: outline.selectedRow) as? CallTreeNode else { return }
        if model.selectedPath != n.path { model.selectedPath = n.path }
    }

    // MARK: Snapshot

    /// Writes a PNG of the window's contents (its frame view: toolbar and
    /// content) — the window does not have to be on screen.
    @discardableResult
    public func writeSnapshot(to url: URL) -> Bool {
        guard let window, let view = window.contentView?.superview ?? window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
