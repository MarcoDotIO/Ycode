import AppKit

/// One template tile: the icon above the title; selected tiles get an
/// accent background (`specs/ide/reference-ui-3.md` §5.3).
@MainActor
final class TemplateTile: NSView {
    let entry: TemplateEntry
    var onClick: ((TemplateEntry) -> Void)?
    var onDoubleClick: ((TemplateEntry) -> Void)?
    var isSelected = false { didSet { needsDisplay = true; label.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor } }
    let label: NSTextField

    static let size = NSSize(width: 104, height: 92)

    init(entry: TemplateEntry) {
        self.entry = entry
        label = NSTextField(wrappingLabelWithString: entry.title)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let icon = NSImageView(image: NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = Self.size.width - 8
        for v in [icon, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width), heightAnchor.constraint(equalToConstant: Self.size.height),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8), icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.heightAnchor.constraint(equalToConstant: 40),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
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
    let scroll = NSScrollView()
    private let content = FlippedStack()
    private(set) var tiles: [TemplateTile] = []
    private(set) var headers: [NSTextField] = []
    var onSelect: ((TemplateEntry) -> Void)?
    var onChoose: ((TemplateEntry) -> Void)?
    /// The section header pinned at the top while scrolling: it shows the
    /// title of the section the top of the visible area is in.
    let stickyHeader = StickyHeaderView()

    init(top: NSView) {
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
                let t = TemplateTile(entry: e)
                t.isSelected = e == selected
                t.onClick = { [weak self] e in self?.onSelect?(e) }
                t.onDoubleClick = { [weak self] e in self?.onSelect?(e); self?.onChoose?(e) }
                return t
            }
            tiles += sectionTiles
            let rows = stride(from: 0, to: sectionTiles.count, by: Self.columns).map { i -> [NSView] in
                Array(sectionTiles[i..<min(i + Self.columns, sectionTiles.count)])
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 4
            grid.columnSpacing = 4
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
