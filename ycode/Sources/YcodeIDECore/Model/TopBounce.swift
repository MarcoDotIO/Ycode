import Foundation

/// The editor's bounce at the top (`editor-area.md` §D.4, checklist row 40).
///
/// When momentum carries the text past the top, it runs on and comes back
/// as one critically damped spring started at the crossing with the
/// scroll's velocity `v` (points per second):
///
///     overscroll(t) = v · t · e^(−ω t),   ω = 12.6 rad/s
///
/// The overscroll peaks at t = 1/ω (about 79 ms) at v / (ω e), then
/// returns; from the peak on this is exactly the critically damped spring
/// x(t′) = peak · (1 + ω t′) · e^(−ω t′) that the reference's return fits
/// (response 2π/ω, about 0.50 s). The reference's flick crossed at about
/// 2840 points a second and overscrolled 83 points.
public enum TopBounce {
    /// The spring's natural frequency, rad/s.
    public static let omega = 12.6
    /// The overscroll is over once it is below this (points) after the peak.
    public static let restThreshold = 0.25
    /// The deepest overscroll, as a share of the visible height (a very
    /// fast flick is limited to it; not measured, Ycode's choice).
    public static let maximumShare = 0.25

    /// The overscroll `t` seconds after crossing the top at `velocity`.
    public static func overscroll(velocity: Double, at t: Double) -> Double {
        guard t > 0, velocity > 0 else { return 0 }
        return velocity * t * exp(-omega * t)
    }

    /// The overscroll `t` seconds after the bounce took over at an
    /// overscroll of `start` points (the system's elastic stop may already
    /// have let the text past the top) moving on at `velocity`:
    /// (x₀ + (v + ω x₀) t) e^(−ω t).
    public static func overscroll(from start: Double, velocity: Double, at t: Double) -> Double {
        guard t > 0 else { return max(0, start) }
        let x0 = max(0, start)
        return (x0 + (max(0, velocity) + omega * x0) * t) * exp(-omega * t)
    }

    /// The time of the deepest overscroll after the crossing.
    public static var peakTime: Double { 1 / omega }

    /// The deepest overscroll for a crossing at `velocity`.
    public static func peak(velocity: Double) -> Double { max(0, velocity) / (omega * M_E) }

    /// The crossing velocity that gives a peak of `peak` points.
    public static func velocity(forPeak peak: Double) -> Double { max(0, peak) * omega * M_E }

    /// The crossing velocity to animate: the measured one, limited so the
    /// peak stays within `maximumShare` of `visibleHeight`.
    public static func effectiveVelocity(_ velocity: Double, visibleHeight: Double) -> Double {
        let cap = visibleHeight > 0 ? self.velocity(forPeak: visibleHeight * maximumShare) : .infinity
        return min(max(0, velocity), cap)
    }

    /// Whether the bounce is over at `t`: past the peak and within
    /// `restThreshold` of the top.
    public static func isAtRest(velocity: Double, at t: Double) -> Bool {
        t >= peakTime && overscroll(velocity: velocity, at: t) < restThreshold
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
