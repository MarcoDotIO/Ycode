import AppKit
import YcodeIDECore

// Ycode's own tooltips on macOS (P-197, `specs/ui/control-states.md` §8 and
// §8.1). AppKit's tooltips have a fixed hold and fade and cannot swap one
// tooltip for the next after a hold, so Ycode draws its own:
// `ToolTipPresenter` follows the pointer, finds the control's text and
// shows it in a borderless panel on the `TooltipSession` timing shared
// with the Linux IDE: 1.56 s to appear, in one frame; a 350 ms hold after
// the pointer leaves, then a 460 ms linear fade; a move straight onto
// another control replaces it in one frame after the hold; a click, a
// drag, a key or a scroll removes it at once.
//
// Only one tooltip may show, so a control the presenter handles gives its
// text up to it: the moment the pointer reaches it (before AppKit's own
// delay can end), its `toolTip` (a segment's, a toolbar item's, a tooltip
// owner's rectangles) moves into the presenter's store on the control, and
// the control's own tooltip is left as "" (AppKit shows nothing for an
// empty tooltip; a nil set later still means "none"). The text stays the
// control's accessibility help, which VoiceOver reads. Text set again later (a
// toggle's "Hide …" / "Show …") is taken over the same way on the next
// hover. `ToolTipPresenter.text(of:)` reads a control's text either way.
// (Pushing AppKit's delay out with `NSInitialToolTipDelay` did not stop
// AppKit's tooltip on macOS 27: both showed.)

/// A control's tooltip texts once the presenter has taken them over.
@MainActor
final class AdoptedToolTips: NSObject {
    var text: String?
    var segments: [Int: String] = [:]
    nonisolated(unsafe) static var key = 0

    static func of(_ o: NSObject) -> AdoptedToolTips? { objc_getAssociatedObject(o, &key) as? AdoptedToolTips }

    static func store(on o: NSObject) -> AdoptedToolTips {
        if let s = of(o) { return s }
        let s = AdoptedToolTips()
        objc_setAssociatedObject(o, &key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }
}

/// One control with a tooltip: a view, and for a segmented control its
/// segment (-1 for the view's own tooltip; a text hash for a tooltip
/// owner such as the gutter).
public struct ToolTipControl: Hashable, Sendable {
    public var view: ObjectIdentifier
    public var part: Int
}

@MainActor
public final class ToolTipPresenter {
    public static let shared = ToolTipPresenter()

    public private(set) var session = TooltipSession<ToolTipControl>()
    /// The clock (tests set their own).
    public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    public private(set) var isInstalled = false
    /// The window the pointer was in.
    public private(set) weak var sourceWindow: NSWindow?
    /// The text drawn now and its opacity (what the panel shows; kept for
    /// tests, which never put the panel on screen).
    public private(set) var shownText: String?
    public private(set) var shownOpacity = 0.0

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var fadeTimer: Timer?
    private var pollTimer: Timer?
    private lazy var panel = ToolTipPanel()

    public init() {}

    /// Starts drawing Ycode's tooltips for the app (idempotent), and lets
    /// `window` report pointer moves.
    public func install(on window: NSWindow?) {
        window?.acceptsMouseMovedEvents = true
        guard !isInstalled else { return }
        isInstalled = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                               .leftMouseDragged, .rightMouseDragged, .keyDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }
        // Windows report moves only when asked; key windows are the ones
        // the pointer works in.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            nonisolated(unsafe) let window = n.object as? NSWindow
            MainActor.assumeIsolated { window?.acceptsMouseMovedEvents = true }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    func handle(_ e: NSEvent) {
        switch e.type {
        case .mouseMoved: pointerMoved(in: e.window, at: e.locationInWindow)
        default: dismiss()
        }
    }

    /// The pointer is at `p` (window coordinates) in `window`.
    public func pointerMoved(in window: NSWindow?, at p: NSPoint, time: Double? = nil) {
        let t = time ?? now()
        if let w = window, let hit = Self.toolTip(in: w, at: p, adopt: true) {
            sourceWindow = w
            session.pointer(over: .init(id: hit.control, text: hit.text, point: w.convertPoint(toScreen: p)), at: t)
        } else {
            session.pointerOverNothing(at: t)
        }
        update(at: t)
    }

    /// A click, a drag, a key or a scroll: the tooltip goes at once.
    public func dismiss(time: Double? = nil) {
        session.dismiss()
        update(at: time ?? now())
    }

    /// Moves the clock on (timers call it; tests too).
    public func tick(at t: Double) {
        session.advance(to: t)
        update(at: t)
    }

    // MARK: Drawing and timers

    func update(at t: Double) {
        session.advance(to: t)
        let v = session.visible(at: t)
        if let v {
            if shownText != v.tip.text { panel.setText(v.tip.text) }
            shownText = v.tip.text
            shownOpacity = v.opacity
            showPanel(at: v.tip.point, opacity: v.opacity, fadeStart: session.fadeStart, at: t)
        } else {
            shownText = nil
            shownOpacity = 0
            panel.orderOut(nil)
        }
        timer?.invalidate()
        timer = nil
        if let d = session.nextDeadline {
            timer = Timer.scheduledTimer(withTimeInterval: max(0, d - t), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.tick(at: $0.now()) } }
            }
        }
        // While a tip is shown or waiting, notice the pointer leaving the
        // window (no move reaches it then).
        pollTimer?.invalidate()
        pollTimer = nil
        switch session.state {
        case .waiting, .shown:
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollPointer() }
            }
        default: break
        }
    }

    private func pollPointer() {
        guard let w = sourceWindow, w.isVisible else { session.pointerOverNothing(at: now()); update(at: now()); return }
        if !w.frame.contains(NSEvent.mouseLocation) { session.pointerOverNothing(at: now()); update(at: now()) }
    }

    /// Whether the panel may go on screen: only for a window shown on a
    /// display (tests keep their windows off every display, so it never
    /// appears for them).
    var mayShow: Bool {
        guard let w = sourceWindow, w.isVisible, NSApp?.isActive == true else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(w.frame) }
    }

    private func showPanel(at point: NSPoint, opacity: Double, fadeStart: Double?, at t: Double) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard mayShow else { return }
        panel.place(pointer: point)
        if fadeStart == nil {
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }
        // Leaving: held, then a linear fade over what is left of 460 ms.
        guard let start = fadeStart else { return }
        func fade() {
            let left = max(0.01, start + TooltipTiming.fade - now())
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = left
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                panel.animator().alphaValue = 0
            }
        }
        panel.alphaValue = CGFloat(opacity)
        panel.orderFront(nil)
        if t >= start { fade() } else {
            fadeTimer = Timer.scheduledTimer(withTimeInterval: start - t, repeats: false) { _ in
                MainActor.assumeIsolated { fade() }
            }
        }
    }

    // MARK: Finding a control's tooltip

    public struct Hit: Equatable {
        public var control: ToolTipControl
        public var text: String
    }

    /// The tooltip of the control at `p` (window coordinates) in `window`,
    /// toolbar included: a segment's, a tooltip owner's (the gutter), the
    /// view's own or its toolbar item's, from the innermost view out.
    /// `adopt`: the control gives its text up to the presenter (AppKit then
    /// has none to show; accessibility keeps it).
    public static func toolTip(in window: NSWindow, at p: NSPoint, adopt: Bool = false) -> Hit? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let q = root.superview.map { $0.convert(p, from: nil) } ?? p
        var view = root.hitTest(q)
        let items = window.toolbar?.items ?? []
        while let v = view {
            let id = ObjectIdentifier(v)
            if let seg = v as? NSSegmentedControl, let i = segment(of: seg, atX: seg.convert(p, from: nil).x) {
                if adopt { adoptSegments(seg) }
                if let t = text(of: seg, segment: i) { return Hit(control: ToolTipControl(view: id, part: i), text: t) }
            }
            if let owner = v as? NSViewToolTipOwner {
                let t = owner.view(v, stringForToolTip: 0, point: v.convert(p, from: nil), userData: nil)
                // Its rectangles go: the presenter asks the owner itself.
                if adopt { v.removeAllToolTips() }
                if !t.isEmpty { return Hit(control: ToolTipControl(view: id, part: t.hashValue), text: t) }
            }
            if adopt { adoptToolTip(of: v) }
            if let t = text(of: v) { return Hit(control: ToolTipControl(view: id, part: -1), text: t) }
            if let item = items.first(where: { $0.view === v }) {
                if adopt { adoptToolTip(of: item) }
                if let t = text(of: item) { return Hit(control: ToolTipControl(view: id, part: -1), text: t) }
            }
            view = v.superview
        }
        return nil
    }

    // MARK: Taking tooltips over from AppKit

    /// A view's tooltip text: its `toolTip`, or the text the presenter took
    /// over from it. A taken-over control's `toolTip` is "" (AppKit shows
    /// nothing for it); nil means its owner cleared it since.
    public static func text(of v: NSView) -> String? { resolve(v.toolTip, AdoptedToolTips.of(v)?.text) }

    /// A segment's tooltip text, live or taken over.
    public static func text(of c: NSSegmentedControl, segment i: Int) -> String? {
        resolve(c.toolTip(forSegment: i), AdoptedToolTips.of(c)?.segments[i])
    }

    /// A toolbar item's tooltip text, live or taken over.
    public static func text(of item: NSToolbarItem) -> String? { resolve(item.toolTip, AdoptedToolTips.of(item)?.text) }

    static func resolve(_ live: String?, _ adopted: String?) -> String? {
        guard let live else { return nil }
        return live.isEmpty ? adopted.flatMap { $0.isEmpty ? nil : $0 } : live
    }

    /// Moves a view's `toolTip` into the store (leaving "", which AppKit
    /// does not show); it stays the view's help. A tooltip its owner has
    /// cleared since takes its help with it.
    static func adoptToolTip(of v: NSView) {
        guard let t = v.toolTip else {
            if let store = AdoptedToolTips.of(v), let old = store.text {
                if v.accessibilityHelp() == old { v.setAccessibilityHelp(nil) }
                store.text = nil
            }
            return
        }
        guard !t.isEmpty else { return }
        let store = AdoptedToolTips.store(on: v)
        keepHelp(t, replacing: store.text, on: v)
        store.text = t
        v.toolTip = ""
    }

    /// Moves a toolbar item's tooltip into the store; its view keeps it as help.
    static func adoptToolTip(of item: NSToolbarItem) {
        guard let t = item.toolTip, !t.isEmpty else { return }
        let store = AdoptedToolTips.store(on: item)
        if let v = item.view { keepHelp(t, replacing: store.text, on: v) }
        store.text = t
        item.toolTip = ""
    }

    /// Moves every segment's tooltip into the store; each segment's
    /// accessibility element keeps it as its help.
    static func adoptSegments(_ c: NSSegmentedControl) {
        let elements = segmentElements(c)
        for i in 0..<c.segmentCount {
            guard let t = c.toolTip(forSegment: i), !t.isEmpty else { continue }
            let store = AdoptedToolTips.store(on: c)
            if i < elements.count, elements[i].responds(to: #selector(NSAccessibilityElement.setAccessibilityHelp(_:))) {
                elements[i].perform(#selector(NSAccessibilityElement.setAccessibilityHelp(_:)), with: t)
            }
            store.segments[i] = t
            c.setToolTip("", forSegment: i)
        }
    }

    /// A segmented control's per-segment accessibility elements (under its
    /// cell's element).
    static func segmentElements(_ c: NSSegmentedControl) -> [NSObject] {
        var kids = (c.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
        if kids.count != c.segmentCount, kids.count == 1, let cell = kids.first {
            kids = ((cell as AnyObject).accessibilityChildren?() ?? []).compactMap { $0 as? NSObject }
        }
        return kids.count == c.segmentCount ? kids : []
    }

    /// Sets `t` as the view's help unless the view has help of its own
    /// (other than its tooltip or the text taken over before).
    static func keepHelp(_ t: String, replacing old: String?, on v: NSView) {
        let help = v.accessibilityHelp()
        if help == nil || help == t || help == v.toolTip || (old != nil && help == old) { v.setAccessibilityHelp(t) }
    }

    /// The segment under `x` (the control's coordinates): fixed widths as
    /// set, the rest sharing what is left.
    static func segment(of c: NSSegmentedControl, atX x: CGFloat) -> Int? {
        let n = c.segmentCount
        guard n > 0, x >= 0, x <= c.bounds.width else { return nil }
        let widths = (0..<n).map { c.width(forSegment: $0) }
        let fixed = widths.reduce(0, +)
        let free = widths.filter { $0 <= 0 }.count
        let share = free > 0 ? max(0, c.bounds.width - fixed) / CGFloat(free) : 0
        let actual = widths.map { $0 > 0 ? $0 : share }
        // Fixed widths may not fill the control: scale them to its width.
        let total = max(1, actual.reduce(0, +))
        let k = c.bounds.width / total
        var edge: CGFloat = 0
        for (i, w) in actual.enumerated() {
            edge += w * k
            if x < edge { return i }
        }
        return n - 1
    }
}

/// The tooltip's panel: one line of text in a dark box with a 1-pt
/// outline (§8: #444446 with #101012 in dark), its left edge at the
/// pointer's x and its top 18 pt below the pointer; it takes no input.
@MainActor
final class ToolTipPanel: NSPanel {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: CGFloat(Motion.tooltipLineHeight)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        ignoresMouseEvents = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        let box = ToolTipBox(frame: .zero)
        label.font = NSFont.toolTipsFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        box.addSubview(label)
        contentView = box
        setAccessibilityRole(.helpTag)
    }

    func setText(_ s: String) {
        label.stringValue = s
        label.sizeToFit()
        let h = CGFloat(Motion.tooltipLineHeight)
        let w = min(480, ceil(label.frame.width) + 16)
        label.frame = NSRect(x: 8, y: (h - label.frame.height) / 2, width: w - 16, height: label.frame.height)
        setContentSize(NSSize(width: w, height: h))
    }

    /// The pointer at `p` (screen): left edge at its x, top 18 below it,
    /// kept on its screen.
    func place(pointer p: NSPoint) {
        var o = NSPoint(x: p.x, y: p.y - CGFloat(TooltipTiming.belowPointer) - frame.height)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) })?.visibleFrame {
            o.x = min(max(o.x, s.minX), s.maxX - frame.width)
            if o.y < s.minY { o.y = p.y + 4 }
        }
        setFrameOrigin(o)
    }
}

/// The tooltip's box (§8): the dark fill and outline, light from the
/// system's colours (the light tooltip was not recorded, OPEN).
final class ToolTipBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        (dark ? NSColor(srgbHex: Motion.tooltipDarkFill) : NSColor.windowBackgroundColor).setFill()
        path.fill()
        (dark ? NSColor(srgbHex: Motion.tooltipDarkOutline) : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private extension NSColor {
    convenience init(srgbHex v: UInt32) {
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
