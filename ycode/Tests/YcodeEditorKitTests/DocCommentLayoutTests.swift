import Foundation
import Testing
import YcodeSyntax
@testable import YcodeEditorKit

/// P-054 on the Linux editor: a documentation comment's text advances in
/// the proportional face, its `///` on the grid (`EditorDocCommentStyle`).
@Suite struct DocCommentLayoutTests {
    func layout() -> EditorLineLayout {
        let l = EditorLineLayout(tabWidth: 4, advance: 8) { _ in 8 }
        l.proportionalCharacterWidth = { _ in 5 }
        return l
    }

    @Test func lineDocCommentIsProportionalAfterItsDelimiter() {
        let b = EditorBuffer(text: "/// Hello\nlet x = 1 // plain\n", language: .swift)
        let l = layout()
        // `///` 3 cells (24), " Hello" 6 × 5.
        #expect(l.x(ofOffset: 9, line: 0, in: b) == 54)
        #expect(l.x(ofOffset: 3, line: 0, in: b) == 24)
        #expect(l.offset(atX: 30, line: 0, in: b) == 4)
        #expect(l.proportionalRanges(line: 0, in: b) == [3..<9])
        let runs = l.displayLine(0, in: b).runs
        #expect(runs.map(\.text) == ["///", " Hello"] && runs.map(\.proportional) == [false, true])
        // Code and plain comments stay on the grid.
        #expect(l.proportionalRanges(line: 1, in: b).isEmpty)
        let r1 = b.document.lineRange(1)
        #expect(l.x(ofOffset: r1.upperBound, line: 1, in: b) == CGFloat(r1.count) * 8,
                "\(r1) \(l.x(ofOffset: r1.upperBound, line: 1, in: b)) \(b.document.tokens(onLine: 1).map { "\($0.kind)" })")
    }

    @Test func noProportionalFaceKeepsTheGrid() {
        let b = EditorBuffer(text: "/// Hello\n", language: .swift)
        let l = EditorLineLayout(tabWidth: 4, advance: 8) { _ in 8 }
        #expect(l.x(ofOffset: 9, line: 0, in: b) == 72)
        #expect(l.displayLine(0, in: b).runs.allSatisfy { !$0.proportional })
    }

    @Test func delimiters() {
        func d(_ s: String) -> [NSRange] { EditorDocCommentStyle.delimiters(in: s as NSString, token: NSRange(location: 0, length: (s as NSString).length)) }
        #expect(d("/// Text") == [NSRange(location: 0, length: 3)])
        #expect(d("    /// Text") == [NSRange(location: 4, length: 3)])
        #expect(d("/** Text */") == [NSRange(location: 0, length: 3), NSRange(location: 9, length: 2)])
        // A block's middle and last lines (line pieces).
        #expect(d(" * more") == [])
        #expect(d(" */") == [NSRange(location: 1, length: 2)])
        #expect(EditorDocCommentStyle.proportionalRanges(in: "/// A" as NSString, token: NSRange(location: 0, length: 5)) == [NSRange(location: 3, length: 2)])
    }
}
