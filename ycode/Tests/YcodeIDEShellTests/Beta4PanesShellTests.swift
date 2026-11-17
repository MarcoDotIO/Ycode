import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 4, B4-PANES on the Linux IDE's model (`specs/ide/parity-inventory.md`):
/// the navigator commands toggle (P-036) and a selected folder's File
/// inspector (P-089). Settings' history (P-138) is the ycode-ide target's,
/// checked by the `YCODE_IDE_PANES4` walk.
@MainActor
@Suite(.serialized) struct Beta4PanesShellTests {
    func model(_ g: GitPackage) async throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: g.url, engine: ScriptedEngine(lines: [], issues: []))
        await m.sourceControl.idle()
        return m
    }

    @Test func navigatorCommandOnTheShownNavigatorHidesIt() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        m.perform(.showIssueNavigator)
        #expect(m.isNavigatorShown && m.navigator == .issues)
        m.perform(.showIssueNavigator)
        #expect(!m.isNavigatorShown)
        m.perform(.showIssueNavigator)
        #expect(m.isNavigatorShown && m.navigator == .issues)
        m.perform(.showProjectNavigator)
        #expect(m.isNavigatorShown && m.navigator == .project)
        // The issue capsule only shows.
        m.showNavigator(.project)
        #expect(m.isNavigatorShown && m.navigator == .project)
    }

    @Test func aSelectedFolderHasItsOwnFileInspector() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        let file = g.workspacePath("Sources/DemoCore/Greeting.swift")
        m.open(file)
        let folder = URL(fileURLWithPath: file).deletingLastPathComponent().path
        let ids = try #require(m.root.idPath(to: file))
        let folderID = try #require(ids.dropLast().last)
        #expect(m.root.find(id: folderID)?.path == folder)
        m.selection = folderID
        #expect(m.inspectedFolder == folder)
        let identity = try #require(m.fileInspector.first)
        #expect(identity.rows.map(\.key).first == "Name" && !identity.rows.map(\.key).contains("Type"))
        #expect(identity.rows.first { $0.key == "Full Path" }?.value == .path(folder, button: "arrow.right.circle.fill"))
        // A file selected again: its own inspector.
        m.selection = ids.last
        #expect(m.inspectedFolder == nil && m.fileInspector.first?.rows.map(\.key).contains("Type") == true)
    }
}
