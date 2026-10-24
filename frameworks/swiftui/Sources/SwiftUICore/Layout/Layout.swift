import Foundation

// The `Layout` protocol (04-layout.md §1; public documentation of `Layout`,
// level 1). A layout container answers sizes for proposals and places its
// subviews; the engine (Engine/) drives it.

/// Properties of a layout container that its subviews can observe.
public struct LayoutProperties: Sendable {
    /// The axis along which the container stacks its subviews, if any
    /// (`Divider` and `Spacer` orient themselves by it).
    public var stackOrientation: Axis?

    public init() { stackOrientation = nil }
}

/// A key for a value a view attaches for its layout container to read.
public protocol LayoutValueKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// A container that sizes and places its subviews.
public protocol Layout: Animatable, Sendable {
    static var layoutProperties: LayoutProperties { get }

    associatedtype Cache = Void
    typealias Subviews = LayoutSubviews

    func makeCache(subviews: Subviews) -> Cache
    func updateCache(_ cache: inout Cache, subviews: Subviews)
    func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat?
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat?
}

extension Layout {
    public static var layoutProperties: LayoutProperties { LayoutProperties() }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    /// Default: the union of every subview's preferences on every edge.
    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        var s = ViewSpacing.zero
        for sv in subviews { s.formUnion(sv.spacing) }
        return s
    }

    /// Default: the subviews' explicit values for the guide, at the positions
    /// where `placeSubviews` puts them, merged with the guide's rule
    /// (baselines: first = smallest, last = largest; other guides: mean).
    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? {
        mergedExplicitAlignment(guide.key, in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? {
        mergedExplicitAlignment(guide.key, in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }

    package func mergedExplicitAlignment(_ key: AlignmentKey, in bounds: CGRect, proposal: ProposedViewSize,
                                         subviews: Subviews, cache: inout Cache) -> CGFloat? {
        let sink = PlacementSink()
        placeSubviews(in: bounds, proposal: proposal, subviews: subviews.withSink(sink), cache: &cache)
        var values: [CGFloat] = []
        for sv in subviews {
            let pl = sink.resolved(sv, in: bounds, containerProposal: proposal)
            if let v = sv.node.dimensions(pl.proposal).explicitValue(key) {
                values.append(pl.origin[key.axis] - bounds.origin[key.axis] + v)
            }
        }
        return key.combine(values)
    }
}

extension Layout where Cache == () {
    public func makeCache(subviews: Subviews) -> Cache { () }
}

/// Collects the `place(at:anchor:proposal:)` calls a layout makes.
package final class PlacementSink {
    package struct Entry {
        var position: CGPoint
        var anchor: UnitPoint
        var proposal: ProposedViewSize
    }
    package private(set) var entries: [ObjectIdentifier: Entry] = [:]

    package init() {}

    func record(_ node: LayoutNode, _ e: Entry) { entries[ObjectIdentifier(node)] = e }

    /// Where `subview` ends up: its recorded placement, or (when the layout
    /// did not place it) centred in `bounds` with the container's proposal.
    package func resolved(_ subview: LayoutSubview, in bounds: CGRect,
                          containerProposal: ProposedViewSize) -> (origin: CGPoint, size: CGSize, proposal: ProposedViewSize) {
        if let e = entries[ObjectIdentifier(subview.node)] {
            let size = subview.node.sizeThatFits(e.proposal)
            return (CGPoint(x: e.position.x - e.anchor.x * size.width, y: e.position.y - e.anchor.y * size.height),
                    size, e.proposal)
        }
        let size = subview.node.sizeThatFits(containerProposal)
        return (CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), size, containerProposal)
    }
}

/// A proxy for one subview of a layout container.
public struct LayoutSubview: Equatable {
    package let node: LayoutNode
    package let sink: PlacementSink?

    package init(node: LayoutNode, sink: PlacementSink?) {
        self.node = node
        self.sink = sink
    }

    /// The size the subview answers for `proposal`.
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { node.sizeThatFits(proposal) }

    /// The subview's size and alignment guides for `proposal`.
    public func dimensions(in proposal: ProposedViewSize) -> ViewDimensions { node.dimensions(proposal) }

    /// The subview's layout priority (`layoutPriority(_:)`; 0 by default).
    public var priority: Double { node.layoutPriority }

    /// The subview's spacing preferences.
    public var spacing: ViewSpacing { node.spacing }

    /// Places the subview so that its `anchor` lies at `position`, sizing it
    /// for `proposal`.
    public func place(at position: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize) {
        sink?.record(node, .init(position: position, anchor: anchor, proposal: proposal))
    }

    /// The value the subview attached for `key` with `layoutValue(key:value:)`.
    public subscript<K: LayoutValueKey>(key: K.Type) -> K.Value {
        (node.layoutValue(ObjectIdentifier(key)) as? K.Value) ?? K.defaultValue
    }

    public static func == (lhs: LayoutSubview, rhs: LayoutSubview) -> Bool { lhs.node === rhs.node }
}

/// The subviews of a layout container, in order.
public struct LayoutSubviews: Equatable, RandomAccessCollection, @unchecked Sendable {
    public typealias Element = LayoutSubview
    public typealias Index = Int
    public typealias SubSequence = LayoutSubviews

    package let elements: [LayoutSubview]
    public let startIndex: Int
    /// The layout direction the container works in.
    public let layoutDirection: LayoutDirection

    package init(_ elements: [LayoutSubview], startIndex: Int = 0, layoutDirection: LayoutDirection = .leftToRight) {
        self.elements = elements
        self.startIndex = startIndex
        self.layoutDirection = layoutDirection
    }

    public var endIndex: Int { startIndex + elements.count }

    public subscript(index: Int) -> LayoutSubview { elements[index - startIndex] }

    public subscript(bounds: Range<Int>) -> LayoutSubviews {
        LayoutSubviews(Array(elements[(bounds.lowerBound - startIndex)..<(bounds.upperBound - startIndex)]),
                       startIndex: bounds.lowerBound, layoutDirection: layoutDirection)
    }

    /// The subviews at `indices`, in that order.
    public subscript<S: Sequence>(indices: S) -> LayoutSubviews where S.Element == Int {
        LayoutSubviews(indices.map { self[$0] }, layoutDirection: layoutDirection)
    }

    public static func == (lhs: LayoutSubviews, rhs: LayoutSubviews) -> Bool {
        lhs.startIndex == rhs.startIndex && lhs.elements == rhs.elements
    }

    package func withSink(_ sink: PlacementSink) -> LayoutSubviews {
        LayoutSubviews(elements.map { LayoutSubview(node: $0.node, sink: sink) }, startIndex: startIndex,
                       layoutDirection: layoutDirection)
    }
}
