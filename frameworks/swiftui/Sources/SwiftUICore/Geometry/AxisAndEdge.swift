import Foundation

// Axis and Edge: names from specs/frameworks/swiftui/api-inventory.md
// ("Layout and geometry"). Raw values follow declaration order.

/// The horizontal or vertical dimension of a two-dimensional layout.
public enum Axis: Int8, CaseIterable, CustomStringConvertible, Sendable {
    case horizontal = 0
    case vertical = 1

    /// The other axis of the pair.
    public var otherAxis: Axis { self == .horizontal ? .vertical : .horizontal }

    /// The two edges that run perpendicular to this axis' direction of travel,
    /// i.e. the edges a stack along this axis starts and ends at.
    public var perpendicularEdges: Edge.Set {
        self == .horizontal ? [.leading, .trailing] : [.top, .bottom]
    }

    public var description: String { self == .horizontal ? "horizontal" : "vertical" }

    /// A set of axes.
    public struct Set: OptionSet, Sendable, Hashable {
        public typealias Element = Axis.Set
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Axis.Set(rawValue: 1 << 0)
        public static let vertical = Axis.Set(rawValue: 1 << 1)

        package init(_ axis: Axis) { self = axis == .horizontal ? .horizontal : .vertical }
    }
}

/// An edge of a rectangle, in layout-direction terms (leading/trailing).
public enum Edge: Int8, CaseIterable, Sendable, Hashable {
    case top = 0, leading = 1, bottom = 2, trailing = 3

    /// A set of edges.
    public struct Set: OptionSet, Sendable, Hashable {
        public typealias Element = Edge.Set
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Edge.Set(rawValue: 1 << 0)
        public static let leading = Edge.Set(rawValue: 1 << 1)
        public static let bottom = Edge.Set(rawValue: 1 << 2)
        public static let trailing = Edge.Set(rawValue: 1 << 3)
        public static let all: Edge.Set = [.top, .leading, .bottom, .trailing]
        public static let horizontal: Edge.Set = [.leading, .trailing]
        public static let vertical: Edge.Set = [.top, .bottom]

        /// The set containing just `edge`.
        public init(_ edge: Edge) { self.init(rawValue: 1 << edge.rawValue) }
    }
}

/// The two vertical edges (top, bottom).
public enum VerticalEdge: Int8, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case top = 0, bottom = 1

    public struct Set: OptionSet, Sendable, Hashable {
        public typealias Element = VerticalEdge.Set
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1 << 0)
        public static let bottom = Set(rawValue: 1 << 1)
        public static let all: Set = [.top, .bottom]
        public init(_ e: VerticalEdge) { self.init(rawValue: 1 << e.rawValue) }
    }
}

/// The two horizontal edges (leading, trailing).
public enum HorizontalEdge: Int8, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case leading = 0, trailing = 1

    public struct Set: OptionSet, Sendable, Hashable {
        public typealias Element = HorizontalEdge.Set
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let leading = Set(rawValue: 1 << 0)
        public static let trailing = Set(rawValue: 1 << 1)
        public static let all: Set = [.leading, .trailing]
        public init(_ e: HorizontalEdge) { self.init(rawValue: 1 << e.rawValue) }
    }
}

/// The direction in which content is laid out horizontally.
public enum LayoutDirection: Hashable, CaseIterable, Sendable {
    case leftToRight
    case rightToLeft
}

/// How a view fills the space it is given while keeping its aspect ratio.
public enum ContentMode: Hashable, CaseIterable, Sendable {
    case fit
    case fill
}
