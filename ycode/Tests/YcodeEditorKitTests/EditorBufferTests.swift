import Foundation
import Testing
import YcodeSyntax
@testable import YcodeEditorKit

@Suite struct EditorBufferTests {
    func plainOptions() -> TypingOptions { TypingOptions(autoIndent: false, autoClose: false, encloseSelection: false) }

    func buffer(_ text: String, language: SyntaxLanguage = .swift, caret: Int? = nil, plain: Bool = false) -> EditorBuffer {
        let b = EditorBuffer(text: text, language: language, typingOptions: plain ? plainOptions() : TypingOptions())
        b.setCaret(caret ?? 0)
        return b
    }

    @Test func typingInsertsAndMovesTheCaret() {
        let b = buffer("ab", caret: 1, plain: true)
        for c in "xyz" { b.insertText(String(c)) }
        #expect(b.text == "axyzb" && b.selection == EditorSelection(caret: 4))
        #expect(b.isDirty)
    }

    @Test func typingOverASelectionReplacesIt() {
        let b = buffer("hello world", plain: true)
        b.setSelection(EditorSelection(anchor: 6, head: 11))
        b.insertText("X")
        #expect(b.text == "hello X" && b.caret == 7)
    }

    @Test func deleteBackwardAndForwardCrossLinesAndClusters() {
        let b = buffer("a\nbc", caret: 2, plain: true)
        b.deleteBackward()
        #expect(b.text == "abc" && b.caret == 1)
        b.deleteForward()
        #expect(b.text == "ac" && b.caret == 1)
        // A flag is two scalars and four units, one cluster.
        let f = buffer("x🇺🇳y", caret: 5, plain: true)
        f.deleteBackward()
        #expect(f.text == "xy" && f.caret == 1)
        let e = buffer("e\u{301}x", caret: 0, plain: true)
        e.deleteForward()
        #expect(e.text == "x")
    }

    @Test func wordMovementAndDeletion() {
        let b = buffer("let fooBar = 12.5 // x", plain: true)
        b.move(.word, forward: true)
        #expect(b.caret == 3)
        b.move(.word, forward: true)
        #expect(b.caret == 10)
        b.move(.word, forward: false)
        #expect(b.caret == 4)
        b.setCaret(10)
        b.deleteBackward(.word)
        #expect(b.text == "let  = 12.5 // x" && b.caret == 4)
    }

    @Test func homeGoesToTheTextThenTheLineStart() {
        let b = buffer("    code", caret: 6, plain: true)
        b.move(.line, forward: false)
        #expect(b.caret == 4)
        b.move(.line, forward: false)
        #expect(b.caret == 0)
        b.move(.line, forward: false)
        #expect(b.caret == 4)
        b.move(.line, forward: true)
        #expect(b.caret == 8)
    }

    @Test func movementCollapsesAndExtendsSelections() {
        let b = buffer("abcdef", plain: true)
        b.setSelection(EditorSelection(anchor: 1, head: 4))
        b.move(.character, forward: false)
        #expect(b.selection == EditorSelection(caret: 1))
        b.move(.character, forward: true, extending: true)
        b.move(.character, forward: true, extending: true)
        #expect(b.selection == EditorSelection(anchor: 1, head: 3))
        b.move(.document, forward: true, extending: true)
        #expect(b.selection == EditorSelection(anchor: 1, head: 6))
    }

    @Test func verticalMovementKeepsItsColumn() {
        let b = buffer("long line here\nab\nanother long line", caret: 10, plain: true)
        let l = EditorLineLayout()
        b.moveVertically(lines: 1, layout: l)
        #expect(b.caret == 15 + 2)
        b.moveVertically(lines: 1, layout: l)
        #expect(b.caret == 18 + 10)
        b.moveVertically(lines: -2, layout: l)
        #expect(b.caret == 10)
        b.moveVertically(lines: -1, layout: l)
        #expect(b.caret == 0)
        b.moveVertically(lines: 99, layout: l)
        #expect(b.caret == b.length)
    }

    @Test func wordAndLineSelection() {
        let b = buffer("foo.bar  baz\nnext", plain: true)
        #expect(b.wordRange(at: 1) == 0..<3)
        #expect(b.wordRange(at: 3) == 0..<3)      // Between a word and punctuation: the word.
        #expect(b.wordRange(at: 7) == 4..<7)
        #expect(b.wordRange(at: 8) == 7..<9)
        #expect(b.wordRange(at: 12) == 9..<12)    // The line's end: the word before.
        b.selectLine(at: 2)
        #expect(b.selectedText == "foo.bar  baz\n")
        b.selectLine(at: 15)
        #expect(b.selectedText == "next")
    }

    @Test func granularDragsKeepTheStartingWord() {
        let b = buffer("one two three", plain: true)
        b.extendGranular(from: 4..<7, to: 10, lines: false)
        #expect(b.selection == EditorSelection(anchor: 4, head: 13))
        b.extendGranular(from: 4..<7, to: 1, lines: false)
        #expect(b.selection == EditorSelection(anchor: 7, head: 0))
    }

    @Test func clipboardOperations() {
        let b = buffer("one two", plain: true)
        #expect(b.copyText() == nil)
        b.setSelection(EditorSelection(anchor: 0, head: 3))
        #expect(b.copyText() == "one")
        #expect(b.cutText() == "one")
        #expect(b.text == " two")
        b.paste("x\r\ny")
        #expect(b.text == "x\ny two" && b.caret == 3)
        b.undo()
        #expect(b.text == " two")
        b.undo()
        #expect(b.text == "one two" && b.selection == EditorSelection(anchor: 0, head: 3))
    }

    @Test func typingUndoesAsOneStepUntilTheCaretMoves() {
        let b = buffer("", plain: true)
        for c in "abc" { b.insertText(String(c)) }
        b.move(.character, forward: false)
        b.move(.character, forward: true)
        for c in "de" { b.insertText(String(c)) }
        #expect(b.text == "abcde")
        b.undo()
        #expect(b.text == "abc" && b.caret == 3)
        b.undo()
        #expect(b.text == "" && !b.canUndo)
        b.redo()
        #expect(b.text == "abc")
        b.redo()
        #expect(b.text == "abcde" && b.caret == 5 && !b.canRedo)
    }

    @Test func eachTypedLineIsItsOwnUndoStep() {
        let b = buffer("", plain: true)
        for c in "one" { b.insertText(String(c)) }
        b.newline()
        for c in "two" { b.insertText(String(c)) }
        b.undo()
        #expect(b.text == "one\n")
        b.undo()
        #expect(b.text == "")
    }

    @Test func deletionsCoalesceByDirection() {
        let b = buffer("abcdef", caret: 3, plain: true)
        b.deleteBackward()
        b.deleteBackward()
        b.deleteForward()
        #expect(b.text == "aef")
        b.undo()
        #expect(b.text == "adef")
        b.undo()
        #expect(b.text == "abcdef" && b.caret == 3)
    }

    @Test func undoRestoresTheSelection() {
        let b = buffer("abc def", plain: true)
        b.setSelection(EditorSelection(anchor: 4, head: 7))
        b.insertText("X")
        b.undo()
        #expect(b.text == "abc def" && b.selection == EditorSelection(anchor: 4, head: 7))
    }

    @Test func aNewEditDropsTheRedoHistory() {
        let b = buffer("", plain: true)
        b.insertText("a")
        b.undo()
        #expect(b.canRedo)
        b.insertText("b")
        #expect(!b.canRedo && b.text == "b")
    }

    @Test func dirtyFollowsTheSavedState() {
        let b = buffer("a", plain: true)
        #expect(!b.isDirty)
        b.setCaret(1)
        b.insertText("b")
        #expect(b.isDirty)
        b.undo()
        #expect(!b.isDirty)
        b.redo()
        #expect(b.isDirty)
        b.markSaved()
        #expect(!b.isDirty)
        b.undo()
        #expect(b.isDirty)
        b.redo()
        #expect(!b.isDirty)
        b.undo()
        b.insertText("c")   // A different text than the one saved.
        #expect(b.isDirty)
        #expect(b.text == "ac")
    }

    @Test func replaceAllIsOneUndoStep() {
        let b = buffer("a b a b a", plain: true)
        let ranges = [0, 4, 8].map { (range: NSRange(location: $0, length: 1), replacement: "xx") }
        b.replaceAll(ranges)
        #expect(b.text == "xx b xx b xx")
        b.undo()
        #expect(b.text == "a b a b a")
        b.redo()
        #expect(b.text == "xx b xx b xx")
    }

    @Test func manyRandomEditsAndUndosComeBackExactly() {
        var rng = SeededGenerator(seed: 42)
        let original = (0..<200).map { "line \($0) { value }" }.joined(separator: "\n")
        let b = buffer(original)
        var texts = [b.text]
        for _ in 0..<400 {
            let p = Int.random(in: 0...b.length, using: &rng)
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: b.setCaret(p); b.insertText(["a", "{", "\"", "(", "é", "😀"].randomElement(using: &rng)!)
            case 1: b.setCaret(p); b.newline()
            case 2: b.setCaret(p); b.deleteBackward()
            case 3: b.setCaret(p); b.deleteForward(.word)
            case 4: b.setSelection(EditorSelection(anchor: p, head: min(b.length, p + 20))); b.paste("pasted\ntext")
            case 5: b.setCaret(p); b.tab(backward: false)
            default: b.setSelection(EditorSelection(anchor: p, head: min(b.length, p + 7))); _ = b.cutText()
            }
            // The tokens' line index matches the text after each edit.
            #expect(b.lineCount == b.text.utf16.filter { $0 == 10 }.count + 1)
            texts.append(b.text)
        }
        let final = b.text
        while b.canUndo { b.undo() }
        #expect(b.text == original && !b.isDirty)
        while b.canRedo { b.redo() }
        #expect(b.text == final)
    }

    // MARK: Typing rules

    @Test func bracketsPairStepOverAndDeleteTogether() {
        let b = buffer("")
        b.insertText("(")
        #expect(b.text == "()" && b.caret == 1)
        b.insertText(")")
        #expect(b.text == "()" && b.caret == 2)
        b.setCaret(0)
        b.setSelection(EditorSelection(caret: 2))
        b.insertText("[")
        #expect(b.text == "()[]" && b.caret == 3)
        b.deleteBackward()
        #expect(b.text == "()")
    }

    @Test func returnIndentsByTheStructure() {
        let b = buffer("func a() {}", caret: 10)
        b.newline()
        #expect(b.text == "func a() {\n    \n}")
        #expect(b.caret == 15)
        b.insertText("x")
        b.newline()
        #expect(b.text == "func a() {\n    x\n    \n}")
    }

    @Test func closingBraceReindentsAndCommentToggles() {
        let b = buffer("if a {\n        ", caret: 15)
        b.insertText("}")
        #expect(b.text.hasSuffix("\n}"))
        let c = buffer("let a = 1\nlet b = 2")
        c.selectAll()
        c.toggleComment()
        #expect(c.text == "// let a = 1\n// let b = 2")
        c.toggleComment()
        #expect(c.text == "let a = 1\nlet b = 2")
    }

    @Test func enclosingASelection() {
        let b = buffer("word")
        b.selectAll()
        b.insertText("(")
        #expect(b.text == "(word)" && b.selectedText == "word")
    }

    @Test func tabAndShiftTabShiftSelectedLines() {
        let b = buffer("a\nb")
        b.selectAll()
        b.tab(backward: false)
        #expect(b.text == "    a\n    b")
        b.tab(backward: true)
        #expect(b.text == "a\nb")
    }

    @Test func undoAfterATypingRuleIsWhole() {
        let b = buffer("")
        for c in "if a {" { b.insertText(String(c)) }
        #expect(b.text == "if a {}")
        b.newline()
        b.undo()
        #expect(b.text == "")
    }

    // MARK: Marked text

    @Test func markedTextStaysOutOfTheTextUntilCommitted() {
        let b = buffer("ab", caret: 1, plain: true)
        b.setMarkedText("に", cursor: 1)
        #expect(b.text == "ab" && b.hasMarkedText && b.markedCursor == 1)
        b.setMarkedText("にほ", cursor: 2)
        b.setMarkedText("", cursor: 0)
        #expect(!b.hasMarkedText)
        b.setMarkedText("日", cursor: 1)
        b.insertText("日本")
        #expect(b.text == "a日本b" && !b.hasMarkedText && b.caret == 3)
    }

    @Test func markedTextReplacesASelectionWhenItStarts() {
        let b = buffer("abc", plain: true)
        b.selectAll()
        b.setMarkedText("x", cursor: 1)
        #expect(b.text == "" && b.markedText == "x")
    }

    // MARK: Read-only

    @Test func aReadOnlyBufferRefusesEveryChange() {
        let b = buffer("abc", caret: 1, plain: true)
        b.isReadOnly = true
        b.insertText("x")
        b.newline()
        b.deleteBackward()
        b.deleteForward()
        b.paste("x")
        b.tab(backward: false)
        b.toggleComment()
        b.selectAll()
        #expect(b.cutText() == nil)
        b.replace(NSRange(location: 0, length: 1), with: "z")
        #expect(b.text == "abc" && !b.isDirty && b.selection == EditorSelection(anchor: 0, head: 3))
    }

    // MARK: Line layout

    @Test func tabsAndWideCharactersMapToX() {
        let b = buffer("\tab\nx\ty\n日本z", plain: true)
        let l = EditorLineLayout(tabWidth: 4, advance: 10) { $0 == "日" || $0 == "本" ? 20 : 10 }
        #expect(l.x(ofOffset: 1, in: b) == 40)
        #expect(l.x(ofOffset: 2, in: b) == 50)
        #expect(l.offset(atX: 44, line: 0, in: b) == 1)
        #expect(l.offset(atX: 18, line: 0, in: b) == 0)
        #expect(l.offset(atX: 22, line: 0, in: b) == 1)
        #expect(l.x(ofOffset: 4 + 2, in: b) == 40)                 // "x\t" ends at the tab stop.
        let line2 = b.document.lineStart(2)
        #expect(l.x(ofOffset: line2 + 2, in: b) == 40)
        #expect(l.offset(atX: 41, line: 2, in: b) == line2 + 2)
        #expect(l.offset(atX: 500, line: 2, in: b) == line2 + 3)
        #expect(l.displayLine(0, in: b).runs.map(\.text).joined() == "    ab")
        #expect(l.displayLine(1, in: b).runs.map(\.text).joined() == "x   y")
    }

    @Test func aVeryLongLineDrawsOnlyWhatIsInView() {
        let long = String(repeating: "abcdefghij", count: 100_000)
        let b = buffer(long, language: .plain, plain: true)
        let l = EditorLineLayout(tabWidth: 4, advance: 10)
        let d = l.displayLine(0, in: b, columns: 500_000..<500_100)
        #expect(d.firstColumn == 500_000 && d.runs.map(\.text).joined().utf16.count == 100)
        #expect(l.width(ofLine: 0, in: b) == 10_000_000)
    }

    @Test func keyBindings() {
        #expect(EditorKeyBindings.command(.left, []) == .move(.character, forward: false, extending: false))
        #expect(EditorKeyBindings.command(.right, [.primary, .shift]) == .move(.word, forward: true, extending: true))
        #expect(EditorKeyBindings.command(.end, [.primary]) == .move(.document, forward: true, extending: false))
        #expect(EditorKeyBindings.command(.backspace, [.primary]) == .deleteBackward(.word))
        #expect(EditorKeyBindings.command(.character("z"), [.primary]) == .undo)
        #expect(EditorKeyBindings.command(.character("z"), [.primary, .shift]) == .redo)
        #expect(EditorKeyBindings.command(.character("y"), [.primary]) == .redo)
        #expect(EditorKeyBindings.command(.character("s"), [.primary]) == nil)      // The menu's.
        #expect(EditorKeyBindings.command(.character("a"), []) == nil)              // Text.
        #expect(EditorKeyBindings.command(.tab, [.shift]) == .tab(backward: true))
        #expect(EditorKeyBindings.command(.insert, [.shift]) == .paste)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        return x
    }
}
