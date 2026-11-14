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
        #expect(EditorMetrics.inspectorSlideDelay(show: false) == 0.075 && EditorMetrics.inspectorSlideDelay(show: true) == 0.170)
        #expect(EditorMetrics.inspectorSlideMotion(show: false) == 0.200 && EditorMetrics.inspectorSlideMotion(show: true) == 0.230)
        for (show, start, length, positions) in [(false, 85.0, 200.0, 7), (true, 180.0, 230.0, 10)] {
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
        // The show starts 80–110 ms after the hide does (both rounds).
        let offset = (EditorMetrics.inspectorSlideDelay(show: true) - EditorMetrics.inspectorSlideDelay(show: false)) * 1000
        #expect(offset >= 80 && offset <= 110)
    }

    @Test func curves() {
        #expect(EditorMetrics.inspectorSlideCurve(show: false) == EditorMetrics.inspectorSlideEaseOut)
        #expect(EditorMetrics.inspectorSlideCurve(show: true) == EditorMetrics.inspectorSlideEaseInOut)
        func p(_ show: Bool, _ ms: Double) -> Double {
            EditorMetrics.inspectorSlideProgress(elapsed: EditorMetrics.inspectorSlideDelay(show: show) + ms / 1000, show: show)
        }
        // Hide (round 10's reference: 25 % at +27 ms, 63 % at +78, 96 % at +167): a fast start.
        #expect((0.15...0.35).contains(p(false, 27)) && (0.48...0.7).contains(p(false, 78)) && p(false, 167) >= 0.9)
        // Show: slow at both ends, half the travel about the middle.
        #expect(p(true, 20) < 0.06 && (0.4...0.6).contains(p(true, 115)) && p(true, 210) > 0.97)
    }
}
