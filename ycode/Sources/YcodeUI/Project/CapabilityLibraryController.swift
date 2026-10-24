import AppKit

/// The "+ Capability" library panel (reference-ui-3.md §1.5): a filter
/// field, list/grid toggles, an alphabetical list with icons, a detail pane
/// for the selection, and an error footer when no team is set.
@MainActor
public final class CapabilityLibraryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public enum Layout: Int { case list, grid }

    public private(set) var items: [Capability] = []
    public private(set) var selected: Capability?
    public private(set) var layout: Layout = .list
    public var filter = "" { didSet { reload() } }
    /// Capabilities already on the target (shown, but not addable).
    public let present: Set<Capability>
    /// Footer lines ("Error Loading Capabilities" …) or nil.
    public let error: [String]?
    /// Adds the capability; returns an error message or nil.
    public var onAdd: ((Capability) -> String?)?

    let searchField = NSSearchField()
    let layoutControl = NSSegmentedControl()
    let table = NSTableView()
    let grid = NSStackView()
    private let listScroll = NSScrollView()
    let detailIcon = NSImageView()
    let detailName = NSTextField(labelWithString: "")
    let detailText = NSTextField(wrappingLabelWithString: "")
    let footer = NSTextField(wrappingLabelWithString: "")

    public init(present: Set<Capability>, error: [String]?) {
        self.present = present
        self.error = error
        super.init(nibName: nil, bundle: nil)
        title = ProjectEditorModel.capabilityLibraryTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        layoutControl.segmentCount = 2
        layoutControl.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 0)
        layoutControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid"), forSegment: 1)
        layoutControl.trackingMode = .selectOne
        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(layoutChosen)
        let col = NSTableColumn(identifier: .init("cap"))
        col.width = 240
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(addSelected)
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.isHidden = true
        detailIcon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        detailName.font = .boldSystemFont(ofSize: 15)
        detailText.textColor = .secondaryLabelColor
        detailText.preferredMaxLayoutWidth = 260
        let detail = NSStackView(views: [detailIcon, detailName, detailText])
        detail.orientation = .vertical
        detail.alignment = .leading
        footer.stringValue = error?.joined(separator: "\n") ?? ""
        footer.textColor = .systemRed
        footer.isHidden = error == nil
        let add = NSButton(title: "Add", target: self, action: #selector(addSelected))
        add.keyEquivalent = "\r"
        let top = NSStackView(views: [searchField, layoutControl])
        let middle = NSStackView(views: [listScroll, grid, detail])
        middle.alignment = .top
        middle.distribution = .fill
        let bottom = NSStackView(views: [footer, add])
        let stack = NSStackView(views: [top, middle, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 250), listScroll.heightAnchor.constraint(equalToConstant: 300),
            searchField.widthAnchor.constraint(equalToConstant: 420),
        ])
        view = root
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        items = ProjectEditorModel.capabilityLibrary(filter: filter)
        table.reloadData()
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in stride(from: 0, to: items.count, by: 3) {
            let buttons = items[row..<min(row + 3, items.count)].map { c -> NSButton in
                let b = NSButton(title: c.rawValue, image: NSImage(systemSymbolName: c.symbolName, accessibilityDescription: nil)!,
                                 target: self, action: #selector(gridClicked(_:)))
                b.imagePosition = .imageAbove
                b.isBordered = false
                b.identifier = .init(c.rawValue)
                b.widthAnchor.constraint(equalToConstant: 80).isActive = true
                return b
            }
            grid.addArrangedSubview(NSStackView(views: buttons))
        }
        select(selected.flatMap { items.contains($0) ? $0 : nil } ?? items.first)
    }

    public func select(_ c: Capability?) {
        selected = c
        if let c, let i = items.firstIndex(of: c) { table.selectRowIndexes([i], byExtendingSelection: false) }
        detailIcon.image = c.flatMap { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.rawValue) }
        detailName.stringValue = c?.rawValue ?? ""
        detailText.stringValue = c.map { present.contains($0) ? $0.summary + "\n\nAlready added." : $0.summary } ?? ""
    }

    public func setLayout(_ l: Layout) {
        _ = view
        layout = l
        layoutControl.selectedSegment = l.rawValue
        listScroll.isHidden = l == .grid
        grid.isHidden = l == .list
    }

    /// Adds the selection; closes the panel on success.
    @discardableResult
    public func addSelectedCapability() -> Bool {
        guard let c = selected, !present.contains(c) else { return false }
        if onAdd?(c) != nil { return false }
        if let w = view.window { if let p = w.sheetParent { p.endSheet(w) } else { w.close() } }
        return true
    }

    @objc private func addSelected() { addSelectedCapability() }
    @objc private func searchChanged() { filter = searchField.stringValue }
    @objc private func layoutChosen() { setLayout(Layout(rawValue: layoutControl.selectedSegment) ?? .list) }
    @objc private func gridClicked(_ b: NSButton) { select(Capability(rawValue: b.identifier?.rawValue ?? "")) }

    public func controlTextDidChange(_ obj: Notification) { filter = searchField.stringValue }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cap = items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: cap.symbolName, accessibilityDescription: nil)!)
        let name = NSTextField(labelWithString: cap.rawValue)
        name.textColor = present.contains(cap) ? .secondaryLabelColor : .labelColor
        return NSStackView(views: [icon, name])
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0, table.selectedRow < items.count, items[table.selectedRow] != selected { select(items[table.selectedRow]) }
    }
}
