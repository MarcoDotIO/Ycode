import Foundation

// Lazy containers (round R9; 06 §3, 10-plan.md T-LIST).
//
// Observed (06 §3): a `List` of 1 000 rows creates the 13 rows that are
// visible (rows 0–12, pitch 52); a `LazyVStack` in a `ScrollView` creates 15
// rows of 48 (the visible part runs 34 points into the bottom safe area) and
// reports the exact content size for equal rows (1 000 × 48 − 8 = 47 992);
// `scrollTo` creates the rows at the new position and removes the old ones;
// a plain `VStack` creates everything.
//
// Design (Ycode's):
// - Content is *enumerated*, not built: tuples, groups, conditionals and
//   `AnyView` are walked; a `ForEach` contributes a collection whose
//   element views are made only for the materialised indices
//   (`LazyItemEnumerating`). Every item has a stable key (its structural
//   path plus, for collection elements, the element ID) and keeps its view
//   node, and state, while it stays materialised.
// - Items are grouped in *units* along the axis (one item per unit for
//   stacks, a row of cells for grids). Each unit's extent is measured when it
//   is laid out and remembered by key; unmeasured units use the mean of the
//   measured ones, so equal rows give the exact content size at once.
// - After every layout pass the container compares the visible region (the
//   enclosing scroll view's viewport, `ScrollViewportProviding`, in its own
//   coordinates) with the units it materialised; when they differ it asks
//   for another update, which creates the missing views and removes the
//   others (their `onAppear`/`onDisappear` run then). A unit is visible when
//   it overlaps the region by more than 0.01 point; there is no overscan, so
//   the counts are the reference's.
// - Outside a scroll view every item is materialised (as the reference's
//   lazy stacks then behave like stacks).

// MARK: - Items

/// One materialisable item of a lazy container's content.
package struct LazyItem {
    package enum Role: Equatable { case row, header, footer }

    /// The item's identity inside its container.
    package let key: AnyHashable
    /// The element ID of a `ForEach` item (implicit tag, `scrollTo` target).
    package let id: AnyHashable?
    package var role: Role = .row
    /// The section the item belongs to (nil: none) and its place in it.
    package var section: AnyHashable?
    package var sectionIndex = 0
    package var isFirstInSection = false
    package var isLastInSection = false
    /// Outline rows (`OutlineGroup`, `List(children:)`, `DisclosureGroup`).
    package var depth = 0
    package var outline: Outline?
    /// Makes the item's view (evaluated only when materialised).
    package let make: @MainActor () -> any View

    package struct Outline {
        package var hasChildren: Bool
        package var isExpanded: Bool
        package var toggle: @MainActor () -> Void
        /// The key of the parent outline row, if any.
        package var parentKey: AnyHashable?

        package init(hasChildren: Bool, isExpanded: Bool, toggle: @escaping @MainActor () -> Void, parentKey: AnyHashable?) {
            self.hasChildren = hasChildren
            self.isExpanded = isExpanded
            self.toggle = toggle
            self.parentKey = parentKey
        }
    }

    package init(key: AnyHashable, id: AnyHashable?, role: Role = .row, make: @escaping @MainActor () -> any View) {
        self.key = key
        self.id = id
        self.role = role
        self.make = make
    }
}

/// The enumerated items of a container's content.
package struct LazyItems {
    package enum Segment {
        case single(LazyItem)
        /// `count` items made on demand.
        case collection(count: Int, item: @MainActor (Int) -> LazyItem)
    }

    package private(set) var segments: [Segment] = []
    private var starts: [Int] = []
    package private(set) var count = 0

    package init() {}

    package mutating func append(_ item: LazyItem) {
        starts.append(count)
        segments.append(.single(item))
        count += 1
    }

    package mutating func append(count n: Int, item: @escaping @MainActor (Int) -> LazyItem) {
        guard n > 0 else { return }
        starts.append(count)
        segments.append(.collection(count: n, item: item))
        count += n
    }

    @MainActor package func item(at i: Int) -> LazyItem {
        // The segment whose start is the last one ≤ i.
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= i { lo = mid } else { hi = mid - 1 }
        }
        switch segments[lo] {
        case .single(let it): return it
        case .collection(_, let make): return make(i - starts[lo])
        }
    }

    /// Marks items `from..<to` as belonging to section `key` (number
    /// `index`); with `rows`, also the first and last row of the group.
    @MainActor package mutating func markSection(_ key: AnyHashable, index: Int, from first: Int, to end: Int, rows: Bool) {
        guard first < end else { return }
        let last = end - 1
        for k in segments.indices {
            let s = starts[k]
            let n: Int
            switch segments[k] {
            case .single: n = 1
            case .collection(let c, _): n = c
            }
            guard s + n > first && s <= last else { continue }
            switch segments[k] {
            case .single(var it):
                it.section = key
                it.sectionIndex = index
                if rows && s == first { it.isFirstInSection = true }
                if rows && s == last { it.isLastInSection = true }
                segments[k] = .single(it)
            case .collection(let c, let make):
                let base = s
                segments[k] = .collection(count: c) { i in
                    var it = make(i)
                    let j = base + i
                    guard j >= first && j <= last else { return it }
                    it.section = key
                    it.sectionIndex = index
                    if rows && j == first { it.isFirstInSection = true }
                    if rows && j == last { it.isLastInSection = true }
                    return it
                }
            }
        }
    }
}

/// Shared state of one enumeration: outline expansion.
package final class LazyEnumerationContext: @unchecked Sendable {
    /// Keys of expanded outline rows and disclosure groups.
    package var expanded: Set<AnyHashable> = []
    /// Keys whose expansion was decided by the user (else the default).
    package var decided: Set<AnyHashable> = []
    /// Called when an outline row is toggled.
    package var onToggle: (@MainActor () -> Void)?
    package var depth = 0
    package var parentKey: AnyHashable?
    /// Sections enumerated so far (their index).
    package var sectionCount = 0
    /// (R13) The ID of the `ForEach` element being enumerated eagerly: the
    /// first row it produces (a leaf, or a disclosure group's label) takes it
    /// as its selection value.
    package var elementID: AnyHashable?
    /// (R13) Whether an outline row with this ID starts expanded
    /// (`outlineInitialExpansion`; nil: collapsed).
    package var initialExpansion: (@MainActor (AnyHashable) -> Bool)?

    package init() {}

    package func isExpanded(_ key: AnyHashable, default d: Bool) -> Bool {
        decided.contains(key) ? expanded.contains(key) : d
    }

    /// The default expansion of an outline row with `id`.
    @MainActor package func initiallyExpanded(_ id: AnyHashable?) -> Bool {
        guard let id, let f = initialExpansion else { return false }
        return f(id)
    }

    /// The pending element ID, once.
    package func takeElementID() -> AnyHashable? {
        defer { elementID = nil }
        return elementID
    }

    @MainActor package func toggle(_ key: AnyHashable, current: Bool) {
        decided.insert(key)
        if current { expanded.remove(key) } else { expanded.insert(key) }
        onToggle?()
    }
}

/// Views that contribute items to a lazy container without being built.
@MainActor
package protocol LazyItemEnumerating {
    func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext)
}

/// Appends the items of `view` (a single item unless it enumerates).
@MainActor
package func enumerateLazyItems(_ view: any View, prefix: [AnyHashable], into items: inout LazyItems,
                                context: LazyEnumerationContext) {
    if let e = view as? any LazyItemEnumerating {
        e._lazyItems(prefix: prefix, into: &items, context: context)
        return
    }
    if view is EmptyView { return }
    var item = LazyItem(key: AnyHashable(prefix), id: context.takeElementID(), make: { view })
    item.depth = context.depth
    if let p = context.parentKey { item.outline = .init(hasChildren: false, isExpanded: false, toggle: {}, parentKey: p) }
    items.append(item)
}

extension TupleView: LazyItemEnumerating {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        for (i, child) in Mirror(reflecting: value).children.enumerated() {
            guard let v = child.value as? any View else { continue }
            enumerateLazyItems(v, prefix: prefix + [AnyHashable(i)], into: &items, context: context)
        }
    }
}

extension Group: LazyItemEnumerating where Content: View {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        enumerateLazyItems(content, prefix: prefix, into: &items, context: context)
    }
}

extension Optional: LazyItemEnumerating where Wrapped: View {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        if case .some(let v) = self { enumerateLazyItems(v, prefix: prefix + [AnyHashable(0)], into: &items, context: context) }
    }
}

extension _ConditionalContent: LazyItemEnumerating {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        switch storage {
        case .trueContent(let v): enumerateLazyItems(v, prefix: prefix + [AnyHashable(true)], into: &items, context: context)
        case .falseContent(let v): enumerateLazyItems(v, prefix: prefix + [AnyHashable(false)], into: &items, context: context)
        }
    }
}

extension AnyView: LazyItemEnumerating {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        enumerateLazyItems(storage, prefix: prefix + [AnyHashable(ObjectIdentifier(type(of: storage)))], into: &items,
                           context: context)
    }
}

extension ForEach: LazyItemEnumerating where Content: View {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        let data = self.data, content = self.content, idOf = self.idOf
        let depth = context.depth, parent = context.parentKey
        // Nested enumerations (an outline group or section inside a
        // `ForEach` row) are flattened eagerly; plain rows stay lazy.
        if let first = data.first, content(first) is any LazyItemEnumerating {
            for element in data {
                let id = AnyHashable(idOf(element))
                context.elementID = id
                enumerateLazyItems(content(element), prefix: prefix + [id], into: &items, context: context)
                context.elementID = nil
            }
            return
        }
        items.append(count: data.count) { i in
            let element = data[data.index(data.startIndex, offsetBy: i)]
            let id = AnyHashable(idOf(element))
            var item = LazyItem(key: AnyHashable(prefix + [id]), id: id, make: { content(element) })
            item.depth = depth
            if let parent { item.outline = .init(hasChildren: false, isExpanded: false, toggle: {}, parentKey: parent) }
            return item
        }
    }
}

// MARK: - Scroll viewports

/// The state of a scroll view as lazy containers inside it see it.
@MainActor
package protocol ScrollViewportProviding: AnyObject {
    /// The part of the window the scroll view shows (its frame grown by the
    /// content insets it scrolls under), from the last layout pass.
    var visibleWindowRect: CGRect? { get }
    /// The scroll view's axes.
    var scrollAxes: Axis.Set { get }
    /// Scrolls so that `rect` (window coordinates of the last layout) is
    /// visible; with an anchor, so that the anchor point of `rect` meets the
    /// same point of the visible region.
    func reveal(_ rect: CGRect, anchor: UnitPoint?, transaction: Transaction)
}

extension ViewNode {
    /// The nearest scroll view above this node.
    package var enclosingScrollViewport: ScrollViewportProviding? {
        var n = parent
        while let m = n {
            if let v = m.primitiveState as? any ScrollViewportProviding { return v }
            n = m.parent
        }
        return nil
    }
}

// MARK: - Container state

/// The state of one lazy container: its items, the units it materialised
/// and the extents it measured. Layout reads it off the main actor's
/// isolation (layout runs on the main thread); views are made on it.
package final class LazyContainerState: @unchecked Sendable {
    package var items = LazyItems()
    /// Item keys by index (for extents and lookups).
    package private(set) var keys: [AnyHashable] = []
    /// Items per unit (1 for stacks; the column count of a grid).
    package var unitSize = 1
    /// Measured extents along the axis, by unit key.
    package var extents: [AnyHashable: CGFloat] = [:]
    /// The materialised units.
    package private(set) var materialised: Range<Int> = 0..<0
    /// The units the last layout found visible (nil: not known yet).
    package private(set) var visible: Range<Int>?
    /// True when a scroll view encloses the container.
    package private(set) var isLazy = false
    /// Unit starts along the axis from the last placement (units + 1 values).
    package var starts: [CGFloat] = []
    package var axis: Axis = .vertical
    package var spacing: CGFloat = 0
    /// The container's window frame from the last layout.
    package private(set) var windowFrame: CGRect?
    package let context = LazyEnumerationContext()
    package weak var node: ViewNode?

    package init() {}

    package var unitCount: Int { unitSize <= 1 ? items.count : (items.count + unitSize - 1) / unitSize }

    package func unitKey(_ u: Int) -> AnyHashable {
        unitSize <= 1 ? (u < keys.count ? keys[u] : AnyHashable(u)) : AnyHashable(u)
    }

    /// Item indices of a unit range.
    package func itemRange(_ units: Range<Int>) -> Range<Int> {
        let n = max(unitSize, 1)
        return min(units.lowerBound * n, items.count)..<min(units.upperBound * n, items.count)
    }

    /// The unit holding item `i`.
    package func unit(ofItem i: Int) -> Int { i / max(unitSize, 1) }

    /// Re-enumerates `content` and decides what to materialise.
    @MainActor package func update(content: any View, node: ViewNode) {
        self.node = node
        context.onToggle = { [weak node] in node?.invalidate(transaction: Transaction()) }
        var items = LazyItems()
        context.sectionCount = 0
        context.depth = 0
        context.parentKey = nil
        context.elementID = nil
        context.initialExpansion = node.environment._outlineInitialExpansion
        enumerateLazyItems(content, prefix: [], into: &items, context: context)
        self.items = items
        keys = (0..<items.count).map { items.item(at: $0).key }
        isLazy = node.enclosingScrollViewport != nil
        let units = unitCount
        if !isLazy {
            materialised = 0..<units
        } else if let v = visible {
            materialised = min(v.lowerBound, units)..<min(v.upperBound, units)
        } else {
            // Before the first layout: the first unit, measured to estimate
            // the others.
            materialised = 0..<min(units, 1)
        }
    }

    /// The materialised items as keyed views (wrapped by `wrap`).
    @MainActor package func materialisedViews(wrap: ((LazyItem, Int) -> any View)?) -> [(AnyHashable, any View)] {
        itemRange(materialised).map { i in
            let it = items.item(at: i)
            return (it.key, wrap?(it, i) ?? it.make())
        }
    }

    /// The mean measured extent (nil before any measurement).
    package func estimate(local: [Int: CGFloat]) -> CGFloat? {
        var sum: CGFloat = 0, n = 0
        for v in local.values { sum += v; n += 1 }
        if n == 0 {
            for v in extents.values { sum += v; n += 1 }
        }
        return n > 0 ? sum / CGFloat(n) : nil
    }

    /// Unit starts for the current items, using `local` extents (units laid
    /// out now), remembered extents and the estimate for the rest.
    package func computeStarts(local: [Int: CGFloat]) -> [CGFloat] {
        let units = unitCount
        let est = estimate(local: local) ?? 0
        var out = [CGFloat](repeating: 0, count: units + 1)
        var y: CGFloat = 0
        for u in 0..<units {
            out[u] = y
            let e = local[u] ?? extents[unitKey(u)] ?? est
            y += e
            if u < units - 1 { y += spacing }
        }
        out[units] = y
        return out
    }

    /// The along-axis extent of unit `u` from `starts`.
    package func extent(_ u: Int, in starts: [CGFloat]) -> CGFloat {
        let e = starts[u + 1] - starts[u]
        return u < starts.count - 2 ? e - spacing : e
    }

    /// The frame of item `i` in the container's coordinates (cross extent 0).
    package func frame(ofItem i: Int) -> CGRect? {
        let u = unit(ofItem: i)
        guard u + 1 < starts.count else { return nil }
        let a = starts[u], l = extent(u, in: starts)
        return axis == .vertical ? CGRect(x: 0, y: a, width: 0, height: l) : CGRect(x: a, y: 0, width: l, height: 0)
    }

    @MainActor package func index(ofID id: AnyHashable) -> Int? {
        for i in 0..<items.count where items.item(at: i).id == id { return i }
        return keys.firstIndex(of: id)
    }

}

extension LazyContainerState: GeometryObserving {
    package func geometryChanged(_ geometry: NodeGeometry, node: ViewNode) {
        windowFrame = geometry.frame
        guard isLazy, let viewport = node.enclosingScrollViewport?.visibleWindowRect, starts.count == unitCount + 1 else { return }
        let lo: CGFloat, hi: CGFloat
        if axis == .vertical {
            lo = viewport.minY - geometry.frame.minY
            hi = viewport.maxY - geometry.frame.minY
        } else {
            lo = viewport.minX - geometry.frame.minX
            hi = viewport.maxX - geometry.frame.minX
        }
        let eps: CGFloat = 0.01
        var first = unitCount, last = -1
        // Units are in order: binary search for the first unit ending after lo.
        var a = 0, b = unitCount
        while a < b {
            let m = (a + b) / 2
            if starts[m] + extent(m, in: starts) > lo + eps { b = m } else { a = m + 1 }
        }
        var u = a
        while u < unitCount, starts[u] < hi - eps {
            if starts[u] + extent(u, in: starts) > lo + eps {
                first = min(first, u)
                last = u
            }
            u += 1
        }
        let range = last >= first ? first..<(last + 1) : a..<a
        visible = range
        if range != materialised { node.invalidate(transaction: Transaction()) }
    }
}

// MARK: - Stack layout

/// The layout of a lazy stack's materialised units: each at its start along
/// the axis (measured, remembered or estimated extents of the units before
/// it), aligned across it; the stack answers the estimated content length
/// and the widest materialised unit.
package struct LazyStackBehavior: NodeBehavior {
    package let axis: Axis
    package let alignment: Alignment
    /// Unit index of each child.
    package let units: [Int]
    package let state: LazyContainerState

    package init(axis: Axis, alignment: Alignment, units: [Int], state: LazyContainerState) {
        self.axis = axis
        self.alignment = alignment
        self.units = units
        self.state = state
    }

    private var cross: Axis { axis == .vertical ? .horizontal : .vertical }

    private func childProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(axis, along: nil, across: p[cross])
    }

    private func measure(_ p: ProposedViewSize, node: LayoutNode) -> (local: [Int: CGFloat], cross: CGFloat) {
        let cp = childProposal(p)
        var local: [Int: CGFloat] = [:]
        var c: CGFloat = 0
        for (k, child) in node.children.enumerated() where k < units.count {
            let s = child.sizeThatFits(cp)
            local[units[k]] = s[axis]
            c = Swift.max(c, s[cross])
        }
        return (local, c)
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let (local, c) = measure(p, node: node)
        let starts = state.computeStarts(local: local)
        let along = starts.last ?? 0
        let across = p[cross].map { $0.isFinite ? Swift.max($0, c) : c } ?? c
        return axis == .vertical ? CGSize(width: across, height: along) : CGSize(width: along, height: across)
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        do {
            let p = ProposedViewSize(axis, along: nil, across: size[cross])
            let (local, _) = measure(ProposedViewSize(size), node: node)
            for (u, e) in local { state.extents[state.unitKey(u)] = e }
            let starts = state.computeStarts(local: local)
            state.starts = starts
            var out: [ChildPlacement] = []
            for (k, child) in node.children.enumerated() where k < units.count {
                let u = units[k]
                guard u < starts.count else { continue }
                let s = child.sizeThatFits(p)
                let d = child.dimensions(p)
                let crossOrigin: CGFloat
                if axis == .vertical {
                    crossOrigin = alignment.horizontal.key.defaultValue(for: size) - d[alignment.horizontal]
                } else {
                    crossOrigin = alignment.vertical.key.defaultValue(for: size) - d[alignment.vertical]
                }
                let origin = axis == .vertical ? CGPoint(x: crossOrigin, y: starts[u]) : CGPoint(x: starts[u], y: crossOrigin)
                out.append(ChildPlacement(index: k, origin: origin, size: s, proposal: p))
            }
            return out
        }
    }
}

// MARK: - The container view

/// A lazily materialising container (package; `LazyVStack`, `LazyHStack`,
/// lazy grids and `List` are built on it).
package struct LazyContainer: View {
    package enum Arrangement {
        case stack(Alignment)
        /// Units of `columns(cross)` items laid out by `layout` (a grid).
        case grid(columns: @MainActor (CGFloat) -> Int, layout: @MainActor ([LayoutNode]) -> LayoutNode)
    }

    package let content: any View
    package let axis: Axis
    package let spacing: CGFloat
    package let arrangement: Arrangement
    /// Wraps each materialised item's view (list rows).
    package var wrap: (@MainActor (LazyItem, Int) -> any View)?
    /// Receives the state (list controllers).
    package var attach: (@MainActor (LazyContainerState) -> Void)?

    package init(content: any View, axis: Axis, spacing: CGFloat, arrangement: Arrangement,
                 wrap: (@MainActor (LazyItem, Int) -> any View)? = nil,
                 attach: (@MainActor (LazyContainerState) -> Void)? = nil) {
        self.content = content
        self.axis = axis
        self.spacing = spacing
        self.arrangement = arrangement
        self.wrap = wrap
        self.attach = attach
    }

    package typealias Body = Never
}

extension LazyContainer: GraphInputComparable {
    package nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

extension LazyContainer: PrimitiveView {
    private func state(_ node: ViewNode) -> LazyContainerState {
        if let s = node.primitiveState as? LazyContainerState { return s }
        let s = LazyContainerState()
        node.primitiveState = s
        return s
    }

    private func build(_ node: ViewNode, _ transaction: Transaction) {
        let s = state(node)
        s.axis = axis
        s.spacing = spacing
        attach?(s)
        let views: [(AnyHashable, any View)] = node.trackContent {
            s.update(content: content, node: node)
            return s.materialisedViews(wrap: wrap)
        }
        node.reconcileChildren(views, transaction: transaction)
    }

    package func _makeChildren(node: ViewNode, old: LazyContainer?, transaction: Transaction) {
        build(node, transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { build(node, transaction) } else { node.refreshChildren(transaction: transaction) }
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let s = state(node)
        let children = node.lowerChildren()
        let n: LayoutNode
        switch arrangement {
        case .stack(let alignment):
            s.unitSize = 1
            let r = s.itemRange(s.materialised)
            let units = Array(r).map { s.unit(ofItem: $0) }
            n = LayoutNode(LazyStackBehavior(axis: axis, alignment: alignment, units: Array(units.prefix(children.count)),
                                             state: s), children: children)
        case let .grid(columns, layout):
            n = LayoutNode(LazyGridBehavior(axis: axis, columns: columns, state: s),
                           children: [layout(children)])
        }
        n.owner = node
        return [n]
    }
}

/// A lazy grid: the materialised units (rows of a vertical grid) are laid
/// out together by the grid's own layout and placed at the first unit's
/// start; the other units use the measured mean extent.
package struct LazyGridBehavior: NodeBehavior {
    package let axis: Axis
    package let columns: @MainActor (CGFloat) -> Int
    package let state: LazyContainerState

    private var cross: Axis { axis == .vertical ? .horizontal : .vertical }

    private func measure(_ p: ProposedViewSize, node: LayoutNode) -> (local: [Int: CGFloat], cross: CGFloat, inner: CGSize) {
        guard let inner = node.children.first else { return ([:], 0, .zero) }
        let cp = ProposedViewSize(axis, along: nil, across: p[cross])
        let s = inner.sizeThatFits(cp)
        let units = state.materialised
        var local: [Int: CGFloat] = [:]
        if !units.isEmpty {
            let k = CGFloat(units.count)
            let e = Swift.max(0, (s[axis] - (k - 1) * state.spacing) / k)
            for u in units { local[u] = e }
        }
        return (local, s[cross], s)
    }

    package func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        if let w = p[cross], w.isFinite {
            let columns = self.columns
            state.unitSize = Swift.max(1, MainActor.assumeIsolated { columns(w) })
        }
        let (local, c, _) = measure(p, node: node)
        let along = state.computeStarts(local: local).last ?? 0
        let across = p[cross].map { $0.isFinite ? Swift.max($0, c) : c } ?? c
        return axis == .vertical ? CGSize(width: across, height: along) : CGSize(width: along, height: across)
    }

    package func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        do {
            guard !node.children.isEmpty else { return [] }
            let (local, _, inner) = measure(ProposedViewSize(size), node: node)
            for (u, e) in local { state.extents[state.unitKey(u)] = e }
            let starts = state.computeStarts(local: local)
            state.starts = starts
            let u0 = state.materialised.lowerBound
            let a = u0 < starts.count ? starts[u0] : 0
            let origin = axis == .vertical ? CGPoint(x: 0, y: a) : CGPoint(x: a, y: 0)
            let p = ProposedViewSize(axis, along: nil, across: size[cross])
            var s = inner
            if axis == .vertical { s.width = size.width } else { s.height = size.height }
            return [ChildPlacement(index: 0, origin: origin, size: s, proposal: p)]
        }
    }
}

// MARK: - LazyVStack / LazyHStack

/// Views one above the other, created as they scroll into view (06 §3).
public struct LazyVStack<Content: View>: View {
    package let alignment: HorizontalAlignment
    package let spacing: CGFloat?
    package let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        LazyContainer(content: content, axis: .vertical, spacing: spacing ?? LazyMetrics.defaultSpacing,
                      arrangement: .stack(Alignment(horizontal: alignment, vertical: .center)))
    }
}

/// Views side by side, created as they scroll into view.
public struct LazyHStack<Content: View>: View {
    package let alignment: VerticalAlignment
    package let spacing: CGFloat?
    package let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
                pinnedViews: PinnedScrollableViews = .init(), @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        LazyContainer(content: content, axis: .horizontal, spacing: spacing ?? LazyMetrics.defaultSpacing,
                      arrangement: .stack(Alignment(horizontal: .center, vertical: alignment)))
    }
}

package enum LazyMetrics {
    /// Spacing between lazy stack items when none is given (the stacks'
    /// standard spacing between equal views; 06 §3 rows 40 + 8).
    package static let defaultSpacing: CGFloat = 8
}

/// Views that stay pinned while a lazy container scrolls (accepted; pinning
/// is not implemented).
public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1 << 0)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 1 << 1)
}

// MARK: - Initial outline expansion (R13, Ycode's own API)

private enum OutlineInitialExpansionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AnyHashable) -> Bool)? = nil
}

extension EnvironmentValues {
    package var _outlineInitialExpansion: (@MainActor (AnyHashable) -> Bool)? {
        get { self[OutlineInitialExpansionKey.self] }
        set { self[OutlineInitialExpansionKey.self] = newValue }
    }
}

extension View {
    /// OpenViews' own API (SwiftUI has none): which rows of the outlines in
    /// this view's lists (`OutlineGroup`, `List(children:)`, and
    /// `DisclosureGroup`s without an `isExpanded` binding inside a
    /// `ForEach`) start expanded, by element ID. A row the user expanded or
    /// collapsed keeps that state.
    public func outlineInitialExpansion(_ isExpanded: @escaping @MainActor (AnyHashable) -> Bool) -> some View {
        environment(\._outlineInitialExpansion, isExpanded)
    }

    /// The rows whose IDs are in `ids` start expanded.
    public func outlineInitialExpansion<ID: Hashable>(_ ids: Set<ID>) -> some View {
        outlineInitialExpansion { id in (id.base as? ID).map(ids.contains) ?? false }
    }
}
