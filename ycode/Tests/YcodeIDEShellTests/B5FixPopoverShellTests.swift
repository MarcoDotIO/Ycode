import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// The beta 5 fix round's popovers on the Linux IDE's model
/// (B5-FIX-POPOVERS): the destination chooser opens on the checked row and
/// hover waits for the pointer to move (P-113, `popovers.md` §2.7); Quick
/// Actions ranks and titles its rows as §5.1 (P-086); Quick Help for a
/// module named in an import (P-083, §4.1).
@MainActor
@Suite(.serialized) struct B5FixPopoverShellTests {
    @Test func destinationChooserKeepsTheCheckedRowUntilThePointerMoves() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.showDestinationChooser()
        let checked = try #require(m.popovers.list.current)
        #expect(checked.isChecked && checked.kind == .choice)
        let rows = m.popovers.list.rows
        if let s = rows.firstIndex(where: { $0.title == "Simulators" }), let setUp = rows.firstIndex(where: { $0.title == WorkspaceShellModel.setUpSimulatorTitle }) {
            #expect(setUp > s, "Ycode's row closes the Simulators section")
        }
        // The pointer resting over Ycode's row when the chooser opens does not move the highlight.
        let y = PopoverMetrics.rowsTop + PopoverMetrics.rowHeight * Double(max(0, rows.count - 1)) + 1
        m.chooserPointer(at: CGPoint(x: 100, y: y), bodyY: y)
        #expect(m.popovers.list.current == checked)
        // Once it moves, hover highlights the row under it.
        let first = PopoverMetrics.rowsTop + 1
        m.chooserPointer(at: CGPoint(x: 100, y: first + 30), bodyY: first + PopoverMetrics.rowHeight)
        #expect(m.popovers.list.highlighted == m.popovers.list.row(atY: first + PopoverMetrics.rowHeight))
        // Opening again resets it.
        m.showDestinationChooser()
        #expect(m.popovers.list.current == checked)
    }

    @Test func quickActionsRowsFollowTheReference() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let app = ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "b5fix-popovers-\(UUID().uuidString)")!),
                                engine: { ScriptedEngine(lines: [], issues: []) })
        #expect(app.open(path: pkg.url.path))
        let m = try #require(app.workspace)
        let commands = ShellQuickActions.collect(app: app)
        let build = try #require(commands.first { $0.title == "Build" })
        #expect(build.menuPath == ["Product"] && build.entry.subtitle == "Product" && build.entry.symbol == "hammer")
        m.showQuickActions(commands)
        m.setQuickActionsQuery("build")
        let shown = m.popovers.quickActions?.shown ?? []
        #expect(shown.first?.title == "Build")
        // Titles that begin with the query come first, in menu order.
        let begins = shown.prefix { $0.entry.displayTitle.lowercased().hasPrefix("build") }
        #expect(!begins.isEmpty && shown.dropFirst(begins.count).allSatisfy { !$0.entry.displayTitle.lowercased().hasPrefix("build") })
        if let sub = shown.first(where: { $0.menuPath.count > 1 }) {
            #expect(sub.entry.displayTitle.contains(" › ") && sub.entry.subtitle == sub.menuPath.joined(separator: " › "))
        }
    }

    @Test func moduleQuickHelpOpensForAnImport() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let source = pkg.url.appendingPathComponent("Sources/DemoCore/Uses.swift")
        try "import Foundation\nimport DemoCore\n\nlet x = 1\n".write(to: source, atomically: true, encoding: .utf8)
        let catalog = pkg.url.appendingPathComponent("Sources/DemoCore/DemoCore.docc")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try "# ``DemoCore``\n\nGreetings for tests.\n\n## Overview\n\nDemoCore says hello.\n".write(to: catalog.appendingPathComponent("DemoCore.md"),
                                                                                                         atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.open(source.path)
        let foundation = try #require(m.showModuleQuickHelp(at: 9))
        #expect(foundation.isModule && foundation.title == "Foundation" && foundation.summary == nil && foundation.showsDocumentationLink)
        #expect(m.languageFeatures.popover?.document == foundation && m.languageFeatures.popover?.offset == 7)
        let own = try #require(m.showModuleQuickHelp(at: 27))
        #expect(own.title == "DemoCore" && own.summary == "Greetings for tests." && own.overview.map(\.plainText) == ["DemoCore says hello."])
        #expect(m.showModuleQuickHelp(at: 37) == nil, "not on an import")
    }
}
