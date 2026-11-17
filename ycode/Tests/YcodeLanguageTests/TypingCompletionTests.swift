import Foundation
import Testing
import YcodeDebug
@testable import YcodeLanguage

/// P-080: when the editors ask for completions while typing, the order of
/// what comes back, and the live issues held on the line being typed.
struct TypingCompletionTests {
    typealias T = CompletionTrigger

    @Test func wordStartsAndDotsAsk() {
        // "Co" on a new line: the "C" asks; the "o" does not (the list filters).
        #expect(T.kind(typed: "C", lineBeforeCaret: "        C") == .word)
        #expect(T.kind(typed: "o", lineBeforeCaret: "        Co") == nil)
        #expect(T.kind(typed: "_", lineBeforeCaret: "x = _") == .word)
        #expect(T.kind(typed: "f", lineBeforeCaret: "foo(f") == .word)
        #expect(T.kind(typed: ".", lineBeforeCaret: "counter.") == .member)
        #expect(T.kind(typed: ".", lineBeforeCaret: "    .") == .member)
        // Not in C-family files for ".", but words still ask there.
        #expect(T.kind(typed: ".", lineBeforeCaret: "s.", memberAccess: false) == nil)
        #expect(T.kind(typed: "N", lineBeforeCaret: "[N", memberAccess: false) == .word)
    }

    @Test func placesThatNeverAsk() {
        #expect(T.kind(typed: "x", lineBeforeCaret: "let x") == nil)
        #expect(T.kind(typed: "f", lineBeforeCaret: "    func f") == nil)
        #expect(T.kind(typed: "S", lineBeforeCaret: "struct S") == nil)
        #expect(T.kind(typed: "a", lineBeforeCaret: "// a") == nil)
        #expect(T.kind(typed: "a", lineBeforeCaret: "let s = \"a") == nil)
        #expect(T.kind(typed: "b", lineBeforeCaret: "/* b") == nil)
        #expect(T.kind(typed: "1", lineBeforeCaret: "x = 1") == nil)
        #expect(T.kind(typed: ".", lineBeforeCaret: "1.") == nil)
        #expect(T.kind(typed: ".", lineBeforeCaret: "0..") == nil)
        #expect(T.kind(typed: "a", lineBeforeCaret: "$a") == nil)
        #expect(T.kind(typed: "a", lineBeforeCaret: "#a") == nil)
        #expect(T.kind(typed: "ab", lineBeforeCaret: "ab") == nil) // a paste
        // After a closed string or comment it asks again.
        #expect(T.kind(typed: "C", lineBeforeCaret: "f(\"x\", C") == .word)
        #expect(T.kind(typed: "C", lineBeforeCaret: "/* x */ C") == .word)
        // Modules after import do ask.
        #expect(T.kind(typed: "F", lineBeforeCaret: "import F") == .word)
    }

    @Test func completionsComeInSortTextOrderWithIncompleteness() {
        let r: JSON = ["isIncomplete": true, "items": [
            ["label": "contentMargins", "sortText": "4985.03-contentMargins"],
            ["label": "Counter", "sortText": "0005.10-Counter"],
            ["label": "Codable", "sortText": "0005.20-Codable"],
            ["label": "CodingKey"],
        ]]
        let items = LSPClient.completionItems(r)
        // Without a sortText the label is the key ("4…" sorts before "C").
        #expect(items.map(\.label) == ["Counter", "Codable", "contentMargins", "CodingKey"])
        #expect(!items.contains { !$0.fromIncompleteList })
        // A plain array: complete, labels as keys.
        let plain = LSPClient.completionItems(.array([["label": "b"], ["label": "a"]]))
        #expect(plain.map(\.label) == ["a", "b"] && !plain.contains { $0.fromIncompleteList })
    }

    static func diagnostic(line: Int, _ message: String) -> LSPDiagnostic {
        LSPDiagnostic(["range": ["start": ["line": .number(Double(line)), "character": 8], "end": ["line": .number(Double(line)), "character": 10]],
                       "severity": 1, "message": .string(message)])
    }

    @Test func issuesOfTheLineBeingTypedWait() {
        var hold = LiveIssueHold(duration: 1.5)
        let t0 = Date(timeIntervalSince1970: 1000)
        let old = "struct A {\n    func f() {\n    }\n}\n"
        let new = "struct A {\n    func f() {\n        Co\n    }\n}\n"
        #expect(LiveIssueHold.firstChangedLine(old, new) == 2)
        #expect(LiveIssueHold.firstChangedLine(old, old) == nil)
        hold.noteEdit(path: "/p/A.swift", old: old, new: new, at: t0)
        let list = [Self.diagnostic(line: 2, "Cannot find 'Co' in scope"), Self.diagnostic(line: 0, "Other")]
        #expect(hold.visible(list, path: "/p/A.swift", at: t0.addingTimeInterval(0.4)).map(\.message) == ["Other"])
        #expect(hold.holdEnd("/p/A.swift", at: t0.addingTimeInterval(0.4)) == t0.addingTimeInterval(1.5))
        // Other files are not held; the hold ends after the pause.
        #expect(hold.visible(list, path: "/p/B.swift", at: t0).count == 2)
        #expect(hold.visible(list, path: "/p/A.swift", at: t0.addingTimeInterval(1.6)).count == 2)
        #expect(hold.holdEnd("/p/A.swift", at: t0.addingTimeInterval(1.6)) == nil)
        // The first open of a file holds nothing; a closed file forgets.
        hold.noteEdit(path: "/p/C.swift", old: nil, new: new, at: t0)
        #expect(hold.heldLine("/p/C.swift", at: t0) == nil)
        hold.forget("/p/A.swift")
        #expect(hold.heldLine("/p/A.swift", at: t0) == nil)
    }
}
