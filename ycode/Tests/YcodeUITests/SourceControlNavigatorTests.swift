import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@discardableResult
private func git(_ dir: URL, _ args: String...) throws -> String {
    try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args)
}

/// A repository with a local identity (so the commit editor reads it from
/// git's configuration), two commits, a branch with `/`, a tag, one
/// modified file and one untracked file.
private func sampleRepo(_ name: String) throws -> URL {
    let dir = ycodeDir.appendingPathComponent(".build-ide/\(name)")
    try? FileManager.default.removeItem(at: dir)
    let src = dir.appendingPathComponent("Sources/App")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
        .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "let a = 1\nlet b = 2\nlet c = 3\n".write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    try git(dir, "init", "-q", "-b", "main")
    try git(dir, "config", "user.name", "Ada Tester")
    try git(dir, "config", "user.email", "ada@ycode.invalid")
    try git(dir, "add", "-A")
    try git(dir, "commit", "-q", "-m", "Initial")
    try "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n".write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    try git(dir, "commit", "-q", "-am", "Add d", "-m", "Body line.")
    try git(dir, "tag", "v1.0")
    try git(dir, "branch", "feature/observe")
    try git(dir, "checkout", "-q", "feature/observe")
    try git(dir, "checkout", "-q", "main")
    try "let a = 10\nlet b = 2\nlet c = 3\nlet d = 4\n".write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    try "struct New {}\n".write(to: src.appendingPathComponent("New.swift"), atomically: true, encoding: .utf8)
    return dir
}

private func find(_ items: [OutlineItem], _ title: String) -> OutlineItem? {
    for i in items {
        if i.title == title { return i }
        if let f = find(i.children, title) { return f }
    }
    return nil
}

/// reference-ui-4.md §1–§3: Source Control navigator, commit editor,
/// branch history, inspector sections and the Integrate menu.
@MainActor
@Suite(.serialized) struct SourceControlNavigatorTests {
    @Test func historyModel() throws {
        let dir = try sampleRepo("scm-nav-model")
        let repo = try #require(GitRepository(containing: dir))
        #expect(repo.currentBranch() == "main")
        #expect(repo.author() == .init(name: "Ada Tester", email: "ada@ycode.invalid"))
        let log = repo.log("main")
        #expect(log.map(\.subject) == ["Add d", "Initial"])
        #expect(log[0].body == "Body line." && log[0].message == "Add d\n\nBody line.")
        #expect(log[0].branches.contains("main") && log[0].branches.contains("feature/observe") && log[0].tags == ["v1.0"])
        #expect(log[0].shortHash.count == 7 && log[0].verification == "Commit unverified")
        #expect(repo.files(in: log[0].hash).map(\.status) == [.modified])
        #expect(repo.files(in: log[1].hash).map(\.path) == ["Package.swift", "Sources/App/main.swift"])
        #expect(repo.files(in: log[1].hash).allSatisfy { $0.status == .added })
        #expect(Set(repo.branches(containing: log[1].hash)) == ["main", "feature/observe"])
        #expect(repo.recentBranches() == ["feature/observe"])
        #expect(repo.remote(of: "main") == nil && repo.upstream(of: "main") == nil)
        let branchRows = SourceControlInspector.branchRows(repository: repo, branch: "main")
        #expect(branchRows.map(\.1) == ["main", "No Remote", "No Remote Branch"])
        let commitRows = SourceControlInspector.commitRows(repository: repo, commit: log[0])
        #expect(commitRows.map(\.0) == ["Identifier", "Date", "Author", "Verification", "Branches", "Commit Message", "Files"])
        #expect(commitRows[0].1 == log[0].hash && commitRows[3].1 == "Commit unverified")
        #expect(commitRows[6].1 == "M  Sources/App/main.swift")

        // Changes and diffs.
        let changes = try repo.changes()
        #expect(changes.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["New.swift", "main.swift"])
        #expect(changes.allSatisfy { $0.isUnstaged && !$0.isStaged })
        let main = changes[1].path, new = changes[0].path
        #expect(repo.diff(of: main, scope: .all).contains("-let a = 1\n+let a = 10"))
        #expect(repo.diff(of: main, scope: .staged).isEmpty)
        #expect(repo.diff(of: new, scope: .all) == "@@ -0,0 +1,1 @@\n+struct New {}")
        try repo.stage([main])
        #expect(try repo.changes().first { $0.path == main }?.isStaged == true)
        #expect(repo.diff(of: main, scope: .staged).contains("+let a = 10"))
        #expect(repo.diff(of: main, scope: .unstaged).isEmpty)
        try repo.unstage([main])
        #expect(try repo.changes().first { $0.path == main }?.isStaged == false)
        try repo.stash(message: "parked")
        #expect(try repo.changes().isEmpty)
        #expect(repo.stashes() == ["stash@{0}: On main: parked"])
        _ = try git(dir, "stash", "pop", "-q")
        #expect(try repo.changes().count == 2)
    }

    @Test func datesScopesAndDiffLines() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        #expect(GitDates.relativeDay(now.addingTimeInterval(-3600), now: now, calendar: cal) == "Today")
        #expect(GitDates.relativeDay(now.addingTimeInterval(-86_400), now: now, calendar: cal) == "Yesterday")
        #expect(GitDates.relativeDay(now.addingTimeInterval(-3 * 86_400), now: now, calendar: cal) == "Oct 16, 2026")
        let late = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 46))!
        #expect(GitDates.detail(late, calendar: cal) == "Oct 18, 2026 at 11:46 PM")
        #expect(HistoryScope.titles == ["All", "Last 24 Hours", "Last 7 Days", "Last 30 Days"])
        func c(_ s: String, _ ago: Double) -> GitRepository.Commit {
            .init(hash: String(repeating: "a", count: 40), authorName: "A", authorEmail: "", date: now.addingTimeInterval(-ago * 86_400),
                  subject: s, body: "", branches: [], tags: [], signature: "N")
        }
        let all = [c("one", 0.5), c("two", 3), c("three", 20), c("four", 90)]
        #expect(HistoryScope.day.apply(all, filter: "", now: now).map(\.subject) == ["one"])
        #expect(HistoryScope.week.apply(all, filter: "", now: now).map(\.subject) == ["one", "two"])
        #expect(HistoryScope.month.apply(all, filter: "", now: now).count == 3)
        #expect(HistoryScope.all.apply(all, filter: "THR", now: now).map(\.subject) == ["three"])

        let lines = UnifiedDiffLines.parse("@@ -1,3 +1,3 @@\n-let a = 1\n+let a = 10\n let b = 2\n")
        #expect(lines.map(\.kind) == [.hunk, .removed, .added, .context])
        #expect(lines[1].old == 1 && lines[2].new == 1 && lines[3].old == 2 && lines[3].new == 2)
    }

    @Test func navigatorTrees() throws {
        let root = URL(fileURLWithPath: "/r")
        let changes = [GitRepository.Change(path: "/r/A.swift", index: " ", worktree: "M", status: .modified),
                       GitRepository.Change(path: "/r/B.swift", index: "?", worktree: "?", status: .untracked)]
        let tree = SourceControlNavigatorModel.changesTree(repository: "repo", branch: "main", changes: changes, root: root)
        #expect(tree[0].title == "repo" && tree[0].detail == "main")
        let group = tree[0].children[0]
        #expect(group.title == "Uncommitted Changes" && group.detail == "2")
        #expect(group.children.map(\.title) == ["A", "B"] && group.children.map(\.badge) == ["M", "?"])
        #expect(group.children[0].scmKey == "change:/r/A.swift")

        let repos = SourceControlNavigatorModel.repositoriesTree(
            repository: "repo", branch: "feature/observe",
            branches: [.init(name: "main", isCurrent: false), .init(name: "feature/observe", isCurrent: true), .init(name: "feature/x", isCurrent: false)],
            recents: ["main"], tags: [.init(name: "v1.0", isCurrent: false)], stashes: ["stash@{0}: On main: parked"],
            remotes: [.init(name: "origin", url: "u")], remoteBranches: [.init(name: "origin/release/1", isCurrent: false)])
        let groups = repos[0].children
        #expect(groups.map(\.title) == ["Branches", "Recents", "Tags", "Stashes", "Remotes"])
        #expect(groups[0].children.map(\.title) == ["feature", "main"])
        #expect(groups[0].children[0].children.map(\.title) == ["observe", "x"])
        #expect(groups[0].children[0].children[0].detail == "(current)" && groups[0].children[0].children[0].scmKey == "branch:feature/observe")
        #expect(groups[3].children.first?.title == "On main: parked" && groups[3].children.first?.scmKey == "stash:stash@{0}")
        #expect(groups[4].children[0].children[0].title == "release")
        #expect(groups[4].children[0].children[0].children[0].scmKey == "remoteBranch:origin/release/1")
    }

    @Test func commitEditor() async throws {
        _ = NSApplication.shared
        let dir = try sampleRepo("scm-nav-commit")
        let repo = try #require(GitRepository(containing: dir))
        let c = CommitEditorController(repository: repo)
        c.loadView()
        await c.idle()   // changes and diffs are read in the background
        #expect(c.authorLabel.stringValue.contains("Ada Tester") && c.authorLabel.stringValue.contains("ada@ycode.invalid"))
        #expect(c.amendLabel.stringValue.hasPrefix("Amend \"") && c.amendLabel.stringValue.count == "Amend \"1234567\"".count)
        #expect(c.placeholderLabel.stringValue == "Commit message (required)" && !c.placeholderLabel.isHidden)
        #expect(CommitEditorController.scopeTitles == ["All Changes", "Unstaged", "Staged"])
        #expect(c.cards.count == 2 && !c.commitButton.isEnabled && c.stageAllButton.isEnabled)
        let newCard = try #require(c.cards.first { $0.titleLabel.stringValue == "New.swift" })
        #expect(newCard.lines.allSatisfy { $0.kind == .added || $0.kind == .hunk } && newCard.statusLabel.stringValue.contains("?"))
        newCard.setCollapsed(true)
        #expect(newCard.isCollapsed)
        c.setScope(.staged)
        await c.idle()
        #expect(c.cards.isEmpty)
        c.stageAll()
        await c.idle()
        #expect(c.cards.count == 2 && !c.stageAllButton.isEnabled)
        c.setScope(.all)
        // Discard a tracked, staged file: back to HEAD in index and working copy.
        c.discard(dir.appendingPathComponent("Sources/App/main.swift").path)
        await c.idle()
        #expect(c.cards.map(\.titleLabel.stringValue) == ["New.swift"])
        #expect(try String(contentsOf: dir.appendingPathComponent("Sources/App/main.swift"), encoding: .utf8).hasPrefix("let a = 1\n"))
        c.messageView.string = "  "
        c.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(!c.commitButton.isEnabled)
        c.messageView.string = "Ten"
        c.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(c.commitButton.isEnabled && c.placeholderLabel.isHidden)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = c.view
        c.view.layoutSubtreeIfNeeded()
        Self.shoot(c.view, "commit-editor.png")
        let hash = try #require(await c.commit())
        await c.idle()
        #expect(hash.count == 40 && c.cards.isEmpty)
        #expect(try git(dir, "log", "--format=%s", "-1").trimmingCharacters(in: .newlines) == "Ten")
        // Amend rewrites HEAD.
        try "let z = 0\n".write(to: dir.appendingPathComponent("Sources/App/Z.swift"), atomically: true, encoding: .utf8)
        c.reload()
        c.amendSwitch.state = .on
        c.messageView.string = "Ten, amended"
        try repo.stageAll()
        c.reload()
        await c.idle()
        #expect(await c.commit() != nil)
        #expect(try git(dir, "log", "--format=%s").split(separator: "\n") == ["Ten, amended", "Add d", "Initial"])
    }

    @Test func branchHistoryAndDetail() async throws {
        _ = NSApplication.shared
        let dir = try sampleRepo("scm-nav-history")
        let repo = try #require(GitRepository(containing: dir))
        let h = BranchHistoryController(repository: repo, ref: "refs/heads/main")
        var selected: [GitRepository.Commit?] = []
        h.onSelectCommit = { selected.append($0) }
        h.loadView()
        await h.idle()   // the log is read in the background
        #expect(h.shown.count == 2 && h.table.numberOfRows == 2)
        let row = h.rowTexts(0)
        #expect(row.author == "Ada Tester" && row.subject == "Add d" && row.hash.count == 7 && row.day == "Today")
        #expect(row.badges.contains("v1.0") && row.badges.contains("main"))
        #expect(h.detailPane.isHidden)
        h.select(h.shown[0])
        #expect(!h.detailPane.isHidden && h.detailHash.stringValue.contains(h.shown[0].shortHash))
        #expect(h.pathBar.stringValue == "Commit › scm-nav-history › No Selection")
        #expect(h.detailMessage.stringValue == "Add d\n\nBody line.")
        #expect(selected.last??.subject == "Add d")
        h.setFilter("initial")
        #expect(h.shown.map(\.subject) == ["Initial"] && h.selectedCommit == nil && h.detailPane.isHidden)
        h.setFilter("")
        h.setScope(.day)
        #expect(h.shown.count == 2)
    }

    @Test func integrateMenu() {
        let titles: [String] = {
            guard case let (_, items)? = CommandTable.menus.first(where: { $0.0 == "Integrate" }) else { return [] }
            return items.compactMap { if case let .command(c) = $0 { c.title } else { nil } }
        }()
        // reference-ui-5.md §2.11: the generic (no-workspace) titles.
        #expect(titles == ["Commit…", "Push…", "Pull…", "Fetch Changes", "Refresh File Status",
                           "Stage All Changes", "Stage Selected Files", "Unstage All Changes", "Unstage Selected Files",
                           "Mark as Resolved", "Add", "Cherry-Pick…", "Stash Changes…", "Create Pull Request…",
                           "Discard All Changes…", "Discard Changes in Selected Files…", "Clone…", "New Git Repository…",
                           "Create Workflow…", "Manage Workflows…"])
        let pull = CommandTable.command(titled: "Pull…")
        #expect(pull?.key == "x" && pull?.modifiers == [.command, .option])
        #expect(CommandTable.command(titled: "Create Workflow…")?.action.hasPrefix("ycodeUnavailable") == true)

        var s = IntegrateMenuState()
        #expect(s.isEnabled("scmClone:") && s.isEnabled("scmNewRepository:") && !s.isEnabled("showCommitSheet:") && !s.isEnabled("scmPush:"))
        s.hasRepository = true
        #expect(!s.isEnabled("scmNewRepository:") && !s.isEnabled("scmStageAll:") && !s.isEnabled("scmPull:") && !s.isEnabled("scmCherryPick:"))
        s.hasUnstaged = true
        s.selectedStatus = .untracked
        #expect(s.isEnabled("scmStageAll:") && !s.isEnabled("scmUnstageAll:") && s.isEnabled("scmAddSelected:") && !s.isEnabled("scmStageSelected:"))
        #expect(s.isEnabled("showCommitSheet:") && s.isEnabled("scmStash:") && s.isEnabled("scmDiscardAll:") && !s.isEnabled("scmMarkResolved:"))
        s.selectedStatus = .conflicted
        s.hasRemote = true
        s.selectedCommit = "abc"
        #expect(s.isEnabled("scmMarkResolved:") && s.isEnabled("scmPush:") && s.isEnabled("scmFetch:") && s.isEnabled("scmCherryPick:"))
        for a in IntegrateMenuState.actions { #expect(WorkspaceWindowController.instancesRespond(to: Selector(a)), "\(a)") }
    }

    @Test func windowIntegration() async throws {
        _ = NSApplication.shared
        let dir = try sampleRepo("scm-nav-window")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        await wc.sourceControl.idle()   // git is read in the background
        // §1: project navigator letters.
        // Extensions are hidden by default (reference-ui-5.md §5.1).
        #expect(find(wc.navigator.rows(0), "main")?.badge == "M" && find(wc.navigator.rows(0), "New")?.badge == "?")
        wc.navigator.select(1)
        #expect(!wc.navigator.sourceControlMode.isHidden && wc.navigator.sourceControlMode.label(forSegment: 1) == "Repositories")
        let group = try #require(find(wc.navigator.rows(1), "Uncommitted Changes"))
        #expect(group.detail == "2")
        let menu = NSMenuItem(title: "Stage All Changes", action: Selector(("scmStageAll:")), keyEquivalent: "")
        #expect(wc.validateMenuItem(menu))
        let unstage = NSMenuItem(title: "Unstage All Changes", action: Selector(("scmUnstageAll:")), keyEquivalent: "")
        #expect(!wc.validateMenuItem(unstage))

        // Selecting a change opens the commit editor over the editor area.
        let key = try #require(group.children.first?.scmKey)
        wc.sourceControl.handleRow(key)
        await wc.sourceControl.idle()
        let editor = try #require(wc.sourceControl.commitEditor)
        #expect(editor.view.superview === wc.editorArea.view && editor.cards.count == 2)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        Self.shoot(wc.window!.contentView!.superview!, "scm-changes-window.png")

        // Stage All through the menu action updates enablement.
        wc.scmStageAll(nil)
        await wc.sourceControl.idle()
        #expect(wc.validateMenuItem(unstage) && !wc.validateMenuItem(menu))

        // Repositories ▸ branch: history and the inspector's Branch section.
        wc.sourceControl.setMode(.repositories)
        #expect(find(wc.navigator.rows(1), "feature")?.children.first?.title == "observe")
        wc.sourceControl.handleRow("branch:main")
        await wc.sourceControl.idle()
        let h = try #require(wc.sourceControl.history)
        #expect(wc.sourceControl.commitEditor == nil)
        #expect(wc.sourceControl.inspectorSections?.map(\.0) == ["Branch"])
        #expect(wc.inspector.tabNames.count == CommandTable.inspectors.count + 1)
        h.select(h.shown[0])
        await wc.sourceControl.idle()
        #expect(wc.sourceControl.inspectorSections?.map(\.0) == ["Branch", "Commit"])
        let pick = NSMenuItem(title: "Cherry-Pick…", action: Selector(("scmCherryPick:")), keyEquivalent: "")
        #expect(wc.validateMenuItem(pick))
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        Self.shoot(wc.window!.contentView!.superview!, "scm-history-window.png")

        // Opening a file hides the overlay and the inspector tab.
        wc.openFromNavigator(path: dir.appendingPathComponent("Package.swift").path, line: nil)
        #expect(wc.sourceControl.editorOverlay == nil && wc.inspector.tabNames.count == CommandTable.inspectors.count)
    }

    /// Off-screen renders for review (scratch output; failures ignored).
    static func shoot(_ view: NSView, _ name: String) {
        let dir = ycodeDir.appendingPathComponent(".build-ide/shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
}
