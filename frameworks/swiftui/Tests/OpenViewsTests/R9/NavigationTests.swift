import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R9, suite T-NAV (10-plan.md §3.2; 06 §2.1): push and pop sequences of
// the `nav` probe with their lifecycle order and 0.5 s timing, the [4, 5]
// multi-push, the root's slide to −30 %, the back swipe; split views
// (06 §2.2).

@MainActor
final class NavControls {
    var path = Controls<[Int]>()
}

struct NavProbe: View {
    let log: Log
    let controls: NavControls
    @State private var path: [Int] = []

    var body: some View {
        controls.path.binding = $path
        return NavigationStack(path: $path) {
            List { Text("root row") }
                .navigationTitle("Root")
                .onAppear { log("root appear") }
                .onDisappear { log("root disappear") }
                .navigationDestination(for: Int.self) { i in
                    Text("page \(i)")
                        .navigationTitle("Page \(i)")
                        .onAppear { log("\(i) appear") }
                        .onDisappear { log("\(i) disappear") }
                }
        }
    }
}

@MainActor
@Suite("R9 navigation (T-NAV)")
struct NavigationTests {
    /// Sets the path and runs frames for `seconds`; returns the log of the
    /// first update and the log at the end.
    func step(_ g: ViewGraph, _ log: Log, _ c: NavControls, _ path: [Int]) -> (start: [String], end: [String], mid: [String]) {
        c.path.value = path
        g.update()
        let start = log.take()
        g.advance(seconds: 0.45)
        let mid = log.take()
        g.advance(seconds: 0.1)
        g.settle()
        return (start, log.take(), mid)
    }

    @Test func pushAndPopFollowTheReferenceLifecycle() {
        let log = Log(), c = NavControls()
        let g = phoneGraph(NavProbe(log: log, controls: c))
        #expect(log.take() == ["root appear"])
        // Push: the destination appears at once, the root disappears at the
        // end of the 0.5 s animation.
        var r = step(g, log, c, [1])
        #expect(r.start == ["1 appear"])
        #expect(r.mid.isEmpty)
        #expect(r.end == ["root disappear"])
        r = step(g, log, c, [1, 2])
        #expect(r.start == ["2 appear"] && r.end == ["1 disappear"])
        r = step(g, log, c, [1, 2, 3])
        #expect(r.start == ["3 appear"] && r.end == ["2 disappear"])
        // Pop one: the page below appears at the start, the top disappears
        // at the end.
        r = step(g, log, c, [1, 2])
        #expect(r.start == ["2 appear"] && r.end == ["3 disappear"])
        // Pop to the root: intermediate pages had already disappeared.
        r = step(g, log, c, [])
        #expect(r.start == ["root appear"] && r.end == ["2 disappear"])
        // Push two: both are created, 4 appears too (never shown).
        r = step(g, log, c, [4, 5])
        #expect(Set(r.start) == ["4 appear", "5 appear"])
        #expect(r.end == ["root disappear"])
        // Pop both: 4 disappears at once, 5 at the end.
        r = step(g, log, c, [])
        #expect(Set(r.start) == ["root appear", "4 disappear"])
        #expect(r.end == ["5 disappear"])
    }

    @Test func pushSlidesTheRootToThirtyPercent() {
        let log = Log(), c = NavControls()
        let g = phoneGraph(NavProbe(log: log, controls: c))
        c.path.value = [7]
        g.update()
        g.advance(seconds: 0.25)
        // Half-way (ease-in-out: progress 0.5 at half the time): the root at
        // −0.3 × 382 × 0.5, the new page at 382 × 0.5.
        let rootX = frameOfText("root row", g)?.minX ?? .nan
        let pageX = frameOfText("page 7", g)?.minX ?? .nan
        #expect(abs(rootX - (40 - 0.3 * 382 * 0.5)) < 4)
        #expect(pageX > 382 * 0.5 - 4 && pageX < 382)
        g.settle()
        // The bar adds 82 points at the top (06 §2.1).
        let page = frameOfText("page 7", g)
        #expect(page.map { $0.minY > 82 } == true)
    }

    @Test func backSwipeFollowsTheFingerAndPops() {
        let log = Log(), c = NavControls()
        let h = Harness(size: CGSize(width: 382, height: 644)) { NavProbe(log: log, controls: c) }
        c.path.value = [3]
        h.run(until: 1.0)
        #expect(log.take() == ["root appear", "3 appear", "root disappear"])
        let x0 = frameOfText("page 3", h.window.graph)?.minX ?? .nan
        // Edge swipe: the root appears when the swipe starts; past half the
        // width the release pops (path → []).
        h.pointer(.down, CGPoint(x: 6, y: 300), at: 1.1)
        h.pointer(.moved, CGPoint(x: 30, y: 300), at: 1.12)
        h.pointer(.moved, CGPoint(x: 120, y: 302), at: 1.15)
        h.run(until: 1.16)
        #expect(log.take() == ["root appear"])
        let pageX = frameOfText("page 3", h.window.graph)?.minX ?? .nan
        #expect(abs(pageX - x0 - 114) < 1)                   // follows the finger (dx = 114)
        h.pointer(.moved, CGPoint(x: 260, y: 302), at: 1.18)
        h.pointer(.up, CGPoint(x: 260, y: 302), at: 1.2)
        h.run(until: 2.0)
        #expect(c.path.value == [])
        #expect(log.take() == ["3 disappear"])
    }

    @Test func navigationLinkPushesAndBackButtonPops() {
        let log = Log()
        let h = Harness(size: CGSize(width: 382, height: 644)) {
            NavigationStack {
                VStack {
                    NavigationLink("Open", value: 10)
                    Text("home").onAppear { log("home appear") }
                }
                .navigationDestination(for: Int.self) { i in Text("detail \(i)").onAppear { log("detail \(i)") } }
            }
        }
        _ = log.take()
        guard let link = frameOfText("Open", h.window.graph) else { Issue.record("link"); return }
        h.tap(link.center, at: 1.0)
        h.run(until: 1.8)
        #expect(log.take() == ["detail 10"])
        // The back button in the bar (leading, 44 points high from the top).
        h.tap(CGPoint(x: 30, y: 22), at: 2.0)
        h.run(until: 2.8)
        #expect(log.take() == ["home appear"])
    }
}

/// The window frame of the first `Text` with `string`.
@MainActor
func frameOfText(_ string: String, _ g: ViewGraph) -> CGRect? {
    var out: CGRect?
    g.root?.forEachNode { n in
        guard out == nil, !n.isInSuspendedSubtree, let t = n.view as? Text, t.plainString == string else { return }
        out = HitTesting.frame(of: n, mirrorWidth: nil)
    }
    return out
}
