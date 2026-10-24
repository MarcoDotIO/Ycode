import Foundation

/// Inset distances for the four edges of a rectangle, in layout-direction
/// terms.
public struct EdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init() { self.init(top: 0, leading: 0, bottom: 0, trailing: 0) }

    /// The same `length` on every edge in `edges`, zero elsewhere.
    package init(_ edges: Edge.Set, _ length: CGFloat) {
        self.init(top: edges.contains(.top) ? length : 0,
                  leading: edges.contains(.leading) ? length : 0,
                  bottom: edges.contains(.bottom) ? length : 0,
                  trailing: edges.contains(.trailing) ? length : 0)
    }

    /// Insets grown by `amount` on the given edges (a negative amount shrinks).
    public func inset(by amount: CGFloat, edges: Edge.Set = .all) -> EdgeInsets {
        var r = self
        if edges.contains(.top) { r.top += amount }
        if edges.contains(.leading) { r.leading += amount }
        if edges.contains(.bottom) { r.bottom += amount }
        if edges.contains(.trailing) { r.trailing += amount }
        return r
    }

    /// Rounds every inset to a multiple of `m` using `rule`.
    public mutating func round(_ rule: FloatingPointRoundingRule, toMultipleOf m: CGFloat) {
        top = top.roundedToMultiple(of: m, rule)
        leading = leading.roundedToMultiple(of: m, rule)
        bottom = bottom.roundedToMultiple(of: m, rule)
        trailing = trailing.roundedToMultiple(of: m, rule)
    }

    public mutating func round(toMultipleOf m: CGFloat) {
        round(.toNearestOrAwayFromZero, toMultipleOf: m)
    }

    public func rounded(_ rule: FloatingPointRoundingRule, toMultipleOf m: CGFloat) -> EdgeInsets {
        var r = self
        r.round(rule, toMultipleOf: m)
        return r
    }

    public func rounded(toMultipleOf m: CGFloat) -> EdgeInsets {
        rounded(.toNearestOrAwayFromZero, toMultipleOf: m)
    }

    /// Whether every inset is within `epsilon` of the other's.
    public func approximates(_ other: EdgeInsets, epsilon: CGFloat) -> Bool {
        abs(top - other.top) <= epsilon && abs(leading - other.leading) <= epsilon
            && abs(bottom - other.bottom) <= epsilon && abs(trailing - other.trailing) <= epsilon
    }

    /// Sum of the leading and trailing insets.
    package var horizontal: CGFloat { leading + trailing }
    /// Sum of the top and bottom insets.
    package var vertical: CGFloat { top + bottom }
}

extension EdgeInsets: Animatable {
    public var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { .init(top, .init(leading, .init(bottom, trailing))) }
        set {
            top = newValue.first
            leading = newValue.second.first
            bottom = newValue.second.second.first
            trailing = newValue.second.second.second
        }
    }
}

extension CGFloat {
    /// Rounds to a multiple of `m` (pixel-grid rounding when `m` = 1/scale).
    package func roundedToMultiple(of m: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat {
        guard m > 0, isFinite else { return self }
        return (self / m).rounded(rule) * m
    }
}

/// A normalized 2D point in a view's bounds: (0, 0) is the top-leading
/// corner, (1, 1) the bottom-trailing corner.
public struct UnitPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init() { self.init(x: 0, y: 0) }
    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)

    /// The point at this unit position inside a rectangle of `size`.
    package func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

extension UnitPoint: Animatable {
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(x, y) }
        set { (x, y) = (newValue.first, newValue.second) }
    }
}

extension UnitPoint: Codable {
    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decode(CGFloat.self, forKey: .x), y: try c.decode(CGFloat.self, forKey: .y))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
    }
}

/// A geometric angle, stored in radians.
public struct Angle: Hashable, Comparable, Sendable {
    public var radians: Double
    public var degrees: Double {
        get { radians * 180 / .pi }
        set { radians = newValue * .pi / 180 }
    }

    public init() { radians = 0 }
    public init(radians: Double) { self.radians = radians }
    public init(degrees: Double) { self.radians = degrees * .pi / 180 }

    public static func radians(_ r: Double) -> Angle { Angle(radians: r) }
    public static func degrees(_ d: Double) -> Angle { Angle(degrees: d) }
    public static let zero = Angle()

    public static func < (lhs: Angle, rhs: Angle) -> Bool { lhs.radians < rhs.radians }
}

extension Angle: Animatable {
    public var animatableData: Double {
        get { radians }
        set { radians = newValue }
    }
}

extension Angle: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(radians: try decoder.singleValueContainer().decode(Double.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(radians)
    }
}

// Arithmetic on angles, used internally (not part of the inventoried API).
extension Angle {
    package static func + (lhs: Angle, rhs: Angle) -> Angle { Angle(radians: lhs.radians + rhs.radians) }
    package static func - (lhs: Angle, rhs: Angle) -> Angle { Angle(radians: lhs.radians - rhs.radians) }
    package static prefix func - (a: Angle) -> Angle { Angle(radians: -a.radians) }
    package static func * (lhs: Angle, rhs: Double) -> Angle { Angle(radians: lhs.radians * rhs) }
    package static func / (lhs: Angle, rhs: Double) -> Angle { Angle(radians: lhs.radians / rhs) }
}
