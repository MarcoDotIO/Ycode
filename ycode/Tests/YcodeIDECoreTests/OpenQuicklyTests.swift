import Foundation
import Testing
@testable import YcodeIDECore

@Suite struct FuzzyMatchTests {
    @Test func scoring() {
        #expect(FuzzyMatch.score("gre", "Greeter") != nil)
        #expect(FuzzyMatch.score("xyz", "Greeter") == nil)
        #expect(FuzzyMatch.score("rg", "Greeter") == nil) // order matters
        // Prefix and word starts beat scattered letters.
        #expect(FuzzyMatch.score("wwc", "WorkspaceWindowController")! > FuzzyMatch.score("wwc", "awkwardwindowcase")!)
        #expect(FuzzyMatch.score("main", "main.swift")! > FuzzyMatch.score("main", "domain.swift")!)
        // Shorter candidates win ties.
        #expect(FuzzyMatch.score("ab", "ab")! > FuzzyMatch.score("ab", "abcdef")!)
    }
}
