import Foundation
import Testing
import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 5's menu items on Linux (B5-MENUS2), as the macOS IDE's
/// (`MenusB5Tests`): Save All as Save's ⌥ alternate (P-001), the File
/// commands Save As…, Export…, Save As Workspace… (P-001), Product's and
/// Debug's glyphs (P-013), Integrate's Stage title (P-016) and the Editor
/// menu at Welcome (P-006).
@MainActor
@Suite(.serialized) struct ShellMenusB5Tests {
    func app() -> ShellAppModel {
        ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "menus-b5-\(UUID().uuidString)")!),
                      engine: { ScriptedEngine(lines: [], issues: []) })
    }

    func row(_ rows: [ShellMenuRow], _ path: String, _ action: String) -> ShellMenuRow? {
        rows.first { $0.path == path && $0.action == action }
    }

    /// P-001: Save All is Save's ⌥ alternate, so the File menu lists Save
    /// alone (the toolkit shows no alternates yet, L-048); ⌥⌘S still saves
    /// all (`ShellAlternateShortcuts`).
    @Test func saveAllIsAnAlternateOfSave() throws {
        let a = app()
        let pkg = try TempPackage()
        defer { pkg.remove() }
        #expect(a.open(path: pkg.url.path))
        let rows = ShellMenuModel.rows(a)
        #expect(row(rows, "File", "saveDocument:") != nil)
        #expect(row(rows, "File", "saveAllDocuments:") == nil)
        let saveAll = try #require(CommandTable.allCommands.first { $0.action == "saveAllDocuments:" })
        #expect(saveAll.isAlternate && saveAll.canonicalShortcut == "⌥⌘S")
        #expect(ShellCommand.saveAll.menuCommand == saveAll)
        #expect(ShellMenuModel.isEnabled(saveAll, app: a))
        a.workspace?.stop()
    }

    /// P-013: Run, Test, Profile, Analyze, Archive and Stop and Debug's
    /// steps carry their glyph (OpenViews' artwork of the macOS symbol's
    /// name); the other rows of those menus keep the glyph column.
    @Test func productAndDebugGlyphs() throws {
        let a = app()
        let rows = ShellMenuModel.rows(a)
        let product = ["runProduct:": "play", "testProduct:": "checkmark.diamond", "profileProduct:": "gauge.with.dots.needle.33percent",
                       "analyzeProduct:": "magnifyingglass", "archiveProduct:": "archivebox", "stopProduct:": "stop"]
        for (action, symbol) in product { #expect(row(rows, "Product", action)?.symbol == symbol, "\(action)") }
        for action in ["stepOver:", "stepInto:", "stepOut:"] { #expect(row(rows, "Debug", action)?.symbol != nil, "\(action)") }
        #expect(row(rows, "Product", "buildProduct:")?.symbol == nil)
        let productItems = try #require(CommandTable.menus.first { $0.0 == "Product" }?.1)
        #expect(ShellMenuModel.reservesGlyph(productItems))
        let fileItems = try #require(CommandTable.menus.first { $0.0 == "File" }?.1)
        #expect(!ShellMenuModel.reservesGlyph(fileItems))
    }

    /// P-016: in a workspace, "Stage Changes in Selected Files".
    @Test func stageTitleInAWorkspace() throws {
        let a = app()
        #expect(row(ShellMenuModel.rows(a), "Integrate", "scmStageSelected:")?.title == "Stage Selected Files")
        let pkg = try TempPackage()
        defer { pkg.remove() }
        #expect(a.open(path: pkg.url.path))
        #expect(row(ShellMenuModel.rows(a), "Integrate", "scmStageSelected:")?.title == "Stage Changes in Selected Files")
        a.workspace?.stop()
    }

    /// P-006: with only Welcome, Preview is unchecked.
    @Test func welcomePreviewIsUnchecked() {
        let r = row(ShellMenuModel.rows(app()), "Editor", "toggleCanvas:")
        #expect(r != nil && r?.isChecked == false)
    }

    /// P-006 (council round 11, B02), as macOS: with only Welcome, View ▸
    /// Inspectors holds Show Inspector alone, disabled, and Editor ▸ Layout
    /// lists Automatic, Editor on Left, Editor on Top, all disabled; in a
    /// workspace with no file open, Inspectors lists File, History, Quick
    /// Help and Hide Inspector.
    @Test func inspectorsAndLayoutAtWelcomeAndInAnEmptyWorkspace() throws {
        let a = app()
        let welcome = ShellMenuModel.rows(a)
        let inspectors = welcome.filter { $0.path == "View ▸ Inspectors" }
        #expect(inspectors.map(\.title) == ["Show Inspector"] && inspectors.allSatisfy { !$0.isEnabled })
        let layout = welcome.filter { $0.path == "Editor ▸ Layout" }
        #expect(layout.map(\.title) == ["Automatic", "Editor on Left", "Editor on Top"])
        #expect(layout.allSatisfy { !$0.isEnabled && !$0.isChecked })

        let pkg = try TempPackage()
        defer { pkg.remove() }
        #expect(a.open(path: pkg.url.path))
        #expect(a.workspace?.document == nil)
        let rows = ShellMenuModel.rows(a).filter { $0.path == "View ▸ Inspectors" }
        #expect(rows.map(\.title) == ["File", "History", "Quick Help", "Hide Inspector"])
        #expect(rows.prefix(3).map(\.shortcut) == ["⌥⌘1", "⌥⌘2", "⌥⌘3"])
        #expect(ShellMenuModel.rows(a).filter { $0.path == "Editor ▸ Layout" }.map(\.title) == ["Automatic", "Preview on Right", "Preview on Bottom"])
        a.workspace?.stop()
    }

    /// The menu bar's per-evaluation state (`ShellMenuModel.Pass`: one menu
    /// context and one Integrate state for all items) gives the titles and
    /// enabled states the per-item path gives, in a repository with changes.
    @Test func onePassGivesThePerItemAnswers() async throws {
        let a = app()
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["sh", "-c", "git init -q . && git add -A && git -c user.name=t -c user.email=t@t commit -qm init && echo x >> README.md"]
        git.currentDirectoryURL = pkg.url
        try git.run()
        git.waitUntilExit()
        #expect(a.open(path: pkg.url.path))
        let w = try #require(a.workspace)
        defer { w.stop() }
        await w.sourceControl.idle()
        w.open(pkg.path("README.md"))
        let pass = ShellMenuModel.Pass(a)
        for c in CommandTable.allCommands {
            let shell = ShellCommand.allCases.first { $0.action == (c.action, c.tag) }
            #expect(ShellMenuModel.command(for: c) == shell, "\(c.action)")
            #expect(ShellMenuModel.title(c, in: pass) == MenuTitles.title(for: c, in: w.menuContext) || c.action == "toggleToolbarShown:", "\(c.title)")
            if let shell { #expect(ShellMenuModel.isEnabled(c, in: pass) == a.isEnabled(shell), "\(c.action)") }
        }
        #expect(ShellMenuModel.isEnabled(try #require(CommandTable.command(action: "scmStageAll:")), in: pass))
    }

    /// Editor ▸ Invisibles, Scope Guides and Code Coverage (B5-EDITOR2
    /// draws them on Linux): enabled with an editor open, checked from the
    /// editing preferences, and choosing one switches its preference — the
    /// macOS items' titles and check marks.
    @Test func invisiblesScopeGuidesAndCodeCoverage() throws {
        let prefs = Preferences.shared
        let saved = (prefs.showInvisibles, prefs.scopeGuides, prefs.showCodeCoverage)
        defer { (prefs.showInvisibles, prefs.scopeGuides, prefs.showCodeCoverage) = saved }
        prefs.showInvisibles = false
        prefs.scopeGuides = .none
        prefs.showCodeCoverage = false
        let a = app()
        let pkg = try TempPackage()
        defer { pkg.remove() }
        #expect(a.open(path: pkg.url.path))
        let w = try #require(a.workspace)
        defer { w.stop() }
        let actions = ["toggleInvisibles:", "toggleScopeGuides:", "toggleCodeCoverage:"]
        func rows() -> [ShellMenuRow] { ShellMenuModel.rows(a).filter { actions.contains($0.action) } }
        #expect(rows().isEmpty)   // the Editor menu with no file open is the first block
        w.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        #expect(rows().map(\.title) == ["Code Coverage", "Invisibles", "Scope Guides"])
        #expect(rows().allSatisfy { $0.isEnabled && !$0.isChecked })
        for action in actions { ShellMenuModel.perform(try #require(CommandTable.command(action: action)), app: a) }
        #expect(prefs.showInvisibles && prefs.scopeGuides == .lines && prefs.showCodeCoverage)
        #expect(rows().allSatisfy { $0.isEnabled && $0.isChecked })
        for action in actions { ShellMenuModel.perform(try #require(CommandTable.command(action: action)), app: a) }
        #expect(!prefs.showInvisibles && prefs.scopeGuides == .none && !prefs.showCodeCoverage)
    }

    /// P-001: Save As…, Export… and Save As Workspace… are enabled once
    /// the window shows their dialogs, and write what macOS writes.
    @Test func fileCommandsWriteWhereTheDialogSays() throws {
        let a = app()
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let commands = ShellFileCommands.shared
        let installed = commands.dialogsInstalled
        defer {
            commands.dialogsInstalled = installed
            commands.request = nil
        }
        commands.dialogsInstalled = false
        #expect(a.open(path: pkg.url.path))
        let w = try #require(a.workspace)
        defer { w.stop() }
        // A package has no document of its own: Save As… needs a file.
        commands.dialogsInstalled = true
        #expect(a.fileCommandState("saveFileAs:") == false && a.fileCommandState("saveAsWorkspace:") == true)
        #expect(a.fileCommandState("openInNewWindow:") == false)
        let readme = pkg.path("README.md")
        w.open(readme)
        commands.dialogsInstalled = false
        #expect(a.fileCommandState("saveFileAs:") == false)
        commands.dialogsInstalled = true
        #expect(a.fileCommandState("saveFileAs:") == true && a.fileCommandState("exportFile:") == true)

        let b = try #require(w.editor?.buffer)
        b.setCaret(0)
        b.insertText("X")
        // Export…: a copy with the edit; the editor keeps the original.
        ShellMenuModel.perform(try #require(CommandTable.allCommands.first { $0.action == "exportFile:" }), app: a)
        let export = try #require(commands.request)
        #expect(export.kind == .export && export.defaultName == "README.md")
        let copy = pkg.url.deletingLastPathComponent().appendingPathComponent("Copy.md")
        try a.completeSave(export, to: copy)
        #expect(try String(contentsOf: copy, encoding: .utf8).hasPrefix("X# Demo") && w.document?.path == readme && commands.request == nil)
        // Save As…: the edit goes to the new file, which the editor shows; the original keeps what was saved.
        a.requestSave("saveFileAs:")
        let saveAs = try #require(commands.request)
        let moved = pkg.url.appendingPathComponent("Moved.md")
        try a.completeSave(saveAs, to: moved)
        #expect(try String(contentsOf: moved, encoding: .utf8).hasPrefix("X# Demo"))
        #expect(try String(contentsOf: URL(fileURLWithPath: readme), encoding: .utf8).hasPrefix("# Demo"))
        #expect(w.document?.path == moved.path)
        // Save As Workspace…: a workspace holding the package, opened.
        a.requestSave("saveAsWorkspace:")
        let ws = try #require(commands.request)
        #expect(ws.kind == .workspace && ws.defaultName == "Demo.xcworkspace")
        let dest = pkg.url.deletingLastPathComponent().appendingPathComponent("Demo")
        try a.completeSave(ws, to: dest)
        let data = try String(contentsOf: dest.appendingPathExtension("xcworkspace").appendingPathComponent("contents.xcworkspacedata"), encoding: .utf8)
        #expect(data.contains("location = \"group:Demo\""))
        #expect(a.workspace?.session.model.kind == .workspace)
        a.workspace?.stop()
    }
}
