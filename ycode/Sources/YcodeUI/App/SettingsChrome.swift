import AppKit
import YcodeIDECore

// The Settings window's chrome and its grouped-card form
// (`specs/ide/settings.md`, "Council round 3", R3.1–R3.3, and round 4,
// R4.1–R4.3): the window's
// metrics and colours, the back/forward capsule, the sidebar's rows, and the
// cards, rows, separators, help text, pop-ups and switches of the panes.
// Everything is drawn by Ycode (paths and fills); the sidebar's symbols are
// the system's, looked up at run time.

/// The measured geometry, shared with the Linux IDE (`SettingsLayout`).
public typealias SettingsMetrics = SettingsLayout

/// The colours (light as measured in round 3, dark in round 4).
@MainActor
public enum SettingsColors {
    static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static func dynamic(_ pair: SettingsPaletteHex.Pair) -> NSColor {
        let l = rgb(pair.light), d = rgb(pair.dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }

    public static let sidebar = dynamic(SettingsPaletteHex.sidebar)
    public static let divider = dynamic(SettingsPaletteHex.divider)
    public static let detail = dynamic(SettingsPaletteHex.detail)
    public static let card = dynamic(SettingsPaletteHex.card)
    public static let separator = dynamic(SettingsPaletteHex.separator)
    public static let selection = dynamic(SettingsPaletteHex.selection)
    public static let title = dynamic(SettingsPaletteHex.title)
    public static let capsuleFill = dynamic(SettingsPaletteHex.capsuleFill)
    public static let capsuleRim = dynamic(SettingsPaletteHex.capsuleRim)
    public static let capsuleDivider = dynamic(SettingsPaletteHex.capsuleDivider)
    public static let chevron = dynamic(SettingsPaletteHex.chevron)
    public static let chevronDisabled = dynamic(SettingsPaletteHex.chevronDisabled)
    public static let popUpCircle = dynamic(SettingsPaletteHex.popUpCircle)
    public static let popUpChevron = dynamic(SettingsPaletteHex.popUpChevron)
    public static let label = dynamic(SettingsPaletteHex.label)
    public static let header = dynamic(SettingsPaletteHex.header)
    public static let switchOff = dynamic(SettingsPaletteHex.switchOff)
    public static let switchOn = dynamic(SettingsPaletteHex.switchOn)
    public static let disclosure = dynamic(SettingsPaletteHex.disclosure)
}

/// A view filled with one (dynamic) colour.
final class SettingsFillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0
    /// A divider drawn along the trailing edge (the sidebar's, 0.5 wide).
    var trailingEdge: NSColor? { didSet { needsDisplay = true } }

    init(_ color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        } else {
            bounds.intersection(dirtyRect).fill()
        }
        if let trailingEdge {
            trailingEdge.setFill()
            NSRect(x: bounds.maxX - SettingsMetrics.dividerWidth, y: bounds.minY, width: SettingsMetrics.dividerWidth, height: bounds.height).fill()
        }
    }
}

// MARK: The back/forward capsule

/// One chevron of the capsule, drawn as a path: the title colour when there
/// is history, #AEAEAE when there is none (R3.1).
final class SettingsChevronButton: NSButton {
    let pointsLeft: Bool

    init(left: Bool, label: String) {
        pointsLeft = left
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setAccessibilityLabel(label)
        toolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // 8 wide and 14.5 tall, centred.
        let w: CGFloat = 8, h: CGFloat = 14.5
        let r = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let p = NSBezierPath()
        if pointsLeft {
            p.move(to: NSPoint(x: r.maxX - 1, y: r.minY + 1))
            p.line(to: NSPoint(x: r.minX + 1, y: r.midY))
            p.line(to: NSPoint(x: r.maxX - 1, y: r.maxY - 1))
        } else {
            p.move(to: NSPoint(x: r.minX + 1, y: r.minY + 1))
            p.line(to: NSPoint(x: r.maxX - 1, y: r.midY))
            p.line(to: NSPoint(x: r.minX + 1, y: r.maxY - 1))
        }
        p.lineWidth = 2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        (isEnabled ? SettingsColors.chevron : SettingsColors.chevronDisabled).setStroke()
        p.stroke()
    }
}

/// The glass back/forward capsule: a near-white capsule with a faint rim
/// and a soft shadow, a divider at its centre, a chevron in each half.
final class SettingsNavigationCapsule: NSView {
    let back = SettingsChevronButton(left: true, label: "Back")
    let forward = SettingsChevronButton(left: false, label: "Forward")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 3
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        for b in [back, forward] { addSubview(b) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let half = bounds.width / 2
        back.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        forward.frame = NSRect(x: half, y: 0, width: half, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.25, dy: 0.25)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        SettingsColors.capsuleFill.setFill()
        capsule.fill()
        SettingsColors.capsuleRim.setStroke()
        capsule.lineWidth = 0.5
        capsule.stroke()
        // The divider: 1 point, y 16–36 in the window (7.5–27.5 here).
        SettingsColors.capsuleDivider.setFill()
        NSRect(x: (bounds.midX - 0.5).rounded(), y: 7.5, width: 1, height: 20).fill()
    }
}

// MARK: The sidebar

/// A pane row: the rounded selection band, 160 × 32 from x 10, #0070F5
/// (#007AFF dark).
final class SettingsSidebarRowView: NSTableRowView {
    // The window's selection stays the accent band (R3.4: the inactive
    // colour is not settled).
    override var isEmphasized: Bool {
        get { true }
        set { _ = newValue }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // x 10–170: 160 wide (R4.2).
        let r = NSRect(x: SettingsMetrics.selectionInset, y: bounds.minY, width: SettingsMetrics.selectionWidth, height: bounds.height)
        SettingsColors.selection.setFill()
        NSBezierPath(roundedRect: r, xRadius: SettingsMetrics.selectionRadius, yRadius: SettingsMetrics.selectionRadius).fill()
    }
}

/// A pane row's symbol (accent-tinted, centred on x 29) and label (ink at
/// x 47 on every row, whatever the symbol's width).
final class SettingsSidebarCellView: NSTableCellView {
    let symbol = NSImageView()
    let label = NSTextField(labelWithString: "")

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: SettingsMetrics.symbolPointSize, weight: .regular)
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbol.imageScaling = .scaleNone
        label.stringValue = title
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        label.lineBreakMode = .byTruncatingTail
        for v in [symbol, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = symbol
        textField = label
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.symbolCenterX),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A label's ink starts about 1 point after its alignment rect.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.sidebarLabelX - 1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.selectionInset - 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyStyle() } }

    func applyStyle() {
        let selected = backgroundStyle == .emphasized
        symbol.contentTintColor = selected ? .white : .controlAccentColor
        label.textColor = selected ? .white : .labelColor
        // The selected row's label is semibold (R5.3).
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize,
                                 weight: selected && SettingsTitleR5.selectedSidebarLabelIsSemibold ? .semibold : .regular)
    }
}

// MARK: The cards

/// A section header over a card: bold, #272727 (#DDDDDD dark), its ink 10 inside
/// the card's edge.
final class SettingsHeaderView: NSView {
    let label: NSTextField

    init(_ title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .boldSystemFont(ofSize: SettingsMetrics.fontSize)
        label.textColor = SettingsColors.header
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.labelInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor), label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A rounded card (#F7F7F7, radius 12, no border, no shadow) holding rows
/// with 1-point separators between them.
public final class SettingsCardView: NSView {
    let rows = NSStackView()
    public private(set) var rowViews: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor), rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor), rows.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        SettingsColors.card.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: SettingsMetrics.cardRadius, yRadius: SettingsMetrics.cardRadius).fill()
    }

    /// Adds a row, after a separator when it is not the first.
    func add(_ row: NSView) {
        if !rowViews.isEmpty { append(SettingsSeparatorView()) }
        append(row)
        rowViews.append(row)
    }

    private func append(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
}

/// The line between two rows: 1 point, #EBEBEB, inset 10 from both edges.
final class SettingsSeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: SettingsMetrics.separatorHeight) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        SettingsColors.separator.setFill()
        bounds.insetBy(dx: SettingsMetrics.separatorInset, dy: 0).fill()
    }
}

/// One row of a card: the label left-aligned (no colon), optional help
/// text under it in the secondary colour, and the trailing controls centred
/// on the label's line. A row whose content is not a label and a control
/// (a list, a preview) holds that view instead, inset 10.
public final class SettingsRowView: NSView {
    public let label: NSTextField
    public let controls: [NSView]
    public private(set) var help: NSTextField?
    private var helpConstraints: [NSLayoutConstraint] = []
    private var oneLine: [NSLayoutConstraint] = []
    private let controlStack: NSStackView?
    /// Whether the row holds one view instead of a label and controls.
    public let isContent: Bool
    /// Called when the row is clicked (drill-down rows).
    var onClick: (() -> Void)?
    /// A navigation row's icon (R4.1), at the row's leading edge.
    public private(set) var iconView: NSView?

    init(label title: String, controls: [NSView], icon: SettingsRowIcon? = nil) {
        label = NSTextField(labelWithString: title)
        self.controls = controls
        controlStack = controls.isEmpty ? nil : NSStackView(views: controls)
        isContent = false
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        label.textColor = SettingsColors.label
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // A navigation row: 44 tall, the icon 10 inside, the label's ink 45
        // inside (a label's ink starts 1 point after its alignment rect).
        let labelInset = icon == nil ? SettingsMetrics.labelInset : SettingsMetrics.navigationLabelInset - 1
        var cs: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: labelInset),
            heightAnchor.constraint(greaterThanOrEqualToConstant: icon == nil ? SettingsMetrics.rowHeight : SettingsMetrics.navigationRowHeight),
        ]
        if let icon {
            let v = SettingsRowIconView(icon)
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            iconView = v
            cs += [
                v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowIconInset),
                v.centerYAnchor.constraint(equalTo: centerYAnchor),
                v.widthAnchor.constraint(equalToConstant: SettingsMetrics.rowIconSize),
                v.heightAnchor.constraint(equalToConstant: SettingsMetrics.rowIconSize),
            ]
        }
        if let s = controlStack {
            s.orientation = .horizontal
            s.spacing = 8
            s.alignment = .centerY
            s.translatesAutoresizingMaskIntoConstraints = false
            s.setHuggingPriority(.required, for: .horizontal)
            addSubview(s)
            cs += [
                s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.controlInset),
                s.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                s.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
                s.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
                s.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            ]
        } else {
            cs.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.controlInset))
        }
        // One line: the label centred in the 37.5-point row.
        oneLine = [label.centerYAnchor.constraint(equalTo: centerYAnchor)]
        let tall = label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9)
        NSLayoutConstraint.activate(cs + oneLine + [tall])
    }

    /// A row that holds one view (a list, a preview, a table) inset 10.
    init(content: NSView, inset: CGFloat = SettingsMetrics.labelInset) {
        label = NSTextField(labelWithString: "")
        controls = [content]
        controlStack = nil
        isContent = true
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// The help text under the label: 11 points, the secondary colour, a
    /// 14-point pitch, the first baseline 19 under the label's.
    func setHelp(_ text: String) {
        if let help {
            help.attributedStringValue = Self.helpText(help.stringValue + "\n" + text)
            return
        }
        let h = NSTextField(wrappingLabelWithString: "")
        h.attributedStringValue = Self.helpText(text)
        h.preferredMaxLayoutWidth = SettingsMetrics.helpWidth
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        help = h
        NSLayoutConstraint.deactivate(oneLine)
        let labelEmpty = label.stringValue.isEmpty
        helpConstraints = [
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.labelInset),
            h.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsMetrics.helpWidth),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: topAnchor, constant: labelEmpty ? 0 : 9),
            labelEmpty ? h.topAnchor.constraint(equalTo: topAnchor, constant: 10.5)
                : h.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: SettingsMetrics.helpBaselineGap),
        ]
        NSLayoutConstraint.activate(helpConstraints)
    }

    static func helpText(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = SettingsMetrics.helpLinePitch
        p.maximumLineHeight = SettingsMetrics.helpLinePitch
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: SettingsMetrics.helpFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
        ])
    }

    public override func mouseUp(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseUp(with: event) }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

// MARK: Controls

/// A card's pop-up: the value text, then a 20-point circular button with
/// up/down chevrons whose right edge is 3.5 inside the frame (13.5 inside
/// the card); the menu is the pop-up's own.
final class SettingsCardPopUpCell: NSPopUpButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {}
    override func drawBorderAndBackground(withFrame cellFrame: NSRect, in controlView: NSView) {}

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let d = SettingsMetrics.popUpCircle
        let trail = SettingsMetrics.popUpCircleInset - SettingsMetrics.controlInset
        let circle = NSRect(x: cellFrame.maxX - trail - d, y: cellFrame.midY - d / 2, width: d, height: d)
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        SettingsColors.popUpCircle.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: circle).fill()
        // Up and down chevrons, 7 wide.
        let p = NSBezierPath()
        let cx = circle.midX, cy = circle.midY
        let flipped = controlView.isFlipped ? CGFloat(1) : -1
        p.move(to: NSPoint(x: cx - 3.5, y: cy - 1.5 * flipped))
        p.line(to: NSPoint(x: cx, y: cy - 5 * flipped))
        p.line(to: NSPoint(x: cx + 3.5, y: cy - 1.5 * flipped))
        p.move(to: NSPoint(x: cx - 3.5, y: cy + 1.5 * flipped))
        p.line(to: NSPoint(x: cx, y: cy + 5 * flipped))
        p.line(to: NSPoint(x: cx + 3.5, y: cy + 1.5 * flipped))
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        SettingsColors.popUpChevron.withAlphaComponent(alpha).setStroke()
        p.stroke()
        // The value, ending 12.5 before the circle.
        let text = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: SettingsMetrics.fontSize),
            .foregroundColor: isEnabled ? SettingsColors.label : NSColor.disabledControlTextColor,
        ])
        let size = text.size()
        let x = circle.minX - SettingsMetrics.popUpTextGap - size.width
        text.draw(at: NSPoint(x: max(cellFrame.minX, x), y: cellFrame.midY - size.height / 2))
    }

    override var cellSize: NSSize {
        let text = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [.font: NSFont.systemFont(ofSize: SettingsMetrics.fontSize)])
        let trail = SettingsMetrics.popUpCircleInset - SettingsMetrics.controlInset
        return NSSize(width: ceil(text.size().width) + SettingsMetrics.popUpTextGap + SettingsMetrics.popUpCircle + trail, height: 22)
    }
}

/// A switch with the row's title (the label beside it is the row's),
/// drawn by Ycode at the card's size: a 36 × 16 track with a 21 × 12 knob
/// (R4.1, `SettingsSwitchDrawing`).
final class ClosureSwitch: NSSwitch {
    /// The row's title.
    let title: String
    var onChange: ((ClosureSwitch) -> Void)?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        controlSize = .small
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func fire() { onChange?(self) }

    override var intrinsicContentSize: NSSize { SettingsMetrics.switchSize }
    override var wantsUpdateLayer: Bool { false }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        SettingsSwitchDrawing.draw(on: state == .on, enabled: isEnabled, in: bounds)
    }

    // The system's switch is drawn by a hosted subview: Ycode hides it and
    // draws its own (the measured size is not one of the system's).
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.isHidden = true
    }

    override func layout() {
        super.layout()
        for v in subviews where !v.isHidden { v.isHidden = true }
    }

    /// A click flips the switch (no drag; the knob moves at once).
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        flip()
    }

    func flip() {
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }

    // Still a switch to accessibility (the hidden subview was its element).
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }
}
