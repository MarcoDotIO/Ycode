import Foundation

// Transitions (05-animation.md §5). A transition is a function of a phase:
// `willAppear` before an insertion, `identity` while the view is shown,
// `didDisappear` after a removal. When a view is inserted by a state change
// in an animated transaction, its transition's body is evaluated at
// `willAppear` and then at `identity` in that transaction, so the animatable
// values in the body (opacity, scale, offsets, custom animatable modifiers)
// animate. On removal the body moves to `didDisappear`, and the removed view
// stays rendered (outside layout) until those animations end; its
// `onDisappear` actions run then (05 §5). Without an animation insertion and
// removal are immediate. A view inserted or removed without a `.transition`
// fades (opacity, the default).
//
// The transition applies to the view at the root of the insertion: the
// inserted view and the chain of modifiers and wrappers below it
// (`ViewNode.passesInsertion`); `.transition` modifiers deeper inside the
// inserted content (in a stack, say) have no effect.

/// The phase of a transition.
public enum TransitionPhase: Hashable, Sendable {
    case willAppear
    case identity
    case didDisappear

    public var isIdentity: Bool { self == .identity }

    /// −1 before appearing, 0 at identity, 1 after disappearing.
    public var value: Double {
        switch self {
        case .willAppear: return -1
        case .identity: return 0
        case .didDisappear: return 1
        }
    }
}

/// Properties of a transition.
public struct TransitionProperties: Sendable {
    /// Whether the transition moves the view (reduce-motion settings may
    /// replace such transitions).
    public var hasMotion: Bool
    public init(hasMotion: Bool = true) { self.hasMotion = hasMotion }
}

/// Stands for the content a transition (or another content-taking API)
/// applies to.
public struct PlaceholderContentView<Value>: View {
    nonisolated(unsafe) package weak var source: ViewNode?
    package let view: AnyView?

    package init(source: ViewNode?) {
        self.source = source
        self.view = nil
    }

    package init<V: View>(wrapping content: V) {
        if let p = content as? any PlaceholderSourcing, let s = p._placeholderSource, p._placeholderView == nil {
            source = s
            view = nil
        } else {
            source = nil
            view = AnyView(content)
        }
    }

    public typealias Body = Never
}

@MainActor package protocol PlaceholderSourcing {
    var _placeholderSource: ViewNode? { get }
    var _placeholderView: AnyView? { get }
}

extension PlaceholderContentView: PlaceholderSourcing {
    package var _placeholderSource: ViewNode? { source }
    package var _placeholderView: AnyView? { view }
}

extension PlaceholderContentView: GraphInputComparable {
    package nonisolated func _isGraphInputEqual(to other: Any) -> Bool {
        guard let o = other as? PlaceholderContentView<Value> else { return false }
        return o.source === source && o.view == nil && view == nil
    }
}

extension PlaceholderContentView: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: PlaceholderContentView?, transaction: Transaction) {
        if let view {
            node.reconcileChildren([(AnyHashable(0), view)], transaction: transaction)
            return
        }
        guard let source, let content = source.modifierContent else {
            node.reconcileChildren([], transaction: transaction)
            return
        }
        source.registerPlaceholder(node)
        node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
    }
}

/// A transition: how a view looks in each phase of its insertion and
/// removal.
public protocol Transition {
    associatedtype Body: View
    typealias Content = PlaceholderContentView<Self>
    @ViewBuilder @MainActor func body(content: Content, phase: TransitionPhase) -> Body
    static var properties: TransitionProperties { get }
}

extension Transition {
    public static var properties: TransitionProperties { TransitionProperties() }

    /// The transition's body applied to `content`.
    @MainActor
    public func apply<V: View>(content: V, phase: TransitionPhase) -> some View {
        body(content: PlaceholderContentView<Self>(wrapping: content), phase: phase)
    }

    /// The transition with its own animation (used instead of the
    /// transaction's).
    public func animation(_ animation: Animation?) -> some Transition {
        _AnimatedTransition(base: self, animation: animation)
    }

    /// This transition and `other`, applied together.
    public func combined<T: Transition>(with other: T) -> some Transition {
        _CombinedTransition(first: self, second: other)
    }
}

/// Supplies a transition's own animation.
package protocol TransitionAnimationProviding {
    var _transitionAnimation: Animation? { get }
}

// MARK: - Built-in transitions

/// No change.
public struct IdentityTransition: Transition {
    public init() {}
    public func body(content: Content, phase: TransitionPhase) -> some View { content }
    public static var properties: TransitionProperties { TransitionProperties(hasMotion: false) }
}

/// Fades the view in and out.
public struct OpacityTransition: Transition {
    public init() {}
    public func body(content: Content, phase: TransitionPhase) -> some View { content.opacity(phase.isIdentity ? 1 : 0) }
    public static var properties: TransitionProperties { TransitionProperties(hasMotion: false) }
}

/// Scales the view (about `anchor`) from and to `scale`.
public struct ScaleTransition: Transition {
    public var scale: Double
    public var anchor: UnitPoint
    public init(_ scale: Double, anchor: UnitPoint = .center) {
        self.scale = scale
        self.anchor = anchor
    }
    public func body(content: Content, phase: TransitionPhase) -> some View {
        content.scaleEffect(phase.isIdentity ? 1 : scale, anchor: anchor)
    }
}

/// Offsets the view by `offset` before appearing and after disappearing.
public struct OffsetTransition: Transition {
    public var offset: CGSize
    public init(_ offset: CGSize) { self.offset = offset }
    public func body(content: Content, phase: TransitionPhase) -> some View {
        content.offset(phase.isIdentity ? .zero : offset)
    }
}

extension Edge {
    /// A one-size step towards this edge (layout-direction terms).
    package var unitOffset: CGSize {
        switch self {
        case .top: return CGSize(width: 0, height: -1)
        case .bottom: return CGSize(width: 0, height: 1)
        case .leading: return CGSize(width: -1, height: 0)
        case .trailing: return CGSize(width: 1, height: 0)
        }
    }

    package var opposite: Edge {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }
}

/// Moves the view in from and out to `edge` (by its own size).
public struct MoveTransition: Transition {
    public var edge: Edge
    public init(edge: Edge) { self.edge = edge }
    public func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(_SizeRelativeOffsetEffect(fraction: phase.isIdentity ? .zero : edge.unitOffset))
    }
}

/// Moves the view in from the leading edge and out to the trailing edge.
public struct SlideTransition: Transition {
    public init() {}
    public func body(content: Content, phase: TransitionPhase) -> some View {
        let f: CGSize
        switch phase {
        case .willAppear: f = Edge.leading.unitOffset
        case .identity: f = .zero
        case .didDisappear: f = Edge.trailing.unitOffset
        }
        return content.modifier(_SizeRelativeOffsetEffect(fraction: f))
    }
}

/// Pushes the view in from `edge` and out towards the opposite edge, fading.
public struct PushTransition: Transition {
    public var edge: Edge
    public init(edge: Edge) { self.edge = edge }
    public func body(content: Content, phase: TransitionPhase) -> some View {
        let f: CGSize
        switch phase {
        case .willAppear: f = edge.unitOffset
        case .identity: f = .zero
        case .didDisappear: f = edge.opposite.unitOffset
        }
        return content.modifier(_SizeRelativeOffsetEffect(fraction: f)).opacity(phase.isIdentity ? 1 : 0)
    }
}

/// One transition for insertion, another for removal.
public struct AsymmetricTransition<Insertion: Transition, Removal: Transition>: Transition {
    public var insertion: Insertion
    public var removal: Removal
    public init(insertion: Insertion, removal: Removal) {
        self.insertion = insertion
        self.removal = removal
    }
    public func body(content: Content, phase: TransitionPhase) -> some View {
        // Both are always applied (a stable structure); each is held at
        // identity outside its own phase.
        removal.apply(content: insertion.apply(content: content, phase: phase == .didDisappear ? .identity : phase),
                      phase: phase == .willAppear ? .identity : phase)
    }
    public static var properties: TransitionProperties {
        TransitionProperties(hasMotion: Insertion.properties.hasMotion || Removal.properties.hasMotion)
    }
}

package struct _CombinedTransition<First: Transition, Second: Transition>: Transition, TransitionAnimationProviding {
    package var first: First
    package var second: Second
    package func body(content: Content, phase: TransitionPhase) -> some View {
        second.apply(content: first.apply(content: content, phase: phase), phase: phase)
    }
    package static var properties: TransitionProperties {
        TransitionProperties(hasMotion: First.properties.hasMotion || Second.properties.hasMotion)
    }
    package var _transitionAnimation: Animation? {
        (second as? any TransitionAnimationProviding)?._transitionAnimation
            ?? (first as? any TransitionAnimationProviding)?._transitionAnimation
    }
}

package struct _AnimatedTransition<Base: Transition>: Transition, TransitionAnimationProviding {
    package var base: Base
    package var animation: Animation?
    package func body(content: Content, phase: TransitionPhase) -> some View {
        base.apply(content: content, phase: phase)
    }
    package static var properties: TransitionProperties { Base.properties }
    package var _transitionAnimation: Animation? { animation }
}

extension Transition where Self == IdentityTransition {
    public static var identity: IdentityTransition { IdentityTransition() }
}

extension Transition where Self == OpacityTransition {
    public static var opacity: OpacityTransition { OpacityTransition() }
}

extension Transition where Self == ScaleTransition {
    /// Scales from and to zero.
    public static var scale: ScaleTransition { ScaleTransition(0) }
    public static func scale(_ scale: Double, anchor: UnitPoint = .center) -> ScaleTransition {
        ScaleTransition(scale, anchor: anchor)
    }
}

extension Transition where Self == OffsetTransition {
    public static func offset(_ offset: CGSize) -> OffsetTransition { OffsetTransition(offset) }
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> OffsetTransition {
        OffsetTransition(CGSize(width: x, height: y))
    }
}

extension Transition where Self == MoveTransition {
    public static func move(edge: Edge) -> MoveTransition { MoveTransition(edge: edge) }
}

extension Transition where Self == SlideTransition {
    public static var slide: SlideTransition { SlideTransition() }
}

extension Transition where Self == PushTransition {
    public static func push(from edge: Edge) -> PushTransition { PushTransition(edge: edge) }
}

// MARK: - AnyTransition

/// A type-erased transition (built and used on the main actor, like views).
@MainActor
public struct AnyTransition {
    package let makeBody: @MainActor (PlaceholderContentView<_ErasedTransition>, TransitionPhase) -> AnyView
    package let animationOverride: Animation?

    package init(makeBody: @escaping @MainActor (PlaceholderContentView<_ErasedTransition>, TransitionPhase) -> AnyView,
                 animation: Animation?) {
        self.makeBody = makeBody
        self.animationOverride = animation
    }

    public init<T: Transition>(_ transition: T) {
        self.init(makeBody: { content, phase in AnyView(transition.apply(content: content, phase: phase)) },
                  animation: (transition as? any TransitionAnimationProviding)?._transitionAnimation)
    }

    public static var identity: AnyTransition { AnyTransition(IdentityTransition()) }
    public static var opacity: AnyTransition { AnyTransition(OpacityTransition()) }
    public static var slide: AnyTransition { AnyTransition(SlideTransition()) }
    public static var scale: AnyTransition { AnyTransition(ScaleTransition(0)) }

    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition {
        AnyTransition(ScaleTransition(scale, anchor: anchor))
    }

    public static func offset(_ offset: CGSize) -> AnyTransition { AnyTransition(OffsetTransition(offset)) }
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition {
        AnyTransition(OffsetTransition(CGSize(width: x, height: y)))
    }

    public static func move(edge: Edge) -> AnyTransition { AnyTransition(MoveTransition(edge: edge)) }
    public static func push(from edge: Edge) -> AnyTransition { AnyTransition(PushTransition(edge: edge)) }

    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition {
        AnyTransition(AsymmetricTransition(insertion: _ErasedTransition(insertion), removal: _ErasedTransition(removal)))
    }

    /// A transition from a modifier: `active` before insertion and after
    /// removal, `identity` while shown.
    public static func modifier<E: ViewModifier>(active: E, identity: E) -> AnyTransition {
        AnyTransition(makeBody: { content, phase in AnyView(content.modifier(phase.isIdentity ? identity : active)) },
                      animation: nil)
    }

    public func animation(_ animation: Animation?) -> AnyTransition {
        AnyTransition(makeBody: makeBody, animation: animation)
    }

    public func combined(with other: AnyTransition) -> AnyTransition {
        AnyTransition(_CombinedTransition(first: _ErasedTransition(self), second: _ErasedTransition(other)))
    }
}

/// `AnyTransition` as a `Transition`.
public struct _ErasedTransition: Transition, TransitionAnimationProviding {
    package let transition: AnyTransition
    package init(_ transition: AnyTransition) { self.transition = transition }
    public func body(content: Content, phase: TransitionPhase) -> AnyView { transition.makeBody(content, phase) }
    package var _transitionAnimation: Animation? { transition.animationOverride }
}

// MARK: - The `.transition` modifier

/// The node state of a `.transition` modifier: its phase, the transition's
/// own animation, and its body for any phase.
@MainActor
package final class TransitionState {
    package var phase: TransitionPhase = .identity
    package var animation: Animation?
    package var body: ((TransitionPhase) -> any View)?
}

@MainActor package protocol TransitionModifierProtocol {
    @MainActor func _body(source: ViewNode, phase: TransitionPhase) -> any View
    var _animation: Animation? { get }
}

/// `.transition(_:)`: its body is the transition's body for the node's
/// current phase.
package struct TransitionModifier<T: Transition>: ViewModifier, TransitionModifierProtocol {
    package let transition: T
    package typealias Body = Never

    package func _body(source: ViewNode, phase: TransitionPhase) -> any View {
        transition.body(content: PlaceholderContentView<T>(source: source), phase: phase)
    }

    package var _animation: Animation? { (transition as? any TransitionAnimationProviding)?._transitionAnimation }
}

package protocol TransitionHosting {
    @MainActor func _transitionUpdate(node: ViewNode, isNew: Bool, transaction: Transaction)
}

extension ModifiedContent: TransitionHosting where Content: View, Modifier: TransitionModifierProtocol {
    package func _transitionUpdate(node: ViewNode, isNew: Bool, transaction: Transaction) {
        node.modifierContent = content
        let state: TransitionState
        if let s = node.primitiveState as? TransitionState {
            state = s
        } else {
            state = TransitionState()
            node.primitiveState = state
        }
        let modifier = self.modifier
        state.animation = modifier._animation
        state.body = { [weak node] phase in
            guard let node else { return EmptyView() }
            return modifier._body(source: node, phase: phase)
        }
        if isNew, let root = node.insertionRoot, !root.transitionClaimed, let rootTx = root.insertionTransaction {
            root.transitionClaimed = true
            if let animation = state.animation ?? rootTx.animation {
                // Insertion: build at `willAppear`, then move to `identity`
                // in the animated transaction.
                let still = Transaction()
                node.setChildTransaction(still)
                state.phase = .willAppear
                node.reconcileChildren([(AnyHashable(0), modifier._body(source: node, phase: .willAppear))], transaction: still)
                var tx = rootTx
                tx.animation = animation
                node.applyTransitionPhase(.identity, transaction: tx)
                return
            }
        }
        node.reconcileChildren([(AnyHashable(0), modifier._body(source: node, phase: state.phase))], transaction: transaction)
    }
}

extension ViewNode {
    /// Moves a `.transition` node to `phase` in `transaction`.
    package func applyTransitionPhase(_ phase: TransitionPhase, transaction: Transaction) {
        guard let state = primitiveState as? TransitionState, let body = state.body else { return }
        state.phase = phase
        setChildTransaction(transaction)
        reconcileChildren([(AnyHashable(0), body(phase))], transaction: transaction)
    }
}

extension View {
    /// The transition used when this view is inserted or removed.
    public func transition<T: Transition>(_ transition: T) -> some View {
        modifier(TransitionModifier(transition: transition))
    }

    public func transition(_ transition: AnyTransition) -> some View {
        modifier(TransitionModifier(transition: _ErasedTransition(transition)))
    }
}
