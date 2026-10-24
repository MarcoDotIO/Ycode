import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

/// `Divider` (04-layout.md §2): a hairline one device pixel thick. Outside a
/// horizontal stack it is horizontal (width = proposal, `nil` → 10); inside
/// an `HStack` it turns vertical and takes the proposed height (`nil` → 10).
package struct DividerLeaf: NodeBehavior {
    package init() {}

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let thickness = node.context.environment.pixelLength
        if node.stackOrientation == .horizontal {
            return CGSize(width: thickness, height: p.height ?? 10)
        }
        return CGSize(width: p.width ?? 10, height: thickness)
    }
}

/// `ViewThatFits` (04 §6): the first child whose ideal size fits the
/// proposal along the constrained axes; if none fits, the last child.
package struct ViewThatFitsBehavior: NodeBehavior {
    package var axes: Axis.Set

    package init(in axes: Axis.Set = [.horizontal, .vertical]) { self.axes = axes }

    package func childStackOrientation(inherited: Axis?, child index: Int) -> Axis? { inherited }

    package func choice(_ p: ProposedViewSize, _ node: LayoutNode) -> Int? {
        let kids = node.children.indices.filter { !node.children[$0].behavior.isEmpty }
        guard let last = kids.last else { return nil }
        let eps: CGFloat = 0.001
        for i in kids {
            let ideal = node.children[i].sizeThatFits(ProposedViewSize(
                width: axes.contains(.horizontal) ? nil : p.width,
                height: axes.contains(.vertical) ? nil : p.height))
            let fitsW = !axes.contains(.horizontal) || p.width.map { ideal.width <= $0 + eps } ?? true
            let fitsH = !axes.contains(.vertical) || p.height.map { ideal.height <= $0 + eps } ?? true
            if fitsW && fitsH { return i }
        }
        return last
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        choice(p, node).map { node.children[$0].sizeThatFits(p) } ?? .zero
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        guard let i = choice(proposal, node) else { return [] }
        return [ChildPlacement(index: i, origin: .zero, size: node.children[i].sizeThatFits(proposal), proposal: proposal)]
    }

    package func explicitAlignment(_ key: AlignmentKey, size: CGSize, proposal: ProposedViewSize,
                                   node: LayoutNode) -> CGFloat? {
        guard let i = choice(proposal, node) else { return nil }
        return node.childExplicitAlignment(key, child: i, size: size, proposal: proposal)
    }

    package func spacing(node: LayoutNode) -> ViewSpacing {
        var s = ViewSpacing.zero
        for c in node.children { s.formUnion(c.spacing) }
        return s
    }
}

extension LayoutNode {
    package static func divider() -> LayoutNode { LayoutNode(DividerLeaf()) }

    package static func viewThatFits(in axes: Axis.Set = [.horizontal, .vertical], _ children: [LayoutNode]) -> LayoutNode {
        LayoutNode(ViewThatFitsBehavior(in: axes), children: children)
    }
}
