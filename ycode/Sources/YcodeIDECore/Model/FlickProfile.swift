import Foundation

/// How a flick plays on a given display (`specs/ide/parity-inventory.md`
/// P-078; `fidelity-council.md` rows 220–222 and the deferred flick study).
///
/// The council posted the **same logged input** to the reference on two
/// displays and got two responses: on a 2x, 120 Hz display (round 11) the
/// fast flick (main 04) stretches **23 pt** past the top, the flick to the
/// bottom (X03) passes the end by **18 pt**, and the slow flick (X05)
/// travels **394 of 600 pt** and stops short of the top; on a 1x, 100 Hz
/// display (round 10) main 04 stretches **182 pt** (deepest +163 ms, at rest
/// +830), X03 passes the end by **111 pt** (deepest +184, at rest +783) and
/// X05 travels **552 pt**, stopping short with no stretch. The two
/// displays differ in both scale and refresh rate, so the measurements
/// cannot tell the two apart; Ycode chooses the profile by the backing
/// scale (`forDisplay`), the one a window always knows.
///
/// A profile sets the share of the momentum applied (a gain decaying with
/// `gainTimeConstant` from the momentum's first event, `EditorMomentum`),
/// the stretch past either edge for a crossing at a given speed
/// (`TopBounce.stretch`: the measured stretch of main 04 at main 04's own
/// crossing speed, scaled by speed to the 0.71 power, I.2) and the return's
/// spring.
public struct FlickProfile: Sendable, Equatable {
    /// A name for logs and tests.
    public var name: String
    /// The momentum gain's time constant (seconds); infinite: every delta
    /// one to one.
    public var gainTimeConstant: Double
    /// Main 04's stretch past the top and X03's past the bottom (points).
    public var topStretch: Double
    public var bottomStretch: Double
    /// The return's natural frequency at each edge (rad/s, critically damped).
    public var topOmega: Double
    public var bottomOmega: Double

    public init(name: String, gainTimeConstant: Double, topStretch: Double, bottomStretch: Double, topOmega: Double, bottomOmega: Double) {
        self.name = name
        self.gainTimeConstant = gainTimeConstant
        self.topStretch = topStretch
        self.bottomStretch = bottomStretch
        self.topOmega = topOmega
        self.bottomOmega = bottomOmega
    }

    /// Round 11, 2x and 120 Hz: a gain falling with τ 0.282 s applies 274 of
    /// X05's 566.7 momentum points (394 travelled with the gesture's 120),
    /// and main 04 still reaches the top (280 of 1544 needed) at about 3300
    /// points a second; 23 pt there, 18 at the bottom. The springs keep
    /// round 9's 2x fits (at rest about 520 and 400 ms after the deepest
    /// point).
    public static let retina = FlickProfile(name: "2x 120 Hz (round 11)", gainTimeConstant: 0.2818, topStretch: 23, bottomStretch: 18,
                                            topOmega: 11.3, bottomOmega: 16.6)
    /// Round 10, 1x and 100 Hz: τ 0.944 s applies 432 of X05's momentum
    /// (552 travelled); main 04 crosses at about 3900 points a second and
    /// stretches 182, X03 111; both return to rest about 600–670 ms after
    /// their deepest point (ω 12.5).
    public static let standard = FlickProfile(name: "1x 100 Hz (round 10)", gainTimeConstant: 0.9442, topStretch: 182, bottomStretch: 111,
                                              topOmega: 12.5, bottomOmega: 12.5)
    /// Round 9 (2x, 120 Hz, superseded by round 11): every delta one to one,
    /// 35 pt at either edge for a crossing at 3970 points a second.
    public static let round9 = FlickProfile(name: "round 9", gainTimeConstant: .infinity, topStretch: 35, bottomStretch: 35,
                                            topOmega: 11.3, bottomOmega: 16.6)

    /// The profile for a display of `scale` pixels per point.
    public static func forDisplay(scale: Double) -> FlickProfile { scale >= 1.5 ? retina : standard }

    /// The stretch's growth with the speed at the edge (I.2, round 7).
    public static let stretchExponent = 0.71

    /// The return's natural frequency at `edge`.
    public func omega(at edge: EditorFlick.Edge) -> Double { edge == .top ? topOmega : bottomOmega }

    /// Main 04's stretch past `edge`.
    public func referenceStretch(at edge: EditorFlick.Edge) -> Double { edge == .top ? topStretch : bottomStretch }

    /// The speed (points a second) at which main 04 crosses the top under
    /// this profile's momentum: its logged events through `EditorMomentum`.
    public var referenceCrossing: Double {
        if gainTimeConstant == .infinity { return TopBounce.referenceVelocity }
        return Self.crossingSpeed(of: Self.mainFlick, gesture: 320, distance: 600, profile: self) ?? TopBounce.referenceVelocity
    }

    /// The stretch past `edge` for a crossing at `velocity` (points a second).
    public func stretch(forCrossing velocity: Double, at edge: EditorFlick.Edge = .top) -> Double {
        guard velocity > 0 else { return 0 }
        return referenceStretch(at: edge) * pow(velocity / referenceCrossing, Self.stretchExponent)
    }

    // MARK: The council's logged input (deferred flick study)

    /// Main 04's momentum: 173 events 8.333 ms apart from 60.3 ms, from
    /// 39.0026 points, each 0.975063 of the one before (1544.33 points).
    public static let mainFlick: [(time: Double, dy: Double)] = momentum(first: 39.0026, at: 0.0603, count: 173)
    /// X05's momentum: 134 events from 14.626 points at 59 ms (566.7 points).
    public static let slowFlick: [(time: Double, dy: Double)] = momentum(first: 14.626, at: 0.059, count: 134)

    static func momentum(first: Double, at t0: Double, count: Int) -> [(time: Double, dy: Double)] {
        (0..<count).map { (t0 + Double($0) / 120, first * pow(0.975063, Double($0))) }
    }

    /// The applied speed when a momentum, starting `gesture` points from an
    /// edge `distance` away, reaches it; nil when it stops short.
    public static func crossingSpeed(of events: [(time: Double, dy: Double)], gesture: Double, distance: Double, profile: FlickProfile) -> Double? {
        var m = EditorMomentum(profile: profile)
        var tracker = TopBounce.VelocityTracker()
        var travelled = gesture
        for e in events {
            tracker.add(e.dy, at: e.time)
            let speed = tracker.hasSample ? tracker.velocity : e.dy * 120
            guard let a = m.applied(e.dy, at: e.time, speed: speed) else { return nil }
            travelled += a
            if travelled >= distance { return m.appliedSpeed(speed, at: e.time) }
        }
        return nil
    }
}
