import AppKit

/// Building blocks of the project editor's tabs (reference-ui-3.md §1):
/// collapsible sections with a disclosure triangle, and small tables with
/// column headers, an empty text and +/− buttons.
@MainActor
final class CollapsibleSection: NSStackView {
    let title: String
    let disclosure: NSButton
    let body: NSView
    var onToggle: ((Bool) -> Void)?

    init(title: String, body: NSView, collapsed: Bool, accessory: [NSView] = []) {
        self.title = title
        self.body = body
        disclosure = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = collapsed ? .off : .on
        disclosure.target = self
        disclosure.action = #selector(toggled)
        disclosure.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        let header = NSStackView(views: [disclosure, label] + accessory)
        header.spacing = 4
        orientation = .vertical
        alignment = .leading
        spacing = 6
        addArrangedSubview(header)
        addArrangedSubview(body)
        body.isHidden = collapsed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isCollapsed: Bool { body.isHidden }

    @objc private func toggled() {
        body.isHidden = disclosure.state == .off
        onToggle?(body.isHidden)
    }

    /// Collapses or expands as a click on the triangle would.
    func setCollapsed(_ c: Bool) {
        disclosure.state = c ? .off : .on
        toggled()
    }
}

/// A fixed-height table of prebuilt cell views.
@MainActor
final class StaticTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let columns: [String]
    var rows: [[NSView]]
    let container = NSStackView()
    let emptyLabel: NSTextField?
    var plusButton: NSButton?
    var minusButton: NSButton?
    /// Owner object ID (a build phase) and per-row object IDs.
    var identifier: String?
    var itemIDs: [String] = []

    init(columns: [String], rows: [[NSView]], emptyText: String? = nil, plusMinus: (target: AnyObject, plus: Selector?, minus: Selector?)? = nil,
         width: CGFloat = 520, rowHeight: CGFloat = 22) {
        self.columns = columns
        self.rows = rows
        emptyLabel = emptyText.map { NSTextField(labelWithString: $0) }
        super.init()
        for (i, c) in columns.enumerated() {
            let col = NSTableColumn(identifier: .init("c\(i)"))
            col.title = c
            col.width = width / CGFloat(max(columns.count, 1)) - 4
            table.addTableColumn(col)
        }
        table.rowHeight = rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let header = max(table.headerView?.frame.height ?? 0, 24)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: header + CGFloat(max(rows.count, 2)) * (rowHeight + 2) + 4),
        ])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2
        // The scroll view tiles its own subviews, so the placeholder lives
        // in a wrapper on top of it rather than inside it.
        let frame = NSView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: frame.topAnchor), scroll.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: frame.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
        ])
        container.addArrangedSubview(frame)
        if let e = emptyLabel, rows.isEmpty {
            e.textColor = .tertiaryLabelColor
            e.alignment = .center
            e.translatesAutoresizingMaskIntoConstraints = false
            // The placeholder sits in the table body: the area below the
            // column header, centered both ways. A guide spans that body.
            frame.addSubview(e)
            let body = NSLayoutGuide()
            frame.addLayoutGuide(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: scroll.topAnchor, constant: header),
                body.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
                body.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
                e.centerXAnchor.constraint(equalTo: body.centerXAnchor),
                e.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                e.topAnchor.constraint(greaterThanOrEqualTo: body.topAnchor),
            ])
        }
        if let pm = plusMinus {
            let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: pm.target, action: pm.plus)
            let minus = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: pm.target, action: pm.minus)
            plusButton = plus
            minusButton = minus
            for b in [plus, minus] { b.bezelStyle = .smallSquare; b.isEnabled = (b === plus ? pm.plus : pm.minus) != nil }
            container.addArrangedSubview(NSStackView(views: [plus, minus]))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        guard let c, let i = tableView.tableColumns.firstIndex(of: c), i < rows[row].count else { return nil }
        return rows[row][i]
    }

    /// Text of every cell (tests).
    var texts: [[String]] {
        rows.map { $0.map { v in
            if let f = v as? NSTextField { return f.stringValue }
            if let p = v as? NSPopUpButton { return p.titleOfSelectedItem ?? "" }
            if let b = v as? NSButton { return b.title }
            return ""
        } }
    }
}

extension NSTextField {
    static func cell(_ s: String, font: NSFont = .systemFont(ofSize: 12)) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = font
        f.lineBreakMode = .byTruncatingMiddle
        return f
    }
}
