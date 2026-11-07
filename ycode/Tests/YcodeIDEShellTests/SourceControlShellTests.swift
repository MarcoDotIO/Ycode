import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// A package in a fresh git repository with a repository-local identity
/// and one commit, and a bare repository as its remote when asked.
struct GitPackage {
    let pkg: TempPackage
    var url: URL { pkg.url }
    let remote: URL?

    init(remote withRemote: Bool = false) throws {
        pkg = try TempPackage()
        let u = pkg.url
        try Self.git(u, ["init", "-q", "-b", "main"])
        try Self.git(u, ["config", "user.name", "Shell Tester"])
        try Self.git(u, ["config", "user.email", "shell@ycode.invalid"])
        try Self.git(u, ["config", "commit.gpgsign", "false"])
        try Self.git(u, ["add", "-A"])
        try Self.git(u, ["commit", "-q", "-m", "First commit"])
        if withRemote {
            let bare = u.deletingLastPathComponent().appendingPathComponent("remote.git")
            try Self.git(u.deletingLastPathComponent(), ["init", "-q", "--bare", "-b", "main", bare.path])
            try Self.git(u, ["remote", "add", "origin", bare.path])
            remote = bare
        } else {
            remote = nil
        }
    }

    @discardableResult
    static func git(_ dir: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitRepository.GitError(description: "git \(args.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self)
    }

    func git(_ args: [String]) throws -> String { try Self.git(url, args) }
    /// A file's path as git reports it (links resolved).
    func path(_ rel: String) -> String { SourceControlShellModel.realPath(pkg.path(rel)) }
    /// A file's path as the workspace has it.
    func workspacePath(_ rel: String) -> String { pkg.path(rel) }
    func write(_ rel: String, _ text: String) throws { try text.write(toFile: path(rel), atomically: true, encoding: .utf8) }
    func remove() { pkg.remove() }
}

@MainActor
@Suite(.serialized) struct SourceControlShellTests {
    func model(_ g: GitPackage) async throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: g.url, engine: ScriptedEngine(lines: [], issues: []))
        await m.sourceControl.idle()
        return m
    }

    // MARK: Navigator

    @Test func changesModeListsTheRepositoryBranchAndChanges() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("Sources/DemoCore/Greeting.swift", "public struct Greeting {}\n")
        try g.write("Sources/DemoCore/New.swift", "let x = 1\n")
        let m = try await model(g)
        let scm = m.sourceControl
        #expect(scm.repository != nil)
        let rows = scm.rows
        #expect(rows.first?.id == "repository")
        #expect(rows.first?.title == "Demo")
        #expect(rows.first?.detail == "main")
        #expect(rows[1].title == "Uncommitted Changes")
        // The count right after the title (cross-platform-parity.md §7).
        #expect(rows[1].detail == "2" && rows[1].trailing == nil)
        #expect(rows.dropFirst(2).map(\.title) == ["Greeting", "New"])
        #expect(rows.dropFirst(2).map(\.badge) == ["M", "?"])
        // The project navigator shows the same letters on the files.
        #expect(m.sourceControl.badges[g.workspacePath("Sources/DemoCore/Greeting.swift")] == "M")
        for id in m.root.idPath(to: g.workspacePath("Sources/DemoCore/Greeting.swift")) ?? [] { m.setExpanded(id, true) }
        #expect(m.projectRows.contains { $0.badge == "M" && $0.title == "Greeting" })
        // Collapsing the group hides its rows.
        scm.setExpanded("group:Uncommitted Changes", false)
        #expect(scm.rows.count == 2)
    }

    @Test func repositoriesModeHasTheGroupsInOrderWithFolders() async throws {
        let g = try GitPackage(remote: true)
        defer { g.remove() }
        try g.git(["branch", "feature/observe"])
        try g.git(["tag", "v1.0"])
        try g.git(["push", "-q", "origin", "main"])
        try g.git(["fetch", "-q", "origin"])
        let m = try await model(g)
        let scm = m.sourceControl
        scm.mode = .repositories
        // At first only Branches is open; no "(current)" (navigators.md round 3 §2).
        #expect(scm.rows.map(\.title) == ["Demo", "Branches", "feature", "observe", "main", "Recents", "Tags", "Stashes", "Remotes"])
        #expect(scm.rows.first { $0.id == "branch:main" }?.detail == nil)
        let groupRows = scm.rows.filter { $0.id.hasPrefix("group:") }
        #expect(groupRows.allSatisfy { $0.isExpandable })
        scm.collapsed = []
        let titles = scm.rows.map(\.title)
        #expect(titles == ["Demo", "Branches", "feature", "observe", "main", "Recents", "Tags", "v1.0", "Stashes", "Remotes", "origin", "main"])
        #expect(scm.rows.contains { $0.id == "branch:feature/observe" })
        #expect(scm.rows.contains { $0.id == "remoteBranch:origin/main" })
        // Branch menus come from the core's table (the reference's set,
        // `merge-sheet.md` §1.1).
        #expect(scm.menu(for: "branch:feature/observe").map(\.title).contains("Switch to \u{201C}feature/observe\u{201D}…"))
    }

    // MARK: Commit editor

    @Test func theCommitEditorShowsCardsAndCommitsEverythingWhenNothingIsStaged() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("README.md", "# Demo\nA greeting package.\nMore.\n")
        try g.write("Notes.txt", "new file\n")
        let m = try await model(g)
        let scm = m.sourceControl
        scm.select("change:" + g.path("README.md"))
        await scm.idle()
        #expect(scm.pane == .commit(focus: g.path("README.md")))
        #expect(scm.cards.map(\.title) == ["Notes", "README"])
        let readme = try #require(scm.cards.first { $0.title == "README" })
        #expect(readme.lines.contains { $0.kind == .added && $0.text == "More." })
        #expect(readme.stats.added == 1)
        #expect(scm.author?.name == "Shell Tester")
        #expect(!scm.canCommit)
        scm.message = "Second commit"
        #expect(scm.canCommit)
        scm.commit()
        await scm.idle()
        #expect(scm.errorMessage == nil)
        #expect(scm.snapshot.changes.isEmpty)
        #expect(scm.message.isEmpty)
        #expect(try g.git(["log", "-1", "--format=%s %an"]).trimmingCharacters(in: .whitespacesAndNewlines) == "Second commit Shell Tester")
        // Opening a file hides the commit editor.
        m.open(g.path("README.md"))
        #expect(scm.pane == nil)
    }

    @Test func scopesStagingAndAmend() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("README.md", "changed\n")
        try g.write("Package.swift", "// changed\n")
        let m = try await model(g)
        let scm = m.sourceControl
        scm.showCommitEditor(focus: nil)
        await scm.idle()
        let card = try #require(scm.cards.first { $0.title == "README" })
        scm.toggleStaged(card)
        await scm.idle()
        scm.scope = .staged
        await scm.idle()
        #expect(scm.cards.map(\.title) == ["README"])
        scm.scope = .unstaged
        await scm.idle()
        #expect(scm.cards.map(\.title) == ["Package"])
        // Only the staged file is committed.
        scm.message = "Readme"
        scm.commit()
        await scm.idle()
        #expect(scm.snapshot.changes.map { ($0.path as NSString).lastPathComponent } == ["Package.swift"])
        // Amend pre-fills HEAD's message into an empty field.
        scm.amend = true
        #expect(scm.message == "Readme")
        scm.amend = false
        scm.message = ""
        scm.stageAll()
        await scm.idle()
        #expect(scm.hasStagedChanges)
    }

    @Test func theCommitSheetCommitsOnlyTheCheckedFiles() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("README.md", "changed\n")
        try g.write("Package.swift", "// changed\n")
        let m = try await model(g)
        let scm = m.sourceControl
        #expect(m.isEnabled(.scmCommit))
        m.perform(.scmCommit)
        var sheet = try #require(scm.commitSheet)
        #expect(sheet.files.map(\.relativePath) == ["Package.swift", "README.md"])
        #expect(!sheet.canCommit)
        sheet.files[0].isOn = false
        sheet.message = "Only the readme"
        scm.commitSheet = sheet
        scm.commitSheetFiles()
        await scm.idle()
        #expect(scm.commitSheet == nil)
        #expect(scm.snapshot.changes.map { ($0.path as NSString).lastPathComponent } == ["Package.swift"])
    }

    @Test func discardAsksThenRestoresTheFile() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("README.md", "changed\n")
        let m = try await model(g)
        let scm = m.sourceControl
        scm.askDiscard(g.path("README.md"))
        let c = try #require(scm.confirmation)
        #expect(c.choices.first?.isDestructive == true)
        scm.confirm(c.choices[0])
        await scm.idle()
        #expect(scm.snapshot.changes.isEmpty)
        #expect(try String(contentsOfFile: g.path("README.md"), encoding: .utf8) == "# Demo\nA greeting package.\n")
    }

    // MARK: Branches

    @Test func newBranchCheckoutMergeAndDelete() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        let scm = m.sourceControl
        scm.mode = .repositories
        scm.choose(.newBranch(from: nil))
        var p = try #require(scm.prompt)
        #expect(!p.canConfirm)
        p.fields[0].text = "topic"
        scm.prompt = p
        scm.confirmPrompt()
        await scm.idle()
        #expect(scm.snapshot.currentBranch == "topic")
        try g.write("README.md", "on topic\n")
        scm.message = "Topic work"
        scm.commit()
        await scm.idle()
        // Back to main, then merge topic.
        scm.choose(.checkout("main"))
        let c = try #require(scm.confirmation)
        #expect(c.choices.map(\.title) == ["Check Out"])
        scm.confirm(c.choices[0])
        await scm.idle()
        #expect(scm.snapshot.currentBranch == "main")
        #expect(scm.snapshot.recentBranches == ["topic"])
        // Merge “topic” into “main”…: the merge confirmation, then Merge.
        scm.choose(.merge("topic"))
        #expect(scm.mergeAlert?.branch == "topic" && scm.confirmation == nil)
        scm.confirmMergeAlert()
        await scm.idle()
        #expect(scm.errorMessage == nil)
        #expect(try String(contentsOfFile: g.path("README.md"), encoding: .utf8) == "on topic\n")
        scm.choose(.deleteBranch("topic"))
        scm.confirm(try #require(scm.confirmation).choices[0])
        await scm.idle()
        #expect(scm.snapshot.branches.map(\.name) == ["main"])
        // A bad name is git's error, shown to the user.
        scm.perform(.createBranch("bad name", from: nil))
        await scm.idle()
        #expect(scm.errorMessage?.contains("not a valid branch name") == true)
    }

    @Test func checkoutWithChangesOffersToStash() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.git(["branch", "other"])
        try g.write("README.md", "dirty\n")
        let m = try await model(g)
        let scm = m.sourceControl
        scm.choose(.checkout("other"))
        let c = try #require(scm.confirmation)
        #expect(c.choices.map(\.title) == ["Stash and Check Out", "Check Out"])
        scm.confirm(c.choices[0])
        await scm.idle()
        #expect(scm.snapshot.currentBranch == "other")
        #expect(scm.snapshot.stashes.count == 1)
        #expect(scm.snapshot.changes.isEmpty)
        // Apply and delete the stash.
        let ref = try #require(scm.snapshot.stashes.first?.components(separatedBy: ": ").first)
        scm.choose(.popStash(ref))
        await scm.idle()
        #expect(scm.snapshot.stashes.isEmpty)
        #expect(scm.snapshot.changes.count == 1)
    }

    @Test func historyAndCommitDetail() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        try g.write("README.md", "second\n")
        try g.git(["commit", "-q", "-am", "Second"])
        let m = try await model(g)
        let scm = m.sourceControl
        scm.mode = .repositories
        scm.select("branch:main")
        await scm.idle()
        #expect(scm.pane == .history(ref: "refs/heads/main", title: "main", branch: "main"))
        #expect(scm.history.map(\.subject) == ["Second", "First commit"])
        #expect(scm.branchInfo.map(\.value) == ["main", "No Remote", "No Remote Branch"])
        scm.historyFilter = "first"
        #expect(scm.shownHistory.map(\.subject) == ["First commit"])
        scm.historyFilter = ""
        scm.selectedCommit = scm.history[0].hash
        await scm.idle()
        #expect(scm.commitDetail?.files.map(\.path) == ["README.md"])
        #expect(scm.commitDetail?.branches == ["main"])
        #expect(scm.commitRows.first?.value == scm.history[0].hash)
        #expect(m.isEnabled(.scmCherryPick))
    }

    // MARK: Remotes

    @Test func pushAndPullThroughALocalRemote() async throws {
        let g = try GitPackage(remote: true)
        defer { g.remove() }
        let m = try await model(g)
        let scm = m.sourceControl
        #expect(m.isEnabled(.scmPush))
        // The first push sets the upstream.
        m.perform(.scmPush)
        await scm.idle()
        #expect(scm.errorMessage == nil)
        #expect(try g.git(["rev-parse", "--abbrev-ref", "main@{upstream}"]).trimmingCharacters(in: .whitespacesAndNewlines) == "origin/main")
        // A commit made elsewhere comes back with Pull.
        let other = g.url.deletingLastPathComponent().appendingPathComponent("other")
        try GitPackage.git(g.url.deletingLastPathComponent(), ["clone", "-q", try #require(g.remote).path, other.path])
        try GitPackage.git(other, ["config", "user.name", "Other Tester"])
        try GitPackage.git(other, ["config", "user.email", "other@ycode.invalid"])
        try "from elsewhere\n".write(to: other.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try GitPackage.git(other, ["commit", "-q", "-am", "Elsewhere"])
        try GitPackage.git(other, ["push", "-q", "origin", "main"])
        m.perform(.scmPull)
        await scm.idle()
        #expect(scm.errorMessage == nil)
        #expect(try String(contentsOfFile: g.path("README.md"), encoding: .utf8) == "from elsewhere\n")
        // Commit and Push.
        try g.write("README.md", "pushed\n")
        scm.refresh()
        await scm.idle()
        scm.message = "Pushed"
        scm.commit(andPush: true)
        await scm.idle()
        #expect(scm.errorMessage == nil, "\(scm.errorMessage ?? "")")
        #expect(try GitPackage.git(try #require(g.remote), ["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines) == "Pushed")
    }

    // MARK: Editor and inspector

    @Test func changeBarsAndFileHistoryFollowTheOpenFile() async throws {
        let g = try GitPackage()
        defer { g.remove() }
        let m = try await model(g)
        let scm = m.sourceControl
        let file = g.workspacePath("Sources/DemoCore/Greeting.swift")
        m.open(file)
        await scm.idle()
        #expect(scm.changeRegions.isEmpty)
        // Typing adds a bar after a moment.
        let b = try #require(m.editor?.buffer)
        b.setCaret(0)
        b.insertText("// added\n")
        try await Task.sleep(nanoseconds: 400_000_000)
        await scm.idle()
        #expect(scm.changeRegions.map(\.kind) == [.added])
        #expect(scm.changeRegions.first?.firstLine == 1)
        scm.showFileHistory(for: file)
        await scm.idle()
        #expect(scm.fileHistory.map(\.subject) == ["First commit"])
    }

    @Test func integrateMenuOutsideARepository() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        await m.sourceControl.idle()
        #expect(m.sourceControl.repository == nil)
        #expect(!m.isEnabled(.scmCommit))
        #expect(!m.isEnabled(.scmPush))
        #expect(m.isEnabled(.scmNewRepository))
        m.perform(.scmNewRepository)
        await m.sourceControl.idle()
        #expect(m.sourceControl.repository != nil)
        #expect(!m.isEnabled(.scmNewRepository))
        #expect(m.isEnabled(.scmCommit))
    }
}
