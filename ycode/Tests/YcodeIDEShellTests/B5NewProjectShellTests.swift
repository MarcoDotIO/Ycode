import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 5's New Project items in the Linux shell's model (B5-NEWPROJECT):
/// File ▸ New ▸ Project…'s compact picker and the save step's new-workspace
/// choice (P-187, L-154), the New File sheet (P-187, L-151), the shared
/// grid keyboard rule and measurements (P-181, P-182), and second
/// workspace windows (P-022).
@MainActor
@Suite struct B5NewProjectShellTests {
    func fixture() throws -> (ShellAppModel, UserDefaults, URL, () -> Void) {
        let suite = "ycode-shell-b5-np-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-b5np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: defaults))
        app.newProjectDefaults = defaults
        return (app, defaults, dir, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        })
    }

    /// Creates a macOS Command Line Tool through the sheet and opens it.
    func makeProject(_ app: ShellAppModel, in dir: URL, name: String = "Walk Tool") throws {
        app.showNewProject(row: 1)
        let m = try #require(app.newProject)
        #expect(m.step == .options)
        m.setOption(TemplateOptionID.productName, name)
        m.setOption(TemplateOptionID.organizationIdentifier, "org.ycode.b5")
        m.next()
        #expect(m.step == .save)
        m.location = dir.path
        m.createGitRepository = false
        #expect(app.createNewProject() != nil)
        #expect(app.workspace != nil)
    }

    @Test func compactPickerRows() throws {
        let (app, defaults, _, cleanUp) = try fixture()
        defer { cleanUp() }
        // File ▸ New ▸ Project… opens the compact picker.
        app.perform(.newProject)
        let m = try #require(app.newProject)
        #expect(m.step == .picker && m.heading == "New Project" && !m.isNextEnabled && !m.isPreviousEnabled)
        // Choose Template…: the template step.
        app.chooseNewProjectRow(NewProjectPicker.chooseTemplateIndex)
        #expect(m.step == .template)
        // Command Line Tool: its options; Package…: the package chooser.
        app.showNewProjectPicker()
        app.chooseNewProjectRow(1)
        #expect(app.newProject?.step == .options && app.newProject?.flow.selected?.id == "macos.command-line-tool")
        app.showNewProjectPicker()
        app.chooseNewProjectRow(2)
        #expect(app.newProject?.flow.chooser == .package)
        #expect(NewProjectPicker.lastRow(defaults) == 2)
        // Choose Template… from the menu (⌥⇧⌘N) skips the picker.
        app.cancelNewProject()
        #expect(app.menuActionState("chooseProjectTemplate:")?.enabled == true)
        #expect(app.performMenuAction("chooseProjectTemplate:"))
        #expect(app.newProject?.step == .template)
    }

    @Test func saveStepOffersANewWorkspace() throws {
        let (app, _, dir, cleanUp) = try fixture()
        defer { cleanUp() }
        try makeProject(app, in: dir)
        app.showNewProject(row: 1)
        let m = try #require(app.newProject)
        #expect(m.openContainer?.pathExtension == "xcodeproj")
        #expect(!m.offersNewWorkspace && m.newWorkspaceForProject)
        m.addToOpenContainer = true
        #expect(m.offersNewWorkspace)
    }

    @Test func newFileSheetCreatesAFileInTheProject() throws {
        let (app, _, dir, cleanUp) = try fixture()
        defer { cleanUp() }
        #expect(app.menuActionState("newFile:")?.enabled == false)
        try makeProject(app, in: dir)
        #expect(app.menuActionState("newFile:")?.enabled == true)
        #expect(app.performMenuAction("newFile:"))
        let f = try #require(app.newFile)
        #expect(f.platform == "macOS" && f.step == .template && f.heading == FileTemplateCatalog.heading)
        #expect(f.groups.first?.title == "Walk Tool" && f.targets == ["Walk Tool"])
        f.select("Swift File")
        f.next()
        #expect(f.step == .save && f.saveAs == "File")
        f.saveAs = "Extra"
        // The group of the sources folder.
        if let i = f.groups.firstIndex(where: { $0.directory.lastPathComponent == "Walk Tool" && $0.depth > 0 }) { f.groupIndex = i }
        let urls = try #require(app.createNewFile())
        #expect(app.newFile == nil)
        let file = try #require(urls.first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(app.workspace?.document?.path == file.path)
        // The project lists the file (a synchronized folder or a reference).
        let names = app.workspace.map { w in Self.names(w.root) } ?? []
        #expect(names.contains("Extra.swift"), "\(names)")
        // An existing name fails and keeps the sheet.
        app.showNewFile()
        let again = try #require(app.newFile)
        again.setPlatform("macOS")
        again.select("Swift File")
        again.next()
        again.saveAs = "Extra"
        again.groupIndex = f.groupIndex
        #expect(app.createNewFile() == nil && again.error != nil && app.newFile != nil)
    }

    static func names(_ item: NavigatorItem) -> [String] { [item.name] + (item.children ?? []).flatMap(names) }

    @Test func secondWorkspaceWindow() throws {
        let (app, _, dir, cleanUp) = try fixture()
        defer { cleanUp() }
        #expect(app.menuActionState("newWorkspaceWindow:")?.enabled == false)
        try makeProject(app, in: dir)
        app.workspaceWindowCount = 1
        var opened: [String] = []
        app.openWindow = { opened.append($0) }
        #expect(app.menuActionState("newWorkspaceWindow:")?.enabled == true)
        #expect(app.menuActionState("newWindowForTab:")?.enabled == false)
        #expect(app.performMenuAction("newWorkspaceWindow:"))
        #expect(opened == [ShellAppModel.workspaceWindowID])
        app.workspaceWindowCount = 2
        var closed = 0
        app.closeActiveWorkspaceWindow = { closed += 1; return true }
        // Close Window closes the active window only; the workspace stays.
        #expect(app.performMenuAction("performClose:"))
        #expect(closed == 1 && app.workspace != nil)
        // ⌘W without a file does the same while two windows are open.
        app.workspace?.closeCurrentDocument()
        if app.workspace?.document == nil, app.workspace?.structuredEditor == nil {
            #expect(app.performMenuAction("closeTab:"))
            #expect(closed == 2 && app.workspace != nil)
        }
        // With one window, Close Window closes the workspace as before.
        app.workspaceWindowCount = 1
        #expect(app.performMenuAction("performClose:"))
        #expect(closed == 2)
    }

    @Test func sharedMeasurementsAndKeyboard() {
        typealias M = TemplateChooserMetrics
        #expect(M.sheetWidth == 720 && M.sheetHeight == 480 && M.filterWidth == 202 && M.columns == 5 && M.columnPitch == 137)
        #expect(M.fieldWidth == 267 && M.rowHeight == 20 && M.rowPitch == 33 && M.popUpFillDark == 0x2F2F31)
        #expect(TemplateGridNavigation.index(moving: .right, from: 0, sectionCounts: [3, 2], columns: 5) == 1)
        #expect(TemplateGridNavigation.index(moving: .down, from: 1, sectionCounts: [3, 2], columns: 5) == 4)
        #expect(TemplateGridNavigation.index(moving: .up, from: 3, sectionCounts: [3, 2], columns: 5) == 0)
        #expect(TemplateGridNavigation.index(moving: .left, from: nil, sectionCounts: [], columns: 5) == nil)
    }
}
