// The device as Ycode draws it (device-hub.md §4.3, §14.2, §15.3–§15.4): the
// live screen with its rounded corners inside a band of even width in the
// tones `DeviceFrameGeometry.bandRings` gives — a classic iPhone's and an
// iPad's light line, #2C2C2C band and black; a foldable's mid grey and black
// (a watch: its case as `WatchCaseDrawing` gives it, `WatchCaseView`) — a foldable's
// cover with the folded half's edge as a darker grey step on its hinge side,
// and the side buttons as short bars on the edges, drawn flat. Clicking a button presses it
// on the device (down while the mouse is down, so a click is a press and a
// hold is a long press). For the iPhone Duo, Option-dragging on the frame
// sets the hinge (the pose slider, §4.4). A watch's Digital Crown is drawn
// rim-outlined with ridges on its outer third (Ycode's own drawing). Without
// bezels, or for visionOS, only the screen with its rounded corners is
// drawn.

#if os(macOS)
import AppKit
import QuartzCore
import YcodeDeviceModel

@MainActor
public final class DeviceFrameView: NSView {
    /// The live screen (touch, keys, scroll).
    public let screen = DeviceView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
    /// View points per device point.
    public var scale: CGFloat = 1 { didSet { if scale != oldValue { needsLayout = true; invalidateIntrinsicContentSize() } } }
    /// The colours follow it too (two tones, or a watch's one).
    public var geometry: DeviceFrameGeometry {
        didSet { if geometry != oldValue { needsLayout = true; needsDisplay = true; invalidateIntrinsicContentSize() } }
    }
    /// A frame button went down or up.
    public var onButton: ((DeviceFrameGeometry.ButtonKind, Bool) -> Void)?
    /// Option-drag on a foldable's frame: called with the horizontal
    /// distance from the press (view points) while dragging, then nil.
    public var onHingeDrag: ((CGFloat?) -> Void)?
    public var allowsHingeDrag = false

    private let bodyLayer = CAShapeLayer()
    /// The band's tones inside the body's (`DeviceFrameGeometry.bandRings`
    /// after the first): a classic iPhone's and an iPad's grey band and black,
    /// a foldable's black.
    private let ringLayers = [CAShapeLayer(), CAShapeLayer()]
    /// Buttons drawn flush with the body's edge, over the band (an iPad's volume).
    private let flushLayer = CAShapeLayer()
    private let stepLayer = CAShapeLayer()
    private let buttonsLayer = CAShapeLayer()
    private let ridgesLayer = CAShapeLayer()
    private let pressedLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    private let hingeLayer = CAShapeLayer()
    private let screenMask = CAShapeLayer()
    /// A watch's case, crown and buttons (council round 10 rows 250–251).
    private let watchCase = WatchCaseView(frame: .zero)
    private var pressed: DeviceFrameGeometry.ButtonKind?
    private var hingeStart: CGPoint?

    public init(geometry: DeviceFrameGeometry) {
        self.geometry = geometry
        super.init(frame: NSRect(origin: .zero, size: geometry.size))
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [stepLayer, buttonsLayer, pressedLayer, ridgesLayer, bodyLayer] + ringLayers + [flushLayer] { layer?.addSublayer(l) }
        addSubview(watchCase)
        addSubview(screen)
        screen.layer?.mask = screenMask
        for l in [shadeLayer, hingeLayer] { l.zPosition = 10; layer?.addSublayer(l) }
        bodyLayer.lineWidth = 1
        hingeLayer.lineWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Device")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The screen's rectangle on whole backing pixels, its size rounded to
    /// pixels rather than points: at a scale that shows one device pixel
    /// per display pixel (1.5 for a 3× device on a 2× display) the picture
    /// keeps exactly its pixel size, so it is drawn 1:1 and sharp
    /// (uikit-feel-ycode.md §8.4). `integral` could grow it by a point.
    public static func pixelAligned(_ r: CGRect, backing: CGFloat) -> CGRect {
        let k = max(backing, 1)
        return CGRect(x: (r.minX * k).rounded() / k, y: (r.minY * k).rounded() / k,
                      width: (r.width * k).rounded() / k, height: (r.height * k).rounded() / k)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: geometry.size.width * scale, height: geometry.size.height * scale) }

    /// Fill colours, the same in both appearances: a two-tone band (the
    /// shared `DeviceFrameGeometry.Palette`: black inside, mid grey outside,
    /// the step and the buttons grey), or for a watch a near-black band with
    /// a slightly lighter rim and buttons a step lighter.
    public override func updateLayer() {
        let rings = geometry.bandRings, twoTone = !rings.isEmpty
        bodyLayer.fillColor = rings.first.map { Self.color($0.color) } ?? NSColor(white: 0.07, alpha: 1).cgColor
        bodyLayer.strokeColor = twoTone ? nil : NSColor(white: 0.32, alpha: 1).cgColor
        for (i, l) in ringLayers.enumerated() {
            l.fillColor = rings.count > i + 1 ? Self.color(rings[i + 1].color) : nil
        }
        flushLayer.fillColor = Self.color(DeviceFrameGeometry.Palette.flushButton)
        stepLayer.fillColor = Self.color(DeviceFrameGeometry.Palette.step)
        buttonsLayer.fillColor = twoTone ? Self.color(DeviceFrameGeometry.Palette.button) : NSColor(white: 0.22, alpha: 1).cgColor
        buttonsLayer.strokeColor = twoTone ? nil : NSColor(white: 0.36, alpha: 1).cgColor
        buttonsLayer.lineWidth = 0.5
        pressedLayer.fillColor = twoTone ? Self.color(DeviceFrameGeometry.Palette.pressedButton) : NSColor(white: 0.55, alpha: 1).cgColor
        ridgesLayer.strokeColor = NSColor(white: 0.12, alpha: 1).cgColor
        ridgesLayer.fillColor = nil
        shadeLayer.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        hingeLayer.strokeColor = NSColor(white: 0.45, alpha: 1).cgColor
    }
    public override var wantsUpdateLayer: Bool { true }

    static func color(_ hex: UInt32) -> CGColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = scale, g = geometry
        func r(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s) }
        let hasBand = g.body != g.screen
        // A watch's case is its own view's drawing (row 250).
        let watch = g.drawsWatchCase
        watchCase.isHidden = !watch
        watchCase.frame = bounds
        watchCase.scale = s
        watchCase.geometry = watch ? g : nil
        watchCase.pressed = pressed
        bodyLayer.path = hasBand && !watch ? Self.path(r(g.body), radii: g.bodyRadii.scaled(by: s)) : nil
        let ringRects = g.bandRingRects
        for (i, l) in ringLayers.enumerated() {
            l.path = ringRects.count > i + 1 ? Self.path(r(ringRects[i + 1].rect), radii: ringRects[i + 1].radii.scaled(by: s)) : nil
        }
        stepLayer.path = g.hingeStep.map { Self.path(r($0), radii: g.hingeStepRadii.scaled(by: s)) }
        let buttons = CGMutablePath(), flush = CGMutablePath()
        for b in g.buttons where !watch {
            (b.flush ? flush : buttons).addPath(Self.path(r(b.rect), radii: b.flush ? CornerRadii(all: 0) : Self.buttonRadii(b, scale: s)))
        }
        buttonsLayer.path = buttons
        flushLayer.path = flush
        pressedLayer.path = watch ? nil : g.buttons.first { $0.kind == pressed }.map { Self.path(r($0.rect), radii: Self.buttonRadii($0, scale: s)) }
        ridgesLayer.path = watch ? nil : g.buttons.first { $0.kind == .crown }.map { Self.ridges(r($0.rect), scale: s) }
        ridgesLayer.lineWidth = max(0.5, 0.6 * s)
        let screenRect = Self.pixelAligned(r(g.screen), backing: window?.backingScaleFactor ?? 2)
        screen.frame = screenRect
        screenMask.frame = screen.bounds
        screenMask.path = Self.path(screen.bounds, radii: g.screenRadii.scaled(by: s))
        shadeLayer.path = g.shadedArea.map { Self.path(r($0), radii: CornerRadii(all: 0)) }
        if let h = g.hinge {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: h.from.x * s, y: h.from.y * s))
            p.addLine(to: CGPoint(x: h.to.x * s, y: h.to.y * s))
            hingeLayer.path = p
        } else {
            hingeLayer.path = nil
        }
        // The shade stays inside the screen's rounded corners.
        let shadeMask = CAShapeLayer()
        shadeMask.path = Self.path(screenRect, radii: g.screenRadii.scaled(by: s))
        shadeLayer.mask = g.shadedArea == nil ? nil : shadeMask
        CATransaction.commit()
    }

    /// A button's corner radii: a bar's are small, the crown's round its
    /// outer end.
    static func buttonRadii(_ b: DeviceFrameGeometry.Button, scale s: CGFloat) -> CornerRadii {
        b.kind == .crown ? CornerRadii(all: 3 * s) : CornerRadii(all: 1.5 * s)
    }

    /// The crown's ridges: short lines across its long side, on the part
    /// outside the body (the bar's outer two thirds).
    static func ridges(_ r: CGRect, scale s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let vertical = r.height >= r.width
        let count = 7
        for i in 1...count {
            let f = CGFloat(i) / CGFloat(count + 1)
            if vertical {
                let y = r.minY + f * r.height
                p.move(to: CGPoint(x: r.minX + r.width * 0.35, y: y))
                p.addLine(to: CGPoint(x: r.maxX - 1.2 * s, y: y))
            } else {
                let x = r.minX + f * r.width
                p.move(to: CGPoint(x: x, y: r.minY + r.height * 0.35))
                p.addLine(to: CGPoint(x: x, y: r.maxY - 1.2 * s))
            }
        }
        return p
    }

    /// A rounded rectangle with a radius per corner (each limited to half
    /// the shorter side).
    static func path(_ r: CGRect, radii: CornerRadii) -> CGPath {
        let lim = min(r.width, r.height) / 2
        func c(_ v: Double) -> CGFloat { min(lim, max(0, CGFloat(v))) }
        let tl = c(radii.topLeft), tr = c(radii.topRight), br = c(radii.bottomRight), bl = c(radii.bottomLeft)
        let p = CGMutablePath()
        // Flipped coordinates: minY is the top edge.
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + tr), radius: tr)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl)
        p.closeSubpath()
        return p
    }

    // MARK: Mouse

    /// The point in device points.
    private func devicePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / max(scale, 0.01), y: p.y / max(scale, 0.01))
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sup = superview else { return nil }
        let local = convert(point, from: sup)
        let d = CGPoint(x: local.x / max(scale, 0.01), y: local.y / max(scale, 0.01))
        if geometry.screen.contains(d) { return screen.hitTest(local) ?? screen }
        if geometry.button(at: d) != nil || geometry.body.contains(d) { return self }
        return nil
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        let d = devicePoint(event)
        if event.modifierFlags.contains(.option), allowsHingeDrag {
            hingeStart = convert(event.locationInWindow, from: nil)
            onHingeDrag?(0)
            return
        }
        guard let kind = geometry.button(at: d) else { return }
        pressed = kind
        needsLayout = true
        onButton?(kind, true)
    }

    public override func mouseDragged(with event: NSEvent) {
        if let start = hingeStart {
            onHingeDrag?(convert(event.locationInWindow, from: nil).x - start.x)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if hingeStart != nil {
            hingeStart = nil
            onHingeDrag?(nil)
            return
        }
        guard let kind = pressed else { return }
        pressed = nil
        needsLayout = true
        onButton?(kind, false)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    /// The tooltip names the button under the pointer.
    public override func mouseMoved(with event: NSEvent) {
        let kind = geometry.button(at: devicePoint(event))
        toolTip = kind?.title
    }
}
#endif
