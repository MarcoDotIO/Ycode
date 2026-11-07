import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 4, row 113 (`editor-area.md` F.12): the Linux IDE keeps
/// the Project navigator's expanded rows in the workspace's user data, as
/// the macOS IDE does, and starts from them.
@MainActor
@Suite struct ShellExpansionStateTests {
    @Test func expansionIsSavedAndRestored() throws {
        let pkg = try TempPackage()
        let model = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let session = model.session
        // Test runs neither read nor write the user data (when the process is
        // known as one: IDEProcess.isTestProcess).
        #expect(!IDEProcess.isTestProcess || WorkspaceShellModel.stateFileURL(for: session.model) == nil)
        let file = pkg.url.appendingPathComponent("ui-state.json")
        // No saved state: the first-open default.
        #expect(WorkspaceShellModel.initialExpansion(for: session.model, stateURL: file) == Set(NavigatorTree.initiallyExpanded(session.model.root)))
        // A saved set comes back, and other saved values are kept.
        var other = WorkspaceUserState()
        other.recentFiles = ["/x"]
        other.save(to: file)
        let saved: Set<String> = Set(NavigatorTree.initiallyExpanded(session.model.root)).union(["extra-key"])
        WorkspaceShellModel.save(expansion: saved, to: file)
        #expect(WorkspaceShellModel.initialExpansion(for: session.model, stateURL: file) == saved)
        #expect(WorkspaceUserState.load(from: file).recentFiles == ["/x"])
    }
}
