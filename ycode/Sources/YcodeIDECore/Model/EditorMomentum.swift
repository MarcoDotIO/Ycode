import Foundation

/// How much of a flick's momentum the editor applies (`fidelity-council.md`
/// rows 205 and 221, `editor-area.md` I.1, J.1, K.1). Both IDEs use it:
/// the macOS editor on the momentum-phase events the system delivers, the
/// Linux editor on the ones the toolkit makes from a touchpad's release
/// (both decay with a 0.33 s time constant).
///
/// Round 9 (row 221, superseding round 8's row 205) tracked the slow flick
/// frame by frame at 2x: the reference's text **reaches the top**, arriving
/// with little speed, and stretches about 6 points past it. Round 8's
/// reading that it stopped 36 short (and the decaying gain and speed floor
/// fitted to it) was a misreading of its 1x strip. So every momentum delta
/// applies one to one until the momentum ends or an edge is reached
/// (I.1's rule): `gainTimeConstant` is infinite (the gain stays 1) and
/// there is no speed floor. X05's input (8 gesture events of 15 points,
/// then 566.7 points of momentum decaying with τ 0.33 s, from 600 below the
/// top) then reaches the top 621 ms after its first event at about 330
/// points a second (round 7's reference: 330 on reaching the top), and the
/// fast flick (main 04) crosses it at 124 ms at about 3970 points a second;
/// what is left at the edge feeds the stretch there (`TopBounce`).
///
/// The gain and the floor are kept as parameters so that a later round's
/// measurement can set them again.
public struct EditorMomentum: Sendable, Equatable {
    /// The gain's time constant (seconds): infinite, so every delta applies
    /// one to one (round 9, row 221; round 8's 1.42 s is superseded).
    public static let gainTimeConstant = Double.infinity
    /// Below this applied speed (points per second) the momentum ends: none
    /// (round 9; round 8's 145 is superseded). The momentum ends with its
    /// events or at an edge.
    public static let stopSpeed = 0.0
    /// The events' speed is their distance over this last stretch of time.
    public static let speedWindow = 0.1

    /// The momentum's first event (nil before it).
    public private(set) var start: Double?
    /// Whether this momentum is over (its remaining events taken in).
    public private(set) var isOver = false
    /// The events within the last `speedWindow`.
    private var recent: [Sample] = []

    struct Sample: Sendable, Equatable {
        var time: Double
        var dy: Double
    }

    public init() {}

    /// A new momentum (or a new gesture) begins.
    public mutating func reset() {
        start = nil
        isOver = false
        recent = []
    }

    /// The gain `t` seconds after the momentum's first event.
    public static func gain(after t: Double) -> Double { exp(-max(0, t) / gainTimeConstant) }

    /// The applied speed for events arriving at `speed` (points per second)
    /// at `time`.
    public func appliedSpeed(_ speed: Double, at time: Double) -> Double {
        speed * Self.gain(after: time - (start ?? time))
    }

    /// The part of a momentum delta `dy` at `time` to apply; nil once the
    /// momentum is over. `speed` (points per second, either sign) stands in
    /// for the events' speed until they span some time (the gesture's speed
    /// at the momentum's first event).
    public mutating func applied(_ dy: Double, at time: Double, speed fallback: Double) -> Double? {
        guard !isOver else { return nil }
        let first = start ?? time
        start = first
        recent.append(Sample(time: time, dy: dy))
        recent.removeAll { $0.time <= time - Self.speedWindow }
        let span = time - (recent.first?.time ?? time)
        let speed = span > 0.004 && recent.count > 1 ? recent.dropFirst().reduce(0) { $0 + $1.dy } / span : fallback
        let g = Self.gain(after: time - first)
        if time > first, abs(speed) * g < Self.stopSpeed {
            isOver = true
            return nil
        }
        return dy * g
    }

    /// The distance a momentum of `events` (time, delta) applies, the speed
    /// read from successive events as the editors read it (tests, specs).
    public static func distance(of events: [(time: Double, dy: Double)], gestureSpeed: Double) -> (distance: Double, lastMove: Double?) {
        var m = EditorMomentum()
        var tracker = TopBounce.VelocityTracker()
        var total = 0.0
        var last: Double?
        for e in events {
            tracker.add(e.dy, at: e.time)
            guard let a = m.applied(e.dy, at: e.time, speed: tracker.hasSample ? tracker.velocity : gestureSpeed) else { break }
            total += a
            if a != 0 { last = e.time }
        }
        return (total, last)
    }
}
