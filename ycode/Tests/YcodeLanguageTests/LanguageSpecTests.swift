import Foundation
import Testing
import YcodeDebug
@testable import YcodeLanguage

/// Pure checks of specs/ide/language.md and refactoring.md parsing rules.
@Suite struct LanguageSpecTests {
    @Test func languageIDs() {
        func id(_ n: String) -> String { LSPClient.languageID(for: URL(fileURLWithPath: "/x/" + n)) }
        #expect(id("a.swift") == "swift")
        #expect(id("a.m") == "objective-c")
        #expect(id("a.mm") == "objective-cpp")
        #expect(id("a.cpp") == "cpp")
        #expect(id("a.c") == "c")
    }

    @Test func hoverContentsForms() {
        #expect(LSPClient.hoverText(["kind": "markdown", "value": "struct S"]) == "struct S")
        #expect(LSPClient.hoverText("plain") == "plain")
        #expect(LSPClient.hoverText(["a", ["language": "swift", "value": "let x"]]) == "a\n\nlet x")
        #expect(LSPClient.hoverText(nil) == nil)
        #expect(LSPClient.hoverText(["value": ""]) == nil)
    }

    @Test func locationAndLocationLink() {
        let loc = Location(["uri": "file:///a.swift", "range": ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 6]]])
        #expect(loc?.start == Position(line: 3, character: 4))
        let link = Location(["targetUri": "file:///b.swift",
                             "targetRange": ["start": ["line": 0, "character": 0], "end": ["line": 9, "character": 0]],
                             "targetSelectionRange": ["start": ["line": 2, "character": 7], "end": ["line": 2, "character": 8]]])
        #expect(link?.url.path == "/b.swift")
        #expect(link?.start == Position(line: 2, character: 7))
    }

    @Test func completionItemFields() {
        let item = CompletionItem(["label": "count", "insertTextFormat": 2, "kind": 10,
                                   "textEdit": ["newText": "count", "range": ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 4]]],
                                   "documentation": ["kind": "markdown", "value": "The count."]])
        #expect(item.isSnippet)
        #expect(item.replaceStart == Position(line: 1, character: 2))
        #expect(item.documentation == "The count.")
    }

    @Test func diagnosticsSeverityAndInlineFixIts() {
        let p: JSON = ["uri": "file:///a.swift", "diagnostics": [
            ["severity": 2, "message": "never mutated", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]],
             "codeActions": [["title": "Replace var with let", "kind": "quickfix",
                              "edit": ["changes": ["file:///a.swift": [["newText": "let", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]]]]]]]]],
        ]]
        let (url, d) = LSPDiagnostic.published(p)!
        #expect(url.path == "/a.swift")
        #expect(d.first?.severity == 2)
        #expect(d.first?.fixIts.first?.edit?.changes[url]?.first?.newText == "let")
    }

    @Test func workspaceEditBothShapes() {
        let e = WorkspaceEdit(["changes": ["file:///b.swift": [["newText": "x", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]]]],
                               "documentChanges": [["textDocument": ["uri": "file:///a.swift", "version": 1],
                                                    "edits": [["newText": "y", "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 1]]]]]]])
        #expect(e.files.map(\.path) == ["/a.swift", "/b.swift"])
        #expect(!e.isEmpty)
    }
}
