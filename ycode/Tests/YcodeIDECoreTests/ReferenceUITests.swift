import Foundation
import Testing
@testable import YcodeIDECore

/// specs/ide/reference-ui.md: navigators, toolbar, menus, settings
/// defaults, behaviors, debug area, File inspector, jump bar.
@MainActor
@Suite(.serialized) struct ReferenceUITests {
    @Test func defaultsFollowReference() {
        let t = TestDefaults("reference-defaults")
        defer { t.remove() }
        let p = Preferences(defaults: t.defaults)
        #expect(!p.showFoldingRibbon && p.wrapLines && p.wrappedLineIndent == 4 && p.trimTrailingWhitespace)
        #expect(p.highlightSelectedSymbol && p.highlightDelay == 0.25)
        #expect(CommandTable.navigators == ["Project", "Source Control", "Bookmarks", "Find", "Issues", "Tests", "Debug", "Breakpoints", "Reports"])
        #expect(p.behavior(.buildErrors).showNavigator == 4)
        #expect(p.behavior(.buildSucceeds).notify && p.behavior(.buildFails).notify)
        #expect(p.behavior(.runPauses).showNavigator == 6 && p.behavior(.runPauses).showDebugArea == true)
        #expect(p.behavior(.runOutput).showDebugArea == true && p.behavior(.runEnds).hideDebugAreaIfNoOutput)
    }
}
