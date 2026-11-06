import AppKit

/// A card of the Device Hub's Settings inspector (`specs/ide/device-hub.md`
/// §11.3, council round 3 checklist row 66): rows 42 points tall with a
/// 1-point separator between them (a 43-point pitch), inset to the label
/// column; each row a leading symbol (13 wide, 13.5 inside the card), the
/// label (38 inside), and the control at the trailing edge (a switch 13
/// inside, a pop-up's chevron about 20 inside, a slider 108 wide). The card
/// is 260 wide (10 inside the 280-point inspector on each side), rounded
/// (radius 12), filled a step darker than the inspector (#E6E6E7 on
/// #EDEDEE in light), no border; cards are 10 apart.
@MainActor
final class InspectorCard: NSView {
    static let width: CGFloat = 260
    static let rowHeight: CGFloat = 42
    static let separatorHeight: CGFloat = 1
    static var rowPitch: CGFloat { rowHeight + separatorHeight }
    static let cornerRadius: CGFloat = 12
    static let symbolX: CGFloat = 13.5
    static let symbolWidth: CGFloat = 13
    static let labelX: CGFloat = 38
    static let sliderWidth: CGFloat = 108
    /// From the control's trailing edge to the card's: switches and sliders, pop-ups.
    static let switchTrailing: CGFloat = 13
    static let popUpTrailing: CGFloat = 14
    static let messagePadding: CGFloat = 13

    struct Row {
        var symbol: String
        var title: String
        var control: NSView
    }

    /// The card's fill: #E6E6E7 in light; in dark a step lighter than the inspector.
    static let fill = NSColor(name: "YcodeInspectorCard") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.192, green: 0.192, blue: 0.2, alpha: 1)
            : NSColor(srgbRed: 0.902, green: 0.902, blue: 0.906, alpha: 1)
    }
    /// The separators: #DCDCDD in light.
    static let separator = NSColor(name: "YcodeInspectorCardSeparator") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09)
            : NSColor(srgbRed: 0.863, green: 0.863, blue: 0.867, alpha: 1)
    }

    private(set) var rows: [Row] = []
    private var symbolViews: [NSImageView] = []
    private var labels: [NSTextField] = []
    private var separators: [NSView] = []
    private var message: NSTextField?

    /// A card of setting rows.
    init(rows: [Row], identifier: String) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(rows: rows.count)))
        setUp(identifier)
        for (i, r) in rows.enumerated() {
            let image = NSImageView(image: NSImage(systemSymbolName: r.symbol, accessibilityDescription: r.title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage())
            image.contentTintColor = .labelColor
            image.imageScaling = .scaleProportionallyDown
            let label = NSTextField(labelWithString: r.title)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            for v in [image, label, r.control] { addSubview(v) }
            symbolViews.append(image)
            labels.append(label)
            if i < rows.count - 1 {
                let sep = SeparatorFill()
                addSubview(sep)
                separators.append(sep)
            }
        }
    }

    /// A card holding one message (no settings to offer, §11.3).
    init(message text: String, identifier: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight))
        setUp(identifier)
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 13)
        l.identifier = .init("inspector-message")
        addSubview(l)
        message = l
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setUp(_ identifier: String) {
        self.identifier = .init(identifier)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let h = heightAnchor.constraint(equalToConstant: frame.height)
        h.isActive = true
        heightConstraint = h
    }

    private var heightConstraint: NSLayoutConstraint?

    static func height(rows n: Int) -> CGFloat { n <= 0 ? rowHeight : CGFloat(n) * rowHeight + CGFloat(n - 1) * separatorHeight }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Self.fill.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
    }

    /// The message's text (tests; nil: a card of rows).
    var messageText: String? { message?.stringValue }

    /// The rectangle of row `i` in the card (tests).
    func rowRect(_ i: Int) -> CGRect { CGRect(x: 0, y: CGFloat(i) * Self.rowPitch, width: Self.width, height: Self.rowHeight) }

    override func layout() {
        super.layout()
        if let message {
            let w = Self.width - 2 * Self.messagePadding
            let s = message.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude))
            let h = max(Self.rowHeight, ceil(s.height) + 2 * Self.messagePadding)
            message.frame = CGRect(x: Self.messagePadding, y: ((h - s.height) / 2).rounded(), width: w, height: ceil(s.height))
            if heightConstraint?.constant != h { heightConstraint?.constant = h }
            return
        }
        for (i, r) in rows.enumerated() {
            let row = rowRect(i)
            symbolViews[i].frame = CGRect(x: Self.symbolX, y: row.midY - 8, width: Self.symbolWidth, height: 16)
            let control = r.control
            let fit = control.fittingSize
            var cw = fit.width, ch = fit.height
            let trailing: CGFloat
            switch control {
            case is NSSwitch: trailing = Self.switchTrailing
            case is NSSlider: trailing = Self.switchTrailing; cw = Self.sliderWidth; ch = max(ch, 20)
            case is NSPopUpButton:
                // The label keeps its width; the pop-up's value truncates instead.
                trailing = Self.popUpTrailing
                let room = Self.width - trailing - Self.labelX - labels[i].fittingSize.width - 8
                cw = max(60, min(cw, room))
            default: trailing = Self.switchTrailing
            }
            control.frame = CGRect(x: Self.width - trailing - cw, y: (row.midY - ch / 2).rounded(), width: cw, height: ch)
            let labelRight = control.frame.minX - 8
            let lh = labels[i].fittingSize.height
            labels[i].frame = CGRect(x: Self.labelX, y: (row.midY - lh / 2).rounded(), width: max(10, labelRight - Self.labelX), height: lh)
            if i < separators.count {
                separators[i].frame = CGRect(x: Self.labelX, y: row.maxY, width: Self.width - Self.labelX, height: Self.separatorHeight)
            }
        }
    }
}

/// A separator line in a card's colour.
@MainActor
private final class SeparatorFill: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = InspectorCard.separator.cgColor }
}
