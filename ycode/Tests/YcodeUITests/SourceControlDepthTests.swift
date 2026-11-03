import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
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
}
