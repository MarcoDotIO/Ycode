import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@discardableResult
private func git(_ dir: URL, _ args: String...) throws -> String {
    try GitRepository.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=Ycode Test", "-c", "user.email=test@ycode.invalid",
                                           "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args)
}

private func freshRepo(_ name: String) throws -> URL {
    let dir = ycodeDir.appendingPathComponent(".build-ide/\(name)")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
        .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    for f in ["main", "Gone", "Old", "Both"] {
        try "// \(f)\nlet \(f.lowercased()) = 1\n".write(to: dir.appendingPathComponent("Sources/App/\(f).swift"), atomically: true, encoding: .utf8)
    }
    try git(dir, "init", "-q", "-b", "main")
    try git(dir, "add", "-A")
    try git(dir, "commit", "-q", "-m", "Initial")
    return dir
}

/// Depth checks for specs/ide/source-control.md.
@MainActor
@Suite(.serialized) struct SourceControlDepthTests {
    @Test func porcelainBadgeMapping() throws {
        let dir = try freshRepo("scm-depth-status")
        let src = dir.appendingPathComponent("Sources/App")
        // Conflict on Both.swift: change it on two branches and merge.
        try git(dir, "checkout", "-q", "-b", "other")
        try "let both = 2\n".write(to: src.appendingPathComponent("Both.swift"), atomically: true, encoding: .utf8)
        try git(dir, "commit", "-q", "-am", "other")
        try git(dir, "checkout", "-q", "main")
        try "let both = 3\n".write(to: src.appendingPathComponent("Both.swift"), atomically: true, encoding: .utf8)
        try git(dir, "commit", "-q", "-am", "main")
        _ = try? git(dir, "merge", "-q", "other")
        // Staged new file, deletion, rename.
        try "let added = 1\n".write(to: src.appendingPathComponent("Added.swift"), atomically: true, encoding: .utf8)
        try git(dir, "add", "Sources/App/Added.swift")
        try git(dir, "rm", "-q", "Sources/App/Gone.swift")
        try git(dir, "mv", "Sources/App/Old.swift", "Sources/App/Renamed.swift")
        try "print(9)\n".write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "x\n".write(to: src.appendingPathComponent("Untracked.swift"), atomically: true, encoding: .utf8)

        let repo = try #require(GitRepository(containing: src))
        let status = try repo.status()
        func s(_ name: String) -> GitRepository.FileStatus? { status.first { $0.key.hasSuffix("/" + name) }?.value }
        #expect(s("Both.swift") == .conflicted)
        #expect(s("Added.swift") == .added)
        #expect(s("Gone.swift") == .deleted)
        #expect(s("Renamed.swift") == .renamed)
        #expect(s("Old.swift") == nil) // the original path is consumed, not listed
        #expect(s("main.swift") == .modified)
        #expect(s("Untracked.swift") == .untracked)
        #expect(GitRepository.FileStatus.conflicted.rawValue == "C" && GitRepository.FileStatus.renamed.rawValue == "R")
    }

    @Test func commitRefusalsAndSelectedFilesOnly() throws {
        let dir = try freshRepo("scm-depth-commit")
        let repo = try #require(GitRepository(containing: dir))
        let main = dir.appendingPathComponent("Sources/App/main.swift").path
        let other = dir.appendingPathComponent("Sources/App/Both.swift").path
        try "print(1)\n".write(toFile: main, atomically: true, encoding: .utf8)
        try "print(2)\n".write(toFile: other, atomically: true, encoding: .utf8)
        let head = try git(dir, "rev-parse", "HEAD")
        #expect(throws: GitRepository.GitError.self) { try repo.commit(files: [], message: "m") }
        #expect(throws: GitRepository.GitError.self) { try repo.commit(files: [main], message: "  \n") }
        #expect(throws: GitRepository.GitError.self) { try repo.commit(files: ["/tmp/elsewhere.swift"], message: "m") }
        #expect(try git(dir, "rev-parse", "HEAD") == head)
        try repo.commit(files: [main], message: "Only main")
        let status = try repo.status()
        #expect(status.count == 1 && status.keys.first?.hasSuffix("Both.swift") == true)
        #expect(try git(dir, "show", "--name-only", "--format=", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "Sources/App/main.swift")
    }

    @Test func navigatorRemoteBranchesAndRefreshAfterSave() async throws {
        _ = NSApplication.shared
        let dir = try freshRepo("scm-depth-nav")
        try git(dir, "remote", "add", "origin", "https://example.invalid/a.git")
        try git(dir, "remote", "set-url", "--add", "origin", "https://example.invalid/b.git")
        try git(dir, "update-ref", "refs/remotes/origin/main", "HEAD")
        try git(dir, "update-ref", "refs/remotes/origin/dev", "HEAD")
        try git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        let repo = try #require(GitRepository(containing: dir))
        #expect(try repo.remotes() == [.init(name: "origin", url: "https://example.invalid/a.git")])
        #expect(try repo.remoteBranches().map(\.name) == ["origin/dev", "origin/main"])

        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        await wc.sourceControl.idle()   // git is read in the background
        wc.sourceControl.setMode(.repositories)
        let root = try #require(wc.navigator.rows(1).first)
        #expect(root.title == "scm-depth-nav")
        #expect(root.children[4].title == "Remotes")
        #expect(root.children[4].children.first?.children.map(\.title) == ["dev", "main"])

        // Badges refresh after Save.
        let main = dir.appendingPathComponent("Sources/App/main.swift")
        wc.open(path: main.path, line: nil)
        func badge(_ items: [OutlineItem]) -> String?? {
            for i in items {
                if i.title == "main" { return .some(i.badge) }  // extensions hidden by default
                if let b = badge(i.children) { return b }
            }
            return nil
        }
        #expect(badge(wc.navigator.rows(0)) == .some(nil))
        wc.editor.textView.string = "print(42)\n"
        wc.editor.textView.didChangeText()
        wc.saveDocument(nil)
        await wc.sourceControl.idle()
        #expect(badge(wc.navigator.rows(0)) == .some("M"))
    }

    @Test func menuCommandsAndShortcuts() {
        let commit = CommandTable.command(titled: "Commit…")
        #expect(commit?.key == "c" && commit?.modifiers == [.command, .option] && commit?.action == "showCommitSheet:")
        #expect(CommandTable.command(titled: "Refresh File Status")?.action == "refreshFileStatus:")
        let review = CommandTable.command(titled: "Code Review")
        #expect(review?.key == Key.return && review?.modifiers == [.command, .option, .shift])
        #expect(CommandTable.command(titled: "Assistant")?.modifiers == [.command, .option, .control])
        let scm = CommandTable.command(titled: "Source Control")
        #expect(scm?.key == "2" && scm?.modifiers == [.command] && scm?.tag == 1)
    }
}
