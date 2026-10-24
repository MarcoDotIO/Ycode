import Foundation

// HStack / VStack / ZStack layouts (04-layout.md §4).

/// One participant in a stack-like distribution along an axis.
package struct DistributionItem {
    /// Length at a zero offer (the minimum).
    package var minLength: CGFloat
    /// Length at an infinite offer (the maximum).
    package var maxLength: CGFloat
    package var priority: Double
    /// Length answered for an offer.
    package var measure: (CGFloat) -> CGFloat

    package init(minLength: CGFloat, maxLength: CGFloat, priority: Double, measure: @escaping (CGFloat) -> CGFloat) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.priority = priority
        self.measure = measure
    }
}

/// Distributes `available` length among `items` (04 §4.2):
///
/// 1. Items are grouped by priority, highest first. A group is offered what
///    remains minus the minimum lengths of all lower-priority items.
/// 2. Within a group, the least flexible item (maximum − minimum) goes
///    first; ties go to the item with the larger minimum (inferred from
///    golden `hstack.threeColors.spacing0`, where two infinitely flexible
///    colours share what a `minWidth: 150` frame leaves), then to
///    declaration order. Each item is offered an equal share of what is
///    left (left ÷ items still to go) and its answer is subtracted.
///
/// Returns each item's (offer, length).
package func distribute(_ available: CGFloat, _ items: [DistributionItem]) -> [(offer: CGFloat, length: CGFloat)] {
    var result = Array(repeating: (offer: CGFloat(0), length: CGFloat(0)), count: items.count)
    func minus(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a.isInfinite ? a : a - b }
    var remaining = available
    let priorities = Set(items.map(\.priority)).sorted(by: >)
    for prio in priorities {
        let members = items.indices.filter { items[$0].priority == prio }
        let reserved = items.indices.filter { items[$0].priority < prio }.reduce(CGFloat(0)) { $0 + items[$1].minLength }
        var left = minus(remaining, reserved)
        let ordered = members.sorted { a, b in
            let fa = items[a].maxLength - items[a].minLength, fb = items[b].maxLength - items[b].minLength
            if fa != fb && !(fa.isInfinite && fb.isInfinite) { return fa < fb }
            if items[a].minLength != items[b].minLength { return items[a].minLength > items[b].minLength }
            return a < b
        }
        var count = ordered.count
        var used: CGFloat = 0
        for i in ordered {
            let offer = Swift.max(0, left / CGFloat(count))
            let length = items[i].measure(offer)
            result[i] = (offer, length)
            left = minus(left, length)
            used += length
            count -= 1
        }
        remaining = minus(remaining, used)
    }
    return result
}

/// Lines up `dims` on the guide `key` along `axis`: each view's position
/// from the start of the union extent, and the extent's length (infinite if
/// any view is infinite along `axis`). The extent always contains the
/// alignment line itself (R4: golden `hstack.baseline` fit[0×0] = 8 × 32.33 —
/// two 0 × 0 texts whose baselines lie 32.33 and 11.33 below their tops span
/// from the higher top to the line).
package func alignedExtent(_ dims: [ViewDimensions], _ key: AlignmentKey, _ axis: Axis) -> (positions: [CGFloat], extent: CGFloat) {
    guard !dims.isEmpty else { return ([], 0) }
    if dims.contains(where: { $0.size[axis].isInfinite }) {
        return (dims.map { _ in 0 }, .infinity)
    }
    let guides = dims.map { $0[key: key] }
    let before = max(guides.max()!, 0)
    let after = max(zip(guides, dims).map { g, d in d.size[axis] - g }.max()!, 0)
    return (guides.map { before - $0 }, before + after)
}

/// The shared algorithm of `HStackLayout` and `VStackLayout`.
package struct StackAlgorithm {
    package var axis: Axis
    /// The cross-axis guide.
    package var alignmentKey: AlignmentKey
    package var spacing: CGFloat?

    package struct Arrangement {
        /// Proposal per subview.
        var proposals: [ProposedViewSize]
        var dimensions: [ViewDimensions]
        /// Along-axis position per subview (from the stack's leading/top).
        var along: [CGFloat]
        /// Cross-axis position per subview (from the extent's start).
        var across: [CGFloat]
        var size: CGSize
    }

    /// Spacing between subview i and i + 1.
    package func gaps(_ subviews: LayoutSubviews) -> [CGFloat] {
        guard subviews.count > 1 else { return [] }
        let svs = Array(subviews)
        return (0..<(svs.count - 1)).map { i in
            spacing ?? svs[i].spacing.distance(to: svs[i + 1].spacing, along: axis)
        }
    }

    package func arrange(_ p: ProposedViewSize, _ subviews: LayoutSubviews) -> Arrangement {
        let svs = Array(subviews)
        let gaps = gaps(subviews)
        let totalGap = gaps.reduce(0, +)
        let across = p[axis.otherAxis]
        var proposals: [ProposedViewSize]
        if let along = p[axis] {
            let items = svs.map { sv in
                DistributionItem(
                    minLength: sv.node.length(along: axis, ProposedViewSize(axis, along: 0, across: across)),
                    maxLength: sv.node.length(along: axis, ProposedViewSize(axis, along: .infinity, across: across)),
                    priority: sv.priority,
                    measure: { sv.node.length(along: axis, ProposedViewSize(axis, along: $0, across: across)) })
            }
            let d = distribute(along - totalGap, items)
            proposals = d.map { ProposedViewSize(axis, along: $0.offer, across: across) }
        } else {
            proposals = svs.map { _ in ProposedViewSize(axis, along: nil, across: across) }
        }
        let dims = zip(svs, proposals).map { $0.dimensions(in: $1) }
        var pos: [CGFloat] = []
        var cursor: CGFloat = 0
        for (i, d) in dims.enumerated() {
            pos.append(cursor)
            cursor += d.size[axis] + (i < gaps.count ? gaps[i] : 0)
        }
        // Cross axis: line up the guide; the extent is the union.
        let (crossPos, extent) = alignedExtent(dims, alignmentKey, axis.otherAxis)
        return Arrangement(proposals: proposals, dimensions: dims, along: pos, across: crossPos,
                           size: CGSize(axis, along: svs.isEmpty ? 0 : cursor, across: extent))
    }

    package func place(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews) {
        let a = arrange(proposal, subviews)
        // When the bounds are larger than the arrangement across the axis,
        // put the extent where the guide's unit position says (top 0,
        // centre ½, bottom and baselines 1).
        let slack = bounds.size[axis.otherAxis] - a.size[axis.otherAxis]
        let unit = Swift.min(Swift.max(alignmentKey.defaultValue(for: CGSize(width: 1, height: 1)), 0), 1)
        let crossStart = bounds.origin[axis.otherAxis] + (abs(slack) < 0.001 ? 0 : slack * unit)
        for (i, sv) in subviews.enumerated() {
            let pt = CGPoint(axis, along: bounds.origin[axis] + a.along[i], across: crossStart + a.across[i])
            sv.place(at: pt, anchor: .topLeading, proposal: a.proposals[i])
        }
    }

    /// A stack's spacing: the first subview's leading (top) edge, the last
    /// one's trailing (bottom) edge, and the union of all subviews on the
    /// edges along the axis.
    package func spacing(_ subviews: LayoutSubviews) -> ViewSpacing {
        var s = ViewSpacing.zero
        let svs = Array(subviews)
        let (startEdge, endEdge): (Edge.Set, Edge.Set) = axis == .horizontal ? (.leading, .trailing) : (.top, .bottom)
        let sides: Edge.Set = axis == .horizontal ? .vertical : .horizontal
        for (i, sv) in svs.enumerated() {
            var edges = sides
            if i == 0 { edges.formUnion(startEdge) }
            if i == svs.count - 1 { edges.formUnion(endEdge) }
            s.formUnion(sv.spacing, edges: edges)
        }
        return s
    }
}

/// Arranges subviews in a horizontal line.
public struct HStackLayout: Layout {
    public var alignment: VerticalAlignment
    public var spacing: CGFloat?

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public typealias Cache = Void
    public typealias AnimatableData = EmptyAnimatableData

    public static var layoutProperties: LayoutProperties {
        var p = LayoutProperties()
        p.stackOrientation = .horizontal
        return p
    }

    private var algorithm: StackAlgorithm { StackAlgorithm(axis: .horizontal, alignmentKey: alignment.key, spacing: spacing) }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        algorithm.arrange(proposal, subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        algorithm.place(in: bounds, proposal: proposal, subviews: subviews)
    }

    public func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing { algorithm.spacing(subviews) }
}

/// Arranges subviews in a vertical line.
public struct VStackLayout: Layout {
    public var alignment: HorizontalAlignment
    public var spacing: CGFloat?

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public typealias Cache = Void
    public typealias AnimatableData = EmptyAnimatableData

    public static var layoutProperties: LayoutProperties {
        var p = LayoutProperties()
        p.stackOrientation = .vertical
        return p
    }

    private var algorithm: StackAlgorithm { StackAlgorithm(axis: .vertical, alignmentKey: alignment.key, spacing: spacing) }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        algorithm.arrange(proposal, subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        algorithm.place(in: bounds, proposal: proposal, subviews: subviews)
    }

    public func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing { algorithm.spacing(subviews) }
}

/// Overlays subviews, aligned on both axes (04 §4.4): every subview gets the
/// stack's proposal; the stack's size is the union of the aligned subviews.
public struct ZStackLayout: Layout {
    public var alignment: Alignment

    public init(alignment: Alignment = .center) { self.alignment = alignment }

    public typealias Cache = Void
    public typealias AnimatableData = EmptyAnimatableData

    private struct Arrangement {
        var origins: [CGPoint]
        var size: CGSize
    }

    private func arrange(_ p: ProposedViewSize, _ subviews: Subviews) -> Arrangement {
        let dims = subviews.map { $0.dimensions(in: p) }
        guard !dims.isEmpty else { return Arrangement(origins: [], size: .zero) }
        let (xs, w) = alignedExtent(dims, alignment.horizontal.key, .horizontal)
        let (ys, h) = alignedExtent(dims, alignment.vertical.key, .vertical)
        return Arrangement(origins: zip(xs, ys).map { CGPoint(x: $0, y: $1) }, size: CGSize(width: w, height: h))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(proposal, subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let a = arrange(proposal, subviews)
        let ux = Swift.min(Swift.max(alignment.horizontal.key.defaultValue(for: CGSize(width: 1, height: 1)), 0), 1)
        let uy = Swift.min(Swift.max(alignment.vertical.key.defaultValue(for: CGSize(width: 1, height: 1)), 0), 1)
        let dx = abs(bounds.width - a.size.width) < 0.001 ? 0 : (bounds.width - a.size.width) * ux
        let dy = abs(bounds.height - a.size.height) < 0.001 ? 0 : (bounds.height - a.size.height) * uy
        for (i, sv) in subviews.enumerated() {
            sv.place(at: CGPoint(x: bounds.minX + dx + a.origins[i].x, y: bounds.minY + dy + a.origins[i].y),
                     anchor: .topLeading, proposal: proposal)
        }
    }
}
