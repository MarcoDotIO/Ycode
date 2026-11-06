import Foundation

/// The editor's bounce at the top (`editor-area.md` §D.4 and E.1,
/// checklist rows 40 and 70).
///
/// When momentum carries the text past the top, it runs on and comes back
/// in two parts, momentum then a critically damped return (E.1 item 3):
///
/// - the run past the top, from the crossing at velocity `v` (points per
///   second): `rise(t) = g · v · t · e^(−ω₁ t)`, which peaks at
///   t₁ = 1/ω₁ (about 67 ms) at `P = g · v / (ω₁ e)`;
/// - the return from the peak: `P · (1 + ω t′) · e^(−ω t′)`, ω 12.6 rad/s.
///
/// Round 3's reference crossed at about 2470 points a second, ran 48
/// points past the end of a 600-point flick (8 %), peaked 157 ms after the
/// flick began (about 67 ms after the crossing), lost half the overshoot
/// about 140 ms after the peak and was within a point of the top 440 ms
/// after it. ω₁ and g fit that run; ω is round 2's return, which round 3
/// confirms.
public enum TopBounce {
    /// The return's natural frequency, rad/s.
    public static let omega = 12.6
    /// The run past the top: its rate (the peak comes 1/ω₁ after the
    /// crossing) and its gain on the crossing velocity.
    public static let riseOmega = 15.0
    public static let riseGain = 0.78
    /// The overscroll is over once it is below this (points) after the peak.
    public static let restThreshold = 0.25
    /// The deepest overscroll, as a share of the visible height (a very
    /// fast flick is limited to it; not measured, Ycode's choice).
    public static let maximumShare = 0.25

    /// The overscroll `t` seconds after crossing the top at `velocity`.
    public static func overscroll(velocity: Double, at t: Double) -> Double {
        overscroll(from: 0, velocity: velocity, at: t)
    }

    /// The overscroll `t` seconds after the bounce took over at an
    /// overscroll of `start` points (the system's elastic stop may already
    /// have let the text past the top) moving on at `velocity`: the run
    /// `(x₀ + (g v + ω₁ x₀) t) e^(−ω₁ t)` up to its peak, then the return.
    public static func overscroll(from start: Double, velocity: Double, at t: Double) -> Double {
        let x0 = max(0, start)
        guard t > 0 else { return x0 }
        let t1 = peakTime(from: x0, velocity: velocity)
        if t <= t1 { return rise(from: x0, velocity: velocity, at: t) }
        let p = rise(from: x0, velocity: velocity, at: t1)
        let r = t - t1
        return p * (1 + omega * r) * exp(-omega * r)
    }

    private static func rise(from x0: Double, velocity: Double, at t: Double) -> Double {
        (x0 + (riseGain * max(0, velocity) + riseOmega * x0) * t) * exp(-riseOmega * t)
    }

    /// The time of the deepest overscroll after the crossing.
    public static var peakTime: Double { 1 / riseOmega }

    /// The time of the deepest overscroll for a bounce that took over
    /// `start` points past the top (0: it is already at its deepest).
    public static func peakTime(from start: Double, velocity: Double) -> Double {
        let a = max(0, start), b = riseGain * max(0, velocity) + riseOmega * a
        guard b > 0 else { return 0 }
        return max(0, 1 / riseOmega - a / b)
    }

    /// The deepest overscroll for a crossing at `velocity`.
    public static func peak(velocity: Double) -> Double { riseGain * max(0, velocity) / (riseOmega * M_E) }

    /// The crossing velocity that gives a peak of `peak` points.
    public static func velocity(forPeak peak: Double) -> Double { max(0, peak) * riseOmega * M_E / riseGain }

    /// The crossing velocity to animate: the measured one, limited so the
    /// peak stays within `maximumShare` of `visibleHeight`.
    public static func effectiveVelocity(_ velocity: Double, visibleHeight: Double) -> Double {
        let cap = visibleHeight > 0 ? self.velocity(forPeak: visibleHeight * maximumShare) : .infinity
        return min(max(0, velocity), cap)
    }

    /// Whether the bounce is over at `t`: past the peak and within
    /// `restThreshold` of the top.
    public static func isAtRest(velocity: Double, at t: Double) -> Bool {
        isAtRest(from: 0, velocity: velocity, at: t)
    }

    public static func isAtRest(from start: Double, velocity: Double, at t: Double) -> Bool {
        t >= peakTime(from: start, velocity: velocity) && overscroll(from: start, velocity: velocity, at: t) < restThreshold
    }

    /// The time from the crossing until the bounce is at rest.
    public static func duration(velocity: Double) -> Double {
        guard velocity > 0 else { return 0 }
        var t = peakTime
        while !isAtRest(velocity: velocity, at: t) { t += 0.001 }
        return t
    }

    /// The scroll velocity from successive scroll deltas: an exponential
    /// average of delta ÷ interval (points per second), weighted to the
    /// latest. Events without motion (a phase's end) are left out.
    public struct VelocityTracker: Sendable {
        public private(set) var velocity = 0.0
        /// Whether any interval has been measured since the last reset.
        public private(set) var hasSample = false
        private var lastTime: Double?

        public init() {}

        public mutating func reset() {
            velocity = 0
            hasSample = false
            lastTime = nil
        }

        /// Adds a delta of `points` at `time` (seconds).
        public mutating func add(_ points: Double, at time: Double) {
            guard points != 0 else { return }
            defer { lastTime = time }
            guard let last = lastTime else { return }
            let dt = time - last
            guard dt > 0.0005, dt < 0.1 else { return }
            let v = points / dt
            velocity = hasSample ? 0.3 * velocity + 0.7 * v : v
            hasSample = true
        }
    }
}
