import Foundation
import Testing
@testable import YcodeIDECore

/// Branch workflows on temporary repositories (`specs/ide/source-control.md`,
/// "Ycode implementation"). Every repository and the one "remote" (a bare
/// repository) are created in a fresh temporary folder; nothing here
/// touches another repository or the network.
struct SCMSandbox {
    let folder: URL
    let repo: URL

    init(_ name: String) throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ycode-scm-\(name)-\(UUID().uuidString.prefix(8))")
        folder = base
        repo = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try configure(repo)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// Local identity and no signing, whatever the user's global settings.
    func configure(_ dir: URL) throws {
        for (k, v) in [("user.name", "Ycode Test"), ("user.email", "test@ycode.invalid"), ("commit.gpgsign", "false"),
                       ("tag.gpgsign", "false"), ("core.autocrlf", "false"), ("merge.conflictstyle", "merge"), ("pull.rebase", "false")] {
            _ = try GitRepository.run("/usr/bin/git", ["-C", dir.path, "config", k, v])
        }
    }

    @discardableResult
    func git(_ args: String...) throws -> String { try GitRepository.run("/usr/bin/git", ["-C", repo.path] + args) }

    func write(_ name: String, _ text: String) throws {
        let u = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8) }

    func commit(_ name: String, _ text: String, _ message: String) throws {
        try write(name, text)
        try git("add", "--", name)
        try git("commit", "-q", "-m", message)
    }

    var repository: GitRepository { GitRepository(containing: repo)! }
    func path(_ name: String) -> String { repository.root.appendingPathComponent(name).path }

    /// main: "a b c d e" on five lines; feature and main then change line 3.
    func makeConflict() throws -> GitRepository {
        try commit("f.txt", "a\nb\nc\nd\ne\n", "Base")
        try git("switch", "-q", "-c", "feature")
        try commit("f.txt", "a\nb\nFEATURE\nd\ne\n", "Feature change")
        try git("switch", "-q", "main")
        try commit("f.txt", "a\nb\nMAIN\nd\ne\n", "Main change")
        return repository
    }

    /// A bare repository next to the work tree, as `origin`.
    func makeRemote() throws -> URL {
        let bare = folder.appendingPathComponent("origin.git")
        _ = try GitRepository.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", bare.path])
        return bare
    }
}

@Suite(.serialized) struct SourceControlBranchesTests {
    @Test func createRenameDeleteAndSwitchBranches() throws {
        let s = try SCMSandbox("branches")
        defer { s.cleanUp() }
        try s.commit("a.txt", "1\n", "One")
        let repo = s.repository
        #expect(repo.isValidBranchName("feature/one"))
        #expect(!repo.isValidBranchName("bad..name") && !repo.isValidBranchName("-x") && !repo.isValidBranchName(""))
        #expect(throws: GitRepository.GitError.self) { try repo.createBranch("has space") }

        try repo.createBranch("feature/one")
        #expect(try repo.branches().map(\.name) == ["feature/one", "main"])
        #expect(repo.currentBranch() == "main")
        try repo.createBranch("topic", checkout: true)
        #expect(repo.currentBranch() == "topic")
        try s.commit("a.txt", "2\n", "Two")

        // Rename the current branch; its name changes in place.
        try repo.renameBranch("topic", to: "topic-renamed")
        #expect(repo.currentBranch() == "topic-renamed")
        #expect(throws: GitRepository.GitError.self) { try repo.renameBranch("topic-renamed", to: "bad..name") }

        try repo.checkout("main", changes: .refuse)
        #expect(repo.currentBranch() == "main")
        // Unmerged: refused without force.
        #expect(throws: GitRepository.GitError.self) { try repo.deleteBranch("topic-renamed") }
        try repo.deleteBranch("topic-renamed", force: true)
        // Current branch: always refused.
        #expect(throws: GitRepository.GitError.self) { try repo.deleteBranch("main", force: true) }
        try repo.deleteBranch("feature/one")
        #expect(try repo.branches().map(\.name) == ["main"])

        // A branch from a given start point.
        let first = try #require(repo.resolve("HEAD"))
        try s.commit("a.txt", "3\n", "Three")
        try repo.createBranch("old", from: first)
        #expect(repo.resolve("old") == first)
        #expect(throws: GitRepository.GitError.self) { try repo.createBranch("x", from: "no-such-ref") }

        try repo.checkoutDetached(first)
        #expect(repo.currentBranch() == nil && repo.headHash() == first)
    }

    @Test func switchingWithUncommittedChanges() throws {
        let s = try SCMSandbox("switch")
        defer { s.cleanUp() }
        try s.commit("a.txt", "1\n", "One")
        try s.git("branch", "other")
        let repo = s.repository
        try s.write("a.txt", "local edit\n")

        #expect(throws: GitRepository.GitError.self) { try repo.checkout("other", changes: .refuse) }
        #expect(repo.currentBranch() == "main")

        // Carry: the edit comes along (both branches have the same a.txt).
        try repo.checkout("other", changes: .carry)
        #expect(repo.currentBranch() == "other")
        #expect(try s.read("a.txt") == "local edit\n")

        // Stash: the edit is saved and the working copy is clean.
        let stash = try repo.checkout("main", changes: .stash)
        #expect(stash == "stash@{0}")
        #expect(repo.currentBranch() == "main")
        #expect(try s.read("a.txt") == "1\n")
        #expect(repo.stashList().first?.message == "Before switching to main")

        // Conflicts block switching.
        _ = try s.makeConflict()
        _ = try repo.merge("feature")
        #expect(throws: GitRepository.GitError.self) { try repo.checkout("other", changes: .carry) }
        try repo.abortIntegration()
        #expect(throws: GitRepository.GitError.self) { try repo.checkout("missing", changes: .carry) }
    }

    @Test func fastForwardAndMergeCommits() throws {
        let s = try SCMSandbox("merge")
        defer { s.cleanUp() }
        try s.commit("a.txt", "1\n", "One")
        let repo = s.repository
        try repo.createBranch("feature", checkout: true)
        try s.commit("b.txt", "b\n", "Add b")
        try repo.checkout("main", changes: .refuse)

        #expect(try repo.merge("feature") == .fastForwarded)
        #expect(repo.headHash() == repo.resolve("feature"))
        #expect(try repo.merge("feature") == .upToDate)

        // Diverged: a merge commit with two parents.
        try repo.checkout("feature", changes: .refuse)
        try s.commit("c.txt", "c\n", "Add c")
        try repo.checkout("main", changes: .refuse)
        try s.commit("d.txt", "d\n", "Add d")
        #expect(throws: GitRepository.GitError.self) { try repo.merge("feature", style: .fastForwardOnly) }
        guard case .completed(let head) = try repo.merge("feature") else { Issue.record("expected a merge commit"); return }
        #expect(try s.git("rev-list", "--parents", "-n", "1", head).split(separator: " ").count == 3)
        #expect(try s.git("log", "-1", "--format=%s") == "Merge branch 'feature'\n")
        #expect(FileManager.default.fileExists(atPath: s.path("c.txt")))

        // --no-ff even when a fast-forward was possible, with a message.
        try repo.createBranch("tiny", checkout: true)
        try s.commit("e.txt", "e\n", "Add e")
        try repo.checkout("main", changes: .refuse)
        guard case .completed = try repo.merge("tiny", style: .mergeCommit, message: "Merge tiny work") else { Issue.record("expected --no-ff commit"); return }
        #expect(try s.git("log", "-1", "--format=%s") == "Merge tiny work\n")
        #expect(throws: GitRepository.GitError.self) { try repo.merge("nothing-here") }
    }

    /// The done-criterion: a conflicting merge resolved through the model.
    @Test func conflictingMergeResolvedThroughTheModel() throws {
        let s = try SCMSandbox("conflict")
        defer { s.cleanUp() }
        let repo = try s.makeConflict()
        let file = s.path("f.txt")

        #expect(try repo.merge("feature") == .conflicts([file]))
        #expect(repo.integrationState() == .merging(branch: "feature"))
        #expect(repo.conflictedFiles() == [file])
        #expect(try repo.status()[file] == .conflicted)
        #expect(repo.conflictLabels() == ("main", "feature"))
        #expect(throws: GitRepository.GitError.self) { try repo.continueIntegration() }

        let sides = try #require(repo.conflictSides(of: file))
        #expect(sides.base == "a\nb\nc\nd\ne\n" && sides.ours == "a\nb\nMAIN\nd\ne\n" && sides.theirs == "a\nb\nFEATURE\nd\ne\n")

        var doc = try #require(repo.mergeDocument(forConflictedFile: file))
        #expect(doc.hunks.count == 1 && doc.conflictCount == 1 && doc.unresolvedCount == 1)
        #expect(doc.oursLabel == "main" && doc.theirsLabel == "feature")
        #expect(doc.result == "a\nb\n<<<<<<< main\nMAIN\n=======\nFEATURE\n>>>>>>> feature\nd\ne\n")
        // Unresolved text is refused.
        #expect(throws: GitRepository.GitError.self) { try repo.resolveConflict(file, text: doc.result) }

        doc.choose(.oursThenTheirs, hunk: 0)
        #expect(doc.isResolved)
        try repo.resolveConflict(file, text: doc.result)
        #expect(repo.conflictedFiles().isEmpty)
        guard case .completed(let head) = try repo.continueIntegration() else { Issue.record("expected the merge commit"); return }
        #expect(repo.integrationState() == .none)
        #expect(try s.git("rev-list", "--parents", "-n", "1", head).split(separator: " ").count == 3)
        #expect(try s.read("f.txt") == "a\nb\nMAIN\nFEATURE\nd\ne\n")
        #expect(try repo.changes().isEmpty)
    }

    @Test func abortingAMerge() throws {
        let s = try SCMSandbox("abort")
        defer { s.cleanUp() }
        let repo = try s.makeConflict()
        let before = repo.headHash()
        _ = try repo.merge("feature")
        try repo.abortIntegration()
        #expect(repo.integrationState() == .none && repo.headHash() == before)
        #expect(try s.read("f.txt") == "a\nb\nMAIN\nd\ne\n")
        #expect(throws: GitRepository.GitError.self) { try repo.abortIntegration() }
    }

    @Test func rebaseCleanAndWithAConflict() throws {
        let s = try SCMSandbox("rebase")
        defer { s.cleanUp() }
        try s.commit("a.txt", "1\n", "One")
        let repo = s.repository
        try repo.createBranch("feature", checkout: true)
        try s.commit("b.txt", "b\n", "Add b")
        try repo.checkout("main", changes: .refuse)
        try s.commit("c.txt", "c\n", "Add c")
        try repo.checkout("feature", changes: .refuse)
        guard case .completed = try repo.rebase(onto: "main") else { Issue.record("expected a rebase"); return }
        #expect(try s.git("log", "--format=%s", "-3") == "Add b\nAdd c\nOne\n")
        #expect(try repo.rebase(onto: "main") == .upToDate)

        // A conflicting rebase stops; resolve with the replayed side and go on.
        let t = try SCMSandbox("rebase-conflict")
        defer { t.cleanUp() }
        let r2 = try t.makeConflict()
        try r2.checkout("feature", changes: .refuse)
        let file = t.path("f.txt")
        #expect(try r2.rebase(onto: "main") == .conflicts([file]))
        guard case .rebasing(let branch, _, let step, let total) = r2.integrationState() else { Issue.record("expected rebasing"); return }
        #expect(branch == "feature" && step == 1 && total == 1)
        #expect(r2.conflictLabels().theirs == "feature")
        var doc = try #require(r2.mergeDocument(forConflictedFile: file))
        doc.choose(.theirs, hunk: 0)
        try r2.resolveConflict(file, text: doc.result)
        guard case .completed = try r2.continueIntegration() else { Issue.record("expected the rebase to finish"); return }
        #expect(r2.integrationState() == .none && r2.currentBranch() == "feature")
        #expect(try t.git("log", "--format=%s", "-3") == "Feature change\nMain change\nBase\n")

        // Abort puts the branch back.
        try t.commit("f.txt", "a\nb\nAGAIN\nd\ne\n", "Again")
        try r2.checkout("main", changes: .refuse)
        try t.commit("f.txt", "a\nb\nMAIN2\nd\ne\n", "Main 2")
        try r2.checkout("feature", changes: .refuse)
        let before = r2.headHash()
        guard case .conflicts = try r2.rebase(onto: "main") else { Issue.record("expected conflicts"); return }
        try r2.abortIntegration()
        #expect(r2.integrationState() == .none && r2.headHash() == before && r2.currentBranch() == "feature")
    }

    @Test func cherryPickAndRevertWithConflicts() throws {
        let s = try SCMSandbox("pick")
        defer { s.cleanUp() }
        let repo = try s.makeConflict()
        let file = s.path("f.txt")
        let pick = try #require(repo.resolve("feature"))
        #expect(try repo.cherryPickCommit(pick) == .conflicts([file]))
        #expect(repo.integrationState() == .cherryPicking(commit: pick))
        var doc = try #require(repo.mergeDocument(forConflictedFile: file))
        doc.choose(.custom(["MERGED"]), hunk: 0)
        try repo.resolveConflict(file, text: doc.result)
        guard case .completed = try repo.continueIntegration() else { Issue.record("expected the pick commit"); return }
        #expect(try s.git("log", "-1", "--format=%s") == "Feature change\n")
        #expect(try s.read("f.txt") == "a\nb\nMERGED\nd\ne\n")

        // A clean revert of the pick.
        guard case .completed = try repo.revert("HEAD") else { Issue.record("expected a revert"); return }
        #expect(try s.read("f.txt") == "a\nb\nMAIN\nd\ne\n")
    }

    @Test func stashPushApplyPopDrop() throws {
        let s = try SCMSandbox("stash")
        defer { s.cleanUp() }
        try s.commit("a.txt", "1\n", "One")
        let repo = s.repository
        try s.write("a.txt", "2\n")
        try s.write("new.txt", "n\n")
        try repo.stash(message: "work in progress")
        #expect(try repo.changes().isEmpty)
        #expect(repo.stashList() == [.init(ref: "stash@{0}", description: "On main: work in progress")])
        #expect(repo.stashList().first?.message == "work in progress")
        #expect(repo.files(inStash: "stash@{0}").map(\.path) == ["a.txt"])

        try repo.applyStash("stash@{0}")
        #expect(try s.read("a.txt") == "2\n" && repo.stashList().count == 1)
        try s.git("checkout", "--", "a.txt")
        try FileManager.default.removeItem(atPath: s.path("new.txt"))
        try repo.applyStash("stash@{0}", pop: true)
        #expect(try s.read("a.txt") == "2\n" && repo.stashList().isEmpty)
        #expect(FileManager.default.fileExists(atPath: s.path("new.txt")))

        // A stash that conflicts with a later commit.
        try repo.stash(message: "edit")
        try s.commit("a.txt", "3\n", "Three")
        guard case .conflicts(let files) = try repo.applyStash("stash@{0}", pop: true) else { Issue.record("expected conflicts"); return }
        #expect(files == [s.path("a.txt")])
        #expect(repo.stashList().count == 1)   // git keeps a conflicting stash
        #expect(repo.integrationState() == .none)
        let doc = try #require(repo.mergeDocument(forConflictedFile: s.path("a.txt")))
        #expect(doc.oursLabel == "main" && doc.theirsLabel == "Stashed changes")
        try repo.resolveConflict(s.path("a.txt"), text: "3\n")
        try repo.dropStash("stash@{0}")
        #expect(repo.stashList().isEmpty)
        #expect(throws: GitRepository.GitError.self) { try repo.dropStash("main") }
    }

    @Test func tags() throws {
        let s = try SCMSandbox("tags")
        defer { s.cleanUp() }
        try s.commit("a.txt", "1\n", "One")
        let repo = s.repository
        let first = try #require(repo.headHash())
        try s.commit("a.txt", "2\n", "Two")
        try repo.createTag("v1.0", at: first)
        try repo.createTag("v2.0", message: "Second release")
        #expect(!repo.isValidTagName("bad tag") && !repo.isValidTagName("-v"))
        #expect(throws: GitRepository.GitError.self) { try repo.createTag("bad..tag") }
        #expect(throws: GitRepository.GitError.self) { try repo.createTag("v1.0") }   // exists
        let tags = repo.tagDetails()
        #expect(tags.map(\.name) == ["v1.0", "v2.0"])
        #expect(tags[0] == .init(name: "v1.0", commit: first, message: "", isAnnotated: false))
        #expect(tags[1].commit == repo.headHash() && tags[1].isAnnotated && tags[1].message == "Second release")
        try repo.createBranch("from-tag", from: "v1.0")
        #expect(repo.resolve("from-tag") == first)
        try repo.deleteTag("v1.0")
        #expect(try repo.tags().map(\.name) == ["v2.0"])
    }

    /// Remotes against a bare repository in the temporary folder (never a
    /// real remote).
    @Test func remotesWithALocalBareRepository() throws {
        let s = try SCMSandbox("remote")
        defer { s.cleanUp() }
        let bare = try s.makeRemote()
        try s.commit("a.txt", "1\n", "One")
        let repo = s.repository
        try repo.addRemote("origin", url: bare.path)
        #expect(try repo.remotes() == [.init(name: "origin", url: bare.path)])
        #expect(throws: GitRepository.GitError.self) { try repo.addRemote("", url: "x") }

        try repo.push(remote: "origin", branch: "main", setUpstream: true)
        #expect(repo.upstream(of: "main") == "origin/main")
        #expect(repo.aheadBehind("main").map { [$0.ahead, $0.behind] } == [0, 0])
        try s.commit("a.txt", "2\n", "Two")
        #expect(repo.aheadBehind("main").map { [$0.ahead, $0.behind] } == [1, 0])

        // A second clone pushes a commit; the first pulls it.
        let other = s.folder.appendingPathComponent("other")
        try GitRepository.clone(bare.path, into: other)
        try s.configure(other)
        try "o\n".write(to: other.appendingPathComponent("o.txt"), atomically: true, encoding: .utf8)
        let otherRepo = try #require(GitRepository(containing: other))
        try otherRepo.commit(files: [otherRepo.root.appendingPathComponent("o.txt").path], message: "From other")
        try otherRepo.push(remote: "origin", branch: "main")

        try repo.fetch(remote: "origin")
        #expect(repo.aheadBehind("main").map { [$0.ahead, $0.behind] } == [1, 1])
        // Diverged: fast-forward only refuses; a merge pull works.
        #expect(throws: GitRepository.GitError.self) { try repo.pull(remote: "origin", branch: "main") }
        guard case .completed = try repo.pull(remote: "origin", branch: "main", style: .merge) else { Issue.record("expected a merge"); return }
        #expect(FileManager.default.fileExists(atPath: s.path("o.txt")))
        try repo.push(remote: "origin", branch: "main")
        #expect(repo.aheadBehind("main").map { [$0.ahead, $0.behind] } == [0, 0])

        // Branches and tags on the remote; checking out a remote branch.
        try repo.createBranch("shared")
        try repo.push(remote: "origin", branch: "shared")
        try repo.createTag("v1")
        try repo.push(remote: "origin", tag: "v1")
        #expect(try GitRepository.run("/usr/bin/git", ["-C", bare.path, "tag"]) == "v1\n")
        try otherRepo.fetch(remote: "origin")
        try otherRepo.checkout("origin/shared", changes: .refuse)
        #expect(otherRepo.currentBranch() == "shared" && otherRepo.upstream(of: "shared") == "origin/shared")
        try repo.deleteRemoteBranch(remote: "origin", branch: "shared")
        try repo.fetch(remote: "origin")
        #expect(try repo.remoteBranches().map(\.name) == ["origin/main"])

        try repo.removeRemote("origin")
        #expect(try repo.remotes().isEmpty)
    }
}
