import AppKit
import QuartzCore
import YcodeIDECore

/// The source editor's scroll view. It adds the top bounce of
/// `editor-area.md` §D.4 and E.1 (checklist rows 40, 70): when momentum
/// would carry the text past the top, the text runs on and springs back
/// (`TopBounce`: about 8 % past the end of a 600-point flick, then a
/// critically damped return at ω 12.6 rad/s), instead of the system's
/// short elastic stop. Everything else is the system's, and the text
/// follows a gesture from its first event (no hold).
final class EditorScrollView: NSScrollView {
    let topBounce = EditorTopBounce()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = EditorClipView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func scrollWheel(with event: NSEvent) {
        if topBounce.handle(event, in: self) { return }
        if scrollByLineWheel(event) { return }
        let before = contentView.bounds.origin
        super.scrollWheel(with: event)
        followFirstEvent(event, from: before)
    }

    /// A gesture's first event moves the text by its own delta
    /// (`editor-area.md` E.1 item 1, checklist row 70: the content follows
    /// the gesture's first event, no hold). The system starts its gesture
    /// on it but leaves its delta out.
    func followFirstEvent(_ event: NSEvent, from before: NSPoint) {
        guard event.phase.contains(.began), event.momentumPhase.isEmpty, event.hasPreciseScrollingDeltas,
              contentView.bounds.origin == before else { return }
        let dy = event.scrollingDeltaY, dx = hasHorizontalScroller ? event.scrollingDeltaX : 0
        guard dx != 0 || dy != 0 else { return }
        let clip = contentView
        var origin = clip.bounds.origin
        origin.x -= dx
        origin.y += clip.isFlipped ? -dy : dy
        let kept = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard kept != clip.bounds.origin else { return }
        clip.scroll(to: kept)
        reflectScrolledClipView(clip)
    }

    /// Wheel events without precise deltas (a mouse wheel: line-based, no
    /// gesture phase) move the text by the points the event carries, 1:1,
    /// as a trackpad's phased scroll does (`editor-area.md` §D.3, checklist
    /// row 25: 600 of input moves 600). AppKit scaled them by its line
    /// scroll, about 1.75 times. Returns false for every other event.
    func scrollByLineWheel(_ event: NSEvent) -> Bool {
        guard let delta = Self.pointDelta(of: event) else { return false }
        let clip = contentView
        var origin = clip.bounds.origin
        origin.x -= delta.width
        origin.y += clip.isFlipped ? -delta.height : delta.height
        let kept = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        if kept != clip.bounds.origin {
            clip.scroll(to: kept)
            reflectScrolledClipView(clip)
        }
        return true
    }

    /// The point deltas of a line-based wheel event (nil for precise,
    /// phased or momentum events, which AppKit already applies 1:1).
    static func pointDelta(of event: NSEvent) -> CGSize? {
        guard event.type == .scrollWheel, !event.hasPreciseScrollingDeltas, event.phase.isEmpty, event.momentumPhase.isEmpty,
              let cg = event.cgEvent else { return nil }
        let dy = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        guard dx != 0 || dy != 0 else { return nil }
        return CGSize(width: dx, height: dy)
    }
}

/// The top bounce's state: the scroll velocity, and the spring while it
/// runs. The rest of the momentum sequence after the crossing is taken in;
/// its end goes to the system once the text is back at the top.
@MainActor
final class EditorTopBounce: NSObject {
    private var tracker = TopBounce.VelocityTracker()
    private var gestureVelocity = 0.0
    /// The overscroll when the bounce took over.
    private var startOverscroll = 0.0
    /// The crossing velocity of the running spring (nil: none).
    private(set) var velocity: Double?
    /// The spring's clock: the crossing, in display-link time.
    private var start: CFTimeInterval?
    private var link: CADisplayLink?
    /// Off screen (tests), a timer stands in for the display link.
    private var timer: Timer?
    private weak var scrollView: NSScrollView?
    /// The momentum after the crossing is swallowed until its end.
    private var swallowingMomentum = false
    private var heldEnd: NSEvent?
    /// The deepest overscroll of the last bounce, and each frame's
    /// overscroll (tests and measurement).
    private(set) var lastPeak: CGFloat = 0
    var onFrame: ((CGFloat) -> Void)?

    var isRunning: Bool { velocity != nil }

    /// The top of the document in the clip view's coordinates.
    static func top(of scrollView: NSScrollView) -> CGFloat { -scrollView.contentInsets.top }

    /// Off: the system's own elastic stop (before/after measurements).
    var isEnabled = true

    /// Returns true when the event was used here (the system must not see it).
    func handle(_ event: NSEvent, in scrollView: NSScrollView) -> Bool {
        guard isEnabled else { return false }
        let momentum = event.momentumPhase
        // A new touch ends the bounce where it is; the system takes over.
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            if isRunning { finish(at: nil) }
            swallowingMomentum = false
            heldEnd = nil
            tracker.reset()
        }
        if swallowingMomentum, !momentum.isEmpty {
            if momentum.contains(.ended) || momentum.contains(.cancelled) {
                swallowingMomentum = false
                if isRunning { heldEnd = event; return true }
                return false   // the system's own end, at the top
            }
            return true
        }
        guard event.hasPreciseScrollingDeltas else { return false }
        let delta = Double(event.scrollingDeltaY)
        // The momentum's own velocity from its first event on; until it
        // has two, the gesture's.
        if momentum.contains(.began) {
            gestureVelocity = tracker.velocity
            tracker.reset()
        }
        tracker.add(delta, at: event.timestamp)
        guard momentum.contains(.began) || momentum.contains(.changed), delta > 0 else { return false }
        let clip = scrollView.contentView
        let top = Self.top(of: scrollView)
        // A scroll that reaches or passes the top; the system's elastic stop
        // may already hold the text a little past it.
        guard clip.bounds.minY - CGFloat(delta) < top else { return false }
        let v = tracker.hasSample ? tracker.velocity : max(gestureVelocity, delta / 0.0167)
        begin(velocity: v, from: max(0, top - clip.bounds.minY), in: scrollView)
        return true
    }

    /// Starts the bounce `overscroll` points past the top with `velocity`
    /// (points per second).
    func begin(velocity v: Double, from overscroll: CGFloat = 0, in scrollView: NSScrollView) {
        self.scrollView = scrollView
        let visible = Double(scrollView.contentView.bounds.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom)
        velocity = TopBounce.effectiveVelocity(v, visibleHeight: visible)
        startOverscroll = Double(overscroll)
        lastPeak = overscroll
        swallowingMomentum = true
        start = nil
        set(overscroll: overscroll)
        link?.invalidate()
        timer?.invalidate()
        if scrollView.window?.isVisible == true, scrollView.window?.screen != nil {
            let l = scrollView.displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let interval = 1.0 / 120
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance(to: CACurrentMediaTime(), frame: interval) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp, frame: link.duration)
    }

    /// One frame at `now`; the crossing is one frame before the first.
    private func advance(to now: CFTimeInterval, frame: CFTimeInterval) {
        guard let v = velocity else { return }
        if start == nil { start = now - frame }
        let t = now - (start ?? now)
        let x = CGFloat(TopBounce.overscroll(from: startOverscroll, velocity: v, at: t))
        if TopBounce.isAtRest(from: startOverscroll, velocity: v, at: t) {
            finish(at: 0)
            return
        }
        lastPeak = max(lastPeak, x)
        set(overscroll: x)
    }

    /// Ends the bounce: at `overscroll` (0: back at the top), or where it is (nil).
    private func finish(at overscroll: CGFloat?) {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        velocity = nil
        start = nil
        if let overscroll { set(overscroll: overscroll) }
        if let end = heldEnd, let scrollView {
            heldEnd = nil
            (scrollView as? EditorScrollView)?.superScrollWheel(end)
        }
    }

    /// Moves the text `x` points below the top.
    private func set(overscroll x: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        (clip as? EditorClipView)?.allowedOverscroll = x
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: Self.top(of: scrollView) - x))
        scrollView.reflectScrolledClipView(clip)
        onFrame?(x)
    }
}

/// The editor's clip view: it lets the bounce hold the text past the top
/// (the system's clip view keeps its bounds inside the document).
final class EditorClipView: NSClipView {
    /// How far past the top the bounds may go (0: the system's rule).
    var allowedOverscroll: CGFloat = 0

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        if allowedOverscroll > 0, proposedBounds.minY < r.minY {
            r.origin.y = max(proposedBounds.minY, r.minY - allowedOverscroll)
        }
        return r
    }
}

extension EditorScrollView {
    /// Hands an event to the system's handling.
    func superScrollWheel(_ event: NSEvent) { super.scrollWheel(with: event) }
}
