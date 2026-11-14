import Foundation

/// The editor's bounce at the top (`editor-area.md` §D.4, E.1 and H.1,
/// checklist rows 40, 70 and 157).
///
/// When momentum carries the text past the top, it runs on and comes back
/// in two parts, momentum then a critically damped return (E.1 item 3):
///
/// - the run past the top, from the crossing at velocity `v` (points per
///   second): `rise(t) = g · v · t · e^(−ω₁ t)`, which peaks at
///   t₁ = 1/ω₁ (about 70 ms) at `P = g · v / (ω₁ e)`, at most
///   `maximumShare` of the visible height;
/// - the return from the peak: `P · (1 + ω t′) · e^(−ω t′)`, ω 11.3 rad/s at
///   the top and 16.6 at the bottom (round 9, rows 220, 222).
///
/// Round 6 (H.1, superseding round 3's 48 points, which the pixel-change
/// measure under-read) matched every frame of the reference against its
/// stills: the council's flick (8 gesture events of 40 points, then about
/// 1544 points of momentum decaying with a 0.33 s time constant, from 600
/// points down) reached the top in one frame, ran **119** points past it,
/// peaked 72 ms after reaching it, returned as a critically damped spring
/// at ω ≈ 13.6 with no oscillation and was settled about 700 ms after the
/// first event. Round 5's Ycode ran 199 past (its cap, a quarter of the
/// view). Round 9 (rows 220–222) measured the stretch frame by frame at
/// 2x: 38 points at the top, 32 at the bottom, about 6 for a slow arrival;
/// see `stretch(forCrossing:)`.
public enum TopBounce {
    /// The return's natural frequency at the top, rad/s. Round 9 (row 220):
    /// the fast flick's stretch peaks about 200 ms after the first event and
    /// is at rest by about 730, so its 35 points return over about 535 ms to
    /// within half a point (H.1's 13.5, fitted to a 119-point stretch, is
    /// superseded).
    public static let omega = 11.3
    /// At the bottom (row 222, X03): the same flick mirrored peaks about 210
    /// ms after its first event and is at rest by about 560.
    public static let bottomOmega = 16.6

    /// The return's natural frequency at `edge`.
    public static func omega(at edge: EditorFlick.Edge) -> Double { edge == .top ? omega : bottomOmega }
    /// The run past the top: its rate (the peak comes 1/ω₁ after the
    /// crossing, H.1: 72 ms) and its gain on the crossing velocity.
    public static let riseOmega = 14.0
    public static let riseGain = 1.1
    /// The overscroll is over once it is below this (points) after the peak:
    /// half a point, a pixel at 2x (round 9's capture), so the text never
    /// jumps the last point (round 8's 1.0 is superseded).
    public static let restThreshold = 0.5
    /// The deepest overscroll, as a share of the visible height: 0.28, so
    /// round 8's 190 points (row 207) fit in the council's window with room
    /// to spare; a limit for flicks far faster than the council's.
    public static let maximumShare = 0.28

    /// The overscroll `t` seconds after crossing the top at `velocity`.
    public static func overscroll(velocity: Double, at t: Double, edge: EditorFlick.Edge = .top) -> Double {
        overscroll(from: 0, velocity: velocity, at: t, edge: edge)
    }

    /// The overscroll `t` seconds after the bounce took over at an
    /// overscroll of `start` points (the system's elastic stop may already
    /// have let the text past the top) moving on at `velocity`: the run
    /// `(x₀ + (g v + ω₁ x₀) t) e^(−ω₁ t)` up to its peak, then the return.
    public static func overscroll(from start: Double, velocity: Double, at t: Double, edge: EditorFlick.Edge = .top) -> Double {
        let x0 = max(0, start)
        guard t > 0 else { return x0 }
        let t1 = peakTime(from: x0, velocity: velocity)
        if t <= t1 { return rise(from: x0, velocity: velocity, at: t) }
        let p = rise(from: x0, velocity: velocity, at: t1)
        let r = t - t1, w = omega(at: edge)
        return p * (1 + w * r) * exp(-w * r)
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

    // MARK: The stretch's depth (round 7, I.2; round 9, rows 220–222)

    /// The stretch grows with the speed left at the edge, more slowly than
    /// in proportion to it (I.2). Round 9 tracked it frame by frame at 2x
    /// (row 220, superseding round 8's 190, a misreading of its 1x strip):
    /// **38** points for the fast flick at the top (main 04), **32** at the
    /// bottom (X03, the same flick mirrored) and **about 6** for the slow
    /// flick's arrival (X05). With every momentum delta applied
    /// (`EditorMomentum`), main 04 crosses the top at about
    /// `referenceVelocity` and X05 at about 330 points a second; a power law
    /// through 35 points (within 4 of both edges' values) at the first and 6
    /// at the second: P(v) = 35 (v ÷ 3970)^0.71.
    public static let stretchAtReference = 35.0
    /// The crossing speed of the council's fast flick (main step 04: 280
    /// points of momentum to the top, crossed 124 ms after the first event).
    public static let referenceVelocity = 3970.0
    public static let stretchExponent = 0.71

    /// The stretch past the edge for a crossing at `velocity` (points per
    /// second, towards the edge), before the cap.
    public static func stretch(forCrossing velocity: Double) -> Double {
        guard velocity > 0 else { return 0 }
        return stretchAtReference * pow(velocity / referenceVelocity, stretchExponent)
    }

    /// The crossing velocity to animate: the one whose run past the edge
    /// peaks at `stretch(forCrossing:)` of the measured velocity, limited so
    /// the peak stays within `maximumShare` of `visibleHeight`.
    public static func effectiveVelocity(_ velocity: Double, visibleHeight: Double) -> Double {
        let cap = visibleHeight > 0 ? visibleHeight * maximumShare : .infinity
        return self.velocity(forPeak: min(stretch(forCrossing: max(0, velocity)), cap))
    }

    /// Whether the bounce is over at `t`: past the peak and within
    /// `restThreshold` of the top.
    public static func isAtRest(velocity: Double, at t: Double, edge: EditorFlick.Edge = .top) -> Bool {
        isAtRest(from: 0, velocity: velocity, at: t, edge: edge)
    }

    public static func isAtRest(from start: Double, velocity: Double, at t: Double, edge: EditorFlick.Edge = .top) -> Bool {
        t >= peakTime(from: start, velocity: velocity) && overscroll(from: start, velocity: velocity, at: t, edge: edge) < restThreshold
    }

    /// The time from the crossing until the bounce is at rest.
    public static func duration(velocity: Double, edge: EditorFlick.Edge = .top) -> Double {
        guard velocity > 0 else { return 0 }
        var t = peakTime
        while !isAtRest(velocity: velocity, at: t, edge: edge) { t += 0.001 }
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
