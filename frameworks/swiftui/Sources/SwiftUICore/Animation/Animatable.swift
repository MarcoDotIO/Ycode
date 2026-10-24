import Foundation

// Vector arithmetic and animatable data (api-inventory.md, "Animation,
// transactions and transitions"). Behaviour: a vector space over Double
// (addition, scaling, squared magnitude), used by animations to interpolate.

/// A type that can be added, subtracted and scaled, so that values can be
/// interpolated.
public protocol VectorArithmetic: AdditiveArithmetic {
    /// Multiplies every component by `rhs`.
    mutating func scale(by rhs: Double)
    /// The dot product of the value with itself.
    var magnitudeSquared: Double { get }
}

extension VectorArithmetic {
    /// A copy multiplied by `rhs`.
    public func scaled(by rhs: Double) -> Self {
        var copy = self
        copy.scale(by: rhs)
        return copy
    }

    /// Moves the value towards `other` by `amount` (0 = self, 1 = other).
    public mutating func interpolate(towards other: Self, amount: Double) {
        var delta = other - self
        delta.scale(by: amount)
        self += delta
    }

    /// The value moved towards `other` by `amount`.
    public func interpolated(towards other: Self, amount: Double) -> Self {
        var copy = self
        copy.interpolate(towards: other, amount: amount)
        return copy
    }
}

extension Double: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= rhs }
    public var magnitudeSquared: Double { self * self }
}

extension Float: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= Float(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

extension CGFloat: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= CGFloat(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

/// Animatable data with no components.
public struct EmptyAnimatableData: VectorArithmetic, Sendable {
    public init() {}
    public static var zero: EmptyAnimatableData { .init() }
    public static func += (lhs: inout EmptyAnimatableData, rhs: EmptyAnimatableData) {}
    public static func -= (lhs: inout EmptyAnimatableData, rhs: EmptyAnimatableData) {}
    public static func + (lhs: EmptyAnimatableData, rhs: EmptyAnimatableData) -> EmptyAnimatableData { .init() }
    public static func - (lhs: EmptyAnimatableData, rhs: EmptyAnimatableData) -> EmptyAnimatableData { .init() }
    public mutating func scale(by rhs: Double) {}
    public var magnitudeSquared: Double { 0 }
    public static func == (a: EmptyAnimatableData, b: EmptyAnimatableData) -> Bool { true }
}

/// Two animatable values treated as one vector.
public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    public static var zero: AnimatablePair { .init(.zero, .zero) }
    public static func += (lhs: inout AnimatablePair, rhs: AnimatablePair) {
        lhs.first += rhs.first
        lhs.second += rhs.second
    }
    public static func -= (lhs: inout AnimatablePair, rhs: AnimatablePair) {
        lhs.first -= rhs.first
        lhs.second -= rhs.second
    }
    public static func + (lhs: AnimatablePair, rhs: AnimatablePair) -> AnimatablePair {
        .init(lhs.first + rhs.first, lhs.second + rhs.second)
    }
    public static func - (lhs: AnimatablePair, rhs: AnimatablePair) -> AnimatablePair {
        .init(lhs.first - rhs.first, lhs.second - rhs.second)
    }
    public mutating func scale(by rhs: Double) {
        first.scale(by: rhs)
        second.scale(by: rhs)
    }
    public var magnitudeSquared: Double { first.magnitudeSquared + second.magnitudeSquared }
    public static func == (a: AnimatablePair, b: AnimatablePair) -> Bool {
        a.first == b.first && a.second == b.second
    }
}

extension AnimatablePair: Sendable where First: Sendable, Second: Sendable {}

/// A type whose value can be interpolated through `animatableData`.
public protocol Animatable {
    associatedtype AnimatableData: VectorArithmetic = EmptyAnimatableData
    var animatableData: AnimatableData { get set }
}

extension Animatable where AnimatableData == EmptyAnimatableData {
    public var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }
}

extension Animatable where Self: VectorArithmetic {
    public var animatableData: Self {
        get { self }
        set { self = newValue }
    }
}

// Geometry types animate component-wise.
extension CGPoint: Animatable {
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(x, y) }
        set { (x, y) = (newValue.first, newValue.second) }
    }
}

extension CGSize: Animatable {
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(width, height) }
        set { (width, height) = (newValue.first, newValue.second) }
    }
}

extension CGRect: Animatable {
    public var animatableData: AnimatablePair<CGPoint.AnimatableData, CGSize.AnimatableData> {
        get { .init(origin.animatableData, size.animatableData) }
        set {
            origin.animatableData = newValue.first
            size.animatableData = newValue.second
        }
    }
}

// Scalars animate as themselves (keyframe tracks and animatable views over
// plain numbers).
extension Double: Animatable {}
extension Float: Animatable {}
extension CGFloat: Animatable {}
