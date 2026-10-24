import AppKit

/// The editor with no document (`specs/ide/reference-ui-4.md` §9): an Open
/// Quickly field, a "Recent Files" heading and the recent files (icon, name
/// without extension, folder breadcrumb). Clicking a row opens it; typing
/// in the field searches like Open Quickly.
@MainActor
public final class EmptyEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public struct Row: Equatable {
        public var path: String
        public var name: String
        public var breadcrumb: String
        public var line: Int?
    }

    public let field = NSSearchField()
    public let heading = NSTextField(labelWithString: "Recent Files")
    let table = NSTableView()
    public private(set) var rows: [Row] = []
    var recent: [String] = []
    var candidates: [FuzzyMatch.Candidate] = []
    var root: String = ""
    var onOpen: ((String, Int?) -> Void)?

    /// A row for a path: the name without extension and the folder path
    /// relative to `root`, joined with " › ".
    public static func row(path: String, root: String, line: Int? = nil) -> Row {
        let url = URL(fileURLWithPath: path)
        var folder = url.deletingLastPathComponent().path
        if !root.isEmpty, folder.hasPrefix(root) {
            folder = String(folder.dropFirst(root.count))
        }
        let crumbs = folder.split(separator: "/").map(String.init)
        return Row(path: path, name: url.deletingPathExtension().lastPathComponent, breadcrumb: crumbs.joined(separator: " › "), line: line)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        field.placeholderString = "Open Quickly"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        heading.font = .boldSystemFont(ofSize: 13)
        heading.textColor = .secondaryLabelColor
        table.addTableColumn(NSTableColumn(identifier: .init("r")))
        table.headerView = nil
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        for v in [field, heading, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 60),
            field.centerXAnchor.constraint(equalTo: centerXAnchor),
            field.widthAnchor.constraint(equalToConstant: 420),
            heading.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Recent files, most recent first.
    func configure(recent: [String], candidates: [FuzzyMatch.Candidate], root: String) {
        self.recent = recent
        self.candidates = candidates
        self.root = root
        search(field.stringValue)
    }

    /// Typing: an empty query lists Recent Files; otherwise Open Quickly
    /// matches (the heading reads as the results).
    public func search(_ q: String) {
        field.stringValue = q
        if q.isEmpty {
            heading.stringValue = "Recent Files"
            rows = recent.map { Self.row(path: $0, root: root) }
        } else {
            heading.stringValue = "Open Quickly"
            rows = FuzzyMatch.search(q, in: candidates).map { c in
                var r = Self.row(path: c.path, root: root, line: c.line)
                if c.kind == .symbol { r.name = c.title; r.breadcrumb += " › " + c.detail }
                return r
            }
        }
        table.reloadData()
    }

    public func controlTextDidChange(_ obj: Notification) { search(field.stringValue) }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { open(row: max(0, table.selectedRow)); return true }
        return false
    }

    @objc func clicked() { if table.clickedRow >= 0 { open(row: table.clickedRow) } }

    /// Opens a row (a click).
    public func open(row: Int) {
        guard rows.indices.contains(row) else { return }
        onOpen?(rows[row].path, rows[row].line)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: r.path))
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let name = NSTextField(labelWithString: r.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let crumb = NSTextField(labelWithString: r.breadcrumb)
        crumb.font = .systemFont(ofSize: 10)
        crumb.textColor = .secondaryLabelColor
        crumb.lineBreakMode = .byTruncatingHead
        let text = NSStackView(views: [name, crumb])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let s = NSStackView(views: [icon, text])
        s.spacing = 8
        return s
    }
}

extension SourceEditorController {
    /// Shows the empty-editor view over the text (no document open),
    /// below the jump bar, which reads "No Selection" (`reference-ui-5.md`
    /// §3.5, L8).
    public func showEmptyState(recent: [String], candidates: [FuzzyMatch.Candidate], root: String, onOpen: @escaping (String, Int?) -> Void) {
        _ = view
        let v = emptyView ?? EmptyEditorView()
        v.onOpen = onOpen
        v.configure(recent: recent, candidates: candidates, root: root)
        if v.superview == nil {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: jumpBar.bottomAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        emptyHolder.view = v
    }

    public func hideEmptyState() {
        emptyHolder.view?.removeFromSuperview()
        emptyHolder.view = nil
    }

    public var emptyView: EmptyEditorView? { emptyHolder.view }
}

/// Holds the empty view (an extension cannot add stored properties).
@MainActor final class EmptyStateHolder { var view: EmptyEditorView? }
