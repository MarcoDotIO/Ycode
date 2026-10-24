import AppKit

/// A template sheet: a list of choices, fields, Cancel and Create. Used for
/// New File and New Project. See `specs/ide/templates.md`.
@MainActor
public final class TemplateSheetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let titles: [String]
    public let fieldLabels: [String]
    public private(set) var fields: [NSTextField] = []
    private let table = NSTableView()
    private let heading: String
    private let initialValues: [String]
    /// (selected template index, field values) → error text or nil.
    public var onCreate: ((Int, [String]) -> String?)?
    public let errorLabel = NSTextField(labelWithString: "")

    public init(heading: String, titles: [String], fields: [(String, String)]) {
        self.heading = heading
        self.titles = titles
        fieldLabels = fields.map(\.0)
        initialValues = fields.map(\.1)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var selectedIndex: Int { max(0, table.selectedRow) }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: 13)
        let col = NSTableColumn(identifier: .init("t"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        let grid = NSGridView(views: zip(fieldLabels, initialValues).map { label, value in
            let l = NSTextField(labelWithString: label + ":")
            let f = NSTextField(string: value)
            f.widthAnchor.constraint(equalToConstant: 300).isActive = true
            fields.append(f)
            return [l, f]
        })
        // A grid without rows has no columns (and would raise).
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
        grid.rowSpacing = 8
        errorLabel.textColor = .systemRed
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: "Create", target: self, action: #selector(createClicked))
        create.keyEquivalent = "\r"
        for v in [title, scroll, grid, errorLabel, cancel, create] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 160),
            grid.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            errorLabel.centerYAnchor.constraint(equalTo: create.centerYAnchor),
            create.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            create.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: create.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: create.bottomAnchor),
        ])
        view = root
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    public func select(_ index: Int) {
        _ = view
        table.selectRowIndexes([index], byExtendingSelection: false)
    }

    /// Runs Create; returns whether it succeeded.
    @discardableResult
    @objc public func createClicked() -> Bool {
        _ = view
        if let error = onCreate?(selectedIndex, fields.map(\.stringValue)) {
            errorLabel.stringValue = error
            return false
        }
        if presentingViewController != nil { dismiss(nil) }
        return true
    }

    @objc private func cancel(_ sender: Any?) { if presentingViewController != nil { dismiss(nil) } }

    public func numberOfRows(in tableView: NSTableView) -> Int { titles.count }
    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: titles[row])
    }
}
