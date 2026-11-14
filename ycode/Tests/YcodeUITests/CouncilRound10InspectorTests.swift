import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 10, row 248 (`specs/ide/fidelity-council.md` "Round 10"):
/// in a council window off every display, the editor's right edge does not
/// move until the slide's start (+75 ms hide, +170 show, so drawn about
/// +85 and +180 at 100 Hz), then moves on every 100 Hz frame until the
/// slide's end (about 200 and 230 ms later).
@MainActor
@Suite(.serialized) struct CouncilRound10InspectorTests {
    func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    @Test func theEdgeHoldsUntilTheStartThenMovesEveryFrame() throws {
        let dir = try CouncilRound8MotionTests.project("r10-start", lines: 200)
        let wc = try CouncilRound8MotionTests.window(dir)
        defer { MergeSheetR5UITests.Offscreen.off() }
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        func edge() -> CGFloat {
            w.contentView?.layoutSubtreeIfNeeded()
            return wc.editorArea.view.convert(wc.editorArea.view.bounds, to: nil).maxX
        }
        let restShown = edge()
        for (show, start, length, positions) in [(false, 85.0, 200.0, 7), (true, 180.0, 230.0, 10)] {
            let name = show ? "show" : "hide"
            let before = edge()
            wc.toggleInspector(nil)
            #expect(wc.isInspectorSliding)
            let state = wc.inspectorSlide
            state.link?.invalidate()
            state.link = nil
            let press = try #require(state.clock?.press)
            // Nothing moves at the press itself.
            #expect(edge() == before, "\(name): \(edge()) against \(before) at the press")
            var xs: [(ms: Double, x: CGFloat)] = []
            var k = 1
            while wc.isInspectorSliding, k < 200 {
                let t = press + Double(k) * 0.01
                var clock = try #require(state.clock)
                let p = clock.progress(at: t)
                state.clock = clock
                state.onFrame?(CGFloat(p))
                xs.append((Double(k) * 10, edge()))
                k += 1
            }
            let moves = zip(xs, [(ms: 0.0, x: before)] + xs).filter { $0.0.x != $0.1.x }.map(\.0)
            let first = try #require(moves.first).ms, last = try #require(moves.last).ms
            print(String(format: "R10B window %@: first edge movement %.0f ms, at rest %.0f ms (slide %.0f ms), %d positions",
                         name, first, last, last - first, moves.count))
            print("R10B window \(name) edge from \(before): " + xs.prefix(12).map { "\(Int($0.ms)):\($0.x)" }.joined(separator: " "))
            #expect(abs(first - start) <= 10, "\(name): first movement at \(first) ms")
            #expect(abs(last - first - length) <= 20, "\(name): \(first)–\(last) ms")
            #expect(moves.count >= positions, "\(name): \(moves.count) positions")
            // Every frame between the first and the last moves the edge (no holds).
            #expect(moves.count >= Int((last - first) / 10) - 1, "\(name): \(moves.map(\.ms))")
            // The slide ends where the split view lays the pane out at rest.
            spin(0.1)
            #expect(edge() == xs.last?.x, "\(name): \(edge()) after the slide, \(xs.last?.x ?? 0) at its end")
        }
        // A hide and a show return the edge to its place.
        #expect(abs(edge() - restShown) < 0.5, "\(edge()) against \(restShown)")
    }
}
