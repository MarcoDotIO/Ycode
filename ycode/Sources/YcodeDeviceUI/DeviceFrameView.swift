// The device as Ycode draws it (device-hub.md §4.3): the live screen with
// its rounded corners inside a dark band of even width whose outer corners
// are concentric with the screen's, and the side buttons as short bars on
// the edges, drawn flat with a slight shade. Clicking a button presses it
// on the device (down while the mouse is down, so a click is a press and a
// hold is a long press). For the iPhone Duo, Option-dragging on the frame
// sets the hinge (the pose slider, §4.4). Without bezels, or for visionOS,
// only the screen with its rounded corners is drawn.

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
    public var geometry: DeviceFrameGeometry { didSet { if geometry != oldValue { needsLayout = true; invalidateIntrinsicContentSize() } } }
    /// A frame button went down or up.
    public var onButton: ((DeviceFrameGeometry.ButtonKind, Bool) -> Void)?
    /// Option-drag on a foldable's frame: called with the horizontal
    /// distance from the press (view points) while dragging, then nil.
    public var onHingeDrag: ((CGFloat?) -> Void)?
    public var allowsHingeDrag = false

    private let bodyLayer = CAShapeLayer()
    private let buttonsLayer = CAShapeLayer()
    private let pressedLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    private let hingeLayer = CAShapeLayer()
    private let screenMask = CAShapeLayer()
    private var pressed: DeviceFrameGeometry.ButtonKind?
    private var hingeStart: CGPoint?

    public init(geometry: DeviceFrameGeometry) {
        self.geometry = geometry
        super.init(frame: NSRect(origin: .zero, size: geometry.size))
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [buttonsLayer, pressedLayer, bodyLayer] { layer?.addSublayer(l) }
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

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: geometry.size.width * scale, height: geometry.size.height * scale) }

    /// Fill colours: a near-black band with a slightly lighter rim, and
    /// buttons a step lighter (system greys, the same in both appearances).
    public override func updateLayer() {
        bodyLayer.fillColor = NSColor(white: 0.07, alpha: 1).cgColor
        bodyLayer.strokeColor = NSColor(white: 0.32, alpha: 1).cgColor
        buttonsLayer.fillColor = NSColor(white: 0.22, alpha: 1).cgColor
        buttonsLayer.strokeColor = NSColor(white: 0.36, alpha: 1).cgColor
        buttonsLayer.lineWidth = 0.5
        pressedLayer.fillColor = NSColor(white: 0.55, alpha: 1).cgColor
        shadeLayer.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        hingeLayer.strokeColor = NSColor(white: 0.45, alpha: 1).cgColor
    }
    public override var wantsUpdateLayer: Bool { true }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = scale, g = geometry
        func r(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s) }
        let hasBand = g.body != g.screen
        bodyLayer.path = hasBand ? Self.path(r(g.body), radii: g.bodyRadii.scaled(by: s)) : nil
        let buttons = CGMutablePath()
        for b in g.buttons { buttons.addPath(Self.path(r(b.rect), radii: CornerRadii(all: 1.5 * s))) }
        buttonsLayer.path = buttons
        pressedLayer.path = g.buttons.first { $0.kind == pressed }.map { Self.path(r($0.rect), radii: CornerRadii(all: 1.5 * s)) }
        let screenRect = r(g.screen).integral
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
