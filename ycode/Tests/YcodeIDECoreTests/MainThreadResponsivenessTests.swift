import Foundation
import Testing
import YcodeSubprocess
@testable import YcodeIDECore

/// The main thread never waits for git or other tools in the paths a user
/// hits all the time: opening a workspace window, opening menus (menu
/// validation), refreshing source-control status, opening and editing a
/// file. Debug builds record every blocking call made on the main thread
/// (`MainThreadGuard`); these tests fail on any.
@MainActor
@Suite struct MainThreadResponsivenessTests {
    static func git(_ dir: URL, _ args: String...) throws {
        let r = try Subprocess.run("/usr/bin/git", ["-C", dir.path, "-c", "user.name=Ada", "-c", "user.email=ada@ycode.invalid"] + args)
        guard r.status == 0 else { throw GitRepository.GitError(description: r.stderrText) }
    }

    /// A package in a git repository with a remote, a branch, local changes.
    func repository(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-mainthread-\(name)-\(UUID().uuidString)")
        let sources = dir.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "let a = 1\nprint(a)\n".write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try Self.git(dir, "init", "-q", "-b", "main")
        try Self.git(dir, "add", "-A")
        try Self.git(dir, "commit", "-qm", "Initial")
        try Self.git(dir, "branch", "feature")
        try Self.git(dir, "remote", "add", "origin", "https://example.invalid/app.git")
        try "let a = 2\nprint(a)\n".write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "let b = 1\n".write(to: sources.appendingPathComponent("New.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The guard itself: a git call on the main thread is recorded (debug
    /// builds), with the caller's stack.
    @Test func guardRecordsGitOnTheMainThread() throws {
        let dir = try repository("guard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = MainThreadGuard.violations { _ = GitRepository(containing: dir) }
        // On Linux, swift-testing runs @MainActor tests on a thread that
        // Foundation does not report as the main thread
        // (`Thread.isMainThread` is false there), so the guard, which
        // checks that, records nothing.
        #if DEBUG && canImport(Darwin)
        try #require(v.count == 1)
        #expect(v[0].operation.contains("rev-parse"))
        #expect(v[0].stack.contains { $0.contains("GitRepository") })
        #endif
    }

    /// Changes outside Ycode reach the source-control refresh through
    /// FSEvents; git's object store, lock files and build output do not.
    @Test func fileSystemWatcherReportsChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-fsw-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Seen { var paths: [String] = [] }
        let seen = Seen()
        let w = FileSystemWatcher { seen.paths += $0 }
        w.start(path: dir.path, latency: 0.05)
        defer { w.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        try "x".write(to: dir.appendingPathComponent("main.swift"), atomically: false, encoding: .utf8)
        // Generous: other suites may keep the main queue busy for seconds.
        let deadline = Date().addingTimeInterval(60)
        while !seen.paths.contains(where: { $0.hasSuffix("main.swift") }) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(seen.paths.contains { $0.hasSuffix("main.swift") })
        #expect(FileSystemWatcher.affectsSourceControl("/r/Sources/main.swift") && FileSystemWatcher.affectsSourceControl("/r/.git/index"))
        #expect(FileSystemWatcher.affectsSourceControl("/r/.git/HEAD") && FileSystemWatcher.affectsSourceControl("/r/.git/refs/heads/main"))
        #expect(!FileSystemWatcher.affectsSourceControl("/r/.git/objects/ab/cdef") && !FileSystemWatcher.affectsSourceControl("/r/.git/index.lock"))
        #expect(!FileSystemWatcher.affectsSourceControl("/r/.build/debug/x.o") && !FileSystemWatcher.affectsSourceControl("/r/DerivedData/a"))
    }
}
