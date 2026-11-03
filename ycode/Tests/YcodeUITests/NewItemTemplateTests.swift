import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

@MainActor
@Suite struct NewItemTemplateTests {
    @Test func sheetSteps() {
        var st = TemplateSheetSteps(count: 2)
        #expect(!st.isPreviousEnabled)
        st.next()
        #expect(st.isPreviousEnabled && st.isLast)
        let sheet = NewFileSheetController(platform: "iOS")
        #expect(sheet.selectedEntry?.title == "Swift File")
        sheet.setFilter("Markdown")
        #expect(sheet.selectedEntry?.title == "Markdown File")
    }

    @Test func lastTemplateIsPreselected() {
        let t = TestDefaults("last-template")
        defer { t.remove() }
        #expect(ProjectTemplateCatalog.lastSelection(t.defaults).title == "App")
        ProjectTemplateCatalog.setLastSelection(platform: "iOS", title: "Game", t.defaults)
        let sheet = NewProjectSheetController(defaults: t.defaults)
        #expect(sheet.platform == "iOS" && sheet.selectedEntry?.title == "Game")
        sheet.nextClicked()
        #expect(sheet.steps.index == 1 && sheet.previousButton.isEnabled && !sheet.nextButton.isEnabled)
        sheet.previousClicked()
        #expect(sheet.steps.index == 0)
    }
}
