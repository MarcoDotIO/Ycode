import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// ScrollView (round R9; 06 §3, golden `scrollView`, `scrollView.horizontal`).
//
// Layout (golden rows): along a scroll axis the scroll view takes the
// proposed length, or the content's when none is proposed; across it, it is
// the content's answer to the proposed cross length. The content is
// proposed the cross length and an unspecified length along the scroll axes,
// placed at the top-leading corner (centred across the axis when narrower)
// and moved by the content offset; the scroll view clips it.
//
// Scrolling (06 §3, Ycode's rules where the spec is silent):
// - the offset runs from 0 to content − viewport per axis;
// - a scroll view whose frame touches the safe-area boundary scrolls its
//   content under that inset (the reference: container 382 × 644 with a
//   34-point bottom content inset, so 678 points of rows are visible);
// - a drag (10 points to start, 06 §7) moves the content with the finger;
//   on release it continues at the release velocity, decelerating by 0.998
//   per millisecond (06 §3: ≈ 0.967 per 60 Hz frame) until slower than
//   10 points/s or at an edge (no rubber band);
// - wheel and trackpad deltas from OVPlatform scroll at once (a notch is 10
//   points, R7); a vertical-only scroll view also takes horizontal deltas as
//   vertical and a horizontal-only one vertical deltas as horizontal;
//   nested scroll views take the delta innermost first, passing it on at an
//   edge;
// - indicators (Ycode's look): 3-point capsules 3 points inside the trailing
//   and bottom edges, at least 36 long, shown while scrolling and for 1 s
//   after (then faded over 0.25 s), always with `.visible`.

// MARK: - State

/// The offset, sizes and motion of one scroll view.
package final class ScrollViewState: @unchecked Sendable {
    package var axes: Axis.Set = .vertical
    /// The content offset (top-leading of the visible content, content
    /// coordinates, without the insets).
    package var offset: CGPoint = .zero
    package var contentSize: CGSize = .zero
    package var viewportSize: CGSize = .zero
    /// Safe-area insets the content scrolls under.
    package var insets = EdgeInsets()
    package var windowFrame: CGRect?
    package var isEnabled = true
    package var indicators: (vertical: ScrollIndicatorVisibility, horizontal: ScrollIndicatorVisibility) = (.automatic, .automatic)
    /// Where a drag started (offset at the start).
    var dragStart: CGPoint?
    weak var node: ViewNode?
    var deceleration: FrameDriver?
    var offsetAnimator: Animator<AnimatablePair<CGFloat, CGFloat>>?
    var indicatorOpacity: Animator<Double>?
    var observers: [ScrollGeometryObserverBox] = []
    var lastGeometry: ScrollGeometry?
    var targetBehavior: (any ScrollTargetBehavior)?
    var positionBinding: ScrollPositionBinding?
    var lastReportedPositionID: AnyHashable?
    var defaultAnchor: UnitPoint?
    var appliedDefaultAnchor = false
    /// Scroll views count as scrolling for this long after the last motion.
    static let indicatorHold: TimeInterval = 1.0

    /// Per-millisecond velocity ratio (06 §3).
    package static let decelerationRate: Double = 0.998
    /// Below this speed (points per second) a fling stops.
    package static let stopSpeed: Double = 10

    package init() {}

    package var maxOffset: CGPoint {
        CGPoint(x: axes.contains(.horizontal) ? max(0, contentSize.width - viewportSize.width) : 0,
                y: axes.contains(.vertical) ? max(0, contentSize.height - viewportSize.height) : 0)
    }

    package func clamped(_ p: CGPoint) -> CGPoint {
        let m = maxOffset
        return CGPoint(x: min(max(p.x, 0), m.x), y: min(max(p.y, 0), m.y))
    }

    package var geometry: ScrollGeometry {
        ScrollGeometry(contentOffset: offset, contentSize: contentSize, contentInsets: insets, containerSize: viewportSize)
    }
}

/// An `onScrollGeometryChange` registration.
@MainActor
final class ScrollGeometryObserverBox {
    var report: (ScrollGeometry) -> Void = { _ in }
}

/// A `scrollPosition(id:)` binding.
@MainActor
struct ScrollPositionBinding {
    let read: () -> AnyHashable?
    let write: (AnyHashable?) -> Void
    let anchor: UnitPoint?
}

@MainActor
extension ScrollViewState: ScrollViewportProviding {
    package var visibleWindowRect: CGRect? {
        guard let f = windowFrame else { return nil }
        return CGRect(x: f.minX - insets.leading, y: f.minY - insets.top,
                      width: f.width + insets.horizontal, height: f.height + insets.vertical)
    }

    package var scrollAxes: Axis.Set { axes }

    package func reveal(_ rect: CGRect, anchor: UnitPoint?, transaction: Transaction) {
        guard let f = windowFrame else { return }
        // `rect` in content coordinates.
        let r = CGRect(x: rect.minX - f.minX + offset.x, y: rect.minY - f.minY + offset.y, width: rect.width, height: rect.height)
        var target = offset
        for axis in [Axis.horizontal, .vertical] where axes.contains(axis == .horizontal ? .horizontal : .vertical) {
            let lo = axis == .horizontal ? r.minX : r.minY
            let len = axis == .horizontal ? r.width : r.height
            let view = axis == .horizontal ? viewportSize.width : viewportSize.height
            let cur = axis == .horizontal ? offset.x : offset.y
            var t: CGFloat
            if let anchor {
                let u = axis == .horizontal ? anchor.x : anchor.y
                t = lo + len * u - view * u
            } else if lo < cur {
                t = lo
            } else if lo + len > cur + view {
                t = lo + len - view
            } else {
                t = cur
            }
            if axis == .horizontal { target.x = t } else { target.y = t }
        }
        setOffset(target, animation: transaction.animation)
    }

    /// Moves the content (animated with `animation`, else at once).
    package func setOffset(_ p: CGPoint, animation: Animation? = nil, stopMotion: Bool = true) {
        if stopMotion { stopDeceleration() }
        let target = clamped(p)
        guard let node, node.isAlive else {
            offset = target
            return
        }
        if let animation {
            let a = offsetAnimator ?? Animator(AnimatablePair(offset.x, offset.y), owner: node)
            offsetAnimator = a
            a.onChange = { [weak self, weak a] in
                guard let self, let a else { return }
                self.offset = self.clamped(CGPoint(x: a.presented.first, y: a.presented.second))
                self.moved()
            }
            a.update(to: AnimatablePair(offset.x, offset.y), animation: nil, graph: node.graph)
            a.update(to: AnimatablePair(target.x, target.y), animation: animation, graph: node.graph)
            return
        }
        offsetAnimator?.stop()
        guard target != offset else { return }
        offset = target
        moved()
    }

    /// The offset changed: lay out again, show the indicators.
    func moved() {
        guard let node, node.isAlive else { return }
        node.graph.scheduleUpdate(transaction: Transaction())
        flashIndicators()
    }

    func flashIndicators() {
        guard let node, node.isAlive else { return }
        let a = indicatorOpacity ?? Animator(0, owner: node)
        indicatorOpacity = a
        a.update(to: 1, animation: nil, graph: node.graph)
        if let services = node.environment._windowServices {
            let now = node.graph.timeSource.now
            services.setTimer(self, at: now + Self.indicatorHold) { [weak self, weak node] _ in
                guard let self, let node, node.isAlive, let a = self.indicatorOpacity else { return }
                a.onChange = { [weak node] in node?.graph.scheduleUpdate(transaction: Transaction()) }
                a.update(to: 0, animation: .easeOut(duration: 0.25), graph: node.graph)
                node.graph.scheduleUpdate(transaction: Transaction())
            }
        }
    }

    func stopDeceleration() {
        deceleration?.cancel()
        deceleration = nil
    }

    /// A fling at `velocity` (points per second, offset direction).
    func decelerate(from velocity: CGSize) {
        guard let node, node.isAlive else { return }
        var v = velocity
        if !axes.contains(.horizontal) { v.width = 0 }
        if !axes.contains(.vertical) { v.height = 0 }
        let speed = hypot(v.width, v.height)
        if let behavior = targetBehavior {
            // Where the fling would end, adjusted by the target behaviour.
            let k = 1 / (-log(Self.decelerationRate) * 1000)
            let natural = clamped(CGPoint(x: offset.x + v.width * k, y: offset.y + v.height * k))
            var target = ScrollTarget(rect: CGRect(origin: natural, size: viewportSize))
            let ctx = ScrollTargetBehaviorContext(originalTarget: target, velocity: CGVector(dx: v.width, dy: v.height),
                                                  contentSize: contentSize, containerSize: viewportSize, axes: axes,
                                                  state: self)
            behavior.updateTarget(&target, context: ctx)
            setOffset(target.rect.origin, animation: .spring(duration: 0.4, bounce: 0))
            return
        }
        guard speed > Self.stopSpeed else { return }
        let start = offset, begin = node.graph.timeSource.now
        let lnr = log(Self.decelerationRate)
        let driver = FrameDriver(owner: node) { [weak self] t in
            guard let self else { return (false, false) }
            let ms = max(0, (t - begin) * 1000)
            let decay = pow(Self.decelerationRate, ms)
            // Distance travelled: ∫ v·r^t dt = v (1 − r^t) / (−ln r).
            let f = CGFloat((1 - decay) / (-lnr) / 1000)
            let p = self.clamped(CGPoint(x: start.x + v.width * f, y: start.y + v.height * f))
            let changed = p != self.offset
            self.offset = p
            if changed { self.flashIndicators() }
            let atEdge = (v.width != 0 && (p.x <= 0 || p.x >= self.maxOffset.x) && v.height == 0)
                || (v.height != 0 && (p.y <= 0 || p.y >= self.maxOffset.y) && v.width == 0)
            let active = speed * decay > Self.stopSpeed && !atEdge
            return (changed, active)
        }
        driver.onChange = { [weak node] in node?.graph.scheduleUpdate(transaction: Transaction()) }
        deceleration = driver
        node.graph.activate(driver)
    }
}

@MainActor
extension ScrollViewState: ScrollWheelHandling {
    package func scrollWheel(delta: CGSize, location: CGPoint, frame: CGRect) -> Bool {
        guard isEnabled else { return false }
        var dx = delta.width, dy = delta.height
        if axes == .vertical && dy == 0 { dy = -dx; dx = 0 }
        if axes == .horizontal && dx == 0 { dx = -dy; dy = 0 }
        // OVPlatform: positive y scrolls up (content moves down), positive x
        // scrolls right.
        let target = clamped(CGPoint(x: offset.x + (axes.contains(.horizontal) ? dx : 0),
                                     y: offset.y - (axes.contains(.vertical) ? dy : 0)))
        guard target != offset else { return false }
        setOffset(target)
        return true
    }
}

@MainActor
extension ScrollViewState: GeometryObserving {
    package func geometryChanged(_ g: NodeGeometry, node: ViewNode) {
        windowFrame = g.frame
        var ins = EdgeInsets()
        if axes.contains(.vertical) {
            ins.top = g.safeAreaInsets.top
            ins.bottom = g.safeAreaInsets.bottom
        }
        if axes.contains(.horizontal) {
            ins.leading = g.safeAreaInsets.leading
            ins.trailing = g.safeAreaInsets.trailing
        }
        insets = ins
        if !appliedDefaultAnchor, let a = defaultAnchor, contentSize != .zero {
            appliedDefaultAnchor = true
            let m = maxOffset
            offset = CGPoint(x: m.x * a.x, y: m.y * a.y)
            node.graph.scheduleUpdate(transaction: Transaction())
        }
        let c = clamped(offset)
        if c != offset {
            offset = c
            node.graph.scheduleUpdate(transaction: Transaction())
        }
        let geo = geometry
        if geo != lastGeometry {
            lastGeometry = geo
            let obs = observers
            node.graph.queueGeometryAction { for o in obs { o.report(geo) } }
        }
        if let pos = positionBinding { syncPosition(pos, node: node) }
    }

    /// `scrollPosition(id:)`: an outside change scrolls to the ID; scrolling
    /// writes the first visible ID.
    private func syncPosition(_ pos: ScrollPositionBinding, node: ViewNode) {
        let wanted = pos.read()
        if let wanted, wanted != lastReportedPositionID {
            lastReportedPositionID = wanted
            if let r = locate(wanted, in: node) {
                reveal(r, anchor: pos.anchor ?? .top, transaction: Transaction())
            }
            return
        }
        guard let first = firstVisibleID(in: node), first != lastReportedPositionID else { return }
        lastReportedPositionID = first
        node.graph.queueGeometryAction { pos.write(first) }
    }

    /// The ID of the first item at least half visible (lazy containers).
    private func firstVisibleID(in node: ViewNode) -> AnyHashable? {
        guard let v = visibleWindowRect else { return nil }
        var out: AnyHashable?
        func walk(_ n: ViewNode) {
            guard out == nil else { return }
            if let lazy = n.primitiveState as? LazyContainerState, let wf = lazy.windowFrame {
                for i in lazy.itemRange(lazy.materialised) {
                    guard let id = lazy.items.item(at: i).id, let f = lazy.frame(ofItem: i) else { continue }
                    let top = (axes.contains(.vertical) ? wf.minY + f.minY : wf.minX + f.minX)
                    let len = axes.contains(.vertical) ? f.height : f.width
                    let lo = axes.contains(.vertical) ? v.minY : v.minX
                    if top + len / 2 >= lo { out = id; return }
                }
            }
            for c in n.children { walk(c) }
        }
        walk(node)
        return out
    }
}

/// The window frame of the view with `id` below `root`: a materialised view
/// whose key is the ID (`.id(_:)`, a `ForEach` element), else an item of a
/// lazy container (materialised or not; its estimated frame).
@MainActor
func locate(_ id: AnyHashable, in root: ViewNode) -> CGRect? {
    var found: CGRect?
    func walk(_ n: ViewNode) {
        guard found == nil, !n.isSuspended else { return }
        if let lazy = n.primitiveState as? LazyContainerState, let wf = lazy.windowFrame, let i = lazy.index(ofID: id),
           let f = lazy.frame(ofItem: i) {
            found = CGRect(x: wf.minX + f.minX, y: wf.minY + f.minY, width: max(f.width, wf.width), height: max(f.height, 0))
            if lazy.axis == .horizontal { found = CGRect(x: wf.minX + f.minX, y: wf.minY, width: f.width, height: wf.height) }
            return
        }
        for (k, c) in zip(n.childKeys, n.children) {
            if k == id, n.view is any ImplicitTagSource || String(describing: type(of: n.view)).hasPrefix("IDView"),
               let f = HitTesting.frame(of: c, mirrorWidth: nil) {
                found = f
                return
            }
        }
        for c in n.children { walk(c) }
    }
    walk(root)
    return found
}

// MARK: - ScrollView

/// A scrollable view of its content (06 §3).
public struct ScrollView<Content: View>: View {
    public var content: Content
    public var axes: Axis.Set
    public var showsIndicators: Bool

    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public typealias Body = Never
}

extension ScrollView: ClipsHitTesting {}

extension ScrollView: PrimitiveView {
    private func state(_ node: ViewNode) -> ScrollViewState {
        if let s = node.primitiveState as? ScrollViewState { return s }
        let s = ScrollViewState()
        node.primitiveState = s
        return s
    }

    private func dragGesture(_ s: ScrollViewState) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                guard s.isEnabled else { return }
                if s.dragStart == nil {
                    s.stopDeceleration()
                    s.dragStart = s.offset
                }
                guard let start = s.dragStart else { return }
                let p = CGPoint(x: start.x - (s.axes.contains(.horizontal) ? v.translation.width : 0),
                                y: start.y - (s.axes.contains(.vertical) ? v.translation.height : 0))
                s.setOffset(p, stopMotion: false)
            }
            .onEnded { v in
                guard s.dragStart != nil else { return }
                s.dragStart = nil
                s.decelerate(from: CGSize(width: -v.velocity.width, height: -v.velocity.height))
            }
    }

    package func _makeChildren(node: ViewNode, old: ScrollView?, transaction: Transaction) {
        let s = state(node)
        s.node = node
        s.axes = axes
        let env = node.environment
        s.isEnabled = env.isScrollEnabled
        s.indicators = showsIndicators ? (env.verticalScrollIndicatorVisibility, env.horizontalScrollIndicatorVisibility)
                                       : (.hidden, .hidden)
        s.observers = env._scrollGeometryObservers
        s.targetBehavior = env._scrollTargetBehavior
        s.positionBinding = env._scrollPositionBinding
        s.defaultAnchor = env._defaultScrollAnchor
        let catcher = Rectangle().fill(Color.clear).contentShape(Rectangle()).gesture(dragGesture(s))
        let body = content.gesture(dragGesture(s))
            .transformEnvironment(\.self) { e in
                e._scrollGeometryObservers = []
                e._scrollTargetBehavior = nil
                e._scrollPositionBinding = nil
                e._defaultScrollAnchor = nil
            }
        node.reconcileChildren([(AnyHashable(0), catcher), (AnyHashable(1), body)], transaction: transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if environmentChanged { _makeChildren(node: node, old: self, transaction: transaction) } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let s = state(node)
        guard node.children.count == 2 else { return node.lowerChildren() }
        let catcher = node.children[0].lower()
        let content = node.children[1].lower()
        let body: LayoutNode = content.count == 1 ? content[0] : (content.isEmpty ? .empty() : .vstack(content))
        let inner = LayoutNode(ScrollOffsetBehavior(axes: axes, offset: s.offset, state: s), children: [body])
        let viewport = LayoutNode(ScrollViewportBehavior(axes: axes), children: catcher + [inner])
        viewport.owner = node
        viewport.renderEffects.append(.clip({ size in
            let i = s.insets
            return Path(CGRect(x: -i.leading, y: -i.top, width: size.width + i.horizontal, height: size.height + i.vertical))
        }, eoFill: false))
        let env = node.environment
        let palette = ControlPalette(env.colorScheme)
        let bar = LayoutNode.color()
        bar.draw = { rec, size in
            MainActor.assumeIsolated { drawIndicators(&rec, size: size, state: s, color: palette.indicator, environment: env) }
        }
        // The indicator layer has no view node, so it takes no hits.
        return [viewport.overlay(bar, alignment: .center)]
    }
}

@MainActor
private func drawIndicators(_ rec: inout DrawRecorder, size: CGSize, state s: ScrollViewState, color: Color,
                            environment: EnvironmentValues) {
    let opacity: Double
    let vis = s.indicators
    let always = vis.vertical == .visible || vis.horizontal == .visible
    if always { opacity = 1 } else { opacity = s.indicatorOpacity?.presented ?? 0 }
    guard opacity > 0.001 else { return }
    let thickness: CGFloat = 3, inset: CGFloat = 3, minLength: CGFloat = 36
    let vb = s.insets.bottom, vt = s.insets.top
    var bars: [CGRect] = []
    if s.axes.contains(.vertical), vis.vertical != .hidden, vis.vertical != .never, s.contentSize.height > s.viewportSize.height + 0.5 {
        let track = size.height - 2 * inset - vt - vb
        let len = max(minLength, track * size.height / max(s.contentSize.height, 1))
        let frac = s.maxOffset.y > 0 ? s.offset.y / s.maxOffset.y : 0
        let y = vt + inset + (track - len) * frac
        bars.append(CGRect(x: size.width - inset - thickness, y: y, width: thickness, height: len))
    }
    if s.axes.contains(.horizontal), vis.horizontal != .hidden, vis.horizontal != .never, s.contentSize.width > s.viewportSize.width + 0.5 {
        let track = size.width - 2 * inset
        let len = max(minLength, track * size.width / max(s.contentSize.width, 1))
        let frac = s.maxOffset.x > 0 ? s.offset.x / s.maxOffset.x : 0
        let x = inset + (track - len) * frac
        bars.append(CGRect(x: x, y: size.height - inset - thickness - vb, width: len, height: thickness))
    }
    let c = color.opacity(opacity).resolve(in: environment).renderColor
    for b in bars { rec.add(.fill(Capsule().path(in: b).renderPath, .color(c), .nonZero)) }
}

/// Sizes the scroll view from the proposal and the content (golden rows) and
/// places the press catcher and the scrolled content in its bounds.
struct ScrollViewportBehavior: NodeBehavior {
    let axes: Axis.Set

    private func contentProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: axes.contains(.horizontal) ? nil : p.width,
                         height: axes.contains(.vertical) ? nil : p.height)
    }

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        guard let inner = node.children.last, let content = inner.children.first else { return .zero }
        let cs = content.sizeThatFits(contentProposal(p))
        let w = axes.contains(.horizontal) ? (p.width ?? cs.width) : cs.width
        let h = axes.contains(.vertical) ? (p.height ?? cs.height) : cs.height
        return CGSize(width: w, height: h)
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        node.children.indices.map { ChildPlacement(index: $0, origin: .zero, size: size, proposal: ProposedViewSize(size)) }
    }
}

/// Places the content at the top-leading corner (centred across a single
/// axis when narrower) and moves it by the offset.
struct ScrollOffsetBehavior: NodeBehavior {
    let axes: Axis.Set
    let offset: CGPoint
    let state: ScrollViewState

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        CGSize(width: p.width ?? 0, height: p.height ?? 0)
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        guard let content = node.children.first else { return [] }
        let p = ProposedViewSize(width: axes.contains(.horizontal) ? nil : size.width,
                                 height: axes.contains(.vertical) ? nil : size.height)
        let cs = content.sizeThatFits(p)
        state.contentSize = cs
        state.viewportSize = size
        var o = CGPoint.zero
        if !axes.contains(.horizontal) { o.x = (size.width - cs.width) / 2 }
        if !axes.contains(.vertical) { o.y = (size.height - cs.height) / 2 }
        return [ChildPlacement(index: 0, origin: o, size: cs, proposal: p)]
    }

    func childTransform(size: CGSize) -> AffineTransform2D? {
        let c = state.clampedForLayout(offset, viewport: size)
        return .translation(-c.x, -c.y)
    }
}

extension ScrollViewState {
    /// The offset clamped to the sizes of the current layout.
    func clampedForLayout(_ p: CGPoint, viewport: CGSize) -> CGPoint {
        let mx = axes.contains(.horizontal) ? max(0, contentSize.width - viewport.width) : 0
        let my = axes.contains(.vertical) ? max(0, contentSize.height - viewport.height) : 0
        return CGPoint(x: min(max(p.x, 0), mx), y: min(max(p.y, 0), my))
    }
}

// MARK: - Environment

private enum ScrollGeometryObserversKey: EnvironmentKey {
    static var defaultValue: [ScrollGeometryObserverBox] { [] }
}

private enum ScrollTargetBehaviorKey: EnvironmentKey {
    static var defaultValue: (any ScrollTargetBehavior)? { nil }
}

private enum ScrollPositionKey: EnvironmentKey {
    static var defaultValue: ScrollPositionBinding? { nil }
}

private enum DefaultScrollAnchorKey: EnvironmentKey {
    static var defaultValue: UnitPoint? { nil }
}

extension EnvironmentValues {
    var _scrollGeometryObservers: [ScrollGeometryObserverBox] {
        get { self[ScrollGeometryObserversKey.self] }
        set { self[ScrollGeometryObserversKey.self] = newValue }
    }

    var _scrollTargetBehavior: (any ScrollTargetBehavior)? {
        get { self[ScrollTargetBehaviorKey.self] }
        set { self[ScrollTargetBehaviorKey.self] = newValue }
    }

    var _scrollPositionBinding: ScrollPositionBinding? {
        get { self[ScrollPositionKey.self] }
        set { self[ScrollPositionKey.self] = newValue }
    }

    var _defaultScrollAnchor: UnitPoint? {
        get { self[DefaultScrollAnchorKey.self] }
        set { self[DefaultScrollAnchorKey.self] = newValue }
    }
}

// MARK: - Modifiers

private struct ScrollGeometryChangeModifier<T: Equatable>: ViewModifier {
    let transform: (ScrollGeometry) -> T
    let action: (T, T) -> Void
    @State private var box = ScrollGeometryObserverBox()
    @State private var last = LastValueBox<T>()

    func body(content: Content) -> some View {
        let transform = transform, action = action, last = last
        box.report = { g in
            let v = transform(g)
            if let old = last.value {
                if old != v {
                    last.value = v
                    action(old, v)
                }
            } else {
                last.value = v
                action(v, v)
            }
        }
        let box = box
        return content.transformEnvironment(\._scrollGeometryObservers) { $0.append(box) }
    }
}

@MainActor
private final class LastValueBox<T> {
    var value: T?
}

extension View {
    /// Runs `action` when the value `transform` computes from the scroll
    /// geometry of the scroll view inside changes (first value too; once per
    /// frame while scrolling, 06 §3).
    public func onScrollGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (ScrollGeometry) -> T,
                                                     action: @escaping (T, T) -> Void) -> some View {
        modifier(ScrollGeometryChangeModifier(transform: transform, action: action))
    }

    /// Keeps `id` bound to the first visible item of the scroll view's lazy
    /// content; setting it scrolls that item to `anchor` (default top).
    public func scrollPosition<ID: Hashable>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View {
        let pos = ScrollPositionBinding(read: { id.wrappedValue.map(AnyHashable.init) },
                                        write: { v in
                                            let nv = v?.base as? ID
                                            if id.wrappedValue != nv { id.wrappedValue = nv }
                                        }, anchor: anchor)
        return environment(\._scrollPositionBinding, pos)
    }

    /// How the scroll view inside chooses where a fling comes to rest.
    public func scrollTargetBehavior<B: ScrollTargetBehavior>(_ behavior: B) -> some View {
        environment(\._scrollTargetBehavior, behavior)
    }

    /// Marks the layout whose subviews are scroll targets (accepted; view
    /// alignment uses the lazy container's items or the content's subviews).
    public func scrollTargetLayout(isEnabled: Bool = true) -> some View { self }

    /// Where the scroll view inside starts (e.g. `.bottom` for logs).
    public func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        environment(\._defaultScrollAnchor, anchor)
    }

    /// Accepted: the content is always clipped.
    public func scrollClipDisabled(_ disabled: Bool = true) -> some View { self }

    /// Accepted (scroll views do not bounce on this host).
    public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = [.vertical]) -> some View { self }
}

public struct ScrollBounceBehavior: Sendable, Equatable {
    let kind: Int
    public static let automatic = ScrollBounceBehavior(kind: 0)
    public static let always = ScrollBounceBehavior(kind: 1)
    public static let basedOnSize = ScrollBounceBehavior(kind: 2)
}

// MARK: - Scroll target behaviours

/// Decides where a fling comes to rest.
@MainActor @preconcurrency
public protocol ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext)
    typealias TargetContext = ScrollTargetBehaviorContext
}

/// What a scroll target behaviour knows about the fling.
@MainActor
public struct ScrollTargetBehaviorContext {
    public var originalTarget: ScrollTarget
    public var velocity: CGVector
    public var contentSize: CGSize
    public var containerSize: CGSize
    public var axes: Axis.Set
    let state: ScrollViewState
}

/// Pages of the scroll view's size.
public struct PagingScrollTargetBehavior: ScrollTargetBehavior {
    public init() {}
    public func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let s = context.state
        var o = s.offset
        for axis in [Axis.horizontal, .vertical] where context.axes.contains(axis == .horizontal ? .horizontal : .vertical) {
            let page = axis == .horizontal ? context.containerSize.width : context.containerSize.height
            guard page > 0 else { continue }
            let cur = axis == .horizontal ? s.offset.x : s.offset.y
            let v = axis == .horizontal ? context.velocity.dx : context.velocity.dy
            var index = (cur / page).rounded()
            if v > 50 { index = (cur / page).rounded(.down) + 1 } else if v < -50 { index = (cur / page).rounded(.up) - 1 }
            if axis == .horizontal { o.x = index * page } else { o.y = index * page }
        }
        target.rect.origin = s.clamped(o)
    }
}

/// Rests with a subview (a lazy container's item) at the leading edge.
public struct ViewAlignedScrollTargetBehavior: ScrollTargetBehavior {
    public struct LimitBehavior: Sendable, Equatable {
        let kind: Int
        public static let automatic = LimitBehavior(kind: 0)
        public static let always = LimitBehavior(kind: 1)
        public static let alwaysByFew = LimitBehavior(kind: 2)
        public static let alwaysByOne = LimitBehavior(kind: 3)
        public static let never = LimitBehavior(kind: 4)
    }

    public init(limitBehavior: LimitBehavior = .automatic) {}

    public func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let s = context.state
        guard let node = s.node else { return }
        let vertical = context.axes.contains(.vertical)
        let natural = vertical ? target.rect.minY : target.rect.minX
        var starts: [CGFloat] = []
        func walk(_ n: ViewNode) {
            if let lazy = n.primitiveState as? LazyContainerState, let wf = lazy.windowFrame, let f = s.windowFrame {
                let base = vertical ? wf.minY - f.minY + s.offset.y : wf.minX - f.minX + s.offset.x
                starts += lazy.starts.dropLast().map { base + $0 }
                return
            }
            for c in n.children { walk(c) }
        }
        walk(node)
        guard let best = starts.min(by: { abs($0 - natural) < abs($1 - natural) }) else { return }
        if vertical { target.rect.origin.y = best } else { target.rect.origin.x = best }
        target.rect.origin = s.clamped(target.rect.origin)
    }
}

extension ScrollTargetBehavior where Self == PagingScrollTargetBehavior {
    public static var paging: PagingScrollTargetBehavior { PagingScrollTargetBehavior() }
}

extension ScrollTargetBehavior where Self == ViewAlignedScrollTargetBehavior {
    public static var viewAligned: ViewAlignedScrollTargetBehavior { ViewAlignedScrollTargetBehavior() }
    public static func viewAligned(limitBehavior: ViewAlignedScrollTargetBehavior.LimitBehavior) -> ViewAlignedScrollTargetBehavior {
        ViewAlignedScrollTargetBehavior(limitBehavior: limitBehavior)
    }
}

// MARK: - ScrollViewReader

/// Scrolls the scroll views inside a `ScrollViewReader`.
@MainActor
public struct ScrollViewProxy {
    let ref: ReaderRef

    /// Scrolls the first scroll view below the reader that contains the view
    /// with `id` (06 §3: `scrollTo(500, anchor: .top)` jumps without
    /// animation; inside `withAnimation` it animates).
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {
        guard let root = ref.node, root.isAlive else { return }
        if root.graph.needsUpdate { root.graph.update() }
        let key = AnyHashable(id)
        let tx = Transaction._current
        func walk(_ n: ViewNode) -> Bool {
            if let s = n.primitiveState as? ScrollViewState {
                if let r = locate(key, in: n) {
                    s.reveal(r, anchor: anchor, transaction: tx)
                    return true
                }
            }
            for c in n.children where walk(c) { return true }
            return false
        }
        _ = walk(root)
    }
}

final class ReaderRef {
    weak var node: ViewNode?
}

/// Gives its content a proxy that scrolls the scroll views inside it.
public struct ScrollViewReader<Content: View>: View {
    public var content: (ScrollViewProxy) -> Content

    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) { self.content = content }

    public typealias Body = Never
}

extension ScrollViewReader: PrimitiveView {
    private func build(_ node: ViewNode, _ transaction: Transaction) {
        let ref = (node.primitiveState as? ReaderRef) ?? ReaderRef()
        ref.node = node
        node.primitiveState = ref
        let child = node.trackContent { content(ScrollViewProxy(ref: ref)) }
        node.reconcileChildren([(AnyHashable(0), child)], transaction: transaction)
    }

    package func _makeChildren(node: ViewNode, old: ScrollViewReader?, transaction: Transaction) { build(node, transaction) }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { build(node, transaction) } else { node.refreshChildren(transaction: transaction) }
    }
}
