import Foundation
import Testing
import YcodeEditorKit
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 7, row 186 (`workspace-window.md` W7.1) in the Linux IDE:
/// the panes (files, selections, first lines, direction, the active pane)
/// and the inspector are saved in the workspace's user data and come back
/// in a new window, as in the macOS IDE.
@MainActor
@Suite struct ShellWindowRestoreTests {
    @Test func panesAndInspectorComeBackInANewWindow() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let greeting = pkg.path("Sources/DemoCore/Greeting.swift"), main = pkg.path("Sources/Demo/main.swift")
        let model = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        model.open(greeting)
        model.splitEditor(sideBySide: true)
        model.open(main)
        model.editor?.buffer.setSelection(EditorSelection(NSRange(location: 7, length: 7)))
        model.restore.firstVisibleLine = { _, path in path == greeting ? 3 : 1 }
        model.showInspector(.history)
        let layout = model.currentEditorLayout
        #expect(layout.panes.map(\.path) == [greeting, main] && layout.focused == 1 && layout.sideBySide)
        #expect(layout.panes[0].topLine == 3 && layout.panes[1].selectionStart == 7 && layout.panes[1].selectionLength == 7)
        #expect(layout.fractions == [0.5, 0.5])
        let file = pkg.url.appendingPathComponent("ui-state.json")
        WorkspaceShellModel.save(layout: layout, inspector: model.currentInspectorState, to: file)

        // The reopened window: a new model reading the same file.
        let again = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        again.isInspectorShown = false
        again.restoreWindowLayout(from: WorkspaceUserState.load(from: file))
        #expect(again.panes.panes.map(\.path) == [greeting, main])
        #expect(again.panes.focused == 1 && again.panes.sideBySide)
        #expect(again.document?.path == main && again.windowTitle == "Demo — main.swift")
        #expect(again.editor?.buffer.selection.nsRange == NSRange(location: 7, length: 7))
        #expect(again.isInspectorShown && again.languageFeatures.inspectorTab == .history)
        // The pane that is not active shows its file's text.
        if case .text(let d) = again.content(of: again.panes.panes[0]) { #expect(d.path == greeting) } else { Issue.record("left pane empty") }
        // Each pane scrolls to its saved first line once drawn.
        #expect(again.restore.takeTopLine(pane: 0, path: greeting) == 3)
        #expect(again.restore.takeTopLine(pane: 0, path: greeting) == nil)
        // The navigator selects no row on reopen.
        #expect(again.selection == nil)
    }

    @Test func aMissingFileLeavesItsPaneEmpty() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        var state = WorkspaceUserState()
        state.editorLayout = WorkspaceEditorLayout(panes: [.init(path: pkg.path("gone.swift")), .init(path: pkg.path("README.md"))], focused: 0)
        let model = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        model.restoreWindowLayout(from: state)
        #expect(model.panes.panes.map(\.path) == [nil, pkg.path("README.md")])
        #expect(model.panes.focused == 0 && model.document == nil && model.windowTitle == "Demo")
    }
}

/// Row 192 in the Linux IDE: the project navigator's rows carry the same
/// icons as the macOS IDE's (logos, the Ycode mark, glyphs; round 9's
/// line-art logos and folder, rows 208–213).
@MainActor
@Suite struct ShellNavigatorIconTests {
    @Test func projectRowsCarryLogosAndTheMark() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let model = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let all = Set(model.root.allFiles.map(\.id)).union([model.root.id])
        func ids(_ item: NavigatorItem) -> [String] { [item.id] + (item.children ?? []).flatMap(ids) }
        let rows = OutlineRows.project(model.root, expanded: Set(ids(model.root)).union(all), hideExtensions: false)
        #expect(rows.first?.icon == .ycodeMark)
        #expect(rows.first { $0.title == "Greeting.swift" }?.icon == .logo("swift"))
        #expect(rows.first { $0.title == "README.md" }?.icon == .markdown)
        // Round 9 (row 213): Ycode's own folder glyph.
        #expect(rows.first { $0.title == "Sources" }?.icon == .folder)
    }
}
