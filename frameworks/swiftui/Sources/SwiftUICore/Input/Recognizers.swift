import Foundation

// Recognizers of the gestures the `SwiftUI` module declares (drag, long
// press, sequence, `updating`, button presses). They live here, beside the
// runtime: a class can be subclassed outside its module only when it is
// `open` (public API), and the recognizer classes are package API. The
// public gesture values that make them are in the `SwiftUI` module
// (Input/Gestures.swift).

/// A drag's state as the recognizer measures it (window or local points).
package struct DragSample: Equatable {
    package var time: TimeInterval
    package var location: CGPoint
    package var startLocation: CGPoint
    package var velocity: CGSize
}

/// The drag state machine. Velocity is the displacement over the samples of
/// the last 0.1 s (at least the last two), divided by their time span (our
/// estimator; the spec gives magnitudes, not the method).
package final class DragRecognizer: GestureRecognizer {
    nonisolated package static let predictionInterval: CGFloat = 0.25
    nonisolated package static let velocityWindow: TimeInterval = 0.1

    let minimumDistance: CGFloat
    let global: Bool
    private var start: CGPoint?
    private var samples: [(t: TimeInterval, p: CGPoint)] = []

    package init(minimumDistance: CGFloat, global: Bool, context: GestureContext) {
        self.minimumDistance = max(0, minimumDistance)
        self.global = global
        super.init(context: context)
    }

    private func point(_ p: CGPoint) -> CGPoint { global ? p : context.local(p) }

    private var velocity: CGSize {
        guard let last = samples.last else { return .zero }
        let window = samples.filter { $0.t >= last.t - Self.velocityWindow - 1e-9 }
        let first = window.count >= 2 ? window[0] : (samples.count >= 2 ? samples[samples.count - 2] : last)
        let dt = last.t - first.t
        guard dt > 0 else { return .zero }
        return CGSize(width: (last.p.x - first.p.x) / dt, height: (last.p.y - first.p.y) / dt)
    }

    private func makeValue(_ s: PointerSample) -> DragSample {
        DragSample(time: s.time, location: point(s.location), startLocation: point(start ?? s.location),
                   velocity: velocity)
    }

    override package func handle(_ input: GestureInput) {
        guard !phase.isResolved, case .pointer(let s) = input else { return }
        switch s.phase {
        case .down:
            guard start == nil else { return }
            start = s.location
            samples = [(s.time, s.location)]
            if minimumDistance == 0 {
                phase = .active
                value = makeValue(s)
            }
        case .moved:
            guard let start else { return }
            samples.append((s.time, s.location))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            if phase == .possible, hypot(s.location.x - start.x, s.location.y - start.y) >= minimumDistance {
                phase = .active
            }
            if phase == .active { value = makeValue(s) }
        case .up:
            guard start != nil else { return }
            if phase == .active {
                samples.append((s.time, s.location))
                value = makeValue(s)
                phase = .ended
            } else {
                fail()
            }
        case .cancelled:
            fail()
        }
    }
}

package class LongPressRecognizer: GestureRecognizer {
    let minimumDuration: Double
    let maximumDistance: CGFloat
    private var down: (t: TimeInterval, p: CGPoint)?
    /// True while the press is physically down.
    package private(set) var isDown = false

    package init(minimumDuration: Double, maximumDistance: CGFloat, context: GestureContext) {
        self.minimumDuration = max(0, minimumDuration)
        self.maximumDistance = maximumDistance
        super.init(context: context)
    }

    override package var deadline: TimeInterval? {
        guard phase == .possible, let down else { return nil }
        return down.t + minimumDuration
    }

    override package func handle(_ input: GestureInput) {
        switch input {
        case .tick(let t):
            if phase == .possible, let down, t >= down.t + minimumDuration - 1e-9 { recognize() }
        case .pointer(let s):
            switch s.phase {
            case .down:
                guard down == nil, phase == .possible else { return }
                down = (s.time, s.location)
                isDown = true
                provisionalValue = true
                if minimumDuration == 0 { recognize() }
            case .moved:
                if phase == .possible, let down,
                   hypot(s.location.x - down.p.x, s.location.y - down.p.y) > maximumDistance { fail() }
            case .up, .cancelled:
                isDown = false
                if phase == .possible { fail() }
            }
        }
    }

    private func recognize() {
        phase = .ended
        value = true
    }
}

/// `onLongPressGesture(…perform:onPressingChanged:)`: pressing true at
/// touch-down, the action at the duration, pressing false at touch-up (06 §7).
package final class LongPressActionRecognizer: LongPressRecognizer {
    let action: () -> Void
    let pressingChanged: ((Bool) -> Void)?
    private var reportedPressing = false
    private var performed = false

    package init(minimumDuration: Double, maximumDistance: CGFloat, context: GestureContext,
                 action: @escaping () -> Void, pressingChanged: ((Bool) -> Void)?) {
        self.action = action
        self.pressingChanged = pressingChanged
        super.init(minimumDuration: minimumDuration, maximumDistance: maximumDistance, context: context)
    }

    override package func flush() {
        let pressing = isDown && phase != .failed
        if pressing != reportedPressing {
            reportedPressing = pressing
            pressingChanged?(pressing)
        }
        if phase == .ended, !performed {
            performed = true
            action()
        }
    }

    override package func cancel() {
        super.cancel()
        if reportedPressing {
            reportedPressing = false
            pressingChanged?(false)
        }
    }
}

/// Runs the second recognizer from the moment the first ends (a press still
/// down is replayed to it as a touch-down where the pointer is). If the
/// second fails, the sequence ends with `.second(first, nil)` (our rule).
package final class SequenceRecognizer: GestureRecognizer {
    let a: GestureRecognizer
    let b: GestureRecognizer
    let wrapFirst: (Any) -> Any
    let wrapSecond: (Any, Any?) -> Any
    private var started = false
    private var last: PointerSample?

    package init(_ a: GestureRecognizer, _ b: GestureRecognizer, first: @escaping (Any) -> Any,
                 second: @escaping (Any, Any?) -> Any) {
        self.a = a
        self.b = b
        wrapFirst = first
        wrapSecond = second
        super.init(context: a.context)
    }

    override package var deadline: TimeInterval? { started ? b.deadline : a.deadline }
    override package var defersLowerPriority: Bool { started ? false : a.defersLowerPriority }

    override package func handle(_ input: GestureInput) {
        if case .pointer(let s) = input { last = s }
        if !started {
            a.handle(input)
            switch a.phase {
            case .possible:
                provisionalValue = a.provisionalValue.map(wrapFirst)
            case .active:
                phase = .active
                value = a.value.map(wrapFirst)
            case .failed:
                phase = .failed
            case .ended:
                started = true
                if var s = last, s.phase != .up, s.phase != .cancelled {
                    s.phase = .down
                    b.handle(.pointer(s))
                }
                syncSecond()
            }
        } else if !phase.isResolved {
            b.handle(input)
            syncSecond()
        }
    }

    private func syncSecond() {
        guard let av = a.value else { return }
        switch b.phase {
        case .possible, .active:
            phase = .active
            value = wrapSecond(av, b.currentValue)
        case .ended:
            phase = .ended
            value = wrapSecond(av, b.value)
        case .failed:
            phase = .ended
            value = wrapSecond(av, nil)
        }
    }

    override package func flush() {
        a.flush()
        if started { b.flush() }
    }

    override package func cancel() {
        a.cancel()
        b.cancel()
        super.cancel()
    }
}

/// Calls the updating body with each new value; resets the state once when
/// the gesture ends, fails or is cancelled.
package final class UpdatingRecognizer: WrappingRecognizer {
    let update: (Any) -> Void
    let reset: () -> Void
    private var dirty = false

    package init(base: GestureRecognizer, update: @escaping (Any) -> Void, reset: @escaping () -> Void) {
        self.update = update
        self.reset = reset
        super.init(base: base)
    }

    override package func flush() {
        super.flush()
        switch phase {
        case .possible, .active:
            if let v = currentValue {
                update(v)
                dirty = true
            }
        case .ended, .failed:
            resetOnce()
        }
    }

    override package func cancel() {
        super.cancel()
        resetOnce()
    }

    private func resetOnce() {
        if dirty {
            dirty = false
            reset()
        }
    }
}

/// A button press: pressed while down (provisional), fails if the pointer
/// leaves the frame by more than 10 pt (our slop), ends on release inside.
package final class PressRecognizer: GestureRecognizer {
    package static let slop: CGFloat = 10
    let onPressed: (Bool) -> Void
    let onAction: () -> Void
    private var isDown = false
    private var reported = false
    private var performed = false

    package init(context: GestureContext, onPressed: @escaping (Bool) -> Void, onAction: @escaping () -> Void) {
        self.onPressed = onPressed
        self.onAction = onAction
        super.init(context: context)
    }

    private func inside(_ p: CGPoint) -> Bool { context.frame.insetBy(dx: -Self.slop, dy: -Self.slop).contains(p) }

    override package func handle(_ input: GestureInput) {
        guard case .pointer(let s) = input, phase == .possible else { return }
        switch s.phase {
        case .down:
            isDown = true
            provisionalValue = true
        case .moved:
            if !inside(s.location) { fail() }
        case .up:
            isDown = false
            if inside(s.location) {
                phase = .ended
                value = ()
            } else {
                fail()
            }
        case .cancelled:
            fail()
        }
    }

    override package func flush() {
        let pressed = isDown && phase == .possible
        if pressed != reported {
            reported = pressed
            onPressed(pressed)
        }
        if phase == .ended, !performed {
            performed = true
            onAction()
        }
    }

    override package func cancel() {
        super.cancel()
        if reported {
            reported = false
            onPressed(false)
        }
    }
}

/// Follows one press from down to up in the view's local coordinates, active
/// from the press (round R8: text selection, slider thumbs, menus). Events
/// are delivered when the arbiter lets the recognizer flush, in order.
package final class PointerTrackRecognizer: GestureRecognizer {
    package enum Event: Equatable {
        case down(CGPoint, TimeInterval)
        case moved(CGPoint, TimeInterval)
        case up(CGPoint, TimeInterval)
        case cancelled
    }

    let handler: (Event) -> Void
    /// Decides at the press whether to track it (false: the gesture fails
    /// and other gestures may take the press).
    let accepts: (CGPoint) -> Bool
    private var pending: [Event] = []
    private var delivered = false
    private var ended = false

    package init(context: GestureContext, accepts: @escaping (CGPoint) -> Bool = { _ in true },
                 handler: @escaping (Event) -> Void) {
        self.handler = handler
        self.accepts = accepts
        super.init(context: context)
    }

    override package func handle(_ input: GestureInput) {
        guard case .pointer(let s) = input, !phase.isResolved || phase == .active else { return }
        let p = context.local(s.location)
        switch s.phase {
        case .down:
            guard phase == .possible, pending.isEmpty, !delivered else { return }
            guard accepts(p) else {
                fail()
                return
            }
            phase = .active
            value = ()
            pending.append(.down(p, s.time))
        case .moved:
            guard phase == .active else { return }
            pending.append(.moved(p, s.time))
        case .up:
            guard phase == .active else { return }
            pending.append(.up(p, s.time))
            phase = .ended
        case .cancelled:
            if phase == .active { pending.append(.cancelled) }
            fail()
        }
    }

    override package func flush() {
        let events = pending
        pending = []
        for e in events {
            delivered = true
            if case .up = e { ended = true }
            if case .cancelled = e { ended = true }
            handler(e)
        }
    }

    override package func cancel() {
        let wasTracking = (delivered || !pending.isEmpty) && !ended
        super.cancel()
        pending = []
        if wasTracking {
            ended = true
            handler(.cancelled)
        }
    }
}

/// A horizontal drag that starts at the leading edge of a view (round R9:
/// the navigation stack's back swipe, 06 §2.1). It fails at touch-down
/// outside the first `edgeWidth` points, when the press moves 10 points
/// vertically before it moves 10 points horizontally, or on release before
/// it started; it becomes active once the press moved 10 points towards the
/// trailing side. While possible it holds nothing back, so taps and
/// vertical scrolling near the edge keep working. Values are the drag's
/// samples in the view's local coordinates.
package final class EdgeSwipeRecognizer: GestureRecognizer {
    package static let threshold: CGFloat = 10
    let edgeWidth: CGFloat
    let handler: (DragSample?, Bool) -> Void
    private var start: CGPoint?
    private var samples: [(t: TimeInterval, p: CGPoint)] = []
    private var pending: [(DragSample?, Bool)] = []

    package init(edgeWidth: CGFloat, context: GestureContext, handler: @escaping (DragSample?, Bool) -> Void) {
        self.edgeWidth = edgeWidth
        self.handler = handler
        super.init(context: context)
    }

    private func sample(_ s: PointerSample) -> DragSample {
        let p = context.local(s.location)
        var v = CGSize.zero
        if let last = samples.last {
            let window = samples.filter { $0.t >= last.t - DragRecognizer.velocityWindow - 1e-9 }
            if let first = window.first, last.t > first.t {
                v = CGSize(width: (last.p.x - first.p.x) / (last.t - first.t), height: (last.p.y - first.p.y) / (last.t - first.t))
            }
        }
        return DragSample(time: s.time, location: p, startLocation: start ?? p, velocity: v)
    }

    override package func handle(_ input: GestureInput) {
        guard case .pointer(let s) = input, !phase.isResolved || phase == .active else { return }
        let p = context.local(s.location)
        switch s.phase {
        case .down:
            guard phase == .possible, start == nil else { return }
            guard p.x >= 0, p.x <= edgeWidth else {
                fail()
                return
            }
            start = p
            samples = [(s.time, p)]
        case .moved:
            guard let start else { return }
            samples.append((s.time, p))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            if phase == .possible {
                let dx = p.x - start.x, dy = p.y - start.y
                if abs(dy) >= Self.threshold && abs(dy) > dx { fail(); return }
                if dx >= Self.threshold { phase = .active; value = () }
            }
            if phase == .active { pending.append((sample(s), false)) }
        case .up:
            guard start != nil else { return }
            if phase == .active {
                samples.append((s.time, p))
                pending.append((sample(s), true))
                phase = .ended
            } else {
                fail()
            }
        case .cancelled:
            if phase == .active { pending.append((nil, true)) }
            fail()
        }
    }

    override package func flush() {
        let events = pending
        pending = []
        for (s, end) in events { handler(s, end) }
    }

    override package func cancel() {
        let wasActive = phase == .active
        super.cancel()
        pending = []
        if wasActive { handler(nil, true) }
    }
}
