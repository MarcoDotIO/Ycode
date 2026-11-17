import Foundation
import Testing
@testable import YcodeIDECore

@MainActor
@Suite(.serialized) struct EditorMenuGoldenTests {
    /// Dynamic titles (§1.3) of the source Editor menu.
    @Test func editorTitlesInContext() {
        var ctx = MenuContext()
        ctx.fileName = "Model.swift"
        #expect(MenuTitles.title(generic: "Format File", in: ctx) == "Format File with \u{2018}swift-format\u{2019}")
        #expect(MenuTitles.title(generic: "Format Selection", in: ctx) == "Format Selection with \u{2018}swift-format\u{2019}")
        ctx.fileName = "main.c"
        #expect(MenuTitles.title(generic: "Format File", in: ctx) == "Format File with \u{2018}clang-format\u{2019}")
        ctx.fileName = "data.json"
        #expect(MenuTitles.title(generic: "Format Selection", in: ctx) == "Format Selection with \u{2018}clang-format\u{2019}")
        #expect(MenuTitles.title(generic: "Comment Selection", in: ctx) == "Toggle Comments")
        ctx.fileName = "notes.txt"
        #expect(MenuTitles.title(generic: "Format File", in: ctx) == "Format File")
        // P-007: the reference keeps "Show All Issues" while issues show.
        #expect(MenuTitles.title(generic: "Show All Issues", in: ctx) == "Show All Issues")
        ctx.inlineIssuesShown = false
        #expect(MenuTitles.title(generic: "Show All Issues", in: ctx) == "Show All Issues")
        #expect(MenuTitles.title(generic: "Format File", in: nil) == "Format File")
    }
}
