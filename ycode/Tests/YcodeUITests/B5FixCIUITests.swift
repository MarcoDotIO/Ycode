import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B5-FIX-CI on macOS (offscreen): the navigator's header rows held for
/// another area's slide keep their layout, and get their priorities back.
@MainActor
@Suite(.serialized) struct B5FixCIUITests {
    typealias Ops = ProjectNavigatorOperationsTests

    /// Every view of the navigator outside its rows, with its frame in the
    /// window and its horizontal priorities.
    func headerState(_ nav: NavigatorAreaController) -> [(String, NSRect, Float, Float)] {
        var out: [(String, NSRect, Float, Float)] = []
        func walk(_ v: NSView, _ path: String) {
            if v is NSScrollView { return }
            let clip = (v as? NSStackView)?.clippingResistancePriority(for: .horizontal).rawValue ?? 0
            out.append((path, v.convert(v.bounds, to: nil), v.contentCompressionResistancePriority(for: .horizontal).rawValue, clip))
            for (i, c) in v.subviews.enumerated() { walk(c, path + "/\(i)") }
        }
        walk(nav.view, "")
        return out
    }

    @Test func heldHeaderRowsKeepTheirLayoutAndPriorities() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        let w = try #require(wc.window)
        w.contentView?.layoutSubtreeIfNeeded()
        let nav = wc.navigator
        let before = headerState(nav)
        // P-024's rows give way: some stacks and controls sit below the usual priorities.
        #expect(before.contains { $0.3 > 0 && $0.3 < 1000 } && before.contains { $0.2 < 750 })
        nav.holdHeaderClipping(true)
        nav.holdHeaderClipping(true)   // once
        let counts = try #require(nav.heldHeaderCounts)
        #expect(counts.stacks > 0 && counts.views > 0, "\(counts)")
        w.contentView?.layoutSubtreeIfNeeded()
        let held = headerState(nav)
        #expect(held.count == before.count)
        for (a, b) in zip(before, held) { #expect(a.0 == b.0 && a.1 == b.1, "\(a.0): \(a.1) → \(b.1)") }
        nav.holdHeaderClipping(false)
        #expect(nav.heldHeaderCounts == nil)
        w.contentView?.layoutSubtreeIfNeeded()
        let after = headerState(nav)
        for (a, b) in zip(before, after) { #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3, "\(a) → \(b)") }
    }

    /// The inspector's slide holds the rows from its press to its end.
    @Test func theInspectorSlideHoldsTheHeaderRows() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        w.orderBack(nil)
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(wc.navigator.heldHeaderCounts == nil)
        wc.toggleInspector(nil)
        guard wc.isInspectorSliding else { Issue.record("no slide"); return }
        #expect(wc.navigator.heldHeaderCounts != nil)
        let state = wc.inspectorSlide
        for i in 1...4 { state.onFrame?(CGFloat(i) / 4) }
        let end = Date().addingTimeInterval(2)
        while wc.isInspectorSliding, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        #expect(!wc.isInspectorSliding && wc.navigator.heldHeaderCounts == nil)
    }
}
