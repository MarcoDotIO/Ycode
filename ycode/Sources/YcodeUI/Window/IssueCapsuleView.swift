import AppKit
import YcodeIDECore

/// The toolbar's issue capsule right after the scheme capsule
/// (`editor-area.md` G.8, council row 138; `reference-ui-6.md` §2.3): one
/// button per kind with issues, errors first, each its symbol (a red circle
/// with a white cross; a yellow triangle with a white mark; Ycode's
/// test-failure diamond) and its count; zero counts are left out and the
/// capsule is hidden with nothing to show. In a narrow window it shows the
/// symbols only (`symbolsOnly`, with the scheme capsule's glyphs-only
/// step). Its sizes are `IssueSummary.Capsule`'s, shared with the Linux
/// IDE. Each button opens the Issue navigator (`onClick`).
@MainActor
public final class IssueCapsuleView: NSView {
    public var errors = 0 { didSet { update() } }
    public var warnings = 0 { didSet { update() } }
    public var failedTests = 0 { didSet { update() } }
    /// Symbols without their counts (a narrow window, G.4).
    public var symbolsOnly = false { didSet { if oldValue != symbolsOnly { update() } } }
    /// A button was clicked (its part's index in `allParts`).
    public var onClick: ((Int) -> Void)?
    /// The shown parts or their digits changed (the toolbar refits, §2.2).
    public var onPartsChange: (() -> Void)?
    private var lastShape = ""

    /// The counts as one value (shared with the jump bar's stepper).
    public var summary: IssueSummary { IssueSummary(errors: errors, warnings: warnings, failedTests: failedTests) }

    /// Every part as (symbol, accessibility title), in order.
    public static let allParts = IssueSummary.Kind.allCases.map { ($0.symbol, $0.title) }
    /// The visible parts as (symbol, count), in order (tests).
    public var parts: [(String, Int)] { summary.parts.map { ($0.kind.symbol, $0.count) } }
    /// The buttons, one per part of `allParts`; hidden ones have a zero count.
    public private(set) var buttons: [IssuePartButton] = []

    static let countFont = NSFont.systemFont(ofSize: CGFloat(IssueSummary.Capsule.countSize))

    /// A kind's symbol: the system symbol in two colours, its mark white
    /// on the kind's fill, sized so the triangle's ink is about 17.5 × 15.5.
    public static func symbolImage(_ kind: IssueSummary.Kind) -> NSImage {
        let fill = NSColor(srgbRed: CGFloat(kind.fill >> 16 & 0xFF) / 255, green: CGFloat(kind.fill >> 8 & 0xFF) / 255,
                           blue: CGFloat(kind.fill & 0xFF) / 255, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(IssueSummary.Capsule.symbolSize), weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, fill]))
        guard let symbol = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)?.withSymbolConfiguration(config) else {
            return NSImage()
        }
        // Drawn once into an image of its own that is not a template: the
        // toolbar tints template images (and symbol images) with its glyph
        // colour, which would turn the red and yellow grey.
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = kind.title
        return image
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        for kind in IssueSummary.Kind.allCases {
            let b = IssuePartButton(kind: kind)
            b.target = self
            b.action = #selector(clicked(_:))
            b.tag = kind.rawValue
            b.setAccessibilityTitle(kind.title)
            b.toolTip = kind.title
            b.isHidden = true
            buttons.append(b)
            addSubview(b)
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    @objc func clicked(_ b: NSButton) { onClick?(b.tag) }

    static func countWidth(_ s: String) -> Double { Double(ceil((s as NSString).size(withAttributes: [.font: countFont]).width)) }

    /// The capsule's width for its parts (`IssueSummary.Capsule.width`).
    public var capsuleWidth: CGFloat {
        CGFloat(IssueSummary.Capsule.width(summary.parts, symbolsOnly: symbolsOnly, countWidth: Self.countWidth))
    }

    /// The content's height: the toolbar draws the 36-point glass capsule
    /// around it (`IssueSummary.Capsule.height`), as for the scheme capsule.
    static let contentHeight: CGFloat = 24
    // Never zero wide, even hidden: the toolbar warns about a view item it
    // measures as empty.
    public override var intrinsicContentSize: NSSize { NSSize(width: max(1, capsuleWidth), height: Self.contentHeight) }

    func update() {
        let shown = Set(summary.parts.map(\.kind))
        for (b, kind) in zip(buttons, IssueSummary.Kind.allCases) {
            b.count = summary.count(kind)
            b.showsCount = !symbolsOnly
            b.isHidden = !shown.contains(kind)
        }
        isHidden = summary.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
        let shape = parts.map { "\($0.0)\(String($0.1).count)" }.joined() + (symbolsOnly ? "s" : "")
        if shape != lastShape { lastShape = shape; onPartsChange?() }
    }

    /// The parts left to right from the capsule's leading inset; each
    /// button covers its symbol and count, the gaps split between them.
    public override func layout() {
        super.layout()
        let c = IssueSummary.Capsule.self
        var x = CGFloat(c.leading)
        for b in buttons where !b.isHidden {
            let w = b.contentWidth
            b.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            b.layoutSubtreeIfNeeded()
            x += w + CGFloat(c.partGap)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !summary.isEmpty else { return }
        // With the Liquid Glass design the toolbar draws the capsule
        // (a bordered item, liquid-glass.md §2.2).
        if #available(macOS 26, *) { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: bounds.height / 2 - 2, yRadius: bounds.height / 2 - 2).fill()
    }
}

/// One kind's button in the issue capsule: its symbol and, unless the
/// capsule shows symbols only, its count 8 after it (13 points, the label
/// colour). The button draws no bezel; its title is the count (for
/// accessibility and tests) and its accessibility title the kind's.
@MainActor
public final class IssuePartButton: NSButton {
    public let kind: IssueSummary.Kind
    let glyph = IssueSymbolView()
    let countLabel = NSTextField(labelWithString: "")
    var count = 0 {
        didSet {
            title = "\(count)"
            countLabel.stringValue = title
            needsLayout = true
        }
    }
    var showsCount = true { didSet { countLabel.isHidden = !showsCount; needsLayout = true } }

    init(kind: IssueSummary.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        glyph.image = IssueCapsuleView.symbolImage(kind)
        glyph.imageScaling = .scaleNone
        countLabel.font = IssueCapsuleView.countFont
        countLabel.textColor = .labelColor
        for v in [glyph, countLabel] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    /// The subviews do not take clicks: the button does.
    public override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !frame.contains(point) ? nil : self }
    public override func draw(_ dirtyRect: NSRect) {}

    /// The symbol's slot, then the count.
    var contentWidth: CGFloat {
        let c = IssueSummary.Capsule.self
        var w = CGFloat(c.symbolWidth)
        if showsCount { w += CGFloat(c.symbolToCount + IssueCapsuleView.countWidth(title)) }
        return w
    }

    /// The symbol's frame in the button (tests).
    public var symbolFrame: NSRect { glyph.frame }
    /// The count's frame in the button; zero with symbols only (tests).
    public var countFrame: NSRect { countLabel.isHidden ? .zero : countLabel.frame }

    public override func layout() {
        super.layout()
        let c = IssueSummary.Capsule.self
        let size = glyph.image?.size ?? .zero
        // Centred in the symbol's slot and on the capsule's middle.
        glyph.frame = NSRect(x: (CGFloat(c.symbolWidth) - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let text = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(x: CGFloat(c.symbolWidth + c.symbolToCount), y: ((bounds.height - text.height) / 2).rounded(),
                                  width: ceil(text.width), height: text.height)
    }
}

/// The kind's symbol in its own colours. A plain view, not an image view:
/// the toolbar validates and dims controls in its items' views and draws
/// vibrant content in its glass, either of which turned the red and yellow
/// grey.
final class IssueSymbolView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var imageScaling: NSImageScaling = .scaleNone
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) { image?.draw(in: bounds) }
}
