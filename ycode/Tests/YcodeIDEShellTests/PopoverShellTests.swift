import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 5's popovers on the Linux IDE's model (B5-POPOVERS,
/// `specs/ide/popovers.md`): the scheme and destination choosers (P-111,
/// P-113), New Scheme (P-112), Jump to Line (P-086), Quick Actions (P-086)
/// and Quick New Project (P-180). The views draw this state with the
/// shared metrics (`PopoverModelTests` checks those).
@MainActor
@Suite(.serialized) struct PopoverShellTests {
    func project() throws -> (URL, WorkspaceShellModel) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-popovers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o = ProjectOptions()
        o.productName = "Glass"
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        let url = try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
        return (dir, try WorkspaceShellModel(url: url, engine: ScriptedEngine(lines: [], issues: [])))
    }

    @Test func schemeChooserChoosesAndRunsNewScheme() throws {
        let (dir, m) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.popovers.anchors[.scheme] = CGRect(x: 600, y: 8, width: 140, height: 36)
        m.showSchemeChooser()
        #expect(m.popovers.chooser == .scheme)
        let rows = m.popovers.list.rows
        #expect(rows.first?.title == "Glass" && rows.first?.isChecked == true && m.popovers.list.highlighted == 0)
        #expect(rows.map(\.title).suffix(3) == ["Edit Scheme…", "New Scheme…", "Manage Schemes…"])
        let place = try #require(m.popovers.placement(.scheme))
        #expect(abs(place.body.midX - 670) <= 1 && place.arrowTip.y == 44)
        // Down to Edit Scheme… is skipped (disabled here), New Scheme… next.
        m.moveChooserHighlight(1)
        #expect(m.popovers.list.current?.title == "New Scheme…")
        #expect(m.chooseHighlightedRow() == .newScheme)
        #expect(m.popovers.chooser == nil, "a command closes the chooser")
        let sheet = try #require(m.popovers.newScheme)
        #expect(sheet.name == "Glass" && sheet.targets.map(\.name) == ["Glass"])
        m.popovers.newScheme?.name = "Glass Release"
        #expect(m.createNewScheme())
        #expect(m.popovers.newScheme == nil && m.scheme == "Glass Release" && m.schemes.contains("Glass Release"))
        // Escape (the view closes it) and a chosen scheme.
        m.showSchemeChooser()
        let i = try #require(m.popovers.list.rows.firstIndex { $0.title == "Glass" })
        #expect(m.chooseChooserRow(i) == .chose && m.scheme == "Glass" && m.popovers.chooser == nil)
    }

    @Test func destinationChooserListsThisComputerOnce() throws {
        let (dir, m) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.showDestinationChooser()
        let rows = m.popovers.list.rows
        #expect(rows.first?.title == "Recent" && rows[1].isChecked)
        let name = try #require(m.destination?.name)
        #expect(rows.filter { $0.title == name }.count == 1)
        #expect(rows.contains { $0.title == "Incompatible" && !$0.isEnabled })
        #expect(rows.last?.title == "Manage Devices…")
        m.setChooserFilter("zzz")
        #expect(!m.popovers.list.rows.contains { $0.kind == .choice })
        m.popovers.closeChooser()
        #expect(m.popovers.chooser == nil)
    }

    @Test func jumpToLineCapsuleJumpsAndFades() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let file = try #require(m.session.model.root.allFiles.first { $0.name.hasSuffix(".swift") })
        m.open(file.path ?? "")
        m.showJumpToLine()
        #expect(m.isJumpToLineShown && m.popovers.jumpText.isEmpty)
        #expect(m.jumpToLine("2") && !m.isJumpToLineShown, "Return jumps and closes")
        m.showJumpToLine()
        m.cancelJumpToLine()
        #expect(m.popovers.jumpFading && m.isJumpToLineShown, "Escape starts the fade")
        m.endJumpFade()
        #expect(!m.isJumpToLineShown && !m.popovers.jumpFading)
    }

    @Test func quickActionsAndQuickNewProject() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "popovers-b5-\(UUID().uuidString)")!),
                                engine: { ScriptedEngine(lines: [], issues: []) })
        #expect(app.open(path: pkg.url.path))
        let m = try #require(app.workspace)
        let commands = ShellQuickActions.collect(app: app)
        #expect(commands.contains { $0.title == "Build" && $0.path == "Product" })
        m.showQuickActions(commands)
        #expect(m.popovers.quickActions?.shown.isEmpty == true, "nothing listed before typing")
        m.setQuickActionsQuery("build")
        #expect(m.popovers.quickActions?.current?.title == "Build")
        m.showQuickNewProject()
        #expect(m.popovers.quickActions == nil, "one palette at a time")
        #expect(m.popovers.quickNewProject?.shown.count == NewProjectPicker.rows.count)
        m.moveQuickNewProject(1)
        #expect(m.popovers.quickNewProject?.current?.title == "Command Line Tool")
        m.closePalettes()
        #expect(m.popovers.quickNewProject == nil)
    }
}
