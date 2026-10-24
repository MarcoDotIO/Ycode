import Foundation

// `PhaseAnimator` and `KeyframeAnimator` (10-plan.md R6; concepts from public
// documentation, 05-animation.md Evidence level 1).
//
// PhaseAnimator: the content is a function of the current phase. Moving to
// a phase is a state change in a transaction with `animation(phase)`; the
// next phase starts when that transaction's animations are logically
// complete. With a trigger, a change of the trigger runs the phases once,
// from the first through the last and back to the first; without one the
// phases cycle for as long as the view exists, starting when it appears.
//
// KeyframeAnimator: when started (on a trigger change, or at appearance when
// repeating), a `KeyframeTimeline` is built from the current value with the
// keyframes closure; every display frame the content is evaluated with the
// timeline's value at the elapsed time. A repeating animator loops; one
// started by a trigger stays at the timeline's final value.

private func equalValues(_ a: any Equatable, _ b: any Equatable) -> Bool {
    func open<A: Equatable>(_ a: A) -> Bool { (b as? A) == a }
    return open(a)
}

// MARK: - PhaseAnimator

@MainActor
private final class PhaseAnimatorState {
    var index = 0
    var trigger: (any Equatable)?
    var generation = 0
}

/// A container that animates its content through a sequence of phases.
public struct PhaseAnimator<Phase: Equatable, Content: View>: View {
    package let phases: [Phase]
    package let trigger: (any Equatable)?
    package let content: (Phase) -> Content
    package let animation: (Phase) -> Animation?

    /// Runs through `phases` once each time `trigger` changes.
    public init(_ phases: some Sequence<Phase>, trigger: some Equatable,
                @ViewBuilder content: @escaping (Phase) -> Content,
                animation: @escaping (Phase) -> Animation? = { _ in .default }) {
        self.phases = Array(phases)
        self.trigger = trigger
        self.content = content
        self.animation = animation
    }

    /// Cycles through `phases` continuously.
    public init(_ phases: some Sequence<Phase>, @ViewBuilder content: @escaping (Phase) -> Content,
                animation: @escaping (Phase) -> Animation? = { _ in .default }) {
        self.phases = Array(phases)
        self.trigger = nil
        self.content = content
        self.animation = animation
    }

    public typealias Body = Never
}

extension PhaseAnimator: GraphInputComparable {
    package nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

extension PhaseAnimator: PrimitiveView {
    private func state(_ node: ViewNode) -> PhaseAnimatorState {
        if let s = node.primitiveState as? PhaseAnimatorState { return s }
        let s = PhaseAnimatorState()
        node.primitiveState = s
        return s
    }

    package func _makeChildren(node: ViewNode, old: PhaseAnimator?, transaction: Transaction) {
        guard !phases.isEmpty else {
            node.reconcileChildren([], transaction: transaction)
            return
        }
        let s = state(node)
        if s.index >= phases.count { s.index = 0 }
        if old == nil {
            s.trigger = trigger
            build(node, transaction)
            if trigger == nil {
                let me = self
                node.graph.queueAppear { [weak node] in
                    guard let node, node.isAlive else { return }
                    me.advance(node, cycleEnds: false)
                }
            }
            return
        }
        if let t = trigger, let previous = s.trigger, !equalValues(t, previous) {
            s.trigger = t
            // Start the sequence in this update.
            let tx = step(node, s, cycleEnds: true, base: transaction)
            node.graph.noteCompletions(tx.completions)
            build(node, tx)
            return
        }
        s.trigger = trigger
        build(node, transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { build(node, transaction) } else { node.refreshChildren(transaction: transaction) }
    }

    private func build(_ node: ViewNode, _ transaction: Transaction) {
        let s = state(node)
        let phase = phases[min(s.index, phases.count - 1)]
        let child = node.trackContent { content(phase) }
        node.setChildTransaction(transaction)
        node.reconcileChildren([(AnyHashable(0), child)], transaction: transaction)
    }

    /// Moves to the next phase: returns the transaction to apply it in (its
    /// completion moves on again unless the cycle ended).
    private func step(_ node: ViewNode, _ s: PhaseAnimatorState, cycleEnds: Bool, base: Transaction) -> Transaction {
        s.index = (s.index + 1) % phases.count
        s.generation += 1
        let generation = s.generation
        let finished = cycleEnds && s.index == 0
        var tx = base
        tx.animation = animation(phases[s.index])
        let me = self
        tx.addAnimationCompletion(criteria: .logicallyComplete) { [weak node] in
            guard let node, node.isAlive, s.generation == generation, !finished else { return }
            me.advance(node, cycleEnds: cycleEnds)
        }
        return tx
    }

    private func advance(_ node: ViewNode, cycleEnds: Bool) {
        let s = state(node)
        let tx = step(node, s, cycleEnds: cycleEnds, base: Transaction())
        node.invalidate(transaction: tx)
    }
}

extension View {
    /// Animates this view through `phases` each time `trigger` changes.
    public func phaseAnimator<Phase: Equatable, V: View>(
        _ phases: some Sequence<Phase>, trigger: some Equatable,
        @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Phase) -> V,
        animation: @escaping (Phase) -> Animation? = { _ in .default }) -> some View {
        let placeholder = PlaceholderContentView<Self>(wrapping: self)
        return PhaseAnimator(phases, trigger: trigger, content: { content(placeholder, $0) }, animation: animation)
    }

    /// Animates this view through `phases` continuously.
    public func phaseAnimator<Phase: Equatable, V: View>(
        _ phases: some Sequence<Phase>,
        @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Phase) -> V,
        animation: @escaping (Phase) -> Animation? = { _ in .default }) -> some View {
        let placeholder = PlaceholderContentView<Self>(wrapping: self)
        return PhaseAnimator(phases, content: { content(placeholder, $0) }, animation: animation)
    }
}

// MARK: - KeyframeAnimator

@MainActor
private final class KeyframeAnimatorState<Value> {
    var value: Value
    var trigger: (any Equatable)?
    var driver: FrameDriver?
    init(_ value: Value) { self.value = value }
}

/// A container that animates a value with keyframes and builds its content
/// from the value every frame.
public struct KeyframeAnimator<Value, KeyframePath: Keyframes, Content: View>: View where KeyframePath.Value == Value {
    package let initialValue: Value
    package let trigger: (any Equatable)?
    package let repeating: Bool
    package let content: (Value) -> Content
    package let keyframes: (Value) -> KeyframePath

    /// Plays the keyframes each time `trigger` changes.
    public init(initialValue: Value, trigger: some Equatable, @ViewBuilder content: @escaping (Value) -> Content,
                @KeyframesBuilder<Value> keyframes: @escaping (Value) -> KeyframePath) {
        self.initialValue = initialValue
        self.trigger = trigger
        self.repeating = false
        self.content = content
        self.keyframes = keyframes
    }

    /// Plays the keyframes from appearance, looping when `repeating`.
    public init(initialValue: Value, repeating: Bool = true, @ViewBuilder content: @escaping (Value) -> Content,
                @KeyframesBuilder<Value> keyframes: @escaping (Value) -> KeyframePath) {
        self.initialValue = initialValue
        self.trigger = nil
        self.repeating = repeating
        self.content = content
        self.keyframes = keyframes
    }

    public typealias Body = Never
}

extension KeyframeAnimator: GraphInputComparable {
    package nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

extension KeyframeAnimator: PrimitiveView {
    private func state(_ node: ViewNode) -> KeyframeAnimatorState<Value> {
        if let s = node.primitiveState as? KeyframeAnimatorState<Value> { return s }
        let s = KeyframeAnimatorState(initialValue)
        node.primitiveState = s
        return s
    }

    package func _makeChildren(node: ViewNode, old: KeyframeAnimator?, transaction: Transaction) {
        let s = state(node)
        if old == nil {
            s.trigger = trigger
            if trigger == nil { start(node, s, loop: repeating) }
        } else if let t = trigger, let previous = s.trigger, !equalValues(t, previous) {
            s.trigger = t
            start(node, s, loop: false)
        }
        build(node, s, transaction)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { build(node, state(node), transaction) } else { node.refreshChildren(transaction: transaction) }
    }

    package func _removed(node: ViewNode) {
        (node.primitiveState as? KeyframeAnimatorState<Value>)?.driver?.cancel()
    }

    private func build(_ node: ViewNode, _ s: KeyframeAnimatorState<Value>, _ transaction: Transaction) {
        let value = s.value
        let child = node.trackContent { content(value) }
        node.setChildTransaction(transaction)
        node.reconcileChildren([(AnyHashable(0), child)], transaction: transaction)
    }

    private func start(_ node: ViewNode, _ s: KeyframeAnimatorState<Value>, loop: Bool) {
        s.driver?.cancel()
        let from = s.value
        let keyframes = self.keyframes
        let timeline = KeyframeTimeline(initialValue: from) { keyframes(from) }
        let begin = node.graph.currentTime
        let duration = timeline.duration
        let driver = FrameDriver(owner: node) { [weak s] time in
            guard let s else { return (false, false) }
            var elapsed = time - begin
            var active = true
            if loop && duration > 0 {
                elapsed = elapsed.truncatingRemainder(dividingBy: duration)
            } else if elapsed >= duration {
                elapsed = duration
                active = false
            }
            s.value = timeline.value(time: elapsed)
            return (true, active)
        }
        let me = self
        driver.onChange = { [weak node] in
            guard let node, node.isAlive else { return }
            let tx = Transaction()
            me.build(node, me.state(node), tx)
        }
        s.driver = driver
        node.graph.activate(driver)
    }
}

extension View {
    /// Plays keyframes on a value each time `trigger` changes; `content`
    /// builds the view from the value every frame.
    public func keyframeAnimator<Value, V: View>(
        initialValue: Value, trigger: some Equatable,
        @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Value) -> V,
        @KeyframesBuilder<Value> keyframes: @escaping (Value) -> some Keyframes<Value>) -> some View {
        let placeholder = PlaceholderContentView<Self>(wrapping: self)
        return KeyframeAnimator(initialValue: initialValue, trigger: trigger,
                                content: { content(placeholder, $0) }, keyframes: keyframes)
    }

    /// Plays keyframes on a value from appearance (looping when `repeating`).
    public func keyframeAnimator<Value, V: View>(
        initialValue: Value, repeating: Bool = true,
        @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Value) -> V,
        @KeyframesBuilder<Value> keyframes: @escaping (Value) -> some Keyframes<Value>) -> some View {
        let placeholder = PlaceholderContentView<Self>(wrapping: self)
        return KeyframeAnimator(initialValue: initialValue, repeating: repeating,
                                content: { content(placeholder, $0) }, keyframes: keyframes)
    }
}
