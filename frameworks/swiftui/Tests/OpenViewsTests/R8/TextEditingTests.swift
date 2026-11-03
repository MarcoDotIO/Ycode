import Foundation
import OVText
import Testing

// Round R8: the text editing core (OVText `TextEditingModel` and
// `TextLayoutGeometry`), the model EditorKit will build on. Rules: README
// "Text editing core (R8)".

@Suite("R8 text editing model")
struct TextEditingModelTests {
    @Test func insertionReplacesTheSelection() {
        let m = TextEditingModel(text: "hello world")
        #expect(m.caret == 11)
        m.setSelection(TextSelectionRange(anchor: 0, head: 5))
        #expect(m.selectedText == "hello")
        m.insert("howdy")
        #expect(m.text == "howdy world")
        #expect(m.caret == 5 && m.selection.isEmpty)
    }

    @Test func characterMovementCollapsesSelections() {
        let m = TextEditingModel(text: "abcdef")
        m.setSelection(TextSelectionRange(anchor: 1, head: 4))
        m.move(.character, forward: false)
        #expect(m.caret == 1 && m.selection.isEmpty)
        m.setSelection(TextSelectionRange(anchor: 1, head: 4))
        m.move(.character, forward: true)
        #expect(m.caret == 4)
        m.move(.character, forward: true, extending: true)
        m.move(.character, forward: true, extending: true)
        #expect(m.selectedRange == 4..<6)
        m.move(.character, forward: false, extending: true)
        #expect(m.selectedRange == 4..<5 && m.selection.anchor == 4)
    }

    @Test func wordMovementAndRanges() {
        let m = TextEditingModel(text: "let value = foo_bar(1)")
        m.setCaret(0)
        m.move(.word, forward: true)
        #expect(m.caret == 3)                  // end of "let"
        m.move(.word, forward: true)
        #expect(m.caret == 9)                  // end of "value"
        m.move(.word, forward: true)
        #expect(m.caret == 11)                 // "=" is a word of its own
        m.move(.word, forward: true)
        #expect(m.caret == 19)                 // "foo_bar": underscores join
        m.move(.word, forward: false)
        #expect(m.caret == 12)
        m.move(.word, forward: false)
        #expect(m.caret == 10)
        #expect(m.wordRange(at: 14) == 12..<19)
        #expect(m.wordRange(at: 3) == 0..<3)   // at a word's end, that word
        #expect(m.wordRange(at: 19) == 19..<20) // "("
        m.move(.document, forward: false, extending: false)
        m.move(.word, forward: true, extending: true)
        #expect(m.selectedText == "let")
    }

    @Test func paragraphAndLineMovementWithoutLayout() {
        let m = TextEditingModel(text: "one\ntwo three\nfour", allowsNewlines: true)
        m.setCaret(6)
        m.move(.line, forward: false)
        #expect(m.caret == 4)
        m.move(.line, forward: true)
        #expect(m.caret == 13)
        #expect(m.paragraphRange(at: 6) == 4..<14)
        // Vertical movement keeps the column on logical lines.
        m.setCaret(2)
        m.moveVertically(lines: 1)
        #expect(m.caret == 6)
        m.moveVertically(lines: 1)
        #expect(m.caret == 16)
        m.moveVertically(lines: -2)
        #expect(m.caret == 2)
    }

    @Test func deletionsByCharacterAndWord() {
        let m = TextEditingModel(text: "hello brave world")
        m.deleteBackward(.word)
        #expect(m.text == "hello brave ")
        m.deleteBackward()
        #expect(m.text == "hello brave")
        m.setCaret(0)
        m.deleteForward(.word)
        #expect(m.text == " brave")
        m.selectAll()
        m.deleteBackward()
        #expect(m.text.isEmpty)
    }

    @Test func undoCoalescesTypingAndRedoes() {
        let m = TextEditingModel(text: "")
        for c in "hello" { m.insert(String(c)) }
        m.insert(" ")
        for c in "you" { m.insert(String(c)) }
        #expect(m.text == "hello you")
        m.undo()
        #expect(m.text.isEmpty)               // one typing run, one step
        m.redo()
        #expect(m.text == "hello you" && m.caret == 9)
        // Moving the caret starts a new step; so does a deletion.
        m.setCaret(5)
        m.insert(",")
        m.deleteBackward()
        m.deleteBackward()
        #expect(m.text == "hell you")
        m.undo()
        #expect(m.text == "hello, you")
        m.undo()
        #expect(m.text == "hello you")
        #expect(m.canRedo)
        m.insert("!")
        #expect(!m.canRedo)                   // a new edit drops the redo history
    }

    @Test func pasteCutAndCopy() {
        let m = TextEditingModel(text: "abc")
        #expect(m.copy() == nil)
        m.setSelection(TextSelectionRange(anchor: 0, head: 2))
        #expect(m.copy() == "ab")
        #expect(m.cut() == "ab")
        #expect(m.text == "c")
        m.paste("x\ny")
        #expect(m.text == "x yc")             // single line: newlines become spaces
        m.undo()
        #expect(m.text == "c")
        let multi = TextEditingModel(text: "", allowsNewlines: true)
        multi.paste("a\nb")
        #expect(multi.text == "a\nb")
    }

    @Test func markedTextIsShownButNotCommitted() {
        let m = TextEditingModel(text: "ab")
        m.setSelection(TextSelectionRange(anchor: 1, head: 2))
        m.setMarkedText("にほ", cursor: 2)
        #expect(m.text == "a")                 // the selection was replaced
        #expect(String(m.displayCharacters) == "aにほ")
        #expect(m.displayMarkedRange == 1..<3)
        #expect(m.displayCaret == 3)
        m.insert("日本")
        #expect(m.text == "a日本" && !m.hasMarkedText)
    }

    @Test func externalChangesClampAndClearHistory() {
        let m = TextEditingModel(text: "abcdef")
        m.insert("g")
        m.setText("ab")
        #expect(m.caret == 2 && !m.canUndo)
    }

    @Test func geometryOfLaidOutText() {
        guard let face = FontCatalog.bundled.face(for: FontRequest()) else {
            Issue.record("no bundled font")
            return
        }
        let style = RunStyle(face: face, size: 17)
        let layout = Typesetter.layout([AttributedRun("one two\nthree", style: style)], width: nil,
                                       style: ParagraphStyle(), rounding: { $0 })
        let g = TextLayoutGeometry(layout: layout)
        #expect(g.lines.count == 2)
        #expect(g.lineIndex(of: 3) == 0 && g.lineIndex(of: 7) == 0 && g.lineIndex(of: 8) == 1)
        let x0 = g.caret(at: 0).x, x3 = g.caret(at: 3).x, x7 = g.caret(at: 7).x
        #expect(x0 == 0 && x3 > 0 && x7 > x3)
        // Hit testing returns the nearest caret position.
        #expect(g.offset(atX: x3 + 0.4, y: 1) == 3)
        #expect(g.offset(atX: 1000, y: 1) == 7)
        #expect(g.offset(atX: -5, y: g.lines[1].top + 2) == 8)
        // A selection over the newline covers both lines.
        let rects = g.selectionRects(5..<11)
        #expect(rects.count == 2)
        #expect(rects[1].x == 0)
        // Vertical movement uses visual lines and the goal x.
        let down = g.verticalMove(from: 2, lines: 1, x: nil)
        #expect(down?.offset ?? -1 >= 8)
        #expect(g.verticalMove(from: 9, lines: 1, x: nil) == nil)
        // A trailing newline opens an empty last line.
        let l2 = Typesetter.layout([AttributedRun("ab\n", style: style)], width: nil, style: ParagraphStyle(), rounding: { $0 })
        let g2 = TextLayoutGeometry(layout: l2)
        #expect(g2.lines.count == 2 && g2.lineIndex(of: 3) == 1 && g2.caret(at: 3).x == 0)
    }

    @Test func softWrapCaretBelongsToTheNextLine() {
        guard let face = FontCatalog.bundled.face(for: FontRequest()) else { return }
        let style = RunStyle(face: face, size: 17)
        let layout = Typesetter.layout([AttributedRun("alpha beta gamma", style: style)], width: 60,
                                       style: ParagraphStyle(), rounding: { $0 })
        let g = TextLayoutGeometry(layout: layout)
        #expect(g.lines.count >= 2)
        let start = g.lines[1].range.lowerBound
        #expect(g.lineIndex(of: start) == 1)
        #expect(g.lineBoundary(of: start + 1, end: false) == start)
    }
}
