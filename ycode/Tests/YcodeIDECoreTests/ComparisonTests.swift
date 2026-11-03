import Foundation
import Testing
@testable import YcodeIDECore

@Suite struct LineDiffTests {
    @Test func diffAndLayout() {
        let old = ["a", "b", "c", "d"], new = ["a", "B", "c", "d", "e"]
        let ops = LineDiff.diff(old, new)
        #expect(ops == [.same("a"), .removed("b"), .added("B"), .same("c"), .same("d"), .added("e")])
        let rows = LineDiff.sideBySide(ops)
        #expect(rows.map(\.kind) == [.same, .changed, .same, .same, .added])
        #expect(rows[1].left?.number == 2 && rows[1].right?.text == "B")
        #expect(rows[4].left == nil && rows[4].right?.number == 5)
        #expect(LineDiff.unified(ops, context: 0) == "-b\n+B\n…\n+e")
        #expect(LineDiff.unified(LineDiff.diff(old, old)).isEmpty)
        #expect(LineDiff.diff([], ["x"]) == [.added("x")])
        #expect(LineDiff.lines("a\nb\n") == ["a", "b"])
    }
}
