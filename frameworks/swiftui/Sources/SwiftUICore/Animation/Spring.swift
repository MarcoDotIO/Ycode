import Foundation

/// A damped spring (05-animation.md §3): a mass m on a spring of stiffness k
/// with damping c, moving towards a target. Values follow the closed-form
/// solution of m·x″ + c·x′ + k·(x − target) = 0.
///
/// Parameter relations (05 §3): response = 2π·√(m/k); dampingRatio =
/// c / (2·√(k·m)); duration = response; bounce = 1 − dampingRatio when
/// bounce ≥ 0, and dampingRatio = 1 / (1 + bounce) when bounce < 0. For the
/// over-damped case the reference reports stiffness = (2π/response)²·(2ζ² − 1)
/// and damping = 4πζ/response (bounce −0.3: 486.6319 and 35.9039); this
/// implementation reproduces those reported parameters and keeps the stated
/// response and damping ratio.
public struct Spring: Hashable, Sendable {
    public private(set) var mass: Double
    public private(set) var stiffness: Double
    public private(set) var damping: Double
    // Perceptual parameters as given (they are not always recoverable from
    // m, k, c; see the over-damped note above).
    private var storedResponse: Double
    private var storedDampingRatio: Double

    /// A spring with a perceptual `duration` and `bounce` (−1…1).
    public init(duration: TimeInterval = 0.5, bounce: Double = 0) {
        let ratio = bounce >= 0 ? 1 - bounce : 1 / (1 + bounce)
        self.init(response: duration, dampingRatio: ratio)
    }

    /// A spring with a `response` (the period of the undamped spring) and a
    /// `dampingRatio` (1 = critically damped).
    public init(response: Double, dampingRatio: Double) {
        let omega = 2 * Double.pi / response
        mass = 1
        stiffness = dampingRatio <= 1 ? omega * omega : omega * omega * (2 * dampingRatio * dampingRatio - 1)
        damping = 2 * dampingRatio * omega
        storedResponse = response
        storedDampingRatio = dampingRatio
    }

    /// A spring from its physical parameters. Without `allowOverDamping`, the
    /// damping ratio is limited to 1.
    public init(mass: Double = 1, stiffness: Double, damping: Double, allowOverDamping: Bool = false) {
        self.mass = mass
        self.stiffness = stiffness
        let critical = 2 * (stiffness * mass).squareRoot()
        self.damping = allowOverDamping ? damping : min(damping, critical)
        storedResponse = 2 * Double.pi * (mass / stiffness).squareRoot()
        storedDampingRatio = self.damping / critical
    }

    /// A spring that settles (to within `epsilon`) in about
    /// `settlingDuration` seconds.
    public init(settlingDuration: TimeInterval, dampingRatio: Double, epsilon: Double = 0.001) {
        // Search the response that gives this settling time.
        var lo = 1e-4, hi = 100.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            let s = Spring(response: mid, dampingRatio: dampingRatio)
            if s.settlingDuration(target: 1.0, initialVelocity: 0.0, epsilon: epsilon) < settlingDuration { lo = mid } else { hi = mid }
        }
        self.init(response: (lo + hi) / 2, dampingRatio: dampingRatio)
    }

    public var response: Double { storedResponse }
    public var dampingRatio: Double { storedDampingRatio }
    public var duration: TimeInterval { storedResponse }
    public var bounce: Double { storedDampingRatio <= 1 ? 1 - storedDampingRatio : 1 / storedDampingRatio - 1 }

    /// Time until the motion from 0 to 1 stays within 0.001 of the target.
    /// Note: this is our definition; the reference's values (05 §3 table)
    /// follow a rule that is still open (see the package README).
    public var settlingDuration: TimeInterval {
        settlingDuration(target: 1.0, initialVelocity: 0.0, epsilon: 0.001)
    }

    public static let smooth = Spring(duration: 0.5, bounce: 0)
    public static let snappy = Spring(duration: 0.5, bounce: 0.15)
    public static let bouncy = Spring(duration: 0.5, bounce: 0.3)

    public static func smooth(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Spring {
        Spring(duration: duration, bounce: extraBounce)
    }
    public static func snappy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Spring {
        Spring(duration: duration, bounce: 0.15 + extraBounce)
    }
    public static func bouncy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Spring {
        Spring(duration: duration, bounce: 0.3 + extraBounce)
    }

    // MARK: Motion (scalar core)

    /// Displacement from the target and velocity at `t` for initial
    /// displacement `x0` and velocity `v0`.
    /// Motion follows the perceptual parameters (ω0 = 2π/response, ζ =
    /// dampingRatio), which equal the physical ones except for the reported
    /// over-damped stiffness.
    private func state(x0: Double, v0: Double, t: Double) -> (x: Double, v: Double) {
        let w0 = 2 * Double.pi / storedResponse
        let z = storedDampingRatio
        if abs(z - 1) < 1e-9 {
            let a = x0, b = v0 + w0 * x0
            let e = exp(-w0 * t)
            return ((a + b * t) * e, (b - w0 * (a + b * t)) * e)
        } else if z < 1 {
            let wd = w0 * (1 - z * z).squareRoot()
            let a = x0, b = (v0 + z * w0 * x0) / wd
            let e = exp(-z * w0 * t)
            let (c, s) = (cos(wd * t), sin(wd * t))
            let x = e * (a * c + b * s)
            let v = e * (-z * w0 * (a * c + b * s) + (-a * wd * s + b * wd * c))
            return (x, v)
        } else {
            let r = (z * z - 1).squareRoot()
            let r1 = -w0 * (z - r), r2 = -w0 * (z + r)
            let b = (v0 - r1 * x0) / (r2 - r1), a = x0 - b
            let (e1, e2) = (exp(r1 * t), exp(r2 * t))
            return (a * e1 + b * e2, a * r1 * e1 + b * r2 * e2)
        }
    }

    // MARK: Motion (public, any VectorArithmetic)

    /// The value at `time` of a motion that starts at zero with
    /// `initialVelocity` and springs towards `target`.
    public func value<V: VectorArithmetic>(target: V, initialVelocity: V = .zero, time: TimeInterval) -> V {
        value(fromValue: V.zero, toValue: target, initialVelocity: initialVelocity, time: time)
    }

    public func velocity<V: VectorArithmetic>(target: V, initialVelocity: V = .zero, time: TimeInterval) -> V {
        velocity(fromValue: V.zero, toValue: target, initialVelocity: initialVelocity, time: time)
    }

    public func value<V: VectorArithmetic>(fromValue: V, toValue: V, initialVelocity: V, time: TimeInterval) -> V {
        // Decompose into a unit displacement and a unit velocity response.
        let disp = fromValue - toValue
        let fromDisp = state(x0: 1, v0: 0, t: time).x
        let fromVel = state(x0: 0, v0: 1, t: time).x
        return toValue + disp.scaled(by: fromDisp) + initialVelocity.scaled(by: fromVel)
    }

    public func velocity<V: VectorArithmetic>(fromValue: V, toValue: V, initialVelocity: V, time: TimeInterval) -> V {
        let disp = fromValue - toValue
        return disp.scaled(by: state(x0: 1, v0: 0, t: time).v)
            + initialVelocity.scaled(by: state(x0: 0, v0: 1, t: time).v)
    }

    /// The spring force on a value at `position` moving at `velocity`.
    public func force<V: VectorArithmetic>(target: V, position: V, velocity: V) -> V {
        force(fromValue: V.zero, toValue: target, position: position, velocity: velocity)
    }

    public func force<V: VectorArithmetic>(fromValue: V, toValue: V, position: V, velocity: V) -> V {
        (toValue - position).scaled(by: stiffness) - velocity.scaled(by: damping)
    }

    /// Advances `value` and `velocity` by `deltaTime` towards `target`.
    public func update<V: VectorArithmetic>(value: inout V, velocity: inout V, target: V, deltaTime: TimeInterval) {
        let newValue = self.value(fromValue: value, toValue: target, initialVelocity: velocity, time: deltaTime)
        let newVelocity = self.velocity(fromValue: value, toValue: target, initialVelocity: velocity, time: deltaTime)
        value = newValue
        velocity = newVelocity
    }

    public func settlingDuration<V: VectorArithmetic>(target: V, initialVelocity: V = .zero, epsilon: Double) -> TimeInterval {
        settlingDuration(fromValue: V.zero, toValue: target, initialVelocity: initialVelocity, epsilon: epsilon)
    }

    /// The last time the distance to the target exceeds `epsilon` (relative
    /// to the initial distance), found by sampling at 1 ms.
    public func settlingDuration<V: VectorArithmetic>(fromValue: V, toValue: V, initialVelocity: V,
                                                      epsilon: Double) -> TimeInterval {
        let scale = max((toValue - fromValue).magnitudeSquared.squareRoot(), 1e-12)
        var last = 0.0
        var t = 0.0
        let step = 0.001
        let w0 = 2 * Double.pi / storedResponse
        let horizon = max(20 / max(w0 * min(storedDampingRatio, 1), 1e-6), 1)
        while t < horizon {
            let x = value(fromValue: fromValue, toValue: toValue, initialVelocity: initialVelocity, time: t)
            if (x - toValue).magnitudeSquared.squareRoot() / scale > epsilon { last = t }
            t += step
        }
        return last + step
    }
}
