import AppKit
import YcodeIDECore

/// The layer over the whole workspace window, toolbar included, that
/// holds the merge confirmation and the merge sheet
/// (`specs/ide/merge-sheet.md` §1.2, §2, §10): the veil that darkens the
/// window, then the alert centred on it or the sheet below the toolbar.
/// It is the window frame's top subview, so it covers the toolbar and
/// takes every click while it is up (the window stays key).
@MainActor
public final class MergeOverlayView: NSView {
    /// Black over the window; its opacity animates (§1.2).
    public let veil = CALayer()
    public private(set) var alert: MergeAlertView?
    public private(set) var sheet: MergeSheetController?
    /// Where the toolbar ends, from the window's top (the sheet's top).
    public var toolbarBottom: CGFloat = 52
    /// Reduce Motion: the sheet fades only (tests set it).
    public var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// The window behind, drawn disabled while the overlay is up (§13.1).
    public private(set) var parentState: ModalParentDimming?
    /// The window buttons' circles (overlay coordinates): the veil leaves
    /// them uncovered and clicks there reach them (§13.1: minimize and zoom
    /// in colour above the veil, close disabled).
    public private(set) var windowButtonHoles: [NSRect] = []
    private let veilMask = CAShapeLayer()
    /// Called once the overlay has gone.
    var onClose: (() -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        veil.backgroundColor = NSColor.black.cgColor
        veil.opacity = 0
        veilMask.fillRule = .evenOdd
        veil.mask = veilMask
        layer?.addSublayer(veil)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    var palette: MergeSheetPalette { MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge) }

    /// The veil's full opacity in this appearance.
    public var veilOpacity: Float { Float(palette.veilOpacity) }

    public override func layout() {
        super.layout()
        windowButtonHoles = Self.windowButtonCircles(in: window, overlay: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veil.frame = bounds
        veilMask.frame = veil.bounds
        let path = CGMutablePath()
        path.addRect(veil.bounds)
        // The layer tree may not be flipped: map the holes into it.
        let flip = !(veil.superlayer?.isGeometryFlipped ?? false) && isFlipped
        for h in windowButtonHoles {
            path.addEllipse(in: flip ? CGRect(x: h.minX, y: bounds.height - h.maxY, width: h.width, height: h.height) : h)
        }
        veilMask.path = path
        CATransaction.commit()
        if let a = alert {
            let f = MergeSheetMetrics.alertFrame(window: (bounds.width, bounds.height), chooser: a.chooser != nil)
            a.frame = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
        }
        if let s = sheet {
            let f = MergeSheetMetrics.sheetFrame(window: (bounds.width, bounds.height), toolbarBottom: toolbarBottom)
            s.view.frame = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
        }
    }

    // Every click lands on the overlay while it is up (the window is modal
    // to it); clicks on the veil do nothing. The window buttons stay usable.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if windowButtonHoles.contains(where: { $0.contains(local) }) { return nil }
        return super.hitTest(point) ?? (frame.contains(point) ? self : nil)
    }

    /// The circles of `window`'s close, minimize and zoom buttons in the
    /// overlay's coordinates.
    static func windowButtonCircles(in window: NSWindow?, overlay: NSView) -> [NSRect] {
        guard let window else { return [] }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { t in
            guard let b = window.standardWindowButton(t), !b.isHidden, b.window === window else { return nil }
            let r = b.convert(b.bounds, to: overlay)
            let d = min(r.width, r.height)
            return NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        }
    }

    public override func mouseDown(with event: NSEvent) {}

    // MARK: Installing

    /// The overlay of `window`, installed over its frame view.
    static func install(in window: NSWindow) -> MergeOverlayView? {
        guard let frameView = window.contentView?.superview else { return nil }
        if let existing = frameView.subviews.compactMap({ $0 as? MergeOverlayView }).first { return existing }
        let o = MergeOverlayView(frame: frameView.bounds)
        frameView.addSubview(o, positioned: .above, relativeTo: nil)
        // The toolbar's bottom: the content layout rect's top.
        o.toolbarBottom = max(0, window.frame.height - window.contentLayoutRect.maxY)
        return o
    }

    // MARK: Veil

    /// Darkens (or clears) the window over `duration`, ease-out, drawing it
    /// disabled under the veil while it is on (§13.1).
    func setVeil(on: Bool, duration: Double) {
        if on {
            if parentState == nil, let w = window { parentState = ModalParentDimming(window: w) }
            parentState?.apply(duration: duration)
        } else {
            parentState?.restore(duration: duration)
        }
        let to: Float = on ? veilOpacity : 0
        let from = veil.presentation()?.opacity ?? veil.opacity
        veil.opacity = to
        guard duration > 0 else { veil.removeAnimation(forKey: "veil"); return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        veil.add(a, forKey: "veil")
    }

    // MARK: Alert

    /// Shows the merge confirmation (§1.2): the veil darkens over 255 ms
    /// and the alert is drawn at once; Merge turns accent once it is up.
    @discardableResult
    func showAlert(_ alert: MergeAlertView) -> MergeAlertView {
        self.alert?.removeFromSuperview()
        self.alert = alert
        addSubview(alert)
        needsLayout = true
        layoutSubtreeIfNeeded()
        setVeil(on: true, duration: MergeSheetMotion.veilIn)
        alert.mergeButton.isDefaultLook = false
        DispatchQueue.main.asyncAfter(deadline: .now() + MergeSheetMotion.veilIn) { [weak alert] in alert?.mergeButton.isDefaultLook = true }
        window?.makeFirstResponder(alert)
        return alert
    }

    /// Fades the alert out over 90 ms (§1.2, "Clicking Merge").
    func dismissAlert() {
        guard let a = alert else { return }
        alert = nil
        a.wantsLayer = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = MergeSheetMotion.alertOut
        a.layer?.opacity = 0
        a.layer?.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + MergeSheetMotion.alertOut) { a.removeFromSuperview() }
    }

    // MARK: Sheet

    /// Shows the merge sheet (§10): it fades in over 90 ms while sliding
    /// down 32 points over 200 ms; with Reduce Motion it fades only.
    func showSheet(_ sheet: MergeSheetController) {
        self.sheet = sheet
        let v = sheet.view
        v.wantsLayer = true
        addSubview(v)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if veil.opacity == 0 { setVeil(on: true, duration: MergeSheetMotion.veilIn) }
        animateSheet(in: true)
        window?.makeFirstResponder(sheet.canvas)
    }

    /// The sheet's appear (or, reversed, disappear) animations.
    func animateSheet(in appearing: Bool) {
        guard let layer = sheet?.view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        fade.duration = appearing ? MergeSheetMotion.sheetFade : MergeSheetMotion.sheetOutFade
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        fade.fillMode = .both
        layer.opacity = appearing ? 1 : 0
        layer.add(fade, forKey: "sheetFade")
        guard !reduceMotion else { layer.removeAnimation(forKey: "sheetSlide"); return }
        let c = MergeSheetMotion.slideCurve
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        // The frame view is not flipped below us: a layer moved up has a
        // larger y in a layer tree that is not flipped.
        let up = (layer.superlayer?.isGeometryFlipped ?? false) || isFlipped ? -MergeSheetMotion.slideDistance : MergeSheetMotion.slideDistance
        slide.fromValue = appearing ? up : 0
        slide.toValue = appearing ? 0 : up
        slide.duration = appearing ? MergeSheetMotion.sheetSlide : MergeSheetMotion.sheetOutSlide
        slide.timingFunction = CAMediaTimingFunction(controlPoints: Float(c.x1), Float(c.y1), Float(c.x2), Float(c.y2))
        slide.fillMode = .both
        layer.add(slide, forKey: "sheetSlide")
    }

    /// Closes the sheet (Ycode's choice, open question 3: the appearance
    /// reversed) and the veil, then removes the overlay.
    func close(animated: Bool = true) {
        let duration = animated ? max(MergeSheetMotion.sheetOutSlide, MergeSheetMotion.veilIn) : 0
        if animated, sheet != nil { animateSheet(in: false) }
        if let a = alert { a.removeFromSuperview(); alert = nil }
        setVeil(on: false, duration: animated ? MergeSheetMotion.veilIn : 0)
        let s = sheet
        sheet = nil
        let finish = { [weak self] in
            s?.view.removeFromSuperview()
            s?.removeFromParent()
            self?.removeFromSuperview()
            self?.onClose?()
        }
        if duration > 0 && window?.isVisible == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
        } else {
            finish()
        }
    }
}

extension NSAppearance {
    var isDarkMerge: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    /// An sRGB colour from a hex value (0xRRGGBB).
    convenience init(mergeHex hex: UInt32, alpha: CGFloat = 1) {
        let c = MergeSheetPalette.components(hex)
        self.init(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha)
    }
}

/// A push button drawn as the sheet's and the alert's buttons are
/// (§1.2, §9): a rounded fill, the label centred; the default one accent.
/// It is an accessibility button (§13.2): its label is its title, and
/// pressing it through accessibility clicks it.
@MainActor
public final class MergeButton: NSControl {
    public var title: String { didSet { needsDisplay = true } }
    /// Accent fill and white text.
    public var isDefaultLook = false { didSet { needsDisplay = true } }
    public var keyEquivalent = ""
    var fontSize: CGFloat = 13

    public init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override var isEnabled: Bool { didSet { needsDisplay = true } }

    var palette: MergeSheetPalette { MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge) }

    /// The fill and label colours as drawn now.
    public var colors: (fill: NSColor, label: NSColor) {
        let p = palette
        if !isEnabled { return (NSColor(mergeHex: p.disabledButton), NSColor(mergeHex: p.disabledButtonLabel)) }
        if isDefaultLook { return (NSColor(mergeHex: p.accent), .white) }
        return (NSColor(mergeHex: p.button), NSColor(mergeHex: p.buttonLabel))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let c = colors
        c.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: isDefaultLook ? .medium : .regular),
                                                    .foregroundColor: c.label]
        let s = NSAttributedString(string: title, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }

    /// The width the title needs at least.
    func fittingWidth(minimum: CGFloat) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return max(minimum, (w + 28).rounded())
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        performClick(nil)
    }

    public override func performClick(_ sender: Any?) {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    // MARK: Accessibility (§13.2)

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityTitle() -> String? { title }
    public override func accessibilityLabel() -> String? { title }
    public override func isAccessibilityEnabled() -> Bool { isEnabled }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled, action != nil else { return false }
        performClick(nil)
        return true
    }
}
