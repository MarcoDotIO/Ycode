// The device screen: shows the stream image at the device's aspect ratio
// and turns mouse, trackpad, and keyboard input into touches, keys, and
// gestures (display-stream.md §5, §7).
//
//   click / drag            one finger
//   option + drag           two fingers mirrored about the screen center (pinch, rotate)
//   option + shift + drag   two fingers moving together (two-finger pan)
//   scroll wheel / trackpad one-finger drag that follows the scroll
//   keys (without command)  hardware keyboard usages
//   keys with command       also sent while Capture Keyboard is on
//                           (device-hub.md §4.6); holding Escape for a
//                           second ends the capture

#if os(macOS)
import AppKit
import QuartzCore
import YcodeDisplayStream

@MainActor
public protocol DeviceInputHandler: AnyObject {
    func sendTouch(_ contacts: [TouchContact], label: String?)
    func sendKey(usage: UInt16, down: Bool, label: String?)
}

public final class DeviceView: NSView {
    public weak var input: DeviceInputHandler?
    /// The device's size in points (touch coordinates).
    public var pointSize = CGSize(width: 466, height: 678)
    private let indicator = CAShapeLayer()

    /// Capture Keyboard (device-hub.md §4.6): command shortcuts go to the
    /// device too. Holding Escape for `escapeHold` seconds ends it.
    public var capturesKeyboard = false {
        didSet { if !capturesKeyboard { escapeTimer?.invalidate(); escapeTimer = nil } }
    }
    /// Called when holding Escape ended the capture.
    public var onCaptureCancelled: (() -> Void)?
    public static let escapeHold: TimeInterval = 1
    private var escapeTimer: Timer?

    public var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            if let image, image.width != oldValue?.width { updateFilter() }
            CATransaction.commit()
        }
    }

    /// Trilinear filtering makes Core Animation build mipmaps of every new
    /// frame (an 11 MB image at full resolution); it is used only when the
    /// image is shrunk by more than half, where bilinear would alias.
    private func updateFilter() {
        guard let image, bounds.width > 0 else { return }
        let backing = window?.backingScaleFactor ?? 2
        let shrink = CGFloat(image.width) / (bounds.width * backing)
        layer?.minificationFilter = shrink > 2 ? .trilinear : .linear
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        indicator.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
        indicator.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        indicator.lineWidth = 1
        layer?.addSublayer(indicator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func layout() {
        super.layout()
        indicator.frame = bounds
        updateFilter()
    }

    // MARK: Coordinates

    /// A view point → device points (clamped to the screen).
    public func devicePoint(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let x = min(max(p.x, 0), bounds.width) / bounds.width * pointSize.width
        let y = min(max(p.y, 0), bounds.height) / bounds.height * pointSize.height
        return CGPoint(x: x, y: y)
    }

    /// A device point → a view point.
    public func viewPoint(device p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / pointSize.width * bounds.width, y: p.y / pointSize.height * bounds.height)
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    // MARK: Touch from the mouse

    private enum Gesture {
        case one
        case pinch
        case pan(offset: CGVector)
    }

    private var gesture: Gesture?
    private var lastLocation = CGPoint.zero

    private func positions(for p: CGPoint, gesture: Gesture) -> [CGPoint] {
        switch gesture {
        case .one: [p]
        case .pinch: [p, CGPoint(x: 2 * center.x - p.x, y: 2 * center.y - p.y)]
        case .pan(let o): [p, CGPoint(x: p.x + o.dx, y: p.y + o.dy)]
        }
    }

    private func contacts(_ points: [CGPoint], phase: TouchPhase) -> [TouchContact] {
        points.enumerated().map { i, p in
            let d = devicePoint(p)
            return TouchContact(finger: UInt8(i), phase: phase, x: Float(d.x), y: Float(d.y))
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endScroll()
        let p = convert(event.locationInWindow, from: nil)
        lastLocation = p
        let flags = event.modifierFlags
        let g: Gesture
        if flags.contains(.option) && flags.contains(.shift) {
            let mirror = CGPoint(x: 2 * center.x - p.x, y: 2 * center.y - p.y)
            g = .pan(offset: CGVector(dx: mirror.x - p.x, dy: mirror.y - p.y))
        } else if flags.contains(.option) {
            g = .pinch
        } else {
            g = .one
        }
        gesture = g
        input?.sendTouch(contacts(positions(for: p, gesture: g), phase: .began), label: "touch down")
        showIndicator(positions(for: p, gesture: g), pressed: true)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let g = gesture else { return }
        let p = convert(event.locationInWindow, from: nil)
        lastLocation = p
        input?.sendTouch(contacts(positions(for: p, gesture: g), phase: .moved), label: nil)
        showIndicator(positions(for: p, gesture: g), pressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        guard let g = gesture else { return }
        let p = convert(event.locationInWindow, from: nil)
        input?.sendTouch(contacts(positions(for: p, gesture: g), phase: .ended), label: nil)
        gesture = nil
        updateHoverIndicator(flags: event.modifierFlags, at: p)
    }

    public override func mouseMoved(with event: NSEvent) {
        lastLocation = convert(event.locationInWindow, from: nil)
        updateHoverIndicator(flags: event.modifierFlags, at: lastLocation)
    }

    public override func mouseExited(with event: NSEvent) { if gesture == nil { showIndicator([], pressed: false) } }

    private func updateHoverIndicator(flags: NSEvent.ModifierFlags, at p: CGPoint) {
        guard gesture == nil else { return }
        if flags.contains(.option) && bounds.contains(p) {
            showIndicator([p, CGPoint(x: 2 * center.x - p.x, y: 2 * center.y - p.y)], pressed: false)
        } else {
            showIndicator([], pressed: false)
        }
    }

    private func showIndicator(_ points: [CGPoint], pressed: Bool) {
        let path = CGMutablePath()
        if points.count > 1 {
            let r: CGFloat = pressed ? 14 : 11
            for p in points { path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.path = path
        CATransaction.commit()
    }

    /// Ends whatever touch is down (the window lost focus).
    public func cancelInput() {
        if let g = gesture {
            input?.sendTouch(contacts(positions(for: lastLocation, gesture: g), phase: .cancelled), label: nil)
            gesture = nil
        }
        endScroll()
        releaseKeys()
        showIndicator([], pressed: false)
    }

    /// Releases every key and modifier held down in the guest.
    private func releaseKeys() {
        for code in pressedModifiers {
            if let u = KeyMap.usage[code] { input?.sendKey(usage: u, down: false, label: nil) }
        }
        pressedModifiers.removeAll()
        for u in pressedKeys { input?.sendKey(usage: u, down: false, label: nil) }
        pressedKeys.removeAll()
    }

    // MARK: Scrolling → a one-finger drag

    private var scrollFinger: CGPoint?
    private var scrollIdle: Timer?

    public override func scrollWheel(with event: NSEvent) {
        if !event.momentumPhase.isEmpty {
            // The guest makes its own momentum from the drag's speed.
            endScroll()
            return
        }
        if event.phase.contains(.began) || scrollFinger == nil {
            endScroll()
            beginScroll(at: convert(event.locationInWindow, from: nil))
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        scrollBy(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endScroll()
        } else {
            scrollIdle?.invalidate()
            scrollIdle = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in self?.endScroll() }
        }
    }

    public func beginScroll(at p: CGPoint) {
        guard gesture == nil else { return }
        scrollFinger = p
        input?.sendTouch(contacts([p], phase: .began), label: "scroll")
    }

    public func scrollBy(dx: CGFloat, dy: CGFloat) {
        guard var p = scrollFinger else { return }
        p.x = min(max(p.x + dx, 0), bounds.width)
        p.y = min(max(p.y + dy, 0), bounds.height)
        scrollFinger = p
        input?.sendTouch(contacts([p], phase: .moved), label: nil)
    }

    public func endScroll() {
        scrollIdle?.invalidate()
        scrollIdle = nil
        guard let p = scrollFinger else { return }
        scrollFinger = nil
        input?.sendTouch(contacts([p], phase: .ended), label: nil)
    }

    // MARK: Keyboard

    private var pressedModifiers = Set<UInt16>()
    private var pressedKeys = Set<UInt16>()

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && !capturesKeyboard { super.keyDown(with: event); return }
        if capturesKeyboard, event.keyCode == 0x35, !event.isARepeat {
            // Escape: sent as usual; held, it ends the capture.
            escapeTimer?.invalidate()
            escapeTimer = Timer.scheduledTimer(withTimeInterval: Self.escapeHold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.escapeHeld() }
            }
        }
        guard !event.isARepeat, let u = KeyMap.usage[event.keyCode] else { return }
        pressedKeys.insert(u)
        input?.sendKey(usage: u, down: true, label: "key")
    }

    /// While capturing, command shortcuts are the device's (not the menus').
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturesKeyboard, window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    private func escapeHeld() {
        escapeTimer = nil
        guard capturesKeyboard else { return }
        capturesKeyboard = false
        releaseKeys()
        onCaptureCancelled?()
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 0x35 { escapeTimer?.invalidate(); escapeTimer = nil }
        guard let u = KeyMap.usage[event.keyCode], pressedKeys.contains(u) else { return }
        pressedKeys.remove(u)
        input?.sendKey(usage: u, down: false, label: nil)
    }

    public override func flagsChanged(with event: NSEvent) {
        updateHoverIndicator(flags: event.modifierFlags, at: lastLocation)
        let code = event.keyCode
        guard let u = KeyMap.usage[code] else { return }
        if u == 0x39 {
            // Caps lock reports its state, not the key: press and release.
            input?.sendKey(usage: u, down: true, label: nil)
            input?.sendKey(usage: u, down: false, label: nil)
            return
        }
        // Command stays with the Mac (menus) unless the keyboard is captured.
        if (u == 0xE3 || u == 0xE7) && !capturesKeyboard { return }
        if pressedModifiers.contains(code) {
            pressedModifiers.remove(code)
            input?.sendKey(usage: u, down: false, label: nil)
        } else {
            pressedModifiers.insert(code)
            input?.sendKey(usage: u, down: true, label: nil)
        }
    }
}
#endif
