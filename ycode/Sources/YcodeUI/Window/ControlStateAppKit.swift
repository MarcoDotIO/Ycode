import AppKit
import QuartzCore
import YcodeIDECore

// B5-STATES (P-198, #58, #64): the macOS IDE's custom-drawn controls in the
// states of `specs/ui/control-states.md`, from the shared table
// (`ControlStates`, YcodeIDECore) the Linux IDE draws too. Hover is one
// frame in and out (no animation); held flat controls tint in one frame;
// no focus rings without Full Keyboard Access.

extension StateColor {
    /// The colour in sRGB.
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

@MainActor
enum ControlStatesAppKit {
    /// Whether `appearance` (the current drawing appearance by default) is dark.
    static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        (appearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// `kind`'s style for `view`'s appearance.
    static func style(_ kind: ControlKind, for view: NSView) -> ControlStateStyle {
        ControlStates.style(kind, dark: isDark(view.effectiveAppearance))
    }

    /// Focus rings show only with Full Keyboard Access (§6).
    static var showsFocusRings: Bool { ControlStates.showsFocusRing(fullKeyboardAccess: NSApp?.isFullKeyboardAccessEnabled ?? false) }
}

// MARK: - Hover bezel behind a control

/// A hover bezel drawn behind a control, in its superview (so it can reach
/// past the control's frame without covering its drawing): one frame on,
/// one frame off. The Settings card pop-ups use it (§4: a bezel over the
/// whole control, dark #232326 → #343436, light #F6F6F6 → #E4E4E4).
@MainActor
final class HoverBezelView: NSView {
    let kind: ControlKind
    /// How far the bezel reaches before the control, its height and radius.
    var lead: CGFloat
    var height: CGFloat
    var radius: CGFloat

    init(kind: ControlKind, lead: CGFloat, height: CGFloat, radius: CGFloat) {
        self.kind = kind
        self.lead = lead
        self.height = height
        self.radius = radius
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the bezel behind `control` (or hides it).
    func show(_ on: Bool, behind control: NSView) {
        guard on, let parent = control.superview else {
            isHidden = true
            return
        }
        if superview !== parent {
            removeFromSuperview()
            parent.addSubview(self, positioned: .below, relativeTo: control)
        }
        let f = control.frame
        frame = NSRect(x: f.minX - lead, y: f.midY - height / 2, width: f.width + lead, height: height).integral
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill = ControlStatesAppKit.style(kind, for: self).hoverFill else { return }
        fill.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// Hover tracking for a control that shows a `HoverBezelView`.
@MainActor
final class HoverBezelTracker: NSObject {
    let bezel: HoverBezelView
    weak var control: NSControl?
    private var area: NSTrackingArea?

    init(control: NSControl, kind: ControlKind, lead: CGFloat, height: CGFloat, radius: CGFloat) {
        self.control = control
        bezel = HoverBezelView(kind: kind, lead: lead, height: height, radius: radius)
        super.init()
        update()
    }

    /// Whether the bezel shows (tests).
    var isShown: Bool { !bezel.isHidden }

    /// Re-installs the tracking area (from `updateTrackingAreas`).
    func update() {
        guard let control else { return }
        if let area { control.removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        control.addTrackingArea(a)
        area = a
    }

    /// The pointer entered or left (tests call it too). A disabled control
    /// has no hover (§7).
    func hover(_ inside: Bool) {
        guard let control else { return }
        bezel.show(inside && control.isEnabled, behind: control)
    }

    @objc func mouseEntered(with event: NSEvent) { hover(true) }
    @objc func mouseExited(with event: NSEvent) { hover(false) }
}

// MARK: - Editor tab close button (§5)

/// An editor tab's × (18 × 18): under the pointer a 16-point round bezel
/// (dark #606060) that appears in one frame and fades out over ≈ 150 ms
/// when the pointer leaves; held #686868. Releasing outside does not close
/// the tab (the button's own tracking).
@MainActor
final class TabCloseButton: NSButton {
    private var area: NSTrackingArea?
    /// When the pointer left (nil: inside, or never entered).
    private var leftAt: CFTimeInterval?
    private(set) var isHovered = false
    private var fadeTimer: Timer?
    /// The clock (tests set it).
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// The pointer entered or left the button (tests call it too).
    func setHovered(_ on: Bool) {
        guard on != isHovered else { return }
        isHovered = on
        leftAt = on ? nil : now()
        fadeTimer?.invalidate()
        fadeTimer = nil
        if !on {
            // Redraw through the fade, then stop.
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fadeStep() }
            }
            RunLoop.main.add(t, forMode: .common)
            fadeTimer = t
        }
        needsDisplay = true
    }

    /// One frame of the fade; the timer stops when the bezel is gone.
    private func fadeStep() {
        needsDisplay = true
        if bezelOpacity == 0 {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    /// The bezel's opacity now: 1 under the pointer or held, fading after
    /// the pointer left.
    var bezelOpacity: Double {
        if isHovered || isHighlighted { return 1 }
        guard let leftAt else { return 0 }
        return EditorTabStates.closeBezelOpacity(afterLeave: now() - leftAt)
    }

    override func draw(_ dirtyRect: NSRect) {
        let o = bezelOpacity
        let s = ControlStatesAppKit.style(.editorTabClose, for: self)
        if o > 0, let fill = isHighlighted ? s.pressedFill : s.hoverFill {
            let d = CGFloat(EditorTabStates.closeBezelDiameter)
            let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
            fill.nsColor.withAlphaComponent(CGFloat(o)).setFill()
            NSBezierPath(ovalIn: r).fill()
        }
        super.draw(dirtyRect)
    }

    override var isHighlighted: Bool { didSet { needsDisplay = true } }
}

// MARK: - Sheet push buttons (§4)

/// A sheet's push button: the default button #0078FE, lighter while held
/// in dark (#2C85FD) and darker in light (#006CE5); the others dark #2F2F31
/// → #434345, light #EBEBEB → #D3D3D3. One frame, no hover, no grow.
final class StatePushButtonCell: NSButtonCell {
    /// The default button's look (else Cancel's).
    var isDefault: Bool { keyEquivalent == "\r" }

    static let radius: CGFloat = 6

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let dark = MainActor.assumeIsolated { ControlStatesAppKit.isDark(controlView.effectiveAppearance) }
        let kind: ControlKind = isDefault && isEnabled ? .sheetDefaultButton : .sheetCancelButton
        let s = ControlStates.style(kind, dark: dark)
        guard let fill = (isHighlighted && isEnabled ? s.pressedFill : s.restFill) else { return }
        fill.nsColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let t = NSMutableAttributedString(attributedString: title)
        let color: NSColor = !isEnabled ? .disabledControlTextColor : isDefault ? .white : .labelColor
        t.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: t.length))
        return super.drawTitle(t, withFrame: frame, in: controlView)
    }

    // No focus ring without Full Keyboard Access (§6).
    override var focusRingType: NSFocusRingType {
        get { MainActor.assumeIsolated { ControlStatesAppKit.showsFocusRings } ? .default : .none }
        set { super.focusRingType = newValue }
    }
}

/// Gives the push buttons of every sheet the measured states: each sheet,
/// as it becomes key, has its system push buttons' cells replaced by
/// `StatePushButtonCell` (title, key equivalent, target and action kept).
@MainActor
enum SheetButtonStates {
    private static var installed = false

    /// Watches for sheets (once per process).
    static func install() {
        guard !installed else { return }
        installed = true
        // swiftlint:disable:next discarded_notification_center_observer - lives as long as the app
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let w = NSApp.keyWindow, w.isSheet, let v = w.contentView else { return }
                adopt(in: v)
            }
        }
    }

    /// Replaces the cells of the system push buttons under `view`; returns
    /// how many it changed.
    @discardableResult
    static func adopt(in view: NSView) -> Int {
        var n = 0
        for v in view.subviews {
            if let b = v as? NSButton, adopt(b) { n += 1 } else { n += adopt(in: v) }
        }
        return n
    }

    /// Gives one system push button the states (false: not a plain push
    /// button, or already done).
    @discardableResult
    static func adopt(_ b: NSButton) -> Bool {
        guard let old = b.cell as? NSButtonCell, type(of: old) == NSButtonCell.self, b.bezelStyle == .push, b.isBordered,
              b.image == nil else { return false }
        let c = StatePushButtonCell(textCell: old.title)
        c.bezelStyle = old.bezelStyle
        c.setButtonType(.momentaryPushIn)
        c.keyEquivalent = old.keyEquivalent
        c.keyEquivalentModifierMask = old.keyEquivalentModifierMask
        c.font = old.font
        c.controlSize = old.controlSize
        c.alignment = old.alignment
        c.isEnabled = old.isEnabled
        c.tag = old.tag
        c.representedObject = old.representedObject
        let target = b.target, action = b.action
        b.cell = c
        b.target = target
        b.action = action
        b.needsDisplay = true
        return true
    }
}

// MARK: - Glass tab bar lens (§3)

/// The inspector's glass lens: mouse-down raises a lens (≈ 98 × 40, larger
/// than the bar) over the selected tab that glides to the pressed one and
/// follows the pointer along the bar while held; on release the tab under
/// it becomes selected. Releasing outside is not a cancel. No hover.
@MainActor
final class GlassTabLensController {
    /// The bar's tab buttons, left to right.
    var buttons: () -> [NSView] = { [] }
    /// The selected tab now.
    var selected: () -> Int = { 0 }
    /// Selects a tab (the release).
    var select: (Int) -> Void = { _ in }
    let bar: GlassTabLens.Bar
    private(set) var lens: GlassTabLens?
    /// The lens drawn (in the buttons' common superview's superview).
    let lensView = LensView()

    init(bar: GlassTabLens.Bar) {
        self.bar = bar
    }

    /// The tab under `x` in `buttons()`' superview's coordinates.
    func tab(atX x: CGFloat) -> Int? {
        let bs = buttons()
        guard let first = bs.first, let last = bs.last else { return nil }
        guard x >= first.frame.minX, x <= last.frame.maxX else { return nil }
        return bs.firstIndex { x >= $0.frame.minX && x <= $0.frame.maxX } ?? bs.indices.min { abs(bs[$0].frame.midX - x) < abs(bs[$1].frame.midX - x) }
    }

    /// Mouse-down on tab `i`.
    func press(_ i: Int) {
        var l = GlassTabLens(bar: bar, tabCount: buttons().count, selected: selected())
        l.press(i)
        lens = l
        place(over: l.origin ?? i, animated: false)
        place(over: i, animated: true)
    }

    /// The pointer moved while held (nil: off the bar's ends).
    func drag(_ i: Int?) {
        guard var l = lens else { return }
        let before = l.lensTab
        l.drag(i)
        lens = l
        if let t = l.lensTab, t != before { place(over: t, animated: true) }
    }

    /// The release: selects the tab under the lens.
    func release() {
        guard var l = lens else { return }
        let chosen = l.release()
        lens = nil
        lensView.isHidden = true
        if let chosen { select(chosen) }
    }

    /// Runs a press from `event` (mouse-down on tab `i`) to the release.
    func track(from event: NSEvent, tab i: Int) {
        press(i)
        guard let window = event.window, let parent = buttons().first?.superview else { return release() }
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            drag(tab(atX: parent.convert(e.locationInWindow, from: nil).x))
        }
        release()
    }

    private func place(over i: Int, animated: Bool) {
        let bs = buttons()
        guard bs.indices.contains(i), let parent = bs[i].superview, let host = parent.superview else { return }
        if lensView.superview !== host { host.addSubview(lensView, positioned: .above, relativeTo: nil) }
        let size = (lens ?? GlassTabLens(bar: bar, tabCount: bs.count, selected: i)).lensSize
        let c = host.convert(NSPoint(x: bs[i].frame.midX, y: bs[i].frame.midY), from: parent)
        let f = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        lensView.bar = bar
        lensView.isHidden = false
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = GlassTabLens.glide
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                lensView.animator().frame = f
            }
        } else {
            lensView.frame = f
        }
        lensView.needsDisplay = true
    }

    /// Clear glass with a thin bright rim; the held tint inside.
    final class LensView: NSView {
        var bar: GlassTabLens.Bar = .inspector
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let dark = ControlStatesAppKit.isDark(effectiveAppearance)
            let tint = GlassTabLens(bar: bar, tabCount: 1, selected: 0).tint(dark: dark, held: true)
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            tint.nsColor.withAlphaComponent(0.55).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(dark ? 0.35 : 0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// A tab of a glass tab bar: its press runs the bar's lens.
@MainActor
final class GlassTabButton: NSButton {
    weak var lens: GlassTabLensController?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let lens else { return super.mouseDown(with: event) }
        lens.track(from: event, tab: lens.buttons().firstIndex { $0 === self } ?? tag)
    }
}

// MARK: - Scroll edges (#58, glass-materials.md §3)

@MainActor
enum ScrollEdgeDrawing {
    /// Draws a 2-point divider in `rect` (its two rows, top first, in a
    /// view that is or is not flipped). With a theme of its own background
    /// colour the system separator over that background stays.
    static func drawDivider(_ rect: NSRect, flipped: Bool, colors: (top: StateColor, bottom: StateColor)) {
        let half = rect.height / 2
        let upper = NSRect(x: rect.minX, y: flipped ? rect.minY : rect.maxY - half, width: rect.width, height: half)
        let lower = NSRect(x: rect.minX, y: flipped ? rect.minY + half : rect.minY, width: rect.width, height: half)
        colors.top.nsColor.setFill()
        upper.fill(using: .copy)
        colors.bottom.nsColor.setFill()
        lower.fill(using: .copy)
    }

    /// The jump bar's divider (§3.1: the same at every scroll offset).
    static func drawJumpBarDivider(_ rect: NSRect, flipped: Bool) {
        guard EditorBlurVeil.applies else { return EditorVeil.drawSeparator(rect) }
        drawDivider(rect, flipped: flipped, colors: GlassMaterials.jumpBarDivider(dark: ControlStatesAppKit.isDark()))
    }

    /// The sticky line's separator (§3.2).
    static func drawStickySeparator(_ rect: NSRect, flipped: Bool) {
        guard EditorBlurVeil.applies else { return EditorVeil.drawSeparator(rect) }
        drawDivider(rect, flipped: flipped, colors: GlassMaterials.stickySeparator(dark: ControlStatesAppKit.isDark()))
    }
}

// MARK: - Toolbar (§2, §7)

/// The toolbar's segmented pairs (Run | Stop, Back | Forward): the system
/// glass gives their hover, held tint and grow (`control-states.md` §9);
/// a press on a disabled segment moves the window instead (§7: the press
/// falls through to the toolbar).
final class ToolbarSegmentedControl: NSSegmentedControl {
    /// The segment under `x` (view points).
    func segment(atX x: CGFloat) -> Int? {
        guard segmentCount > 0, x >= 0, x <= bounds.width else { return nil }
        let widths = (0..<segmentCount).map { width(forSegment: $0) }
        guard widths.allSatisfy({ $0 > 0 }) else { return min(segmentCount - 1, Int(x / (bounds.width / CGFloat(segmentCount)))) }
        let total = widths.reduce(0, +), pad = max(0, (bounds.width - total) / 2)
        var edge = pad
        for (i, w) in widths.enumerated() {
            edge += w
            if x < edge { return i }
        }
        return segmentCount - 1
    }

    /// Whether a press at `x` goes to the window (a disabled segment).
    func passesPressToWindow(atX x: CGFloat) -> Bool {
        guard let i = segment(atX: x) else { return false }
        return !isEnabled || !isEnabled(forSegment: i)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if passesPressToWindow(atX: x), let window {
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

/// The scheme › destination capsule's halves: only the hovered half shows a
/// bezel as wide as its content, 28 tall (dark #4B4B4B, light #EDEDED), one
/// frame in and out; each opens its chooser on mouse-down (B5-POPOVERS).
@MainActor
enum ToolbarControlStates {
    /// The association that keeps a half's tracker on the control itself,
    /// so the tracker lives exactly as long as its control (a table keyed by
    /// the control's identity kept trackers of freed controls, and a new
    /// pop-up at a reused address found one whose control was gone: no
    /// hover bezel).
    nonisolated(unsafe) private static var key = 0

    static func installHalfHover(_ controls: [NSControl]) {
        for c in controls where tracker(c) == nil {
            let t = HoverBezelTracker(control: c, kind: .toolbarChooserHalf, lead: 0,
                                      height: CGFloat(ControlStates.toolbarBezelHeight),
                                      radius: CGFloat(ControlStates.toolbarBezelHeight / 2))
            objc_setAssociatedObject(c, &key, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// A half's hover tracker (tests).
    static func tracker(_ c: NSControl) -> HoverBezelTracker? { objc_getAssociatedObject(c, &key) as? HoverBezelTracker }
}
