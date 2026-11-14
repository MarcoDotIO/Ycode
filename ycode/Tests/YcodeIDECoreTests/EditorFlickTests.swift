import Foundation
import Testing
@testable import YcodeIDECore

/// The Linux editor's flick at the edges (B6-OPENVIEWS; `editor-area.md`
/// H.1, council row 157): `EditorFlick` on the council's input, frame by
/// frame at 60 Hz, against the round 6 targets and the macOS values.
@Suite struct EditorFlickTests {
    /// The council's flick as phased events (H.1): 8 gesture events of 40
    /// points 8.3 ms apart, the gesture's end, then about 1544 points of
    /// momentum decaying with a 0.33 s time constant.
    static func councilFlick(t0: Double) -> [EditorFlick.Step] {
        var out: [EditorFlick.Step] = []
        for i in 0..<8 { out.append(.init(dy: 40, phase: i == 0 ? .began : .changed, time: t0 + Double(i) * 0.0083)) }
        out.append(.init(dy: 0, phase: .ended, time: t0 + 0.062))
        let tau = 0.33, n = 173, total = 1.43
        let dt = total / Double(n)
        let v0 = 1544 / (tau * (1 - exp(-total / tau)))
        for i in 0..<n {
            let a = Double(i) * dt
            out.append(.init(dy: v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)), momentumPhase: i == 0 ? .began : .changed,
                             time: t0 + 0.066 + a))
        }
        out.append(.init(dy: 0, momentumPhase: .ended, time: t0 + 0.066 + total))
        return out
    }

    /// Runs steps through the flick, `burst` (all queued before the first
    /// frame, as the council's harness posts them) or each at its own time;
    /// returns the offset per 60 Hz frame (negative: past the top).
    static func run(_ steps: [EditorFlick.Step], from start: Double, visible: Double, maxOffset: Double = 20_000,
                    burst: Bool, frames: Int = 90) -> (curve: [(t: Double, offset: Double)], flick: EditorFlick) {
        var flick = EditorFlick()
        var offset = start
        var pending = steps
        let t0 = steps.first?.time ?? 0
        var curve: [(Double, Double)] = []
        func apply(_ s: EditorFlick.Step) {
            switch flick.handle(s, offset: offset, maxOffset: maxOffset, visibleHeight: visible) {
            case .scroll(let y): offset = y
            case .bounce(let e): offset = e == .top ? 0 : maxOffset
            case .held, .ignored: break
            }
        }
        if burst { while !pending.isEmpty { apply(pending.removeFirst()) } }
        for f in 0..<frames {
            let t = t0 + Double(f + 1) / 60
            while let s = pending.first, s.time <= t { apply(pending.removeFirst()) }
            if let edge = flick.bounce?.edge {
                let x = flick.overscroll(at: t, frame: 1.0 / 60) ?? 0
                offset = edge == .bottom ? maxOffset + x : -x
            }
            curve.append((t - t0, offset))
        }
        return (curve, flick)
    }

    /// Round 9 (row 220): the stretch is 38 ± 4 (35), at rest by about 730 ms.
    @Test func councilBurstReachesTheTopInOneFrameAndStretchesAbout35() {
        let visible = 770.0
        let (curve, flick) = Self.run(Self.councilFlick(t0: 10), from: 600, visible: visible, burst: true)
        print("B6FLICK burst: " + curve.prefix(48).map { String(format: "%.0f:%.0f", $0.t * 1000, $0.offset) }.joined(separator: " "))
        // The first frame: at the top already (the reference: 600 → 4 at 90 ms, one frame).
        #expect(curve[0].offset <= 0)
        let peak = -(curve.map(\.offset).min() ?? 0)
        let peakTime = curve.first { $0.offset == -peak }?.t ?? 0
        #expect(abs(peak - 38) <= 4, "\(peak)")
        // Peak about 70 ms after reaching the top (one frame at 16.7 ms).
        #expect(peakTime > 0.06 && peakTime < 0.11, "\(peakTime)")
        // No oscillation; at rest within about 700 ms of the first event.
        #expect(curve.allSatisfy { $0.offset <= 0 })
        let rest = curve.first { $0.t > peakTime && $0.offset == 0 }?.t ?? 9
        #expect(rest > 0.55 && rest < 0.85, "\(rest)")
        #expect(!flick.isBouncing && abs(flick.lastPeak - peak) < 1)
        // A new position every frame from the crossing until rest.
        let moving = curve.filter { $0.t <= rest }
        #expect(zip(moving.dropFirst(), moving).allSatisfy { $0.offset != $1.offset || $0.offset == 0 })
    }

    @Test func realTimeFlickCrossesWithTheMomentumsVelocity() {
        let visible = 770.0
        let (curve, _) = Self.run(Self.councilFlick(t0: 10), from: 600, visible: visible, burst: false)
        print("B6FLICK timed: " + curve.prefix(48).map { String(format: "%.0f:%.0f", $0.t * 1000, $0.offset) }.joined(separator: " "))
        let peak = -(curve.map(\.offset).min() ?? 0)
        #expect(abs(peak - 38) <= 4, "\(peak)")
        #expect(curve.allSatisfy { $0.offset >= -peak - 0.01 })
        #expect(curve.last?.offset == 0)
    }

    @Test func theBottomStretchesTheSameWay() {
        let steps = Self.councilFlick(t0: 10).map { s -> EditorFlick.Step in
            var s = s
            s.dy = -s.dy
            return s
        }
        let maxOffset = 5000.0
        let (curve, _) = Self.run(steps, from: maxOffset - 600, visible: 770, maxOffset: maxOffset, burst: true)
        let peak = (curve.map(\.offset).max() ?? 0) - maxOffset
        #expect(abs(peak - 32) <= 4, "\(peak)")
        #expect(curve.last?.offset == maxOffset)
    }

    @Test func fingersOnTheTouchpadStopAtTheEdgeAndWheelNotchesDoNotStretch() {
        var f = EditorFlick()
        #expect(f.handle(.init(dy: 40, phase: .began, time: 0), offset: 20, maxOffset: 1000, visibleHeight: 700) == .scroll(0))
        #expect(f.handle(.init(dy: 40, phase: .changed, time: 0.01), offset: 0, maxOffset: 1000, visibleHeight: 700) == .held)
        #expect(!f.isBouncing)
        var g = EditorFlick()
        #expect(g.handle(.init(dy: 30, time: 0), offset: 10, maxOffset: 1000, visibleHeight: 700) == .scroll(0))
        #expect(g.handle(.init(dy: 30, time: 0.01), offset: 0, maxOffset: 1000, visibleHeight: 700) == .ignored)
        #expect(!g.isBouncing)
    }

    @Test func turningBackDuringTheSpringEndsItAtTheEdge() {
        var f = EditorFlick()
        _ = f.handle(.init(dy: 40, phase: .began, time: 0), offset: 100, maxOffset: 1000, visibleHeight: 700)
        _ = f.handle(.init(dy: 0, phase: .ended, time: 0.03), offset: 60, maxOffset: 1000, visibleHeight: 700)
        #expect(f.handle(.init(dy: 80, momentumPhase: .began, time: 0.04), offset: 60, maxOffset: 1000, visibleHeight: 700) == .bounce(.top))
        #expect(f.handle(.init(dy: 50, momentumPhase: .changed, time: 0.05), offset: 0, maxOffset: 1000, visibleHeight: 700) == .held)
        #expect(f.handle(.init(dy: 10, phase: .began, time: 0.2), offset: 0, maxOffset: 1000, visibleHeight: 700) == .held)
        #expect(f.isBouncing)
        #expect(f.handle(.init(dy: -25, phase: .changed, time: 0.21), offset: 0, maxOffset: 1000, visibleHeight: 700) == .scroll(25))
        #expect(!f.isBouncing)
    }
}
