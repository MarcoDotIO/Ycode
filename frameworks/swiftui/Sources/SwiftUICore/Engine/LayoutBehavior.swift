import Foundation

/// Drives any `Layout` (built-in stacks and user layouts alike) as a node
/// behaviour. The layout's cache lives in the node and is created on first
/// use.
package struct LayoutBehavior<L: Layout>: NodeBehavior {
    package var layout: L

    package init(_ layout: L) { self.layout = layout }

    package func childStackOrientation(inherited: Axis?, child index: Int) -> Axis? {
        if let any = layout as? AnyLayout { return any.stackOrientation }
        return L.layoutProperties.stackOrientation
    }

    private func subviews(_ node: LayoutNode, sink: PlacementSink? = nil) -> LayoutSubviews {
        LayoutSubviews(node.children.filter { !$0.behavior.isEmpty }.map { LayoutSubview(node: $0, sink: sink) },
                       layoutDirection: node.context.environment.layoutDirection)
    }

    private func withCache<R>(_ node: LayoutNode, _ subviews: LayoutSubviews, _ body: (inout L.Cache) -> R) -> R {
        var cache = (node.layoutCache as? L.Cache) ?? layout.makeCache(subviews: subviews)
        let r = body(&cache)
        node.layoutCache = cache
        return r
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let sv = subviews(node)
        return withCache(node, sv) { layout.sizeThatFits(proposal: p, subviews: sv, cache: &$0) }
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let sink = PlacementSink()
        let sv = subviews(node, sink: sink)
        let bounds = CGRect(origin: .zero, size: size)
        withCache(node, sv) { layout.placeSubviews(in: bounds, proposal: proposal, subviews: sv, cache: &$0) }
        var result: [ChildPlacement] = []
        for (i, child) in node.children.enumerated() where !child.behavior.isEmpty {
            let r = sink.resolved(LayoutSubview(node: child, sink: nil), in: bounds, containerProposal: proposal)
            result.append(ChildPlacement(index: i, origin: r.origin, size: r.size, proposal: r.proposal))
        }
        return result
    }

    package func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize,
                                   node: LayoutNode) -> CGFloat? {
        let sv = subviews(node)
        let bounds = CGRect(origin: .zero, size: size)
        return withCache(node, sv) { cache in
            key.axis == .horizontal
                ? layout.explicitAlignment(of: HorizontalAlignment(key: key), in: bounds, proposal: proposal,
                                           subviews: sv, cache: &cache)
                : layout.explicitAlignment(of: VerticalAlignment(key: key), in: bounds, proposal: proposal,
                                           subviews: sv, cache: &cache)
        }
    }

    package func spacing(node: LayoutNode) -> ViewSpacing {
        let sv = subviews(node)
        return withCache(node, sv) { layout.spacing(subviews: sv, cache: &$0) }
    }
}

extension HorizontalAlignment {
    package init(key: AlignmentKey) { self.key = key }
}

extension VerticalAlignment {
    package init(key: AlignmentKey) { self.key = key }
}
