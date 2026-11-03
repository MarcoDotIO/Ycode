import Foundation
import Testing
import YcodeLanguage
@testable import YcodeIDECore

@MainActor
@Suite struct CompletionModelTests {
    @Test func filtersAndMoves() {
        var m = CompletionModel()
        let items = ["greet(times:)", "name", "Greeter", "regret"].map { CompletionItem(label: $0, insertText: $0) }
        m.reset(items: items, wordStart: 4, prefix: "gre")
        #expect(m.visible.map(\.label) == ["greet(times:)", "Greeter", "regret"])
        m.move(5)
        #expect(m.current?.label == "regret")
        m.filter("")
        #expect(m.visible.count == 4 && m.selected == 0)
        #expect(CompletionModel.wordStart(in: "print(g.gr", before: 10) == 8)
        let idx = LineIndex("ab\ncde\n")
        #expect(idx.position(at: 5) == Position(line: 1, character: 2))
        #expect(idx.offset(of: Position(line: 1, character: 99)) == 6)
    }

    @Test func liveIssueConversion() {
        let d = LSPDiagnostic(["range": ["start": ["line": 15, "character": 6], "end": ["line": 15, "character": 13]],
                               "severity": 1, "message": "cannot find 'missing' in scope"])
        let hint = LSPDiagnostic(["severity": 4, "message": "hint"])
        let issues = LanguageService.issues(file: "/a.swift", [d, hint])
        #expect(issues.count == 1)
        #expect(issues[0].location == .init(file: "/a.swift", line: 16, column: 7))
    }
}
