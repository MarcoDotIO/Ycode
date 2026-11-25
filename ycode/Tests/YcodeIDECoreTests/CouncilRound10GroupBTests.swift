import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 10, group B, row 248 (`specs/ide/fidelity-council.md`
/// "Round 10"; `editor-area.md` H.2): the inspector's slide starts about
/// +85 ms (hide) and +180 ms (show) after the press, a hide ease-out over
/// about 200 ms and a show ease-in-out over about 230, with a new position
/// on every display frame. Both IDEs read these values.
@Suite struct CouncilRound10GroupBTests {
    /// The frames a 100 Hz display draws from the press (at 10, 20, ... ms):
    /// (time in ms, progress).
    static func frames(show: Bool, hz: Double = 100) -> [(ms: Double, p: Double)] {
        var clock = InspectorSlideClock(show: show, press: 0)
        var out: [(Double, Double)] = []
        var t = 0.0
        while !clock.isFinished, t < 2 {
            t += 1 / hz
            out.append((t * 1000, clock.progress(at: t)))
        }
        return out
    }

    @Test func startsAndLengths() {
        // Beta 5's catalogue (P-192) supersedes round 10's 75 + 200 and 170 + 230.
        let hide = Motion.inspector(show: false), show = Motion.inspector(show: true)
        #expect(EditorMetrics.inspectorSlideDelay(show: false) == hide.delay && EditorMetrics.inspectorSlideDelay(show: true) == show.delay)
        #expect(EditorMetrics.inspectorSlideMotion(show: false) == hide.duration && EditorMetrics.inspectorSlideMotion(show: true) == show.duration)
        for (show, start, length, positions) in [(false, hide.delay * 1000 + 10, hide.duration * 1000, 7),
                                                 (true, show.delay * 1000 + 10, show.duration * 1000, 10)] {
            let f = Self.frames(show: show)
            let moving = f.filter { $0.p > 0 }
            let first = moving.first?.ms ?? 0, last = f.first { $0.p >= 1 }?.ms ?? 0
            // The first moving frame within a frame of the target; the slide as long as the target.
            #expect(abs(first - start) <= 10, "\(show ? "show" : "hide") starts at \(first)")
            #expect(abs(last - first - length) <= 15, "\(show ? "show" : "hide") \(first)–\(last)")
            // A new position on every frame, at least the reference's count.
            let travel = 259.0
            let xs = moving.map { ($0.p * travel).rounded() }
            let distinct = zip(xs.dropFirst(), xs).filter { $0.0 != $0.1 }.count + 1
            #expect(distinct >= positions && distinct >= 18, "\(show ? "show" : "hide"): \(distinct) positions")
            print(String(format: "R10B %@: first motion %.0f ms, at rest %.0f ms (slide %.0f ms), %d positions at 100 Hz",
                         show ? "show" : "hide", first, last, last - first, distinct))
        }
        // Round 10's show starting 80–110 ms after the hide is superseded:
        // the parity run's show starts 51 ms before the hide (P-192).
    }

    @Test func curves() {
        #expect(EditorMetrics.inspectorSlideCurve(show: false) == EditorMetrics.inspectorSlideEaseOut)
        #expect(EditorMetrics.inspectorSlideCurve(show: true) == EditorMetrics.inspectorSlideEaseInOut)
        func p(_ show: Bool, _ ms: Double) -> Double {
            EditorMetrics.inspectorSlideProgress(elapsed: EditorMetrics.inspectorSlideDelay(show: show) + ms / 1000, show: show)
        }
        // Hide: a fast start (round 10's shape; P-192's 275 ms of motion).
        #expect((0.1...0.35).contains(p(false, 27)) && p(false, 78) >= 0.4 && p(false, 250) >= 0.97)
        // Show: slow at both ends, half the travel about the middle.
        let half = Motion.inspector(show: true).duration * 500
        #expect(p(true, 20) < 0.06 && (0.4...0.6).contains(p(true, half)) && p(true, half * 2 - 20) > 0.97)
    }
}
