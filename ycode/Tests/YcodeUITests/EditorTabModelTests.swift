import Testing
import Foundation
@testable import YcodeUI

@Suite struct EditorTabModelTests {
    @Test func openTargetReusesUnpinnedAndAddsAfterPinned() {
        let tabs = [["/a.swift"], ["/b.swift"]]
        #expect(EditorTabPolicy.openTarget(path: "/c.swift", currentPath: "/a.swift", currentPinned: false, openInTabs: false, tabPaths: tabs) == .current)
        #expect(EditorTabPolicy.openTarget(path: "/c.swift", currentPath: "/a.swift", currentPinned: true, openInTabs: false, tabPaths: tabs) == .newTab)
        #expect(EditorTabPolicy.openTarget(path: "/b.swift", currentPath: "/a.swift", currentPinned: true, openInTabs: false, tabPaths: tabs) == .select(1))
        #expect(EditorTabPolicy.openTarget(path: "/a.swift", currentPath: "/a.swift", currentPinned: true, openInTabs: false, tabPaths: tabs) == .current)
        #expect(EditorTabPolicy.openTarget(path: "/c.swift", currentPath: nil, currentPinned: true, openInTabs: true, tabPaths: tabs) == .current)
        #expect(EditorTabPolicy.openTarget(path: "/c.swift", currentPath: "/a.swift", currentPinned: false, openInTabs: true, tabPaths: tabs) == .newTab)
    }

    @Test func barTitlesHoverAndSelection() {
        #expect(!EditorTabPolicy.isBarVisible(shown: false, tabCount: 1))
        #expect(EditorTabPolicy.isBarVisible(shown: true, tabCount: 1))
        #expect(EditorTabPolicy.isBarVisible(shown: false, tabCount: 2))
        let u = URL(fileURLWithPath: "/x/ObsKit.swift")
        #expect(EditorTabPolicy.title(for: u) == "ObsKit")
        #expect(EditorTabPolicy.toolTip(for: u, groupPath: "Obs \u{203A} Sources \u{203A} ObsKit") == "ObsKit.swift\nObs \u{203A} Sources \u{203A} ObsKit")
        #expect(EditorTabPolicy.showsCloseButton(tab: 1, hovered: 1) && !EditorTabPolicy.showsCloseButton(tab: 0, hovered: 1) && !EditorTabPolicy.showsCloseButton(tab: 0, hovered: nil))
        #expect(EditorTabPolicy.selectionAfterClosing(0, selected: 2, count: 3) == 1)
        #expect(EditorTabPolicy.selectionAfterClosing(2, selected: 2, count: 3) == 1)
        #expect(EditorTabPolicy.selectionAfterClosing(1, selected: 0, count: 3) == 0)
    }

    @Test func closeCommands() {
        #expect(EditorCloseCommand.allCases.map(\.shortcut) == ["⌘W", "⌃⌘W", "⌃⇧⌘W", "⇧⌘W", "⌃⌥⌘W"])
        #expect(EditorCloseCommand.allCases.map { $0.title(fileName: "main.swift", isPackage: true) }
            == ["Close Tab", "Close \u{201C}main.swift\u{201D}", "Close Editor Pane", "Close Window", "Close Package"])
        #expect(EditorCloseCommand.workspace.title(fileName: nil, isPackage: false) == "Close Project")
        #expect(!EditorCloseCommand.editorPane.isEnabled(paneCount: 1) && EditorCloseCommand.editorPane.isEnabled(paneCount: 2))
    }

    @Test func variableScopesAndMetadata() {
        #expect(VariableScope.allCases.map(\.title) == ["Auto", "Local Variables", "All Variables, Registers, Globals and Statics"])
        let names = ["count", "$rax", "Registers", "self"]
        #expect(VariableScope.auto.filter(names, text: "") == ["count", "self"])
        #expect(VariableScope.local.filter(names, text: "se") == ["self"])
        #expect(VariableScope.all.filter(names, text: "") == names)
        var m = ConsoleMetadata()
        #expect(m.enabled && m.checked.isEmpty && ConsoleMetadata.columns.count == 6)
        m.set(3, true); m.type = true
        #expect(m.isOn(3) && m.type && !m.timestamp)
        m.set(9, true)
        #expect(m.checked == [0, 3])
    }

    @MainActor @Test func hoverShowsOnlyThatTabsCloseButton() {
        let area = EditorAreaController(first: SourceEditorController())
        _ = area.view
        area.newTab()
        #expect(area.closeButtons.count == 2 && area.closeButtons.allSatisfy(\.isHidden))
        area.hover(1)
        #expect(area.closeButtons.map(\.isHidden) == [true, false])
        #expect(area.closeTab(at: 1) && area.tabs.count == 1 && area.selectedTab == 0)
    }
}
