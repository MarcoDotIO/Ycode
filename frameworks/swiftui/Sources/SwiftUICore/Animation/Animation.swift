import Foundation

// `Animation` values (05-animation.md §2–4). An `Animation` wraps a
// `CustomAnimation`; the built-in ones are timing curves (the `UnitCurve`s of
// §2 over a duration, 0.35 s when none is given), springs (§3) and the
// modifiers delay, speed, repeat and logical completion.
//
// Rules (05 §4):
//  - A curve animation reaches its target at `duration` and is then both
//    logically complete and finished.
//  - A spring is logically complete at its perceptual duration (`response`)
//    and finishes when it has settled (see `SpringAnimation`).
//  - `delay` produces no change during the delay; `speed` scales time;
//    `repeatCount(n, autoreverses:)` counts traversals (two = there and back)
//    and then jumps to the model value; `repeatForever` never completes.

/// How a value changes over time when it is animated.
public struct Animation: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The animation this value wraps.
    public let base: any CustomAnimation

    /// An animation from a custom animation type.
    public init<A: CustomAnimation>(_ base: A) {
        if let a = base as? Animation { self = a } else { self.base = base }
    }

    public static func == (lhs: Animation, rhs: Animation) -> Bool { AnyHashable(lhs.base) == AnyHashable(rhs.base) }
    public func hash(into hasher: inout Hasher) { hasher.combine(AnyHashable(base)) }

    public var description: String { String(describing: base) }
    public var debugDescription: String { description }

    // MARK: Evaluation

    public func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        base.animate(value: value, time: time, context: &context)
    }

    public func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        base.velocity(value: value, time: time, context: context)
    }

    public func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                                 context: inout AnimationContext<V>) -> Bool {
        base.shouldMerge(previous: previous, value: value, time: time, context: &context)
    }

    /// The time at which one run of the animation finishes for a unit change
    /// (curves: their duration; others: found by sampling; nil when it never
    /// finishes within an hour).
    package func cycleDuration() -> TimeInterval? {
        if let c = base as? TimingCurveAnimation { return c.duration }
        if let d = base as? DelayAnimation, let inner = d.animation.cycleDuration() { return d.delay + inner }
        if let s = base as? SpeedAnimation, let inner = s.animation.cycleDuration() { return s.speed > 0 ? inner / s.speed : nil }
        var ctx = AnimationContext<Double>()
        var t = 0.0
        let step = 1.0 / 240
        while t < 3600 {
            if animate(value: 1.0, time: t, context: &ctx) == nil { return t }
            t += step
        }
        return nil
    }

    // MARK: Curves (default duration 0.35 s, 05 §4)

    private static let defaultCurveDuration: TimeInterval = 0.35

    public static func timingCurve(_ curve: UnitCurve, duration: TimeInterval) -> Animation {
        Animation(TimingCurveAnimation(curve: curve, duration: duration))
    }

    public static func timingCurve(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double,
                                   duration: TimeInterval = 0.35) -> Animation {
        timingCurve(.bezier(startControlPoint: UnitPoint(x: p1x, y: p1y), endControlPoint: UnitPoint(x: p2x, y: p2y)),
                    duration: duration)
    }

    public static var linear: Animation { linear(duration: defaultCurveDuration) }
    public static func linear(duration: TimeInterval) -> Animation { timingCurve(.linear, duration: duration) }
    public static var easeIn: Animation { easeIn(duration: defaultCurveDuration) }
    public static func easeIn(duration: TimeInterval) -> Animation { timingCurve(.easeIn, duration: duration) }
    public static var easeOut: Animation { easeOut(duration: defaultCurveDuration) }
    public static func easeOut(duration: TimeInterval) -> Animation { timingCurve(.easeOut, duration: duration) }
    public static var easeInOut: Animation { easeInOut(duration: defaultCurveDuration) }
    public static func easeInOut(duration: TimeInterval) -> Animation { timingCurve(.easeInOut, duration: duration) }

    // MARK: Springs (05 §4 table)

    /// A spring like `.smooth` (response 0.5, critically damped).
    public static let `default` = Animation(SpringAnimation(spring: Spring(response: 0.5, dampingRatio: 1)))

    public static func spring(_ spring: Spring, blendDuration: TimeInterval = 0) -> Animation {
        Animation(SpringAnimation(spring: spring, blendDuration: blendDuration))
    }

    /// Response 0.5, damping fraction 1, blend 0 (measured `.spring()`).
    public static var spring: Animation { spring(duration: 0.5, bounce: 0) }

    /// (`.spring()` with no arguments is the duration/bounce form: response
    /// 0.5, damping 1, as measured in 05 §4.)
    @_disfavoredOverload
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825,
                              blendDuration: TimeInterval = 0) -> Animation {
        spring(Spring(response: response, dampingRatio: dampingFraction), blendDuration: blendDuration)
    }

    public static func spring(duration: TimeInterval = 0.5, bounce: Double = 0, blendDuration: Double = 0) -> Animation {
        spring(Spring(duration: duration, bounce: bounce), blendDuration: blendDuration)
    }

    /// Response 0.15, damping 0.85, blend 0.25 (measured).
    public static var interactiveSpring: Animation { interactiveSpring(response: 0.15, dampingFraction: 0.85, blendDuration: 0.25) }

    @_disfavoredOverload
    public static func interactiveSpring(response: Double = 0.15, dampingFraction: Double = 0.85,
                                         blendDuration: TimeInterval = 0.25) -> Animation {
        spring(Spring(response: response, dampingRatio: dampingFraction), blendDuration: blendDuration)
    }

    public static func interactiveSpring(duration: TimeInterval = 0.15, extraBounce: Double = 0,
                                         blendDuration: TimeInterval = 0.25) -> Animation {
        spring(Spring(duration: duration, bounce: 0.15 + extraBounce), blendDuration: blendDuration)
    }

    public static var smooth: Animation { spring(.smooth) }
    public static func smooth(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        spring(.smooth(duration: duration, extraBounce: extraBounce))
    }

    public static var snappy: Animation { spring(.snappy) }
    public static func snappy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        spring(.snappy(duration: duration, extraBounce: extraBounce))
    }

    public static var bouncy: Animation { spring(.bouncy) }
    public static func bouncy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        spring(.bouncy(duration: duration, extraBounce: extraBounce))
    }

    /// Mass 1, stiffness 157.9137, damping 25.1327 (measured).
    public static var interpolatingSpring: Animation {
        interpolatingSpring(mass: 1, stiffness: 157.9137, damping: 25.1327)
    }

    public static func interpolatingSpring(mass: Double = 1, stiffness: Double, damping: Double,
                                           initialVelocity: Double = 0) -> Animation {
        Animation(SpringAnimation(spring: Spring(mass: mass, stiffness: stiffness, damping: damping),
                                  initialVelocity: initialVelocity, interpolating: true))
    }

    public static func interpolatingSpring(_ spring: Spring, initialVelocity: Double = 0) -> Animation {
        Animation(SpringAnimation(spring: spring, initialVelocity: initialVelocity, interpolating: true))
    }

    public static func interpolatingSpring(duration: TimeInterval = 0.5, bounce: Double = 0,
                                           initialVelocity: Double = 0) -> Animation {
        interpolatingSpring(Spring(duration: duration, bounce: bounce), initialVelocity: initialVelocity)
    }

    // MARK: Modifiers

    public func delay(_ delay: TimeInterval) -> Animation { Animation(DelayAnimation(animation: self, delay: delay)) }
    public func speed(_ speed: Double) -> Animation { Animation(SpeedAnimation(animation: self, speed: speed)) }

    public func repeatCount(_ repeatCount: Int, autoreverses: Bool = true) -> Animation {
        Animation(RepeatAnimation(animation: self, count: repeatCount, autoreverses: autoreverses))
    }

    public func repeatForever(autoreverses: Bool = true) -> Animation {
        Animation(RepeatAnimation(animation: self, count: nil, autoreverses: autoreverses))
    }

    /// Reports logical completion `duration` seconds after the start.
    public func logicallyComplete(after duration: TimeInterval) -> Animation {
        Animation(LogicallyCompleteAnimation(animation: self, after: duration))
    }
}

extension Animation: CustomAnimation {}

// MARK: - Built-in animations

/// A unit curve stretched over `duration` (05 §2, §4).
package struct TimingCurveAnimation: CustomAnimation, CustomStringConvertible {
    package let curve: UnitCurve
    package let duration: TimeInterval

    package func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: curve.value(at: time / duration))
    }

    package func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        guard duration > 0, time < duration else { return .zero }
        return value.scaled(by: curve.velocity(at: time / duration) / duration)
    }

    package var description: String { "curve(\(curve), duration: \(duration))" }
}

/// A spring towards the target (05 §3). Logically complete at the spring's
/// perceptual duration; finished at the first sample where both the distance
/// to the target and the speed (divided by ω₀ = 2π/response) are within
/// `settleEpsilon` of the motion's scale. The value of `settleEpsilon`
/// (2 × 10⁻⁶) is fitted to the one measurement there is: `.spring()` is
/// removed ≈ 1.28 s after the change, after ≈ 77 frames (05 §4).
///
/// A spring retargeted while a spring runs merges with it: it starts from
/// the current value *and velocity* (05 §4.2). Any other previous animation
/// leaves velocity zero.
package struct SpringAnimation: CustomAnimation, CustomStringConvertible {
    package static let settleEpsilon = 2e-6

    package let spring: Spring
    package var blendDuration: TimeInterval = 0
    package var initialVelocity: Double = 0
    package var interpolating = false

    package init(spring: Spring, blendDuration: TimeInterval = 0, initialVelocity: Double = 0, interpolating: Bool = false) {
        self.spring = spring
        self.blendDuration = blendDuration
        self.initialVelocity = initialVelocity
        self.interpolating = interpolating
    }

    private func startVelocity<V: VectorArithmetic>(_ value: V, _ context: AnimationContext<V>) -> V {
        context.state.inheritedVelocity ?? value.scaled(by: initialVelocity)
    }

    package func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let v0 = startVelocity(value, context)
        if time >= spring.duration { context.isLogicallyComplete = true }
        let x = spring.value(target: value, initialVelocity: v0, time: time)
        let w0 = 2 * Double.pi / spring.response
        let scale = max(value.magnitudeSquared.squareRoot(), v0.magnitudeSquared.squareRoot() / w0)
        guard scale > 0 else { return nil }
        let distance = (value - x).magnitudeSquared.squareRoot()
        let speed = spring.velocity(target: value, initialVelocity: v0, time: time).magnitudeSquared.squareRoot() / w0
        if time > 0 && distance <= Self.settleEpsilon * scale && speed <= Self.settleEpsilon * scale { return nil }
        return x
    }

    package func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        spring.velocity(target: value, initialVelocity: startVelocity(value, context), time: time)
    }

    package func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                                  context: inout AnimationContext<V>) -> Bool {
        guard previous.base is SpringAnimation else { return false }
        context.state.inheritedVelocity = previous.velocity(value: value, time: time, context: context)
        return true
    }

    package var description: String {
        interpolating
            ? "interpolatingSpring(mass: \(spring.mass), stiffness: \(spring.stiffness), damping: \(spring.damping), initialVelocity: \(initialVelocity))"
            : "spring(response: \(spring.response), dampingFraction: \(spring.dampingRatio), blendDuration: \(blendDuration))"
    }
}

/// No change for `delay` seconds, then the wrapped animation.
package struct DelayAnimation: CustomAnimation, CustomStringConvertible {
    package let animation: Animation
    package let delay: TimeInterval

    package func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time >= delay else { return .zero }
        return animation.animate(value: value, time: time - delay, context: &context)
    }

    package func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        guard time >= delay else { return .zero }
        return animation.velocity(value: value, time: time - delay, context: context)
    }

    package func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                                  context: inout AnimationContext<V>) -> Bool {
        animation.shouldMerge(previous: previous, value: value, time: time, context: &context)
    }

    package var description: String { "\(animation).delay(\(delay))" }
}

/// The wrapped animation with time scaled by `speed`.
package struct SpeedAnimation: CustomAnimation, CustomStringConvertible {
    package let animation: Animation
    package let speed: Double

    package func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        animation.animate(value: value, time: time * speed, context: &context)
    }

    package func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        animation.velocity(value: value, time: time * speed, context: context)?.scaled(by: speed)
    }

    package func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                                  context: inout AnimationContext<V>) -> Bool {
        animation.shouldMerge(previous: previous, value: value, time: time, context: &context)
    }

    package var description: String { "\(animation).speed(\(speed))" }
}

/// `count` traversals of the wrapped animation (nil: forever); with
/// `autoreverses`, every second traversal runs backwards.
package struct RepeatAnimation: CustomAnimation, CustomStringConvertible {
    package let animation: Animation
    package let count: Int?
    package let autoreverses: Bool

    private func position(_ time: TimeInterval) -> (cycle: Int, local: TimeInterval)? {
        guard let d = animation.cycleDuration(), d > 0 else { return nil }
        var k = Int((time / d).rounded(.down))
        var local = time - Double(k) * d
        if let n = count, n > 0, k == n, local <= 1e-9 {
            // The end of the last traversal is still shown (05 §4: back at
            // 0 at 1.0 s, the jump to the model value comes after).
            k = n - 1
            local = d
        }
        return (k, autoreverses && k % 2 == 1 ? d - local : local)
    }

    package func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard let p = position(time) else { return nil }
        if let n = count, p.cycle >= n { return nil }
        var inner = context
        return animation.animate(value: value, time: p.local, context: &inner) ?? value
    }

    package func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        guard let p = position(time) else { return nil }
        let v = animation.velocity(value: value, time: p.local, context: context)
        return autoreverses && p.cycle % 2 == 1 ? v?.scaled(by: -1) : v
    }

    package var description: String {
        count.map { "\(animation).repeatCount(\($0), autoreverses: \(autoreverses))" }
            ?? "\(animation).repeatForever(autoreverses: \(autoreverses))"
    }
}

/// The wrapped animation, logically complete after a fixed time.
package struct LogicallyCompleteAnimation: CustomAnimation, CustomStringConvertible {
    package let animation: Animation
    package let after: TimeInterval

    package func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let r = animation.animate(value: value, time: time, context: &context)
        context.isLogicallyComplete = time >= after
        return r
    }

    package func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        animation.velocity(value: value, time: time, context: context)
    }

    package func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                                  context: inout AnimationContext<V>) -> Bool {
        animation.shouldMerge(previous: previous, value: value, time: time, context: &context)
    }

    package var description: String { "\(animation).logicallyComplete(after: \(after))" }
}
