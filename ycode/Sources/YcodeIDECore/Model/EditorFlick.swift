import Foundation

/// The flick at the editor's edges on a toolkit that hands the editor every
/// scroll event with its touchpad phases (the Linux IDE on OpenViews,
/// B6-OPENVIEWS; `editor-area.md` H.1, council row 157). It is the macOS
/// editor's `EditorTopBounce` without AppKit: when momentum would carry the
/// text past the top (or the bottom), the text runs on and springs back by
/// `TopBounce` (about 120 points for the council's flick, at most 0.16 of
/// the view, gain 1.1, a critically damped return at ω 13.5, at rest within
/// about 700 ms); the rest of that momentum is taken in.
///
/// Offsets are the viewport's top in the content, 0 at the top and
/// `maxOffset` at the bottom; a positive `dy` scrolls towards the top (the
/// text moves down), as the toolkit's scroll events. While the fingers are
/// on the touchpad the text stops at the edges; only momentum stretches.
public struct EditorFlick: Sendable {
    /// A scroll event's phases, as the toolkit's (`ScrollPhase`).
    public enum Phase: Sendable, Hashable {
        case none, began, changed, ended, cancelled
    }

    public enum Edge: Sendable, Hashable { case top, bottom }

    /// One scroll event, vertical part.
    public struct Step: Sendable, Equatable {
        public var dy: Double
        public var phase: Phase
        public var momentumPhase: Phase
        public var time: Double

        public init(dy: Double, phase: Phase = .none, momentumPhase: Phase = .none, time: Double) {
            self.dy = dy
            self.phase = phase
            self.momentumPhase = momentumPhase
            self.time = time
        }

        var hasPhase: Bool { phase != .none || momentumPhase != .none }
    }

    /// What the editor does with a step.
    public enum Outcome: Sendable, Equatable {
        /// Scroll to this offset (already within 0…maxOffset).
        case scroll(Double)
        /// A bounce began at this edge: put the text at the edge and ask
        /// for frames (`overscroll(at:frame:)`).
        case bounce(Edge)
        /// Used, nothing moves (momentum taken in, a stop, an edge reached).
        case held
        /// Not used (no motion and no phase).
        case ignored
    }

    /// A running bounce.
    public struct Bounce: Sendable, Equatable {
        public var edge: Edge
        /// The crossing velocity animated (points per second, towards the edge).
        public var velocity: Double
        /// The spring's clock: the crossing (nil until its first frame).
        public var start: Double?
    }

    private var tracker = TopBounce.VelocityTracker()
    private var gestureVelocity = 0.0
    private var swallowingMomentum = false
    /// The share of the momentum applied (row 205).
    private var momentum = EditorMomentum()
    public private(set) var bounce: Bounce?
    /// The deepest overscroll of the last bounce (measurement).
    public private(set) var lastPeak = 0.0

    public init() {}

    public var isBouncing: Bool { bounce != nil }

    /// Takes one step at `offset` in a document that scrolls to `maxOffset`
    /// with `visibleHeight` points on screen.
    public mutating func handle(_ s: Step, offset: Double, maxOffset: Double, visibleHeight: Double) -> Outcome {
        let maxOffset = max(0, maxOffset)
        if s.phase == .began {
            swallowingMomentum = false
            momentum.reset()
            tracker.reset()
        }
        if s.momentumPhase == .ended || s.momentumPhase == .cancelled {
            let was = swallowingMomentum
            swallowingMomentum = false
            return was || bounce != nil ? .held : .ignored
        }
        if swallowingMomentum, s.momentumPhase != .none { return .held }
        if s.momentumPhase == .began {
            gestureVelocity = tracker.velocity
            tracker.reset()
            momentum.reset()
        }
        if s.hasPhase { tracker.add(s.dy, at: s.time) }
        if let b = bounce {
            // A touch while the text springs back: towards the edge it waits
            // for the spring; away from it the spring ends at the edge.
            let away = b.edge == .top ? s.dy < 0 : s.dy > 0
            guard away else { return s.hasPhase || s.dy != 0 ? .held : .ignored }
            bounce = nil
            let edge = b.edge == .top ? 0 : maxOffset
            return .scroll(min(max(edge - s.dy, 0), maxOffset))
        }
        guard s.dy != 0 else { return s.hasPhase ? .held : .ignored }
        let isMomentum = s.momentumPhase == .began || s.momentumPhase == .changed
        let delivered = tracker.hasSample ? tracker.velocity : (abs(gestureVelocity) > 0 ? gestureVelocity : s.dy / 0.0167)
        // The momentum's share (row 205): a decaying gain, then taken in.
        var dy = s.dy
        if isMomentum {
            guard let applied = momentum.applied(s.dy, at: s.time, speed: delivered) else {
                swallowingMomentum = true
                return .held
            }
            dy = applied
        }
        let target = offset - dy
        let crossing: Edge? = target < 0 && dy > 0 ? .top : target > maxOffset && dy < 0 ? .bottom : nil
        if isMomentum, let edge = crossing {
            let measured = momentum.appliedSpeed(delivered, at: s.time)
            let towards = edge == .top ? measured : -measured
            let fallback = abs(dy) / 0.0167
            let v = towards > 0 ? towards : fallback
            bounce = Bounce(edge: edge, velocity: TopBounce.effectiveVelocity(v, visibleHeight: visibleHeight), start: nil)
            lastPeak = 0
            swallowingMomentum = true
            return .bounce(edge)
        }
        let clamped = min(max(target, 0), maxOffset)
        if clamped == offset { return s.hasPhase ? .held : .ignored }
        return .scroll(clamped)
    }

    /// The overscroll at display time `time` (`frame` the frame's length:
    /// the crossing counts one frame before the first), or nil once the
    /// bounce is at rest (the text back at its edge).
    public mutating func overscroll(at time: Double, frame: Double) -> Double? {
        guard var b = bounce else { return nil }
        if b.start == nil { b.start = time - frame }
        bounce = b
        let t = time - (b.start ?? time)
        if TopBounce.isAtRest(velocity: b.velocity, at: t, edge: b.edge) {
            bounce = nil
            return nil
        }
        let x = TopBounce.overscroll(velocity: b.velocity, at: t, edge: b.edge)
        lastPeak = max(lastPeak, x)
        return x
    }

    /// Ends a bounce where it is (the document changed under it).
    public mutating func cancel() {
        bounce = nil
        swallowingMomentum = false
    }
}
