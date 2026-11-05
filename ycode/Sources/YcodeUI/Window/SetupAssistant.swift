import AppKit
import QuartzCore

/// The paged setup assistant (`specs/ide/liquid-glass-ycode.md` §11) that the
/// headset and runtime setup windows share: page dots at the top, a centred
/// header (glyph, title, summary), a centred column that scrolls, and a footer
/// with Back at the leading side and Re-check and Continue at the trailing
/// side. The header and column form the page, which moves when the step
/// changes; the dots and the footer stay still.
@MainActor
final class SetupAssistant: NSObject {
    static let windowSize = NSSize(width: 760, height: 600)
    static let minimumSize = NSSize(width: 640, height: 520)
    static let glyphTop: CGFloat = 48
    static let glyphSize: CGFloat = 64
    static let titleGap: CGFloat = 12
    static let summaryWidth: CGFloat = 480
    static let columnWidth: CGFloat = 520
    static let footerInset: CGFloat = 20
    /// The column's distance from the footer.
    static let columnGap: CGFloat = 12
    static let slideDuration: TimeInterval = 0.3
    static let fadeDuration: TimeInterval = 0.2
    static let animationKey = "ycode.setup.page"

    let dots = SetupPageDots()
    /// The header and the column: what a step change moves.
    let page = NSView()
    let glyph = SetupGlyphView()
    let titleLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let scroll = NSScrollView()
    /// The step's content.
    let column = NSStackView()
    let footnote: NSTextField
    let footer = NSStackView()
    let backButton = NSButton(title: "Back", target: nil, action: nil)
    let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    let recheckButton = NSButton(title: "Re-check", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    /// Forces Reduce Motion on or off (tests); nil follows the system.
    var reduceMotionOverride: Bool?
    /// The last page change, as it was animated (tests).
    private(set) var lastTransition: SetupTransition?
    /// The old page while it leaves.
    private(set) var leavingPage: NSView?
    private let document = FlippedView()

    /// The window both assistants use: full-size content, a transparent
    /// title bar, only the close button.
    static func makeWindow(title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }
        w.isReleasedWhenClosed = false
        w.contentMinSize = minimumSize
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        return w
    }

    init(footnote words: String, footnoteID: String, statusID: String, dotsID: String) {
        footnote = NSTextField(wrappingLabelWithString: words)
        super.init()
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.alignment = .center
        footnote.identifier = .init(footnoteID)
        footnote.preferredMaxLayoutWidth = Self.summaryWidth
        statusLabel.identifier = .init(statusID)
        dots.identifier = .init(dotsID)
    }

    /// Lays the assistant out in `root` (the window's content view); the
    /// buttons send `back`, `next` and `recheck` actions to `target`.
    func install(in root: NSView, target: AnyObject, back: Selector, next: Selector, recheck: Selector) {
        root.wantsLayer = true
        page.wantsLayer = true
        glyph.identifier = .init("setup-glyph")
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.identifier = .init("setup-title")
        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .center
        summaryLabel.preferredMaxLayoutWidth = Self.summaryWidth
        summaryLabel.identifier = .init("setup-summary")
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.identifier = .init("setup-column")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.identifier = .init("setup-scroll")
        document.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document
        for v in [glyph, titleLabel, summaryLabel, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(v)
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for (b, sel) in [(backButton, back), (continueButton, next), (recheckButton, recheck)] {
            b.target = target
            b.action = sel
            GlassBars.style(b, primary: b === continueButton)
            b.controlSize = .large
        }
        continueButton.keyEquivalent = "\r"
        backButton.identifier = .init("setup-back")
        continueButton.identifier = .init("setup-continue")
        recheckButton.identifier = .init("setup-recheck")
        footer.setViews([backButton, spinner, statusLabel], in: .leading)
        footer.setViews([recheckButton, continueButton], in: .trailing)
        footer.spacing = 8
        footer.identifier = .init("setup-footer")
        for v in [page, dots, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let inset = Self.footerInset
        let fill = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48)
        fill.priority = .defaultLow  // below the window's own size (500), which it must never push
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dots.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.topAnchor.constraint(equalTo: root.topAnchor),
            page.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Self.columnGap),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            backButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            glyph.topAnchor.constraint(equalTo: page.topAnchor, constant: Self.glyphTop),
            glyph.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSize), glyph.heightAnchor.constraint(equalToConstant: Self.glyphSize),
            titleLabel.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: Self.titleGap),
            titleLabel.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -48),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            summaryLabel.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.summaryWidth),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -48),
            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            // Centred on the page, not the document, so a shown scroller does not move it.
            column.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth), fill,
        ])
    }

    /// The header: the step's glyph (a system symbol in the accent colour,
    /// hierarchical), its title and summary.
    func setHeader(glyph name: String, title: String, summary: String) {
        var config = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
        if #available(macOS 12.0, *) { config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: .controlAccentColor)) }
        glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyph.set(symbolName: name)
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary
    }

    /// Replaces the column's content. Views of `SetupWideView` run the
    /// column's width; the footnote ends it.
    func setColumn(_ views: [NSView]) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views + [SetupCentered(footnote)] {
            column.addArrangedSubview(v)
            if v is SetupWideView { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
    }

    // MARK: Page changes

    var reducesMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Shows the next page: `fill` builds it, then it pushes in from the
    /// trailing edge (`forward`) or the leading edge while the old page leaves
    /// the other way; a crossfade with Reduce Motion. The new content is in
    /// place at once; only its presentation moves.
    func turn(forward: Bool, fill: () -> Void) {
        finishTransition()
        guard let root = page.superview, page.bounds.width > 0, page.bounds.height > 0,
              let rep = page.bitmapImageRepForCachingDisplay(in: page.bounds) else {
            fill()
            return
        }
        page.cacheDisplay(in: page.bounds, to: rep)
        let image = NSImage(size: page.bounds.size)
        image.addRepresentation(rep)
        let old = NSImageView(frame: page.frame)
        old.image = image
        old.imageScaling = .scaleAxesIndependently
        old.wantsLayer = true
        old.identifier = .init("setup-leaving-page")
        root.addSubview(old, positioned: .above, relativeTo: page)
        leavingPage = old
        fill()
        root.layoutSubtreeIfNeeded()
        let crossfade = reducesMotion
        let leftToRight = root.userInterfaceLayoutDirection == .leftToRight
        // Where the new page starts: the trailing side going forward.
        let offset = page.bounds.width * (forward == leftToRight ? 1 : -1)
        lastTransition = SetupTransition(style: crossfade ? .crossfade : .push, forward: forward, offset: crossfade ? 0 : offset)
        let duration = crossfade ? Self.fadeDuration : Self.slideDuration
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        func animate(_ layer: CALayer?, _ keyPath: String, from: CGFloat, to: CGFloat) {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = timing
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            layer?.add(a, forKey: Self.animationKey)
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            if crossfade {
                animate(page.layer, "opacity", from: 0, to: 1)
                animate(old.layer, "opacity", from: 1, to: 0)
            } else {
                animate(page.layer, "transform.translation.x", from: offset, to: 0)
                animate(old.layer, "transform.translation.x", from: 0, to: -offset)
            }
        }, completionHandler: { [weak self, weak old] in
            MainActor.assumeIsolated {
                guard let self, let old, self.leavingPage === old else { return }
                self.finishTransition()
            }
        })
    }

    /// Ends a page change at once: the old page goes, the new one is in place.
    func finishTransition() {
        leavingPage?.removeFromSuperview()
        leavingPage = nil
        page.layer?.removeAnimation(forKey: Self.animationKey)
    }

    // MARK: Pieces for the column

    /// A heading inside the column.
    static func heading(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    /// The check marks (and runtime rows): a system colour and a shape per state.
    static func mark(_ state: SetupDotState) -> (String, NSColor) {
        switch state {
        case .ok: ("checkmark.circle.fill", .systemGreen)
        case .missing: ("xmark.circle.fill", .systemRed)
        case .notApplicable: ("minus.circle", .secondaryLabelColor)
        case .unknown, .notChecked: ("questionmark.circle", .secondaryLabelColor)
        }
    }
}

/// The step's glyph, drawn to fit its 64-point box (an image view would
/// align the symbol's own alignment rect instead of the box).
final class SetupGlyphView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    private(set) var symbolName = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(symbolName name: String) { symbolName = name }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let k = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// How a page change was animated.
struct SetupTransition: Equatable {
    enum Style: Equatable { case push, crossfade }
    var style: Style
    var forward: Bool
    /// Where the new page started, in points along x (0 for a crossfade).
    var offset: CGFloat
}

/// A step's state as its page dot shows it.
enum SetupDotState: Equatable {
    case ok, missing, unknown, notChecked, notApplicable

    var title: String {
        switch self {
        case .ok: "passed"
        case .missing: "needs attention"
        case .unknown: "unknown"
        case .notChecked: "not checked"
        case .notApplicable: "not applicable"
        }
    }

    var color: NSColor {
        switch self {
        case .ok: .systemGreen
        case .missing: .systemOrange
        case .unknown, .notChecked, .notApplicable: .systemGray
        }
    }
}

/// The page dots: one per step, the current one larger; a click jumps.
@MainActor
final class SetupPageDots: NSStackView {
    var onSelect: ((Int) -> Void)?
    private(set) var dots: [SetupPageDot] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        spacing = 2
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Steps")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ pages: [(title: String, state: SetupDotState)], current: Int) {
        if dots.count != pages.count {
            dots.forEach { $0.removeFromSuperview() }
            dots = pages.indices.map { SetupPageDot(index: $0, target: self, action: #selector(clicked(_:))) }
            dots.forEach(addArrangedSubview)
        }
        for (i, p) in pages.enumerated() {
            dots[i].set(state: p.state, current: i == current, label: "Step \(i + 1) of \(pages.count): \(p.title), \(p.state.title)")
        }
    }

    @objc func clicked(_ sender: SetupPageDot) { onSelect?(sender.index) }
}

/// One page dot, drawn by itself in a 20-point click target: ok a filled
/// circle, missing a filled diamond, unknown a ring, not applicable a bar.
@MainActor
final class SetupPageDot: NSButton {
    static let side: CGFloat = 20
    static let currentDiameter: CGFloat = 10
    static let diameter: CGFloat = 7
    let index: Int
    private(set) var dotState: SetupDotState = .notChecked
    private(set) var isCurrent = false

    init(index: Int, target: AnyObject, action: Selector) {
        self.index = index
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        title = ""
        isBordered = false
        self.target = target
        self.action = action
        identifier = .init("setup-dot-\(index)")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(state: SetupDotState, current: Bool, label: String) {
        dotState = state
        isCurrent = current
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityValue(current ? "current" : nil)
        needsDisplay = true
    }

    /// The drawn dot's side.
    var dotDiameter: CGFloat { isCurrent ? Self.currentDiameter : Self.diameter }

    override func draw(_ dirtyRect: NSRect) {
        let d = dotDiameter
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        dotState.color.set()
        switch dotState {
        case .ok:
            NSBezierPath(ovalIn: r).fill()
        case .missing:
            let s = d * 0.62
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX, y: r.midY + s))
            p.line(to: NSPoint(x: r.midX + s, y: r.midY))
            p.line(to: NSPoint(x: r.midX, y: r.midY - s))
            p.line(to: NSPoint(x: r.midX - s, y: r.midY))
            p.close()
            p.fill()
        case .unknown, .notChecked:
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        case .notApplicable:
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.midY - 1, width: d, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// A view that runs the column's width.
class SetupWideView: NSView {}

/// A view centred in the column (forms, the footnote).
final class SetupCentered: SetupWideView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Rows in a grouped inset box: corner radius 10, the quaternary system
/// fill, hairline separators between rows inset to the rows' text.
final class SetupGroupBox: SetupWideView {
    static let cornerRadius: CGFloat = 10
    static let insets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    /// Where a row's text starts: past its 16-point mark and the gap.
    static let textInset: CGFloat = 12 + 16 + 8
    /// The width rows have for their content.
    static var rowWidth: CGFloat { SetupAssistant.columnWidth - insets.left - insets.right }
    /// The width a row's text has beside its mark.
    static var textWidth: CGFloat { rowWidth - 16 - 8 }
    private(set) var rows: [NSView] = []
    private(set) var separators: [SetupHairline] = []

    init(rows: [NSView], identifier id: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let id { identifier = .init(id) }
        self.rows = rows
        var previous: NSView?
        for (i, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            var top = row.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top)
            if let previous {
                let line = SetupHairline()
                addSubview(line)
                separators.append(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
                    line.trailingAnchor.constraint(equalTo: trailingAnchor),
                    line.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: Self.insets.bottom),
                ])
                top = row.topAnchor.constraint(equalTo: line.bottomAnchor, constant: Self.insets.top)
            }
            NSLayoutConstraint.activate([
                top,
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
            ])
            if i == rows.count - 1 { row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom).isActive = true }
            previous = row
        }
        if rows.isEmpty { heightAnchor.constraint(equalToConstant: 0).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Drawn rather than set on the layer, so snapshots (the page change,
    /// tests' captures) have it too.
    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = if #available(macOS 14.0, *) { .quaternarySystemFill } else { .quaternaryLabelColor }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
}

/// A one-pixel separator in the system's separator colour.
final class SetupHairline: NSView {
    private lazy var height = heightAnchor.constraint(equalToConstant: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        height.constant = 1 / max(1, window?.backingScaleFactor ?? 2)
    }
}
