import Foundation

// Layout modifiers (04-layout.md §5; order semantics 03 §6): each wraps every
// layout node its content produces (a modifier on a group of views applies to
// each view). The arithmetic lives in the R3 engine's behaviours.

/// A modifier that wraps each of the content's layout nodes.
package struct LayoutEffectModifier: PrimitiveModifier {
    package let name: String
    package let apply: (LayoutNode) -> LayoutNode

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        content.map(apply)
    }
}

/// `background` / `overlay` with a view: the secondary view is laid out in
/// the content's bounds (several secondary views are stacked in a ZStack).
package struct SecondaryLayerModifier<Secondary: View>: PrimitiveModifier {
    package let secondary: Secondary
    package let alignment: Alignment
    package let isBackground: Bool

    package func _secondary(node: ViewNode) -> (any View)? { secondary }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        content.map { c in
            let s = secondary()
            let layer: LayoutNode = s.count == 1 ? s[0] : (s.isEmpty ? .empty() : .zstack(alignment: alignment, s))
            return isBackground ? c.background(layer, alignment: alignment) : c.overlay(layer, alignment: alignment)
        }
    }
}

extension View {
    private func layoutEffect(_ name: String, _ apply: @escaping (LayoutNode) -> LayoutNode) -> some View {
        modifier(LayoutEffectModifier(name: name, apply: apply))
    }

    /// A fixed frame; nil dimensions take the content's size (04 §5).
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        layoutEffect("frame") { $0.frame(width: width, height: height, alignment: alignment) }
    }

    /// A flexible frame (04 §5).
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                      minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                      alignment: Alignment = .center) -> some View {
        layoutEffect("flexibleFrame") {
            $0.frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                     minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight, alignment: alignment)
        }
    }

    public func padding(_ insets: EdgeInsets) -> some View { layoutEffect("padding") { $0.padding(insets) } }

    /// Padding on `edges`; nil length = the default amount (04 §5).
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        layoutEffect("padding") { $0.padding(edges, length) }
    }

    public func padding(_ length: CGFloat) -> some View { layoutEffect("padding") { $0.padding(length) } }

    public func fixedSize() -> some View { layoutEffect("fixedSize") { $0.fixedSize() } }

    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View {
        layoutEffect("fixedSize") { $0.fixedSize(horizontal: horizontal, vertical: vertical) }
    }

    public func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> some View {
        layoutEffect("aspectRatio") { $0.aspectRatio(aspectRatio, contentMode: contentMode) }
    }

    public func aspectRatio(_ aspectRatio: CGSize, contentMode: ContentMode) -> some View {
        layoutEffect("aspectRatio") { $0.aspectRatio(aspectRatio, contentMode: contentMode) }
    }

    public func scaledToFit() -> some View { layoutEffect("scaledToFit") { $0.scaledToFit() } }
    public func scaledToFill() -> some View { layoutEffect("scaledToFill") { $0.scaledToFill() } }

    // `offset`, `scaleEffect`, `rotationEffect`: Animation/Effects.swift
    // (render effects whose values animate).

    /// Centres the view at a point of its parent's space; takes the proposal.
    public func position(_ position: CGPoint) -> some View { layoutEffect("position") { $0.position(position) } }
    public func position(x: CGFloat = 0, y: CGFloat = 0) -> some View { layoutEffect("position") { $0.position(x: x, y: y) } }

    public func clipped(antialiased: Bool = false) -> some View { layoutEffect("clipped") { $0.clipped() } }

    public func layoutPriority(_ value: Double) -> some View { layoutEffect("layoutPriority") { $0.layoutPriority(value) } }

    public func layoutValue<K: LayoutValueKey>(key: K.Type, value: K.Value) -> some View {
        let box = UncheckedBox(value)
        return layoutEffect("layoutValue") { $0.layoutValue(key: key, value: box.value) }
    }

    public func alignmentGuide(_ g: HorizontalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat) -> some View {
        layoutEffect("alignmentGuide") { $0.alignmentGuide(g, computeValue: computeValue) }
    }

    public func alignmentGuide(_ g: VerticalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat) -> some View {
        layoutEffect("alignmentGuide") { $0.alignmentGuide(g, computeValue: computeValue) }
    }

    /// Extends the view into the safe-area insets it touches (04 §7).
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View {
        layoutEffect("ignoresSafeArea") { $0.ignoresSafeArea(edges: edges) }
    }

    @available(*, deprecated, message: "Use ignoresSafeArea(_:edges:) instead.")
    public func edgesIgnoringSafeArea(_ edges: Edge.Set) -> some View {
        layoutEffect("ignoresSafeArea") { $0.ignoresSafeArea(edges: edges) }
    }

    /// Layers `background` behind the view, in the view's bounds.
    public func background<V: View>(_ background: V, alignment: Alignment = .center) -> some View {
        modifier(SecondaryLayerModifier(secondary: background, alignment: alignment, isBackground: true))
    }

    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        modifier(SecondaryLayerModifier(secondary: content(), alignment: alignment, isBackground: true))
    }

    /// Layers `overlay` in front of the view, in the view's bounds.
    public func overlay<V: View>(_ overlay: V, alignment: Alignment = .center) -> some View {
        modifier(SecondaryLayerModifier(secondary: overlay, alignment: alignment, isBackground: false))
    }

    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        modifier(SecondaryLayerModifier(secondary: content(), alignment: alignment, isBackground: false))
    }
}

/// Safe-area regions (only the container region exists before R8's
/// keyboard handling).
public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let container = SafeAreaRegions(rawValue: 1 << 0)
    public static let keyboard = SafeAreaRegions(rawValue: 1 << 1)
    public static let all: SafeAreaRegions = [.container, .keyboard]
}

// MARK: - Geometry observation

private final class GeometryChangeState<T: Equatable>: GeometryObserving {
    var last: T?
    var transform: (GeometryProxy) -> T
    var action: (T, T) -> Void
    init(transform: @escaping (GeometryProxy) -> T, action: @escaping (T, T) -> Void) {
        self.transform = transform
        self.action = action
    }

    func geometryChanged(_ geometry: NodeGeometry, node: ViewNode) {
        let value = transform(GeometryProxy(geometry))
        guard last != value else { return }
        let old = last ?? value
        last = value
        let action = self.action
        node.graph.queueGeometryAction { action(old, value) }
    }
}

/// `onGeometryChange(for:of:action:)`: after layout, runs the action when
/// the transformed geometry changes (including its first value).
package struct GeometryChangeModifier<T: Equatable>: PrimitiveModifier {
    package let transform: (GeometryProxy) -> T
    package let action: (T, T) -> Void

    package func _inserted(node: ViewNode) {
        node.primitiveState = GeometryChangeState(transform: transform, action: action)
    }

    package func _updated(old: GeometryChangeModifier, node: ViewNode) {
        guard let s = node.primitiveState as? GeometryChangeState<T> else { return }
        s.transform = transform
        s.action = action
    }

    package func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        content.map { c in
            let probe = LayoutNode.geometryReader()
            probe.owner = node
            return c.background(probe)
        }
    }
}

extension View {
    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                               action: @escaping (_ newValue: T) -> Void) -> some View {
        modifier(GeometryChangeModifier(transform: transform) { _, new in action(new) })
    }

    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                               action: @escaping (_ oldValue: T, _ newValue: T) -> Void) -> some View {
        modifier(GeometryChangeModifier(transform: transform, action: action))
    }
}
