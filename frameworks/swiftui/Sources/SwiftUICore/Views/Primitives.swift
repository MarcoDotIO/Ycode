import Foundation

// Primitive views and containers, lowered onto the R3 layout engine
// (Engine/NodeBuilders.swift). Layout rules are those of 04-layout.md; this
// file only says which engine node each view becomes.

// MARK: - Image

/// An image: a symbol, an asset, or (for tests) an image of known size.
public struct Image: Equatable, Sendable {
    package enum Source: Equatable, Sendable {
        case system(String)
        case named(String)
        case natural(CGSize)
    }

    package var source: Source
    package var isResizable = false

    public init(systemName: String) { source = .system(systemName) }
    public init(_ name: String, bundle: Bundle? = nil) { source = .named(name) }
    public init(decorative name: String, bundle: Bundle? = nil) { source = .named(name) }
    package init(naturalSize: CGSize) { source = .natural(naturalSize) }

    public enum ResizingMode: Hashable, Sendable { case tile, stretch }

    /// Relative size of symbol images.
    public enum Scale: Hashable, Sendable { case small, medium, large }

    public func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: ResizingMode = .stretch) -> Image {
        var i = self
        i.isResizable = true
        return i
    }

    public typealias Body = Never
}

extension Image: View {}

extension Image: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Image?, transaction: Transaction) {}

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let font = (node.environment.font ?? .body).textFont(in: node.environment)
        switch source {
        case .system(let name): return [.image(systemName: name, resizable: isResizable, font: font)]
        case .named(let name): return [.image(systemName: "asset:" + name, resizable: isResizable, font: font)]
        case .natural(let size): return [.image(naturalSize: size, resizable: isResizable)]
        }
    }
}

// MARK: - Colours and shapes

extension Color: View {
    public typealias Body = Never
}

extension Color: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Color?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.color()] }
}

/// Corner style of rounded rectangles.
public enum RoundedCornerStyle: Hashable, Sendable {
    case circular
    case continuous
}

public struct Rectangle: View, Sendable {
    public init() {}
    public typealias Body = Never
}

public struct Circle: View, Sendable {
    public init() {}
    public typealias Body = Never
}

public struct Ellipse: View, Sendable {
    public init() {}
    public typealias Body = Never
}

public struct Capsule: View, Sendable {
    public var style: RoundedCornerStyle
    public init(style: RoundedCornerStyle = .continuous) { self.style = style }
    public typealias Body = Never
}

public struct RoundedRectangle: View, Sendable {
    public var cornerSize: CGSize
    public var style: RoundedCornerStyle
    public init(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        self.cornerSize = cornerSize
        self.style = style
    }
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.init(cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: style)
    }
    public typealias Body = Never
}

extension Rectangle: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Rectangle?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.rectangle()] }
}

extension Circle: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Circle?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.circle()] }
}

extension Ellipse: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Ellipse?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.ellipse()] }
}

extension Capsule: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Capsule?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.capsule()] }
}

extension RoundedRectangle: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: RoundedRectangle?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.roundedRectangle()] }
}

// MARK: - Spacer

/// Flexible space along the enclosing stack's axis (04 §2).
public struct Spacer: View, Sendable {
    public var minLength: CGFloat?
    public init(minLength: CGFloat? = nil) { self.minLength = minLength }
    public typealias Body = Never
}

extension Spacer: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Spacer?, transaction: Transaction) {}
    package func _lower(node: ViewNode) -> [LayoutNode] { [.spacer(minLength: minLength)] }
}

// MARK: - Layout containers

/// A `Layout` applied to views (`HStackLayout() { … }`, stacks, grids).
package struct LayoutContainer<L: Layout, Content: View>: View {
    package let layout: L
    package let content: Content
    package typealias Body = Never
}

extension LayoutContainer: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: LayoutContainer?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }

    package func _lower(node: ViewNode) -> [LayoutNode] { [.layout(layout, node.lowerChildren())] }
}

extension Layout {
    /// Lays out the views of `content` with this layout.
    @MainActor
    public func callAsFunction<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        LayoutContainer(layout: self, content: content())
    }
}

/// Views side by side (04 §4).
public struct HStack<Content: View>: View {
    package let layout: HStackLayout
    package let content: Content
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        layout = HStackLayout(alignment: alignment, spacing: spacing)
        self.content = content()
    }
    public typealias Body = Never
}

/// Views one above the other (04 §4).
public struct VStack<Content: View>: View {
    package let layout: VStackLayout
    package let content: Content
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        layout = VStackLayout(alignment: alignment, spacing: spacing)
        self.content = content()
    }
    public typealias Body = Never
}

/// Views on top of each other (04 §4).
public struct ZStack<Content: View>: View {
    package let layout: ZStackLayout
    package let content: Content
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        layout = ZStackLayout(alignment: alignment)
        self.content = content()
    }
    public typealias Body = Never
}

extension HStack: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: HStack?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
    package func _lower(node: ViewNode) -> [LayoutNode] { [.layout(layout, node.lowerChildren())] }
}

extension VStack: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: VStack?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
    package func _lower(node: ViewNode) -> [LayoutNode] { [.layout(layout, node.lowerChildren())] }
}

extension ZStack: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: ZStack?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
    package func _lower(node: ViewNode) -> [LayoutNode] { [.layout(layout, node.lowerChildren())] }
}

// MARK: - ForEach

/// Views computed from a collection; each element's view is identified by
/// its ID, so state follows the IDs when the collection is reordered
/// (03 §2).
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content> {
    public var data: Data
    public var content: (Data.Element) -> Content
    package let idOf: (Data.Element) -> ID
    public typealias Body = Never
}

extension ForEach: View where Content: View {
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        let kp = UncheckedBox(id)
        idOf = { $0[keyPath: kp.value] }
    }
}

extension ForEach where Content: View, Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        idOf = { $0.id }
    }
}

extension ForEach where Content: View, Data == Range<Int>, ID == Int {
    /// A constant range of views, identified by offset.
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.content = content
        idOf = { $0 }
    }
}

extension ForEach: PrimitiveView where Content: View {
    package func _makeChildren(node: ViewNode, old: ForEach?, transaction: Transaction) {
        let items: [(AnyHashable, any View)] = node.trackContent {
            var seen: [ID: Int] = [:]
            var items: [(AnyHashable, any View)] = []
            items.reserveCapacity(data.count)
            for element in data {
                let id = idOf(element)
                let n = seen[id, default: 0]
                seen[id] = n + 1
                // Duplicate IDs keep distinct identities by occurrence.
                let key = n == 0 ? AnyHashable(id) : AnyHashable([AnyHashable(id), AnyHashable(n)])
                items.append((key, content(element)))
            }
            return items
        }
        node.reconcileChildren(items, transaction: transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty {
            _makeChildren(node: node, old: self, transaction: transaction)
        } else {
            node.refreshChildren(transaction: transaction)
        }
    }
}

// MARK: - GeometryReader

/// Access to the size and position of a geometry reader (04 §2).
public struct GeometryProxy {
    package let geometry: NodeGeometry

    package init(_ geometry: NodeGeometry) { self.geometry = geometry }

    /// The size proposed to (and taken by) the reader.
    public var size: CGSize { geometry.size }

    /// The safe-area insets the reader's frame touches (04 §7).
    public var safeAreaInsets: EdgeInsets { geometry.safeAreaInsets }

    /// The reader's frame in a coordinate space.
    public func frame(in coordinateSpace: CoordinateSpace) -> CGRect {
        switch coordinateSpace {
        case .global: return geometry.frame
        case .local: return CGRect(origin: .zero, size: geometry.size)
        case .named: return geometry.frame
        }
    }
}

/// A coordinate space for geometry queries (named spaces are not yet
/// resolved: they answer global coordinates).
public enum CoordinateSpace: Hashable {
    case global
    case local
    case named(AnyHashable)
}

private final class GeometryReaderState: GeometryObserving {
    var used: NodeGeometry?
    func geometryChanged(_ geometry: NodeGeometry, node: ViewNode) {
        if geometry != used { node.invalidate(transaction: Transaction()) }
    }
}

/// A container whose content is built from its own size and position. It
/// takes the proposed size; its content is rebuilt after a layout pass that
/// changed its geometry.
public struct GeometryReader<Content: View>: View {
    public var content: (GeometryProxy) -> Content
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }
    public typealias Body = Never
}

@MainActor
extension GeometryReader: PrimitiveView {
    private func build(_ node: ViewNode, _ transaction: Transaction) {
        let state = (node.primitiveState as? GeometryReaderState) ?? GeometryReaderState()
        node.primitiveState = state
        let g = node.geometry ?? NodeGeometry()
        state.used = g
        let child = node.trackContent { content(GeometryProxy(g)) }
        node.reconcileChildren([(AnyHashable(0), child)], transaction: transaction)
    }

    package func _makeChildren(node: ViewNode, old: GeometryReader?, transaction: Transaction) {
        build(node, transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { build(node, transaction) } else { node.refreshChildren(transaction: transaction) }
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let n = LayoutNode.geometryReader(node.lowerChildren())
        n.owner = node
        return [n]
    }
}
