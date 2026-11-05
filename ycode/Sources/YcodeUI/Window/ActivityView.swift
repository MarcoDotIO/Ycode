import AppKit
import YcodeIDECore

/// The toolbar's activity view (`reference-ui-6.md` §3.1): the workspace's
/// icon, or a small spinner while an action runs, then two lines, the
/// workspace name and the activity subtitle (truncated in the middle).
/// Issue counts are in their own capsule (`IssueCapsuleView`).
@MainActor
public final class ActivityView: NSView {
    public var workspaceName = "" { didSet { changed() } }
    /// The activity line; empty while idle (no "Ready", reference-ui-5.md §4.3).
    public var status = "" { didSet { changed() } }
    public var errors = 0 { didSet { needsDisplay = true } }
    public var warnings = 0 { didSet { needsDisplay = true } }
    /// An action runs: the spinner replaces the icon.
    public var isBusy = false { didSet { if oldValue != isBusy { updateBusy() } } }
    /// The workspace's glyph (a package or a project).
    public var isPackage = false { didSet { icon.image = Self.iconImage(package: isPackage) } }
    /// The widest the view may be (the toolbar sets it when room is short,
    /// reference-ui-6.md §2.2); the subtitle truncates to fit.
    public var maximumWidth: CGFloat = .greatestFiniteMagnitude { didSet { if oldValue != maximumWidth { changed() } } }

    let icon = NSImageView()
    let spinner = NSProgressIndicator()

    /// `liquid-glass.md` §7.1 item 3: the icon is 19 wide and the text
    /// starts 8 after it.
    static let iconSize: CGFloat = 19
    /// The space before the icon and after the text: none (the activity
    /// view has no glass shape, `specs/ide/liquid-glass.md` §2.2).
    static let sideInset: CGFloat = 0
    /// Where the text starts (after the icon) with no leading pad.
    static var textInset: CGFloat { sideInset + iconSize + 8 }
    /// From the toolbar item before this view (Back | Forward) to the icon:
    /// the reference's control ends at x 371 and its icon starts at 385
    /// (`liquid-glass.md` §7.1, `metrics.md` §14). The system's gap before
    /// a view item differs between macOS versions (4 points on 27.2, 8 on
    /// 27.0), so the view pads its leading end up to this gap.
    static let gapAfterNeighbor: CGFloat = 14
    /// The toolbar control before this view, whose trailing edge the icon
    /// keeps `gapAfterNeighbor` from.
    public weak var leadingNeighbor: NSView? { didSet { needsLayout = true } }
    /// The room before the icon that makes up the system's smaller gap.
    public private(set) var leadingPad: CGFloat = 0
    /// Where the text starts.
    var textStart: CGFloat { leadingPad + Self.textInset }
    static let nameFont = NSFont.boldSystemFont(ofSize: 13)
    static let statusFont = NSFont.systemFont(ofSize: 11)
    static func iconImage(package: Bool) -> NSImage? {
        NSImage(systemSymbolName: package ? "shippingbox" : "folder.badge.gearshape", accessibilityDescription: nil)
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = Self.iconImage(package: false)
        icon.imageScaling = .scaleProportionallyUpOrDown
        // The project's colour family, as in the navigator (not a document glyph).
        icon.contentTintColor = .systemBlue
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        for v in [icon, spinner] as [NSView] { addSubview(v) }
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The spinner is shown (tests).
    public var showsSpinner: Bool { !spinner.isHidden }

    /// Whether the window is key (the title's colours follow it).
    public var isWindowActive: Bool { window.map { $0.isKeyWindow || $0.isMainWindow && NSApp.isActive } ?? true }
    private var keyObservers: [NSObjectProtocol] = []

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in keyObservers { NotificationCenter.default.removeObserver(o) }
        keyObservers = []
        guard let w = window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didResignMainNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            })
        }
    }

    func updateBusy() {
        spinner.isHidden = !isBusy
        icon.isHidden = isBusy
        if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsDisplay = true
    }

    /// The natural width changed (the toolbar refits, §2.2).
    public var onNaturalWidthChange: (() -> Void)?
    private var lastNaturalWidth: CGFloat = 0

    func changed() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        let w = naturalWidth
        if abs(w - lastNaturalWidth) >= 1 { lastNaturalWidth = w; onNaturalWidthChange?() }
    }

    /// The width the name and the whole subtitle need.
    public var naturalWidth: CGFloat {
        let name = (workspaceName as NSString).size(withAttributes: [.font: Self.nameFont]).width
        let line = (status as NSString).size(withAttributes: [.font: Self.statusFont]).width
        return ceil(textStart + max(name, line) + 2 + Self.sideInset)
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: max(textStart + 40, min(naturalWidth, maximumWidth)), height: 34) }

    public override func layout() {
        super.layout()
        updateLeadingPad()
        let r = NSRect(x: Self.sideInset + leadingPad, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
        icon.frame = r
        spinner.frame = r
    }

    /// Pads the leading end so the icon sits `gapAfterNeighbor` after the
    /// item before it, whatever gap the system leaves between the items.
    func updateLeadingPad() {
        var pad: CGFloat = 0
        if let n = leadingNeighbor, let w = window, n.window === w, !n.isHiddenOrHasHiddenAncestor {
            let gap = convert(bounds, to: nil).minX - n.convert(n.bounds, to: nil).maxX
            if gap >= 0 { pad = max(0, (Self.gapAfterNeighbor - gap).rounded()) }
        }
        if abs(pad - leadingPad) >= 0.5 {
            leadingPad = pad
            changed()
        }
    }

    /// The subtitle as drawn in `width` points: truncated in the middle
    /// ("Finished r…ning MyApp", §3.1.3).
    public static func truncatedStatus(_ status: String, width: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: statusFont]
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        guard w(status) > width else { return status }
        let chars = Array(status)
        var keep = chars.count - 1
        while keep > 0 {
            let head = keep - keep / 2, tail = keep / 2
            let s = String(chars[..<head]) + "\u{2026}" + String(chars[(chars.count - tail)...])
            if w(s) <= width { return s }
            keep -= 1
        }
        return "\u{2026}"
    }

    /// The text shown as the subtitle at the current width (tests).
    public var shownStatus: String { Self.truncatedStatus(status, width: max(0, bounds.width - textStart - Self.sideInset)) }

    /// Two lines (reference-ui.md §5): the workspace name, and under it
    /// the activity. While idle only the name is drawn, centered
    /// vertically. No progress bar and no underline (§3.1.2).
    public override func draw(_ dirtyRect: NSRect) {
        let width = max(0, bounds.width - textStart - Self.sideInset)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // In an inactive window both lines dim to the same grey (#BCBDBD,
        // liquid-glass.md §7.1 item 3).
        let active = isWindowActive
        let name = NSAttributedString(string: workspaceName, attributes: [.font: Self.nameFont, .paragraphStyle: para,
                                                                           .foregroundColor: active ? NSColor.labelColor : NSColor.tertiaryLabelColor])
        let line = NSAttributedString(string: shownStatus, attributes: [.font: Self.statusFont,
                                                                        .foregroundColor: active ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor])
        let nameH = name.size().height
        let lineHeight = status.isEmpty ? 0 : line.size().height
        let top = (bounds.height - nameH - lineHeight) / 2
        // Flipped drawing is not used: y grows upward.
        if !status.isEmpty { line.draw(at: NSPoint(x: textStart, y: top)) }
        name.draw(in: NSRect(x: textStart, y: top + lineHeight, width: width, height: nameH))
    }
}

/// The toolbar's issue capsule right of the scheme pill
/// (`reference-ui-6.md` §2.3, T9): an errors button, an issues button
/// (warnings) and, after a test run, a failed-tests button; zero counts
/// are left out and the capsule is hidden with nothing to show. Each
/// button opens the Issue navigator (`onClick`).
@MainActor
public final class IssueCapsuleView: NSView {
    public var errors = 0 { didSet { update() } }
    public var warnings = 0 { didSet { update() } }
    public var failedTests = 0 { didSet { update() } }
    /// A button was clicked (its part's index in `allParts`).
    public var onClick: ((Int) -> Void)?
    /// The shown parts or their digits changed (the toolbar refits, §2.2).
    public var onPartsChange: (() -> Void)?
    private var lastShape = ""

    /// Every part as (symbol, accessibility title), in order.
    public static let allParts = [("xmark.octagon.fill", "Errors"), ("exclamationmark.triangle.fill", "Issues"), ("xmark.diamond.fill", "Test Failures")]
    /// The visible parts as (symbol, count), in order (tests).
    public var parts: [(String, Int)] {
        zip(Self.allParts.map(\.0), [errors, warnings, failedTests]).filter { $0.1 > 0 }
    }
    /// The buttons, one per part of `allParts`; hidden ones have a zero count.
    public private(set) var buttons: [NSButton] = []
    let stack = NSStackView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        for (i, (symbol, title)) in Self.allParts.enumerated() {
            let color = symbol.hasPrefix("exclamation") ? Theme.warningColor : Theme.errorColor
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            let b = NSButton(title: "0", image: image ?? NSImage(), target: self, action: #selector(clicked(_:)))
            b.contentTintColor = color   // the glyph's severity color; the count keeps the label color (`update`)
            b.tag = i
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageScaling = .scaleProportionallyDown
            b.font = .systemFont(ofSize: 11)
            b.setAccessibilityTitle(title)
            b.toolTip = title
            b.isHidden = true
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc func clicked(_ b: NSButton) { onClick?(b.tag) }

    func update() {
        for (b, n) in zip(buttons, [errors, warnings, failedTests]) {
            b.attributedTitle = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
            b.isHidden = n == 0
        }
        isHidden = parts.isEmpty
        invalidateIntrinsicContentSize()
        needsDisplay = true
        let shape = parts.map { "\($0.0)\(String($0.1).count)" }.joined()
        if shape != lastShape { lastShape = shape; onPartsChange?() }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !parts.isEmpty else { return }
        // With the Liquid Glass design the toolbar draws the capsule
        // (a bordered item, liquid-glass.md §2.2).
        if #available(macOS 26, *) { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
}
