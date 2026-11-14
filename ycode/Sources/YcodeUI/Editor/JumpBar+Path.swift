import AppKit
import YcodeIDECore

/// The jump bar's path laid out by ink (`editor-area.md` H.4, checklist
/// rows 143–145; `JumpBarPathLayout`): icon to title 6, title to chevron 7,
/// chevron (2 wide) to the next icon 10.5, to an icon-less title 9.5; when
/// the bar is too narrow the leading titles go (their icons stay), then
/// the file's title is cut with a fade, and the last item stays whole
/// until then. The Linux jump bar (`ycode-ide/EditorArea.swift`) follows
/// the same model.
extension JumpBar {
    /// One path component's views.
    struct PathPart {
        let icon: JumpBarIconView?
        let title: FadingTruncationLabel
    }

    /// Adds a component's views (after a chevron when it is not the first).
    func addPathPart(title: String, symbol: String, first: Bool, role: JumpBarPathLayout.IconRole = .file) {
        if !first { stack.addArrangedSubview(JumpBarChevronView(active: isActivePane)) }
        // The navigator's glyphs, smaller (council round 9, row 211): the
        // file's line-art logo or JSON glyph in its type's tint, a group's
        // folder, the project's Ycode mark (`FileGlyphs.jumpBarGlyph`).
        let glyph = FileGlyphs.jumpBarGlyph(symbol: symbol, role: role, fileName: pathState.fileName)
        let icon = glyph.flatMap { g -> JumpBarIconView? in
            if g == .ycodeMark {
                let side = CGFloat(FileGlyphs.jumpBarBox(g).width)
                return JumpBarIconView(logo: NavigatorRowImages.ycodeMark(side: side), symbol: symbol, role: role)
            }
            return NavigatorRowImages.glyph(g, box: FileGlyphs.jumpBarBox(g)).map {
                let v = JumpBarIconView(glyph: $0, symbol: symbol, role: role)
                v.glyphIcon = g
                return v
            }
        } ?? JumpBarIconView(symbol: symbol, role: role)
        if first, icon.image != nil, let prev = stack.arrangedSubviews.last {
            // The first icon's ink where the framed image's was (+71.5 in a
            // split pane, E.2 item 3).
            let cur = stack.customSpacing(after: prev)
            stack.setCustomSpacing((cur == NSStackView.useDefaultSpacing ? stack.spacing : cur) + Self.firstIconLeadIn, after: prev)
        }
        icon.tint = glyph.map { pathGlyphTint($0, fileName: pathState.fileName) } ?? pathIconTint(symbol: symbol, title: title)
        if icon.image != nil { stack.addArrangedSubview(icon) }
        let label = pathLabel(title)
        stack.addArrangedSubview(label)
        pathState.parts.append(PathPart(icon: icon.image != nil ? icon : nil, title: label))
    }

    /// Adds the last item ("No Selection" or the symbol), in the path's
    /// colour (row 145).
    func addPathLast(_ title: String) {
        if !pathState.parts.isEmpty { stack.addArrangedSubview(JumpBarChevronView(active: isActivePane)) }
        let label = pathLabel(title)
        stack.addArrangedSubview(label)
        pathState.last = label
    }

    /// A glyph's tint in the path: the jump bar's tint for its type
    /// (`FileGlyphs.jumpBarGlyphTint`; Markdown #5A8095 / #B7D5EB) in the
    /// focused pane, grey in the other.
    func pathGlyphTint(_ g: NavigatorRowIcon, fileName: String?) -> NSColor? {
        guard isActivePane else { return .secondaryLabelColor }
        return FileGlyphs.jumpBarGlyphTint(g, fileName: fileName).map(NavigatorRowImages.color) ?? .controlAccentColor
    }

    /// The first icon's ink starts this far past the spacing before it.
    static let firstIconLeadIn: CGFloat = 1.5

    /// Where the path's ink may end, in the bar's coordinates: 23 inside the
    /// bar's edge, or 10.5 before the issue stepper when it shows.
    var pathInkLimit: CGFloat {
        let edge = bounds.width - CGFloat(JumpBarPathLayout.trailingInset)
        guard !issueStack.arrangedSubviews.isEmpty, issueStack.frame.width > 0 else { return edge }
        return min(edge, issueStack.frame.minX - CGFloat(JumpBarPathLayout.stepperGap))
    }

    /// Fits the path to the bar: hides, cuts and spaces its views. Returns
    /// whether anything changed (the stack then lays out again).
    @discardableResult func applyPathFit() -> Bool {
        let parts = pathState.parts
        guard !parts.isEmpty || pathState.last != nil else { return false }
        guard let firstView = parts.first.map({ $0.icon ?? $0.title }) ?? pathState.last, bounds.width > 0 else { return false }
        let firstInk = convert(firstView.frame, from: firstView.superview).minX + Self.leadPad(of: firstView)
        let room = Double(pathInkLimit - firstInk)
        let model = parts.map {
            JumpBarPathLayout.Part(icon: $0.icon.map { Double($0.slotWidth) }, title: Double($0.title.ink.width), initial: Double($0.title.initialInk))
        }
        let fit = JumpBarPathLayout.fit(parts: model, last: pathState.last.map { Double($0.ink.width) }, room: room)
        guard fit != pathState.fit else { return false }
        pathState.fit = fit
        for (p, w) in zip(parts, fit.titles) { p.title.show(inkWidth: w.map { CGFloat($0) }) }
        pathState.last?.show(inkWidth: fit.last.map { CGFloat($0) })
        // The spacing between the visible views, ink to ink.
        let views = stack.arrangedSubviews.filter { !$0.isHidden }
        guard let start = views.firstIndex(of: firstView) else { return true }
        for (a, b) in zip(views[start...], views[(start + 1)...]) {
            stack.setCustomSpacing(Self.inkGap(after: a, before: b) - Self.trailPad(of: a) - Self.leadPad(of: b), after: a)
        }
        return true
    }

    /// The ink gap between two neighbouring path views (H.4); a wide
    /// (active pane's) chevron takes its extra point from the gap after it
    /// (round 9, row 217).
    static func inkGap(after a: NSView, before b: NSView) -> CGFloat {
        typealias L = JumpBarPathLayout
        let base: CGFloat
        switch (a, b) {
        case (is JumpBarIconView, is FadingTruncationLabel): base = CGFloat(L.iconToTitle)
        case (is JumpBarChevronView, is JumpBarIconView): base = CGFloat(L.chevronToIcon)
        case (is JumpBarChevronView, _): base = CGFloat(L.chevronToTitle)
        default: base = CGFloat(L.titleToChevron)
        }
        func extra(_ v: NSView) -> CGFloat { ((v as? JumpBarChevronView)?.inkWidth ?? CGFloat(L.chevronWidth)) - CGFloat(L.chevronWidth) }
        return base - extra(a)
    }

    /// From a view's alignment rect to its ink, at the leading and the
    /// trailing end (the stack spaces alignment rects).
    static func leadPad(of v: NSView) -> CGFloat { (v as? FadingTruncationLabel)?.ink.minX ?? 0 }
    static func trailPad(of v: NSView) -> CGFloat {
        guard let l = v as? FadingTruncationLabel else { return 0 }
        return l.inkCut != nil ? 0 : max(0, l.alignmentWidth - l.ink.maxX)
    }

    /// The path's ink extents in the bar's coordinates, left to right
    /// (tests): each visible view's ink.
    var pathInk: [(view: NSView, minX: CGFloat, maxX: CGFloat)] {
        stack.arrangedSubviews.filter { !$0.isHidden && ($0 is JumpBarIconView || $0 is JumpBarChevronView || $0 is FadingTruncationLabel) }.map { v in
            let f = convert(v.frame, from: v.superview)
            let a = f.minX + v.alignmentRectInsets.left
            if let l = v as? FadingTruncationLabel { return (v, a + l.ink.minX, a + l.ink.minX + (l.inkCut ?? l.ink.width)) }
            return (v, f.minX, f.maxX)
        }
    }
}

/// What the path holds and how it was fitted.
final class JumpBarPathState {
    /// The file the path ends at (its name with the extension): its
    /// component shows the navigator's icon for it, a language's logo
    /// (council round 8, row 200).
    var fileName: String?
    var parts: [JumpBar.PathPart] = []
    var last: FadingTruncationLabel?
    var fit: JumpBarPathLayout.Fit?

    func reset() {
        parts = []
        last = nil
        fit = nil
    }
}

/// A path icon whose frame is its slot (so the stack spaces slot to slot):
/// the symbol at the path's 11 points, drawn in the component's tint, its
/// ink scaled down to the reference's width for its role when wider (the
/// project's 13, a group's 12.5, the file's 11.5; `editor-area.md` I.5,
/// row 180) and centred in the slot.
final class JumpBarIconView: NSView {
    /// The icons' point size: the path's text size.
    static let pointSize: CGFloat = 11
    let symbol: String
    let image: NSImage?
    /// The image's ink inside its own rectangle (points).
    let inkBox: NSRect
    let role: JumpBarPathLayout.IconRole
    var tint: NSColor? { didSet { needsDisplay = true } }
    /// A picture drawn in its own colours (not tinted).
    let isLogo: Bool
    /// One of Ycode's glyphs, drawn at its own size (not scaled to the role).
    let isGlyph: Bool
    /// The glyph's icon: drawn from its vector drawing on the pixel grid
    /// (round 10, row 246; `GlyphPixelGrid`).
    var glyphIcon: NavigatorRowIcon? { didSet { needsDisplay = true } }
    /// The slot's width (the frame) and the ink drawn in it.
    var slotWidth: CGFloat { image == nil ? 0 : CGFloat(JumpBarPathLayout.iconSlot(role)) }
    var inkWidth: CGFloat { isGlyph ? inkBox.width : min(inkBox.width, CGFloat(JumpBarPathLayout.iconInk(role))) }
    /// The image's scale: its ink fits the role's width.
    var drawScale: CGFloat { isGlyph || inkBox.width <= 0 ? 1 : min(1, CGFloat(JumpBarPathLayout.iconInk(role)) / inkBox.width) }

    init(symbol: String, role: JumpBarPathLayout.IconRole = .file) {
        self.symbol = symbol
        self.role = role
        isLogo = false
        isGlyph = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.pointSize, weight: .regular))
        inkBox = image.map { Self.ink(of: $0, symbol: symbol) } ?? .zero
        super.init(frame: NSRect(x: 0, y: 0, width: image == nil ? 0 : CGFloat(JumpBarPathLayout.iconSlot(role)), height: image?.size.height ?? 0))
        configure()
    }

    /// A picture drawn in its own colours (the project's Ycode mark), its
    /// whole square counted as ink, so it is drawn at the role's ink width.
    init(logo: NSImage, symbol: String, role: JumpBarPathLayout.IconRole) {
        self.symbol = symbol
        self.role = role
        isLogo = true
        isGlyph = false
        image = logo
        inkBox = NSRect(origin: .zero, size: logo.size)
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(JumpBarPathLayout.iconSlot(role)), height: logo.size.height))
        configure()
    }

    /// One of Ycode's glyphs (`FileGlyphs`), already at its jump-bar box:
    /// drawn at that size, centred in the slot, in the tint.
    init(glyph: NSImage, symbol: String, role: JumpBarPathLayout.IconRole) {
        self.symbol = symbol
        self.role = role
        isLogo = false
        isGlyph = true
        image = glyph
        inkBox = NSRect(origin: .zero, size: glyph.size)
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(JumpBarPathLayout.iconSlot(role)), height: glyph.size.height))
        configure()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: slotWidth, height: image?.size.height ?? NSView.noIntrinsicMetric) }

    /// The ink's extent in the view (its slot): centred.
    var inkRange: (minX: CGFloat, maxX: CGFloat) {
        let w = inkBox.width * drawScale
        let x = (bounds.width - w) / 2
        return (x, x + w)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let k = drawScale
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)
        let r = NSRect(x: inkRange.minX - inkBox.minX * k, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        // The Ycode mark keeps its colours; dimmed in a pane without
        // focus, as the other icons go grey there.
        if isLogo {
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: tint == .secondaryLabelColor ? 0.55 : 1)
            return
        }
        if let g = glyphIcon, let d = FileGlyphs.jumpBarDrawing(g) {
            GlyphPixelGrid.draw(d, in: NSRect(x: r.minX, y: r.minY, width: CGFloat(d.width), height: CGFloat(d.height)),
                                color: tint ?? .labelColor, flipped: isFlipped)
            return
        }
        // The tint (its own alpha too) through the symbol's shape.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            (self.tint ?? .labelColor).setFill()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: r)
    }

    /// The columns of a symbol image that hold ink, measured once per symbol
    /// at 4x.
    static func ink(of image: NSImage, symbol: String) -> NSRect {
        if let r = inkCache[symbol] { return r }
        let scale: CGFloat = 4
        let size = image.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSRect(origin: .zero, size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = w, maxX = -1
        for x in 0..<w {
            for y in 0..<h where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                break
            }
        }
        let r = maxX < minX ? NSRect(origin: .zero, size: size)
            : NSRect(x: CGFloat(minX) / scale, y: 0, width: CGFloat(maxX - minX + 1) / scale, height: size.height)
        inkCache[symbol] = r
        return r
    }

    @MainActor static var inkCache: [String: NSRect] = [:]
}

/// The path's chevron: a 1.25-point stroke 2 wide (3 in the active pane,
/// I.5) and 10 tall (round 10, row 247), #808080 / #DEDEDE in the active
/// pane, the secondary label colour in the other (Ycode's drawing of the
/// reference's chevron).
final class JumpBarChevronView: NSView {
    let inkWidth: CGFloat

    init(active: Bool = false) {
        inkWidth = CGFloat(JumpBarPathLayout.chevronInk(active: active))
        super.init(frame: NSRect(x: 0, y: 0, width: inkWidth, height: 14))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: inkWidth, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let w = inkWidth, h = CGFloat(JumpBarPathLayout.chevronHeight), s = CGFloat(JumpBarPathLayout.chevronStroke)
        let midY = bounds.midY
        let p = NSBezierPath()
        p.move(to: NSPoint(x: s / 2, y: midY + h / 2))
        p.line(to: NSPoint(x: w - s / 2, y: midY))
        p.line(to: NSPoint(x: s / 2, y: midY - h / 2))
        p.lineWidth = s
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        Self.color(active: inkWidth > CGFloat(JumpBarPathLayout.chevronWidth)).setStroke()
        p.stroke()
    }
}
