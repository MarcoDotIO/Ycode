import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Presentations (round R9; 06 §6, suite T-MODAL).
//
// Measured (06 §6): a sheet's `onAppear` runs when the presentation starts;
// setting `isPresented = false` slides it out and runs `onDismiss`, then
// `onDisappear`, at the end (0.53 s later); a sheet with detents [.medium,
// .large] floats 8 points in from the window's edges at (8, 280, 374, 356)
// and (8, 8, 374, 636) in the reference's window (466 × 678, safe area 382 ×
// 644); setting the detent binding resizes it with an animation; a
// full-screen cover fills the window with the content in its safe area and
// has the sheet's dismissal order; a popover is sized to its content.
//
// Design (Ycode's): sheets, covers, alerts and dialogs are layers of their
// window (a presentation layer above the window's content and below its
// pop-up overlays) with a dimming layer that takes every press, so the
// content below is modal; Tab stays inside the innermost presentation.
// Popovers are R8's pop-up windows. Presenting animates for 0.35 s,
// dismissing for 0.5 s (ease-in-out), both by sliding from the bottom edge
// (alerts and desktop dialogs fade and scale instead).
//
// Geometry: on the headless host (the reference phone) sheets follow the
// detents: `.large` is (8, 8, W − 8, H − 8) in the safe area W × H; a sheet
// of any other detent ends 8 points above the safe area's bottom, `.medium`
// being half the window's height plus 17 points (356 at 678, the measured
// value), `.fraction(f)` f × the large height, `.height(h)` h. On desktop
// hosts a sheet is a card centred in the window at its content's ideal
// size, at least 360 × 200 and at most the window less 40 points. Alerts are
// 270 points wide (300 on desktop) and centred; dialogs are action sheets at
// the bottom on the phone host and centred cards on desktop hosts.

// MARK: - Detents

/// A height a sheet can rest at.
public struct PresentationDetent: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case medium, large
        case fraction(CGFloat)
        case height(CGFloat)
    }
    let kind: Kind
    public static let medium = PresentationDetent(kind: .medium)
    public static let large = PresentationDetent(kind: .large)
    public static func fraction(_ f: CGFloat) -> PresentationDetent { PresentationDetent(kind: .fraction(f)) }
    public static func height(_ h: CGFloat) -> PresentationDetent { PresentationDetent(kind: .height(h)) }
}

/// The options a presentation's content registers.
@MainActor
final class SheetOptions {
    var detents: [PresentationDetent] = [.large]
    var selection: Binding<PresentationDetent>?
    var dragIndicator = Visibility.automatic
    weak var owner: ViewNode?

    var current: PresentationDetent {
        if let s = selection?.wrappedValue, detents.contains(s) { return s }
        return detents.contains(.large) ? .large : (detents.last ?? .large)
    }
}

private enum SheetOptionsKey: EnvironmentKey { static let defaultValue: SheetOptions? = nil }

extension EnvironmentValues {
    var _sheetOptions: SheetOptions? {
        get { self[SheetOptionsKey.self] }
        set { self[SheetOptionsKey.self] = newValue }
    }
}

struct SheetOptionsModifier: PrimitiveModifier {
    let apply: @MainActor (SheetOptions) -> Void

    private func sync(_ node: ViewNode) {
        guard let o = node.environment._sheetOptions else { return }
        let before = (o.detents, o.selection != nil, o.dragIndicator)
        apply(o)
        if before != (o.detents, o.selection != nil, o.dragIndicator) { o.owner?.invalidate(transaction: Transaction()) }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: SheetOptionsModifier, node: ViewNode) { sync(node) }
}

extension View {
    public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View {
        let list = Array(detents)
        return modifier(SheetOptionsModifier { o in o.detents = list.isEmpty ? [.large] : list })
    }

    public func presentationDetents(_ detents: Set<PresentationDetent>, selection: Binding<PresentationDetent>) -> some View {
        let list = Array(detents)
        return modifier(SheetOptionsModifier { o in
            o.detents = list.isEmpty ? [.large] : list
            o.selection = selection
        })
    }

    public func presentationDragIndicator(_ visibility: Visibility) -> some View {
        modifier(SheetOptionsModifier { o in o.dragIndicator = visibility })
    }

    public func interactiveDismissDisabled(_ isDisabled: Bool = true) -> some View { self }
    public func presentationCornerRadius(_ radius: CGFloat?) -> some View { self }
    public func presentationBackground<S: ShapeStyle>(_ style: S) -> some View { self }
    public func presentationCompactAdaptation(_ adaptation: PresentationAdaptation) -> some View { self }
    public func presentationBackgroundInteraction(_ interaction: PresentationBackgroundInteraction) -> some View { self }
}

public struct PresentationAdaptation: Sendable, Equatable {
    let kind: Int
    public static let automatic = PresentationAdaptation(kind: 0)
    public static let none = PresentationAdaptation(kind: 1)
    public static let popover = PresentationAdaptation(kind: 2)
    public static let sheet = PresentationAdaptation(kind: 3)
    public static let fullScreenCover = PresentationAdaptation(kind: 4)
}

public struct PresentationBackgroundInteraction: Sendable, Equatable {
    let kind: Int
    public static let automatic = PresentationBackgroundInteraction(kind: 0)
    public static let disabled = PresentationBackgroundInteraction(kind: 1)
    public static let enabled = PresentationBackgroundInteraction(kind: 2)
}

// MARK: - The window's presentations

/// One presentation of a window.
@MainActor
final class PresentationEntry {
    enum Kind { case sheet, cover, alert, dialog }
    let id: ObjectIdentifier
    let kind: Kind
    var content: AnyView
    var onDismiss: (() -> Void)?
    /// Writes the presenting binding (false when dismissed from inside).
    var setPresented: (Bool) -> Void
    let options = SheetOptions()
    /// The presenter's environment (the card's colours follow it).
    var environment = EnvironmentValues()
    var progress: Double = 0
    var isDismissing = false
    var driver: FrameDriver?

    init(id: ObjectIdentifier, kind: Kind, content: AnyView, onDismiss: (() -> Void)?, setPresented: @escaping (Bool) -> Void) {
        self.id = id
        self.kind = kind
        self.content = content
        self.onDismiss = onDismiss
        self.setPresented = setPresented
    }
}

/// The presentations of a window, innermost last.
@MainActor
package final class PresentationCenter {
    private(set) var entries: [PresentationEntry] = []
    var onChange: (() -> Void)?
    weak var layerNode: ViewNode?
    weak var graph: ViewGraph?

    static let presentDuration: TimeInterval = 0.35
    static let dismissDuration: TimeInterval = 0.5

    package init() {}

    package var isEmpty: Bool { entries.isEmpty }

    func entry(_ id: ObjectIdentifier) -> PresentationEntry? { entries.first { $0.id == id } }

    func present(_ e: PresentationEntry, animated: Bool) {
        entries.append(e)
        e.progress = animated ? 0 : 1
        onChange?()
        if animated { run(e, to: 1, duration: Self.presentDuration) }
    }

    func update(_ id: ObjectIdentifier, content: AnyView) {
        guard let e = entry(id) else { return }
        e.content = content
        onChange?()
    }

    /// Animates the presentation out; at the end `onDismiss` runs and the
    /// content is removed (its `onDisappear` follows; 06 §6).
    func dismiss(_ id: ObjectIdentifier, animated: Bool = true) {
        guard let e = entry(id), !e.isDismissing else { return }
        e.isDismissing = true
        if animated, graph != nil, layerNode != nil {
            run(e, to: 0, duration: Self.dismissDuration)
        } else {
            finish(e)
        }
    }

    private func finish(_ e: PresentationEntry) {
        e.driver?.cancel()
        let action = e.onDismiss
        e.onDismiss = nil
        action?()
        entries.removeAll { $0 === e }
        onChange?()
    }

    private func run(_ e: PresentationEntry, to target: Double, duration: TimeInterval) {
        guard let graph, let owner = layerNode else {
            e.progress = target
            if target == 0 { finish(e) }
            return
        }
        e.driver?.cancel()
        let from = e.progress, begin = graph.currentTime
        let driver = FrameDriver(owner: owner) { [weak self, weak e] t in
            guard let self, let e else { return (false, false) }
            let p = min(1, max(0, (t - begin) / duration))
            e.progress = from + (target - from) * UnitCurve.easeInOut.value(at: p)
            if p >= 1 {
                e.driver = nil
                if target == 0 { MainActor.assumeIsolated { self.finish(e) } }
            }
            return (true, p < 1)
        }
        driver.onChange = { [weak graph] in graph?.scheduleUpdate(transaction: Transaction()) }
        e.driver = driver
        graph.activate(driver)
        graph.scheduleUpdate(transaction: Transaction())
    }
}

/// The layer that shows a window's presentations.
struct PresentationLayer: View, PrimitiveView {
    let center: PresentationCenter
    let entries: [PresentationEntry]
    typealias Body = Never

    func _makeChildren(node: ViewNode, old: PresentationLayer?, transaction: Transaction) {
        center.layerNode = node
        center.graph = node.graph
        var items: [(AnyHashable, any View)] = []
        // The detent bindings are dependencies of the layer (06 §6: setting
        // the detent resizes the sheet).
        _ = node.trackContent { entries.map { $0.options.current } }
        for e in entries {
            e.options.owner = node
            let content = e.content
                .environment(\._sheetOptions, e.options)
            let env = e.environment
            let card = PresentationCard(entry: e, content: AnyView(content)).transformEnvironment(\.self) { x in
                let options = x._sheetOptions
                x = env
                x._sheetOptions = options
            }
            items.append((AnyHashable(e.id), card))
        }
        node.reconcileChildren(items, transaction: transaction)
        if let services = node.environment._windowServices {
            services.focus.modalScopes.removeAll { $0.node == nil || $0.node === node }
            if !entries.isEmpty { services.focus.modalScopes.append(WeakNode(node)) }
        }
    }

    func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { _makeChildren(node: node, old: self, transaction: transaction) } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    func _lower(node: ViewNode) -> [LayoutNode] {
        let env = node.environment
        var layers: [LayoutNode] = []
        for (e, c) in zip(entries, node.children) {
            let ns = c.lower()
            let card: LayoutNode = ns.count == 1 ? ns[0] : .zstack(ns)
            let dim = fillNode(ControlPalette(e.environment.colorScheme).dimming, environment: env)
            let w = LayoutNode(OpacityBehavior(e.kind == .cover ? 0 : e.progress), children: [dim])
            layers.append(w)
            layers.append(LayoutNode(PresentationPlacementBehavior(kind: e.kind, progress: e.progress, options: PlacementOptions(e.options),
                                                                   desktop: env._desktopChrome), children: [card]))
        }
        guard !layers.isEmpty else { return [LayoutNode.empty()] }
        return [LayoutNode.zstack(alignment: .topLeading, layers)]
    }
}

extension PresentationLayer: ClipsHitTesting {}

extension PresentationLayer: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

/// The detents a sheet uses, captured for layout.
struct PlacementOptions {
    let detent: PresentationDetent
    init(_ o: SheetOptions) { detent = MainActor.assumeIsolated { o.current } }
}

/// Places a presentation's card in the layer (header comment).
struct PresentationPlacementBehavior: NodeBehavior {
    let kind: PresentationEntry.Kind
    let progress: Double
    let options: PlacementOptions
    let desktop: Bool

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        CGSize(width: p.width ?? 0, height: p.height ?? 0)
    }

    private func frame(in size: CGSize, node: LayoutNode) -> CGRect {
        guard let card = node.children.first else { return .zero }
        let inset: CGFloat = 8
        switch kind {
        case .cover:
            return CGRect(origin: .zero, size: size)
        case .sheet where !desktop:
            let large = size.height - inset
            let windowHeight = node.context.safeArea?.window.height ?? size.height
            let h: CGFloat
            switch options.detent.kind {
            case .large: return CGRect(x: inset, y: inset, width: max(0, size.width - inset), height: max(0, large))
            case .medium: h = windowHeight / 2 + 17
            case .fraction(let f): h = large * f
            case .height(let v): h = v
            }
            let hh = min(h, large)
            return CGRect(x: inset, y: size.height - inset - hh, width: max(0, size.width - inset), height: hh)
        case .sheet:
            let ideal = card.sizeThatFits(.unspecified)
            let w = min(max(ideal.width.isFinite ? ideal.width : 480, 360), max(0, size.width - 40))
            let ih = card.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            let h = min(max(ih.isFinite ? ih : 320, 200), max(0, size.height - 40))
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        case .alert, .dialog:
            let phoneDialog = kind == .dialog && !desktop
            let w = phoneDialog ? max(0, size.width - 16) : (desktop ? 300 : 270)
            let h = min(card.sizeThatFits(ProposedViewSize(width: w, height: nil)).height, size.height - 40)
            if phoneDialog { return CGRect(x: 8, y: size.height - 8 - h, width: w, height: h) }
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        guard !node.children.isEmpty else { return [] }
        let f = frame(in: size, node: node)
        return [ChildPlacement(index: 0, origin: f.origin, size: f.size, proposal: ProposedViewSize(f.size))]
    }

    func childTransform(size: CGSize) -> AffineTransform2D? {
        let p = CGFloat(progress)
        switch kind {
        case .alert, .dialog where desktop:
            let s = 0.9 + 0.1 * p
            return AffineTransform2D.scale(s, s).about(CGPoint(x: size.width / 2, y: size.height / 2))
        case .dialog, .sheet, .cover:
            if kind == .sheet && desktop {
                let s = 0.94 + 0.06 * p
                return AffineTransform2D.scale(s, s).about(CGPoint(x: size.width / 2, y: size.height / 2))
            }
            return .translation(0, (1 - p) * size.height)
        }
    }
}

/// A presentation's card: its background, the content, the modal press
/// catcher behind it.
struct PresentationCard: View {
    let entry: PresentationEntry
    let content: AnyView
    @Environment(\.colorScheme) private var scheme
    @Environment(\._desktopChrome) private var desktop

    var body: some View {
        let palette = ControlPalette(scheme)
        let e = entry
        let radius: CGFloat = e.kind == .cover ? 0 : (e.kind == .alert ? 14 : 12)
        let fill: Color = e.kind == .alert || e.kind == .dialog ? palette.alertBackground : palette.sheetBackground
        content
            .frame(maxWidth: .infinity, maxHeight: e.kind == .sheet || e.kind == .cover ? .infinity : nil, alignment: .top)
            .background { RoundedRectangle(cornerRadius: radius).fill(fill).ignoresSafeArea() }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .opacity(e.kind == .alert || (e.kind == .dialog && desktop) || (e.kind == .sheet && desktop) ? e.progress : 1)
            .environment(\.dismiss, DismissAction { e.setPresented(false) })
            .environment(\.isPresented, true)
    }
}

// MARK: - Modifiers

/// Presents `content` in its window while `isPresented` is true. The
/// colour scheme is read here so that a change of it (or of the presenting
/// view) reaches the presentation, which takes the presenter's environment.
struct PresentationModifier: ViewModifier {
    let kind: PresentationEntry.Kind
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let content: () -> AnyView
    @Environment(\.colorScheme) private var scheme

    func body(content base: Content) -> some View {
        base.modifier(PresentationCore(kind: kind, isPresented: isPresented, onDismiss: onDismiss, content: content,
                                       scheme: scheme))
    }
}

struct PresentationCore: PrimitiveModifier {
    let kind: PresentationEntry.Kind
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let content: () -> AnyView
    let scheme: ColorScheme

    private final class Box { var center: PresentationCenter? }

    private func makeContent(_ node: ViewNode) -> AnyView {
        makeContent(node, into: nil)
    }

    private func makeContent(_ node: ViewNode, into entry: PresentationEntry?) -> AnyView {
        var lastEnvironment = EnvironmentValues()
        defer { entry?.environment = lastEnvironment }
        var env = node.environment
        env._navigationPage = nil
        env._navigation = nil
        env._collapsedSplit = nil
        env._collapsedColumnIndex = -1
        env._splitColumn = nil
        env._sheetOptions = nil
        let binding = isPresented
        env.dismiss = DismissAction { if binding.wrappedValue { binding.wrappedValue = false } }
        env.isPresented = true
        let env2 = env
        lastEnvironment = env
        return AnyView(content().transformEnvironment(\.self) { e in
            let options = e._sheetOptions
            e = env2
            e._sheetOptions = options
        })
    }

    private func sync(_ node: ViewNode) {
        let box = (node.primitiveState as? Box) ?? Box()
        node.primitiveState = box
        guard let center = node.environment._windowServices?.presentations else { return }
        box.center = center
        let id = ObjectIdentifier(box)
        // The binding is a dependency of this node (the presenting body need
        // not read it).
        let presented = node.trackContent { isPresented.wrappedValue }
        if let e = center.entry(id), !e.isDismissing {
            if presented {
                center.update(id, content: makeContent(node, into: e))
            } else {
                center.dismiss(id)
            }
        } else if presented, center.entry(id) == nil {
            let binding = isPresented
            let e = PresentationEntry(id: id, kind: kind, content: makeContent(node), onDismiss: onDismiss,
                                      setPresented: { v in if binding.wrappedValue != v { binding.wrappedValue = v } })
            _ = makeContent(node, into: e)
            center.present(e, animated: !node.graph.passTransaction.disablesAnimations)
        }
    }

    var _rebuildsWhenDirty: Bool { true }
    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: PresentationCore, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) {
        guard let box = node.primitiveState as? Box else { return }
        box.center?.dismiss(ObjectIdentifier(box), animated: false)
    }
}

extension PresentationCore: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

extension View {
    /// Presents a sheet while `isPresented` is true (06 §6).
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(PresentationModifier(kind: .sheet, isPresented: isPresented, onDismiss: onDismiss) { AnyView(content()) })
    }

    /// Presents a sheet for `item` while it is not nil.
    public func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                         @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(PresentationModifier(kind: .sheet, isPresented: presented, onDismiss: onDismiss) {
            item.wrappedValue.map { AnyView(content($0)) } ?? AnyView(EmptyView())
        })
    }

    /// Covers the window while `isPresented` is true.
    public func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(PresentationModifier(kind: .cover, isPresented: isPresented, onDismiss: onDismiss) { AnyView(content()) })
    }

    public func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                   @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(PresentationModifier(kind: .cover, isPresented: presented, onDismiss: onDismiss) {
            item.wrappedValue.map { AnyView(content($0)) } ?? AnyView(EmptyView())
        })
    }

    // MARK: Alerts

    public func alert<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                               @ViewBuilder actions: () -> A) -> some View {
        alert(Text(titleKey), isPresented: isPresented, actions: actions, message: { EmptyView() })
    }

    @_disfavoredOverload
    public func alert<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>,
                                                  @ViewBuilder actions: () -> A) -> some View {
        alert(Text(title), isPresented: isPresented, actions: actions, message: { EmptyView() })
    }

    public func alert<A: View, M: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View {
        alert(Text(titleKey), isPresented: isPresented, actions: actions, message: message)
    }

    @_disfavoredOverload
    public func alert<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>,
                                                           @ViewBuilder actions: () -> A,
                                                           @ViewBuilder message: () -> M) -> some View {
        alert(Text(title), isPresented: isPresented, actions: actions, message: message)
    }

    public func alert<A: View, M: View>(_ title: Text, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View {
        let a = AnyView(actions()), m = AnyView(message())
        let binding = isPresented
        return modifier(PresentationModifier(kind: .alert, isPresented: isPresented, onDismiss: nil) {
            AnyView(AlertCard(title: title, message: m, actions: a, dialog: false,
                              dismiss: { binding.wrappedValue = false }))
        })
    }

    public func alert<D, A: View, M: View>(_ title: Text, isPresented: Binding<Bool>, presenting data: D?,
                                           @ViewBuilder actions: (D) -> A, @ViewBuilder message: (D) -> M) -> some View {
        let a = data.map { AnyView(actions($0)) } ?? AnyView(EmptyView())
        let m = data.map { AnyView(message($0)) } ?? AnyView(EmptyView())
        let binding = isPresented
        return modifier(PresentationModifier(kind: .alert, isPresented: isPresented, onDismiss: nil) {
            AnyView(AlertCard(title: title, message: m, actions: a, dialog: false, dismiss: { binding.wrappedValue = false }))
        })
    }

    // MARK: Dialogs

    public func confirmationDialog<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>,
                                            titleVisibility: Visibility = .automatic,
                                            @ViewBuilder actions: () -> A) -> some View {
        confirmationDialog(Text(titleKey), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions,
                           message: { EmptyView() })
    }

    @_disfavoredOverload
    public func confirmationDialog<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>,
                                                               titleVisibility: Visibility = .automatic,
                                                               @ViewBuilder actions: () -> A) -> some View {
        confirmationDialog(Text(title), isPresented: isPresented, titleVisibility: titleVisibility, actions: actions,
                           message: { EmptyView() })
    }

    public func confirmationDialog<A: View, M: View>(_ title: Text, isPresented: Binding<Bool>,
                                                     titleVisibility: Visibility = .automatic,
                                                     @ViewBuilder actions: () -> A,
                                                     @ViewBuilder message: () -> M) -> some View {
        let a = AnyView(actions()), m = AnyView(message())
        let binding = isPresented
        let showTitle = titleVisibility == .visible
        return modifier(PresentationModifier(kind: .dialog, isPresented: isPresented, onDismiss: nil) {
            AnyView(AlertCard(title: showTitle ? title : nil, message: m, actions: a, dialog: true,
                              dismiss: { binding.wrappedValue = false }))
        })
    }

    // MARK: Popover and inspector

    /// Shows `content` in a pop-up window next to the view (R8 pop-ups).
    public func popover<Content: View>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                       arrowEdge: Edge? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(PopoverModifier(isPresented: isPresented, content: { AnyView(content()) }))
    }

    public func popover<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                           attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
                                                           arrowEdge: Edge? = nil,
                                                           @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(PopoverModifier(isPresented: presented, content: {
            item.wrappedValue.map { AnyView(content($0)) } ?? AnyView(EmptyView())
        }))
    }

    /// A trailing column beside the view while `isPresented` is true.
    public func inspector<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View {
        InspectorHost(base: self, isPresented: isPresented.wrappedValue, content: content())
    }

    public func inspectorColumnWidth(_ width: CGFloat) -> some View { self }
    public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View { self }
}

/// Where a popover attaches.
public enum PopoverAttachmentAnchor: Sendable {
    case rect(Anchor<CGRect>.Source)
    case point(UnitPoint)
}

/// An anchor's source (bounds only).
public struct Anchor<Value> {
    public struct Source: Sendable {
        public static var bounds: Source { Source() }
    }
}

struct InspectorHost<Base: View, Content: View>: View {
    let base: Base
    let isPresented: Bool
    let content: Content
    var body: some View {
        HStack(spacing: 0) {
            base.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                Divider()
                content.frame(width: 270).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// `popover`: a pop-up window below the view.
struct PopoverModifier: PrimitiveModifier {
    let isPresented: Binding<Bool>
    let content: () -> AnyView

    private final class Box {
        var handle: PopupHandle?
        let ref = NodeRef()
    }

    private func sync(_ node: ViewNode) {
        let box = (node.primitiveState as? Box) ?? Box()
        node.primitiveState = box
        box.ref.node = node
        let presented = node.trackContent { isPresented.wrappedValue }
        let open = box.handle.map { !$0.isDismissed } ?? false
        if presented && !open {
            guard let services = node.environment._windowServices, let popups = services.popups else { return }
            // Open after this update, when the view has a frame.
            let binding = isPresented, make = content
            node.graph.queuePreferenceAction { [weak node] in
                guard let node, node.isAlive, box.handle.map({ !$0.isDismissed }) != true,
                      let f = HitTesting.frame(of: node, mirrorWidth: nil) else { return }
                let chrome = AnyView(PopoverChrome(content: make()))
                box.handle = popups.presentPopup(content: chrome, origin: CGPoint(x: f.minX, y: f.maxY + 6), minWidth: 0,
                                                 chrome: .plain, onDismiss: {
                                                     if binding.wrappedValue { binding.wrappedValue = false }
                                                 })
            }
        } else if !presented && open {
            box.handle?.dismiss()
            box.handle = nil
        }
    }

    var _rebuildsWhenDirty: Bool { true }
    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: PopoverModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) { (node.primitiveState as? Box)?.handle?.dismiss() }
}

extension PopoverModifier: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

/// A popover's frame (Ycode): the sheet colour, a hairline, 12-point padding.
struct PopoverChrome: View {
    let content: AnyView
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = ControlPalette(scheme)
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.sheetBackground)
            .overlay { Rectangle().strokeBorder(palette.outline, lineWidth: 1).allowsHitTesting(false) }
    }
}

// MARK: - Alert and dialog cards

/// An alert or confirmation dialog: title, message, buttons (two side by
/// side, otherwise one per row; cancel last). Choosing a button runs its
/// action and dismisses.
struct AlertCard: View {
    let title: Text?
    let message: AnyView
    let actions: AnyView
    let dialog: Bool
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        var buttons = enumeratedViews(actions).map(\.1)
        if buttons.isEmpty { buttons = [Button("OK") {}] }
        let side = buttons.count == 2 && !dialog
        let dismiss = dismiss
        return VStack(spacing: 0) {
            VStack(spacing: 4) {
                if let title { title.font(.headline).multilineTextAlignment(.center) }
                message.font(.footnote).multilineTextAlignment(.center)
            }
            .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 16))
            .frame(maxWidth: .infinity)
            Rectangle().fill(palette.separator).frame(height: 1 / 3)
            if side {
                HStack(spacing: 0) {
                    AnyView(_fromValue: buttons[0])!.frame(maxWidth: .infinity)
                    Rectangle().fill(palette.separator).frame(width: 1 / 3)
                    AnyView(_fromValue: buttons[1])!.frame(maxWidth: .infinity)
                }
                .frame(height: 44)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { pair in
                        if pair.offset > 0 { Rectangle().fill(palette.separator).frame(height: 1 / 3) }
                        AnyView(_fromValue: pair.element)!.frame(maxWidth: .infinity).frame(height: 44)
                    }
                    if dialog {
                        Rectangle().fill(palette.separator).frame(height: 1 / 3)
                        Button("Cancel", role: .cancel) {}.frame(maxWidth: .infinity).frame(height: 44)
                    }
                }
            }
        }
        .buttonStyle(AlertButtonStyle(dismiss: dismiss))
    }
}

/// Alert buttons: the tinted label (red when destructive, semibold when
/// cancelling); choosing one dismisses the alert.
struct AlertButtonStyle: PrimitiveButtonStyle {
    let dismiss: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        let d = dismiss
        let c = PrimitiveButtonStyleConfiguration(role: configuration.role, label: configuration.label,
                                                  action: { configuration.trigger(); d() })
        return ButtonBehavior(configuration: c, ring: AnyShape(Rectangle())) { s in
            AlertButtonLook(configuration: s)
        }
    }
}

struct AlertButtonLook: View {
    let configuration: ButtonStyleConfiguration
    var body: some View {
        let role = configuration.role
        let base = configuration.label
            .font(role == .cancel ? .body.weight(.semibold) : .body)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
        if role == .destructive {
            base.foregroundStyle(Color.red)
        } else {
            base.foregroundStyle(.tint)
        }
    }
}
