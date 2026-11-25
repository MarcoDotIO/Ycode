import Foundation
import Testing
@testable import YcodeIDECore

/// The shared toolbar overflow and Run menu tables (P-025, P-028) both
/// IDEs read.
struct ToolbarOverflowTests {
    /// The editor modes go first, the right group next from its right end
    /// (`window-layout.md` §2), then the title area, Back | Forward,
    /// Navigators, Run | Stop; Show Inspector never.
    @Test func leavingOrder() {
        #expect(ToolbarOverflow.leavingOrder.map(\.rawValue) == [
            "editorModes", "editorOptions", "addEditor", "issues", "scheme", "newConversation", "activity", "history", "leftPanes", "run",
        ])
        #expect(!ToolbarOverflow.leavingOrder.contains(.inspectorToggle))
        #expect(ToolbarOverflow.leaving(2) == [.editorModes, .editorOptions])
        #expect(ToolbarOverflow.leaving(0).isEmpty && ToolbarOverflow.leaving(-1).isEmpty)
    }

    /// The ranks keep the order the reference shows at 817 and 503 points.
    @Test func ranks() {
        let r = ToolbarOverflow.rank
        // Council round 12 (`window-layout.md` §2.3, §5.1): with the
        // navigator hidden Navigators and Run | Stop never enter "»", and
        // Back | Forward does at the minimum, after the title.
        #expect(r(.inspectorToggle) > r(.run) && r(.run) > r(.leftPanes) && r(.leftPanes) > r(.history))
        #expect(r(.history) > r(.activity))
        // Above the toolbar's fixed spaces (AppKit's high, 1000).
        #expect(r(.activity) > 1000)
        // The right group about standard, below the fixed spaces and above the modes.
        let right: [ToolbarOverflow.Item] = [.editorOptions, .addEditor, .issues, .scheme, .newConversation]
        #expect(right.map(r) == right.map(r).sorted() && right.allSatisfy { r($0) >= 0 && r($0) < 1000 })
        #expect(r(.editorModes) == -1000)
    }

    /// Each entry has a title; the segmented items list their segments with
    /// glyphs; sub-menus where the item has a menu or segments.
    @Test func entries() {
        for i in ToolbarOverflow.Item.allCases where i != .inspectorToggle {
            let e = ToolbarOverflow.entry(i)
            #expect(!e.title.isEmpty)
            #expect(e.symbol.isEmpty == [.activity, .scheme].contains(i), "\(i)")
        }
        #expect(ToolbarOverflow.segments(.leftPanes).map(\.title) == ["Navigators", "Coding Assistant"])
        #expect(ToolbarOverflow.segments(.history).map(\.title) == ["Go Back", "Go Forward"])
        #expect(ToolbarOverflow.segments(.editorModes).map(\.title) == ["Canvas", "Assistant", "Code Review"])
        #expect(ToolbarOverflow.segments(.editorModes).allSatisfy { !$0.symbol.isEmpty })
        let withSub = ToolbarOverflow.Item.allCases.filter { ToolbarOverflow.entry($0).hasSubmenu }
        #expect(withSub == [.leftPanes, .run, .history, .scheme, .issues, .addEditor, .editorOptions, .editorModes])
        #expect(ToolbarOverflow.entry(.activity).title == "Window Title/Activity")
        #expect(ToolbarOverflow.entry(.editorModes).title == "Editor Mode")
        #expect(ToolbarOverflow.issueRow(.error, count: 1) == "1 Error" && ToolbarOverflow.issueRow(.warning, count: 2) == "2 Warnings")
    }

    @Test func runMenu() {
        #expect(RunButtonMenu.rows.map(\.title) == ["Run", "Test", "Profile", "Analyze"])
        #expect(RunButtonMenu.rows.map(\.selector) == ["runProduct:", "testProduct:", "profileProduct:", "analyzeProduct:"])
        #expect(RunButtonMenu.rows.allSatisfy { !$0.symbol.isEmpty })
        #expect(abs(RunButtonMenu.holdDelay - 0.374) < 0.0005)
    }
}
