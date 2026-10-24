import Foundation

// Lifecycle and transaction modifiers (03-architecture.md §2, §3, §5;
// 05-animation.md §4.1).
//
// - `onAppear`/`task` start when the modifier's identity is inserted; the
//   graph runs insertions in reverse pre-order (children first, later
//   siblings first). `onDisappear`/task cancellation run when it is removed,
//   after the update's appearances.
// - `onChange(of:)` compares the value each time the modifier receives a new
//   value and runs the action at once (during the update, after the value
//   changed, before the content is updated); with `initial: true` it also
//   runs once on appearance (old == new).
// - `task(id:)`: a changed ID cancels the running task and starts a new one
//   in the same update.

private final class AppearanceState {
    var disappear: (() -> Void)?
    init(_ d: (() -> Void)?) { disappear = d }
}

package struct AppearanceActionModifier: PrimitiveModifier {
    package var appear: (() -> Void)?
    package var disappear: (() -> Void)?

    package func _inserted(node: ViewNode) {
        node.primitiveState = AppearanceState(disappear)
        if let appear { node.graph.queueAppear(appear) }
    }

    package func _updated(old: AppearanceActionModifier, node: ViewNode) {
        (node.primitiveState as? AppearanceState)?.disappear = disappear
    }

    package func _removed(node: ViewNode) {
        if let d = (node.primitiveState as? AppearanceState)?.disappear { node.graph.queueDisappear(d) }
    }
}

private final class ValueActionState<V> {
    var value: V
    init(_ v: V) { value = v }
}

package struct ValueActionModifier<V: Equatable>: PrimitiveModifier {
    package let value: V
    package let initial: Bool
    package let action: (V, V) -> Void

    package func _inserted(node: ViewNode) {
        node.primitiveState = ValueActionState(value)
        if initial {
            let v = value, action = action
            node.graph.queueAppear { action(v, v) }
        }
    }

    package func _updated(old: ValueActionModifier, node: ViewNode) {
        guard let state = node.primitiveState as? ValueActionState<V> else { return }
        let previous = state.value
        state.value = value
        if previous != value { action(previous, value) }
    }
}

private final class TaskState {
    var task: Task<Void, Never>?
    func cancel() {
        task?.cancel()
        task = nil
    }
}

package struct TaskModifier: PrimitiveModifier {
    package let id: AnyHashable?
    package let priority: TaskPriority
    package let action: @MainActor () async -> Void

    private func start(_ state: TaskState) {
        let action = self.action
        state.task = Task(priority: priority) { @MainActor in await action() }
    }

    package func _inserted(node: ViewNode) {
        let state = TaskState()
        node.primitiveState = state
        node.graph.queueAppear { self.start(state) }
    }

    package func _updated(old: TaskModifier, node: ViewNode) {
        guard old.id != id, let state = node.primitiveState as? TaskState else { return }
        node.graph.queueAppear {
            state.cancel()
            self.start(state)
        }
    }

    package func _removed(node: ViewNode) {
        guard let state = node.primitiveState as? TaskState else { return }
        node.graph.queueDisappear { state.cancel() }
    }
}

extension TaskModifier: GraphInputComparable {
    package nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

/// `.transaction(_:)`: rewrites the transaction that reaches the content.
package struct TransactionModifier: PrimitiveModifier {
    package let transform: (inout Transaction) -> Void

    package func _transaction(_ transaction: Transaction, old: TransactionModifier?, node: ViewNode) -> Transaction {
        var t = transaction
        transform(&t)
        return t
    }
}

/// `.transaction(value:_:)`: rewrites it only when `value` changed.
package struct ValueTransactionModifier<V: Equatable>: PrimitiveModifier {
    package let value: V
    package let transform: (inout Transaction) -> Void

    package func _transaction(_ transaction: Transaction, old: ValueTransactionModifier?, node: ViewNode) -> Transaction {
        guard let old, old.value != value else { return transaction }
        var t = transaction
        transform(&t)
        return t
    }
}

/// `.animation(_:value:)`: when `value` changed in this update, the
/// content's transaction gets `animation` — overriding the transaction's own
/// animation (05 §4.1: "the view's own modifier wins in its subtree"), unless
/// the transaction disables implicit animations.
package struct AnimationModifier<V: Equatable>: PrimitiveModifier {
    package let animation: Animation?
    package let value: V

    package func _transaction(_ transaction: Transaction, old: AnimationModifier?, node: ViewNode) -> Transaction {
        guard let old, old.value != value, !transaction.disablesAnimations else { return transaction }
        var t = transaction
        t.animation = animation
        return t
    }
}

/// Render-only modifiers: no layout effect (04-layout.md §5, 03 §6).
package struct RenderEffectModifier<Value: Equatable>: PrimitiveModifier {
    package let name: String
    package let value: Value
}

extension View {
    /// Runs `action` when the view appears (03 §2 for the order).
    public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        modifier(AppearanceActionModifier(appear: action, disappear: nil))
    }

    /// Runs `action` when the view disappears.
    public func onDisappear(perform action: (() -> Void)? = nil) -> some View {
        modifier(AppearanceActionModifier(appear: nil, disappear: action))
    }

    /// Runs `action` with the old and new value when `value` changes.
    public func onChange<V: Equatable>(of value: V, initial: Bool = false,
                                       _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        modifier(ValueActionModifier(value: value, initial: initial, action: action))
    }

    /// Runs `action` when `value` changes.
    public func onChange<V: Equatable>(of value: V, initial: Bool = false,
                                       _ action: @escaping () -> Void) -> some View {
        modifier(ValueActionModifier(value: value, initial: initial) { _, _ in action() })
    }

    @available(*, deprecated, message: "Use onChange with a two or zero parameter action closure instead.")
    public func onChange<V: Equatable>(of value: V, perform action: @escaping (_ newValue: V) -> Void) -> some View {
        modifier(ValueActionModifier(value: value, initial: false) { _, new in action(new) })
    }

    /// Starts `action` when the view appears and cancels it when it
    /// disappears.
    public func task(priority: TaskPriority = .userInitiated,
                     _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(TaskModifier(id: nil, priority: priority, action: action))
    }

    /// Like `task(priority:_:)`, and restarts the task when `id` changes.
    public func task<T: Equatable & Hashable>(id value: T, priority: TaskPriority = .userInitiated,
                                              _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(TaskModifier(id: AnyHashable(value), priority: priority, action: action))
    }

    /// Edits the transaction that reaches this view's content.
    public func transaction(_ transform: @escaping (inout Transaction) -> Void) -> some View {
        modifier(TransactionModifier(transform: transform))
    }

    /// Edits the transaction when `value` changes.
    public func transaction<V: Equatable>(value: V, _ transform: @escaping (inout Transaction) -> Void) -> some View {
        modifier(ValueTransactionModifier(value: value, transform: transform))
    }

    /// Animates changes in this view's content when `value` changes.
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(AnimationModifier(animation: animation, value: value))
    }

    /// Hides the view; it keeps its place in layout.
    public func hidden() -> some View { modifier(RenderEffectModifier(name: "hidden", value: true)) }
}
