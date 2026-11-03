import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Split views (round R9 and PARITY §5.4 R12): `HSplitView`, `VSplitView`
// (the macOS names, for the IDE) and `NavigationSplitView` (06 §2.2).
//
// Panes (Ycode's rules; the reference measured only the collapsed iPhone
// case): panes sit side by side (or one above the other) with 1-point
// dividers; each divider can be dragged within an 8-point band. A pane's
// limits are its answers to a zero and an infinite proposal along the axis
// (`frame(minWidth:maxWidth:)` sets them); its first length is its ideal
// length when it has a finite maximum, the panes without one share the
// rest. A drag moves one divider: the panes on both sides change within
// their limits. When the container grows or shrinks, the last flexible pane
// takes the difference.
//
// NavigationSplitView: below 600 points of width it collapses into a
// navigation stack (06 §2.2: on the compact iPhone the sidebar shows first;
// a selection in a sidebar list pushes the next column, clearing it pops
// back). Otherwise its columns are panes: sidebar 180–400 (240 at first),
// content 200–500 (280), the detail the rest (at least 300);
// `navigationSplitViewColumnWidth` overrides them; each column is the root of
// a navigation stack of its own; `columnVisibility` hides the sidebar
// (`.detailOnly`) or the sidebar and content (`.detailOnly` with three
// columns shows only the detail; `.doubleColumn` hides the sidebar of three);
// a sidebar button in the first shown column's bar toggles it.

// MARK: - Panes

/// Lengths and limits of a row of panes.
final class SplitPanesState: @unchecked Sendable {
    var axis: Axis = .horizontal
    /// Pane lengths along the axis (after the last layout).
    var lengths: [CGFloat] = []
    var limits: [(min: CGFloat, max: CGFloat, ideal: CGFloat)] = []
    var total: CGFloat = 0
    /// Lengths the user chose (nil: automatic).
    var chosen: [CGFloat?] = []
    var dragStart: [CGFloat]?
    /// Fixed limits per pane (navigation split columns); nil: measured.
    var fixedLimits: [(min: CGFloat, ideal: CGFloat, max: CGFloat)?] = []
    /// Panes that are kept (suspended) but not shown.
    var hidden: Set<Int> = []

    func dividerThickness(_ k: Int) -> CGFloat {
        hidden.contains(k) || hidden.contains(k + 1) ? 0 : Self.dividerThickness
    }

    var dividersLength: CGFloat {
        limits.count > 1 ? (0..<(limits.count - 1)).map(dividerThickness).reduce(0, +) : 0
    }
    weak var node: ViewNode?

    static let dividerThickness: CGFloat = 1
    static let dividerBand: CGFloat = 8

    /// Resolves lengths for `total` from the limits and the chosen lengths.
    func resolve(total t: CGFloat) -> [CGFloat] {
        let n = limits.count
        guard n > 0 else { return [] }
        let avail = max(0, t - dividersLength)
        if chosen.count != n { chosen = Array(repeating: nil, count: n) }
        var out = [CGFloat](repeating: 0, count: n)
        var flexible: [Int] = []
        var used: CGFloat = 0
        for i in 0..<n {
            if hidden.contains(i) {
                out[i] = 0
            } else if let c = chosen[i] {
                out[i] = min(max(c, limits[i].min), limits[i].max)
                used += out[i]
            } else if limits[i].max.isFinite || fixedLimits.indices.contains(i) && fixedLimits[i] != nil {
                out[i] = min(max(limits[i].ideal, limits[i].min), limits[i].max)
                used += out[i]
            } else {
                flexible.append(i)
            }
        }
        if flexible.isEmpty, let last = (0..<n).last(where: { !hidden.contains($0) }) { flexible = [last]; used -= out[last] }
        guard !flexible.isEmpty else { return out }
        let share = max(0, avail - used) / CGFloat(flexible.count)
        for i in flexible { out[i] = max(share, limits[i].min) }
        // Too long: take the excess from the last panes first (down to their
        // minimum).
        var excess = out.reduce(0, +) - avail
        var i = n - 1
        while excess > 0.001 && i >= 0 {
            let give = min(excess, out[i] - limits[i].min)
            out[i] -= give
            excess -= give
            i -= 1
        }
        return out
    }

    @MainActor func drag(divider k: Int, by d: CGFloat, ended: Bool) {
        guard k + 1 < lengths.count else { return }
        if dragStart == nil { dragStart = lengths }
        guard let start = dragStart else { return }
        var a = start[k] + d
        a = min(max(a, limits[k].min), limits[k].max)
        var b = start[k] + start[k + 1] - a
        b = min(max(b, limits[k + 1].min), limits[k + 1].max)
        a = start[k] + start[k + 1] - b
        if chosen.count != lengths.count { chosen = Array(repeating: nil, count: lengths.count) }
        // Every pane keeps its current length from now on, except the last
        // flexible one, which absorbs container changes.
        for i in lengths.indices { chosen[i] = start[i] }
        chosen[k] = a
        chosen[k + 1] = b
        if let last = limits.lastIndex(where: { !$0.max.isFinite }), last != k, last != k + 1 { chosen[last] = nil } else {
            chosen[lengths.count - 1] = nil
        }
        if ended { dragStart = nil }
        node?.graph.scheduleUpdate(transaction: Transaction())
    }
}

/// Places panes and dividers: children alternate pane, divider, pane, ….
struct SplitPanesBehavior: NodeBehavior {
    let state: SplitPanesState

    private func paneProposal(_ length: CGFloat?, cross: CGFloat?) -> ProposedViewSize {
        state.axis == .horizontal ? ProposedViewSize(width: length, height: cross) : ProposedViewSize(width: cross, height: length)
    }

    private func measureLimits(cross: CGFloat?, node: LayoutNode) {
        let panes = stride(from: 0, to: node.children.count, by: 2).map { node.children[$0] }
        state.limits = panes.enumerated().map { i, p in
            if state.hidden.contains(i) { return (0, 0, 0) }
            if state.fixedLimits.indices.contains(i), let f = state.fixedLimits[i] { return (f.min, f.max, f.ideal) }
            let lo = p.sizeThatFits(paneProposal(0, cross: cross))[state.axis]
            let hi = p.sizeThatFits(paneProposal(.infinity, cross: cross))[state.axis]
            let ideal = p.sizeThatFits(paneProposal(nil, cross: cross))[state.axis]
            return (lo, Swift.max(lo, hi), ideal)
        }
    }

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let cross: Axis = state.axis == .horizontal ? .vertical : .horizontal
        measureLimits(cross: p[cross], node: node)
        let along = p[state.axis].map { $0.isFinite ? $0 : 0 }
            ?? (state.limits.map { Swift.min(Swift.max($0.ideal, $0.min), $0.max.isFinite ? $0.max : Swift.max($0.ideal, $0.min)) }
                .reduce(0, +) + state.dividersLength)
        let lengths = state.resolve(total: along)
        var c: CGFloat = 0
        for (i, l) in lengths.enumerated() { c = Swift.max(c, node.children[2 * i].sizeThatFits(paneProposal(l, cross: p[cross]))[cross]) }
        let across = p[cross].map { $0.isFinite ? $0 : c } ?? c
        return state.axis == .horizontal ? CGSize(width: along, height: across) : CGSize(width: across, height: along)
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        let cross: Axis = state.axis == .horizontal ? .vertical : .horizontal
        measureLimits(cross: size[cross], node: node)
        let lengths = state.resolve(total: size[state.axis])
        state.lengths = lengths
        state.total = size[state.axis]
        var out: [ChildPlacement] = []
        var a: CGFloat = 0
        for (i, l) in lengths.enumerated() {
            let pp = paneProposal(l, cross: size[cross])
            let s = state.axis == .horizontal ? CGSize(width: l, height: size.height) : CGSize(width: size.width, height: l)
            out.append(ChildPlacement(index: 2 * i, origin: state.axis == .horizontal ? CGPoint(x: a, y: 0) : CGPoint(x: 0, y: a),
                                      size: s, proposal: pp))
            a += l
            if 2 * i + 1 < node.children.count {
                let t = state.dividerThickness(i)
                let ds = state.axis == .horizontal ? CGSize(width: t, height: size.height) : CGSize(width: size.width, height: t)
                out.append(ChildPlacement(index: 2 * i + 1, origin: state.axis == .horizontal ? CGPoint(x: a, y: 0) : CGPoint(x: 0, y: a),
                                          size: ds, proposal: ProposedViewSize(ds)))
                a += t
            }
        }
        return out
    }
}

/// A divider between panes: a hairline with an 8-point drag band.
struct SplitDivider: View {
    let axis: Axis
    let index: Int
    let state: SplitPanesState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        let band = SplitPanesState.dividerBand
        let s = state, k = index
        Rectangle().fill(palette.separator)
            .overlay {
                Rectangle().fill(Color.clear)
                    .frame(width: axis == .horizontal ? band : nil, height: axis == .vertical ? band : nil)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in s.drag(divider: k, by: axis == .horizontal ? v.translation.width : v.translation.height, ended: false) }
                        .onEnded { v in s.drag(divider: k, by: axis == .horizontal ? v.translation.width : v.translation.height, ended: true) })
            }
    }
}

/// Panes from enumerated views (package; split views build on it).
struct SplitPanes: View, PrimitiveView {
    let axis: Axis
    let panes: [(AnyHashable, any View)]
    var fixedLimits: [(min: CGFloat, ideal: CGFloat, max: CGFloat)?] = []
    var hidden: Set<Int> = []
    typealias Body = Never

    private func state(_ node: ViewNode) -> SplitPanesState {
        if let s = node.primitiveState as? SplitPanesState { return s }
        let s = SplitPanesState()
        node.primitiveState = s
        return s
    }

    func _makeChildren(node: ViewNode, old: SplitPanes?, transaction: Transaction) {
        let s = state(node)
        s.node = node
        s.axis = axis
        s.fixedLimits = fixedLimits
        s.hidden = hidden
        var items: [(AnyHashable, any View)] = []
        for (i, p) in panes.enumerated() {
            items.append(p)
            if i < panes.count - 1 { items.append((AnyHashable("divider \(i)"), SplitDivider(axis: axis, index: i, state: s))) }
        }
        if s.chosen.count != panes.count { s.chosen = Array(repeating: nil, count: panes.count) }
        node.reconcileChildren(items, transaction: transaction)
        // Hidden panes keep their state (suspended, 06 §2.1's rule).
        for (i, c) in node.children.enumerated() {
            c.setSuspended(i % 2 == 0 ? hidden.contains(i / 2) : s.dividerThickness(i / 2) == 0)
        }
    }

    func _lower(node: ViewNode) -> [LayoutNode] {
        let s = state(node)
        let children = node.children.enumerated().map { i, c -> LayoutNode in
            let pane = i / 2
            if s.hidden.contains(pane) || (i % 2 == 1 && s.dividerThickness(pane) == 0) { return LayoutNode.color() }
            let ns = c.lower()
            return ns.count == 1 ? ns[0] : .zstack(ns)
        }
        let n = LayoutNode(SplitPanesBehavior(state: state(node)), children: children)
        return [n]
    }
}

extension SplitPanes: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

@MainActor
func enumeratedViews(_ content: any View) -> [(AnyHashable, any View)] {
    var items = LazyItems()
    enumerateLazyItems(content, prefix: [], into: &items, context: LazyEnumerationContext())
    return (0..<items.count).map { i in
        let it = items.item(at: i)
        return (it.key, it.make())
    }
}

// MARK: - HSplitView / VSplitView

/// Views side by side with draggable dividers (the macOS container, for
/// desktop hosts).
public struct HSplitView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { SplitPanesHost(axis: .horizontal, content: content) }
}

/// Views one above the other with draggable dividers.
public struct VSplitView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { SplitPanesHost(axis: .vertical, content: content) }
}

/// Enumerates its content into panes (so state reads in it are its own).
struct SplitPanesHost<Content: View>: View {
    let axis: Axis
    let content: Content
    var body: some View { SplitPanes(axis: axis, panes: enumeratedViews(content)) }
}

// MARK: - NavigationSplitView

/// Which columns of a split view are shown.
public struct NavigationSplitViewVisibility: Equatable, Codable, Sendable {
    let kind: Int
    public static let automatic = NavigationSplitViewVisibility(kind: 0)
    public static let all = NavigationSplitViewVisibility(kind: 1)
    public static let doubleColumn = NavigationSplitViewVisibility(kind: 2)
    public static let detailOnly = NavigationSplitViewVisibility(kind: 3)
}

/// A column of a split view.
public struct NavigationSplitViewColumn: Hashable, Sendable {
    let kind: Int
    public static let sidebar = NavigationSplitViewColumn(kind: 0)
    public static let content = NavigationSplitViewColumn(kind: 1)
    public static let detail = NavigationSplitViewColumn(kind: 2)
}

/// How a split view arranges its columns (accepted; one look).
@MainActor @preconcurrency
public protocol NavigationSplitViewStyle {}

public struct AutomaticNavigationSplitViewStyle: NavigationSplitViewStyle { public init() {} }
public struct BalancedNavigationSplitViewStyle: NavigationSplitViewStyle { public init() {} }
public struct ProminentDetailNavigationSplitViewStyle: NavigationSplitViewStyle { public init() {} }

extension NavigationSplitViewStyle where Self == AutomaticNavigationSplitViewStyle {
    public static var automatic: AutomaticNavigationSplitViewStyle { AutomaticNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == BalancedNavigationSplitViewStyle {
    public static var balanced: BalancedNavigationSplitViewStyle { BalancedNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == ProminentDetailNavigationSplitViewStyle {
    public static var prominentDetail: ProminentDetailNavigationSplitViewStyle { ProminentDetailNavigationSplitViewStyle() }
}

/// Column options registered by the views in a column.
@MainActor
final class SplitColumnContext {
    var width: (min: CGFloat?, ideal: CGFloat, max: CGFloat?)?
    weak var owner: ViewNode?
}

/// The collapsed split view's link with the lists in its columns.
@MainActor
final class CollapsedSplitContext {
    /// Column index of each list's column → whether it has a selection.
    var show: (Int, Bool) -> Void = { _, _ in }
    var clearSelections: [Int: () -> Void] = [:]
}

private enum SplitColumnKey: EnvironmentKey { static let defaultValue: SplitColumnContext? = nil }
private enum CollapsedSplitKey: EnvironmentKey { static let defaultValue: CollapsedSplitContext? = nil }
private enum CollapsedColumnIndexKey: EnvironmentKey { static let defaultValue = -1 }

extension EnvironmentValues {
    var _splitColumn: SplitColumnContext? {
        get { self[SplitColumnKey.self] }
        set { self[SplitColumnKey.self] = newValue }
    }

    var _collapsedSplit: CollapsedSplitContext? {
        get { self[CollapsedSplitKey.self] }
        set { self[CollapsedSplitKey.self] = newValue }
    }

    var _collapsedColumnIndex: Int {
        get { self[CollapsedColumnIndexKey.self] }
        set { self[CollapsedColumnIndexKey.self] = newValue }
    }
}

struct ColumnWidthModifier: PrimitiveModifier {
    let width: (min: CGFloat?, ideal: CGFloat, max: CGFloat?)

    private func sync(_ node: ViewNode) {
        guard let c = node.environment._splitColumn else { return }
        let changed = c.width.map { $0.min != width.min || $0.ideal != width.ideal || $0.max != width.max } ?? true
        c.width = width
        if changed { c.owner?.invalidate(transaction: Transaction()) }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: ColumnWidthModifier, node: ViewNode) { sync(node) }
}

extension View {
    public func navigationSplitViewColumnWidth(_ width: CGFloat) -> some View {
        modifier(ColumnWidthModifier(width: (width, width, width)))
    }

    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        modifier(ColumnWidthModifier(width: (min, ideal, max)))
    }

    public func navigationSplitViewStyle<S: NavigationSplitViewStyle>(_ style: S) -> some View { self }
}

enum SplitMetrics {
    static let collapseWidth: CGFloat = 600
    static let sidebar = (min: CGFloat(180), ideal: CGFloat(240), max: CGFloat(400))
    static let content = (min: CGFloat(200), ideal: CGFloat(280), max: CGFloat(500))
    static let detailMin: CGFloat = 300
}

/// A sidebar (and content) column beside a detail column (06 §2.2).
public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View {
    let sidebar: Sidebar
    let content: Content?
    let detail: Detail
    let visibility: Binding<NavigationSplitViewVisibility>?
    public typealias Body = Never
}

extension NavigationSplitView {
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
        visibility = nil
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar,
                @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
        visibility = columnVisibility
    }
}

extension NavigationSplitView where Content == EmptyView {
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        content = nil
        self.detail = detail()
        visibility = nil
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar,
                @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        content = nil
        self.detail = detail()
        visibility = columnVisibility
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, preferredCompactColumn: Binding<NavigationSplitViewColumn>,
                @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.init(columnVisibility: columnVisibility, sidebar: sidebar, detail: detail)
    }
}

/// The split view's state: its mode and columns.
@MainActor
final class SplitViewState: GeometryObserving {
    var collapsed: Bool?
    var internalVisibility = NavigationSplitViewVisibility.automatic
    /// Columns pushed in the collapsed stack (1: content or detail, …).
    var collapsedPath: [Int] = []
    let columns = [SplitColumnContext(), SplitColumnContext(), SplitColumnContext()]
    let collapsedContext = CollapsedSplitContext()
    /// The View menu's sidebar toggle (R11).
    let sidebarController = SidebarController()
    weak var node: ViewNode?

    func geometryChanged(_ g: NodeGeometry, node: ViewNode) {
        let c = g.size.width < SplitMetrics.collapseWidth
        if collapsed != c {
            collapsed = c
            node.invalidate(transaction: Transaction())
        }
    }
}

extension NavigationSplitView: PrimitiveView {
    private func state(_ node: ViewNode) -> SplitViewState {
        if let s = node.primitiveState as? SplitViewState { return s }
        let s = SplitViewState()
        node.primitiveState = s
        return s
    }

    private var columnCount: Int { content == nil ? 2 : 3 }

    private func currentVisibility(_ s: SplitViewState) -> NavigationSplitViewVisibility {
        visibility?.wrappedValue ?? s.internalVisibility
    }

    private func setVisibility(_ s: SplitViewState, _ v: NavigationSplitViewVisibility) {
        if let b = visibility { b.wrappedValue = v } else {
            s.internalVisibility = v
            s.node?.invalidate(transaction: Transaction(animation: .easeInOut(duration: 0.25)))
        }
    }

    package func _makeChildren(node: ViewNode, old: NavigationSplitView?, transaction: Transaction) {
        let s = state(node)
        s.node = node
        for c in s.columns { c.owner = node }
        if s.collapsed == nil {
            // Before the first layout: the window's width.
            if case .window(let size, let insets)? = node.graph.layout?.mode {
                s.collapsed = size.width - insets.horizontal < SplitMetrics.collapseWidth
            } else {
                s.collapsed = false
            }
        }
        let vis = node.trackContent { currentVisibility(s) }
        if s.collapsed == true {
            buildCollapsed(s, node: node, transaction: transaction)
        } else {
            buildRegular(s, node: node, visibility: vis, transaction: transaction)
        }
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { _makeChildren(node: node, old: self, transaction: transaction) } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    private func buildCollapsed(_ s: SplitViewState, node: ViewNode, transaction: Transaction) {
        let n = columnCount
        let ctx = s.collapsedContext
        weak var ws = s
        ctx.show = { [weak node] column, has in
            guard let s = ws else { return }
            // A selection in column `column` shows the next column; clearing
            // it goes back to that column.
            var p = s.collapsedPath
            if has {
                if !p.contains(column + 1), column + 1 < n { p = Array(p.prefix(column)) + [column + 1] }
            } else {
                p = Array(p.prefix(column))
            }
            if p != s.collapsedPath {
                s.collapsedPath = p
                node?.invalidate(transaction: Transaction())
            }
        }
        let content = self.content, detail = self.detail
        let path = Binding<[Int]>(get: { ws?.collapsedPath ?? [] }, set: { [weak node] new in
            guard let s = ws else { return }
            let removed = s.collapsedPath.filter { !new.contains($0) }
            s.collapsedPath = new
            for c in removed { s.collapsedContext.clearSelections[c - 1]?() }
            node?.invalidate(transaction: Transaction())
        })
        let stack = NavigationStack(path: path) {
            sidebar
                .environment(\._collapsedColumnIndex, 0)
                .navigationDestination(for: Int.self) { column in
                    Group {
                        if column == 1, let content {
                            AnyView(content)
                        } else {
                            AnyView(detail)
                        }
                    }
                    .environment(\._collapsedColumnIndex, column)
                }
        }
        .environment(\._collapsedSplit, ctx)
        node.reconcileChildren([(AnyHashable("collapsed"), stack)], transaction: transaction)
    }

    private func buildRegular(_ s: SplitViewState, node: ViewNode, visibility vis: NavigationSplitViewVisibility,
                              transaction: Transaction) {
        let n = columnCount
        let shown: [Int]
        switch vis {
        case .detailOnly: shown = [n - 1]
        case .doubleColumn: shown = n == 3 ? [1, 2] : [0, 1]
        default: shown = Array(0..<n)
        }
        let first = shown.first ?? 0
        let toggle = { [weak s] in
            guard let s else { return }
            let hidden = vis == .detailOnly || (n == 3 && vis == .doubleColumn)
            self.setVisibility(s, hidden ? .all : .detailOnly)
        }
        // View > Show/Hide Sidebar (R11).
        s.sidebarController.toggleAction = toggle
        if let services = node.environment._windowServices {
            if s.sidebarController.isVisible != shown.contains(0) { s.sidebarController.isVisible = shown.contains(0) }
            services.sidebar = s.sidebarController
        }
        func column(_ i: Int) -> any View {
            let view: AnyView
            switch i {
            case 0: view = AnyView(sidebar)
            case 1 where n == 3: view = AnyView(content!)
            default: view = AnyView(detail)
            }
            let root = view
                .modifier(SidebarToggleToolbar(show: i == first && n > 1 && !node.environment._sidebarToggleRemoved,
                                               controller: s.sidebarController))
            return NavigationStack { root }
                .environment(\._splitColumn, s.columns[i])
        }
        var panes: [(AnyHashable, any View)] = []
        var limits: [(min: CGFloat, ideal: CGFloat, max: CGFloat)?] = []
        for i in 0..<n {
            panes.append((AnyHashable("column \(i)"), column(i)))
            let isDetail = i == n - 1
            if let w = s.columns[i].width {
                limits.append((w.min ?? w.ideal, w.ideal, w.max ?? w.ideal))
            } else if isDetail {
                limits.append(nil)
            } else {
                let m = (i == 0) ? SplitMetrics.sidebar : SplitMetrics.content
                limits.append((m.min, m.ideal, m.max))
            }
        }
        let hidden = Set((0..<n).filter { !shown.contains($0) })
        let panesView = SplitPanes(axis: .horizontal, panes: panes, fixedLimits: limits, hidden: hidden)
        node.reconcileChildren([(AnyHashable("regular"), panesView)], transaction: transaction)
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let ns = node.lowerChildren()
        let n = LayoutNode(SplitHostBehavior(), children: [ns.count == 1 ? ns[0] : .zstack(ns)])
        n.owner = node
        return [n]
    }
}

/// Takes the proposed size (split views fill their container).
struct SplitHostBehavior: NodeBehavior {
    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let s = node.children.first?.sizeThatFits(p) ?? .zero
        return CGSize(width: p.width.map { $0.isFinite ? $0 : s.width } ?? s.width,
                      height: p.height.map { $0.isFinite ? $0 : s.height } ?? s.height)
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        node.children.isEmpty ? [] : [ChildPlacement(index: 0, origin: .zero, size: size, proposal: ProposedViewSize(size))]
    }
}

/// The sidebar toggle in the first shown column's bar.
/// (R13: it holds the split view's controller, not a new closure each
/// time, so that an unchanged toggle does not register its toolbar again:
/// that re-registration re-evaluated the column's bar in a loop.)
struct SidebarToggleToolbar: ViewModifier {
    let show: Bool
    let controller: SidebarController
    func body(content: Content) -> some View {
        if show {
            let controller = controller
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: { controller.toggle() }) { Image(systemName: "sidebar.left") }.buttonStyle(.borderless)
                }
            }
        } else {
            content
        }
    }
}
