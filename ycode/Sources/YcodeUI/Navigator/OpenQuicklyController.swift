import AppKit
import YcodeIDECore

/// Open Quickly (⇧⌘O): a search field over a list of matching files and
/// symbols; Return opens the selected one. See `specs/ide/open-quickly.md`.
/// Its layout and colours are `OpenQuicklyLayout`'s (council round 9, row
/// 215): a 640-point panel; a field with no border, focus ring or clear
/// button after a 21-point magnifier; a separator inset 20; 620 × 56 rows
/// with a 22-point radius, #0064E1 / #0059D1 when selected, a file's glyph,
/// its name (the extension dimmed) and under it the project's glyph and
/// its group path. The Linux IDE's panel is `ycode-ide/OpenQuicklyPanel.swift`.
@MainActor
public final class OpenQuicklyController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    typealias L = OpenQuicklyLayout
    public let field = OpenQuicklyField()
    let table = NSTableView()
    let magnifier = NSImageView()
    let separator = OpenQuicklySeparator()
    let scroll = NSScrollView()
    private var candidates: [FuzzyMatch.Candidate]
    public private(set) var results: [FuzzyMatch.Candidate] = []
    public var onOpen: ((FuzzyMatch.Candidate) -> Void)?
    /// Closes the panel when the controller is not presented as a sheet
    /// (the glass panel of `liquid-glass-ycode.md` §7).
    public var onClose: (() -> Void)?
    /// The panel's height changed with the results (its top stays put).
    var onResize: ((CGFloat) -> Void)?

    public init(candidates: [FuzzyMatch.Candidate]) {
        self.candidates = candidates
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The panel's height for the current results.
    public var panelHeight: CGFloat { CGFloat(L.height(results: results.count)) }

    public override func loadView() {
        let root = OpenQuicklyRootView(frame: NSRect(x: 0, y: 0, width: L.width, height: L.height(results: 0)))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.imageScaling = .scaleProportionallyUpOrDown
        magnifier.contentTintColor = Self.color { L.magnifier(dark: $0) }
        magnifier.setAccessibilityElement(false)
        field.placeholderString = L.placeholder
        field.font = .systemFont(ofSize: CGFloat(L.queryFontSize))
        field.textColor = Self.color { L.query(dark: $0) }
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged)
        field.setAccessibilityLabel(L.placeholder)
        let col = NSTableColumn(identifier: .init("r"))
        col.width = CGFloat(L.rowWidth)
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = CGFloat(L.rowHeight)
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        for v in [magnifier, field, separator, scroll] as [NSView] { root.addSubview(v) }
        root.controller = self
        view = root
        layoutParts()
    }

    /// Places the parts in the panel (flipped: y from the top).
    func layoutParts() {
        let w = view.bounds.width
        let band = CGFloat(L.headerHeight)
        let m = CGFloat(L.magnifierSize)
        magnifier.frame = NSRect(x: CGFloat(L.magnifierX), y: (band - m) / 2, width: m, height: m)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        // The text's ink starts at the field's frame plus its cell's inset
        // and the face's leading bearing.
        let x = CGFloat(L.queryX) - OpenQuicklyField.textInset - OpenQuicklyField.bearing
        field.frame = NSRect(x: x, y: ((band - fieldHeight) / 2).rounded(), width: w - x - CGFloat(L.separatorInset), height: fieldHeight)
        separator.frame = NSRect(x: CGFloat(L.separatorInset), y: band, width: w - 2 * CGFloat(L.separatorInset), height: CGFloat(L.separatorHeight))
        separator.isHidden = results.isEmpty
        let rows = CGFloat(min(results.count, L.maximumVisibleRows)) * CGFloat(L.rowHeight)
        scroll.frame = NSRect(x: CGFloat(L.rowInset), y: CGFloat(L.rowsTop), width: CGFloat(L.rowWidth), height: rows)
        scroll.isHidden = results.isEmpty
    }

    /// A colour from a light/dark pair of 0xRRGGBB.
    static func color(_ hex: @escaping @Sendable (Bool) -> UInt32) -> NSColor {
        NSColor(name: nil) { a in
            let v = hex(a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    /// New candidates (a fresh workspace index): the search runs again.
    public func update(candidates: [FuzzyMatch.Candidate]) {
        self.candidates = candidates
        if isViewLoaded { search(field.stringValue) }
    }

    /// Runs a query as typing would.
    public func search(_ q: String) {
        _ = view
        if field.stringValue != q { field.stringValue = q }
        results = q.trimmingCharacters(in: .whitespaces).isEmpty ? [] : FuzzyMatch.search(q, in: candidates)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        resizeForResults()
    }

    /// The panel follows its results' height, its top in place.
    func resizeForResults() {
        let h = panelHeight
        if view.frame.height != h {
            if let onResize { onResize(h) } else { view.setFrameSize(NSSize(width: view.frame.width, height: h)) }
        }
        layoutParts()
    }

    @objc private func searchChanged() { search(field.stringValue) }
    public func controlTextDidChange(_ obj: Notification) { search(field.stringValue) }

    /// Up/Down move the selection; Return opens; Escape closes.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
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

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { OpenQuicklyRowView() }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: OpenQuicklyCell.id, owner: nil) as? OpenQuicklyCell) ?? OpenQuicklyCell()
        cell.show(results[row])
        return cell
    }

    /// The row views (tests).
    var rowCells: [OpenQuicklyCell] {
        (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? OpenQuicklyCell }
    }
}

/// The panel's root: flipped, so the parts are placed from the top.
final class OpenQuicklyRootView: NSView {
    weak var controller: OpenQuicklyController?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A sheet (before macOS 26) has no glass: the window's background.
        guard PanelBackgroundView.paints(in: window) else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        controller?.layoutParts()
    }
}

/// The query field: no border, bezel, background, focus ring or clear button.
public final class OpenQuicklyField: NSTextField {
    /// From the field's frame to its text's first ink (the cell's inset).
    static let textInset: CGFloat = 2
    /// The 22-point face's typical leading bearing before a letter's ink.
    static let bearing: CGFloat = 1.5

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The 1-point line under the field.
final class OpenQuicklySeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OpenQuicklyController.color { OpenQuicklyLayout.separator(dark: $0) }.setFill()
        bounds.fill()
    }
}

/// A result row: the selection is a rounded fill (radius 22) in the
/// reference's blue, drawn whether or not the list has the keyboard (the
/// field keeps it), so the row's text turns white.
final class OpenQuicklyRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        OpenQuicklyController.color { OpenQuicklyLayout.selection(dark: $0) }.setFill()
        let r = CGFloat(OpenQuicklyLayout.rowCornerRadius)
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }
}

/// A result's content: the glyph in its 24.5 × 20.5 box, the name with its
/// extension dimmed, and under it the project's glyph and the group path
/// (a symbol: its file and line).
final class OpenQuicklyCell: NSTableCellView {
    typealias L = OpenQuicklyLayout
    static let id = NSUserInterfaceItemIdentifier("openQuicklyRow")
    /// The result's glyph: a file's navigator glyph in its tint, white on
    /// the selected row (`FileGlyphIconView`, row 211); a symbol's kind.
    let glyph = FileGlyphIconView()
    let name = NSTextField(labelWithString: "")
    let projectGlyph = NSImageView()
    let detail = NSTextField(labelWithString: "")
    /// A file's group path, drawn with the thin chevrons (round 10, row 242).
    let breadcrumb = OpenQuicklyBreadcrumbView()
    private(set) var candidate: FuzzyMatch.Candidate?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: L.rowWidth, height: L.rowHeight))
        identifier = Self.id
        glyph.imageScaling = .scaleProportionallyUpOrDown
        projectGlyph.imageScaling = .scaleProportionallyUpOrDown
        name.font = .boldSystemFont(ofSize: CGFloat(L.nameFontSize))
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: CGFloat(L.breadcrumbFontSize))
        detail.lineBreakMode = .byTruncatingMiddle
        for v in [glyph, name, projectGlyph, detail, breadcrumb] { addSubview(v) }
        textField = name
        imageView = glyph
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var isSelectedRow: Bool { backgroundStyle == .emphasized }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { if oldValue != backgroundStyle { restyle() } } }

    func show(_ c: FuzzyMatch.Candidate) {
        candidate = c
        restyle()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let g = L.glyphSize
        glyph.frame = NSRect(x: CGFloat(L.glyphX), y: (bounds.height - CGFloat(g.height)) / 2, width: CGFloat(g.width), height: CGFloat(g.height))
        // Row 242: the name's baseline 23 below the row's top, the second
        // line's 44.5; the project glyph 12 × 12 4 before the path.
        let nameH = ceil(name.intrinsicContentSize.height), detailH = ceil(detail.intrinsicContentSize.height)
        // The labels' text starts 2 inside their frames.
        let x = CGFloat(L.nameX) - 2
        name.frame = NSRect(x: x, y: CGFloat(L.nameBaseline) - Self.baselineOffset(name), width: bounds.width - x - 12, height: nameH)
        let b = CGFloat(L.breadcrumbGlyphSize)
        projectGlyph.frame = NSRect(x: CGFloat(L.nameX), y: CGFloat(L.breadcrumbGlyphCenter) - b / 2, width: b, height: b)
        let dx = projectGlyph.isHidden ? x : CGFloat(L.nameX) + b + CGFloat(L.breadcrumbGap) - 2
        detail.frame = NSRect(x: dx, y: CGFloat(L.breadcrumbBaseline) - Self.baselineOffset(detail), width: bounds.width - dx - 12, height: detailH)
        breadcrumb.frame = NSRect(x: dx + 2, y: 0, width: max(0, bounds.width - dx - 14), height: bounds.height)
    }

    /// From a label's frame top to its first baseline.
    static func baselineOffset(_ l: NSTextField) -> CGFloat { l.firstBaselineOffsetFromTop }

    /// Colours and content for the row's state (white on the selection).
    func restyle() {
        guard let c = candidate else { return }
        let selected = isSelectedRow
        let ink: NSColor = selected ? .white : .labelColor
        let dim: NSColor = selected ? NSColor.white.withAlphaComponent(CGFloat(L.selectedExtensionOpacity)) : .secondaryLabelColor
        let font = name.font ?? .systemFont(ofSize: CGFloat(L.nameFontSize))
        let (base, ext) = c.kind == .file ? L.splitExtension(c.title) : (c.title, "")
        let text = NSMutableAttributedString(string: base, attributes: [.font: font, .foregroundColor: ink])
        text.append(NSAttributedString(string: ext, attributes: [.font: font, .foregroundColor: dim]))
        name.attributedStringValue = text
        detail.textColor = selected ? .white : .secondaryLabelColor
        breadcrumb.color = detail.textColor ?? .secondaryLabelColor
        if c.kind == .file {
            glyph.show(fileName: c.title, box: FileGlyphs.openQuicklyBox)
        } else {
            glyph.image = OpenQuicklyGlyphs.image(for: c)
            glyph.imageScaling = .scaleProportionallyUpOrDown
            glyph.tint = OpenQuicklyGlyphs.tint(for: c, selected: false)
        }
        glyph.isOnSelection = selected
        if c.kind == .file, !c.groupPath.isEmpty {
            detail.stringValue = L.breadcrumb(c.groupPath)
            breadcrumb.groups = c.groupPath
            projectGlyph.image = OpenQuicklyGlyphs.projectImage()
            projectGlyph.isHidden = false
        } else {
            detail.stringValue = c.line.map { "\(c.detail):\($0)" } ?? c.detail
            breadcrumb.groups = []
            projectGlyph.isHidden = true
        }
        // The path's text is drawn by the breadcrumb view (its chevrons are
        // not a character); the label keeps the text for the other kinds.
        detail.alphaValue = breadcrumb.groups.isEmpty ? 1 : 0
        setAccessibilityLabel(c.title)
    }
}

/// A file result's group path (council round 10, row 242): each group in
/// 15-point type on the row's breadcrumb baseline, a thin tall chevron 3 ×
/// 14 with 7 of space at each side between two (`OpenQuicklyLayout`).
final class OpenQuicklyBreadcrumbView: NSView {
    typealias L = OpenQuicklyLayout
    var groups: [String] = [] { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    static let font = NSFont.systemFont(ofSize: CGFloat(OpenQuicklyLayout.breadcrumbFontSize))

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Each group's and chevron's x in the view.
    var layout: (groups: [Double], chevrons: [Double]) {
        L.breadcrumbLayout(widths: groups.map { Double(($0 as NSString).size(withAttributes: [.font: Self.font]).width) })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !groups.isEmpty else { return }
        let (xs, chevrons) = layout
        let f = Self.font
        for (g, x) in zip(groups, xs) {
            // The baseline 44.5 below the row's top (the view's top).
            NSAttributedString(string: g, attributes: [.font: f, .foregroundColor: color])
                .draw(at: NSPoint(x: CGFloat(x), y: CGFloat(L.breadcrumbBaseline) - f.ascender))
        }
        let w = CGFloat(L.breadcrumbChevronWidth), h = CGFloat(L.breadcrumbChevronHeight), s = CGFloat(L.breadcrumbChevronStroke)
        let mid = CGFloat(L.breadcrumbChevronCenter)
        color.setStroke()
        for x in chevrons {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: CGFloat(x) + s / 2, y: mid - (h - s) / 2))
            p.line(to: NSPoint(x: CGFloat(x) + w - s / 2, y: mid))
            p.line(to: NSPoint(x: CGFloat(x) + s / 2, y: mid + (h - s) / 2))
            p.lineWidth = s
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
    }
}

/// The glyphs Open Quickly shows (council round 9, row 211; group A1's
/// vector glyphs, `FileGlyphs`): a file's navigator glyph fitted to the
/// 24.5 × 20.5 box, a symbol's kind, the project's mark on the second line.
@MainActor
enum OpenQuicklyGlyphs {
    static func image(for c: FuzzyMatch.Candidate) -> NSImage? {
        if c.kind == .symbol {
            let s = c.symbolKind.map { NavigatorAreaController.symbolGlyph($0) } ?? "f.square.fill"
            return NSImage(systemSymbolName: s, accessibilityDescription: nil)
        }
        if let g = NavigatorRowImages.fileGlyph(c.title, box: FileGlyphs.openQuicklyBox) { return g.image }
        return NSImage(systemSymbolName: WorkspaceChrome.symbol(kind: .file, name: c.title, path: c.path), accessibilityDescription: nil)
    }

    /// A glyph's tint: white on the selection; else a symbol's kind's, a
    /// file's type tint (`OpenQuicklyLayout.fileGlyphColor`), or for a file
    /// shown with a symbol the secondary label colour.
    static func tint(for c: FuzzyMatch.Candidate, selected: Bool) -> NSColor? {
        if selected { return .white }
        if c.kind == .symbol { return c.symbolKind.map { NavigatorAreaController.symbolTint($0) } }
        guard OpenQuicklyLayout.fileGlyph(c.title) != nil else { return .secondaryLabelColor }
        return OpenQuicklyLayout.fileGlyphColor(c.title, selected: false).map(NavigatorRowImages.color) ?? .controlAccentColor
    }

    static func projectImage() -> NSImage? { NavigatorRowImages.image(.ycodeMark) }
}
