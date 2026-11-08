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
    func addPathPart(title: String, symbol: String, first: Bool) {
        if !first { stack.addArrangedSubview(JumpBarChevronView()) }
        let icon = JumpBarIconView(symbol: symbol)
        if first, icon.image != nil, let prev = stack.arrangedSubviews.last {
            // The first icon's ink where the framed image's was (+71.5 in a
            // split pane, E.2 item 3).
            let cur = stack.customSpacing(after: prev)
            stack.setCustomSpacing((cur == NSStackView.useDefaultSpacing ? stack.spacing : cur) + Self.firstIconLeadIn, after: prev)
        }
        icon.tint = pathIconTint(symbol: symbol, title: title)
        if icon.image != nil { stack.addArrangedSubview(icon) }
        let label = pathLabel(title)
        stack.addArrangedSubview(label)
        pathState.parts.append(PathPart(icon: icon.image != nil ? icon : nil, title: label))
    }

    /// Adds the last item ("No Selection" or the symbol), in the path's
    /// colour (row 145).
    func addPathLast(_ title: String) {
        if !pathState.parts.isEmpty { stack.addArrangedSubview(JumpBarChevronView()) }
        let label = pathLabel(title)
        stack.addArrangedSubview(label)
        pathState.last = label
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
        let model = parts.map { JumpBarPathLayout.Part(icon: $0.icon.map { Double($0.inkWidth) }, title: Double($0.title.ink.width)) }
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

    /// The ink gap between two neighbouring path views (H.4).
    static func inkGap(after a: NSView, before b: NSView) -> CGFloat {
        typealias L = JumpBarPathLayout
        switch (a, b) {
        case (is JumpBarIconView, is FadingTruncationLabel): return CGFloat(L.iconToTitle)
        case (is JumpBarChevronView, is JumpBarIconView): return CGFloat(L.chevronToIcon)
        case (is JumpBarChevronView, _): return CGFloat(L.chevronToTitle)
        default: return CGFloat(L.titleToChevron)
        }
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
    var parts: [JumpBar.PathPart] = []
    var last: FadingTruncationLabel?
    var fit: JumpBarPathLayout.Fit?

    func reset() {
        parts = []
        last = nil
        fit = nil
    }
}

/// A path icon whose frame is its ink (so the stack spaces ink to ink):
/// the symbol at the path's 11 points (its ink about the reference's 12–13
/// wide), drawn in the component's tint.
final class JumpBarIconView: NSView {
    /// The icons' point size: the path's text size.
    static let pointSize: CGFloat = 11
    let symbol: String
    let image: NSImage?
    /// The image's ink inside its own rectangle (points).
    let inkBox: NSRect
    var tint: NSColor? { didSet { needsDisplay = true } }
    var inkWidth: CGFloat { inkBox.width }

    init(symbol: String) {
        self.symbol = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.pointSize, weight: .regular))
        inkBox = image.map { Self.ink(of: $0, symbol: symbol) } ?? .zero
        super.init(frame: NSRect(x: 0, y: 0, width: inkBox.width, height: image?.size.height ?? 0))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: inkBox.width, height: image?.size.height ?? NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let size = image.size
        let r = NSRect(x: -inkBox.minX, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        // The tint (its own alpha too) through the symbol's shape.
        let tinted = NSImage(size: size, flipped: false) { rect in
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

/// The path's chevron: a 1-point stroke 2 wide and 6 tall in the secondary
/// label colour (Ycode's drawing of the reference's 2-wide chevron).
final class JumpBarChevronView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: JumpBarPathLayout.chevronWidth, height: 14))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: JumpBarPathLayout.chevronWidth, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let w = CGFloat(JumpBarPathLayout.chevronWidth), h = CGFloat(JumpBarPathLayout.chevronHeight)
        let midY = bounds.midY
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0.5, y: midY + h / 2))
        p.line(to: NSPoint(x: w - 0.5, y: midY))
        p.line(to: NSPoint(x: 0.5, y: midY - h / 2))
        p.lineWidth = 1
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        p.stroke()
    }
}
