import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 4's window items in the Linux shell's model (B4-WINDOWS):
/// Window ▸ Welcome keeps the workspace (P-216), New Project from Welcome
/// moves to a workspace window and creates and opens a project (P-177),
/// sheets are not doubled while Welcome is beside a workspace, and the
/// options step's defaults (P-178).
@MainActor
@Suite struct B4WindowsShellTests {
    func fixture() throws -> (ShellAppModel, UserDefaults, URL, () -> Void) {
        let suite = "ycode-shell-b4-windows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-b4w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: defaults))
        app.newProjectDefaults = defaults
        return (app, defaults, dir, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        })
    }

    /// Welcome's New Project, as far as the model goes: the sheet is a
    /// workspace window's; Create opens the project.
    @Test func newProjectFromWelcomeOnAWorkspaceWindow() throws {
        let (app, defaults, dir, cleanUp) = try fixture()
        defer { cleanUp() }
        #expect(app.workspace == nil && app.workspaceWindowCount == 0)
        app.showNewProject()
        let m = try #require(app.newProject)
        // P-177: never on Welcome (its 480-point window would clamp it).
        #expect(!app.presentsNewProject(in: .welcome))
        #expect(app.presentsNewProject(in: .workspace))
        // The workspace window opens behind it.
        app.workspaceWindowCount = 1
        m.setPlatform("macOS")
        m.select("macos.command-line-tool")
        m.next()
        #expect(m.step == .options)
        // P-178: Product Name is the first text field (it takes focus).
        #expect(m.flow.form.visibleFields.first { $0.kind == .text }?.id == TemplateOptionID.productName)
        #expect(m.flow.form.visibleFields.allSatisfy { !$0.help.isEmpty })
        m.setOption(TemplateOptionID.productName, "Walk Tool")
        m.setOption(TemplateOptionID.organizationIdentifier, "org.ycode.walk")
        m.next()
        #expect(m.step == .save)
        m.location = dir.path
        m.createGitRepository = false
        let opens = app.openCount
        let created = try #require(app.createNewProject())
        #expect(app.newProject == nil && app.workspace != nil)
        #expect(app.openCount == opens + 1)
        #expect(created.openURL.lastPathComponent == "Walk Tool.xcodeproj")
        #expect(app.workspace?.document?.name == "main.swift")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Walk Tool/Walk Tool/main.swift").path))
        // P-178: the next New Project starts from the organization used.
        #expect(NewProjectShellModel(defaults: defaults).flow.form.organizationIdentifier == "org.ycode.walk")
    }

    /// P-216: Window ▸ Welcome opens Welcome's window beside the workspace.
    @Test func welcomeBesideTheWorkspace() throws {
        let (app, _, dir, cleanUp) = try fixture()
        defer { cleanUp() }
        let pkg = dir.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Sources/Pkg"), withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Pkg\", targets: [.target(name: \"Pkg\")])\n"
            .write(to: pkg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let x = 1\n".write(to: pkg.appendingPathComponent("Sources/Pkg/Pkg.swift"), atomically: true, encoding: .utf8)
        #expect(app.open(path: pkg.path))
        app.workspaceWindowCount = 1
        var opened: [String] = []
        app.openWindow = { opened.append($0) }
        #expect(app.isEnabled(.welcome))
        app.perform(.welcome)
        #expect(opened == [ShellAppModel.welcomeWindowID])
        #expect(app.workspace != nil)
        // Sheets and alerts stay on the workspace window.
        #expect(!app.presents(in: .welcome) && app.presents(in: .workspace))
        app.workspaceWindowCount = 0
        #expect(app.presents(in: .welcome))
    }

    /// P-178: Testing System starts at Swift Testing; a stored choice wins.
    @Test func testingSystemDefault() throws {
        let (_, defaults, _, cleanUp) = try fixture()
        defer { cleanUp() }
        let m = NewProjectShellModel(defaults: defaults)
        m.select("ios.app")
        #expect(m.flow.form.value(TemplateOptionID.testingSystem) == "Swift Testing")
        #expect(!m.flow.form.isAllowed(TemplateOptionID.language, "Objective-C"))
        defaults.set([TemplateOptionID.testingSystem: "XCTest"], forKey: "YcodeNewProjectOptions")
        let again = NewProjectShellModel(defaults: defaults)
        again.select("ios.app")
        #expect(again.flow.form.value(TemplateOptionID.testingSystem) == "XCTest")
    }
}
