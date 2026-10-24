import Foundation
import Testing
@testable import YcodeUI

/// The scoring rule of specs/ide/open-quickly.md §Matching, value by value.
@Suite struct OpenQuicklySpecTests {
    @Test func scoreValues() {
        // "a" at index 0 of "ab": 1 + 8 = 9 → 90 − 2.
        #expect(FuzzyMatch.score("a", "ab") == 88)
        // "b" after "_": 1 + 6 → 70 − 3.
        #expect(FuzzyMatch.score("b", "a_b") == 67)
        // Case change: "B" in "aB": 1 + 5 → 60 − 2.
        #expect(FuzzyMatch.score("b", "aB") == 58)
        // Spaces in the query are ignored; case ignored; order required.
        #expect(FuzzyMatch.score("A B", "ab") == FuzzyMatch.score("ab", "ab"))
        #expect(FuzzyMatch.score("ba", "ab") == nil)
        #expect(FuzzyMatch.score("abc", "xyz") == nil)
    }

    @Test func limitAndTiesFilesFirst() {
        let sym = FuzzyMatch.Candidate(title: "View", detail: "a.swift", path: "/a.swift", line: 3, kind: .symbol)
        let file = FuzzyMatch.Candidate(title: "View", detail: "/", path: "/View", kind: .file)
        #expect(FuzzyMatch.search("view", in: [sym, file]).first?.kind == .file)
        let many = (0..<30).map { FuzzyMatch.Candidate(title: "v\($0)", detail: "", path: "/v\($0)", kind: .file) }
        #expect(FuzzyMatch.search("v", in: many).count == 20)
    }
}
