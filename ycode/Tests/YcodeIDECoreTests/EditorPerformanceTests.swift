import Foundation
import Testing
@testable import YcodeIDECore

@Suite struct LineIndexEditTests {
    @Test func incrementalMatchesFull() {
        var text = "a\nbb\nccc\n"
        var idx = LineIndex(text)
        let edits: [(NSRange, String)] = [(NSRange(location: 1, length: 0), "x\ny"), (NSRange(location: 0, length: 4), ""),
                                           (NSRange(location: 2, length: 3), "\n\n"), (NSRange(location: 0, length: 0), "\n")]
        for (r, s) in edits {
            idx.applyEdit(range: r, replacement: s)
            text = (text as NSString).replacingCharacters(in: r, with: s)
            #expect(idx == LineIndex(text), "after \(r) \(s)")
        }
    }
}
