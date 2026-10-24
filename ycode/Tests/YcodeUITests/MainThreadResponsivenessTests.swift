import AppKit
import Foundation
import Testing
import YcodeSubprocess
@testable import YcodeUI

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

    func validateAll(_ menu: NSMenu, in wc: WorkspaceWindowController) {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.action != nil { _ = wc.validateMenuItem(item) }
            if let s = item.submenu { validateAll(s, in: wc) }
        }
    }

    /// The guard itself: a git call on the main thread is recorded (debug
    /// builds), with the caller's stack.
    @Test func guardRecordsGitOnTheMainThread() throws {
        let dir = try repository("guard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = MainThreadGuard.violations { _ = GitRepository(containing: dir) }
        #if DEBUG
        #expect(v.count == 1 && v[0].operation.contains("rev-parse"))
        #expect(v[0].stack.contains { $0.contains("GitRepository") })
        #endif
    }

    @Test func windowMenusAndEditingRunNoToolsOnTheMainThread() async throws {
        _ = NSApplication.shared
        let dir = try repository("window")
        defer { try? FileManager.default.removeItem(at: dir) }
        let menu = MainMenu.make()
        var opened: WorkspaceWindowController?
        // A new window: git status and the rest are read in the background.
        var v = try MainThreadGuard.violations {
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                               startLanguageService: false, openFirstFile: false)
            wc.applyDefaultLayout()
            for item in menu.items { if let s = item.submenu { validateAll(s, in: wc) } }
            opened = wc
        }
        let wc = try #require(opened)
        await wc.sourceControl.idle()
        // The state the menus read came from that background read.
        let stageAll = NSMenuItem(title: "Stage All Changes", action: Selector(("scmStageAll:")), keyEquivalent: "")
        #expect(wc.validateMenuItem(stageAll) && wc.sourceControl.hasRemote)
        let main = dir.appendingPathComponent("Sources/App/main.swift")
        // Menus with a repository known, Refresh File Status, opening and
        // editing a file, the change bars, the branch menu, Integrate
        // commands, the History inspector, both navigator modes.
        v += MainThreadGuard.violations {
            for item in menu.items { if let s = item.submenu { validateAll(s, in: wc) } }
            wc.refreshFileStatus(nil)
            wc.open(path: main.path, line: nil)
            wc.editor.textView.insertText("// edit\n", replacementRange: NSRange(location: 0, length: 0))
            wc.editor.recomputeSourceChanges()
            _ = wc.debugArea.branchMenu()
            wc.scmStageAll(nil)
            wc.inspector.select(1)
            wc.sourceControl.setMode(.repositories)
            wc.sourceControl.setMode(.changes)
            wc.saveDocument(nil)
        }
        await wc.sourceControl.idle()
        await wc.editor.sourceChangesIdle()
        await wc.inspector.historyIdle()
        #expect(v.isEmpty, "blocking calls on the main thread: \(v.map(\.description))")
        #expect(wc.sourceControl.snapshot.changes.allSatisfy { $0.isStaged })
        #expect(wc.inspector.historyRows.map(\.subject) == ["Initial"])
    }

    /// The debug-build watchdog reports a main-thread stall, and captures
    /// the main thread's stack while it is blocked. (Other suites may block
    /// the main thread for long stretches during a full run, so the stack
    /// is checked by sampling during this test's own block.)
    @Test func watchdogReportsAStallWithTheMainThreadsStack() async throws {
        let w = MainThreadWatchdog(thresholdMilliseconds: 50) { _ in }
        w.start()
        defer { w.stop() }
        // Let the watchdog's thread start pinging before the block.
        try await Task.sleep(nanoseconds: 100_000_000)
        let stack = Self.blockMainThreadAndSample(w)
        #expect(stack.contains { $0.contains("sleep") || $0.contains("semwait") }, "\(stack)")
        for _ in 0..<40 where !w.recorded.contains(where: { $0.milliseconds >= 200 }) { try await Task.sleep(nanoseconds: 50_000_000) }
        let stall = try #require(w.recorded.first { $0.milliseconds >= 200 }, "\(w.recorded.map(\.milliseconds))")
        #expect(!stall.samples.isEmpty)
        #expect(stall.description.hasPrefix("Ycode main-thread watchdog: main thread blocked for "))
    }

    /// Blocks the main thread for 300 ms; another thread samples its stack
    /// 100 ms in.
    static func blockMainThreadAndSample(_ w: MainThreadWatchdog) -> [String] {
        final class Box: @unchecked Sendable { var stack: [String] = [] }
        let box = Box()
        let sampled = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            usleep(100_000)
            box.stack = w.sampleMainThread()
            sampled.signal()
        }
        usleep(300_000)   // the main thread is blocked
        sampled.wait()
        return box.stack
    }

    /// `YCODE_MAIN_THREAD_WATCHDOG=<ms> swift test` watches the rest of the
    /// test run and logs its main-thread stalls (diagnosis; off by default).
    @Test func watchdogForTheTestRunWhenRequested() {
        MainThreadWatchdog.startIfRequested()
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

    /// The watchdog starts only when asked for.
    @Test func watchdogStartsOnlyWhenRequested() {
        #expect(MainThreadWatchdog.startIfRequested(environment: [:]) == nil)
        #expect(MainThreadWatchdog.startIfRequested(environment: ["YCODE_MAIN_THREAD_WATCHDOG": "off"]) == nil)
    }
}
