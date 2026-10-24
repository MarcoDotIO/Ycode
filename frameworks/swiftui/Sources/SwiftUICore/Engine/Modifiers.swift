import Foundation

// Layout modifiers (04-layout.md §5). Each wraps one child (index 0) unless
// noted; spacing, priority, layout values and explicit guides pass through.

/// The origin that aligns a child with dimensions `d` inside a container of
/// `size` on `alignment` (the container's default guide values against the
/// child's guide values, explicit ones included).
package func alignedOrigin(_ d: ViewDimensions, in size: CGSize, alignment: Alignment) -> CGPoint {
    CGPoint(x: alignment.horizontal.key.defaultValue(for: size) - d[key: alignment.horizontal.key],
            y: alignment.vertical.key.defaultValue(for: size) - d[key: alignment.vertical.key])
}

/// A modifier that places its single child at the origin with the node's own
/// proposal (size = the child's answer unless overridden).
package protocol PassthroughModifier: NodeBehavior {}

extension PassthroughModifier {
    package var traitChild: Int? { 0 }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        node.children[0].sizeThatFits(p)
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        [ChildPlacement(index: 0, origin: .zero, size: node.children[0].sizeThatFits(proposal), proposal: proposal)]
    }
}

/// `frame(width:height:alignment:)`: answers the given dimensions (the
/// child's for omitted ones), proposes them to the child and aligns it.
package struct FixedFrameBehavior: NodeBehavior {
    package var width: CGFloat?
    package var height: CGFloat?
    package var alignment: Alignment

    package init(width: CGFloat?, height: CGFloat?, alignment: Alignment = .center) {
        self.width = width
        self.height = height
        self.alignment = alignment
    }

    package var traitChild: Int? { 0 }

    private func childProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: width ?? p.width, height: height ?? p.height)
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        if let width, let height { return CGSize(width: width, height: height) }
        let c = node.children[0].sizeThatFits(childProposal(p))
        return CGSize(width: width ?? c.width, height: height ?? c.height)
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let cp = childProposal(proposal)
        let d = node.children[0].dimensions(cp)
        return [ChildPlacement(index: 0, origin: alignedOrigin(d, in: size, alignment: alignment), size: d.size, proposal: cp)]
    }
}

/// `frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:alignment:)`.
///
/// Child proposal per dimension: a given proposal clamped to [min, max]; an
/// unspecified one replaced by the ideal value when there is one.
/// Answer per dimension (04 §5 and golden `frame.*`, `hstack.flex`):
/// - min and max both given: the proposal clamped to them (unspecified → the
///   child's answer clamped);
/// - only min: max(min, min(child, proposal));
/// - only max: min(max, max(child, proposal));
/// - neither: the child's answer;
/// where an unspecified proposal counts as the child's answer.
package struct FlexibleFrameBehavior: NodeBehavior {
    package var minWidth, idealWidth, maxWidth, minHeight, idealHeight, maxHeight: CGFloat?
    package var alignment: Alignment

    package init(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                 minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                 alignment: Alignment = .center) {
        (self.minWidth, self.idealWidth, self.maxWidth) = (minWidth, idealWidth, maxWidth)
        (self.minHeight, self.idealHeight, self.maxHeight) = (minHeight, idealHeight, maxHeight)
        self.alignment = alignment
    }

    package var traitChild: Int? { 0 }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat?, _ hi: CGFloat?) -> CGFloat {
        var r = v
        if let hi { r = Swift.min(r, hi) }
        if let lo { r = Swift.max(r, lo) }
        return r
    }

    private func childProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: p.width.map { Self.clamp($0, minWidth, maxWidth) } ?? idealWidth,
            height: p.height.map { Self.clamp($0, minHeight, maxHeight) } ?? idealHeight)
    }

    private static func resolve(proposal: CGFloat?, child: () -> CGFloat, min lo: CGFloat?, max hi: CGFloat?) -> CGFloat {
        switch (lo, hi) {
        case (let lo?, let hi?):
            return clamp(proposal ?? child(), lo, hi)
        case (let lo?, nil):
            let c = child()
            return Swift.max(lo, Swift.min(c, proposal ?? c))
        case (nil, let hi?):
            let c = child()
            return Swift.min(hi, Swift.max(c, proposal ?? c))
        case (nil, nil):
            return child()
        }
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let cp = childProposal(p)
        var memo: CGSize?
        func child() -> CGSize {
            if let memo { return memo }
            let s = node.children[0].sizeThatFits(cp)
            memo = s
            return s
        }
        return CGSize(
            width: Self.resolve(proposal: p.width, child: { child().width }, min: minWidth, max: maxWidth),
            height: Self.resolve(proposal: p.height, child: { child().height }, min: minHeight, max: maxHeight))
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let cp = childProposal(proposal)
        let d = node.children[0].dimensions(cp)
        return [ChildPlacement(index: 0, origin: alignedOrigin(d, in: size, alignment: alignment), size: d.size, proposal: cp)]
    }
}

/// `padding`: proposes the proposal minus the insets (not below 0), answers
/// the child plus the insets; negative insets shrink the answer and shift the
/// child outward. Padded edges get the default spacing preferences.
package struct PaddingBehavior: NodeBehavior {
    package var insets: EdgeInsets

    package init(_ insets: EdgeInsets) { self.insets = insets }

    /// iOS default padding amount (04 §5).
    package static let defaultAmount: CGFloat = 16

    package var traitChild: Int? { 0 }

    private func childProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: p.width.map { Swift.max($0 - insets.horizontal, 0) },
                         height: p.height.map { Swift.max($0 - insets.vertical, 0) })
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let c = node.children[0].sizeThatFits(childProposal(p))
        return CGSize(width: Swift.max(c.width + insets.horizontal, 0), height: Swift.max(c.height + insets.vertical, 0))
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let cp = childProposal(proposal)
        return [ChildPlacement(index: 0, origin: CGPoint(x: insets.leading, y: insets.top),
                               size: node.children[0].sizeThatFits(cp), proposal: cp)]
    }

    package func spacing(node: LayoutNode) -> ViewSpacing {
        var padded: Edge.Set = []
        if insets.top != 0 { padded.insert(.top) }
        if insets.leading != 0 { padded.insert(.leading) }
        if insets.bottom != 0 { padded.insert(.bottom) }
        if insets.trailing != 0 { padded.insert(.trailing) }
        return node.children[0].spacing.replacing(padded, with: [.standard])
    }
}

/// `fixedSize(horizontal:vertical:)`: unspecified proposal in the fixed
/// dimensions, so the child takes its ideal size there.
package struct FixedSizeBehavior: PassthroughModifier {
    package var horizontal: Bool
    package var vertical: Bool

    package init(horizontal: Bool = true, vertical: Bool = true) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    private func childProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: horizontal ? nil : p.width, height: vertical ? nil : p.height)
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        node.children[0].sizeThatFits(childProposal(p))
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let cp = childProposal(proposal)
        return [ChildPlacement(index: 0, origin: .zero, size: node.children[0].sizeThatFits(cp), proposal: cp)]
    }
}

/// `aspectRatio(_:contentMode:)`: proposes the largest (fit) or smallest
/// (fill) rectangle of the ratio inside/around the proposal; one unspecified
/// dimension is derived from the other; both unspecified pass through. A nil
/// ratio uses the child's ideal aspect.
package struct AspectRatioBehavior: PassthroughModifier {
    package var ratio: CGFloat?
    package var contentMode: ContentMode

    package init(_ ratio: CGFloat?, contentMode: ContentMode) {
        self.ratio = ratio
        self.contentMode = contentMode
    }

    private func childProposal(_ p: ProposedViewSize, _ node: LayoutNode) -> ProposedViewSize {
        if p.width == nil && p.height == nil { return p }
        let r: CGFloat
        if let ratio { r = ratio } else {
            let ideal = node.children[0].sizeThatFits(.unspecified)
            r = ideal.width / ideal.height
        }
        guard r.isFinite, r > 0 else { return p }
        switch (p.width, p.height) {
        case (let w?, nil): return ProposedViewSize(width: w, height: w / r)
        case (nil, let h?): return ProposedViewSize(width: h * r, height: h)
        case (let w?, let h?):
            let s = contentMode == .fit ? Swift.min(w / r, h) : Swift.max(w / r, h)
            return ProposedViewSize(width: s * r, height: s)
        case (nil, nil): return p
        }
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        node.children[0].sizeThatFits(childProposal(p, node))
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let cp = childProposal(proposal, node)
        return [ChildPlacement(index: 0, origin: .zero, size: node.children[0].sizeThatFits(cp), proposal: cp)]
    }
}

/// `offset(x:y:)`: no layout effect; moves the rendering (and the frames
/// geometry readers report). Horizontal offsets follow the layout direction.
package struct OffsetBehavior: PassthroughModifier {
    package var x: CGFloat
    package var y: CGFloat

    package init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    package func childTransform(size: CGSize) -> AffineTransform2D? { .translation(x, y) }
}

/// An offset by a fraction of the node's own size (move, slide and push
/// transitions, R6).
package struct SizeRelativeOffsetBehavior: PassthroughModifier {
    package var fraction: CGSize
    package init(_ fraction: CGSize) { self.fraction = fraction }
    package func childTransform(size: CGSize) -> AffineTransform2D? {
        .translation(fraction.width * size.width, fraction.height * size.height)
    }
}

/// `opacity(_:)`: no layout effect; the value is applied when rendering.
package struct OpacityBehavior: PassthroughModifier {
    package var opacity: Double
    package init(_ opacity: Double) { self.opacity = opacity }
}

/// `scaleEffect(_:anchor:)`: no layout effect; scales the rendering about
/// `anchor`.
package struct ScaleEffectBehavior: PassthroughModifier {
    package var x: CGFloat
    package var y: CGFloat
    package var anchor: UnitPoint

    package init(x: CGFloat, y: CGFloat, anchor: UnitPoint = .center) {
        self.x = x
        self.y = y
        self.anchor = anchor
    }

    package func childTransform(size: CGSize) -> AffineTransform2D? {
        AffineTransform2D.scale(x, y).about(anchor.point(in: size))
    }
}

/// `rotationEffect(_:anchor:)`: no layout effect; rotates the rendering about
/// `anchor` (reported frames are the rotated bounding box).
package struct RotationEffectBehavior: PassthroughModifier {
    package var angle: Angle
    package var anchor: UnitPoint

    package init(_ angle: Angle, anchor: UnitPoint = .center) {
        self.angle = angle
        self.anchor = anchor
    }

    package func childTransform(size: CGSize) -> AffineTransform2D? {
        AffineTransform2D.rotation(angle.radians).about(anchor.point(in: size))
    }
}

/// `position(x:y:)`: takes the whole proposal (the child's answer for an
/// unspecified dimension) and centres the child on the point.
package struct PositionBehavior: NodeBehavior {
    package var x: CGFloat
    package var y: CGFloat

    package init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    package var traitChild: Int? { 0 }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        if let w = p.width, let h = p.height { return CGSize(width: w, height: h) }
        let c = node.children[0].sizeThatFits(p)
        return CGSize(width: p.width ?? c.width, height: p.height ?? c.height)
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let c = node.children[0].sizeThatFits(proposal)
        return [ChildPlacement(index: 0, origin: CGPoint(x: x - c.width / 2, y: y - c.height / 2), size: c, proposal: proposal)]
    }
}

/// `overlay` / `background`: children [base, secondary]. Answers the base's
/// size; the secondary is proposed exactly that size and aligned to the base
/// on `alignment`, using the base's guides (explicit ones included).
package struct SecondaryLayerBehavior: NodeBehavior {
    package var alignment: Alignment
    package var isBackground: Bool

    package init(alignment: Alignment = .center, isBackground: Bool) {
        self.alignment = alignment
        self.isBackground = isBackground
    }

    package var traitChild: Int? { 0 }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        node.children[0].sizeThatFits(p)
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let base = node.children[0].dimensions(proposal)
        let sp = ProposedViewSize(base.size)
        let sec = node.children[1].dimensions(sp)
        let origin = CGPoint(x: base[key: alignment.horizontal.key] - sec[key: alignment.horizontal.key],
                             y: base[key: alignment.vertical.key] - sec[key: alignment.vertical.key])
        return [ChildPlacement(index: 0, origin: .zero, size: base.size, proposal: proposal),
                ChildPlacement(index: 1, origin: origin, size: sec.size, proposal: sp)]
    }
}

/// `clipped()`: no layout effect (clipping is a rendering matter).
package struct ClipBehavior: PassthroughModifier {
    package init() {}
}

/// `layoutPriority(_:)`.
package struct LayoutPriorityBehavior: PassthroughModifier {
    package var priority: Double
    package init(_ priority: Double) { self.priority = priority }
    package func layoutPriority(node: LayoutNode) -> Double { priority }
}

/// `layoutValue(key:value:)`.
package struct LayoutValueBehavior: PassthroughModifier {
    package var key: ObjectIdentifier
    package var value: Any

    package init(key: ObjectIdentifier, value: Any) {
        self.key = key
        self.value = value
    }

    package func layoutValue(_ k: ObjectIdentifier, node: LayoutNode) -> Any? {
        k == key ? value : node.children[0].layoutValue(k)
    }
}

/// `alignmentGuide(_:computeValue:)`: overrides one explicit guide with a
/// function of the child's dimensions.
package struct AlignmentGuideBehavior: PassthroughModifier {
    package var key: AlignmentKey
    package var compute: (ViewDimensions) -> CGFloat

    package init(_ key: AlignmentKey, compute: @escaping (ViewDimensions) -> CGFloat) {
        self.key = key
        self.compute = compute
    }

    package func explicitAlignment(_ k: AlignmentKey, size: CGSize, proposal: ProposedViewSize,
                                   node: LayoutNode) -> CGFloat? {
        if k == key { return compute(node.children[0].dimensions(proposal)) }
        return node.childExplicitAlignment(k, child: 0, size: size, proposal: proposal)
    }
}

/// `ignoresSafeArea(_:edges:)`: when the view's frame touches the safe-area
/// boundary on one of `edges`, its content is extended into that inset
/// (04 §7). Only the container safe area is modelled in R3 (no keyboard).
package struct IgnoresSafeAreaBehavior: PassthroughModifier, SafeAreaExpandingBehavior {
    package var edges: Edge.Set

    package init(edges: Edge.Set = .all) { self.edges = edges }

    package func expand(_ placements: [ChildPlacement], node: LayoutNode, frame: CGRect) -> [ChildPlacement] {
        guard let area = node.context.safeArea, var pl = placements.first else { return placements }
        let eps: CGFloat = 0.001
        var grow = EdgeInsets()
        if edges.contains(.top), frame.minY <= area.safe.minY + eps { grow.top = frame.minY - area.window.minY }
        if edges.contains(.leading), frame.minX <= area.safe.minX + eps { grow.leading = frame.minX - area.window.minX }
        if edges.contains(.bottom), frame.maxY >= area.safe.maxY - eps { grow.bottom = area.window.maxY - frame.maxY }
        if edges.contains(.trailing), frame.maxX >= area.safe.maxX - eps { grow.trailing = area.window.maxX - frame.maxX }
        grow = EdgeInsets(top: Swift.max(grow.top, 0), leading: Swift.max(grow.leading, 0),
                          bottom: Swift.max(grow.bottom, 0), trailing: Swift.max(grow.trailing, 0))
        if grow == EdgeInsets() { return placements }
        let size = CGSize(width: frame.width + grow.horizontal, height: frame.height + grow.vertical)
        pl.proposal = ProposedViewSize(size)
        pl.size = node.children[0].sizeThatFits(pl.proposal)
        pl.origin = CGPoint(x: -grow.leading, y: -grow.top)
        return [pl]
    }
}
