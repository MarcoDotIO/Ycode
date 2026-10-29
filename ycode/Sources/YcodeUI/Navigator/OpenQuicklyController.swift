import AppKit

/// Open Quickly (⇧⌘O): a search field over a list of matching files and
/// symbols; Return opens the selected one. See `specs/ide/open-quickly.md`.
@MainActor
public final class OpenQuicklyController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public let field = NSSearchField()
    private let table = NSTableView()
    private var candidates: [FuzzyMatch.Candidate]
    public private(set) var results: [FuzzyMatch.Candidate] = []
    public var onOpen: ((FuzzyMatch.Candidate) -> Void)?
    /// Closes the panel when the controller is not presented as a sheet
    /// (the glass panel of `liquid-glass-ycode.md` §7).
    public var onClose: (() -> Void)?

    public init(candidates: [FuzzyMatch.Candidate]) {
        self.candidates = candidates
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 640, height: 380))
        field.placeholderString = "Open Quickly"
        field.font = .systemFont(ofSize: 20)
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged)
        let col = NSTableColumn(identifier: .init("r"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        if #available(macOS 26, *) {
            // The list sits on the panel's glass (liquid-glass-ycode.md §7).
            scroll.drawsBackground = false
            table.backgroundColor = .clear
            table.style = .inset
        }
        for v in [field, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Runs a query as typing would.
    /// New candidates (a fresh workspace index): the search runs again.
    public func update(candidates: [FuzzyMatch.Candidate]) {
        self.candidates = candidates
        if isViewLoaded { search(field.stringValue) }
    }

    public func search(_ q: String) {
        _ = view
        field.stringValue = q
        results = FuzzyMatch.search(q, in: candidates)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func searchChanged() { search(field.stringValue) }
    public func controlTextDidChange(_ obj: Notification) { search(field.stringValue) }

    /// Up/Down move the selection; Return opens; Escape closes.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let d = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let r = max(0, min(results.count - 1, table.selectedRow + d))
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc public func openSelected() {
        let r = table.selectedRow >= 0 ? table.selectedRow : 0
        guard results.indices.contains(r) else { return }
        onOpen?(results[r])
        close()
    }

    private func close() {
        if presentingViewController != nil { dismiss(nil) } else { onClose?() }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = results[row]
        let symbol = r.kind == .file ? "doc.text" : (r.symbolKind.map { NavigatorAreaController.symbolGlyph($0) } ?? "f.square.fill")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = r.kind == .file ? .secondaryLabelColor : r.symbolKind.map { NavigatorAreaController.symbolTint($0) }
        let title = NSTextField(labelWithString: r.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: r.line.map { "\(r.detail):\($0)" } ?? r.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [icon, text])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return stack
    }
}
