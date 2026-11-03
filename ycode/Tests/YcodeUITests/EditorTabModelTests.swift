import Testing
import Foundation
@testable import YcodeUI

@Suite struct EditorTabModelTests {
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
