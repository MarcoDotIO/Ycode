import Foundation

// `matchedGeometryEffect` (10-plan.md R6, "first cut"; 05-animation.md does
// not measure it, so this follows the public documentation's concept):
// views with the same identifier in a namespace share geometry.
//
//  - A view that is inserted in an animated transaction while another view
//    with the same identifier is shown (or is being removed in the same
//    update) starts at that view's frame and animates to its own; the
//    removed view moves towards the new one while it transitions out.
//  - A view with `isSource: false` is rendered in the frame of the source
//    view with the same identifier.
//
// Matching is applied at render time, as a transform that maps the view's
// layout frame to the matched frame (position, size or both, per
// `properties`); layout itself is not changed. Not covered: proposing the
// source's size to non-source views, rotated or scaled ancestors.

/// Which parts of the geometry are matched.
public struct MatchedGeometryProperties: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let position = MatchedGeometryProperties(rawValue: 1 << 0)
    public static let size = MatchedGeometryProperties(rawValue: 1 << 1)
    public static let frame: MatchedGeometryProperties = [.position, .size]
}

package struct MatchedGeometryKey: Hashable {
    let namespace: Namespace.ID
    let id: AnyHashable
}

/// Node state of a matched view.
@MainActor
package final class MatchedGeometryState {
    package var key: MatchedGeometryKey
    package var properties: MatchedGeometryProperties
    package var anchor: UnitPoint
    package var isSource: Bool
    /// The layout node wrapping the view (last lowering).
    package weak var wrapper: LayoutNode?
    /// The view's layout frame in root coordinates (last layout).
    package var frame: CGRect?
    /// The frame the view is rendered in (root coordinates).
    package var presented: Animator<CGRect.AnimatableData>?
    package weak var node: ViewNode?

    init(key: MatchedGeometryKey, properties: MatchedGeometryProperties, anchor: UnitPoint, isSource: Bool) {
        self.key = key
        self.properties = properties
        self.anchor = anchor
        self.isSource = isSource
    }

    /// The render transform (in the wrapper's coordinates) mapping the
    /// layout frame to the presented frame.
    func transform() -> AffineTransform2D {
        guard let f = frame, let a = presented, f.width.isFinite, f.height.isFinite else { return .identity }
        var p = CGRect.zero
        p.animatableData = a.presented
        var sx: CGFloat = 1, sy: CGFloat = 1
        if properties.contains(.size) {
            sx = f.width > 0 ? p.width / f.width : 1
            sy = f.height > 0 ? p.height / f.height : 1
        }
        // The anchor of the scaled view goes to the anchor of the target.
        let own = anchor.point(in: f.size)
        let target = properties.contains(.position)
            ? CGPoint(x: p.minX + anchor.x * p.width, y: p.minY + anchor.y * p.height)
            : CGPoint(x: f.minX + own.x, y: f.minY + own.y)
        let tx = target.x - f.minX - own.x * sx
        let ty = target.y - f.minY - own.y * sy
        return AffineTransform2D.translation(tx, ty).concatenating(.scale(sx, sy))
    }
}

package struct MatchedGeometryModifier: PrimitiveModifier {
    package let key: MatchedGeometryKey
    package let properties: MatchedGeometryProperties
    package let anchor: UnitPoint
    package let isSource: Bool

    package func _inserted(node: ViewNode) {
        let s = MatchedGeometryState(key: key, properties: properties, anchor: anchor, isSource: isSource)
        s.node = node
        node.primitiveState = s
        node.graph.registerMatched(s)
    }

    package func _updated(old: MatchedGeometryModifier, node: ViewNode) {
        guard let s = node.primitiveState as? MatchedGeometryState else { return }
        s.key = key
        s.properties = properties
        s.anchor = anchor
        s.isSource = isSource
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        guard let s = node.primitiveState as? MatchedGeometryState else { return content }
        return content.enumerated().map { i, c in
            let w = LayoutNode(MatchedGeometryBehavior(), children: [c])
            if i == 0 {
                s.wrapper = w
                w.presentation = .transform { _ in s.transform() }
            }
            return w
        }
    }
}

/// The layout node of a matched view: no layout effect; rendering maps it
/// to the matched frame.
package struct MatchedGeometryBehavior: PassthroughModifier {}

extension View {
    /// Matches this view's geometry with the views that have the same `id`
    /// in `namespace`.
    public func matchedGeometryEffect<ID: Hashable>(id: ID, in namespace: Namespace.ID,
                                                    properties: MatchedGeometryProperties = .frame,
                                                    anchor: UnitPoint = .center, isSource: Bool = true) -> some View {
        modifier(MatchedGeometryModifier(key: MatchedGeometryKey(namespace: namespace, id: AnyHashable(id)),
                                         properties: properties, anchor: anchor, isSource: isSource))
    }
}

extension ViewGraph {
    /// After a layout pass: records the frames of matched views, starts the
    /// animations of matched insertions, and points non-source views at
    /// their source.
    package func updateMatchedGeometry(animated: Bool) {
        let states = matchedStates()
        var inMainTree: [ObjectIdentifier: Bool] = [:]
        for s in states {
            guard let node = s.node else { continue }
            let ghost = ghosts.contains { node.isDescendant(of: $0.node) }
            inMainTree[ObjectIdentifier(s)] = !ghost
            if !ghost, let f = s.wrapper?.placedFrame, f.minX.isFinite, f.minY.isFinite { s.frame = f }
        }
        for s in states {
            guard let node = s.node, inMainTree[ObjectIdentifier(s)] == true, let f = s.frame else { continue }
            if s.presented == nil {
                let partner = states.first { o in
                    o !== s && o.key == s.key && o.presented != nil && o.frame != nil
                }
                let tx = node.transactionForSelf()
                if let partner, animated, tx.animation != nil, let pf = partner.presented {
                    let a = Animator(pf.presented, owner: node)
                    s.presented = a
                    a.update(to: f.animatableData, transaction: tx, graph: self)
                    if inMainTree[ObjectIdentifier(partner)] == false {
                        pf.update(to: f.animatableData, transaction: tx, graph: self)
                    }
                } else {
                    let source = s.isSource ? nil : states.first { $0 !== s && $0.key == s.key && $0.isSource }
                    s.presented = Animator((source?.frame ?? f).animatableData, owner: node)
                }
                continue
            }
            var target = f
            if !s.isSource, let source = states.first(where: { $0 !== s && $0.key == s.key && $0.isSource }),
               let sf = source.frame {
                target = sf
            }
            s.presented?.update(to: target.animatableData, animation: nil, graph: self)
        }
    }
}
