import Foundation

/// Tooltip timing for both IDEs (P-197, `specs/ui/control-states.md` §8 and
/// §8.1, council round 12): a toolbar or IDE control's tooltip appears
/// 1.56 s after the pointer arrives, in one frame; after the pointer leaves
/// it stays 350 ms, then fades linearly over 460 ms; a pointer that moves
/// straight onto another control with a tooltip replaces it in one frame
/// once the 350 ms hold is over (no fade, no new delay); a click, a drag or
/// a key removes it at once.
///
/// These supersede `Motion.tooltipDelay`, `Motion.tooltipHold` and
/// `Motion.tooltipFade` (B5-MOTION's catalogue still carries the earlier
/// 1.6 s / 290 ms / 310 ms values).
public enum TooltipTiming {
    /// From the pointer's arrival to the tooltip (toolbar and IDE controls).
    public static let delay = 1.56
    /// An editor tab's rich tooltip (§8 table; not re-measured in round 12).
    public static let tabDelay = 1.1
    /// After the pointer leaves: how long the tooltip stays.
    public static let hold = 0.350
    /// Then: the linear fade to nothing.
    public static let fade = 0.460
    /// Placement: the tooltip's left edge at the pointer's x, its top this
    /// far below the pointer (§8).
    public static let belowPointer = 18.0

    /// The opacity `t` seconds after the pointer left the control.
    public static func opacity(afterLeave t: Double) -> Double {
        if t <= hold { return 1 }
        return max(0, 1 - (t - hold) / fade)
    }

    /// When the tooltip has gone after the pointer left.
    public static var gone: Double { hold + fade }
}

/// One window's (or app's) tooltip as a state machine over time, so both
/// IDEs and the tests share §8.1's rules. `ID` names a control (a view, a
/// segment); times are seconds on any monotonic clock.
public struct TooltipSession<ID: Hashable & Sendable>: Sendable {
    public struct Tip: Equatable, Sendable {
        public var id: ID
        public var text: String
        /// The pointer where the tip was asked for (the tooltip's left edge
        /// and, 18 pt below it, its top).
        public var point: CGPoint

        public init(id: ID, text: String, point: CGPoint) {
            self.id = id
            self.text = text
            self.point = point
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// The pointer rests on a control: its tip appears at `at`.
        case waiting(Tip, at: Double)
        /// Shown, the pointer still on its control.
        case shown(Tip)
        /// The pointer left at `left`: held, then fading.
        case leaving(Tip, left: Double)
        /// The pointer moved from `old` (left at `left`) onto another
        /// control: `new` replaces it at `left + hold`.
        case swapping(old: Tip, new: Tip, left: Double)
    }

    public private(set) var state: State = .idle
    public var delay: Double
    public var hold: Double
    public var fade: Double

    public init(delay: Double = TooltipTiming.delay, hold: Double = TooltipTiming.hold, fade: Double = TooltipTiming.fade) {
        self.delay = delay
        self.hold = hold
        self.fade = fade
    }

    /// The pointer is over control `tip.id` at `t` (call it on every move;
    /// a move within the same control changes nothing). `delay` overrides
    /// the session's (an editor tab's 1.1 s).
    public mutating func pointer(over tip: Tip, at t: Double, delay d: Double? = nil) {
        advance(to: t)
        switch state {
        case .waiting(let w, _) where w.id == tip.id, .shown(let w) where w.id == tip.id:
            return
        case .swapping(_, let new, _) where new.id == tip.id:
            return
        case .leaving(let old, _) where old.id == tip.id:
            // Back onto the same control while it is still drawn.
            state = .shown(old)
            return
        case .shown(let old):
            // Straight from one control to the next (no leave in between).
            state = .swapping(old: old, new: tip, left: t)
        case .leaving(let old, let left), .swapping(let old, _, let left):
            state = .swapping(old: old, new: tip, left: left)
        case .idle, .waiting:
            state = .waiting(tip, at: t + (d ?? delay))
        }
        advance(to: t)
    }

    /// The pointer is over no control with a tooltip at `t`.
    public mutating func pointerOverNothing(at t: Double) {
        advance(to: t)
        switch state {
        case .waiting: state = .idle
        case .shown(let tip): state = .leaving(tip, left: t)
        case .swapping(let old, _, let left): state = .leaving(old, left: left)
        case .idle, .leaving: break
        }
    }

    /// A click, a drag or a key: any tooltip goes at once, held or fading.
    public mutating func dismiss() { state = .idle }

    /// Moves the state on to time `t`.
    public mutating func advance(to t: Double) {
        switch state {
        case .waiting(let tip, let at) where t >= at - 1e-9:
            state = .shown(tip)
        case .leaving(_, let left) where t >= left + hold + fade - 1e-9:
            state = .idle
        case .swapping(_, let new, let left) where t >= left + hold - 1e-9:
            state = .shown(new)
        default: break
        }
    }

    /// What is drawn at `t` (after `advance(to: t)`): the tip and its
    /// opacity, or nil.
    public func visible(at t: Double) -> (tip: Tip, opacity: Double)? {
        switch state {
        case .idle, .waiting: return nil
        case .shown(let tip): return (tip, 1)
        case .leaving(let tip, let left):
            let o = t - left <= hold ? 1 : max(0, 1 - (t - left - hold) / fade)
            return o > 0 ? (tip, o) : nil
        case .swapping(let old, _, _): return (old, 1)
        }
    }

    /// When the state next changes by itself (a timer's deadline), or nil.
    public var nextDeadline: Double? {
        switch state {
        case .idle, .shown: nil
        case .waiting(_, let at): at
        case .leaving(_, let left): left + hold + fade
        case .swapping(_, _, let left): left + hold
        }
    }

    /// When the fade of a leaving tip starts, if one is leaving.
    public var fadeStart: Double? {
        if case .leaving(_, let left) = state { return left + hold }
        return nil
    }
}
