import AppKit
import Foundation
import Testing
@testable import YcodeUI

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

@MainActor
@Suite(.serialized) struct OpenQuicklyTests {
    @Test func searchesFilesAndSymbolsAndOpens() async throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        let oq = wc.openQuickly(nil)
        await wc.workspaceCandidatesIdle()   // the index is read in the background
        oq.search("greet")
        #expect(oq.results.map(\.title).prefix(2) == ["greet", "Greeter"])
        #expect(oq.results.first?.kind == .symbol && oq.results.first?.line == 5)
        oq.search("pkg")
        #expect(oq.results.first?.title == "Package.swift")
        let window = NSWindow(contentRect: oq.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = oq.view
        oq.search("gr")
        _ = try WindowSnapshotTests().render(oq.view, to: "open-quickly.png")
        // Return opens the selection at its line.
        oq.search("greet")
        oq.openSelected()
        #expect(wc.editor.fileURL?.lastPathComponent == "main.swift" && wc.editor.currentLine == 5)
    }
}
