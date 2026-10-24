import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Runs git in `dir` (test setup only; the repository is created here).
@discardableResult
private func git(_ dir: URL, _ args: String...) throws -> String {
    try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=Ycode Test", "-c", "user.email=test@ycode.invalid",
                                           "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args)
}

@MainActor
@Suite(.serialized) struct SourceControlTests {
    /// A fresh repository under .build-ide with a package, a tag, a second
    /// branch, a remote (never contacted), one modified and one new file.
    func makeRepo() throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/scm-repo")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "print(1)\n".write(to: dir.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "add", "-A")
        try git(dir, "commit", "-q", "-m", "Initial")
        try git(dir, "tag", "v1.0")
        try git(dir, "branch", "feature")
        try git(dir, "remote", "add", "origin", "https://example.invalid/app.git")
        try "print(2)\n".write(to: dir.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: dir.appendingPathComponent("Sources/App/New.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func repositoryReading() throws {
        let dir = try makeRepo()
        let repo = try #require(GitRepository(containing: dir))
        #expect(repo.root.path == dir.standardizedFileURL.resolvingSymlinksInPath().path || repo.root.lastPathComponent == "scm-repo")
        #expect(try repo.branches() == [.init(name: "feature", isCurrent: false), .init(name: "main", isCurrent: true)])
        #expect(try repo.tags().map(\.name) == ["v1.0"])
        #expect(try repo.remotes() == [.init(name: "origin", url: "https://example.invalid/app.git")])
        let status = try repo.status()
        #expect(status.values.sorted { $0.rawValue < $1.rawValue } == [.untracked, .modified])
        #expect(status.first { $0.key.hasSuffix("main.swift") }?.value == .modified)
        #expect(GitRepository(containing: URL(fileURLWithPath: "/")) == nil)
    }

    @Test func navigatorsBadgesAndCommit() async throws {
        _ = NSApplication.shared
        let dir = try makeRepo()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        await wc.sourceControl.idle()   // git is read in the background
        let repo = try #require(wc.repository)

        // Badges: main.swift M, New.swift ?, and their folders M.
        func find(_ items: [OutlineItem], _ title: String) -> OutlineItem? {
            for i in items {
                if i.title == title { return i }
                if let f = find(i.children, title) { return f }
            }
            return nil
        }
        let rows = wc.navigator.rows(0)
        // File extensions are hidden by default; letters are on files only
        // (reference-ui-5.md §5.1).
        #expect(find(rows, "main")?.badge == "M")
        #expect(find(rows, "New")?.badge == "?")
        #expect(find(rows, "Sources") != nil && find(rows, "Sources")?.badge == nil)
        #expect(find(rows, "Package") != nil && find(rows, "Package")?.badge == nil)
        wc.navigator.select(0)
        wc.navigator.view.layoutSubtreeIfNeeded()
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-navigator-badges.png")

        // Source Control navigator.
        wc.navigator.select(1)
        wc.sourceControl.setMode(.repositories)
        let scm = try #require(wc.navigator.rows(1).first)
        #expect(scm.children.map(\.title) == ["Branches", "Recents", "Tags", "Stashes", "Remotes"])
        #expect(scm.children[0].children.map(\.title) == ["feature", "main"])
        #expect(scm.children[0].children[1].detail == "(current)")
        #expect(scm.children[2].children.map(\.title) == ["v1.0"])
        #expect(scm.children[4].children.map(\.title) == ["origin"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "source-control-navigator.png")

        // Commit only main.swift.
        let sheet = try #require(await wc.presentCommitSheet())
        #expect(sheet.rows.count == 2)
        let newFile = try #require(sheet.rows.first { $0.path.hasSuffix("New.swift") })
        sheet.setSelected(false, path: newFile.path)
        sheet.messageView.string = "Change the output"
        let window = NSWindow(contentRect: sheet.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = sheet.view
        _ = try WindowSnapshotTests().render(sheet.view, to: "commit-sheet.png")
        let hash = try #require(await sheet.commit())
        #expect(hash.count == 40)
        #expect(try git(dir, "log", "--format=%s").split(separator: "\n") == ["Change the output", "Initial"])
        await wc.sourceControl.idle()
        let after = try repo.status()
        #expect(after.count == 1 && after.first?.value == .untracked)
        #expect(find(wc.navigator.rows(0), "main.swift")?.badge == nil)

        // An empty message is refused and nothing is committed.
        let empty = try #require(await wc.presentCommitSheet())
        #expect(await empty.commit() == nil && empty.lastError?.contains("empty commit message") == true)
    }
}
