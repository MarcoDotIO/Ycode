import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Views the reference SDK declares in the `SwiftUI` module
// (api-inventory.md), lowered onto the layout behaviours of this module.

/// A thin line between views; vertical inside an `HStack` (04 §2).
public struct Divider: View {
    public init() {}
    public typealias Body = Never
}

extension Divider: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Divider?, transaction: Transaction) {}
    /// The hairline is painted in the separator color (it was laid out but
    /// not drawn before LINUX-UI-PARITY); in a menu it is a separator row:
    /// inset 8 at the sides with 4 above and below.
    package func _lower(node: ViewNode) -> [LayoutNode] {
        let env = node.environment
        let n = LayoutNode.divider()
        n.draw = shapeDraw(shape: Rectangle(), style: ControlPalette(env.colorScheme).separator, mode: .fill(FillStyle()), environment: env)
        return [env._inMenu ? n.padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)) : n]
    }
}

/// The first of its views that fits the proposal (04 §6).
public struct ViewThatFits<Content: View>: View {
    package let axes: Axis.Set
    package let content: Content
    public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }
    public typealias Body = Never
}

extension ViewThatFits: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: ViewThatFits?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
    package func _lower(node: ViewNode) -> [LayoutNode] { [.viewThatFits(in: axes, node.lowerChildren())] }
}

// MARK: - Grid

/// Rows of cells aligned in columns (04 §6).
public struct Grid<Content: View>: View {
    package let alignment: Alignment
    package let horizontalSpacing: CGFloat?
    package let verticalSpacing: CGFloat?
    package let content: Content
    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
    }
    public typealias Body = Never
}

/// A row of a `Grid`.
public struct GridRow<Content: View>: View {
    package let alignment: VerticalAlignment?
    package let content: Content
    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }
    public typealias Body = Never
}

/// Marks a grid row while lowering; `Grid` turns it into row cells.
package struct GridRowMarker: NodeBehavior {
    package let alignment: VerticalAlignment?
    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize { .zero }
}

extension GridRow: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: GridRow?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
    package func _lower(node: ViewNode) -> [LayoutNode] {
        [LayoutNode(GridRowMarker(alignment: alignment), children: node.lowerChildren())]
    }
}

extension Grid: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Grid?, transaction: Transaction) {
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
    package func _lower(node: ViewNode) -> [LayoutNode] {
        let items: [GridContent] = node.lowerChildren().map { n in
            if let row = n.behavior as? GridRowMarker { return .row(alignment: row.alignment, cells: n.children) }
            return .single(n)
        }
        return [.grid(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing, items)]
    }
}

extension View {
    /// The number of grid columns this cell spans.
    public func gridCellColumns(_ count: Int) -> some View { layoutValue(key: GridCellColumnsKey.self, value: count) }
}

// MARK: - Lazy grids

/// A vertically growing grid with columns described by `GridItem`s (04 §6).
/// In a scroll view its rows are created as they scroll into view (R9);
/// elsewhere every cell is created.
public struct LazyVGrid<Content: View>: View {
    package let columns: [GridItem]
    package let alignment: HorizontalAlignment
    package let spacing: CGFloat?
    package let content: Content
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }
    public typealias Body = Never
}

extension LazyVGrid: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: LazyVGrid?, transaction: Transaction) {
        if node.enclosingScrollViewport != nil {
            let layout = LazyVGridLayout(columns: columns, alignment: alignment, spacing: spacing)
            let lazy = LazyContainer(content: content, axis: .vertical, spacing: spacing ?? 8,
                                     arrangement: .grid(columns: { w in layout.columnCount(forWidth: w) },
                                                        layout: { LayoutNode.layout(layout, $0) }))
            node.reconcileChildren([(AnyHashable("lazy"), lazy)], transaction: transaction)
        } else {
            node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
        }
    }
    package func _lower(node: ViewNode) -> [LayoutNode] {
        if node.childKeys.first == AnyHashable("lazy") { return node.lowerChildren() }
        return [.lazyVGrid(columns: columns, alignment: alignment, spacing: spacing, node.lowerChildren())]
    }
}

/// A horizontally growing grid with rows described by `GridItem`s; in a
/// scroll view its columns are created as they scroll into view.
public struct LazyHGrid<Content: View>: View {
    package let rows: [GridItem]
    package let alignment: VerticalAlignment
    package let spacing: CGFloat?
    package let content: Content
    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }
    public typealias Body = Never
}

extension LazyHGrid: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: LazyHGrid?, transaction: Transaction) {
        let layout = LazyHGridLayout(rows: rows, alignment: alignment, spacing: spacing)
        if node.enclosingScrollViewport != nil {
            let lazy = LazyContainer(content: content, axis: .horizontal, spacing: spacing ?? 8,
                                     arrangement: .grid(columns: { h in layout.rowCount(forHeight: h) },
                                                        layout: { LayoutNode.layout(layout, $0) }))
            node.reconcileChildren([(AnyHashable("lazy"), lazy)], transaction: transaction)
        } else {
            node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
        }
    }
    package func _lower(node: ViewNode) -> [LayoutNode] {
        if node.childKeys.first == AnyHashable("lazy") { return node.lowerChildren() }
        return [.layout(LazyHGridLayout(rows: rows, alignment: alignment, spacing: spacing), node.lowerChildren())]
    }
}

// MARK: - EquatableView

/// A view whose updates are decided by its `==` (03 §4.1, §8).
///
/// Measured: a view whose stored properties are all plain values re-ran
/// although its custom `==` said "equal" — the comparison was field by field.
/// Our reading of the open question: field-by-field comparison applies when
/// the content is a plain-value (bitwise-copyable) type; otherwise `==` is
/// consulted and, when it answers equal, the content keeps its old value.
public struct EquatableView<Content: Equatable & View>: View {
    public var content: Content
    public init(content: Content) { self.content = content }
    public typealias Body = Never
}

extension EquatableView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: EquatableView?, transaction: Transaction) {
        if let old, !_isPOD(Content.self), old.content == content {
            node.refreshChildren(transaction: transaction)
            return
        }
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
}

extension View where Self: Equatable {
    /// Lets `==` decide whether the view needs updating.
    public func equatable() -> EquatableView<Self> { EquatableView(content: self) }
}

// MARK: - Scene phase

/// The operational state of a scene (06 §1).
public enum ScenePhase: Comparable, Hashable, Sendable {
    case background
    case inactive
    case active
}

private enum ScenePhaseKey: EnvironmentKey { static let defaultValue = ScenePhase.active }

extension EnvironmentValues {
    /// The phase of the enclosing scene.
    public var scenePhase: ScenePhase {
        get { self[ScenePhaseKey.self] }
        set { self[ScenePhaseKey.self] = newValue }
    }
}
