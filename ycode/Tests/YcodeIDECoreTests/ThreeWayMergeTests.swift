import Foundation
import Testing
@testable import YcodeIDECore

/// The three-way merge, conflict markers, merge documents, blame and the
/// Integrate menu's conflict items (`specs/ide/comparison.md` and
/// `source-control.md`, "Ycode implementation").
struct ThreeWayMergeTests {
    typealias Chunk = ThreeWayMerge.Chunk

    @Test func classifiesChunks() {
        let base = ["1", "2", "3", "4", "5", "6", "7"]
        let ours = ["1", "TWO", "3", "4", "5", "SIX", "7"]
        let theirs = ["1", "2", "3", "FOUR", "5", "SIX", "7", "8"]
        let chunks = ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
        #expect(chunks.map(\.kind) == [.unchanged, .oursOnly, .unchanged, .theirsOnly, .unchanged, .bothSame, .unchanged, .theirsOnly])
        #expect(chunks[1] == Chunk(kind: .oursOnly, base: ["2"], ours: ["TWO"], theirs: ["2"]))
        #expect(chunks[7] == Chunk(kind: .theirsOnly, base: [], ours: [], theirs: ["8"]))
        let doc = MergeDocument(chunks: chunks)
        #expect(doc.isResolved && doc.conflictCount == 0)
        #expect(doc.result == "1\nTWO\n3\nFOUR\n5\nSIX\n7\n8\n")
    }

    @Test func conflictsAndChoices() {
        var doc = MergeDocument(base: "a\nb\nc\n", ours: "a\nB1\nc\n", theirs: "a\nB2\nc\nd\n", oursLabel: "main", theirsLabel: "topic")
        #expect(doc.chunks.map(\.kind) == [.unchanged, .conflict, .unchanged, .theirsOnly])
        #expect(doc.hunks == [1, 3] && doc.unresolvedCount == 1)
        #expect(doc.result == "a\n<<<<<<< main\nB1\n=======\nB2\n>>>>>>> topic\nc\nd\n")
        #expect(doc.layout().hunkRanges == [1..<6, 7..<8])
        let expected: [(MergeDocument.Choice, String)] = [
            (.ours, "a\nB1\nc\nd\n"), (.theirs, "a\nB2\nc\nd\n"), (.oursThenTheirs, "a\nB1\nB2\nc\nd\n"),
            (.theirsThenOurs, "a\nB2\nB1\nc\nd\n"), (.base, "a\nb\nc\nd\n"), (.custom(["x", "y"]), "a\nx\ny\nc\nd\n"),
        ]
        for (choice, text) in expected {
            doc.choose(choice, hunk: 0)
            #expect(doc.result == text)
        }
        #expect(doc.isResolved)
        doc.chooseAll(.ours)
        #expect(doc.result == "a\nB1\nc\n")
        #expect(doc.oursText == "a\nB1\nc\n" && doc.theirsText == "a\nB2\nc\nd\n" && doc.baseText == "a\nb\nc\n")
        #expect(doc.sideStarts(forHunk: 1) == (3, 3, 3))
    }

    @Test func steppingThroughHunks() {
        var doc = MergeDocument(base: "1\n2\n3\n4\n5\n", ours: "X\n2\nY\n4\nZ\n", theirs: "x\n2\ny\n4\nZ\n")
        #expect(doc.hunks.count == 3)
        #expect(doc.step(from: nil, forward: true) == 0 && doc.step(from: nil, forward: false) == 2)
        #expect(doc.step(from: 2, forward: true) == 0 && doc.step(from: 0, forward: false) == 2)
        doc.choose(.ours, hunk: 0)
        #expect(doc.step(from: 0, forward: true, unresolvedOnly: true) == 1)
        doc.choose(.ours, hunk: 1)
        // Hunk 2 is one-sided (resolved by default).
        #expect(doc.step(from: 1, forward: true, unresolvedOnly: true) == nil)
    }

    @Test func insertionsAndDeletionsAtTheEnds() {
        let c = ThreeWayMerge.merge(base: [], ours: ["a"], theirs: ["b"])
        #expect(c == [Chunk(kind: .conflict, base: [], ours: ["a"], theirs: ["b"])])
        let d = ThreeWayMerge.merge(base: ["a", "b"], ours: ["b"], theirs: ["a", "b"])
        #expect(d.map(\.kind) == [.oursOnly, .unchanged])
        #expect(MergeDocument(chunks: d).result == "b\n")
        #expect(ThreeWayMerge.merge(base: [], ours: [], theirs: []).isEmpty)
        #expect(MergeDocument(base: "", ours: "", theirs: "").result == "")
    }

    @Test func twoWayCompareTakesTheRightByDefault() {
        var doc = MergeDocument(chunks: ThreeWayMerge.compare(left: ["a", "b", "c"], right: ["a", "B", "c", "d"]))
        #expect(doc.chunks.map(\.kind) == [.unchanged, .theirsOnly, .unchanged, .theirsOnly])
        #expect(doc.result == "a\nB\nc\nd\n")
        doc.choose(.ours, hunk: 0)
        doc.choose(.ours, hunk: 1)
        #expect(doc.result == "a\nb\nc\n")
    }

    @Test func parsesConflictMarkers() throws {
        let text = "top\n<<<<<<< HEAD\nmine\n||||||| base\nold\n=======\nyours\n>>>>>>> topic\nmid\n<<<<<<<\nsame\n=======\nsame\n>>>>>>>\nend\n"
        let p = try #require(ConflictMarkers.parse(text))
        #expect(p.oursLabel == "HEAD" && p.theirsLabel == "topic")
        #expect(p.chunks.map(\.kind) == [.unchanged, .conflict, .unchanged, .bothSame, .unchanged])
        #expect(p.chunks[1] == Chunk(kind: .conflict, base: ["old"], ours: ["mine"], theirs: ["yours"]))
        #expect(ConflictMarkers.hasConflicts(text))
        #expect(!ConflictMarkers.hasConflicts("no markers\n======= not one\n"))
        #expect(ConflictMarkers.parse("<<<<<<< a\nopen\n") == nil)
        // A line of seven '<' followed by text without a space is not a marker.
        #expect(ConflictMarkers.parse("<<<<<<<x\n")?.chunks.map(\.kind) == [.unchanged])
    }

    @Test func blamePorcelainAndBlocks() throws {
        let s = try SCMSandbox("blame")
        defer { s.cleanUp() }
        try s.commit("f.txt", "one\ntwo\nthree\n", "First")
        try s.git("-c", "user.name=Second Author", "-c", "user.email=second@ycode.invalid", "commit", "-q", "--allow-empty", "-m", "Empty")
        try s.write("f.txt", "one\nTWO\nthree\nfour\n")
        try s.git("add", "f.txt")
        try s.git("-c", "user.name=Second Author", "-c", "user.email=second@ycode.invalid", "commit", "-q", "-m", "Second\n\nBody")
        let repo = s.repository
        let lines = try #require(repo.blame(of: s.path("f.txt")))
        #expect(lines.map(\.author) == ["Ycode Test", "Second Author", "Ycode Test", "Second Author"])
        #expect(lines[1].summary == "Second" && lines[1].authorEmail == "second@ycode.invalid")
        #expect(lines[0].hash == repo.resolve("HEAD~2") && lines[1].hash == repo.headHash())
        let blocks = GitBlame.blocks(lines)
        #expect(blocks.map(\.firstLine) == [1, 2, 3, 4] && blocks.map(\.lineCount) == [1, 1, 1, 1])

        // Unsaved edits: changed lines are not committed yet.
        let edited = try #require(repo.blame(of: s.path("f.txt"), contents: "one\nTWO\nnew line\nnew 2\nthree\nfour\n"))
        #expect(edited.count == 6)
        #expect(edited[2].isUncommitted && edited[3].isUncommitted && !edited[4].isUncommitted)
        let b2 = GitBlame.blocks(edited)
        #expect(b2.map(\.lines) == [1...1, 2...2, 3...4, 5...5, 6...6])
        #expect(GitBlame.annotation(edited[2]) == "Not Committed Yet")
        let now = lines[0].date
        #expect(GitBlame.annotation(lines[0], now: now) == "Ycode Test  Today")
        #expect(GitBlame.details(lines[1]).hasPrefix("\(lines[1].shortHash) \u{2014} Second Author <second@ycode.invalid>\n"))
        #expect(GitBlame.details(lines[1]).hasSuffix("\n\nSecond"))

        // Not in the history or outside the repository: none.
        try s.write("untracked.txt", "x\n")
        #expect(repo.blame(of: s.path("untracked.txt")) == nil)
        #expect(repo.blame(of: "/etc/hosts") == nil)
        #expect(GitBlame.parse("").isEmpty)
    }

    @Test func fileCompareDiffAndMerge() throws {
        let d = FileCompare.unifiedDiff(old: "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", new: "1\nTWO\n3\n4\n5\n6\n7\n8\n9\n10\n11\n",
                                        oldName: "a.txt", newName: "b.txt", context: 1)
        #expect(d == "--- a.txt\n+++ b.txt\n@@ -1,3 +1,3 @@\n 1\n-2\n+TWO\n 3\n@@ -10 +10,2 @@\n 10\n+11\n")
        // UnifiedDiffLines reads it back with line numbers.
        let parsed = UnifiedDiffLines.parse(String(d[try #require(d.range(of: "@@")).lowerBound...]))
        #expect(parsed.filter { $0.kind == .added }.map(\.new) == [2, 11])
        #expect(parsed.filter { $0.kind == .removed }.map(\.old) == [2])
        #expect(FileCompare.unifiedDiff(old: "same\n", new: "same\n", oldName: "a", newName: "b").isEmpty)
        #expect(FileCompare.unifiedDiff(old: "", new: "x\n", oldName: "a", newName: "b") == "--- a\n+++ b\n@@ -0,0 +1 @@\n+x\n")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-compare-cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ n: String, _ t: String) throws -> String {
            let p = folder.appendingPathComponent(n).path
            try t.write(toFile: p, atomically: true, encoding: .utf8)
            return p
        }
        let base = try file("base", "a\nb\nc\nd\ne\n"), l = try file("l", "a\nB\nc\nd\ne\n"), r = try file("r", "a\nb\nc\nD\ne\n"),
            x = try file("x", "a\nX\nc\nd\ne\n")
        var out = "", err = ""
        #expect(FileCompare.run([l, r], print: { out += $0 }, error: { err += $0 }) == 1 && out.hasPrefix("--- \(l)\n+++ \(r)\n"))
        out = ""
        #expect(FileCompare.run([l, l], print: { out += $0 }, error: { err += $0 }) == 0 && out.isEmpty)
        // Changes on neighbouring lines conflict, as in git's merge.
        #expect(ThreeWayMerge.merge(base: ["a", "b", "c"], ours: ["a", "B", "c"], theirs: ["a", "b", "C"]).map(\.kind) == [.unchanged, .conflict])
        #expect(FileCompare.run([l, r, "--ancestor", base], print: { out += $0 }, error: { err += $0 }) == 0 && out == "a\nB\nc\nD\ne\n")
        let merged = folder.appendingPathComponent("merged").path
        #expect(FileCompare.run([l, x, "--ancestor", base, "--merge", merged], print: { _ in }, error: { err += $0 }) == 1)
        #expect(try String(contentsOfFile: merged, encoding: .utf8) == "a\n<<<<<<< \(l)\nB\n=======\nX\n>>>>>>> \(x)\nc\nd\ne\n")
        #expect(err.hasSuffix("1 conflict\n"))
        #expect(FileCompare.run([l], print: { _ in }, error: { _ in }) == 2)
        #expect(FileCompare.run([l, r, "--merge", merged], print: { _ in }, error: { _ in }) == 2)
        #expect(FileCompare.run([l, folder.appendingPathComponent("missing").path], print: { _ in }, error: { _ in }) == 2)
    }

    @Test func sourceControlRowMenus() {
        typealias M = SourceControlRowMenu
        func titles(_ key: String, _ ctx: M.Context) -> [String] { M.items(forKey: key, in: ctx).map { $0.action == nil ? "|" : $0.title } }
        let ctx = M.Context(currentBranch: "main", remotes: ["origin"])
        #expect(titles("branch:main", ctx) == ["New Branch from \u{201C}main\u{201D}…", "New Tag from \u{201C}main\u{201D}…", "|",
                                              "Push \u{201C}main\u{201D}…", "Pull…", "|", "Rename…", "Delete…"])
        #expect(M.items(forKey: "branch:main", in: ctx).last?.isEnabled == false)
        #expect(M.items(forKey: "branch:dev", in: ctx).first?.action == .checkout("dev"))
        #expect(titles("remoteBranch:origin/dev", ctx).last == "Delete \u{201C}dev\u{201D} from \u{201C}origin\u{201D}…")
        #expect(M.items(forKey: "remoteBranch:origin/dev", in: ctx).first?.action == .checkout("origin/dev"))
        #expect(titles("tag:v1", ctx) == ["New Branch from \u{201C}v1\u{201D}…", "Push \u{201C}v1\u{201D}…", "|", "Delete…"])
        #expect(titles("tag:v1", M.Context(currentBranch: "main")) == ["New Branch from \u{201C}v1\u{201D}…", "|", "Delete…"])
        #expect(titles("stash:stash@{1}", ctx) == ["Apply Stashed Changes", "Apply and Delete Stash", "|", "Delete…"])
        #expect(titles("repository", ctx) == ["New Branch…", "New Tag…", "|", "Add Remote…"])
        #expect(titles("group:Tags", ctx) == ["New Tag…"] && titles("unknown", ctx).isEmpty)
        #expect(titles("change:/r/a.swift", ctx).isEmpty)
        #expect(titles("change:/r/a.swift", M.Context(conflicted: ["/r/a.swift"])) == ["Resolve Conflicts…", "Mark as Resolved"])
        // While a merge is stopped, starting another integration is disabled.
        let busy = M.Context(currentBranch: "main", integration: .merging(branch: "dev"))
        #expect(M.items(forKey: "branch:dev", in: busy).filter { $0.action != nil && !$0.isEnabled }.map(\.title)
                == ["Check Out \u{201C}dev\u{201D}…", "Merge \u{201C}dev\u{201D} into \u{201C}main\u{201D}…", "Rebase \u{201C}main\u{201D} onto \u{201C}dev\u{201D}…"])
        // Detached HEAD: no rebase.
        #expect(M.items(forKey: "branch:dev", in: M.Context()).first { $0.title.hasPrefix("Rebase") }?.isEnabled == false)
    }

    @Test func integrateMenuConflictItems() {
        var s = IntegrateMenuState()
        s.hasRepository = true
        #expect(!s.isEnabled("scmResolveConflicts:") && !s.isEnabled("scmContinueIntegration:") && !s.isEnabled("scmAbortIntegration:"))
        s.integration = .merging(branch: "feature")
        s.conflictCount = 1
        #expect(s.isEnabled("scmResolveConflicts:") && !s.isEnabled("scmContinueIntegration:") && s.isEnabled("scmAbortIntegration:"))
        s.conflictCount = 0
        #expect(s.isEnabled("scmContinueIntegration:"))

        var ctx = MenuContext()
        #expect(!MenuConditions.isShown(.integrationInProgress, in: ctx) && !MenuConditions.isShown(.integrationInProgress, in: nil))
        ctx.hasConflicts = true
        #expect(MenuConditions.isShown(.integrationInProgress, in: ctx))
        ctx.integrationVerb = "Rebase"
        #expect(MenuTitles.title(generic: "Continue", in: ctx) == "Continue Rebase")
        #expect(MenuTitles.title(generic: "Abort", in: ctx) == "Abort Rebase")
        #expect(GitRepository.IntegrationState.cherryPicking(commit: "x").verb == "Cherry-Pick")
        #expect(GitRepository.mergedName("Merge branch 'feature' into main\n\n# Conflicts:") == "feature")
        #expect(GitRepository.mergedName("Merge remote-tracking branch 'origin/x'") == "origin/x")
        #expect(GitRepository.mergedName("Something else") == nil)
    }
}
