import Foundation

// The gesture runtime (round R7; 06-app-and-components.md §7, 10-plan.md
// T-GEST). Ycode-original design; the observable rules it implements are the
// spec's, the rest is marked "our rule" in the README.
//
// Recognizers. Every gesture value makes a recognizer: a small state machine
// fed with pointer samples and timer ticks. Its phase is `possible` (it may
// still recognize), `active` (a continuous gesture has started: a drag past
// its minimum distance), `ended` (recognized; for a tap at touch-up) or
// `failed`. Recognizers do not call user code while they process input;
// `flush()` delivers what changed since the last flush (`onChanged`,
// `onEnded`, `updating` callbacks), and `cancel()` resets (a `@GestureState`
// goes back to its initial value). The arbiter decides who may flush.
//
// Arbitration (a session per press, see `GestureSession`):
//  - The attachments on the hit view and its ancestors take part, innermost
//    first. `.gesture` of an inner view has priority over an outer one; on
//    one view, the modifier applied first (innermost) has priority;
//    `.highPriorityGesture` moves an outer gesture ahead of everything inside
//    it; `.simultaneousGesture` takes part without excluding or being excluded.
//  - The first exclusive member to become active or to end wins, unless a
//    member of higher priority is still possible *and defers* lower ones (a
//    multi-tap between its taps); members that end on the same input are
//    ranked by priority. The winner cancels every other exclusive member.
//  - A member that is still possible may deliver provisional values (a long
//    press reports "pressing" at touch-down).

/// A pointer sample in window (root) coordinates.
package struct PointerSample: Equatable {
    package enum Phase: Equatable { case down, moved, up, cancelled }
    package var pointer: Int
    package var phase: Phase
    package var location: CGPoint
    package var time: TimeInterval
    package var isTouch: Bool

    package init(pointer: Int = 0, phase: Phase, location: CGPoint, time: TimeInterval, isTouch: Bool = false) {
        self.pointer = pointer
        self.phase = phase
        self.location = location
        self.time = time
        self.isTouch = isTouch
    }
}

/// Input of a recognizer.
package enum GestureInput: Equatable {
    case pointer(PointerSample)
    /// Time passed without input (timer deadlines).
    case tick(TimeInterval)

    package var time: TimeInterval {
        switch self {
        case .pointer(let p): return p.time
        case .tick(let t): return t
        }
    }
}

/// Where a recognizer is.
package enum GesturePhase: Equatable {
    case possible
    case active
    case ended
    case failed

    package var isResolved: Bool { self == .ended || self == .failed }
}

/// What a session knows about the view a gesture is attached to.
package struct GestureContext {
    /// The view's frame in window coordinates when the press began.
    package var frame: CGRect
    package init(frame: CGRect) { self.frame = frame }

    /// A window point in the view's local coordinates.
    package func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
}

/// The non-generic face of a recognizer.
@MainActor
package protocol AnyGestureRecognizer: AnyObject {
    var phase: GesturePhase { get }
    /// True while possible and wanting lower-priority members to wait.
    var defersLowerPriority: Bool { get }
    /// The next time the recognizer needs a tick.
    var deadline: TimeInterval? { get }
    func handle(_ input: GestureInput)
    /// Delivers callbacks for what changed since the last flush.
    func flush()
    /// Gives up: fails if unresolved, resets callbacks' state.
    func cancel()
}

/// Base class of recognizers. Values are carried untyped inside the runtime
/// (each gesture's typed value is restored at its callbacks), which keeps the
/// recognizer classes non-generic.
@MainActor
package class GestureRecognizer: AnyGestureRecognizer {
    package var phase: GesturePhase = .possible
    /// The value while active and once ended.
    package var value: Any?
    /// A value reported while still possible (e.g. a long press's
    /// "pressing"); nil when there is none.
    package var provisionalValue: Any?
    package var context: GestureContext

    package init(context: GestureContext) { self.context = context }

    package var defersLowerPriority: Bool { false }
    package var deadline: TimeInterval? { nil }
    package func handle(_ input: GestureInput) {}
    package func flush() {}
    package func cancel() {
        if !phase.isResolved { phase = .failed }
    }

    /// The value callbacks see now: the value when active or ended,
    /// otherwise the provisional value.
    package var currentValue: Any? {
        switch phase {
        case .active, .ended: return value
        case .possible: return provisionalValue
        case .failed: return nil
        }
    }

    package func fail() {
        if !phase.isResolved { phase = .failed }
    }
}

/// A recognizer that forwards to another one, mapping its value.
@MainActor
package class WrappingRecognizer: GestureRecognizer {
    package let base: GestureRecognizer
    package let transform: (Any) -> Any

    package init(base: GestureRecognizer, transform: @escaping (Any) -> Any = { $0 }) {
        self.base = base
        self.transform = transform
        super.init(context: base.context)
    }

    override package var defersLowerPriority: Bool { base.defersLowerPriority }
    override package var deadline: TimeInterval? { base.deadline }

    override package func handle(_ input: GestureInput) {
        base.handle(input)
        sync()
    }

    package func sync() {
        phase = base.phase
        value = base.value.map(transform)
        provisionalValue = base.provisionalValue.map(transform)
    }

    override package func flush() {
        base.flush()
        sync()
    }

    override package func cancel() {
        base.cancel()
        sync()
    }
}

/// A wrapper that maps typed values.
@MainActor
package func mapping<A, B>(_ base: GestureRecognizer, _ f: @escaping (A) -> B) -> GestureRecognizer {
    WrappingRecognizer(base: base) { f($0 as! A) } // swiftlint:disable:this force_cast
}

// MARK: - Making recognizers from gesture values

/// A gesture the runtime implements directly.
/// The recognizer's values are the gesture's `Value`s.
@MainActor
package protocol PrimitiveGesture: Gesture {
    func _makeRecognizer(context: GestureContext) -> GestureRecognizer
}

@MainActor
package enum GestureFactory {
    /// The recognizer of any gesture: primitives make their own; custom
    /// gestures make the recognizer of their body (whose value is theirs).
    package static func make<G: Gesture>(_ gesture: G, context: GestureContext) -> GestureRecognizer {
        if let p = gesture as? any PrimitiveGesture { return p._makeRecognizer(context: context) }
        return make(gesture.body, context: context)
    }
}

// MARK: - Sessions

/// How an attachment takes part in arbitration.
package enum GestureAttachmentKind: Equatable {
    case normal
    case highPriority
    case simultaneous
}

/// A gesture attached to a view (the state of a gesture modifier's node).
@MainActor
package final class GestureAttachment {
    package var kind: GestureAttachmentKind
    package var mask: GestureMask
    package var isEnabled: Bool
    package var make: (GestureContext) -> GestureRecognizer

    package init(kind: GestureAttachmentKind, mask: GestureMask, isEnabled: Bool,
                 make: @escaping (GestureContext) -> GestureRecognizer) {
        self.kind = kind
        self.mask = mask
        self.isEnabled = isEnabled
        self.make = make
    }
}

/// The recognizers of one press (and of the presses a multi-tap waits for).
@MainActor
package final class GestureSession {
    package struct Member {
        package let recognizer: any AnyGestureRecognizer
        package let simultaneous: Bool
        package var cancelled = false
    }

    package private(set) var members: [Member]
    /// Index of the exclusive member that won.
    package private(set) var winner: Int?
    /// Pointers currently down in this session.
    package private(set) var pointersDown: Set<Int> = []
    /// The views whose gestures the session runs (R13).
    package var nodes: Set<ObjectIdentifier> = []

    package init(members: [Member]) { self.members = members }

    /// True once every member is resolved and no pointer is down.
    package var isFinished: Bool {
        pointersDown.isEmpty && members.allSatisfy { $0.cancelled || $0.recognizer.phase.isResolved }
    }

    package var deadline: TimeInterval? {
        members.filter { !$0.cancelled }.compactMap { $0.recognizer.deadline }.min()
    }

    package func handle(_ input: GestureInput) {
        if case .pointer(let p) = input {
            switch p.phase {
            case .down: pointersDown.insert(p.pointer)
            case .up, .cancelled: pointersDown.remove(p.pointer)
            case .moved: break
            }
        }
        for m in members where !m.cancelled { m.recognizer.handle(input) }
        resolve()
    }

    /// Cancels everything (the view went away, the window lost the pointer).
    package func cancelAll() {
        for i in members.indices where !members[i].cancelled {
            members[i].cancelled = true
            members[i].recognizer.cancel()
        }
        pointersDown = []
    }

    private func resolve() {
        if winner == nil {
            var deferring = false
            for (i, m) in members.enumerated() where !m.simultaneous && !m.cancelled {
                let r = m.recognizer
                if (r.phase == .active || r.phase == .ended) && !deferring {
                    winner = i
                    break
                }
                if r.phase == .possible && r.defersLowerPriority { deferring = true }
            }
            if let w = winner {
                for i in members.indices where i != w && !members[i].simultaneous && !members[i].cancelled {
                    members[i].cancelled = true
                    members[i].recognizer.cancel()
                }
            }
        }
        for i in members.indices where !members[i].cancelled {
            let r = members[i].recognizer
            if members[i].simultaneous || i == winner {
                r.flush()
            } else if r.phase == .possible {
                // Provisional values only.
                r.flush()
            } else if r.phase == .failed {
                members[i].cancelled = true
                r.cancel()
            }
        }
    }
}
