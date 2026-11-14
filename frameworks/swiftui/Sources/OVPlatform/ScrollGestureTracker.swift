import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Touchpad gesture phases and momentum for back ends that report neither
// (B6-OPENVIEWS). SDL3 delivers a touchpad's two-finger scroll as a stream
// of fractional ("precise") wheel deltas: no began or ended, no momentum
// after the fingers leave. The desktop conventions this follows (a
// touchpad scroll carries the content while the fingers move, then the
// content coasts and slows down) need both, so the host infers them:
//
// - **Gesture.** The first precise delta after a pause begins a gesture;
//   the following ones change it. The gesture ends when the back end sends
//   a precise event without motion (a "stop"), or when no event has come
//   for `endDelay` (three of the gesture's own intervals, 30–100 ms).
// - **Momentum.** At the end the release velocity (the gesture's motion
//   over its last `velocityWindow`) starts a momentum whose speed decays
//   exponentially with `momentumTimeConstant` (0.33 s, the decay of the
//   council's flick in `specs/ide/editor-area.md` H.1): the distance
//   travelled after t seconds is v₀ τ (1 − e^(−t/τ)). Its events come once
//   per display frame (`step`), each carrying the distance since the last,
//   until the speed is below `momentumStopSpeed`. A new touch (any scroll
//   event) cancels it.
//
// Events that already carry phases (a back end that reports them, the
// automation) and wheel notches (`isPrecise` false) pass through as they are.

/// Infers touchpad phases from precise scroll deltas and synthesizes the
/// momentum after a gesture (see the file's header).
public struct ScrollGestureTracker: Sendable {
    /// The tracker's constants.
    public struct Configuration: Sendable, Equatable {
        /// The gesture ends after this many of its typical intervals without
        /// an event, within `minimumEndDelay`…`maximumEndDelay` seconds.
        public var endIntervals = 3.0
        public var minimumEndDelay = 0.03
        public var maximumEndDelay = 0.1
        /// The momentum's speed falls by e every this many seconds.
        public var momentumTimeConstant = 0.33
        /// Release speeds below this (points per second) start no momentum.
        public var minimumMomentumSpeed = 60.0
        /// The momentum ends once its speed is below this.
        public var momentumStopSpeed = 6.0
        /// Release speeds are limited to this.
        public var maximumMomentumSpeed = 12_000.0
        /// The release velocity is the motion over this last part of the gesture.
        public var velocityWindow = 0.1
        /// Seconds between momentum events (the display's frame period).
        public var step = 1.0 / 60

        public init() {}
    }

    private struct Sample: Sendable {
        var time: TimeInterval
        var delta: CGSize
    }

    private struct Gesture: Sendable {
        var window: PlatformWindowID
        var location: CGPoint
        var modifiers: KeyModifiers
        var samples: [Sample]
        var last: TimeInterval { samples.last?.time ?? 0 }
    }

    private struct Momentum: Sendable {
        var window: PlatformWindowID
        var location: CGPoint
        var modifiers: KeyModifiers
        /// Velocity at `start` (points per second, as the deltas).
        var velocity: CGSize
        var start: TimeInterval
        /// Distance delivered so far.
        var delivered: CGSize
        var lastStep: TimeInterval
        var hasBegun: Bool
    }

    private enum State: Sendable {
        case idle
        case gesture(Gesture)
        case momentum(Momentum)
    }

    public var configuration: Configuration
    /// Off: every event passes through unchanged (no phases, no momentum).
    public var isEnabled = true
    private var state = State.idle

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// True while a gesture is followed (fingers on the touchpad).
    public var isTracking: Bool {
        if case .gesture = state { return true }
        return false
    }

    /// True while synthesized momentum is running.
    public var isCoasting: Bool {
        if case .momentum = state { return true }
        return false
    }

    /// The time a gesture without further events ends.
    private func endTime(of g: Gesture) -> TimeInterval {
        let s = g.samples
        var interval = configuration.minimumEndDelay / configuration.endIntervals
        if s.count >= 2 {
            let gaps = zip(s.dropFirst(), s).map { $0.time - $1.time }.sorted()
            interval = gaps[gaps.count / 2]
        }
        let delay = min(configuration.maximumEndDelay, max(configuration.minimumEndDelay, interval * configuration.endIntervals))
        return g.last + delay
    }

    /// When `advance(to:)` has work: the gesture's end, or the momentum's next
    /// step. `nextFrame` (the display's next tick) aligns momentum steps with
    /// frames when it is ahead of the last step.
    public func deadline(nextFrame: TimeInterval? = nil) -> TimeInterval? {
        switch state {
        case .idle: return nil
        case .gesture(let g): return endTime(of: g)
        case .momentum(let m):
            let earliest = m.lastStep + configuration.step / 2
            if let f = nextFrame, f >= earliest { return f }
            return m.lastStep + configuration.step
        }
    }

    /// Takes one event from the back end; returns the events to deliver.
    public mutating func feed(_ e: ScrollEvent) -> [ScrollEvent] {
        guard isEnabled else { return [e] }
        var out: [ScrollEvent] = []
        // Any new scroll input stops the momentum (a touch on the touchpad).
        if case .momentum(let m) = state {
            if m.hasBegun { out.append(momentumEvent(m, delta: .zero, phase: .cancelled, at: e.timestamp)) }
            state = .idle
        }
        if e.hasPhase {
            if case .gesture(let g) = state { out.append(gestureEvent(g, delta: .zero, phase: .ended, at: e.timestamp)) }
            state = .idle
            out.append(e)
            return out
        }
        let moving = e.delta != .zero
        switch state {
        case .gesture(var g) where e.timestamp <= endTime(of: g) + 1e-9:
            // Within a gesture every event counts as precise (a touchpad's
            // delta can happen to be a whole notch).
            if !moving {
                out.append(gestureEvent(g, delta: .zero, phase: .ended, at: e.timestamp))
                startMomentum(after: g, at: e.timestamp)
                return out
            }
            g.location = e.location
            g.modifiers = e.modifiers
            g.samples.append(Sample(time: e.timestamp, delta: e.delta))
            g.samples.removeAll { e.timestamp - $0.time > max(configuration.velocityWindow, 0.25) }
            state = .gesture(g)
            out.append(phased(e, .changed))
            return out
        case .gesture(let g):
            // A late event: the gesture ended without telling.
            out.append(gestureEvent(g, delta: .zero, phase: .ended, at: endTime(of: g)))
            state = .idle
        default:
            break
        }
        guard e.isPrecise else {
            out.append(e)
            return out
        }
        guard moving else { return out }
        state = .gesture(Gesture(window: e.window, location: e.location, modifiers: e.modifiers,
                                 samples: [Sample(time: e.timestamp, delta: e.delta)]))
        out.append(phased(e, .began))
        return out
    }

    /// Runs the gesture's end and the momentum's steps due at `now`.
    public mutating func advance(to now: TimeInterval) -> [ScrollEvent] {
        guard isEnabled else { return [] }
        switch state {
        case .idle:
            return []
        case .gesture(let g):
            let end = endTime(of: g)
            guard now + 1e-9 >= end else { return [] }
            let ended = gestureEvent(g, delta: .zero, phase: .ended, at: end)
            startMomentum(after: g, at: end)
            return [ended] + advance(to: now)
        case .momentum(var m):
            guard now + 1e-9 >= m.lastStep + configuration.step / 2 else { return [] }
            let tau = configuration.momentumTimeConstant
            let t = max(0, now - m.start)
            let k = tau * (1 - exp(-t / tau))
            let total = CGSize(width: m.velocity.width * k, height: m.velocity.height * k)
            let d = CGSize(width: total.width - m.delivered.width, height: total.height - m.delivered.height)
            let speed = hypot(m.velocity.width, m.velocity.height) * exp(-t / tau)
            var out: [ScrollEvent] = []
            if d != .zero {
                out.append(momentumEvent(m, delta: d, phase: m.hasBegun ? .changed : .began, at: now))
                m.hasBegun = true
            }
            m.delivered = total
            m.lastStep = now
            if speed < configuration.momentumStopSpeed {
                if m.hasBegun { out.append(momentumEvent(m, delta: .zero, phase: .ended, at: now)) }
                state = .idle
            } else {
                state = .momentum(m)
            }
            return out
        }
    }

    /// The release velocity of a gesture: its motion over the last
    /// `velocityWindow` before its last event, per second.
    private func releaseVelocity(_ g: Gesture) -> CGSize {
        let recent = g.samples.filter { g.last - $0.time <= configuration.velocityWindow + 1e-9 }
        guard recent.count >= 2, let first = recent.first else { return .zero }
        let span = g.last - first.time
        guard span > 0.001 else { return .zero }
        // The first sample's delta moved the content before the span began.
        let moved = recent.dropFirst().reduce(CGSize.zero) { CGSize(width: $0.width + $1.delta.width, height: $0.height + $1.delta.height) }
        return CGSize(width: moved.width / span, height: moved.height / span)
    }

    private mutating func startMomentum(after g: Gesture, at end: TimeInterval) {
        var v = releaseVelocity(g)
        let speed = hypot(v.width, v.height)
        guard speed >= configuration.minimumMomentumSpeed else {
            state = .idle
            return
        }
        if speed > configuration.maximumMomentumSpeed {
            let k = configuration.maximumMomentumSpeed / speed
            v = CGSize(width: v.width * k, height: v.height * k)
        }
        // The momentum's clock starts when the next gesture event would have
        // come (one typical interval after the last), so the content carries
        // on where it would have been and the wait for the end shows as at
        // most one longer step.
        let s = g.samples
        let interval = s.count >= 2 ? min(configuration.step, (g.last - s[0].time) / Double(s.count - 1)) : 0
        let start = min(end, g.last + interval)
        state = .momentum(Momentum(window: g.window, location: g.location, modifiers: g.modifiers, velocity: v,
                                   start: start, delivered: .zero, lastStep: end, hasBegun: false))
    }

    private func phased(_ e: ScrollEvent, _ phase: ScrollPhase) -> ScrollEvent {
        var e = e
        e.isPrecise = true
        e.phase = phase
        e.momentumPhase = .none
        return e
    }

    private func gestureEvent(_ g: Gesture, delta: CGSize, phase: ScrollPhase, at t: TimeInterval) -> ScrollEvent {
        ScrollEvent(window: g.window, location: g.location, delta: delta, isPrecise: true, modifiers: g.modifiers, timestamp: t,
                    phase: phase)
    }

    private func momentumEvent(_ m: Momentum, delta: CGSize, phase: ScrollPhase, at t: TimeInterval) -> ScrollEvent {
        ScrollEvent(window: m.window, location: m.location, delta: delta, isPrecise: true, modifiers: m.modifiers, timestamp: t,
                    momentumPhase: phase)
    }
}
