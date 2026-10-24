import Foundation

// Construction API for layout trees, named after the views and modifiers
// they stand for. Round R2's views lower to these calls; tests use them
// directly. Each modifier returns a new node wrapping the receiver.

extension LayoutNode {
    // MARK: Leaves

    package static func color() -> LayoutNode { LayoutNode(ShapeLeaf(.rectangle)) }
    package static func rectangle() -> LayoutNode { LayoutNode(ShapeLeaf(.rectangle)) }
    package static func capsule() -> LayoutNode { LayoutNode(ShapeLeaf(.rectangle)) }
    package static func ellipse() -> LayoutNode { LayoutNode(ShapeLeaf(.rectangle)) }
    package static func roundedRectangle() -> LayoutNode { LayoutNode(ShapeLeaf(.rectangle)) }
    package static func circle() -> LayoutNode { LayoutNode(ShapeLeaf(.circle)) }
    package static func empty() -> LayoutNode { LayoutNode(EmptyLeaf()) }
    package static func spacer(minLength: CGFloat? = nil) -> LayoutNode { LayoutNode(SpacerLeaf(minLength: minLength)) }

    package static func text(_ s: String, font: TextFont = .body, lineLimit: Int? = nil) -> LayoutNode {
        LayoutNode(TextLeaf(s, font: font, lineLimit: lineLimit))
    }

    package static func text(_ t: ResolvedText) -> LayoutNode { LayoutNode(TextLeaf(t)) }

    package static func image(systemName: String, resizable: Bool = false, font: TextFont = .body) -> LayoutNode {
        LayoutNode(ImageLeaf(.symbol(systemName), resizable: resizable, font: font))
    }

    package static func image(naturalSize: CGSize, resizable: Bool = false) -> LayoutNode {
        LayoutNode(ImageLeaf(.natural(naturalSize), resizable: resizable))
    }

    package static func geometryReader(_ content: [LayoutNode] = []) -> LayoutNode {
        LayoutNode(GeometryReaderBehavior(), children: content)
    }

    // MARK: Containers

    package static func layout<L: Layout>(_ layout: L, _ children: [LayoutNode]) -> LayoutNode {
        LayoutNode(LayoutBehavior(layout), children: children)
    }

    package static func hstack(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                               _ children: [LayoutNode]) -> LayoutNode {
        layout(HStackLayout(alignment: alignment, spacing: spacing), children)
    }

    package static func vstack(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                               _ children: [LayoutNode]) -> LayoutNode {
        layout(VStackLayout(alignment: alignment, spacing: spacing), children)
    }

    package static func zstack(alignment: Alignment = .center, _ children: [LayoutNode]) -> LayoutNode {
        layout(ZStackLayout(alignment: alignment), children)
    }

    // MARK: Modifiers

    private func wrap(_ b: some NodeBehavior) -> LayoutNode { LayoutNode(b, children: [self]) }

    package func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> LayoutNode {
        wrap(FixedFrameBehavior(width: width, height: height, alignment: alignment))
    }

    package func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                       minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                       alignment: Alignment = .center) -> LayoutNode {
        wrap(FlexibleFrameBehavior(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                                   minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight,
                                   alignment: alignment))
    }

    package func padding(_ insets: EdgeInsets) -> LayoutNode { wrap(PaddingBehavior(insets)) }

    package func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> LayoutNode {
        padding(EdgeInsets(edges, length ?? PaddingBehavior.defaultAmount))
    }

    package func padding(_ length: CGFloat) -> LayoutNode { padding(.all, length) }

    package func fixedSize(horizontal: Bool = true, vertical: Bool = true) -> LayoutNode {
        wrap(FixedSizeBehavior(horizontal: horizontal, vertical: vertical))
    }

    package func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> LayoutNode {
        wrap(AspectRatioBehavior(ratio, contentMode: contentMode))
    }

    package func aspectRatio(_ size: CGSize, contentMode: ContentMode) -> LayoutNode {
        aspectRatio(size.width / size.height, contentMode: contentMode)
    }

    package func scaledToFit() -> LayoutNode { aspectRatio(nil, contentMode: .fit) }
    package func scaledToFill() -> LayoutNode { aspectRatio(nil, contentMode: .fill) }

    package func offset(x: CGFloat = 0, y: CGFloat = 0) -> LayoutNode { wrap(OffsetBehavior(x: x, y: y)) }
    package func offset(_ size: CGSize) -> LayoutNode { offset(x: size.width, y: size.height) }

    package func position(x: CGFloat = 0, y: CGFloat = 0) -> LayoutNode { wrap(PositionBehavior(x: x, y: y)) }
    package func position(_ p: CGPoint) -> LayoutNode { position(x: p.x, y: p.y) }

    package func scaleEffect(_ s: CGFloat, anchor: UnitPoint = .center) -> LayoutNode {
        wrap(ScaleEffectBehavior(x: s, y: s, anchor: anchor))
    }

    package func scaleEffect(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> LayoutNode {
        wrap(ScaleEffectBehavior(x: x, y: y, anchor: anchor))
    }

    package func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> LayoutNode {
        wrap(RotationEffectBehavior(angle, anchor: anchor))
    }

    package func overlay(_ secondary: LayoutNode, alignment: Alignment = .center) -> LayoutNode {
        LayoutNode(SecondaryLayerBehavior(alignment: alignment, isBackground: false), children: [self, secondary])
    }

    package func background(_ secondary: LayoutNode, alignment: Alignment = .center) -> LayoutNode {
        LayoutNode(SecondaryLayerBehavior(alignment: alignment, isBackground: true), children: [self, secondary])
    }

    package func clipped() -> LayoutNode { wrap(ClipBehavior()) }

    package func layoutPriority(_ p: Double) -> LayoutNode { wrap(LayoutPriorityBehavior(p)) }

    package func layoutValue<K: LayoutValueKey>(key: K.Type, value: K.Value) -> LayoutNode {
        wrap(LayoutValueBehavior(key: ObjectIdentifier(key), value: value))
    }

    package func alignmentGuide(_ g: HorizontalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat) -> LayoutNode {
        wrap(AlignmentGuideBehavior(g.key, compute: computeValue))
    }

    package func alignmentGuide(_ g: VerticalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat) -> LayoutNode {
        wrap(AlignmentGuideBehavior(g.key, compute: computeValue))
    }

    package func ignoresSafeArea(edges: Edge.Set = .all) -> LayoutNode { wrap(IgnoresSafeAreaBehavior(edges: edges)) }

    /// Names this node so that its frame is reported in `LayoutResult`.
    package func named(_ name: String) -> LayoutNode {
        self.name = name
        return self
    }
}
