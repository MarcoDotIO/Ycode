import AppKit
import YcodeIDECore

/// One template tile: the icon above the title; selected tiles get an
/// accent background (`specs/ide/reference-ui-3.md` §5.3).
@MainActor
final class TemplateTile: NSView {
    /// How a tile draws: `filled` (the New Project grid: accent glyphs, an
    /// accent tile when selected) or `outlined` (the New File grid, P-184:
    /// monochrome outline glyphs; selected, a grey tile and the name on an
    /// accent capsule).
    enum Style { case filled, outlined }

    let entry: TemplateEntry
    let style: Style
    var onClick: ((TemplateEntry) -> Void)?
    var onDoubleClick: ((TemplateEntry) -> Void)?
    var isSelected = false {
        didSet {
            needsDisplay = true
            label.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
            label.drawsBackground = style == .outlined && isSelected
        }
    }
    let label: NSTextField

    static let size = NSSize(width: 104, height: 92)
    /// The New File grid's wider tiles: five fill the sheet on a ≈ 134-point
    /// pitch (P-184; the reference's ≈ 137).
    static let outlinedSize = NSSize(width: 130, height: 92)
    static func size(_ style: Style) -> NSSize { style == .outlined ? outlinedSize : size }

    init(entry: TemplateEntry, style: Style = .filled) {
        self.entry = entry
        self.style = style
        label = NSTextField(wrappingLabelWithString: entry.title)
        let size = Self.size(style)
        super.init(frame: NSRect(origin: .zero, size: size))
        let icon = NSImageView(image: NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: style == .outlined ? .light : .regular)
        icon.contentTintColor = style == .outlined ? .secondaryLabelColor : .controlAccentColor
        if style == .outlined {
            label.backgroundColor = .controlAccentColor
            label.wantsLayer = true
            label.layer?.cornerRadius = 4
            label.layer?.masksToBounds = true
        }
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = size.width - 8
        for v in [icon, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8), icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.heightAnchor.constraint(equalToConstant: 40),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
        ])
        if style == .outlined {
            // The name's capsule hugs the text.
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8)])
        } else {
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                                         label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)])
        }
        // A button to accessibility: pressing it chooses the template, as a
        // click does (merge-sheet.md §13.2's rule for Ycode's drawn
        // controls in sheets).
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.title)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(entry)
        return true
    }

    override func isAccessibilitySelected() -> Bool { isSelected }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        (style == .outlined ? NSColor.unemphasizedSelectedContentBackgroundColor : NSColor.selectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onDoubleClick?(entry) } else { onClick?(entry) }
    }
}

/// The new-file sheet body: platform tabs and filter on top, then the
/// templates as an icon grid in sections (a bold header above each).
@MainActor
final class TemplateGridView: NSView {
    static let columns = 6
    /// Tiles per row (the New File grid has 5, P-184).
    let columns: Int
    let tileStyle: TemplateTile.Style
    let scroll = NSScrollView()
    private let content = FlippedStack()
    private(set) var tiles: [TemplateTile] = []
    private(set) var headers: [NSTextField] = []
    var onSelect: ((TemplateEntry) -> Void)?
    var onChoose: ((TemplateEntry) -> Void)?
    /// The section header pinned at the top while scrolling: it shows the
    /// title of the section the top of the visible area is in.
    let stickyHeader = StickyHeaderView()

    init(top: NSView, columns: Int = TemplateGridView.columns, tileStyle: TemplateTile.Style = .filled) {
        self.columns = columns
        self.tileStyle = tileStyle
        super.init(frame: .zero)
        stickyHeader.isHidden = true
        scroll.addFloatingSubview(stickyHeader, for: .vertical)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        for v in [top, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), top.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ sections: [TemplateSection], selected: TemplateEntry?) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []
        headers = []
        for s in sections where !s.entries.isEmpty {
            let h = NSTextField(labelWithString: s.title)
            h.font = .boldSystemFont(ofSize: 11)
            h.textColor = .secondaryLabelColor
            headers.append(h)
            content.addArrangedSubview(h)
            let sectionTiles = s.entries.map { e -> TemplateTile in
                let t = TemplateTile(entry: e, style: tileStyle)
                t.isSelected = e == selected
                t.onClick = { [weak self] e in self?.onSelect?(e) }
                t.onDoubleClick = { [weak self] e in self?.onSelect?(e); self?.onChoose?(e) }
                return t
            }
            tiles += sectionTiles
            let rows = stride(from: 0, to: sectionTiles.count, by: columns).map { i -> [NSView] in
                Array(sectionTiles[i..<min(i + columns, sectionTiles.count)])
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 4
            grid.columnSpacing = 4
            // Fixed columns: a short last row keeps the tiles' positions.
            for i in 0..<grid.numberOfColumns { grid.column(at: i).width = TemplateTile.size(tileStyle).width }
            content.addArrangedSubview(grid)
        }
        updateStickyHeader()
    }

    @objc private func clipScrolled(_ n: Notification) { updateStickyHeader() }

    /// Pins the header of the section at the top of the visible area. When
    /// the next header reaches the pinned one, it pushes it up.
    func updateStickyHeader() {
        content.layoutSubtreeIfNeeded()
        let top = scroll.contentView.bounds.minY
        let height = stickyHeader.fittingSize.height
        // Header y positions in the (flipped) document.
        let ys = headers.map { content.convert($0.frame, from: $0.superview).minY - 4 }
        guard let i = ys.lastIndex(where: { $0 <= top }), top > 0 else {
            stickyHeader.isHidden = true
            return
        }
        stickyHeader.label.stringValue = headers[i].stringValue
        var y: CGFloat = 0
        if i + 1 < ys.count { y = min(0, ys[i + 1] - top - height) }
        let clip = scroll.contentView
        stickyHeader.frame = NSRect(x: 0, y: clip.frame.minY + y, width: clip.frame.width, height: height)
        stickyHeader.isHidden = false
    }

    func highlight(_ entry: TemplateEntry?) {
        for t in tiles { t.isSelected = t.entry == entry }
    }
}

/// A stack view with a top-left origin, so a scroll view's document starts
/// at the top.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// The pinned section header: a bold label on the grid's background.
final class StickyHeaderView: NSView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        label.topAnchor.constraint(equalTo: topAnchor, constant: 4).isActive = true
        label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }
}
