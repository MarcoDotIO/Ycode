import AppKit
import Foundation
import Testing
@testable import YcodeUI

@MainActor
@Suite struct NewItemTemplateTests {
    @Test func fileMenuNewSubmenu() throws {
        let file = try #require(CommandTable.menus.first { $0.0 == "File" })
        guard case .submenu("New", let items)? = file.1.first else { Issue.record("no New submenu"); return }
        let titles = items.compactMap { i -> String? in if case .command(let c) = i { return c.title } else { return nil } }
        #expect(titles == ["Conversation", "Conversation in New Tab", "Conversation in Editor Pane", "Tab", "Editor Pane On Right",
                           "Editor Pane Below", "Window Tab", "Window", "Empty File", "File from Clipboard", "File from Template…",
                           "Target…", "Project…", "Choose Template…", "Workspace…", "Group", "Group without Folder",
                           "Group from Selection", "Group from Selection without Folder", "Folder", "Folder from Selection"])
        #expect(CommandTable.command(titled: "File from Template…")?.shortcutText == "⌘N")
        #expect(CommandTable.command(titled: "Editor Pane On Right")?.shortcutText == "⌃⌘T")
        #expect(CommandTable.command(titled: "Editor Pane Below")?.shortcutText == "⌃⌥⌘T")
        #expect(CommandTable.command(titled: "Folder")?.shortcutText == "⌥⌘N")
    }

    @Test func commandWWithOneTab() {
        #expect(CloseShortcutRule.commandWTitle(tabCount: 1) == "Close Window")
        #expect(!CloseShortcutRule.showsSeparateCloseWindow(tabCount: 1))
        #expect(CloseShortcutRule.commandWTitle(tabCount: 2) == "Close Tab")
        #expect(CloseShortcutRule.showsSeparateCloseWindow(tabCount: 2))
    }

    @Test func newFileCatalog() {
        let s = FileTemplateCatalog.sections(platform: "iOS")
        #expect(s.map(\.title) == ["Source", "User Interface", "Test", "Core Data", "Resource", "Documentation", "Other"])
        #expect(s[0].entries.map(\.title) == ["Swift File", "Cocoa Touch Class", "Objective-C File", "Header File", "C File", "C++ File", "Metal File"])
        #expect(s[4].entries.count == 21)
        #expect(s[0].entries[0].defaultName == "File")
        let f = FileTemplateCatalog.sections(platform: "iOS", filter: "spritekit")
        #expect(f.map(\.title) == ["Resource"] && f[0].entries.count == 4)
        #expect(FileTemplateCatalog.platforms == ["iOS", "macOS", "watchOS", "tvOS", "visionOS", "DriverKit"])
        #expect(TemplateEntry("Metal File", ext: "metal").files(named: "Shaders").map(\.0) == ["Shaders.metal"])
    }

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

    @Test func newProjectPickerAndCatalog() {
        #expect(NewProjectPicker.rows.map(\.title) == ["App", "Command Line Tool", "Package…", "Playground", "Choose Template…"])
        #expect(NewProjectPicker.rows[0].subtitle == "SwiftUI app for iPhone, iPad, Mac & Vision Pro")
        #expect(ProjectTemplateCatalog.platforms == ["Multiplatform", "iOS", "macOS", "watchOS", "tvOS", "visionOS", "DriverKit", "Other"])
        #expect(ProjectTemplateCatalog.sections(platform: "iOS")[0].entries.map(\.title)
                == ["App", "Document App", "Game", "Augmented Reality App", "App Playground", "Sticker Pack App", "iMessage App", "Safari Extension App"])
        #expect(ProjectTemplateCatalog.sections(platform: "Multiplatform")[1].entries.map(\.title) == ["Framework"])
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

    @Test func projectOptions() {
        var o = ProjectOptions()
        #expect(o.testing == .swiftTesting && o.storage == .none && o.interface == .swiftUI)
        #expect(o.bundleIdentifier == "com.example.ProductName" && o.isBundleIdentifierPlaceholder && !o.isNextEnabled)
        #expect(!o.isCloudKitEnabled)
        o.productName = "My App"
        #expect(o.bundleIdentifier == "com.example.My-App" && o.isNextEnabled)
        o.setStorage(.swiftData)
        o.hostInCloudKit = true
        o.setStorage(.none)
        #expect(!o.hostInCloudKit && !o.isCloudKitEnabled)
        #expect(ProjectOptions.Testing.allCases.map(\.rawValue) == ["None", "XCTest for Unit and UI Tests", "Swift Testing with XCTest UI Tests"])
    }
}
