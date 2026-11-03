import Foundation
import Testing
@testable import YcodeIDECore

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
}
