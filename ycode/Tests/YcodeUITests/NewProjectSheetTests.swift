import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let worktree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The New Project flow in the AppKit IDE (`templates.md` § Ycode
/// implementation): the compact picker, the template sheet's tabs, filter
/// and grid, the options step, the save accessory, and the result opening.
/// Screenshots of Ycode's own sheet (offscreen `cacheDisplay`, never the
/// screen) go next to the worktree as `new-project-*.png`.
@MainActor
@Suite(.serialized) struct NewProjectSheetTests {
    typealias ID = TemplateOptionID

    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-newproject-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Renders a view in an offscreen window with an appearance.
    func snapshot(_ view: NSView, _ name: String, dark: Bool, size: NSSize = NSSize(width: 760, height: 540)) throws -> URL {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = worktree.deletingLastPathComponent().appendingPathComponent("new-project-\(name)-\(dark ? "dark" : "light").png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func host() throws -> (WorkspaceWindowController, TestDefaults, URL) {
        _ = NSApplication.shared
        let model = try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false)
        let td = TestDefaults("new-project-ui")
        wc.templateDefaults = td.defaults
        let dir = try tempDir()
        wc.newProjectLocation = dir
        wc.untitledProjectsLocation = dir.appendingPathComponent("Untitled")
        return (wc, td, dir)
    }

    @Test func pickerRows() throws {
        let (wc, td, dir) = try host()
        defer { td.remove(); try? FileManager.default.removeItem(at: dir) }
        #expect(NewProjectPicker.rows.map(\.title) == ["App", "Command Line Tool", "Package…", "Playground", "Choose Template…"])
        // App: the untitled multiplatform project, no sheet.
        #expect(wc.projectPickerChose(0) == nil)
        #expect(wc.lastCreatedProject?.lastPathComponent == "MyApp.xcodeproj")
        // Command Line Tool: its options step.
        let tool = try #require(wc.projectPickerChose(1))
        #expect(tool.steps.index == 1 && tool.selectedTemplate?.id == "macos.command-line-tool")
        // Package…: the package chooser.
        let pkg = try #require(wc.projectPickerChose(2))
        #expect(pkg.flow.chooser == .package && pkg.platforms == ["Multiplatform", "macOS"] && pkg.selectedTemplate?.id == "package.library")
        // Playground: the App Playground options step (Ycode's choice).
        #expect(wc.projectPickerChose(3)?.selectedTemplate?.id == "ios.app-playground")
        #expect(NewProjectPicker.lastRow(td.defaults) == 3)
    }

    @Test func templateSheetTabsFilterOptionsSaveAndOpen() throws {
        let (wc, td, dir) = try host()
        defer { td.remove(); try? FileManager.default.removeItem(at: dir) }
        let sheet = wc.chooseProjectTemplate()
        _ = sheet.view
        #expect(sheet.heading == "Choose a template for your new project:")
        // Every tab shows its sections; the grid has a tile per template.
        for tab in ProjectTemplateCatalog.platforms {
            sheet.setPlatform(tab)
            #expect(sheet.grid?.tiles.count == ProjectTemplates.templates(platform: tab).count, "\(tab)")
            #expect(sheet.grid?.headers.map(\.stringValue) == ProjectTemplates.sections(platform: tab).map(\.title), "\(tab)")
        }
        sheet.setPlatform("iOS")
        for dark in [false, true] { _ = try snapshot(sheet.view, "templates", dark: dark) }
        // The filter narrows the grid; nothing matching disables Next.
        sheet.setFilter("Library")
        #expect(sheet.grid?.tiles.map(\.entry.title) == ["Static Library", "Metal Library"])
        sheet.setFilter("zzz")
        #expect(!sheet.nextButton.isEnabled && sheet.captionLabel.stringValue.hasPrefix("No templates match"))
        sheet.setFilter("")
        // An unavailable template keeps Next disabled with its reason.
        sheet.setPlatform("Multiplatform")
        #expect(sheet.select(title: "Foveated Streaming App") && !sheet.nextButton.isEnabled)
        // Double-click (the grid's choose) is Next.
        sheet.setPlatform("iOS")
        let tile = try #require(sheet.grid?.tiles.first { $0.entry.templateID == "ios.app" })
        tile.onDoubleClick?(tile.entry)
        #expect(sheet.steps.index == 1 && sheet.previousButton.isEnabled && !sheet.nextButton.isEnabled)
        #expect(sheet.titleLabel.stringValue == "Choose options for your new project:")
        // The options step: the iOS App rows in order, Bundle Identifier grey, CloudKit disabled.
        let labels = sheet.flow.form.visibleFields.map(\.label)
        #expect(labels == ["Product Name", "Team", "Organization Identifier", "Bundle Identifier", "Interface", "Language", "Testing System", "Storage",
                           "Host in CloudKit"])
        let bundle = try #require(sheet.fieldControls[ID.bundleIdentifier] as? NSTextField)
        #expect(bundle.stringValue == "com.yourcompany.ProductName")
        #expect((sheet.fieldControls[ID.hostInCloudKit] as? NSButton)?.isEnabled == false)
        let testing = try #require(sheet.fieldControls[ID.testingSystem] as? NSPopUpButton)
        #expect(testing.itemTitles == TemplateFields.testingChoices)
        // Typing the name updates the derived identifier and enables Next.
        let name = try #require(sheet.fieldControls[ID.productName] as? NSTextField)
        name.stringValue = "Sheet App"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        let org = try #require(sheet.fieldControls[ID.organizationIdentifier] as? NSTextField)
        org.stringValue = "org.ycode.ui"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: org))
        #expect(bundle.stringValue == "org.ycode.ui.Sheet-App" && sheet.nextButton.isEnabled)
        // Storyboard makes Objective-C available; SwiftData is then disabled.
        let interface = try #require(sheet.fieldControls[ID.interface] as? NSPopUpButton)
        interface.selectItem(withTitle: "Storyboard")
        sheet.readFields()
        let language = try #require(sheet.fieldControls[ID.language] as? NSPopUpButton)
        #expect(language.item(withTitle: "Objective-C")?.isEnabled == true)
        let storage = try #require(sheet.fieldControls[ID.storage] as? NSPopUpButton)
        #expect(storage.item(withTitle: "SwiftData")?.isEnabled == false)
        interface.selectItem(withTitle: "SwiftUI")
        sheet.readFields()
        storage.selectItem(withTitle: "SwiftData")
        sheet.readFields()
        #expect((sheet.fieldControls[ID.hostInCloudKit] as? NSButton)?.isEnabled == true)
        for dark in [false, true] { _ = try snapshot(sheet.view, "options", dark: dark) }
        // Previous keeps the values.
        sheet.previousClicked()
        #expect(sheet.steps.index == 0)
        sheet.nextClicked()
        #expect(sheet.flow.form.productName == "Sheet App" && sheet.flow.form.value(ID.storage) == "SwiftData")
        // Next is the save step; headless, it creates in the location.
        sheet.nextClicked()
        let created = try #require(wc.lastCreated)
        #expect(created.openURL.lastPathComponent == "Sheet App.xcodeproj" && created.entryFile?.lastPathComponent == "ContentView.swift")
        // The result opens in a workspace window on its initial file.
        let opened = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: created.openURL)), loadDestinations: false,
                                               startLanguageService: false)
        opened.open(path: try #require(created.entryFile).path, line: nil)
        #expect(opened.editor.fileURL?.lastPathComponent == "ContentView.swift")
        #expect(opened.session.model.root.allFiles.contains { $0.name == "Item.swift" })
        // The choices are remembered for the next sheet.
        let next = NewProjectSheetController(defaults: td.defaults)
        #expect(next.platform == "iOS" && next.selectedTemplate?.id == "ios.app")
        #expect(next.flow.form.organizationIdentifier == "org.ycode.ui" && next.flow.form.productName.isEmpty)
    }

    @Test func saveAccessoryRowsAndGroups() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = try #require(ProjectTemplates.find("macos.app"))
        let proj = try ProjectGenerator.create(d, d.makeForm([ID.productName: "Host", ID.organizationIdentifier: "org"]), in: dir)
        let a = NewProjectSaveAccessory(containers: [proj], createGitRepository: true, defaultContainer: proj)
        #expect(a.addToPopUp.itemTitles.first == NewProjectSaveAccessory.dontAdd && a.addTo == proj)
        #expect(a.groupPopUp.isEnabled && a.groupPopUp.itemTitles.first == "Host")
        #expect(a.newWorkspaceBox.isEnabled && a.save.createGitRepository)
        a.chooseContainer(0)
        #expect(a.addTo == nil && !a.groupPopUp.isEnabled)
        for dark in [false, true] { _ = try snapshot(a.view, "save-accessory", dark: dark, size: NSSize(width: 500, height: 132)) }
    }
}
