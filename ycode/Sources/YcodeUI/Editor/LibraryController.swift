import AppKit

/// The Library (⇧⌘L): Snippets and Symbols tabs, a filter field, and a
/// list. Double-click inserts the item into the source editor; dragging
/// carries its text. See `specs/ide/library.md`.
@MainActor
public final class LibraryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public enum Tab: Int, CaseIterable { case snippets, symbols, objects }

    /// Whether the Objects tab is offered (an Interface Builder document is focused).
    public var objectsAvailable = false {
        didSet {
            guard oldValue != objectsAvailable else { return }
            if !objectsAvailable && tab == .objects { tab = .snippets }
            if isViewLoaded { configureTabs(); reload() }
        }
    }
    /// Called with the object to insert (double-click or Return on Objects).
    public var onInsertObject: ((IBDocument.NewObject) -> Void)?
    public private(set) var objects: [IBDocument.NewObject] = []

    public private(set) var tab: Tab = .snippets
    public var filter = "" { didSet { reload() } }
    public private(set) var snippets: [LibrarySnippet] = []
    public private(set) var symbols: [String] = []
    /// Called with the text to insert (double-click or Return).
    public var onInsert: ((String) -> Void)?

    let tabs = NSSegmentedControl()
    let search = NSSearchField()
    let table = NSTableView()
    let detail = NSTextField(wrappingLabelWithString: "")

    /// Symbol names the running system can draw.
    public static let availableSymbols: [String] = LibraryContent.symbolNames.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
        configureTabs()
        tabs.target = self
        tabs.action = #selector(tabChosen)
        search.placeholderString = "Filter"
        search.delegate = self
        let col = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        detail.font = Theme.font
        detail.textColor = .secondaryLabelColor
        for v in [tabs, search, scroll, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            search.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        view = root
        reload()
    }

    func configureTabs() {
        let list: [(String, String)] = [("Snippets", "curlybraces"), ("Symbols", "star.square")] + (objectsAvailable ? [("Objects", "square.on.circle")] : [])
        tabs.segmentCount = list.count
        for (i, (t, s)) in list.enumerated() {
            tabs.setLabel(t, forSegment: i)
            tabs.setImage(NSImage(systemSymbolName: s, accessibilityDescription: t), forSegment: i)
        }
        tabs.selectedSegment = tab.rawValue
    }

    public func select(tab t: Tab) {
        tab = t
        if isViewLoaded { tabs.selectedSegment = t.rawValue }
        reload()
    }

    @objc private func tabChosen() { select(tab: Tab(rawValue: tabs.selectedSegment) ?? .snippets) }

    public func controlTextDidChange(_ obj: Notification) { filter = search.stringValue }

    func reload() {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        snippets = LibraryContent.snippets.filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.language.lowercased().contains(q)
        }
        symbols = Self.availableSymbols.filter { q.isEmpty || $0.contains(q) }
        objects = IBDocument.NewObject.allCases.filter { q.isEmpty || $0.rawValue.lowercased().contains(q) }
        guard isViewLoaded else { return }
        table.rowHeight = tab == .symbols ? 28 : 40
        table.reloadData()
        updateDetail()
    }

    /// The text an item inserts: a snippet's body, or a symbol's name as a
    /// string literal.
    public func insertionText(row: Int) -> String? {
        switch tab {
        case .snippets: row < snippets.count ? snippets[row].body : nil
        case .symbols: row < symbols.count ? "\"\(symbols[row])\"" : nil
        case .objects: nil
        }
    }

    /// Inserts the item at `row` (what double-click does).
    @discardableResult
    public func insert(row: Int) -> Bool {
        if tab == .objects {
            guard row < objects.count else { return false }
            onInsertObject?(objects[row])
            return true
        }
        guard let text = insertionText(row: row) else { return false }
        onInsert?(text)
        return true
    }

    @objc private func doubleClicked() { if table.clickedRow >= 0 { insert(row: table.clickedRow) } }

    public override func keyDown(with e: NSEvent) {
        if e.keyCode == 36, table.selectedRow >= 0 { insert(row: table.selectedRow) } else { super.keyDown(with: e) }
    }

    func updateDetail() {
        let r = table.selectedRow
        switch tab {
        case .snippets: detail.stringValue = r >= 0 && r < snippets.count ? snippets[r].body : ""
        case .symbols: detail.stringValue = r >= 0 && r < symbols.count ? symbols[r] : ""
        case .objects: detail.stringValue = r >= 0 && r < objects.count ? Self.objectSummary(objects[r]) : ""
        }
    }

    // MARK: Table

    public func numberOfRows(in t: NSTableView) -> Int {
        switch tab { case .snippets: snippets.count; case .symbols: symbols.count; case .objects: objects.count }
    }

    public static func objectSummary(_ o: IBDocument.NewObject) -> String {
        switch o {
        case .label: "Displays a line of read-only text."
        case .button: "Sends an action when clicked."
        case .textField: "Lets the user type a line of text."
        case .imageView: "Displays an image."
        case .view: "A plain rectangular area that holds other views."
        case .stackView: "Arranges its views in a row or column."
        }
    }

    /// The Objects tab's icons, drawn by Ycode (no artwork files).
    public static func objectIcon(_ o: IBDocument.NewObject) -> NSImage {
        NSImage(size: NSSize(width: 26, height: 26), flipped: true) { r in
            let box = r.insetBy(dx: 2, dy: 2)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            NSColor.controlAccentColor.setStroke()
            NSColor.controlAccentColor.setFill()
            switch o {
            case .label:
                NSAttributedString(string: "Aa", attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.controlAccentColor])
                    .draw(at: NSPoint(x: box.minX + 3, y: box.minY + 4))
            case .button:
                NSBezierPath(roundedRect: box.insetBy(dx: 2, dy: 6), xRadius: 4, yRadius: 4).fill()
            case .textField:
                NSBezierPath(rect: box.insetBy(dx: 2, dy: 6)).stroke()
                NSBezierPath(rect: CGRect(x: box.minX + 5, y: box.midY - 3, width: 1, height: 6)).fill()
            case .imageView:
                let m = NSBezierPath()
                m.move(to: CGPoint(x: box.minX + 3, y: box.maxY - 4))
                m.line(to: CGPoint(x: box.midX - 2, y: box.midY))
                m.line(to: CGPoint(x: box.maxX - 3, y: box.maxY - 4))
                m.close()
                m.fill()
                NSBezierPath(ovalIn: CGRect(x: box.maxX - 8, y: box.minY + 3, width: 4, height: 4)).fill()
            case .view:
                NSBezierPath(rect: box.insetBy(dx: 4, dy: 4)).stroke()
            case .stackView:
                for i in 0..<3 { NSBezierPath(rect: CGRect(x: box.minX + 3 + CGFloat(i) * 6.5, y: box.minY + 5, width: 5, height: box.height - 10)).fill() }
            }
            return true
        }
    }

    public func tableViewSelectionDidChange(_ n: Notification) { updateDetail() }

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let image = NSImageView()
        let title = NSTextField(labelWithString: "")
        let sub = NSTextField(labelWithString: "")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        switch tab {
        case .snippets:
            let s = snippets[row]
            image.image = NSImage(systemSymbolName: "curlybraces.square", accessibilityDescription: nil)
            title.stringValue = s.title
            title.font = .boldSystemFont(ofSize: 12)
            sub.stringValue = "\(s.summary) · \(s.language)"
        case .symbols:
            image.image = NSImage(systemSymbolName: symbols[row], accessibilityDescription: symbols[row])
            title.stringValue = symbols[row]
        case .objects:
            image.image = Self.objectIcon(objects[row])
            title.stringValue = objects[row].rawValue
            title.font = .boldSystemFont(ofSize: 12)
            sub.stringValue = Self.objectSummary(objects[row])
        }
        image.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        let texts = NSStackView(views: tab == .symbols ? [title] : [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [image, texts])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 26).isActive = true
        cell.addSubview(row)
        cell.textField = title
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                                     row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                                     row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    /// Dragging a row carries its insertion text as a plain string.
    public func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if tab == .objects {
            guard row < objects.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(objects[row].rawValue, forType: IBCanvasView.objectType)
            return item
        }
        return insertionText(row: row) as NSString?
    }
}
