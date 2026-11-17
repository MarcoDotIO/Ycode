import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 4 workflow fixes in the Linux IDE's model, one to one with the
/// AppKit IDE (parity inventory P-123, P-131, P-132).
@MainActor
@Suite(.serialized) struct WorkflowsShellB4Tests {
    func model(_ g: GitPackage) async throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: g.url, engine: ScriptedEngine(lines: [], issues: []))
        await m.sourceControl.idle()
        return m
    }

    @Test func activateConsoleShowsTheConsoleAndAsksForTheKeyboard() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        m.debug.showsConsole = false
        m.debug.showsVariables = true
        m.perform(.activateConsole)
        #expect(m.isDebugAreaShown && m.debugPane == .console)
        #expect(m.debug.showsConsole && m.consoleFocusPending)
    }

    @Test func newBranchAsksForANameFromTheCurrentBranch() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        let scm = m.sourceControl
        scm.choose(.newBranch(from: nil))
        let p = try #require(scm.prompt)
        #expect(p.title == "Create new branch in \u{201C}\(scm.repositoryName)\u{201D}:")
        #expect(p.info.map(\.label) == ["From"] && p.info.first?.text == "main")
        #expect(p.fields.map(\.label) == ["To"])
        #expect(!p.canConfirm)
        scm.prompt?.fields[0].text = "   "
        #expect(scm.prompt?.canConfirm == false)
        scm.confirmPrompt()
        #expect(scm.prompt != nil, "an empty name creates nothing")
        scm.prompt?.fields[0].text = "topic"
        #expect(scm.prompt?.canConfirm == true)
        scm.confirmPrompt()
        await scm.idle()
        #expect(scm.snapshot.currentBranch == "topic")
    }
}
