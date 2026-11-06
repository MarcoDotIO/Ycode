import AppKit
import YcodeIDECore

/// The Library (⇧⌘L). With a source file it has Snippets and Symbols tabs;
/// while an Interface Builder document is focused it has Objects, Image,
/// Color and Symbols (`library.md` §Reference Objects library ▸ Panel).
/// The panel follows the measured layout: 681 × 504 with the details
/// shown, 272 × 504 without (same centre); a filter icon and search field,
/// an icon/list toggle and a details toggle; the tabs; a flat list of
/// 48-point rows (or four 34-point icons to a row); and the detail area
/// (name, `Class: summary`, description). Double-click or Return inserts;
/// dragging carries the item.
@MainActor
public final class LibraryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public enum Tab: Int, CaseIterable { case snippets, symbols, objects, image, color }

    /// Panel sizes (`library.md` §Panel).
    public static let size = NSSize(width: 681, height: 504)
    public static let narrowWidth: CGFloat = 272

    /// Whether the Objects tab is offered (an Interface Builder document is focused).
    public var objectsAvailable = false {
        didSet {
            guard oldValue != objectsAvailable else { return }
            tab = objectsAvailable ? .objects : .snippets
            if isViewLoaded { configureTabs(); reload() }
        }
    }
    /// The kinds the focused document offers, in Library order.
    public private(set) var objectKinds: [IBDocument.NewObject] = IBDocument.NewObject.macList
    /// Whether they are UIKit kinds (the class names shown).
    public private(set) var objectsIOS = false

    /// Offers the Objects tab for a document (nil: no Interface Builder document).
    public func setObjects(for d: IBDocument?) {
        if let d {
            objectKinds = IBDocument.NewObject.list(for: d)
            objectsIOS = d.isFlippedRuntime
        }
        objectsAvailable = d != nil
        reload()
    }

    /// Called with the object to insert (double-click or Return on Objects).
    public var onInsertObject: ((IBDocument.NewObject) -> Void)?
    public private(set) var objects: [IBDocument.NewObject] = []

    public private(set) var tab: Tab = .snippets
    public var filter = "" { didSet { reload(); selectFirst() } }
    public private(set) var snippets: [LibrarySnippet] = []
    public private(set) var symbols: [String] = []
    public private(set) var colors: [String] = []
    /// Called with the text to insert (double-click or Return).
    public var onInsert: ((String) -> Void)?
    /// The list shows icons only, four to a row.
    public private(set) var isIconView = false
    /// The detail area is shown.
    public private(set) var showsDetails = true

    let filterIcon = NSImageView()
    let search = NSSearchField()
    let viewToggle = NSButton()
    let detailsToggle = NSButton()
    let tabs = NSSegmentedControl()
    let table = NSTableView()
    let listScroll = NSScrollView()
    let detailName = NSTextField(labelWithString: "")
    let detailSubtitle = NSTextField(labelWithString: "")
    let detailText = NSTextView()
    let detailScroll = NSScrollView()
    /// The selected item in the icon view (the table selects rows of four).
    public private(set) var iconSelection: Int?

    /// Symbol names the running system can draw.
    public static let availableSymbols: [String] = LibraryContent.symbolNames.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    /// The tabs shown, in order.
    public var visibleTabs: [Tab] { objectsAvailable ? [.objects, .image, .color, .symbols] : [.snippets, .symbols] }

    public override func loadView() {
        let root = FlippedPanelView(frame: NSRect(origin: .zero, size: Self.size))
        filterIcon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
        filterIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        filterIcon.contentTintColor = .secondaryLabelColor
        search.placeholderString = "Filter"
        search.delegate = self
        search.controlSize = .large
        for (b, action) in [(viewToggle, #selector(toggleIconView)), (detailsToggle, #selector(toggleDetails))] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.target = self
            b.action = action
        }
        configureTabs()
        tabs.target = self
        tabs.action = #selector(tabChosen)
        tabs.segmentStyle = .texturedSquare
        let col = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 48
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        detailName.font = .systemFont(ofSize: 15, weight: .semibold)
        detailName.lineBreakMode = .byTruncatingTail
        detailSubtitle.font = .systemFont(ofSize: 11)
        detailSubtitle.textColor = .secondaryLabelColor
        detailSubtitle.lineBreakMode = .byTruncatingTail
        detailText.isEditable = false
        detailText.drawsBackground = false
        detailText.font = .systemFont(ofSize: 12)
        detailScroll.documentView = detailText
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        for v in [filterIcon, search, viewToggle, detailsToggle, tabs, listScroll, detailName, detailSubtitle, detailScroll] as [NSView] { root.addSubview(v) }
        view = root
        preferredContentSize = Self.size
        layoutPanel()
        reload()
        selectFirst()
    }

    /// Places everything at the measured positions (y from the top).
    func layoutPanel() {
        let w = showsDetails ? Self.size.width : Self.narrowWidth
        view.setFrameSize(NSSize(width: w, height: Self.size.height))
        filterIcon.frame = NSRect(x: 15, y: 11, width: 34, height: 34)
        search.frame = NSRect(x: 61, y: 10, width: showsDetails ? 557 : 148, height: 36)
        let tx: CGFloat = showsDetails ? 616 : w - 65
        viewToggle.frame = NSRect(x: tx, y: 19, width: 18, height: 18)
        detailsToggle.frame = NSRect(x: tx + 28, y: 19, width: 18, height: 18)
        tabs.sizeToFit()
        let tw = CGFloat(tabs.segmentCount) * 42
        for i in 0..<tabs.segmentCount { tabs.setWidth(40, forSegment: i) }
        tabs.frame = NSRect(x: (w - tw) / 2, y: 61, width: tw, height: 25)
        listScroll.frame = NSRect(x: 0, y: 94, width: Self.narrowWidth, height: Self.size.height - 94)
        table.tableColumns.first?.width = 255
        for v in [detailName, detailSubtitle, detailScroll] as [NSView] { v.isHidden = !showsDetails }
        detailName.frame = NSRect(x: 282, y: 103, width: 390, height: 21)
        detailSubtitle.frame = NSRect(x: 282, y: 123, width: 390, height: 16)
        detailScroll.frame = NSRect(x: 278, y: 152, width: 381, height: 339)
        detailText.frame = NSRect(origin: .zero, size: detailScroll.contentSize)
        viewToggle.image = NSImage(systemSymbolName: isIconView ? "list.bullet" : "square.grid.2x2", accessibilityDescription: nil)
        viewToggle.toolTip = isIconView ? "Switch to List View" : "Switch to Icon View"
        detailsToggle.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        detailsToggle.toolTip = showsDetails ? "Hide Details" : "Show Details"
    }

    func configureTabs() {
        let list = visibleTabs
        tabs.segmentCount = list.count
        for (i, t) in list.enumerated() {
            let (title, symbol) = Self.tabInfo(t)
            tabs.setLabel("", forSegment: i)
            tabs.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: i)
            tabs.setToolTip(title, forSegment: i)
        }
        tabs.selectedSegment = list.firstIndex(of: tab) ?? 0
        if isViewLoaded { layoutPanel() }
    }

    static func tabInfo(_ t: Tab) -> (String, String) {
        switch t {
        case .snippets: ("Snippets", "curlybraces")
        case .symbols: ("Symbols", "star.square")
        case .objects: ("Objects", "square.on.circle")
        case .image: ("Image", "photo")
        case .color: ("Color", "paintpalette")
        }
    }

    public func select(tab t: Tab) {
        tab = t
        if isViewLoaded { tabs.selectedSegment = visibleTabs.firstIndex(of: t) ?? 0 }
        reload()
    }

    @objc private func tabChosen() {
        let list = visibleTabs
        select(tab: tabs.selectedSegment >= 0 && tabs.selectedSegment < list.count ? list[tabs.selectedSegment] : list[0])
    }

    /// The header's first toggle: icon view or list view.
    @objc public func toggleIconView() {
        isIconView.toggle()
        iconSelection = isIconView ? (table.selectedRow >= 0 ? table.selectedRow : nil) : nil
        layoutPanel()
        reload()
    }

    /// The header's second toggle: shows or hides the detail area; the
    /// panel keeps its horizontal centre.
    @objc public func toggleDetails() {
        let old = view.frame.width
        showsDetails.toggle()
        layoutPanel()
        if let w = view.window {
            var f = w.frame
            let dw = view.frame.width - old
            f.origin.x -= dw / 2
            f.size.width += dw
            w.setFrame(f, display: true)
        }
    }

    public func controlTextDidChange(_ obj: Notification) { filter = search.stringValue }

    func reload() {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        snippets = LibraryContent.snippets.filter {
            q.isEmpty || $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.language.lowercased().contains(q)
        }
        symbols = Self.availableSymbols.filter { q.isEmpty || $0.contains(q) }
        objects = IBDocument.NewObject.matching(filter, in: objectKinds, iOS: objectsIOS)
        colors = IBDocument.colorChoices.dropFirst().map(\.title).filter { q.isEmpty || $0.lowercased().contains(q) }
        guard isViewLoaded else { return }
        table.rowHeight = tab == .symbols ? 28 : 48
        table.reloadData()
        updateDetail()
    }

    /// Filtering selects the first match (`library.md` §Panel, Selection).
    func selectFirst() {
        guard isViewLoaded else { return }
        if isIconView && tab == .objects {
            iconSelection = objects.isEmpty ? nil : 0
            table.reloadData()
        } else if numberOfRows(in: table) > 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateDetail()
    }

    /// The text an item inserts: a snippet's body, or a symbol's name as a
    /// string literal.
    public func insertionText(row: Int) -> String? {
        switch tab {
        case .snippets: row < snippets.count ? snippets[row].body : nil
        case .symbols: row < symbols.count ? "\"\(symbols[row])\"" : nil
        case .objects, .image, .color: nil
        }
    }

    /// Inserts the item at `row` (what double-click does; in the icon view
    /// the item index).
    @discardableResult
    public func insert(row: Int) -> Bool {
        if tab == .objects {
            guard row >= 0, row < objects.count else { return false }
            onInsertObject?(objects[row])
            return true
        }
        guard let text = insertionText(row: row) else { return false }
        onInsert?(text)
        return true
    }

    /// The selected object (list or icon view).
    public var selectedObject: IBDocument.NewObject? {
        guard tab == .objects else { return nil }
        let i = isIconView ? iconSelection : (table.selectedRow >= 0 ? table.selectedRow : nil)
        return i.flatMap { $0 < objects.count ? objects[$0] : nil }
    }

    @objc private func doubleClicked() { if !isIconView, table.clickedRow >= 0 { insert(row: table.clickedRow) } }

    public override func keyDown(with e: NSEvent) {
        if e.keyCode == 36, let o = selectedObject, let i = objects.firstIndex(of: o) { insert(row: i); return }
        if e.keyCode == 36, table.selectedRow >= 0 { insert(row: table.selectedRow) } else { super.keyDown(with: e) }
    }

    /// The detail area: the selected item's name, subtitle and description.
    public var detail: (name: String, subtitle: String, description: String) {
        let r = table.selectedRow
        switch tab {
        case .snippets:
            guard r >= 0, r < snippets.count else { return ("", "", "") }
            return (snippets[r].title, "\(snippets[r].language): \(snippets[r].summary)", snippets[r].body)
        case .symbols:
            guard r >= 0, r < symbols.count else { return ("", "", "") }
            return (symbols[r], "Symbol", symbols[r])
        case .color:
            guard r >= 0, r < colors.count else { return ("", "", "") }
            return (colors[r], "Color", "")
        case .image: return ("", "", "")
        case .objects:
            guard let o = selectedObject else { return ("", "", "") }
            return (o.rawValue, o.subtitle(iOS: objectsIOS), o.details)
        }
    }

    func updateDetail() {
        let d = detail
        detailName.stringValue = d.name
        detailSubtitle.stringValue = d.subtitle
        detailText.string = d.description
    }

    // MARK: Table

    public func numberOfRows(in t: NSTableView) -> Int {
        switch tab {
        case .snippets: snippets.count
        case .symbols: symbols.count
        case .objects: isIconView ? (objects.count + 3) / 4 : objects.count
        case .color: colors.count
        case .image: 0
        }
    }

    public static func objectSummary(_ o: IBDocument.NewObject) -> String { o.summary }

    /// The Objects tab's icons, drawn by Ycode from the shared shapes
    /// (`IBLibraryObjects.swift`; no artwork files), 34 points.
    public static func objectIcon(_ o: IBDocument.NewObject) -> NSImage { IBIconDrawing.image(o.icon, size: 34) }

    public func tableViewSelectionDidChange(_ n: Notification) { updateDetail() }

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 255, height: t.rowHeight))
        if tab == .objects && isIconView {
            for k in 0..<4 {
                let i = row * 4 + k
                guard i < objects.count else { break }
                let v = LibraryIconCell(frame: NSRect(x: CGFloat(k) * 64, y: 0, width: k == 0 ? 63 : 64, height: 48))
                v.image = Self.objectIcon(objects[i])
                v.toolTip = objects[i].rawValue
                v.isSelected = iconSelection == i
                v.onClick = { [weak self] double in
                    guard let self else { return }
                    self.iconSelection = i
                    self.table.reloadData()
                    self.updateDetail()
                    if double { self.insert(row: i) }
                }
                cell.addSubview(v)
            }
            return cell
        }
        let image = NSImageView(frame: NSRect(x: 17, y: 7, width: 34, height: 34))
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        switch tab {
        case .snippets:
            image.image = NSImage(systemSymbolName: "curlybraces.square", accessibilityDescription: nil)
            title.stringValue = snippets[row].title
        case .symbols:
            image.image = NSImage(systemSymbolName: symbols[row], accessibilityDescription: symbols[row])
            image.frame = NSRect(x: 17, y: 2, width: 24, height: 24)
            title.stringValue = symbols[row]
        case .objects:
            image.image = Self.objectIcon(objects[row])
            title.stringValue = objects[row].rawValue
        case .color:
            image.image = InterfaceBuilderController.swatch(colors[row])
            title.stringValue = colors[row]
        case .image: break
        }
        image.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        title.frame = NSRect(x: 59, y: tab == .symbols ? 5 : 15, width: 180, height: 18)
        cell.addSubview(image)
        cell.addSubview(title)
        cell.textField = title
        return cell
    }

    /// Dragging a row carries its insertion text as a plain string, or the
    /// object's name for the canvas.
    public func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if tab == .objects {
            guard !isIconView, row < objects.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(objects[row].rawValue, forType: IBCanvasView.objectType)
            return item
        }
        return insertionText(row: row) as NSString?
    }
}

/// The Library panel's root: paints the panel background and is flipped,
/// so frames read from the top.
final class FlippedPanelView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard PanelBackgroundView.paints(in: window) else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// One icon of the Library's icon view (34 points, 7 from the cell top).
final class LibraryIconCell: NSView {
    var image: NSImage?
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: ((Bool) -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ r: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        image?.draw(in: NSRect(x: (bounds.width - 34) / 2, y: 7, width: 34, height: 34))
    }

    override func mouseDown(with e: NSEvent) { onClick?(e.clickCount >= 2) }
}
