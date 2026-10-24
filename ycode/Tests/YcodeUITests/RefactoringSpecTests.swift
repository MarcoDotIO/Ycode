import Foundation
import Testing
import YcodeBuild
import YcodeLanguage
@testable import YcodeUI

/// Edit application rules of specs/ide/refactoring.md §Applying edits.
@Suite struct RefactoringSpecTests {
    @Test @MainActor func editsApplyLastToFirst() {
        let text = "let a = a + 1\nprint(a)\n"
        let edits = [
            TextEdit(start: Position(line: 0, character: 4), end: Position(line: 0, character: 5), newText: "count"),
            TextEdit(start: Position(line: 1, character: 6), end: Position(line: 1, character: 7), newText: "count"),
            TextEdit(start: Position(line: 0, character: 8), end: Position(line: 0, character: 9), newText: "count"),
        ]
        #expect(WorkspaceWindowController.apply(edits, to: text) == "let count = count + 1\nprint(count)\n")
    }

    @Test @MainActor func fixItConversionIsOneBasedToZeroBased() {
        let f = Diagnostic.FixIt(file: "/a.swift", start: .init(file: "/a.swift", line: 2, column: 1),
                                 end: .init(file: "/a.swift", line: 2, column: 4), replacement: "let")
        let t = WorkspaceWindowController.textEdit(f)
        #expect(t.start == Position(line: 1, character: 0))
        #expect(t.end == Position(line: 1, character: 3))
    }
}
