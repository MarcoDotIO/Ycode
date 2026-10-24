import Foundation

// The animation protocol (05-animation.md §1; api-inventory.md "Animation,
// transactions and transitions"). An animation is a function of elapsed time
// that moves a vector from zero towards a target delta: `animate` returns the
// part of `value` reached at `time`, or nil once the animation is finished.
// The runtime adds the result to the value the animation started from.

/// A type that defines how an animatable value changes over time.
public protocol CustomAnimation: Hashable, Sendable {
    /// The value reached at `time` on the way from zero to `value`, or nil
    /// when the animation has finished.
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V?

    /// The velocity at `time`, if the animation can compute it.
    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V?

    /// Whether this (new) animation takes over the state of `previous`, which
    /// is still running on the same value (`time` is the previous animation's
    /// elapsed time, `context` its context, which this method may change).
    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                          context: inout AnimationContext<V>) -> Bool
}

extension CustomAnimation {
    public func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? { nil }

    public func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval,
                                                 context: inout AnimationContext<V>) -> Bool { false }
}

/// A key for a value an animation keeps in its `AnimationState`.
public protocol AnimationStateKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// Storage an animation keeps between calls (for example a velocity carried
/// over from a merged animation).
public struct AnimationState<Value: VectorArithmetic> {
    private var storage: [ObjectIdentifier: Any] = [:]
    /// The velocity inherited from a merged animation (runtime use).
    package var inheritedVelocity: Value?

    public init() {}

    public subscript<K: AnimationStateKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)].map { $0 as! K.Value } ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

/// What an animation sees while it runs: its state, whether it has reached
/// its logical end, and the environment of the view being animated.
public struct AnimationContext<Value: VectorArithmetic> {
    public var state: AnimationState<Value>
    /// Set by the animation when it is logically complete (05 §4: curves at
    /// their duration, springs at their perceptual duration); completion
    /// handlers with `.logicallyComplete` criteria run then.
    public var isLogicallyComplete: Bool
    package var _environment: EnvironmentValues

    package init(state: AnimationState<Value> = AnimationState(), isLogicallyComplete: Bool = false,
                 environment: EnvironmentValues = EnvironmentValues()) {
        self.state = state
        self.isLogicallyComplete = isLogicallyComplete
        self._environment = environment
    }

    public var environment: EnvironmentValues { _environment }

    /// The same context with another state (for animations that drive a
    /// value of another type).
    public func withState<T: VectorArithmetic>(_ state: AnimationState<T>) -> AnimationContext<T> {
        AnimationContext<T>(state: state, isLogicallyComplete: isLogicallyComplete, environment: _environment)
    }
}
