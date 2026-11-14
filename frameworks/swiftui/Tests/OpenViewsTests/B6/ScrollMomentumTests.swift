import Foundation
import OVPlatform
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// B6-OPENVIEWS: touchpad phases and momentum for back ends that report
// neither (SDL3), routed to the view a gesture began over.

/// The council's flick input (`specs/ide/editor-area.md` H.1): 8 precise
/// events of 40 points 8.3 ms apart, as SDL delivers a two-finger scroll.
private func flick(at t0: TimeInterval, window: PlatformWindowID = 1, location: CGPoint = CGPoint(x: 100, y: 100),
                   points: Double = 40) -> [ScrollEvent] {
    (0..<8).map { i in
        ScrollEvent(window: window, location: location, delta: CGSize(width: 0, height: points), isPrecise: true,
                    timestamp: t0 + Double(i) * 0.0083)
    }
}

/// Feeds events at their times and advances the tracker at 60 Hz up to `end`.
private func drive(_ tracker: inout ScrollGestureTracker, _ events: [ScrollEvent], until end: TimeInterval) -> [ScrollEvent] {
    var out: [ScrollEvent] = []
    var pending = events
    var t = events.first?.timestamp ?? 0
    while t <= end {
        while let e = pending.first, e.timestamp <= t {
            pending.removeFirst()
            out += tracker.feed(e)
        }
        if let d = tracker.deadline(), d <= t { out += tracker.advance(to: t) }
        t += 0.001
    }
    return out
}

@Suite struct ScrollGestureTrackerTests {
    @Test func aTouchpadFlickGetsPhasesAndMomentum() {
        var tracker = ScrollGestureTracker()
        let out = drive(&tracker, flick(at: 1), until: 4)
        let gesture = out.filter { $0.momentumPhase == .none }
        let momentum = out.filter { $0.momentumPhase != .none }
        #expect(gesture.map(\.phase) == [.began] + Array(repeating: .changed, count: 7) + [.ended])
        #expect(gesture.prefix(8).allSatisfy { $0.delta.height == 40 && $0.isPrecise })
        #expect(gesture.last?.delta == .zero)
        // The end: three of the gesture's intervals (25 ms) or 30 ms at least.
        let end = gesture.last?.timestamp ?? 0
        #expect(abs(end - (1 + 7 * 0.0083 + 0.03)) < 0.002, "\(end)")
        #expect(momentum.first?.momentumPhase == .began && momentum.last?.momentumPhase == .ended)
        #expect(momentum.dropFirst().dropLast().allSatisfy { $0.momentumPhase == .changed && $0.phase == .none })
        // v₀ ≈ 280 points in 58 ms ≈ 4800 per second, τ 0.33: about v₀ τ in all.
        let total = momentum.reduce(0) { $0 + $1.delta.height }
        print("B6 momentum: \(momentum.count) events, \(total) points, \(momentum.last!.timestamp - end) s")
        #expect(total > 1450 && total < 1650, "\(total)")
        // Every step moves on (no holds), speeds only fall.
        let steps = momentum.dropLast().map(\.delta.height)
        #expect(steps.allSatisfy { $0 > 0 })
        #expect(zip(steps.dropFirst(), steps).allSatisfy { $0 <= $1 + 1e-9 })
        #expect(!tracker.isTracking && !tracker.isCoasting && tracker.deadline() == nil)
    }

    @Test func momentumStepsComeOncePerFrameAndCarryOnFromTheGesture() {
        var tracker = ScrollGestureTracker()
        let out = drive(&tracker, flick(at: 1), until: 3)
        let times = out.filter { $0.momentumPhase == .began || $0.momentumPhase == .changed }.map(\.timestamp)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.002 }, "\(gaps.prefix(5))")
        // The first momentum step catches up from one interval after the last
        // gesture event: about v₀ × (first step − 1.0664).
        let first = out.first { $0.momentumPhase == .began }!
        let expected = 4820 * (first.timestamp - (1 + 7 * 0.0083 + 0.0083))
        #expect(abs(first.delta.height - expected) < 25, "\(first.delta.height) vs \(expected)")
    }

    @Test func wheelNotchesPassThroughWithoutPhasesOrMomentum() {
        var tracker = ScrollGestureTracker()
        let notches = (0..<5).map { ScrollEvent(window: 1, location: .zero, delta: CGSize(width: 0, height: -10), timestamp: 1 + Double($0) * 0.01) }
        let out = drive(&tracker, notches, until: 2)
        #expect(out == notches)
        #expect(tracker.deadline() == nil)
    }

    @Test func aStopEventEndsTheGestureAtOnce() {
        var tracker = ScrollGestureTracker()
        var events = flick(at: 1)
        events.append(ScrollEvent(window: 1, location: CGPoint(x: 100, y: 100), delta: .zero, isPrecise: true, timestamp: 1.062))
        let out = drive(&tracker, events, until: 1.063)
        #expect(out.last?.phase == .ended && abs((out.last?.timestamp ?? 0) - 1.062) < 1e-9)
        #expect(tracker.isCoasting)
    }

    @Test func aNewTouchCancelsTheMomentum() {
        var tracker = ScrollGestureTracker()
        var events = flick(at: 1)
        events += flick(at: 1.3, points: -10)
        let out = drive(&tracker, events, until: 1.31)
        let cancel = out.firstIndex { $0.momentumPhase == .cancelled }
        let began = out.lastIndex { $0.phase == .began }
        #expect(cancel != nil && began != nil && cancel! < began!)
        #expect(out[began!].delta.height == -10)
    }

    @Test func aSlowReleaseHasNoMomentum() {
        var tracker = ScrollGestureTracker()
        let slow = (0..<4).map { ScrollEvent(window: 1, location: .zero, delta: CGSize(width: 0, height: 0.5), isPrecise: true, timestamp: 1 + Double($0) * 0.02) }
        let out = drive(&tracker, slow, until: 2)
        #expect(out.last?.phase == .ended)
        #expect(!out.contains { $0.momentumPhase != .none })
    }

    @Test func phasedEventsFromTheBackEndPassThrough() {
        var tracker = ScrollGestureTracker()
        let phased = [ScrollEvent(window: 1, location: .zero, delta: CGSize(width: 0, height: 5), isPrecise: true, timestamp: 1, phase: .began),
                      ScrollEvent(window: 1, location: .zero, delta: .zero, isPrecise: true, timestamp: 1.01, phase: .ended),
                      ScrollEvent(window: 1, location: .zero, delta: CGSize(width: 0, height: 9), isPrecise: true, timestamp: 1.02, momentumPhase: .began)]
        #expect(drive(&tracker, phased, until: 2) == phased)
    }

    @Test func turnedOffEverythingPassesThrough() {
        var tracker = ScrollGestureTracker()
        tracker.isEnabled = false
        let events = flick(at: 1)
        #expect(drive(&tracker, events, until: 2) == events)
    }
}

/// Logs every scroll event a view gets.
@MainActor
final class ScrollLog {
    var events: [ScrollEvent] = []
    var deltas: [CGSize] = []
}

@MainActor
@Suite struct ScrollMomentumHostTests {
    @Test func aSurfaceGetsTheWholeGestureAndItsMomentumAtFrameRate() {
        let log = ScrollLog()
        let h = Harness(size: CGSize(width: 400, height: 300)) {
            Color.blue.frame(width: 400, height: 300)
                .textSurfaceScroll(events: { e in log.events.append(e); return true })
        }
        let id = h.windowID
        for e in flick(at: 1, window: id) { h.backend.post(.scroll(e), at: e.timestamp) }
        h.run(until: 4)
        let phases = log.events.map { "\($0.phase)/\($0.momentumPhase)" }
        #expect(phases.first == "began/none" && phases.last == "none/ended")
        #expect(log.events.filter { $0.phase == .ended }.count == 1)
        let momentum = log.events.filter { $0.momentumPhase == .changed }
        #expect(momentum.count > 60)
        #expect(log.events.allSatisfy { $0.location.x == 100 && $0.window == id })
    }

    @Test func aGestureStaysWithTheViewItBeganOver() {
        let left = ScrollLog(), right = ScrollLog()
        let h = Harness(size: CGSize(width: 400, height: 300)) {
            HStack(spacing: 0) {
                Color.blue.frame(width: 200, height: 300).textSurfaceScroll(events: { left.events.append($0); return true })
                Color.red.frame(width: 200, height: 300).textSurfaceScroll(events: { right.events.append($0); return true })
            }
        }
        // The fingers drift from the left view over the right one.
        let events = flick(at: 1, window: h.windowID).enumerated().map { i, e -> ScrollEvent in
            var e = e
            e.location = CGPoint(x: 150 + Double(i) * 15, y: 100)
            return e
        }
        for e in events { h.backend.post(.scroll(e), at: e.timestamp) }
        h.run(until: 4)
        #expect(right.events.isEmpty)
        #expect(left.events.count > 60 && left.events.last?.momentumPhase == .ended)
        // A wheel notch afterwards goes by the pointer again.
        h.backend.post(.scroll(ScrollEvent(window: h.windowID, location: CGPoint(x: 300, y: 100), delta: CGSize(width: 0, height: 10), timestamp: 4.1)), at: 4.1)
        h.run(until: 4.2)
        #expect(right.events.count == 1 && right.events[0].phase == .none)
    }

    @Test func deltaOnlyHandlersGetTheMomentumButNoPhaseEnds() {
        let log = ScrollLog()
        let h = Harness(size: CGSize(width: 400, height: 300)) {
            Color.blue.frame(width: 400, height: 300)
                .textSurfaceScroll { d, _ in log.deltas.append(d); return true }
        }
        for e in flick(at: 1, window: h.windowID) { h.backend.post(.scroll(e), at: e.timestamp) }
        h.run(until: 4)
        #expect(log.deltas.allSatisfy { $0 != .zero })
        let total = log.deltas.reduce(0) { $0 + $1.height }
        #expect(total > 320 + 1450, "\(total)")
    }

    @Test func frameRequestsRunOncePerFrameWithTheFrameTime() {
        let h = Harness(size: CGSize(width: 200, height: 200)) { Color.blue }
        final class Owner {}
        let owner = Owner()
        var times: [TimeInterval] = []
        func again() {
            h.window.services.requestFrame(owner) { t in
                times.append(t)
                if times.count < 10 { again() }
            }
        }
        again()
        h.run(until: 2)
        #expect(times.count == 10)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.001 }, "\(gaps)")
        #expect(!h.window.services.hasFrameCallbacks)
    }

    @Test func momentumCanBeTurnedOff() {
        let log = ScrollLog()
        let h = Harness(size: CGSize(width: 400, height: 300)) {
            Color.blue.frame(width: 400, height: 300).textSurfaceScroll(events: { log.events.append($0); return true })
        }
        h.host.scrollGestures.isEnabled = false
        for e in flick(at: 1, window: h.windowID) { h.backend.post(.scroll(e), at: e.timestamp) }
        h.run(until: 3)
        #expect(log.events.count == 8 && log.events.allSatisfy { !$0.hasPhase })
    }
}

@Suite struct FilledGroupGlyphTests {
    /// The filled clock and tray cover the ink of their outlines, so rows
    /// keep their metrics; the clock's hands are cut out of the disc.
    @Test func filledClockAndTrayMatchTheOutlines() {
        for (outline, filled) in [("clock", "clock.fill"), ("tray", "tray.fill")] {
            guard let a = SymbolArtwork.all[outline], let b = SymbolArtwork.all[filled] else {
                Issue.record("missing \(outline) or \(filled)")
                continue
            }
            #expect(a.bodySize == b.bodySize && a.bodyBaselineOffset == b.bodyBaselineOffset)
        }
        let clock = SymbolArtwork.all["clock.fill"]!
        #expect(clock.operations.contains { if case .knockout = $0 { return true } else { return false } })
    }
}
