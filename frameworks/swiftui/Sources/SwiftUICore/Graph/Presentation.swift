import Foundation

// What is rendered (R6): the last layout tree with every animation applied.
// There is no display list before R5, so this module reports, for named
// layout nodes, the presented frame (root coordinates, left to right) and the
// presented opacity. A node's frame is its layout frame in its parent's
// coordinates as animated by its view's geometry animator, composed with its
// ancestors' presented frames and with the presented values of render
// effects (offset, scale, rotation; Animation/Effects.swift). Removed views
// still transitioning out are included, at the place where they were last
// laid out.

/// A rendered layer: frame and opacity.
package struct PresentedLayer: Equatable {
    package var frame: CGRect
    package var opacity: Double
}

extension ViewGraph {
    /// Presented frames and opacities of the named layout nodes.
    package func presentedLayers() -> [String: PresentedLayer] {
        var out: [String: PresentedLayer] = [:]
        let mirror = layoutResult?.mirrorWidth
        if let root = layoutResult?.root {
            Self.present(root, parent: .identity, opacity: 1, mirror: mirror, into: &out)
        }
        for g in ghosts where g.node.isAlive && (g.parent?.isAlive ?? false) {
            let nodes = rootLowering(of: g.node)
            let engine = LayoutEngine(environment: environment, textMeasurer: layout?.textMeasurer ?? TypesetTextMeasurer.shared,
                                      symbols: layout?.symbols ?? StubSymbolProvider())
            for (n, p) in zip(nodes, g.placements) {
                engine.prepare(n)
                n.place(at: p.origin, size: n.sizeThatFits(p.proposal), proposal: p.proposal, parentTransform: p.parent)
                Self.present(n, parent: p.parent, opacity: 1, mirror: mirror, into: &out)
            }
        }
        return out
    }

    /// The presented layer of the layout node named `name`.
    package func presented(_ name: String) -> PresentedLayer? { presentedLayers()[name] }

    private func rootLowering(of node: ViewNode) -> [LayoutNode] {
        beginLowering()
        return node.lower()
    }

    private static func present(_ n: LayoutNode, parent: AffineTransform2D, opacity: Double, mirror: CGFloat?,
                                into out: inout [String: PresentedLayer]) {
        guard let origin = n.placedLocalOrigin, let size = n.placedSize else { return }
        var local = CGRect(origin: origin, size: size)
        if let creator = n.creator as? ViewNode, let f = creator.presentedFrame(index: n.creatorIndex) { local = f }
        let t = parent.concatenating(.translation(local.minX, local.minY))
        var op = opacity
        var childT = t
        switch n.presentation {
        case .opacity(let f)?:
            op *= f()
        case .transform(let f)?:
            childT = t.concatenating(f(local.size))
        case nil:
            if let ct = n.behavior.childTransform(size: local.size) { childT = t.concatenating(ct) }
        }
        if let name = n.name {
            var frame = t.boundingBox(of: CGRect(origin: .zero, size: local.size))
            if let w = mirror { frame.origin.x = w - frame.origin.x - frame.width }
            out[name] = PresentedLayer(frame: frame, opacity: op)
        }
        for c in n.children { present(c, parent: childT, opacity: op, mirror: mirror, into: &out) }
    }
}
