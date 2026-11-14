import AppKit
import YcodeIDECore

/// The coding assistant button's glyph (`fidelity-council.md` round 9,
/// row 214; `AssistantButtonGlyph`): Ycode's own outlined speech bubble
/// with a plus, 18 × 17 points, painted with one angular gradient centred
/// on the bubble, clockwise from the top through the measured stops. The
/// gradient is drawn here as thin wedges of the shared model's colours,
/// clipped to the stroked outline and plus, so the macOS and Linux
/// toolbars paint the same colours at the same angles.
@MainActor
enum ToolbarGradientGlyph {
    typealias G = AssistantButtonGlyph

    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// A shared path as a Core Graphics path in the glyph's box (y down).
    static func path(_ elements: [G.Element]) -> CGPath {
        let p = CGMutablePath()
        for e in elements {
            switch e {
            case let .move(x, y): p.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): p.addLine(to: CGPoint(x: x, y: y))
            case let .quad(x, y, cx, cy): p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// The bubble's outline, stroked at `scale` pixels per point (one pixel
    /// at 1x, row 239).
    static func outlinePath(scale: CGFloat) -> CGPath {
        path(G.bubble).copy(strokingWithWidth: CGFloat(G.bubbleStroke(scale: Double(scale))), lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// The plus, stroked (round caps).
    static var plusPath: CGPath {
        path(G.plus).copy(strokingWithWidth: CGFloat(G.plusStroke), lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// Paints the glyph into `ctx` whose user space is the glyph's box with
    /// y down: the outline clipped, then a wedge per degree in the angular
    /// gradient's colour at its middle; the plus clipped and filled with
    /// its own linear gradient, top to bottom (round 10, row 239).
    static func paint(in ctx: CGContext, dark: Bool) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, (hypot(t.a, t.b) * 4).rounded() / 4)
        ctx.saveGState()
        ctx.addPath(outlinePath(scale: scale))
        ctx.clip(using: .winding)
        // The clip's edges are antialiased; the wedges inside it are not, so
        // a pixel the outline covers whole is painted at full colour.
        ctx.setShouldAntialias(false)
        let (cx, cy) = G.center
        let r = 2 * max(G.width, G.height)
        for d in 0..<360 {
            let a0 = Double(d) - 0.6, a1 = Double(d) + 1.6   // overlapping, so no seams show
            let c = G.color(atDegrees: Double(d) + 0.5, dark: dark)
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
            // Clockwise from the top, y down: x = sin, y = -cos.
            func point(_ deg: Double) -> CGPoint {
                let t = deg * .pi / 180
                return CGPoint(x: cx + r * sin(t), y: cy - r * cos(t))
            }
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: point(a0))
            ctx.addLine(to: point(a1))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(plusPath)
        ctx.clip(using: .winding)
        let (top, bottom) = G.plusInkY
        let c0 = G.plusColor(atY: top), c1 = G.plusColor(atY: bottom)
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorSpace: space, colorComponents: [c0.r, c0.g, c0.b, 1, c1.r, c1.g, c1.b, 1].map { CGFloat($0) }, locations: [0, 1], count: 2) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: G.plusCenter.x, y: top), end: CGPoint(x: G.plusCenter.x, y: bottom),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    /// The glyph as a non-template image (18 × 18), drawn for the
    /// appearance and the pixel scale it is drawn in.
    static func newConversation() -> NSImage {
        let image = NSImage(size: NSSize(width: G.width, height: G.height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            paint(in: ctx, dark: dark)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "New Conversation"
        return image
    }
}

/// The toolbar's New Conversation button (rows 214, 238): the glyph centred in a
/// 36-point view the toolbar wraps in its glass circle; under the pointer
/// the light capsule darkens to #F2F2F2 (an overlay on the system's
/// glass), the dark one does not change; pressed, Ycode's own state (a
/// little darker). Sends `action` on a click inside.
@MainActor
final class AssistantToolbarButton: NSControl {
    typealias G = AssistantButtonGlyph
    private(set) var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private(set) var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    let glyph = ToolbarGradientGlyph.newConversation()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: G.diameter, height: G.diameter))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: G.diameter),
            heightAnchor.constraint(equalToConstant: G.diameter),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Conversation")
        toolTip = "New Conversation"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: G.diameter, height: G.diameter) }
    override var isFlipped: Bool { true }

    /// Row 238: the hover starts within a frame of the pointer entering,
    /// however it arrived: the tracking area's entered and moved events,
    /// any mouse-moved event the app receives (a posted one too, through a
    /// local monitor), and a check of where the pointer is when the button
    /// joins a window, the window becomes key or the tracking areas are
    /// rebuilt (the pointer already inside).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .assumeInside],
                               owner: self)
        addTrackingArea(t)
        tracking = t
        syncHoverWithPointer()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(toWindowPoint: event.locationInWindow) }

    /// The pointer's hover (tracking areas; tests set it directly).
    func setHovered(_ on: Bool) { isHovered = on }

    /// The pointer is at `p` in the window: hovered while it is inside the
    /// circle's square.
    func pointerMoved(toWindowPoint p: NSPoint) {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return setHovered(false) }
        setHovered(bounds.contains(convert(p, from: nil)))
    }

    /// Where the pointer is now (tests replace it): the window's own idea
    /// of it, outside the event stream.
    var pointerLocation: () -> NSPoint? = { nil }

    /// Takes the hover from where the pointer is now.
    func syncHoverWithPointer() {
        guard let w = window else { return setHovered(false) }
        pointerMoved(toWindowPoint: pointerLocation() ?? w.mouseLocationOutsideOfEventStream)
    }

    private var moveMonitor: Any?
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        moveMonitor = nil
        keyObserver = nil
        guard let w = window else { return setHovered(false) }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let w = self.window else { return }
                if e.window === w { self.pointerMoved(toWindowPoint: e.locationInWindow) } else if e.type == .mouseMoved { self.syncHoverWithPointer() }
            }
            return e
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHoverWithPointer() }
        }
        syncHoverWithPointer()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        // Track until the button comes up, as a system button does.
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp {
                isPressed = false
                if inside { performClick(nil) }
                return
            }
            isPressed = inside
        }
        isPressed = false
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    /// The overlay's opacity on the system's capsule for the current state.
    var overlayOpacity: Double {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isPressed { return G.pressedOverlayOpacity(dark: dark) }
        return isHovered ? G.hoverOverlayOpacity(dark: dark) : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let o = overlayOpacity
        if o > 0 {
            NSColor(white: 0, alpha: CGFloat(o)).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        // Painted straight into the view's context (not through a cached
        // image), so at 1x its sides land on whole pixels (row 239).
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: ((bounds.width - CGFloat(G.width)) / 2).rounded(), y: ((bounds.height - CGFloat(G.height)) / 2).rounded())
        ToolbarGradientGlyph.paint(in: ctx, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        ctx.restoreGState()
    }
}
