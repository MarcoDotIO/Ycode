import Foundation

// Render effects whose values animate (05-animation.md §1: opacity, offsets,
// scale and rotation are animatable). None of them changes layout (04 §5,
// 03 §6). Each effect keeps an `Animator` for its value; layout uses the
// model value (geometry readers see model geometry), rendering
// (`ViewGraph.presentedLayers()`) uses the presented value.

/// The animator of an effect modifier's node, created on insertion and
/// updated with each new value in the transaction that reached the modifier.
@MainActor
package func effectAnimator<D: VectorArithmetic>(_ node: ViewNode, _ data: D, isNew: Bool,
                                                transaction: Transaction) -> Animator<D> {
    if !isNew, let a = node.primitiveState as? Animator<D> {
        a.update(to: data, transaction: transaction, graph: node.graph)
        return a
    }
    let a = Animator(data, owner: node)
    node.primitiveState = a
    return a
}

/// `opacity(_:)`.
package struct _OpacityEffect: PrimitiveModifier, Equatable {
    package let opacity: Double

    package func _animate(old: _OpacityEffect?, node: ViewNode, transaction: Transaction) {
        _ = effectAnimator(node, opacity, isNew: old == nil, transaction: transaction)
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        let a = node.primitiveState as? Animator<Double>
        return content.map { c in
            let w = LayoutNode(OpacityBehavior(opacity), children: [c])
            if let a { w.presentation = .opacity { a.presented } }
            return w
        }
    }
}

/// `offset(_:)`; horizontal offsets follow the layout direction.
package struct _OffsetEffect: PrimitiveModifier, Equatable {
    package let offset: CGSize

    package func _animate(old: _OffsetEffect?, node: ViewNode, transaction: Transaction) {
        _ = effectAnimator(node, offset.animatableData, isNew: old == nil, transaction: transaction)
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        let a = node.primitiveState as? Animator<CGSize.AnimatableData>
        return content.map { c in
            let w = LayoutNode(OffsetBehavior(x: offset.width, y: offset.height), children: [c])
            if let a { w.presentation = .transform { _ in .translation(a.presented.first, a.presented.second) } }
            return w
        }
    }
}

/// `scaleEffect(_:anchor:)`.
package struct _ScaleEffect: PrimitiveModifier, Equatable {
    package let scale: CGSize
    package let anchor: UnitPoint

    package func _animate(old: _ScaleEffect?, node: ViewNode, transaction: Transaction) {
        _ = effectAnimator(node, scale.animatableData, isNew: old == nil, transaction: transaction)
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        let a = node.primitiveState as? Animator<CGSize.AnimatableData>
        let anchor = self.anchor
        return content.map { c in
            let w = LayoutNode(ScaleEffectBehavior(x: scale.width, y: scale.height, anchor: anchor), children: [c])
            if let a {
                w.presentation = .transform { size in
                    AffineTransform2D.scale(a.presented.first, a.presented.second).about(anchor.point(in: size))
                }
            }
            return w
        }
    }
}

/// `rotationEffect(_:anchor:)` (the angle animates in radians).
package struct _RotationEffect: PrimitiveModifier, Equatable {
    package let angle: Angle
    package let anchor: UnitPoint

    package func _animate(old: _RotationEffect?, node: ViewNode, transaction: Transaction) {
        _ = effectAnimator(node, angle.radians, isNew: old == nil, transaction: transaction)
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        let a = node.primitiveState as? Animator<Double>
        let anchor = self.anchor
        return content.map { c in
            let w = LayoutNode(RotationEffectBehavior(angle, anchor: anchor), children: [c])
            if let a { w.presentation = .transform { size in AffineTransform2D.rotation(a.presented).about(anchor.point(in: size)) } }
            return w
        }
    }
}

/// An offset by a fraction of the view's own size (move, slide and push
/// transitions: (−1, 0) is one width towards the leading edge).
package struct _SizeRelativeOffsetEffect: PrimitiveModifier, Equatable {
    package let fraction: CGSize

    package func _animate(old: _SizeRelativeOffsetEffect?, node: ViewNode, transaction: Transaction) {
        _ = effectAnimator(node, fraction.animatableData, isNew: old == nil, transaction: transaction)
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        let a = node.primitiveState as? Animator<CGSize.AnimatableData>
        return content.map { c in
            let w = LayoutNode(SizeRelativeOffsetBehavior(fraction), children: [c])
            if let a {
                w.presentation = .transform { size in
                    .translation(a.presented.first * size.width, a.presented.second * size.height)
                }
            }
            return w
        }
    }
}

extension View {
    /// Sets the transparency of the view (render only; animatable).
    public func opacity(_ opacity: Double) -> some View { modifier(_OpacityEffect(opacity: opacity)) }

    /// Moves the rendering; layout is unchanged.
    public func offset(_ offset: CGSize) -> some View { modifier(_OffsetEffect(offset: offset)) }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(_OffsetEffect(offset: CGSize(width: x, height: y)))
    }

    public func scaleEffect(_ s: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(_ScaleEffect(scale: CGSize(width: s, height: s), anchor: anchor))
    }

    public func scaleEffect(_ s: CGSize, anchor: UnitPoint = .center) -> some View {
        modifier(_ScaleEffect(scale: s, anchor: anchor))
    }

    public func scaleEffect(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> some View {
        modifier(_ScaleEffect(scale: CGSize(width: x, height: y), anchor: anchor))
    }

    public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> some View {
        modifier(_RotationEffect(angle: angle, anchor: anchor))
    }
}

/// `animation(_:)` without a value (deprecated): every change in the
/// subtree gets `animation`, unless the transaction disables implicit
/// animations.
package struct UnconditionalAnimationModifier: PrimitiveModifier {
    package let animation: Animation?

    package func _transaction(_ transaction: Transaction, old: UnconditionalAnimationModifier?, node: ViewNode) -> Transaction {
        guard !transaction.disablesAnimations else { return transaction }
        var t = transaction
        t.animation = animation
        return t
    }
}

extension View {
    @available(*, deprecated, message: "Use withAnimation or animation(_:value:) instead.")
    public func animation(_ animation: Animation?) -> some View {
        modifier(UnconditionalAnimationModifier(animation: animation))
    }
}
