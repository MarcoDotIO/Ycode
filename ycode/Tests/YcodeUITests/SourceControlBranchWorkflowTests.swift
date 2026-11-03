import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// A package repository in a fresh temporary folder, with a local identity
/// and no signing; a bare repository beside it is the only "remote".
private struct Sandbox {
    let folder: URL
    let dir: URL

    init(_ name: String) throws {
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ycode-scm-ui-\(name)-\(UUID().uuidString.prefix(8))")
        dir = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try git("init", "-q", "-b", "main")
        for (k, v) in [("user.name", "Ycode Test"), ("user.email", "test@ycode.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
                       ("merge.conflictstyle", "merge")] {
            try git("config", k, v)
        }
        try write("Sources/App/main.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "Initial")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    func git(_ args: String...) throws -> String { try GitRepository.run("/usr/bin/git", ["-C", dir.path] + args) }
    func write(_ rel: String, _ text: String) throws { try text.write(to: dir.appendingPathComponent(rel), atomically: true, encoding: .utf8) }
    func read(_ rel: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) }
    func commit(_ rel: String, _ text: String, _ message: String) throws {
        try write(rel, text)
        try git("add", "--", rel)
        try git("commit", "-q", "-m", message)
    }

    /// main and feature both change line 2 of main.swift.
    func makeConflict() throws {
        try git("switch", "-q", "-c", "feature")
        try commit("Sources/App/main.swift", "let a = 1\nlet b = 20\nlet c = 3\n", "Feature b")
        try git("switch", "-q", "main")
        try commit("Sources/App/main.swift", "let a = 1\nlet b = 200\nlet c = 3\n", "Main b")
    }

    @MainActor
    func window() async throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        await waitFor("loading the window") { await wc.sourceControl.idle() }
        return wc
    }
}

/// Awaits `body` for at most `seconds`. Past that the test records an
/// issue and goes on. A main actor that never yields cannot even report
/// the timeout, so a watchdog thread stops the test process after twice
/// the time, with a message, instead of letting the suite hang.
@MainActor
func waitFor<T: Sendable>(_ what: String, seconds: Double = 180, sourceLocation: SourceLocation = #_sourceLocation,
                          _ body: @escaping @MainActor () async -> T) async -> T? {
    let finished = Latch()
    let watchdog = DispatchWorkItem {
        guard !finished.isSet else { return }
        FileHandle.standardError.write(Data("SourceControlBranchWorkflowTests: \(what) hung for \(Int(seconds * 2)) s with the main actor busy; stopping.\n".utf8))
        exit(70)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds * 2, execute: watchdog)
    defer { finished.set(); watchdog.cancel() }
    let result: T?? = await withCheckedContinuation { (c: CheckedContinuation<T??, Never>) in
        let once = ResumeOnce(c)
        Task { @MainActor in once.resume(.some(await body())) }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(.none)
        }
    }
    guard let value = result else {
        Issue.record("\(what) did not finish within \(Int(seconds)) s", sourceLocation: sourceLocation)
        return nil
    }
    return value
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock { defer { continuation = nil }; return continuation }
        c?.resume(returning: value)
    }
}

private func find(_ items: [OutlineItem], key: String) -> OutlineItem? {
    for i in items {
        if i.scmKey == key { return i }
        if let f = find(i.children, key: key) { return f }
    }
    return nil
}

/// Gap #13: branch workflows, the conflict editor, Compare Files and
/// Authors in the window (`specs/ide/source-control.md`, `comparison.md`,
/// "Ycode implementation").
@MainActor
@Suite(.serialized) struct SourceControlBranchWorkflowTests {
    @Test func navigatorMenusDriveBranchTagStashAndRemoteOperations() async throws {
        let s = try Sandbox("scm-ui-branches")
        defer { s.cleanUp() }
        try s.git("branch", "feature")
        try s.git("tag", "v1")
        let bare = s.folder.appendingPathComponent("origin.git")
        _ = try GitRepository.run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", bare.path])
        try s.git("remote", "add", "origin", bare.path)
        try s.write("Sources/App/main.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try s.git("stash", "push", "-q", "-m", "saved")

        let wc = try await s.window()
        let scm = wc.sourceControl
        scm.setMode(.repositories)
        let roots = wc.navigator.rows(1)
        #expect(find(roots, key: "group:Branches")?.title == "Branches")
        #expect(find(roots, key: "remote:origin")?.title == "origin")

        // The row menus, through the navigator's own context menu.
        wc.navigator.select(1)
        #expect(wc.navigator.selectSourceControlRow(key: "branch:feature"))
        let menu = NSMenu()
        wc.navigator.rebuildRowMenu(menu)
        #expect(menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "Check Out \u{201C}feature\u{201D}…", "|", "New Branch from \u{201C}feature\u{201D}…", "New Tag from \u{201C}feature\u{201D}…", "|",
            "Merge \u{201C}feature\u{201D} into \u{201C}main\u{201D}…", "Rebase \u{201C}main\u{201D} onto \u{201C}feature\u{201D}…", "|",
            "Push \u{201C}feature\u{201D}…", "|", "Rename…", "Delete…",
        ])
        #expect(scm.rowMenuItems(forKey: "branch:main").first { $0.title == "Delete…" }?.isEnabled == false)
        #expect(scm.rowMenuItems(forKey: "group:Remotes").map(\.title) == ["Add Remote…"])
        #expect(scm.rowMenuItems(forKey: "remote:origin").map { $0.isSeparatorItem ? "|" : $0.title } == ["Fetch \u{201C}origin\u{201D}", "|", "Remove \u{201C}origin\u{201D}…"])

        // Create and switch, rename, delete (an unmerged branch is forced
        // after the second confirmation, which is automatic off screen).
        scm.createBranch("topic", checkout: true)
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.currentBranch == "topic")
        try s.commit("Sources/App/Extra.swift", "let extra = 1\n", "Extra")
        scm.checkout("main", changes: .refuse)
        scm.renameBranch("topic", to: "topic-2")
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.branches.map(\.name) == ["feature", "main", "topic-2"])
        scm.run(.deleteBranch("topic-2"))
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.branches.map(\.name) == ["feature", "main"])

        // Stash: apply from its menu item; then delete it.
        let apply = try #require(scm.rowMenuItems(forKey: "stash:stash@{0}").first { $0.title == "Apply Stashed Changes" })
        _ = (apply.target as? NSObject)?.perform(apply.action, with: apply)
        await waitFor("source control") { await scm.idle() }
        #expect(try s.read("Sources/App/main.swift") == "let a = 2\nlet b = 2\nlet c = 3\n")
        scm.run(.dropStash("stash@{0}"))
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.stashes.isEmpty)

        // Tags; pushing a branch and a tag to the bare remote.
        scm.createTag("v2", message: "Two")
        scm.run(.deleteTag("v1"))
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.tags.map(\.name) == ["v2"])
        scm.push(branch: "main", remote: "origin")
        scm.run(.pushTag("v2"))
        await waitFor("source control") { await scm.idle() }
        #expect(try GitRepository.run("/usr/bin/git", ["-C", bare.path, "tag"]) == "v2\n")
        #expect(scm.snapshot.repository?.upstream(of: "main") == "origin/main")
        scm.run(.fetch(remote: "origin"))
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.remoteBranches.map(\.name) == ["origin/main"])
        #expect(scm.rowMenuItems(forKey: "remoteBranch:origin/main").first?.title == "Check Out \u{201C}main\u{201D}…")
    }

    @Test func conflictEditorResolvesAMergeAndContinues() async throws {
        let s = try Sandbox("scm-ui-conflict")
        defer { s.cleanUp() }
        try s.makeConflict()
        let wc = try await s.window()
        let scm = wc.sourceControl
        let file = s.dir.appendingPathComponent("Sources/App/main.swift").path

        scm.merge("feature")
        await waitFor("source control") { await scm.idle() }
        #expect(scm.lastIntegrationResult == .conflicts([file]))
        let editor = try #require(scm.conflictEditor)
        await waitFor("the conflict editor") { await editor.idle() }
        #expect(editor.files == [file] && editor.currentFile == file)
        #expect(editor.titleLabel.stringValue == "Conflicts in main.swift")
        #expect(editor.statusLabel.stringValue == "1 conflict unresolved")
        #expect(editor.hunkLabel.stringValue == "Change 1 of 1 (conflict)")
        #expect(!editor.resolveButton.isEnabled && editor.choiceControl.selectedSegment == -1)
        #expect(!editor.continueButton.isHidden && editor.continueButton.title == "Continue Merge" && !editor.continueButton.isEnabled)
        #expect(editor.resultText.contains("<<<<<<< main\nlet b = 200\n=======\nlet b = 20\n>>>>>>> feature\n"))
        #expect(editor.comparison.rows.contains { $0.kind == .changed })

        // The window's state: navigator header, Integrate menu, menu titles.
        scm.setMode(.changes)
        #expect(wc.navigator.rows(1).first?.detail == "main (Merging \u{201C}feature\u{201D})")
        #expect(scm.rowMenuItems(forKey: "change:" + file).map(\.title) == ["Resolve Conflicts…", "Mark as Resolved"])
        let state = scm.menuState()
        #expect(state.isEnabled("scmResolveConflicts:") && state.isEnabled("scmAbortIntegration:") && !state.isEnabled("scmContinueIntegration:"))
        #expect(wc.menuContext.integrationVerb == "Merge" && wc.menuContext.hasConflicts)
        #expect(MenuTitles.title(generic: "Continue", in: wc.menuContext) == "Continue Merge")
        #expect(scm.rowMenuItems(forKey: "branch:feature").first { $0.title.hasPrefix("Merge") }?.isEnabled == false)

        // Base / ours / theirs, two at a time.
        editor.setPair(.baseLeft)
        #expect(editor.comparison.leftView.string.contains("let b = 2\n") && editor.comparison.rightView.string.contains("let b = 200"))
        editor.setPair(.baseRight)
        #expect(editor.comparison.rightView.string.contains("let b = 20\n"))
        editor.setPair(.leftRight)

        // Per hunk: right, both, then a hand edit.
        editor.choose(.theirs)
        #expect(editor.resultText == "let a = 1\nlet b = 20\nlet c = 3\n" && editor.resolveButton.isEnabled)
        #expect(editor.choiceControl.selectedSegment == 1 && editor.statusLabel.stringValue == "Resolved")
        editor.choose(.oursThenTheirs)
        #expect(editor.resultText == "let a = 1\nlet b = 200\nlet b = 20\nlet c = 3\n")
        editor.beginEditing()
        #expect(editor.isEditing && editor.choiceControl.selectedSegment == 5 && !editor.hunkEditorScroll.isHidden)
        editor.setEditedText("let b = 2_000\n")
        #expect(editor.resultText == "let a = 1\nlet b = 2_000\nlet c = 3\n")

        // Mark as Resolved, then Continue Merge.
        #expect(await waitFor("Mark as Resolved") { await editor.markResolved() } == true)
        await waitFor("source control") { await scm.idle() }
        #expect(editor.files.isEmpty && editor.statusLabel.stringValue == "All conflicts resolved")
        #expect(editor.continueButton.isEnabled)
        #expect(scm.menuState().isEnabled("scmContinueIntegration:"))
        editor.continueButton.performClick(nil)
        await waitFor("source control") { await scm.idle() }
        guard case .completed? = scm.lastIntegrationResult else { Issue.record("expected the merge commit"); return }
        #expect(scm.conflictEditor == nil && scm.snapshot.integration == .none)
        #expect(try s.read("Sources/App/main.swift") == "let a = 1\nlet b = 2_000\nlet c = 3\n")
        #expect(try s.git("rev-list", "--parents", "-n", "1", "HEAD").split(separator: " ").count == 3)
    }

    /// Regression: `idle()` once waited on a wrapper task that finished
    /// before the code clearing it ran; awaiting a finished task does not
    /// suspend, so the main actor spun and the suite hung. Every read is
    /// now a task that removes itself as its last step.
    @Test func conflictEditorIdleNeverSpinsOnAFinishedRead() async throws {
        let s = try Sandbox("scm-ui-idle")
        defer { s.cleanUp() }
        try s.makeConflict()
        let repo = try #require(GitRepository(containing: s.dir))
        #expect(try repo.merge("feature") != .upToDate)
        let file = repo.root.appendingPathComponent("Sources/App/main.swift").path
        let editor = ConflictEditorController(repository: repo, focus: file)
        _ = editor.view
        for _ in 0..<40 {
            // Reads started from outside idle(), in every interleaving.
            Task { await editor.show(file: file) }
            editor.reloadFiles()
            await Task.yield()
            await waitFor("the conflict editor", seconds: 60) { await editor.idle() }
            #expect(editor.loading == nil)
        }
        #expect(editor.document?.conflictCount == 1 && editor.currentFile == file)
        // The invariant idle() relies on: once a tracked task has finished,
        // it is no longer listed (a finished task's `value` returns without
        // suspending, so a listed one would make idle() spin).
        let t = editor.track { _ = await Task.detached { 1 }.value }
        await t.value
        #expect(editor.loading == nil)
    }

    @Test func rebaseConflictOpensTheEditorAndAbortsFromTheIntegrateMenu() async throws {
        let s = try Sandbox("scm-ui-rebase")
        defer { s.cleanUp() }
        try s.makeConflict()
        try s.git("switch", "-q", "feature")
        let wc = try await s.window()
        let scm = wc.sourceControl
        let before = try s.git("rev-parse", "HEAD")
        scm.rebase(onto: "main")
        await waitFor("source control") { await scm.idle() }
        let editor = try #require(scm.conflictEditor)
        await waitFor("the conflict editor") { await editor.idle() }
        guard case .rebasing(let branch, _, _, _) = scm.snapshot.integration else { Issue.record("expected rebasing"); return }
        #expect(branch == "feature")
        #expect(editor.abortButton.title == "Abort Rebase" && wc.menuContext.integrationVerb == "Rebase")
        #expect(editor.document?.theirsLabel == "feature")
        wc.scmAbortIntegration(nil)
        await waitFor("source control") { await scm.idle() }
        #expect(scm.snapshot.integration == .none && scm.conflictEditor == nil)
        #expect(try s.git("rev-parse", "HEAD") == before)

        // A cherry-pick of a clean commit from another branch.
        try s.git("switch", "-q", "main")
        try s.git("switch", "-q", "-c", "side")
        try s.commit("Sources/App/Side.swift", "let side = 1\n", "Side file")
        let pick = try s.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try s.git("switch", "-q", "main")
        await waitFor("source control") { await wc.sourceControl.idle() }
        wc.refreshFileStatus(nil)
        scm.cherryPick(pick)
        await waitFor("source control") { await scm.idle() }
        guard case .completed? = scm.lastIntegrationResult else { Issue.record("expected the pick"); return }
        #expect(FileManager.default.fileExists(atPath: s.dir.appendingPathComponent("Sources/App/Side.swift").path))
    }

    @Test func compareFilesTwoAndThreeWay() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ycode-compare-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, _ text: String) throws -> URL {
            let u = folder.appendingPathComponent(name)
            try text.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let left = try file("left.txt", "one\ntwo\nthree\nfour\n")
        let right = try file("right.txt", "one\nTWO\nthree\nfour\nfive\n")
        let base = try file("base.txt", "one\ntwo\nthree\n4\n")

        // The command: Ycode ▸ Open Developer Tool ▸ Compare Files….
        #expect(AppCommands.handles("compareFiles:") && AppCommands.shared.responds(to: NSSelectorFromString("compareFiles:")))
        let tools = CommandTable.menus[0].1.compactMap { item -> [MenuItemSpec]? in
            if case .submenu("Open Developer Tool", let items) = item { return items } else { return nil }
        }.first ?? []
        #expect(tools.contains(.command(.init("Compare Files…", "", [], "compareFiles:"))))

        // Two files: every difference takes the right side until changed.
        let two = CompareFilesWindowController.show(left: left, right: right, display: false)
        let e2 = two.editor
        _ = e2.view
        #expect(two.window?.title == "Compare Files" && e2.isComparingFiles)
        #expect(e2.titleLabel.stringValue == "left.txt \u{2194} right.txt")
        #expect(e2.document?.hunks.count == 2 && e2.hunkLabel.stringValue == "Difference 1 of 2")
        #expect(e2.pairControl.isHidden && !e2.choiceControl.isEnabled(forSegment: 4))
        #expect(!e2.saveButton.isHidden && e2.resolveButton.isHidden && e2.continueButton.isHidden)
        #expect(e2.resultText == "one\nTWO\nthree\nfour\nfive\n")
        e2.choose(.ours)          // first difference: left
        #expect(e2.hunkLabel.stringValue == "Difference 1 of 2")   // nothing unresolved to jump to
        e2.nextHunk(nil)
        #expect(e2.hunkLabel.stringValue == "Difference 2 of 2")
        e2.choose(.ours)
        let out2 = folder.appendingPathComponent("out2.txt")
        try e2.save(to: out2)
        #expect(try String(contentsOf: out2, encoding: .utf8) == "one\ntwo\nthree\nfour\n")
        two.close()

        // Three files: the ancestor decides what is a conflict.
        let three = CompareFilesWindowController.show(left: left, right: right, ancestor: base, display: false)
        let e3 = three.editor
        _ = e3.view
        let doc = try #require(e3.document)
        #expect(doc.chunks.map(\.kind) == [.unchanged, .theirsOnly, .unchanged, .conflict])
        #expect(!e3.pairControl.isHidden && e3.choiceControl.isEnabled(forSegment: 4))
        // The first undecided hunk is selected: the conflict.
        #expect(e3.currentHunk == 1 && e3.hunkLabel.stringValue == "Change 2 of 2 (conflict)")
        #expect(throws: (any Error).self) { try e3.save(to: folder.appendingPathComponent("refused.txt")) }
        e3.choose(.ours)
        #expect(e3.resultText == "one\nTWO\nthree\nfour\n")
        e3.choose(.base)
        #expect(e3.resultText == "one\nTWO\nthree\n4\n")
        let out3 = folder.appendingPathComponent("out3.txt")
        try e3.save(to: out3)
        #expect(try String(contentsOf: out3, encoding: .utf8) == "one\nTWO\nthree\n4\n")
        e3.setPair(.baseRight)
        #expect(e3.comparison.leftView.string.contains("4\n") && e3.comparison.rightView.string.contains("five"))
        three.close()
    }

    @Test func authorsColumnAndShowLastChangeForLine() async throws {
        let s = try Sandbox("scm-ui-authors")
        defer { s.cleanUp() }
        try s.write("Sources/App/main.swift", "let a = 1\nlet b = 22\nlet c = 3\n")
        try s.git("add", "-A")
        try s.git("-c", "user.name=Grace Second", "-c", "user.email=grace@ycode.invalid", "commit", "-q", "-m", "Change b")
        let second = try s.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        let wc = try await s.window()
        let path = s.dir.appendingPathComponent("Sources/App/main.swift").path
        wc.open(path: path, line: nil)
        let e = wc.editor
        await waitFor("the change baselines") { await e.sourceChangesIdle() }
        let item = NSMenuItem(title: "Authors", action: #selector(WorkspaceWindowController.toggleAuthors(_:)), keyEquivalent: "")
        #expect(wc.validateEditorMenuItem(item) == true && item.state == .off)
        let thin = e.gutter.ruleThickness
        wc.toggleAuthors(nil)
        await waitFor("the blame read") { await e.authorsIdle() }
        #expect(e.showsAuthors && e.gutter.ruleThickness == thin + GutterView.authorsColumnWidth)
        _ = wc.validateEditorMenuItem(item)
        #expect(item.state == .on)
        #expect(e.authorBlocks.map(\.lines) == [1...1, 2...2, 3...3])
        #expect(e.authorBlocks.map(\.commit.author) == ["Ycode Test", "Grace Second", "Ycode Test"])
        #expect(e.gutter.authorsText(line: 2) == "Grace Second  Today")
        #expect(e.gutter.authorsToolTip(line: 2)?.hasPrefix(String(second.prefix(7)) + " \u{2014} Grace Second <grace@ycode.invalid>") == true)
        #expect(e.gutter.authorsToolTip(line: 2)?.hasSuffix("Change b") == true)

        // Unsaved edits: new lines are not committed yet.
        e.textView.string = "let a = 1\nlet new = 0\nlet b = 22\nlet c = 3\n"
        e.textView.didChangeText()
        e.recomputeSourceChanges()
        await waitFor("the change baselines") { await e.sourceChangesIdle() }
        await waitFor("the blame read") { await e.authorsIdle() }
        #expect(e.gutter.authorsText(line: 2) == "Not Committed Yet")
        #expect(e.gutter.authorsText(line: 3) == "Grace Second  Today")

        // Show Last Change for Line: the commit's history, selected.
        e.textView.setSelectedRange(NSRange(location: ("let a = 1\nlet new = 0\n" as NSString).length, length: 0))
        let line = e.currentLine, text = e.text
        #expect(await waitFor("Show Last Change") { await wc.sourceControl.showLastChange(path: path, line: line, contents: text) } == true)
        #expect(wc.sourceControl.history?.selectedCommit?.hash == second)
        #expect(await waitFor("Show Last Change") { await wc.sourceControl.showLastChange(path: path, line: 2, contents: text) } == false)

        wc.toggleAuthors(nil)
        #expect(!e.showsAuthors && e.authorBlocks.isEmpty && e.gutter.ruleThickness == thin)
    }
}
