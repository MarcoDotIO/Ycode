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

// Round R9, suite T-LIST (10-plan.md §3.2; 06 §3): materialisation counts of
// `List`, `LazyVStack` and `VStack` in the reference's window (466 × 678,
// safe area bottom 34 and trailing 84, so a 382 × 644 container) with 52 /
// 48-point rows; `scrollTo` offsets and the rows it creates and removes.

/// The reference device's window (06 §1).
@MainActor
func phoneGraph<V: View>(_ view: V) -> ViewGraph {
    let g = ViewGraph(rootView: view, layout: HostLayout(.window(CGSize(width: 466, height: 678),
                                                                 safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84))))
    g.update()
    return g
}

@MainActor
final class RowCounter {
    var appeared: [Int] = []
    var disappeared: [Int] = []
    var geometry: ScrollGeometry?
    var proxy: ScrollViewProxy?
}

@MainActor
@Suite("R9 lists and lazy stacks (T-LIST)")
struct ListTests {
    @Test func lazyVStackMaterialisesTheVisibleRowsAndReportsExactContentSize() {
        let c = RowCounter()
        let g = phoneGraph(
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<1000, id: \.self) { i in
                        Color.red.frame(height: 40)
                            .onAppear { c.appeared.append(i) }
                            .onDisappear { c.disappeared.append(i) }
                    }
                }
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in c.geometry = new }
        )
        // 06 §3: 15 rows (0–14) — 678 points of the 48-point pitch, the last
        // 34 under the bottom safe area.
        #expect(c.appeared.sorted() == Array(0...14))
        #expect(c.disappeared.isEmpty)
        let geo = c.geometry
        #expect(geo?.contentSize.height == 47_992)        // 1 000 × 48 − 8, exact at once
        #expect(geo?.contentSize.width == 382)
        #expect(geo?.containerSize == CGSize(width: 382, height: 644))
        #expect(geo?.contentInsets.bottom == 34)
        _ = g
    }

    @Test func lazyGridsMaterialiseVisibleRowsAndColumns() {
        let c = RowCounter()
        _ = phoneGraph(
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(0..<999, id: \.self) { i in Color.red.frame(height: 40).onAppear { c.appeared.append(i) } }
                }
            }
        )
        // 15 rows of three (the 678 visible points, as for the lazy stack).
        #expect(c.appeared.sorted() == Array(0..<45))
        let h = RowCounter()
        _ = phoneGraph(
            ScrollView(.horizontal) {
                LazyHGrid(rows: [GridItem(.fixed(100)), GridItem(.fixed(100))], spacing: 10) {
                    ForEach(0..<500, id: \.self) { i in Color.blue.frame(width: 50).onAppear { h.appeared.append(i) } }
                }
            }
        )
        // Columns of 50 + 10 in 382 points plus the 84-point trailing inset
        // the scroll view touches: 8 columns of two.
        #expect(h.appeared.sorted() == Array(0..<16))
    }

    @Test func vStackInAScrollViewCreatesEveryRow() {
        let c = RowCounter()
        _ = phoneGraph(
            ScrollView {
                VStack {
                    ForEach(0..<300, id: \.self) { i in
                        Color.red.frame(height: 40).onAppear { c.appeared.append(i) }
                    }
                }
            }
        )
        #expect(c.appeared.count == 300)                   // 06 §3: all at once
    }

    @Test func listMaterialisesThirteenRowsAndScrollToJumpsWithoutAnimation() {
        let c = RowCounter()
        let g = phoneGraph(
            ScrollViewReader { proxy in
                List {
                    ForEach(0..<1000, id: \.self) { i in
                        Text("Row \(i)")
                            .onAppear { c.appeared.append(i) }
                            .onDisappear { c.disappeared.append(i) }
                    }
                }
                .onAppear { c.proxy = proxy }
            }
        )
        // 06 §3: rows 0–12 at launch (pitch 52).
        #expect(c.appeared.sorted() == Array(0...12))
        c.appeared = []
        c.proxy?.scrollTo(500, anchor: .top)
        g.update()
        // Rows 500–513 appear, the 13 earlier ones disappear; the offset
        // jumps to 500 × 52 + 13.33 (no animation).
        #expect(c.appeared.sorted() == Array(500...513))
        #expect(c.disappeared.sorted() == Array(0...12))
        let s = scrollState(in: g)
        #expect(abs((s?.offset.y ?? 0) - 26_013.33) < 0.01)
        #expect(!g.isAnimating)
    }

    @Test func flingDeceleratesByTheReferenceRate() {
        let h = Harness(size: CGSize(width: 382, height: 644)) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<1000, id: \.self) { _ in Color.red.frame(height: 40) }
                }
            }
        }
        guard let s = scrollState(in: h.window.graph) else { Issue.record("scroll view"); return }
        // A drag of 305 points in 160 ms (06 §3), released.
        let end = h.drag(from: CGPoint(x: 190, y: 500), delta: CGSize(width: 0, height: -30.5), steps: 10, interval: 0.016, at: 1.0)
        let atRelease = s.offset.y
        #expect(atRelease > 290 && atRelease < 306)       // followed the finger (after the 10-point start)
        var samples: [CGFloat] = []
        var t = end
        while t < end + 4 {
            t += 1.0 / 60
            h.run(until: t)
            samples.append(s.offset.y)
        }
        // Per-frame displacement ratio ≈ 0.998^16.7 ≈ 0.967 (06 §3).
        let d = zip(samples.dropFirst(), samples).map { $0 - $1 }
        let ratios = zip(d.dropFirst(), d).prefix(60).dropFirst(5).compactMap { $1 > 0.5 ? $0 / $1 : nil }
        #expect(!ratios.isEmpty)
        for r in ratios { #expect(abs(r - 0.967) < 0.006) }
        // At rest after about 2.5 s.
        let restIndex = d.firstIndex { $0 == 0 } ?? d.count
        let restTime = Double(restIndex) / 60
        #expect(restTime > 1.5 && restTime < 3.0)
    }

    @Test func wheelNotchesScrollTenPoints() {
        let h = Harness(size: CGSize(width: 300, height: 300)) {
            ScrollView { VStack(spacing: 0) { ForEach(0..<50, id: \.self) { _ in Color.blue.frame(height: 40) } } }
        }
        guard let s = scrollState(in: h.window.graph) else { Issue.record("scroll view"); return }
        h.backend.post(.scroll(ScrollEvent(window: h.windowID, location: CGPoint(x: 150, y: 150),
                                           delta: CGSize(width: 0, height: -30), timestamp: 1.0)), at: 1.0)
        h.run(until: 1.05)
        #expect(s.offset.y == 30)
        // Up past the top stops at 0 and passes the delta on.
        h.backend.post(.scroll(ScrollEvent(window: h.windowID, location: CGPoint(x: 150, y: 150),
                                           delta: CGSize(width: 0, height: 100), timestamp: 1.1)), at: 1.1)
        h.run(until: 1.15)
        #expect(s.offset.y == 0)
    }
}

@MainActor
func scrollState(in g: ViewGraph) -> ScrollViewState? {
    var out: ScrollViewState?
    g.root?.forEachNode { n in if out == nil, let s = n.primitiveState as? ScrollViewState { out = s } }
    return out
}
