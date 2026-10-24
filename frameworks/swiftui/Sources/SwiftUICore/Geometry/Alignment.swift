import Foundation

// Alignment guides (04-layout.md §4.3; api-inventory.md "Layout and geometry").
//
// An alignment guide is a function from a view's dimensions to a position
// along one axis. Every view has a default value for every guide (from the
// guide's `AlignmentID.defaultValue(in:)`); some views also carry *explicit*
// values (text baselines, `alignmentGuide(_:computeValue:)`, containers that
// merge their children's explicit values).

/// Identifies an alignment guide and supplies its default value.
public protocol AlignmentID {
    /// The guide's value for a view that has no explicit value for it.
    static func defaultValue(in context: ViewDimensions) -> CGFloat
}

/// Built-in guides that merge their children's explicit values with a rule
/// other than the default (the mean). Not public: the observed rule for the
/// text baselines is "first = smallest, last = largest" (golden-layout.md,
/// `hstack.center`, `hstack.textImage`, `vstack.texts`, `grid`).
package protocol ExplicitCombiningAlignmentID: AlignmentID {
    static func combine(_ values: [CGFloat]) -> CGFloat?
}

/// The opaque key of an alignment guide on one axis. Keys are ordered by the
/// order in which their guides were first used in this process.
public struct AlignmentKey: Hashable, Comparable, Sendable {
    package let index: Int
    package let axis: Axis

    package init(id: any AlignmentID.Type, axis: Axis) {
        self.index = AlignmentRegistry.shared.index(of: id)
        self.axis = axis
    }

    package var id: any AlignmentID.Type { AlignmentRegistry.shared.type(at: index) }

    public static func < (lhs: AlignmentKey, rhs: AlignmentKey) -> Bool {
        (lhs.index, lhs.axis.rawValue) < (rhs.index, rhs.axis.rawValue)
    }

    /// The guide's default value for a view of `size` (no explicit values).
    package func defaultValue(for size: CGSize) -> CGFloat {
        id.defaultValue(in: ViewDimensions(size: size))
    }

    package func defaultValue(in d: ViewDimensions) -> CGFloat { id.defaultValue(in: d) }

    /// Merges explicit values produced by several children.
    package func combine(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        if let c = id as? any ExplicitCombiningAlignmentID.Type { return c.combine(values) }
        return values.reduce(0, +) / CGFloat(values.count)
    }
}

/// Process-wide numbering of alignment identifiers.
package final class AlignmentRegistry: @unchecked Sendable {
    package static let shared = AlignmentRegistry()
    private let lock = NSLock()
    private var indices: [ObjectIdentifier: Int] = [:]
    private var types: [any AlignmentID.Type] = []

    func index(of id: any AlignmentID.Type) -> Int {
        lock.lock(); defer { lock.unlock() }
        let oid = ObjectIdentifier(id)
        if let i = indices[oid] { return i }
        types.append(id)
        indices[oid] = types.count - 1
        return types.count - 1
    }

    func type(at index: Int) -> any AlignmentID.Type {
        lock.lock(); defer { lock.unlock() }
        return types[index]
    }
}

/// A guide along the horizontal axis (it gives an x position).
public struct HorizontalAlignment: Equatable, Sendable {
    public let key: AlignmentKey

    public init(_ id: any AlignmentID.Type) { key = AlignmentKey(id: id, axis: .horizontal) }

    /// Merges explicit values of this guide from several views.
    public func combineExplicit(_ values: some Sequence<CGFloat>) -> CGFloat? {
        key.combine(Array(values))
    }

    private enum Leading: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { 0 }
    }
    private enum Center: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.width / 2 }
    }
    private enum Trailing: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.width }
    }

    public static let leading = HorizontalAlignment(Leading.self)
    public static let center = HorizontalAlignment(Center.self)
    public static let trailing = HorizontalAlignment(Trailing.self)
}

/// A guide along the vertical axis (it gives a y position).
public struct VerticalAlignment: Equatable, Sendable {
    public let key: AlignmentKey

    public init(_ id: any AlignmentID.Type) { key = AlignmentKey(id: id, axis: .vertical) }

    public func combineExplicit(_ values: some Sequence<CGFloat>) -> CGFloat? {
        key.combine(Array(values))
    }

    private enum Top: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { 0 }
    }
    private enum Center: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height / 2 }
    }
    private enum Bottom: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height }
    }
    // Baselines default to the bottom edge (golden `geometryReader`: 500/500
    // for a 500-tall view without text).
    private enum FirstTextBaseline: ExplicitCombiningAlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height }
        static func combine(_ values: [CGFloat]) -> CGFloat? { values.min() }
    }
    private enum LastTextBaseline: ExplicitCombiningAlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height }
        static func combine(_ values: [CGFloat]) -> CGFloat? { values.max() }
    }

    public static let top = VerticalAlignment(Top.self)
    public static let center = VerticalAlignment(Center.self)
    public static let bottom = VerticalAlignment(Bottom.self)
    public static let firstTextBaseline = VerticalAlignment(FirstTextBaseline.self)
    public static let lastTextBaseline = VerticalAlignment(LastTextBaseline.self)
}

/// A pair of horizontal and vertical guides.
public struct Alignment: Equatable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
    public static let centerFirstTextBaseline = Alignment(horizontal: .center, vertical: .firstTextBaseline)
    public static let centerLastTextBaseline = Alignment(horizontal: .center, vertical: .lastTextBaseline)
    public static let leadingFirstTextBaseline = Alignment(horizontal: .leading, vertical: .firstTextBaseline)
    public static let leadingLastTextBaseline = Alignment(horizontal: .leading, vertical: .lastTextBaseline)
    public static let trailingFirstTextBaseline = Alignment(horizontal: .trailing, vertical: .firstTextBaseline)
    public static let trailingLastTextBaseline = Alignment(horizontal: .trailing, vertical: .lastTextBaseline)
}

/// Supplies a view's explicit alignment-guide values, computed on demand and
/// memoised.
package final class ExplicitGuides {
    private let lookup: (AlignmentKey) -> CGFloat?
    private var memo: [AlignmentKey: CGFloat?] = [:]

    package init(_ lookup: @escaping (AlignmentKey) -> CGFloat?) { self.lookup = lookup }

    package func value(_ key: AlignmentKey) -> CGFloat? {
        if let v = memo[key] { return v }
        let v = lookup(key)
        memo[key] = .some(v)
        return v
    }
}

/// A view's size together with its alignment guides.
public struct ViewDimensions: Equatable {
    package let size: CGSize
    package let guides: ExplicitGuides?

    package init(size: CGSize, guides: ExplicitGuides? = nil) {
        self.size = size
        self.guides = guides
    }

    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }

    public subscript(guide: HorizontalAlignment) -> CGFloat { self[key: guide.key] }
    public subscript(guide: VerticalAlignment) -> CGFloat { self[key: guide.key] }
    public subscript(explicit guide: HorizontalAlignment) -> CGFloat? { explicitValue(guide.key) }
    public subscript(explicit guide: VerticalAlignment) -> CGFloat? { explicitValue(guide.key) }

    /// Explicit value if any, otherwise the guide's default.
    package subscript(key key: AlignmentKey) -> CGFloat {
        explicitValue(key) ?? key.defaultValue(in: ViewDimensions(size: size))
    }

    package func explicitValue(_ key: AlignmentKey) -> CGFloat? { guides?.value(key) }

    public static func == (lhs: ViewDimensions, rhs: ViewDimensions) -> Bool {
        lhs.size == rhs.size && lhs.guides === rhs.guides
    }
}
