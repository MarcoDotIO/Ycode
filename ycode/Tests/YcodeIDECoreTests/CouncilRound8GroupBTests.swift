import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 8, group B, in the models both IDEs share
/// (`specs/ide/fidelity-council.md` rows 204, 205, 207): the momentum's
/// share fitted to the slow flick, the fast flick's stretch and rest, and
/// the inspector slide's curves.
@Suite struct CouncilRound8GroupBTests {
    /// A flick's momentum events: `points` in `n` events over `span` seconds
    /// decaying with a 0.33 s time constant, from `t0`.
    static func momentum(points: Double, n: Int, span: Double, t0: Double) -> [(time: Double, dy: Double)] {
        let tau = 0.33, dt = span / Double(n)
        let v0 = points / (tau * (1 - exp(-span / tau)))
        return (0..<n).map { i in
            let a = Double(i) * dt
            return (t0 + a, v0 * tau * (exp(-a / tau) - exp(-(a + dt) / tau)))
        }
    }

    // MARK: Rows 205 and 207: superseded by round 9

    // Round 9 (rows 220 and 221) measured the slow flick reaching the top and
    // the fast flick's stretch at 38 points; round 8's 564-point stop, the
    // decaying gain and the 190-point stretch were misreadings of its 1x
    // strip. Their checks are `CouncilRound9GroupBTests`.

    // MARK: Row 204: the inspector's curves

    /// Hide: ease-out (round 10, row 248: over 200 ms). Show: ease-in-out
    /// over 230 ms since round 10 (rounds 8–9: an even ease-out over 280).
    @Test func slideCurves() {
        #expect(EditorMetrics.inspectorSlideMotion(show: false) == 0.200)
        #expect(EditorMetrics.inspectorSlideMotion(show: true) == 0.230)
        for show in [false] {
            let c = EditorMetrics.inspectorSlideCurve(show: show)
            #expect(c == EditorMetrics.inspectorSlideEaseOut)
            // Monotonic, front-loaded: half the travel in under 40 % of the time.
            let d = EditorMetrics.inspectorSlideDelay(show: show), m = EditorMetrics.inspectorSlideMotion(show: show)
            var last = 0.0
            for i in 0...100 {
                let p = EditorMetrics.inspectorSlideProgress(elapsed: d + m * Double(i) / 100, show: show)
                #expect(p >= last - 1e-9)
                last = p
            }
            #expect(EditorMetrics.inspectorSlideProgress(elapsed: d + m * 0.4, show: show) > 0.5)
            #expect(abs(last - 1) < 1e-9)
        }
    }

    /// At 60 Hz the show draws a new position on every frame of its 230 ms
    /// (at least 12), each a step forward, none over a frame apart.
    @Test func showMovesEveryFrame() {
        var clock = InspectorSlideClock(show: true, press: 0)
        var positions: [Double] = []
        var t = 0.0
        while !clock.isFinished, t < 1 {
            t += 1.0 / 60
            positions.append(clock.progress(at: t))
        }
        let moving = zip(positions.dropFirst(), positions).filter { $0.0 > 0 && $0.1 < 1 }
        #expect(moving.count >= 12, "\(moving.count)")
        #expect(moving.allSatisfy { $0.0 > $0.1 })
    }
}
