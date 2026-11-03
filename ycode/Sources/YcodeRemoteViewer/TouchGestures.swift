// Mouse → touches (display-stream.md §7, hid-input.md §8), shared by the
// viewers: a press and drag is one finger; with the multi-touch modifier
// (Option on a Mac, Alt on Linux) two fingers mirrored about the screen's
// center (pinch, rotate); with it and Shift two fingers moving together
// (two-finger pan); a scroll is a one-finger drag that ends after a pause.
// Coordinates come in the view's points (origin top-left of the shown
// screen picture) and leave in device points of the panel shown, as the
// stream's touch messages take them (§5.1; a turned panel is mapped back
// with DisplayPanelState.nativePoint).

import Foundation
import YcodeDisplayStream

public struct ViewPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { (self.x, self.y) = (x, y) }
}

public enum TouchGesture: Equatable, Sendable {
    case one
    case pinch
    case pan(dx: Double, dy: Double)

    /// The gesture a press starts with these modifiers.
    public static func starting(at p: ViewPoint, center c: ViewPoint, multiTouch: Bool, shift: Bool) -> TouchGesture {
        guard multiTouch else { return .one }
        guard shift else { return .pinch }
        return .pan(dx: 2 * c.x - 2 * p.x, dy: 2 * c.y - 2 * p.y)
    }

    /// The fingers' view positions for a pointer at `p`.
    public func positions(_ p: ViewPoint, center c: ViewPoint) -> [ViewPoint] {
        switch self {
        case .one: [p]
        case .pinch: [p, ViewPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)]
        case .pan(let dx, let dy): [p, ViewPoint(x: p.x + dx, y: p.y + dy)]
        }
    }
}

/// The touch state of one device screen.
public struct TouchMapper: Sendable {
    /// The screen picture's size in view points.
    public var viewWidth: Double
    public var viewHeight: Double
    /// The shown picture's size in device points (turned for a turned panel).
    public var pointWidth: Double
    public var pointHeight: Double
    /// The panel shown (a foldable's turned panel), nil: no turn.
    public var panel: DisplayPanelState?

    public private(set) var gesture: TouchGesture?
    public private(set) var last = ViewPoint(x: 0, y: 0)
    public private(set) var scrollFinger: ViewPoint?
    /// Client seconds of the last scroll step (the front end ends a scroll
    /// after `scrollIdle` without one).
    public private(set) var lastScroll: Double = 0
    public static let scrollIdle = 0.15

    public init(viewWidth: Double, viewHeight: Double, pointWidth: Double, pointHeight: Double, panel: DisplayPanelState? = nil) {
        (self.viewWidth, self.viewHeight, self.pointWidth, self.pointHeight, self.panel) = (viewWidth, viewHeight, pointWidth, pointHeight, panel)
    }

    public var center: ViewPoint { ViewPoint(x: viewWidth / 2, y: viewHeight / 2) }
    public var isTouching: Bool { gesture != nil || scrollFinger != nil }

    /// A view point → device points of the panel (clamped to the screen).
    public func devicePoint(_ p: ViewPoint) -> (x: Double, y: Double) {
        guard viewWidth > 0, viewHeight > 0 else { return (0, 0) }
        let x = min(max(p.x, 0), viewWidth) / viewWidth * pointWidth
        let y = min(max(p.y, 0), viewHeight) / viewHeight * pointHeight
        if let panel, panel.quarterTurns != 0 { return panel.nativePoint(shownX: x, shownY: y) }
        return (x, y)
    }

    public func contacts(_ points: [ViewPoint], _ phase: TouchPhase) -> [TouchContact] {
        points.enumerated().map { i, p in
            let d = devicePoint(p)
            return TouchContact(finger: UInt8(i), phase: phase, x: Float(d.x), y: Float(d.y))
        }
    }

    /// Whether a view point is on the screen picture.
    public func contains(_ p: ViewPoint) -> Bool { p.x >= 0 && p.y >= 0 && p.x <= viewWidth && p.y <= viewHeight }

    // MARK: Pointer

    public mutating func down(_ p: ViewPoint, multiTouch: Bool, shift: Bool) -> [TouchContact] {
        var out = endScroll() ?? []
        let g = TouchGesture.starting(at: p, center: center, multiTouch: multiTouch, shift: shift)
        gesture = g
        last = p
        out = contacts(g.positions(p, center: center), .began)
        return out
    }

    public mutating func drag(_ p: ViewPoint) -> [TouchContact]? {
        guard let g = gesture else { return nil }
        last = p
        return contacts(g.positions(p, center: center), .moved)
    }

    public mutating func up(_ p: ViewPoint) -> [TouchContact]? {
        guard let g = gesture else { return nil }
        gesture = nil
        last = p
        return contacts(g.positions(p, center: center), .ended)
    }

    /// Ends whatever is down (focus lost): cancelled fingers.
    public mutating func cancel() -> [TouchContact]? {
        if let g = gesture {
            gesture = nil
            return contacts(g.positions(last, center: center), .cancelled)
        }
        return endScroll()
    }

    /// The indicator dots for the fingers (multi-touch only), in view points.
    public func indicator(hover p: ViewPoint?, multiTouch: Bool) -> [ViewPoint] {
        if let g = gesture { return g == .one ? [] : g.positions(last, center: center) }
        guard multiTouch, let p, contains(p) else { return [] }
        return TouchGesture.pinch.positions(p, center: center)
    }

    // MARK: Scroll wheel → one finger

    /// A scroll step at `p` by (dx, dy) view points at client time `now`
    /// (seconds): began (first step) and moved contacts.
    public mutating func scroll(at p: ViewPoint, dx: Double, dy: Double, now: Double) -> [[TouchContact]] {
        guard gesture == nil else { return [] }
        var out: [[TouchContact]] = []
        if scrollFinger == nil {
            scrollFinger = p
            out.append(contacts([p], .began))
        }
        var f = scrollFinger!
        f.x = min(max(f.x + dx, 0), viewWidth)
        f.y = min(max(f.y + dy, 0), viewHeight)
        scrollFinger = f
        lastScroll = now
        out.append(contacts([f], .moved))
        return out
    }

    /// The scroll's finger lifts (nil: none down).
    public mutating func endScroll() -> [TouchContact]? {
        guard let f = scrollFinger else { return nil }
        scrollFinger = nil
        return contacts([f], .ended)
    }

    /// Ends a scroll idle since `scrollIdle`.
    public mutating func endIdleScroll(now: Double) -> [TouchContact]? {
        guard scrollFinger != nil, now - lastScroll >= Self.scrollIdle else { return nil }
        return endScroll()
    }

    /// A watch's crown delta for a wheel step (watchos.md §5.1, §12: content
    /// moving up, i.e. scrolling down a list, is positive); `precise` for
    /// pixel deltas (trackpads), else a wheel's line counts 10 points.
    public static func crownDelta(scrollingDeltaY: Double, precise: Bool, factor: Double = 2) -> Double {
        -scrollingDeltaY * (precise ? 1 : 10) * factor
    }
}
