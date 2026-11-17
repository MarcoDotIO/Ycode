import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// Beta 4's window items (B4-WINDOWS; `specs/ide/parity-inventory.md`):
/// New Project end to end from Welcome (P-177), its options step (P-178),
/// File ▸ New ▸ Project… at Welcome (P-179), Welcome's and the chooser's
/// placement (P-023), second windows (P-022) and the macOS New File
/// templates (P-184). Every window stays off the displays (the offscreen
/// guard); the save panel is a hook, as the guard answers panels with
/// Cancel. Screenshots (`cacheDisplay`, never the screen) go to
/// `.build-ide/b4-shots/`.
@MainActor
@Suite(.serialized) struct B4WindowsUITests {
    typealias ID = TemplateOptionID

    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-b4-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Ycode's own window content, rendered offscreen to a PNG.
    func shot(_ view: NSView, _ name: String) throws {
        let dir = worktree.appendingPathComponent(".build-ide/b4-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("macos-\(name).png"))
    }

    /// Runs the main loop until `done` holds (the project is created off
    /// the main thread) or the time is up.
    func waitUntil(_ seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// The flow's save panel and document opening, recorded.
    func installHooks(saveTo url: URL, into box: HookBox) -> () -> Void {
        let save = NewProjectFlow.runSavePanel, open = NewProjectFlow.openDocument
        NewProjectFlow.runSavePanel = { _, window, done in
            box.savedOn.append(window)
            done(url)
        }
        NewProjectFlow.openDocument = { url, done in
            box.opened.append(url)
            done([])
        }
        return {
            NewProjectFlow.runSavePanel = save
            NewProjectFlow.openDocument = open
        }
    }

    /// What the hooks saw.
    final class HookBox {
        var savedOn: [NSWindow] = []
        var opened: [URL] = []
    }

    // MARK: P-177, P-023, P-178

    @Test func newProjectFromWelcomeCreatesAndOpens() async throws {
        #expect(YcodeOffscreenIsActive())
        _ = NSApplication.shared
        let td = TestDefaults("b4-windows-np")
        let dir = try tempDir()
        defer { td.remove(); try? FileManager.default.removeItem(at: dir) }
        let box = HookBox()
        let restore = installHooks(saveTo: dir.appendingPathComponent("Walk Tool"), into: box)
        defer { restore() }
        let welcome = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        welcome.newProjectDefaults = td.defaults
        welcome.newProjectLocation = dir
        var openedFromWelcome: [URL] = []
        welcome.openWorkspace = { url, done in openedFromWelcome.append(url); done(true) }
        welcome.showWindow(nil)
        #expect(welcome.window?.isVisible == true)
        // P-023: the Window menu's list leaves Welcome out.
        #expect(welcome.window?.isExcludedFromWindowsMenu == true)

        // P-179: Choose Template… at Welcome; the sheet opens on an empty
        // workspace window and Welcome closes (P-023).
        let sheet = try #require(welcome.chooseProjectTemplate(nil))
        #expect(welcome.window?.isVisible == false)
        let sheetWindow = try #require(sheet.view.window)
        let host = try #require(sheetWindow.sheetParent)
        #expect(host.windowController is WorkspaceWindowController)
        #expect(host.title == "Untitled")

        #expect(sheet.select(templateID: "macos.command-line-tool"))
        sheet.nextClicked()
        #expect(sheet.flow.step == .options)
        // P-178: Product Name has focus; Tab goes to Organization Identifier and back.
        let name = try #require(sheet.fieldControls[ID.productName] as? NSTextField)
        let org = try #require(sheet.fieldControls[ID.organizationIdentifier] as? NSTextField)
        #expect(sheetWindow.firstResponder === name || (sheetWindow.firstResponder as? NSTextView)?.delegate === name)
        #expect(name.nextKeyView === org && org.nextKeyView === name)
        // P-178: help tags on every control.
        for (id, control) in sheet.fieldControls { #expect(control.toolTip?.isEmpty == false, "\(id)") }
        #expect(!sheet.nextButton.isEnabled)   // no organization yet (first project)
        name.stringValue = "Walk Tool"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        org.stringValue = "org.ycode.walk"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: org))
        #expect(sheet.nextButton.isEnabled)
        try shot(sheet.view, "new-project-options-filled")

        // P-177: Next shows the save step on the template sheet's own window.
        sheet.nextButton.performClick(nil)
        #expect(box.savedOn.count == 1)
        #expect(box.savedOn.first === sheetWindow)
        let project = dir.appendingPathComponent("Walk Tool/Walk Tool.xcodeproj")
        await waitUntil { !openedFromWelcome.isEmpty }
        #expect(openedFromWelcome.map(\.standardizedFileURL) == [project.standardizedFileURL])
        #expect(box.opened.map(\.standardizedFileURL).contains(project.standardizedFileURL))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Walk Tool/Walk Tool/main.swift").path))
        // The empty window closed; the project opens.
        #expect(!host.isVisible)
        let model = try WorkspaceModel(url: project)
        let proj = try #require(model.projects.values.first)
        #expect(proj.targets.compactMap { $0.string("name") } == ["Walk Tool"])

        // P-178: the next New Project starts from this organization.
        let next = NewProjectFlowModel(defaults: td.defaults)
        #expect(next.form.organizationIdentifier == "org.ycode.walk")
    }

    @Test func optionsStepDefaultsAndLanguage() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-windows-options")
        defer { td.remove() }
        let sheet = NewProjectSheetController(defaults: td.defaults)
        sheet.jump(to: "ios.app")
        _ = sheet.view
        // P-178: Testing System starts at Swift Testing for a first project.
        #expect(sheet.flow.form.value(ID.testingSystem) == "Swift Testing")
        let testing = try #require(sheet.fieldControls[ID.testingSystem] as? NSPopUpButton)
        #expect(testing.titleOfSelectedItem == "Swift Testing with XCTest UI Tests")
        // P-178: with SwiftUI, Language offers Swift only.
        let language = try #require(sheet.fieldControls[ID.language] as? NSPopUpButton)
        #expect(language.itemArray.filter { !$0.isHidden }.map(\.title) == ["Swift"])
        sheet.setOption(ID.interface, "Storyboard")
        #expect(language.itemArray.filter { !$0.isHidden }.map(\.title) == ["Swift", "Objective-C"])
        sheet.setOption(ID.interface, "SwiftUI")
        try shot(sheet.view, "new-project-options-swiftui")
        // A stored choice wins over the default.
        td.defaults.set([ID.testingSystem: "None"], forKey: "YcodeNewProjectOptions")
        #expect(NewProjectFlowModel(defaults: td.defaults, chooser: .project).sharedValues[ID.testingSystem] == "None")
    }

    // MARK: P-179, P-023

    @Test func welcomeNewProjectPickerAndPlacement() throws {
        _ = NSApplication.shared
        let td = TestDefaults("b4-windows-welcome")
        defer { td.remove() }
        let welcome = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        welcome.newProjectDefaults = td.defaults
        // P-179: File ▸ New ▸ Project… reaches Welcome through its window's
        // responder chain, so the item is enabled with only Welcome open.
        var r: NSResponder? = welcome.window
        while let x = r, x !== welcome { r = x.nextResponder }
        #expect(r === welcome)
        #expect(welcome.responds(to: #selector(WelcomeWindowController.newProject(_:))))
        #expect(welcome.responds(to: #selector(WelcomeWindowController.chooseProjectTemplate(_:))))
        welcome.showWindow(nil)
        let picker = welcome.newProject(nil)
        let pickerWindow = try #require(welcome.window?.attachedSheet)
        #expect(pickerWindow.isExcludedFromWindowsMenu)
        #expect(picker.rowViews.count == NewProjectPicker.rows.count)
        picker.cancelPicker()
        #expect(welcome.window?.attachedSheet == nil)
        #expect(!pickerWindow.isVisible)
        #expect(welcome.window?.isVisible == true)
        welcome.close()

        // P-023: Welcome opens on the screen holding the key workspace
        // window, and the chooser's window is centred on its screen.
        let left = NSRect(x: 0, y: 0, width: 1512, height: 982), right = NSRect(x: 1512, y: -200, width: 3440, height: 1440)
        let screens = [(left, "built-in"), (right, "external")]
        #expect(WelcomeWindowController.screen(containing: NSRect(x: 2000, y: 100, width: 1400, height: 880), screens: screens) == "external")
        #expect(WelcomeWindowController.screen(containing: NSRect(x: 1200, y: 100, width: 400, height: 300), screens: screens) == "built-in")
        #expect(WelcomeWindowController.screen(containing: nil, screens: screens) == nil)
        let centred = NewProjectFlow.centered(NSSize(width: 1400, height: 880), in: NSRect(x: 1512, y: -200, width: 3440, height: 1400))
        #expect(centred == NSRect(x: 2532, y: 60, width: 1400, height: 880))
        #expect(NewProjectFlow.centered(NSSize(width: 4000, height: 880), in: left).width == 1512)
    }

    // MARK: P-022

    @Test func secondWindowAndWindowTab() throws {
        _ = NSApplication.shared
        let model = try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false)
        wc.showWindow(nil)
        defer { wc.close() }
        // Both items are enabled.
        for action in [#selector(WorkspaceWindowController.newWorkspaceWindow(_:)), #selector(NSResponder.newWindowForTab(_:)),
                       #selector(WorkspaceWindowController.chooseProjectTemplate(_:))] {
            #expect(wc.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
            #expect(wc.responds(to: action))
        }
        // File ▸ New ▸ Window (⇧⌘T): a second window on the same workspace,
        // 22 points lower; closing it leaves the first.
        let second = wc.newWorkspaceWindow(nil)
        #expect(second !== wc)
        #expect(second.session.model.url == wc.session.model.url)
        let a = try #require(wc.window), b = try #require(second.window)
        #expect(b.isVisible)
        #expect(b.frame.minY == a.frame.minY - WorkspaceWindowController.cascadeOffset)
        #expect(b.frame.size == a.frame.size)
        second.close()
        #expect(!b.isVisible && a.isVisible)
        // File ▸ New ▸ Window Tab: a tab of the same window group.
        let tab = wc.newWorkspaceWindowTab(nil)
        defer { tab.close() }
        #expect(tab.session.model.url == wc.session.model.url)
        #expect(a.tabbedWindows?.contains { $0 === tab.window } == true)
    }

    // MARK: P-184

    @Test func newFileMacOSTemplates() throws {
        _ = NSApplication.shared
        let mac = FileTemplateCatalog.sections(platform: "macOS")
        #expect(mac[0].entries.map(\.title) == ["Swift File", "Cocoa Class", "Objective-C File", "Header File", "C File", "C++ File", "Metal File"])
        #expect(mac[1].title == "User Interface")
        #expect(mac[1].entries.map(\.title) == ["SwiftUI View", "Storyboard", "Application", "Window", "View"])
        let ios = FileTemplateCatalog.sections(platform: "iOS")
        #expect(ios[0].entries[1].title == "Cocoa Touch Class")
        #expect(ios[1].entries.map(\.title) == ["SwiftUI View", "Storyboard", "View", "Empty", "Launch Screen"])
        // The AppKit documents and the class template write files.
        for title in ["Application", "Window"] {
            let e = try #require(mac[1].entries.first { $0.title == title })
            let files = try FileTemplateCatalog.files(e, name: e.defaultName, platform: "macOS")
            #expect(files.count == 1 && files[0].0.hasSuffix(".xib") && files[0].1.contains("MacOSX.Cocoa"), "\(title)")
        }
        #expect(mac[0].entries[1].fileTemplate == .swiftClass)

        let sheet = NewFileSheetController(platform: "macOS")
        let view = sheet.view
        view.layoutSubtreeIfNeeded()
        let grid = try #require(sheet.grid)
        let first = grid.tiles.prefix(mac[0].entries.count)
        // Five tiles a row; Next 96 points wide.
        let columns = Set(first.map { $0.convert($0.bounds, to: nil).minX.rounded() })
        #expect(columns.count == NewFileSheetController.columns)
        #expect(NewFileSheetController.columns == 5)
        #expect(sheet.nextButton.frame.width == NewFileSheetController.nextButtonWidth)
        #expect(grid.tiles.allSatisfy { $0.style == .outlined })
        try shot(view, "new-file-macos")
    }
}
