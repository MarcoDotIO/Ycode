import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// NavigationStack (round R9; 06 §2.1, suite T-NAV).
//
// Measured (06 §2.1): a pushed destination is created and gets `onAppear` at
// once; the push animates for about 0.5 s while the page below slides to
// −30 % of the width; the page below gets `onDisappear` (and its tasks are
// cancelled) at the end. A pop gives the page below `onAppear` at its start
// and the popped page `onDisappear` at its end; pages under the top that
// were never shown keep their appearance (pushing [4, 5] makes 4 appear with
// no frame; popping to the root then makes 4 disappear at once and 5 at the
// end); intermediate pages that were covered already disappeared. An edge
// swipe pops interactively: the top page follows the finger and the page
// below moves at 30 % (x = −0.3 W + 0.3 dx). The bar adds 82 points to the
// top (inline and large titles alike).
//
// Design (Ycode's): the stack keeps a view node per page (the root, the
// path's values and pages pushed by destination links); covered pages are
// *suspended* (their state stays; `ViewNode.setSuspended`) rather than
// removed. Transitions run on a frame driver for 0.5 s with the ease-in-out
// curve; programmatic path changes animate unless the transaction disables
// animations. Each page draws its own bar: a back button (chevron and the
// previous page's title, or "Back") unless hidden, the title (inline:
// headline, centred; large: bold large title below the controls on the
// headless phone host) and toolbar items; 82 points high on the headless
// host (the reference's inset), 44 on desktop hosts. Titles, toolbars and
// bar options register with their page (an observable page context), so a
// change re-renders only the bar. The back swipe starts within 20 points of
// a page's leading edge; released past half the width (or faster than 500
// points/s) it pops, else it returns.

// MARK: - Environment

/// Dismisses the current presentation: pops the navigation page, closes the
/// sheet or cover it is in.
@MainActor
public struct DismissAction {
    let action: (@MainActor () -> Void)?
    public func callAsFunction() { action?() }
}

private enum DismissKey: EnvironmentKey { static let defaultValue = DismissAction(action: nil) }
private enum IsPresentedKey: EnvironmentKey { static let defaultValue = false }
private enum NavigationContextKey: EnvironmentKey { static let defaultValue: NavigationContext? = nil }
private enum PageContextKey: EnvironmentKey { static let defaultValue: NavigationPageContext? = nil }
private enum DesktopChromeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    public var dismiss: DismissAction {
        get { self[DismissKey.self] }
        set { self[DismissKey.self] = newValue }
    }

    /// True inside a pushed page or a presentation.
    public var isPresented: Bool {
        get { self[IsPresentedKey.self] }
        set { self[IsPresentedKey.self] = newValue }
    }

    var _navigation: NavigationContext? {
        get { self[NavigationContextKey.self] }
        set { self[NavigationContextKey.self] = newValue }
    }

    var _navigationPage: NavigationPageContext? {
        get { self[PageContextKey.self] }
        set { self[PageContextKey.self] = newValue }
    }

    /// True on window-system hosts (desktop bars and sheets); false on the
    /// headless host, which keeps the reference phone's metrics.
    package var _desktopChrome: Bool {
        get { self[DesktopChromeKey.self] }
        set { self[DesktopChromeKey.self] = newValue }
    }
}

enum NavigationMetrics {
    /// 06 §2.1: the bar adds 82 points to the top inset.
    static let phoneBarHeight: CGFloat = 82
    static let desktopBarHeight: CGFloat = 44
    static let transitionDuration: TimeInterval = 0.5
    /// The page below a pushed page sits at −30 % of the width (06 §2.1).
    static let parallax: CGFloat = 0.3
    static let edgeWidth: CGFloat = 20

    static func barHeight(_ env: EnvironmentValues) -> CGFloat { env._desktopChrome ? desktopBarHeight : phoneBarHeight }
}

// MARK: - NavigationPath

/// A type-erased list of the values a navigation stack shows.
public struct NavigationPath: Equatable {
    package var elements: [AnyHashable]

    public init() { elements = [] }

    public init<S: Sequence>(_ elements: S) where S.Element: Hashable { self.elements = elements.map(AnyHashable.init) }

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    public mutating func append<V: Hashable>(_ value: V) { elements.append(AnyHashable(value)) }

    public mutating func removeLast(_ k: Int = 1) { elements.removeLast(min(k, elements.count)) }
}

// MARK: - Contexts

/// What views inside a stack use to navigate.
@MainActor
final class NavigationContext {
    var destinations: [ObjectIdentifier: (AnyHashable) -> AnyView?] = [:]
    weak var state: NavigationStackState?

    func register(_ type: ObjectIdentifier, _ make: @escaping (AnyHashable) -> AnyView?) {
        let isNew = destinations[type] == nil
        destinations[type] = make
        if isNew, let s = state, s.needsDestination { s.node?.invalidate(transaction: Transaction()) }
    }

    func destination(for value: AnyHashable) -> AnyView? {
        destinations[ObjectIdentifier(type(of: value.base))]?(value)
    }

    func push(_ value: AnyHashable) { state?.push(value) }
    func push(view: AnyView, key: AnyHashable) { state?.pushView(view, key: key) }
    func pop(view key: AnyHashable) { state?.popView(key) }
}

/// What a page shows in its bar (registered by the modifiers inside it).
@MainActor
@Observable
final class NavigationPageContext {
    var title: String?
    var displayMode = NavigationBarItem.TitleDisplayMode.automatic
    var backButtonHidden = false
    var barHidden = false
    var toolbar: [ToolbarEntryGroup] = []

    @ObservationIgnored var toolbarOrder: [ObjectIdentifier] = []

    func setTitle(_ t: String?) { if title != t { title = t } }

    func setToolbar(_ id: ObjectIdentifier, _ entries: [ToolbarEntry]?) {
        if let entries {
            if !toolbarOrder.contains(id) { toolbarOrder.append(id) }
            var groups = toolbar.filter { $0.id != id }
            groups.append(ToolbarEntryGroup(id: id, entries: entries))
            toolbar = toolbarOrder.compactMap { o in groups.first { $0.id == o } }
        } else {
            toolbarOrder.removeAll { $0 == id }
            if toolbar.contains(where: { $0.id == id }) { toolbar.removeAll { $0.id == id } }
        }
    }
}

package struct ToolbarEntryGroup {
    package let id: ObjectIdentifier
    package let entries: [ToolbarEntry]
}

// MARK: - Stack state

/// One page of a stack.
struct NavigationPageRecord {
    enum Kind {
        case root
        case value(AnyHashable)
        case view(AnyView)
    }
    let key: AnyHashable
    let kind: Kind
}

/// A width measured at layout (read by the stack's transitions).
final class LayoutWidthBox: @unchecked Sendable {
    var value: CGFloat = 0
}

@MainActor
final class NavigationStackState {
    let context = NavigationContext()
    let widthBox = LayoutWidthBox()
    var internalPath: [AnyHashable] = []
    var viewPages: [(key: AnyHashable, view: AnyView)] = []
    var pages: [NavigationPageRecord] = []
    var pageContexts: [AnyHashable: NavigationPageContext] = [:]
    var isBuilt = false
    var needsDestination = false
    /// The page fully shown (the top when no transition runs).
    var shown = AnyHashable("root")

    struct Motion {
        enum Kind { case push, pop }
        let kind: Kind
        let from: AnyHashable
        let to: AnyHashable
        /// The page leaving the stack (kept until the end), if any.
        let outgoing: AnyHashable?
        var progress: Double = 0
        var driver: FrameDriver?
    }
    var motion: Motion?
    /// The back swipe: the top page's translation, while dragging.
    var swipe: CGFloat?
    /// Where the next pop starts (a released back swipe continues).
    var motionStart: Double?
    var width: CGFloat { widthBox.value }

    weak var node: ViewNode?
    var readPath: (() -> [AnyHashable])?
    var writePath: (([AnyHashable]) -> Void)?

    init() {}

    var path: [AnyHashable] { readPath?() ?? internalPath }

    @MainActor func setPath(_ p: [AnyHashable], transaction: Transaction = Transaction()) {
        if let writePath {
            writePath(p)
        } else {
            internalPath = p
            node?.invalidate(transaction: transaction)
        }
    }

    @MainActor func push(_ value: AnyHashable) { setPath(path + [value]) }

    @MainActor func pushView(_ view: AnyView, key: AnyHashable) {
        guard !viewPages.contains(where: { $0.key == key }) else { return }
        viewPages.append((key, view))
        node?.invalidate(transaction: Transaction())
    }

    @MainActor func popView(_ key: AnyHashable) {
        guard viewPages.contains(where: { $0.key == key }) else { return }
        viewPages.removeAll { $0.key == key }
        node?.invalidate(transaction: Transaction())
    }

    /// Pops to the page before `key`.
    @MainActor func pop(above key: AnyHashable, transaction: Transaction = Transaction()) {
        guard let i = pages.firstIndex(where: { $0.key == key }), i > 0 else { return }
        let keep = pages[..<i]
        let pathCount = keep.filter { if case .value = $0.kind { return true } else { return false } }.count
        let viewKeys = Set(keep.compactMap { r -> AnyHashable? in if case .view = r.kind { return r.key } else { return nil } })
        if viewPages.contains(where: { !viewKeys.contains($0.key) }) {
            viewPages.removeAll { !viewKeys.contains($0.key) }
            if path.count == pathCount { node?.invalidate(transaction: transaction) }
        }
        if path.count != pathCount { setPath(Array(path.prefix(pathCount)), transaction: transaction) }
    }

    func pageContext(_ key: AnyHashable) -> NavigationPageContext {
        if let c = pageContexts[key] { return c }
        let c = NavigationPageContext()
        pageContexts[key] = c
        return c
    }
}

// MARK: - NavigationStack

/// A stack of pages over a root view (06 §2.1).
public struct NavigationStack<Data, Root: View>: View {
    let root: Root
    let readPath: (() -> [AnyHashable])?
    let writePath: (([AnyHashable]) -> Void)?
    public typealias Body = Never
}

extension NavigationStack where Data == NavigationPath {
    public init(@ViewBuilder root: () -> Root) {
        self.root = root()
        readPath = nil
        writePath = nil
    }

    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {
        self.root = root()
        readPath = { path.wrappedValue.elements }
        writePath = { p in
            var np = NavigationPath()
            np.elements = p
            if path.wrappedValue != np { path.wrappedValue = np }
        }
    }
}

extension NavigationStack where Data: MutableCollection, Data: RandomAccessCollection, Data: RangeReplaceableCollection,
    Data.Element: Hashable {
    public init(path: Binding<Data>, @ViewBuilder root: () -> Root) {
        self.root = root()
        readPath = { path.wrappedValue.map(AnyHashable.init) }
        writePath = { p in
            let v = Data(p.compactMap { $0.base as? Data.Element })
            if !path.wrappedValue.elementsEqual(v) { path.wrappedValue = v }
        }
    }
}

extension NavigationStack: ClipsHitTesting {}

extension NavigationStack: PrimitiveView {
    private func state(_ node: ViewNode) -> NavigationStackState {
        if let s = node.primitiveState as? NavigationStackState { return s }
        let s = NavigationStackState()
        node.primitiveState = s
        return s
    }

    private func pageView(_ s: NavigationStackState, _ record: NavigationPageRecord, index: Int,
                          previous: NavigationPageContext?) -> any View {
        let ctx = s.pageContext(record.key)
        let content: AnyView
        switch record.kind {
        case .root:
            content = AnyView(root)
        case .value(let v):
            if let d = s.context.destination(for: v) {
                content = d
            } else {
                s.needsDestination = true
                content = AnyView(EmptyView())
            }
        case .view(let v):
            content = v
        }
        let key = record.key
        let isRoot = index == 0
        weak var ws = s
        let back: () -> Void = { ws?.pop(above: key) }
        var swipe: ((DragSample?, Bool) -> Void)?
        if !isRoot { swipe = { sample, ended in ws?.handleSwipe(sample, ended: ended, key: key) } }
        var dismiss: (@MainActor () -> Void)?
        if !isRoot { dismiss = { ws?.pop(above: key) } }
        let host = NavigationPageHost(content: content, context: ctx, previous: previous, canGoBack: !isRoot,
                                      back: back, swipe: swipe)
        return host
            .environment(\._navigationPage, ctx)
            .environment(\.dismiss, DismissAction(action: dismiss))
            .environment(\.isPresented, !isRoot)
    }

    package func _makeChildren(node: ViewNode, old: NavigationStack?, transaction: Transaction) {
        let s = state(node)
        s.node = node
        s.context.state = s
        s.readPath = readPath
        s.writePath = writePath
        build(s, node: node, transaction: transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { build(state(node), node: node, transaction: transaction) } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    private func build(_ s: NavigationStackState, node: ViewNode, transaction: Transaction) {
        // The root first: its body registers the destinations (and the
        // pages' destinations register theirs as they are built).
        let rootRecord = NavigationPageRecord(key: AnyHashable("root"), kind: .root)
        let ctxView: (any View) -> any View = { v in
            AnyView(_fromValue: v)!.environment(\._navigation, s.context)
        }
        s.needsDestination = false
        let path = node.trackContent { s.path }
        var records = [rootRecord]
        for (i, v) in path.enumerated() {
            records.append(NavigationPageRecord(key: AnyHashable([AnyHashable(i), v]), kind: .value(v)))
        }
        for p in s.viewPages { records.append(NavigationPageRecord(key: p.key, kind: .view(p.view))) }
        let oldPages = s.pages
        let oldTop = oldPages.last?.key ?? rootRecord.key
        let newTop = records.last!.key
        let newKeys = Set(records.map(\.key))
        // Transitions (06 §2.1).
        let animate = s.isBuilt && !transaction.disablesAnimations && s.width > 0
        if oldTop != newTop, s.isBuilt {
            finishMotion(s, node: node)
            let isPop = oldPages.contains { $0.key == newTop }
            let kind: NavigationStackState.Motion.Kind = isPop ? .pop : .push
            let outgoing: AnyHashable? = newKeys.contains(oldTop) ? nil : oldTop
            if animate {
                s.motion = .init(kind: kind, from: oldTop, to: newTop, outgoing: outgoing)
            } else {
                s.motion = nil
            }
            // A pop shows the page below at once (onAppear at the start).
            if kind == .pop, let c = child(node, newTop) { c.setSuspended(false) }
        }
        var items: [(AnyHashable, any View)] = []
        var previous: NavigationPageContext?
        for (i, r) in records.enumerated() {
            items.append((r.key, ctxView(pageView(s, r, index: i, previous: previous))))
            previous = s.pageContext(r.key)
        }
        if let m = s.motion, let out = m.outgoing, !newKeys.contains(out), let c = child(node, out) {
            items.append((out, c.view))
        }
        s.pages = records
        node.reconcileChildren(items, transaction: transaction)
        for (k, _) in s.pageContexts where !newKeys.contains(k) && k != s.motion?.outgoing { s.pageContexts[k] = nil }
        if !s.isBuilt || s.motion == nil {
            // No animation: the new top is shown, the page it covers is
            // suspended at once.
            if s.isBuilt, oldTop != newTop, newKeys.contains(oldTop), let c = child(node, oldTop) {
                if records.firstIndex(where: { $0.key == oldTop })! < records.count - 1 { c.setSuspended(true) }
            }
            s.shown = newTop
        } else if s.motion?.driver == nil {
            startMotion(s, node: node)
        }
        s.isBuilt = true
    }

    private func child(_ node: ViewNode, _ key: AnyHashable) -> ViewNode? {
        zip(node.childKeys, node.children).first { $0.0 == key }?.1
    }

    private func startMotion(_ s: NavigationStackState, node: ViewNode) {
        let begin = node.graph.currentTime
        let start = s.motionStart ?? 0
        s.motionStart = nil
        let d = NavigationMetrics.transitionDuration * max(0.2, 1 - start)
        s.motion?.progress = start
        let driver = FrameDriver(owner: node) { [weak s, weak node] t in
            guard let s, let node, var m = s.motion else { return (false, false) }
            let p = min(1, max(0, (t - begin) / d))
            m.progress = start + (1 - start) * UnitCurve.easeInOut.value(at: p)
            s.motion = m
            if p >= 1 { MainActor.assumeIsolated { completeMotion(s, node: node) } }
            return (true, p < 1)
        }
        driver.onChange = { [weak node] in node?.graph.scheduleUpdate(transaction: Transaction()) }
        s.motion?.driver = driver
        node.graph.activate(driver)
    }

    /// The end of a push or pop: the covered page disappears (it is
    /// suspended), the page that left is removed.
    private func completeMotion(_ s: NavigationStackState, node: ViewNode) {
        guard let m = s.motion else { return }
        s.motion = nil
        s.shown = m.to
        if m.kind == .push, let c = child(node, m.from), s.pages.contains(where: { $0.key == m.from }) {
            c.setSuspended(true)
        }
        if m.outgoing != nil { node.invalidate(transaction: Transaction()) } else {
            node.graph.scheduleUpdate(transaction: Transaction())
        }
    }

    private func finishMotion(_ s: NavigationStackState, node: ViewNode) {
        guard let m = s.motion else { return }
        m.driver?.cancel()
        s.motion = nil
        s.shown = m.to
        if m.kind == .push, let c = child(node, m.from), s.pages.contains(where: { $0.key == m.from }) {
            c.setSuspended(true)
        }
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let s = state(node)
        func lowered(_ key: AnyHashable) -> LayoutNode? {
            guard let c = child(node, key) else { return nil }
            let ns = c.lower()
            let n: LayoutNode = ns.count == 1 ? ns[0] : .vstack(ns)
            return n.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        var layers: [LayoutNode] = []
        let w = s.width
        if let dx = s.swipe, let top = s.pages.last, s.pages.count >= 2 {
            let below = s.pages[s.pages.count - 2].key
            if let b = lowered(below) { layers.append(b.offset(x: -NavigationMetrics.parallax * w + NavigationMetrics.parallax * dx)) }
            if let t = lowered(top.key) { layers.append(t.offset(x: dx)) }
        } else if let m = s.motion {
            let p = CGFloat(m.progress)
            switch m.kind {
            case .push:
                if let a = lowered(m.from) { layers.append(a.offset(x: -NavigationMetrics.parallax * w * p)) }
                if let b = lowered(m.to) { layers.append(b.offset(x: w * (1 - p))) }
            case .pop:
                if let b = lowered(m.to) { layers.append(b.offset(x: -NavigationMetrics.parallax * w * (1 - p))) }
                if let a = lowered(m.from) { layers.append(a.offset(x: w * p)) }
            }
        } else if let top = lowered(s.shown) ?? s.pages.last.flatMap({ lowered($0.key) }) {
            layers.append(top)
        }
        let stack = LayoutNode(NavigationStackBehavior(width: s.widthBox), children: [LayoutNode.zstack(alignment: .topLeading, layers)])
        stack.renderEffects.append(.clip({ size in Path(CGRect(origin: .zero, size: size)) }, eoFill: false))
        return [stack]
    }

    package func _preferences(node: ViewNode) -> PreferenceValues {
        // Pages' preferences stay inside the stack (only the shown page's
        // pass on).
        let s = state(node)
        return child(node, s.shown)?.preferenceValues() ?? PreferenceValues()
    }
}

/// Takes the proposed size and remembers its width (the transitions' unit).
struct NavigationStackBehavior: NodeBehavior {
    let width: LayoutWidthBox
    var traitChild: Int? { nil }

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        let s = node.children.first?.sizeThatFits(p) ?? .zero
        return CGSize(width: p.width.map { $0.isFinite ? $0 : s.width } ?? s.width,
                      height: p.height.map { $0.isFinite ? $0 : s.height } ?? s.height)
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        width.value = size.width
        return node.children.isEmpty ? [] : [ChildPlacement(index: 0, origin: .zero, size: size, proposal: ProposedViewSize(size))]
    }
}

extension NavigationStackState {
    /// The back swipe (06 §2.1).
    @MainActor func handleSwipe(_ sample: DragSample?, ended: Bool, key: AnyHashable) {
        guard let node, motion == nil, pages.last?.key == key, pages.count >= 2 else { return }
        let below = pages[pages.count - 2].key
        let belowNode = zip(node.childKeys, node.children).first { $0.0 == below }?.1
        guard let sample else {
            // Cancelled: back to the top page.
            swipe = nil
            belowNode?.setSuspended(true)
            node.graph.scheduleUpdate(transaction: Transaction())
            return
        }
        let dx = max(0, sample.location.x - sample.startLocation.x)
        if swipe == nil { belowNode?.setSuspended(false) }
        if !ended {
            swipe = dx
            node.graph.scheduleUpdate(transaction: Transaction())
            return
        }
        swipe = nil
        let completes = dx > width / 2 || sample.velocity.width > 500
        if completes {
            // Continue as a pop from where the finger left it (the page
            // below already appeared).
            motionStart = width > 0 ? min(1, Double(dx / width)) : 1
            pop(above: key)
        } else {
            belowNode?.setSuspended(true)
            node.graph.scheduleUpdate(transaction: Transaction())
        }
    }
}

/// A page: its bar over its content.
struct NavigationPageHost: View {
    let content: AnyView
    let context: NavigationPageContext
    let previous: NavigationPageContext?
    let canGoBack: Bool
    let back: () -> Void
    let swipe: ((DragSample?, Bool) -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        VStack(spacing: 0) {
            if !context.barHidden {
                NavigationBar(context: context, previous: previous, canGoBack: canGoBack && !context.backButtonHidden, back: back)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.plainBackground)
        .modifier(EdgeSwipeModifier(handler: swipe))
    }
}

/// The back swipe's gesture (a high-priority gesture of non-root pages).
struct EdgeSwipeModifier: ViewModifier {
    let handler: ((DragSample?, Bool) -> Void)?
    func body(content: Content) -> some View {
        if let handler {
            content.highPriorityGesture(EdgeSwipeGesture(handler: handler))
        } else {
            content
        }
    }
}

struct EdgeSwipeGesture: Gesture, PrimitiveGesture {
    typealias Value = Void
    typealias Body = Never
    let handler: (DragSample?, Bool) -> Void
    func _makeRecognizer(context: GestureContext) -> GestureRecognizer {
        let h = handler
        return EdgeSwipeRecognizer(edgeWidth: NavigationMetrics.edgeWidth, context: context) { s, e in
            MainActor.assumeIsolated { h(s, e) }
        }
    }
}

/// A page's bar.
struct NavigationBar: View {
    let context: NavigationPageContext
    let previous: NavigationPageContext?
    let canGoBack: Bool
    let back: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\._desktopChrome) private var desktop
    @Environment(\._splitColumn) private var splitColumn

    /// R13: a desktop split view's column shows no bar of its own when the
    /// bar would be empty (no title, items or back button); the window
    /// toolbar is the column's bar, as on desktop systems. (Decided here,
    /// not in the page: the page must not depend on its toolbar, which its
    /// content registers.)
    private var isEmpty: Bool {
        splitColumn != nil && desktop && !canGoBack && context.title == nil
            && !context.toolbar.contains { !$0.entries.isEmpty }
    }

    var body: some View {
        if !isEmpty { bar }
    }

    @ViewBuilder private var bar: some View {
        let palette = ControlPalette(scheme)
        let height = desktop ? NavigationMetrics.desktopBarHeight : NavigationMetrics.phoneBarHeight
        let large = !desktop && context.displayMode != .inline
        let entries = context.toolbar.flatMap(\.entries)
        let leading = entries.filter { $0.placement.isLeading }
        let trailing = entries.filter { !$0.placement.isLeading && $0.placement != .principal && $0.placement != .bottomBar }
        let principal = entries.first { $0.placement == .principal && $0.spacer == nil }
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 12) {
                    if canGoBack {
                        Button(action: back) {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                                Text(previous?.title ?? "Back").lineLimit(1)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(Array(leading.enumerated()), id: \.offset) { $0.element.barView }
                    Spacer(minLength: 0)
                    ForEach(Array(trailing.enumerated()), id: \.offset) { $0.element.barView }
                }
                if let principal {
                    principal.view
                } else if !large, let t = context.title {
                    Text(t).font(.headline).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            if large {
                Text(context.title ?? "").font(.largeTitle.bold()).lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: height - 44, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(palette.barBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1 / 3).allowsHitTesting(false) }
    }
}

// MARK: - Registrations

/// `navigationTitle`, bar options and toolbars register with their page.
struct PageRegistrationModifier: PrimitiveModifier {
    let apply: @MainActor (NavigationPageContext, ObjectIdentifier) -> Void
    let remove: (@MainActor (NavigationPageContext, ObjectIdentifier) -> Void)?

    private final class Reg { weak var page: NavigationPageContext? }

    private func sync(_ node: ViewNode) {
        let reg = (node.primitiveState as? Reg) ?? Reg()
        node.primitiveState = reg
        guard let page = node.environment._navigationPage else { return }
        reg.page = page
        apply(page, ObjectIdentifier(node))
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: PageRegistrationModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) {
        if let remove, let page = (node.primitiveState as? Reg)?.page { remove(page, ObjectIdentifier(node)) }
    }
}

/// `navigationDestination(for:)` registers with its stack.
struct DestinationRegistrationModifier<D: Hashable, Destination: View>: PrimitiveModifier {
    let destination: (D) -> Destination

    private func sync(_ node: ViewNode) {
        let make = destination
        node.environment._navigation?.register(ObjectIdentifier(D.self)) { v in
            (v.base as? D).map { AnyView(make($0)) }
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: DestinationRegistrationModifier, node: ViewNode) { sync(node) }
}

/// `navigationDestination(isPresented:)`: pushes while the binding is true.
struct PresentedDestinationModifier<Destination: View>: PrimitiveModifier {
    let isPresented: Binding<Bool>
    let destination: () -> Destination

    private final class Key {}

    private func sync(_ node: ViewNode) {
        let key = (node.primitiveState as? Key) ?? Key()
        node.primitiveState = key
        guard let nav = node.environment._navigation else { return }
        let k = AnyHashable(ObjectIdentifier(key))
        if node.trackContent({ isPresented.wrappedValue }) {
            let binding = isPresented
            nav.push(view: AnyView(destination().environment(\.dismiss, DismissAction { binding.wrappedValue = false })), key: k)
        } else {
            nav.pop(view: k)
        }
    }

    var _rebuildsWhenDirty: Bool { true }
    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: PresentedDestinationModifier, node: ViewNode) { sync(node) }
}

extension View {
    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View {
        let t = Text(titleKey).plainString
        return modifier(PageRegistrationModifier(apply: { p, _ in p.setTitle(t) }, remove: nil))
    }

    @_disfavoredOverload
    public func navigationTitle<S: StringProtocol>(_ title: S) -> some View {
        let t = String(title)
        return modifier(PageRegistrationModifier(apply: { p, _ in p.setTitle(t) }, remove: nil))
    }

    public func navigationTitle(_ title: Text) -> some View {
        let t = title.plainString
        return modifier(PageRegistrationModifier(apply: { p, _ in p.setTitle(t) }, remove: nil))
    }

    public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View {
        modifier(PageRegistrationModifier(apply: { p, _ in if p.displayMode != mode { p.displayMode = mode } }, remove: nil))
    }

    public func toolbarTitleDisplayMode(_ mode: ToolbarTitleDisplayMode) -> some View {
        navigationBarTitleDisplayMode(mode == .inline ? .inline : (mode == .automatic ? .automatic : .large))
    }

    public func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View {
        modifier(PageRegistrationModifier(apply: { p, _ in if p.backButtonHidden != hidden { p.backButtonHidden = hidden } },
                                          remove: nil))
    }

    public func navigationBarHidden(_ hidden: Bool) -> some View {
        modifier(PageRegistrationModifier(apply: { p, _ in if p.barHidden != hidden { p.barHidden = hidden } }, remove: nil))
    }

    public func navigationDestination<D: Hashable, C: View>(for data: D.Type,
                                                            @ViewBuilder destination: @escaping (D) -> C) -> some View {
        modifier(DestinationRegistrationModifier(destination: destination))
    }

    public func navigationDestination<V: View>(isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> V) -> some View {
        modifier(PresentedDestinationModifier(isPresented: isPresented, destination: destination))
    }

    public func navigationDestination<D: Hashable, C: View>(item: Binding<D?>,
                                                            @ViewBuilder destination: @escaping (D) -> C) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(PresentedDestinationModifier(isPresented: presented) {
            Group { if let v = item.wrappedValue { destination(v) } }
        })
    }
}

extension Text {
    /// The text's characters without styling (titles).
    package var plainString: String {
        let r = resolve(in: EnvironmentValues())
        return r.string
    }
}

/// Title display modes of a navigation bar.
public enum NavigationBarItem {
    public enum TitleDisplayMode: Hashable, Sendable { case automatic, inline, large }
}

public struct ToolbarTitleDisplayMode: Hashable, Sendable {
    let kind: Int
    public static let automatic = ToolbarTitleDisplayMode(kind: 0)
    public static let inline = ToolbarTitleDisplayMode(kind: 1)
    public static let large = ToolbarTitleDisplayMode(kind: 2)
    public static let inlineLarge = ToolbarTitleDisplayMode(kind: 3)
}

// MARK: - NavigationLink

/// A button that pushes a value (or a destination view) on the enclosing
/// navigation stack.
public struct NavigationLink<Label: View, Destination: View>: View {
    let label: Label
    let value: AnyHashable?
    let destination: Destination?
    @Environment(\._navigation) private var navigation
    @State private var key = LinkKey()

    final class LinkKey {}

    public var body: some View {
        let nav = navigation, value = value, destination = destination, key = key
        Button {
            if let value {
                nav?.push(value)
            } else if let destination {
                nav?.push(view: AnyView(destination), key: AnyHashable(ObjectIdentifier(key)))
            }
        } label: {
            HStack {
                label
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension NavigationLink where Destination == Never {
    public init<P: Hashable>(value: P?, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.value = value.map(AnyHashable.init)
        destination = nil
    }
}

extension NavigationLink where Destination == Never, Label == Text {
    public init<P: Hashable>(_ titleKey: LocalizedStringKey, value: P?) {
        self.init(value: value) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol, P: Hashable>(_ title: S, value: P?) {
        self.init(value: value) { Text(title) }
    }
}

extension NavigationLink {
    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.destination = destination()
        value = nil
    }

    public init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.destination = destination
        value = nil
    }
}

extension NavigationLink where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder destination: () -> Destination) {
        self.init(destination: destination) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) {
        self.init(destination: destination) { Text(title) }
    }
}

/// The deprecated container: a stack on this host.
public struct NavigationView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { NavigationStack { content } }
}
