import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// The Linux shell's New Project sheet model (`templates.md` § Ycode
/// implementation): template step, options, save step, Create and open.
@MainActor
@Suite struct NewProjectShellTests {
    @Test func templateOptionsSaveAndOpen() throws {
        let suite = "ycode-shell-newproject-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = ShellAppModel(recentProjects: RecentProjects(defaults: defaults))
        app.newProjectDefaults = defaults
        #expect(app.isEnabled(.newProject))
        app.perform(.newProject)
        let m = try #require(app.newProject)
        #expect(m.step == .template && m.heading == "Choose a template for your new project:")
        m.setPlatform("macOS")
        m.select("macos.command-line-tool")
        #expect(m.isNextEnabled)
        m.next()
        #expect(m.step == .options && !m.isNextEnabled)
        m.setOption(TemplateOptionID.productName, "Shell Tool")
        m.setOption(TemplateOptionID.organizationIdentifier, "org.ycode.shell")
        #expect(m.flow.form.bundleIdentifier == "org.ycode.shell.Shell-Tool")
        m.next()
        #expect(m.step == .save && m.saveAs == "Shell Tool" && m.nextTitle == "Create")
        m.location = dir.path
        m.createGitRepository = false
        let created = try #require(app.createNewProject())
        #expect(app.newProject == nil)
        #expect(created.openURL.path.hasSuffix("Shell Tool/Shell Tool.xcodeproj"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Shell Tool/Shell Tool/main.swift").path))
        #expect(app.workspace != nil)
        // Remembered: the tab, the template and the save folder.
        let again = NewProjectShellModel(defaults: defaults)
        #expect(again.flow.platform == "macOS" && again.flow.selected?.id == "macos.command-line-tool" && again.location == dir.path)
        #expect(!again.createGitRepository)
        // Package… is the package chooser.
        app.showNewProject(row: 2)
        #expect(app.newProject?.flow.chooser == .package)
        app.cancelNewProject()
        #expect(app.newProject == nil)
    }
}
