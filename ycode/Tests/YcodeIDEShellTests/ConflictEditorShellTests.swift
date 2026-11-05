import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// The Linux IDE's conflict editor (`ConflictEditorShellModel`, issue #75):
/// a conflicting merge opens it, one file is resolved by choosing sides and
/// one by hand, the merge continues; a cherry-pick continues and a rebase
/// aborts (after asking); Integrate ▸ Resolve Conflicts…, Continue and
/// Abort.
@MainActor
@Suite(.serialized) struct ConflictEditorShellTests {
    static let colorsBase = "let background = \"white\"\nlet border = \"gray\"\nlet text = \"black\"\nlet link = \"blue\"\nlet accent = \"orange\"\n"

    /// main and "feature" change Colors.swift in two places and Greeting.swift
    /// in one, differently.
    func conflictingPackage() throws -> GitPackage {
        let g = try GitPackage()
        let colors = "Sources/DemoCore/Colors.swift", greeting = "Sources/DemoCore/Greeting.swift"
        try g.write(colors, Self.colorsBase)
        try g.git(["add", "-A"])
        try g.git(["commit", "-q", "-m", "Colors"])
        try g.git(["switch", "-q", "-c", "feature"])
        try g.write(colors, Self.colorsBase.replacingOccurrences(of: "white", with: "ivory").replacingOccurrences(of: "orange", with: "teal"))
        try g.write(greeting, "public func greeting() -> String { \"Welcome\" }\n")
        try g.git(["commit", "-q", "-am", "Feature"])
        try g.git(["switch", "-q", "main"])
        try g.write(colors, Self.colorsBase.replacingOccurrences(of: "white", with: "snow").replacingOccurrences(of: "orange", with: "purple"))
        try g.write(greeting, "public func greeting() -> String { \"Hi\" }\n")
        try g.git(["commit", "-q", "-am", "Main"])
        return g
    }

    /// A conflicted file's path as git reports it (the snapshot's).
    static func gitPath(_ scm: SourceControlShellModel, _ name: String) -> String {
        scm.snapshot.changes.first { $0.path.hasSuffix("/" + name) }?.path ?? name
    }

    func model(_ g: GitPackage) async throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: g.url, engine: ScriptedEngine(lines: [], issues: []))
        await m.sourceControl.idle()
        return m
    }

    @Test func mergeResolvedBySidesAndByHandThenContinued() async throws {
        let g = try conflictingPackage()
        defer { g.remove() }
        let m = try await model(g)
        let scm = m.sourceControl
        scm.choose(.merge("feature"))
        scm.confirm(try #require(scm.confirmation).choices[0])
        await scm.idle()
        let colors = Self.gitPath(scm, "Colors.swift"), greeting = Self.gitPath(scm, "Greeting.swift")
        // The conflicting merge opens the editor on the first file; no notice.
        #expect(scm.pane == .conflicts && scm.notice == nil)
        let editor = try #require(scm.conflictEditor)
        await scm.idle()
        var st = editor.state
        #expect(st.files == [colors, greeting] && st.currentFile == colors)
        #expect(st.title == "Conflicts in Colors.swift" && st.statusText == "2 conflicts unresolved")
        #expect(st.hunkLabel == "Change 1 of 2 (conflict)" && st.showsIntegrationButtons && st.continueTitle == "Continue Merge" && !st.canContinue)
        #expect(st.document?.oursLabel == "main" && st.document?.theirsLabel == "feature")
        // The window: menu items while the merge is stopped.
        #expect(m.menuContext.integrationVerb == "Merge" && m.menuContext.hasConflicts)
        #expect(m.isEnabled(.scmResolveConflicts) && m.isEnabled(.scmAbortIntegration) && !m.isEnabled(.scmContinueIntegration))
        #expect(ShellCommand.scmContinueIntegration.title(in: m.menuContext) == "Continue Merge")
        #expect(ShellCommand.scmAbortIntegration.title(in: m.menuContext) == "Abort Merge")
        #expect(scm.selectedFile == colors)

        // Colors.swift: Left, then Right.
        editor.chooseSegment(0)
        #expect(editor.state.hunkLabel == "Change 2 of 2 (conflict)")
        editor.chooseSegment(1)
        #expect(editor.state.canMarkResolved && editor.state.statusText == "Resolved")
        #expect(await editor.markResolved())
        await scm.idle()
        st = editor.state
        #expect(st.files == [greeting] && st.currentFile == greeting && st.title == "Conflicts in Greeting.swift")
        #expect(try String(contentsOfFile: colors, encoding: .utf8) == Self.colorsBase.replacingOccurrences(of: "white", with: "snow").replacingOccurrences(of: "orange", with: "teal"))

        // Greeting.swift: by hand. Text with markers is refused.
        editor.chooseSegment(ConflictEditorState.editSegment)
        #expect(editor.state.isEditing && editor.editedText.contains("Hi") && editor.editedText.contains("Welcome"))
        editor.editedText = "public func greeting() -> String { \"Greetings\" }\n"
        #expect(editor.state.document?.result == "public func greeting() -> String { \"Greetings\" }\n")
        #expect(await editor.markResolved())
        await scm.idle()
        st = editor.state
        #expect(st.files.isEmpty && st.statusText == "All conflicts resolved" && st.canContinue)
        #expect(m.isEnabled(.scmContinueIntegration))

        // Continue Merge: the merge commit; the editor closes.
        editor.continueIntegration()
        await scm.idle()
        #expect(scm.pane == nil && scm.conflictEditor == nil && scm.snapshot.integration == .none)
        #expect(try g.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count == 3)
        #expect(try String(contentsOfFile: greeting, encoding: .utf8) == "public func greeting() -> String { \"Greetings\" }\n")
        #expect(!m.menuContext.hasConflicts && m.menuContext.integrationVerb.isEmpty)
    }

    @Test func markersAreRefusedAndTheRowMenuOpensTheEditor() async throws {
        let g = try conflictingPackage()
        defer { g.remove() }
        // The merge stops on conflicts (git exits non-zero).
        _ = try? g.git(["merge", "feature"])
        let m = try await model(g)
        let scm = m.sourceControl
        let greeting = Self.gitPath(scm, "Greeting.swift")
        #expect(scm.pane == nil)
        // The conflicted change's row opens the editor on that file.
        scm.select("change:" + greeting)
        await scm.idle()
        let editor = try #require(scm.conflictEditor)
        await editor.idle()
        #expect(editor.state.currentFile == greeting)
        // Undecided: Mark as Resolved does nothing.
        #expect(await editor.markResolved() == false)
        // Writing markers by hand is refused with git's reason shown.
        editor.beginEditing()
        editor.editedText = "<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n"
        #expect(editor.state.canMarkResolved)
        #expect(await editor.markResolved() == false)
        #expect(editor.state.statusText == "The file still has conflict markers.")
        // Integrate ▸ Resolve Conflicts… with nothing selected: the first file.
        scm.hidePane()
        m.perform(.scmResolveConflicts)
        await scm.idle()
        #expect(scm.conflictEditor?.state.currentFile == Self.gitPath(scm, "Colors.swift"))
        // Abort asks first.
        m.perform(.scmAbortIntegration)
        let c = try #require(scm.confirmation)
        #expect(c.title == "Abort the merge?" && c.choices.map(\.title) == ["Abort"])
        scm.confirm(c.choices[0])
        await scm.idle()
        #expect(scm.snapshot.integration == .none && scm.pane == nil && scm.conflictEditor == nil)
    }

    @Test func rebaseAbortsAndCherryPickContinues() async throws {
        let g = try conflictingPackage()
        defer { g.remove() }
        let m = try await model(g)
        let scm = m.sourceControl
        let greeting = scm.repoPath(g.workspacePath("Sources/DemoCore/Greeting.swift"))

        // "feature" rebased onto main conflicts; Abort Rebase restores it.
        let before = try g.git(["rev-parse", "feature"])
        scm.perform(.checkout("feature", .carry))
        scm.perform(.rebase("main"))
        await scm.idle()
        let rebase = try #require(scm.conflictEditor)
        #expect(rebase.state.abortTitle == "Abort Rebase" && rebase.state.document?.theirsLabel == "feature")
        rebase.abortIntegration()
        let c = try #require(scm.confirmation)
        #expect(c.title == "Abort the rebase?")
        scm.confirm(c.choices[0])
        await scm.idle()
        #expect(scm.snapshot.integration == .none && scm.conflictEditor == nil && scm.pane == nil)
        #expect(try g.git(["rev-parse", "HEAD"]) == before)
        scm.perform(.checkout("main", .carry))
        await scm.idle()
        #expect(scm.snapshot.currentBranch == "main")

        // A cherry-pick of "feature" conflicts in both files.
        scm.perform(.cherryPick("feature"))
        await scm.idle()
        let pick = try #require(scm.conflictEditor)
        #expect(pick.state.continueTitle == "Continue Cherry-Pick" && pick.state.files.count == 2)
        for _ in 0..<2 {
            for _ in 0..<(pick.state.document?.conflictCount ?? 0) { pick.chooseSegment(1) }
            #expect(await pick.markResolved())
            await scm.idle()
        }
        #expect(pick.state.canContinue)
        pick.continueIntegration()
        await scm.idle()
        #expect(scm.snapshot.integration == .none && scm.conflictEditor == nil)
        #expect(try g.git(["log", "-1", "--format=%s"]) == "Feature\n")
        #expect(try String(contentsOfFile: greeting, encoding: .utf8).contains("Welcome"))
    }
}
