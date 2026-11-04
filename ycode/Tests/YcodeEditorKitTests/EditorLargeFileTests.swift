import Foundation
import Testing
import YcodeSyntax
@testable import YcodeEditorKit

/// The cost of an edit in a 50,000-line Swift file. Debug builds are far slower
/// than release (the measured numbers in `docs/PARITY.md` are release); these
/// limits catch a change that makes an edit scale with the file.
@Suite(.serialized) struct EditorLargeFileTests {
    static func source(lines n: Int) -> String {
        let templates = [
            "import Foundation", "",
            "/// A value that counts the things it has seen so far.",
            "struct Counter<Element: Hashable> {",
            "    private(set) var counts: [Element: Int] = [:]",
            "    mutating func add(_ e: Element) { counts[e, default: 0] += 1 }",
            "    func count(of e: Element) -> Int { counts[e] ?? 0 }",
            "}",
            "let greeting = \"Hello, world!\"  // the classic",
        ]
        return (0..<n).map { templates[$0 % templates.count] }.joined(separator: "\n")
    }

    func seconds(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9
    }

    @Test func fiftyThousandLinesEditWithoutScalingWithTheFile() {
        let b = EditorBuffer(text: Self.source(lines: 50_000), language: .swift)
        #expect(b.lineCount == 50_000)
        let mid = b.document.lineStart(25_000)
        b.setCaret(mid)
        var worst = 0.0
        for c in "let inserted = 1" {
            worst = max(worst, seconds { b.insertText(String(c)) })
        }
        for _ in 0..<8 { worst = max(worst, seconds { b.deleteBackward() }) }
        worst = max(worst, seconds { b.newline() })
        worst = max(worst, seconds { b.undo() })
        // Debug build, a loaded machine; release is under a millisecond.
        #expect(worst < 0.25)
    }

    @Test func undoOverAWholeLargeFileEdit() {
        let original = Self.source(lines: 50_000)
        let b = EditorBuffer(text: original, language: .swift, typingOptions: TypingOptions(autoIndent: false, autoClose: false, encloseSelection: false))
        b.selectAll()
        b.paste("gone")
        #expect(b.lineCount == 1)
        b.undo()
        #expect(b.text == original && b.lineCount == 50_000 && !b.isDirty)
    }

    @Test func movementAndLayoutOnALargeFile() {
        let b = EditorBuffer(text: Self.source(lines: 50_000), language: .swift)
        let l = EditorLineLayout(tabWidth: 4, advance: 7)
        b.setCaret(0)
        var worst = 0.0
        for _ in 0..<50 { worst = max(worst, seconds { b.moveVertically(lines: 1000, layout: l) }) }
        #expect(b.caretLine == 49_999)
        #expect(worst < 0.05)
        #expect(l.displayLine(25_000, in: b).runs.count > 0)
    }
}
