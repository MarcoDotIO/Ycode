import Foundation
import Testing
import YcodeIDECore
@testable import YcodeIDEShell

/// B5-FOLLOWUP: the project navigator's commands reach the Linux menu bar
/// (`ShellMenuModel` asks the workspace's `validateProjectNavigatorAction`
/// and `performProjectNavigatorAction`, and `fillMenuBarContext` adds the
/// navigator's conditions), as the macOS window answers them.
@MainActor
@Suite(.serialized) struct NavigatorMenuBarShellTests {
    func app() -> ShellAppModel {
        ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "navmenu-\(UUID().uuidString)")!),
                      engine: { ScriptedEngine(lines: [], issues: []) })
    }

    /// The row with this title (its parents opened), in the app's workspace.
    func row(_ w: WorkspaceShellModel, _ title: String) -> String? {
        func walk(_ n: NavigatorItem) -> NavigatorItem? {
            if n.name == title { return n }
            for c in n.children ?? [] { if let f = walk(c) { return f } }
            return nil
        }
        guard let item = (w.root.children ?? []).lazy.compactMap(walk).first else { return nil }
        for a in (w.root.ancestry(ofID: item.id) ?? []).dropLast() { w.setExpanded(a.id, true) }
        return item.id
    }

    func select(_ w: WorkspaceShellModel, _ title: String) {
        guard let id = row(w, title) else { return }
        w.clickProjectRow(id, rows: w.projectRows)
    }

    func menuRow(_ a: ShellAppModel, _ action: String) -> ShellMenuRow? {
        ShellMenuModel.rows(a).first { $0.action == action }
    }

    @Test func navigatorCommandsEnableAndRunFromTheMenuBar() throws {
        let s = try ShellNavigatorSample()
        defer { s.remove() }
        let a = app()
        #expect(a.open(path: s.xcodeproj.path))
        let w = try #require(a.workspace)
        w.navigator = .project
        w.isNavigatorShown = true
        let newGroup = try #require(CommandTable.command(action: "newGroup:"))

        // Nothing selected: File ▸ New ▸ Group is listed and disabled.
        #expect(menuRow(a, "newGroup:")?.isEnabled == false)
        #expect(!ShellMenuModel.isEnabled(newGroup, app: a))

        // A group selected: enabled, and choosing it makes the group on
        // disk and in the project, with the navigator's undo.
        select(w, "Nav")
        #expect(menuRow(a, "newGroup:")?.isEnabled == true)
        #expect(ShellMenuModel.isEnabled(newGroup, app: a))
        ShellMenuModel.perform(newGroup, app: a)
        #expect(s.exists("Nav/New Group"))
        #expect(s.written.contains("New Group"))
        #expect(w.navigatorUndoTitle == "Undo New Group")

        // In a synchronized folder File ▸ New ▸ Group is hidden (the
        // navigator's menu context reaches the menu bar).
        select(w, "Greeting.swift")
        #expect(menuRow(a, "newGroup:") == nil)

        // Paste ▸ Move Item Here: disabled until a Cut, then it moves the
        // item from the menu bar.
        let moveHere = try #require(CommandTable.command(action: "moveItemHere:"))
        select(w, "Model.swift")
        #expect(menuRow(a, "moveItemHere:")?.isEnabled == false)
        w.cutNavigatorSelection()
        select(w, "Support")
        #expect(menuRow(a, "moveItemHere:")?.isEnabled == true)
        ShellMenuModel.perform(moveHere, app: a)
        let moved = try #require(row(w, "Model.swift"))
        #expect(w.root.ancestry(ofID: moved)?.dropLast().last?.name == "Support")
    }
}
