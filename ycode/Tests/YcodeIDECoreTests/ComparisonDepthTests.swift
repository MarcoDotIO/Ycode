import Foundation
import Testing
@testable import YcodeIDECore

/// Depth checks for specs/ide/comparison.md.
@MainActor
@Suite(.serialized) struct ComparisonDepthTests {
    @Test func diffRules() {
        // Removals before additions; pure removal leaves a filler on the right.
        #expect(LineDiff.diff(["a", "b"], ["c"]) == [.removed("a"), .removed("b"), .added("c")])
        let rows = LineDiff.sideBySide(LineDiff.diff(["a", "b"], ["c"]))
        #expect(rows.map(\.kind) == [.changed, .removed])
        #expect(rows[1].right == nil && rows[1].left?.number == 2)
        #expect(LineDiff.sideBySide(LineDiff.diff(["x", "y"], ["x"])).map(\.kind) == [.same, .removed])
        // Three lines of context; separated hunks get "…".
        let old = (1...12).map { "l\($0)" }
        var new = old
        new[0] = "L1"; new[11] = "L12"
        let u = LineDiff.unified(LineDiff.diff(old, new))
        #expect(u == "-l1\n+L1\n l2\n l3\n l4\n…\n l9\n l10\n l11\n-l12\n+L12")
    }
}
