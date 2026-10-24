import Foundation

// The animation runtime (05-animation.md §1, §4, §7; 10-plan.md T-ANIM).
//
// Time comes from an injectable source. The headless host uses a manual
// clock that advances in display frames (60 Hz, 05 §7); a real display link
// arrives with the platform host (R7).
//
// An `Animator` holds one animatable value of a view: its model value (what
// the views say) and its presented value (what is rendered). When the model
// value changes in a transaction with an animation, a run starts from the
// current presented value towards the new model value (05 §4.2: retargeting
// starts from the presentation value; a spring following a spring also keeps
// the velocity). A change without animation moves the presented value by the
// same amount, so a running animation keeps its remaining distance. Every
// display frame the graph samples the active animators.
//
// Completion (05 §4): a transaction's completion handlers wait for every run
// the transaction started — `.logicallyComplete` until each is logically
// complete, `.removed` until each has finished or was replaced. A
// transaction that starts no run completes at the end of its update.

/// A source of the current time for animations.
@MainActor
package protocol AnimationTimeSource: AnyObject {
    var now: TimeInterval { get }
}

/// A clock advanced by hand, one display frame at a time (headless host).
@MainActor
package final class ManualAnimationClock: AnimationTimeSource {
    package let framesPerSecond: Double
    package private(set) var frame = 0
    private var offset: TimeInterval = 0

    package init(framesPerSecond: Double = 60) { self.framesPerSecond = framesPerSecond }

    package var now: TimeInterval { offset + Double(frame) / framesPerSecond }
    package var frameDuration: TimeInterval { 1 / framesPerSecond }

    /// Moves to the next display frame(s).
    package func advance(frames: Int = 1) { frame += frames }

    /// Moves by an arbitrary amount (between frames).
    package func advance(by seconds: TimeInterval) { offset += seconds }
}

/// Something the graph samples once per display frame.
@MainActor
package protocol AnimationDriver: AnyObject {
    /// Advances to `time`; true if what it drives changed.
    func sample(at time: TimeInterval) -> Bool
    /// False once finished (the graph then forgets the driver).
    var isActive: Bool { get }
    /// The view node whose value this drives (removal transitions wait for
    /// the drivers in a removed subtree).
    var owner: ViewNode? { get }
    /// Called after a sample that changed something.
    var onChange: (() -> Void)? { get }
    /// Stops at once (its owner went away).
    func cancel()
}

/// A completion handler of a transaction, with the runs it waits for.
/// Created wherever a transaction is built; used on the main actor only.
package final class AnimationCompletionRecord: @unchecked Sendable {
    package let criteria: AnimationCompletionCriteria
    package let action: () -> Void
    private var pendingLogical = 0
    private var pendingRemoved = 0
    private var sealed = false
    private var fired = false
    private weak var graph: ViewGraph?

    package init(criteria: AnimationCompletionCriteria, action: @escaping () -> Void) {
        self.criteria = criteria
        self.action = action
    }

    @MainActor package func register(graph: ViewGraph) {
        self.graph = graph
        pendingLogical += 1
        pendingRemoved += 1
    }

    @MainActor package func runLogicallyCompleted() {
        pendingLogical -= 1
        check()
    }

    @MainActor package func runRemoved(wasLogicallyComplete: Bool) {
        if !wasLogicallyComplete { pendingLogical -= 1 }
        pendingRemoved -= 1
        check()
    }

    /// The update that applied the transaction is over: no more runs join.
    @MainActor package func seal(graph: ViewGraph) {
        if self.graph == nil { self.graph = graph }
        guard !sealed else { return }
        sealed = true
        check()
    }

    @MainActor private func check() {
        guard sealed, !fired, let graph else { return }
        let done = criteria == .removed ? pendingRemoved <= 0 : pendingLogical <= 0
        if done {
            fired = true
            graph.queueCompletion(action)
        }
    }
}

/// One animatable value: its model value, presented value and the run that
/// moves one towards the other.
@MainActor
package final class Animator<V: VectorArithmetic>: AnimationDriver {
    private struct Run {
        var animation: Animation
        var from: V
        var delta: V
        var begin: TimeInterval
        var context: AnimationContext<V>
        var records: [AnimationCompletionRecord]
        var logicallyComplete = false
    }

    package private(set) var model: V
    package private(set) var presented: V
    package weak var owner: ViewNode?
    package var onChange: (() -> Void)?
    private var run: Run?
    private var lastTime: TimeInterval = 0

    package init(_ value: V, owner: ViewNode?) {
        model = value
        presented = value
        self.owner = owner
    }

    package var isActive: Bool { run != nil }

    /// The animation of the current run.
    package var animation: Animation? { run?.animation }

    /// Sets a new model value. With an animation in `transaction`, a run
    /// starts (or retargets) from the presented value; without one the
    /// presented value moves by the same amount as the model value.
    package func update(to value: V, transaction: Transaction, graph: ViewGraph) {
        update(to: value, animation: transaction.animation, completions: transaction.completions, graph: graph)
    }

    package func update(to value: V, animation: Animation?, completions: [AnimationCompletionRecord] = [],
                        graph: ViewGraph) {
        guard value != model else { return }
        guard let animation else {
            let shift = value - model
            model = value
            presented += shift
            run?.from += shift
            return
        }
        let now = graph.currentTime
        var context = AnimationContext<V>(environment: owner?.environment ?? EnvironmentValues())
        if let old = run {
            var oldContext = old.context
            if animation.shouldMerge(previous: old.animation, value: old.delta, time: now - old.begin, context: &oldContext) {
                context.state = oldContext.state
            }
            finish(old)
        }
        for r in completions { r.register(graph: graph) }
        model = value
        run = Run(animation: animation, from: presented, delta: value - presented, begin: now,
                  context: context, records: completions)
        lastTime = now
        graph.activate(self)
    }

    /// The current velocity (zero when not animating).
    package var velocity: V {
        guard let r = run else { return .zero }
        return r.animation.velocity(value: r.delta, time: lastTime - r.begin, context: r.context) ?? .zero
    }

    package func sample(at time: TimeInterval) -> Bool {
        guard var r = run else { return false }
        lastTime = time
        let old = presented
        if let offset = r.animation.animate(value: r.delta, time: max(0, time - r.begin), context: &r.context) {
            presented = r.from + offset
            if r.context.isLogicallyComplete && !r.logicallyComplete {
                r.logicallyComplete = true
                for c in r.records { c.runLogicallyCompleted() }
            }
            run = r
        } else {
            presented = model
            run = nil
            finish(r)
        }
        return presented != old
    }

    package func cancel() { stop() }

    /// Stops the run at once (the presented value jumps to the model value).
    package func stop() {
        guard let r = run else { return }
        run = nil
        presented = model
        finish(r)
    }

    private func finish(_ r: Run) {
        for c in r.records { c.runRemoved(wasLogicallyComplete: r.logicallyComplete) }
    }
}

/// A driver that calls `step` with the time of every frame until it
/// returns false (keyframe animators, phase sequences).
@MainActor
package final class FrameDriver: AnimationDriver {
    package weak var owner: ViewNode?
    package var onChange: (() -> Void)?
    private let step: (TimeInterval) -> (changed: Bool, active: Bool)
    package private(set) var isActive = true

    package init(owner: ViewNode?, step: @escaping (TimeInterval) -> (changed: Bool, active: Bool)) {
        self.owner = owner
        self.step = step
    }

    package func sample(at time: TimeInterval) -> Bool {
        guard isActive else { return false }
        let r = step(time)
        isActive = r.active
        return r.changed
    }

    package func cancel() { isActive = false }
}
