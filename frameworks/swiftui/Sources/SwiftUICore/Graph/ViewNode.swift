import Foundation
import Observation

// The retained view tree (09-open-design.md §3.2). A `ViewNode` is one
// identity: it lives as long as its position in the static structure (and
// its explicit ID) stays the same, holds the identity's state, records the
// dependencies of its last body evaluation, and is updated with the new view
// values its parent produces.
//
// Update rules (03-architecture.md §4.2):
//  1. A custom view's body runs when an input differs (field by field), when
//     a dependency recorded during its last body evaluation changed (state,
//     an environment key, an observed property or object), or on insertion.
//  2. Updates go top-down; a node that did not change still passes a changed
//     environment, and the walk towards invalidated descendants, to its
//     children.
//  3. Insertions queue `onAppear` actions in pre-order; the graph runs them
//     in reverse (children before parents, later siblings first; 03 §2).

/// A weak reference to a node that may be captured by `@Sendable` closures
/// (observation callbacks) and by dependency sources.
package final class WeakNode: @unchecked Sendable {
    package weak var node: ViewNode?
    package init(_ node: ViewNode) { self.node = node }

    /// Invalidates the node from any thread (observation and publishers may
    /// fire off the main thread; the graph itself runs on the main actor).
    package nonisolated func invalidate() {
        if MainActorCheck.isCurrent {
            let tx = Transaction._current
            MainActor.assumeIsolated { node?.invalidate(transaction: tx) }
        } else {
            Task { @MainActor in self.node?.invalidate(transaction: Transaction()) }
        }
    }
}

/// Something view bodies can depend on: a state location, an observed
/// object. Dependents are tracked weakly.
package class DependencySource: @unchecked Sendable {
    private var dependents: [ObjectIdentifier: WeakNode] = [:]

    package init() {}

    @MainActor package func addDependent(_ node: ViewNode) {
        dependents[ObjectIdentifier(node)] = WeakNode(node)
    }

    @MainActor package func removeDependent(_ node: ViewNode) {
        dependents[ObjectIdentifier(node)] = nil
    }

    @MainActor package func invalidateDependents(transaction: Transaction) {
        for (id, ref) in dependents {
            guard let n = ref.node, n.isAlive else { dependents[id] = nil; continue }
            n.invalidate(transaction: transaction)
        }
    }
}

/// Records dependencies of the body being evaluated.
package enum DependencyTracker {
    /// The node whose body is being evaluated (main thread only).
    nonisolated(unsafe) package static var current: ViewNode?

    package static func recordRead(_ source: DependencySource) {
        guard MainActorCheck.isCurrent, current != nil else { return }
        MainActor.assumeIsolated { current?.addDependency(source) }
    }

    @MainActor
    package static func recordEnvironmentRead(node: ViewNode?, key: AnyHashable, value: Any,
                                              read: @escaping (EnvironmentValues) -> Any) {
        guard let cur = current, let node, cur === node else { return }
        node.addEnvironmentDependency(key: key, value: value, read: read)
    }
}

@MainActor
package final class ViewNode {
    package enum Kind { case custom, primitive }

    package unowned let graph: ViewGraph
    package private(set) weak var parent: ViewNode?
    package private(set) var view: any View
    package let kind: Kind
    /// The environment this node received.
    package private(set) var environment = EnvironmentValues()
    /// The environment passed to children (environment modifiers change it).
    package var childEnvironment: EnvironmentValues { environmentOverride ?? environment }
    package var environmentOverride: EnvironmentValues?
    /// Input revision the override was computed from (environment modifiers).
    package var primitiveEnvironmentCache: UInt64?
    package private(set) var children: [ViewNode] = []
    package private(set) var childKeys: [AnyHashable] = []

    package private(set) var isAlive = true
    private var isNew = true
    package var isDirty = false
    package var hasDirtyDescendant = false

    // Flags of the update being processed (read by primitives).
    package private(set) var updateEnvironmentChanged = false
    package private(set) var updateWasDirty = false
    package private(set) var updateHadDirtyDescendant = false

    /// Number of body evaluations (custom views and modifiers).
    package private(set) var bodyCount = 0

    // Dynamic property storage, by slot (03 §3: state lives with the identity).
    package var slots: [Int: AnyObject] = [:]
    // Dependencies of the last body evaluation.
    private var sources: [ObjectIdentifier: DependencySource] = [:]
    private var environmentDependencies: [AnyHashable: (value: Any, read: (EnvironmentValues) -> Any)] = [:]

    /// Per-primitive storage (lifecycle state, task handles, cached values).
    package var primitiveState: AnyObject?
    /// For custom modifiers: the content `body(content:)` places.
    package var modifierContent: (any View)?
    private var placeholders: [WeakNode] = []

    /// Geometry from the last layout pass (for nodes that asked for it).
    package var geometry: NodeGeometry?

    // MARK: Animation state (R6)

    /// The pass that created this node.
    package let createdPass: Int
    /// The transaction this node passed to its children, and the pass it
    /// was computed in (see `transactionForChildren()`).
    private var childTx = Transaction()
    private var childTxStamp = -1
    /// The root of the insertion this node was created by (it and the chain
    /// of modifiers and wrappers below it), when inserted into an existing
    /// parent; the root also keeps the inserting transaction.
    package weak var insertionRoot: ViewNode?
    package var insertionTransaction: Transaction?
    /// True once a `.transition` on the insertion chain has taken over.
    package var transitionClaimed = false
    /// The default (opacity) transition of an inserted or removed node.
    package var transitionOpacity: Animator<Double>?
    /// The animator of an `Animatable` custom view or modifier.
    package var bodyAnimator: AnyObject?
    /// Animated layout geometry of the layout nodes this node created, by
    /// creation index (frames in the parent layout node's coordinates).
    package var frameAnimators: [Int: Animator<CGRect.AnimatableData>] = [:]
    /// The layout nodes of the last lowering.
    package private(set) var lastLowered: [LayoutNode] = []
    private var lowerGeneration = -1
    private var lowerCounter = 0

    package init(graph: ViewGraph, parent: ViewNode?, view: any View) {
        self.graph = graph
        self.parent = parent
        self.view = view
        self.kind = view is any PrimitiveView ? .primitive : .custom
        self.createdPass = graph.passCount
    }

    // MARK: Update

    /// Updates the node with a new value from its parent (`nil`: the parent
    /// did not produce one in this update — only the environment and the
    /// walk towards invalidated descendants pass through).
    package func update(_ newView: (any View)?, environment env: EnvironmentValues, transaction: Transaction) {
        guard isAlive else { return }
        let first = isNew
        isNew = false
        setChildTransaction(transaction)
        let envChanged = first || env.revision != environment.revision
        environment = env
        let old: (any View)? = first ? nil : view
        if let v = newView { view = v }
        let dirty = isDirty, dirtyDescendant = hasDirtyDescendant
        isDirty = false
        hasDirtyDescendant = false
        updateEnvironmentChanged = envChanged
        updateWasDirty = dirty
        updateHadDirtyDescendant = dirtyDescendant
        switch kind {
        case .custom:
            let inputsChanged = old == nil || (newView != nil && !GraphComparison.fieldsEqual(old!, view))
            let presented = presentedCustomView(isNewValue: newView != nil, transaction: transaction)
            updateTracked(inputs: presented ?? view, inputsChanged: inputsChanged, transaction: transaction) {
                evaluateBody(of: presented ?? self.view)
            }
        case .primitive:
            let p = view as! any PrimitiveView
            if newView != nil || first {
                makeChildren(p, old: old, transaction: transaction)
            } else if envChanged || dirty || dirtyDescendant {
                p._refresh(node: self, environmentChanged: envChanged, transaction: transaction)
            }
        }
    }

    private func makeChildren<P: PrimitiveView>(_ p: P, old: (any View)?, transaction: Transaction) {
        p._makeChildren(node: self, old: old as? P, transaction: transaction)
    }

    /// The body-evaluating update shared by custom views and custom
    /// modifiers. Returns true if the body ran.
    @discardableResult
    package func updateTracked(inputs: Any, inputsChanged: Bool, transaction: Transaction,
                               evaluate: () -> any View) -> Bool {
        let envDependencyChanged = updateEnvironmentChanged && environmentDependenciesChanged()
        if inputsChanged || updateWasDirty || envDependencyChanged {
            let body = runTracked(inputs: inputs, evaluate)
            reconcileChildren([(AnyHashable(0), body)], transaction: transaction)
            return true
        }
        if updateEnvironmentChanged || updateHadDirtyDescendant {
            refreshChildren(transaction: transaction)
        }
        return false
    }

    /// Runs `evaluate` as this node's body: installs dynamic properties,
    /// records state, environment and observation dependencies.
    package func runTracked(inputs: Any, _ evaluate: () -> any View) -> any View {
        clearDependencies()
        DynamicPropertyInstaller.install(inputs, in: self)
        let previous = DependencyTracker.current
        DependencyTracker.current = self
        defer { DependencyTracker.current = previous }
        let ref = WeakNode(self)
        let body = withObservationTracking {
            evaluate()
        } onChange: {
            ref.invalidate()
        }
        bodyCount += 1
        graph.noteBodyEvaluation(self)
        return body
    }

    /// Runs a closure a container calls to produce its content (`ForEach`
    /// content, `GeometryReader` content) with this node as the dependent:
    /// state, environment and observation reads in it invalidate this node,
    /// which then re-evaluates the closure without its parent's body running.
    package func trackContent<T>(_ evaluate: () -> T) -> T {
        clearDependencies()
        let previous = DependencyTracker.current
        DependencyTracker.current = self
        defer { DependencyTracker.current = previous }
        let ref = WeakNode(self)
        return withObservationTracking {
            evaluate()
        } onChange: {
            ref.invalidate()
        }
    }

    /// Passes the environment and the update walk to the existing children.
    package func refreshChildren(transaction: Transaction) {
        let env = childEnvironment
        for c in children { c.update(nil, environment: env, transaction: transaction) }
    }

    /// Reconciles the children with new keyed values: a child keeps its
    /// identity (and state) when its key and type are unchanged; new keys
    /// insert children, missing keys remove them.
    package func reconcileChildren(_ items: [(AnyHashable, any View)], transaction: Transaction) {
        var oldByKey: [AnyHashable: ViewNode] = [:]
        var oldOrder: [AnyHashable] = []
        for (k, c) in zip(childKeys, children) where oldByKey[k] == nil {
            oldByKey[k] = c
            oldOrder.append(k)
        }
        var newChildren: [ViewNode] = []
        var newKeys: [AnyHashable] = []
        newChildren.reserveCapacity(items.count)
        let env = childEnvironment
        var toUpdate: [(ViewNode, any View)] = []
        var inserted: [ViewNode] = []
        for (key, v) in items {
            if let c = oldByKey[key], ObjectIdentifier(type(of: c.view)) == ObjectIdentifier(type(of: v)) {
                oldByKey[key] = nil
                newChildren.append(c)
                toUpdate.append((c, v))
            } else {
                let c = ViewNode(graph: graph, parent: self, view: v)
                if createdPass == graph.passCount {
                    // Part of a larger insertion: continue its chain.
                    if passesInsertion(toChildKey: key) { c.insertionRoot = insertionRoot }
                } else {
                    c.insertionRoot = c
                    c.insertionTransaction = transaction
                    inserted.append(c)
                }
                newChildren.append(c)
                toUpdate.append((c, v))
            }
            newKeys.append(key)
        }
        // Removed children (in their old order).
        for k in oldOrder { if let c = oldByKey[k] { remove(c, transaction: transaction) } }
        children = newChildren
        childKeys = newKeys
        for (c, v) in toUpdate { c.update(v, environment: env, transaction: transaction) }
        // Insertions no `.transition` took over get the default (opacity).
        for c in inserted where !c.transitionClaimed && transaction.animation != nil {
            let fade = Animator<Double>(0, owner: c)
            c.transitionOpacity = fade
            fade.update(to: 1, transaction: transaction, graph: graph)
        }
    }

    /// Removes a child: with an animated transaction (or a transition with
    /// its own animation) the child stays rendered until its removal
    /// transition ends (05 §5), otherwise it is torn down now.
    private func remove(_ c: ViewNode, transaction: Transaction) {
        if let t = c.transitionNode(), let state = t.primitiveState as? TransitionState,
           let animation = state.animation ?? transaction.animation {
            var tx = transaction
            tx.animation = animation
            t.applyTransitionPhase(.didDisappear, transaction: tx)
        } else if transaction.animation != nil {
            let fade = c.transitionOpacity ?? Animator<Double>(1, owner: c)
            c.transitionOpacity = fade
            fade.update(to: 0, transaction: transaction, graph: graph)
        }
        if graph.hasActiveDrivers(in: c) {
            graph.addGhost(c)
        } else {
            c.teardown()
        }
    }

    /// The `.transition` node on this node's insertion chain, if any.
    package func transitionNode() -> ViewNode? {
        var n = self
        while true {
            if n.primitiveState is TransitionState, n.view is any TransitionHosting { return n }
            guard let first = n.children.first, n.passesInsertion(toChildKey: n.childKeys[0]) else { return nil }
            n = first
        }
    }

    /// Whether an insertion at this node continues into the child with `key`
    /// (custom views, modifiers' content, wrappers; not containers).
    package func passesInsertion(toChildKey key: AnyHashable) -> Bool {
        switch kind {
        case .custom: return true
        case .primitive: return (view as? any InsertionChaining)?._passesInsertion(childKey: key) ?? false
        }
    }

    /// True if `ancestor` is this node or one of its ancestors.
    package func isDescendant(of ancestor: ViewNode) -> Bool {
        var n: ViewNode? = self
        while let m = n {
            if m === ancestor { return true }
            n = m.parent
        }
        return false
    }

    // MARK: Transactions (R6)

    package func setChildTransaction(_ t: Transaction) {
        childTx = t
        childTxStamp = graph.passCount
    }

    /// The transaction that reaches this node's children in the current
    /// pass. Nodes the pass did not visit derive it from their parent, with
    /// the transaction modifiers on the way applied as for an unchanged value.
    package func transactionForChildren() -> Transaction {
        if childTxStamp == graph.passCount { return childTx }
        let incoming = transactionForSelf()
        let t = (view as? any TransactionRewriting)?._unchangedTransaction(incoming, node: self) ?? incoming
        setChildTransaction(t)
        return t
    }

    /// The transaction that reaches this node in the current pass.
    package func transactionForSelf() -> Transaction {
        parent?.transactionForChildren() ?? graph.passTransaction
    }

    // MARK: Animatable views (R6)

    /// For an `Animatable` custom view: updates its animator and returns a
    /// copy with the presented data (nil when the view is not animatable).
    private func presentedCustomView(isNewValue: Bool, transaction: Transaction) -> (any View)? {
        guard let a = view as? any Animatable else { return nil }
        return presentedAnimatable(a, isNewValue: isNewValue, transaction: transaction) { [weak self] in
            self?.customViewFrame()
        } as? any View
    }

    /// Re-evaluates an animatable custom view's body with the presented data.
    private func customViewFrame() {
        guard isAlive else { return }
        let tx = Transaction()
        setChildTransaction(tx)
        let presented = presentedCustomView(isNewValue: false, transaction: tx)
        updateTracked(inputs: presented ?? view, inputsChanged: true, transaction: tx) {
            evaluateBody(of: presented ?? self.view)
        }
    }

    /// The animator half of `Animatable` views and modifiers: keeps the
    /// node's animator in step with the model data and returns the value with
    /// the presented data (nil for empty animatable data).
    package func presentedAnimatable<A: Animatable>(_ a: A, isNewValue: Bool, transaction: Transaction,
                                                    onFrame: @escaping () -> Void) -> A? {
        if A.AnimatableData.self == EmptyAnimatableData.self { return nil }
        let data = a.animatableData
        let animator: Animator<A.AnimatableData>
        if let existing = bodyAnimator as? Animator<A.AnimatableData> {
            animator = existing
            if isNewValue { animator.update(to: data, transaction: transaction, graph: graph) }
        } else {
            animator = Animator(data, owner: self)
            bodyAnimator = animator
        }
        animator.onChange = onFrame
        var copy = a
        copy.animatableData = animator.presented
        return copy
    }

    // MARK: Geometry (R6)

    /// Records the layout frame of created node `index` (parent layout
    /// coordinates); a change animates with `transaction`'s animation.
    package func recordFrame(index: Int, _ frame: CGRect, transaction: Transaction) {
        let data = frame.animatableData
        if let a = frameAnimators[index] {
            a.update(to: data, transaction: transaction, graph: graph)
        } else {
            frameAnimators[index] = Animator(data, owner: self)
        }
    }

    /// The presented frame of created node `index`, if animating.
    package func presentedFrame(index: Int) -> CGRect? {
        guard let a = frameAnimators[index], a.isActive else { return nil }
        var r = CGRect.zero
        r.animatableData = a.presented
        return r
    }

    /// Removes this node and its subtree: queues disappear actions, cancels
    /// tasks, drops state and subscriptions.
    package func teardown() {
        guard isAlive else { return }
        if kind == .primitive, let p = view as? any PrimitiveView { p._removed(node: self) }
        for c in children { c.teardown() }
        isAlive = false
        clearDependencies()
        slots.removeAll()
        children = []
        childKeys = []
        parent = nil
    }

    // MARK: Invalidation

    /// Marks the node for re-evaluation in the next update.
    package func invalidate(transaction: Transaction) {
        guard isAlive else { return }
        isDirty = true
        var p = parent
        while let q = p, !q.hasDirtyDescendant {
            q.hasDirtyDescendant = true
            p = q.parent
        }
        graph.scheduleUpdate(transaction: transaction)
    }

    // MARK: Dependencies

    package func addDependency(_ source: DependencySource) {
        sources[ObjectIdentifier(source)] = source
        source.addDependent(self)
    }

    package func addEnvironmentDependency(key: AnyHashable, value: Any, read: @escaping (EnvironmentValues) -> Any) {
        if environmentDependencies[key] == nil { environmentDependencies[key] = (value, read) }
    }

    private func clearDependencies() {
        for s in sources.values { s.removeDependent(self) }
        sources = [:]
        environmentDependencies = [:]
    }

    /// True if a key read by the last body evaluation has a different value
    /// in the current environment (per-key granularity, 03 §3).
    private func environmentDependenciesChanged() -> Bool {
        for (_, dep) in environmentDependencies where !GraphComparison.valuesEqual(dep.read(environment), dep.value) {
            return true
        }
        return false
    }

    // MARK: Custom modifier content

    package func registerPlaceholder(_ node: ViewNode) {
        placeholders.removeAll { $0.node == nil || $0.node === node }
        placeholders.append(WeakNode(node))
    }

    /// Hands new modifier content to the placeholders of a modifier body that
    /// did not need to run again.
    package func pushContentToPlaceholders(transaction: Transaction) {
        guard let content = modifierContent else { return }
        for ref in placeholders {
            guard let ph = ref.node, ph.isAlive else { continue }
            ph.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
        }
    }

    // MARK: Lowering and preferences

    /// The layout nodes this subtree produces (R3 engine input).
    package func lower() -> [LayoutNode] {
        switch kind {
        case .custom: return finishLowering(lowerChildren())
        case .primitive: return finishLowering((view as! any PrimitiveView)._lower(node: self))
        }
    }

    /// Marks the layout nodes this node created (and that no deeper node
    /// claimed) with this node, numbering them in creation order; applies
    /// the default transition's opacity.
    private func finishLowering(_ nodes: [LayoutNode]) -> [LayoutNode] {
        if lowerGeneration != graph.lowerGeneration {
            lowerGeneration = graph.lowerGeneration
            lowerCounter = 0
        }
        var out = nodes
        if let fade = transitionOpacity, fade.isActive || fade.model != 1 {
            out = out.map { n in
                let w = LayoutNode(OpacityBehavior(fade.model), children: [n])
                w.presentation = .opacity { fade.presented }
                return w
            }
        }
        for n in out {
            n.forEachNode { m in
                if m.creator == nil {
                    m.creator = self
                    m.creatorIndex = lowerCounter
                    lowerCounter += 1
                }
            }
        }
        lastLowered = out
        return out
    }

    package func lowerChildren() -> [LayoutNode] { children.flatMap { $0.lower() } }

    /// The preference values of this subtree, reduced in child order (03 §7).
    package func preferenceValues() -> PreferenceValues {
        switch kind {
        case .custom: return childPreferences()
        case .primitive: return (view as! any PrimitiveView)._preferences(node: self)
        }
    }

    package func childPreferences() -> PreferenceValues {
        var r = PreferenceValues()
        for c in children { r.combine(with: c.preferenceValues()) }
        return r
    }

    /// Visits the subtree, depth first.
    package func forEachNode(_ body: (ViewNode) -> Void) {
        body(self)
        for c in children { c.forEachNode(body) }
    }
}

/// Geometry a node received in the last layout pass.
package struct NodeGeometry: Equatable {
    package var size: CGSize
    /// Frame in the root's (global) coordinates.
    package var frame: CGRect
    package var safeAreaInsets: EdgeInsets

    package init(size: CGSize = .zero, frame: CGRect = .zero, safeAreaInsets: EdgeInsets = EdgeInsets()) {
        self.size = size
        self.frame = frame
        self.safeAreaInsets = safeAreaInsets
    }
}

@MainActor
package func evaluateBody(of view: any View) -> any View {
    func open<V: View>(_ v: V) -> any View { v.body }
    return open(view)
}
