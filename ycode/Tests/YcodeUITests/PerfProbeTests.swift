import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

/// Responsiveness probes (opt-in: `YCODE_PERF=1`). They print timings;
/// they assert nothing about them. A background thread pings the main
/// queue every millisecond and records how long each ping waited, so the
/// numbers are main-thread blocking as a user would feel it.
///
/// 1. Launch to first window interactive: main menu, workspace model,
///    window, display, until the main queue answers within 5 ms.
/// 2. The same window on a git repository of a few thousand files with
///    local changes (status letters, Source Control navigator).
/// 3. Opening every menu of the menu bar (validation of all items) while
///    a build of that workspace runs.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YCODE_PERF"] == "1"), .serialized)
struct PerfProbeTests {
    /// Main-queue latency meter.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var samples: [Double] = []
        init() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let live = running; lock.unlock()
                    guard live else { return }
                    let start = DispatchTime.now().uptimeNanoseconds
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { done.signal() }
                    done.wait()
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    lock.lock(); samples.append(ms); lock.unlock()
                    usleep(1000)
                }
            }
        }
        func stop() -> (max: Double, blockedOver16: Double, stallsOver50: Int) {
            lock.lock(); running = false; let s = samples; lock.unlock()
            return (s.max() ?? 0, s.filter { $0 > 16 }.reduce(0, +), s.filter { $0 > 50 }.count)
        }
    }

    static func git(_ dir: URL, _ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "-c", "user.name=Perf", "-c", "user.email=perf@ycode.invalid"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// A package with `count` sources in a git repository; 20 modified and
    /// 20 untracked files.
    static func repo(count: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-perf-\(count)")
        let marker = dir.appendingPathComponent(".perf-ready")
        if FileManager.default.fileExists(atPath: marker.path) { return dir }
        try? FileManager.default.removeItem(at: dir)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Perf\", targets: [.executableTarget(name: \"Perf\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for i in 0..<count {
            let sub = dir.appendingPathComponent("Sources/Perf/Group\(i / 100)")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try "struct Type\(i) { var value = \(i) }\n".write(to: sub.appendingPathComponent("Type\(i).swift"), atomically: true, encoding: .utf8)
        }
        try "print(\"perf\")\n".write(to: dir.appendingPathComponent("Sources/Perf/main.swift"), atomically: true, encoding: .utf8)
        git(dir, "init", "-q", "-b", "main")
        git(dir, "add", "-A")
        git(dir, "commit", "-qm", "Initial")
        for i in 0..<20 {
            try "struct Type\(i) { var value = \(i + 1) }\n".write(to: dir.appendingPathComponent("Sources/Perf/Group0/Type\(i).swift"), atomically: true, encoding: .utf8)
            try "struct New\(i) {}\n".write(to: dir.appendingPathComponent("Sources/Perf/New\(i).swift"), atomically: true, encoding: .utf8)
        }
        fm.createFile(atPath: marker.path, contents: nil)
        try "/.perf-ready\n.build\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Waits until the main queue answers within 5 ms (queued work done).
    static func settle(timeout: Double = 30) async {
        let end = Date().addingTimeInterval(timeout)
        var quiet = 0
        while Date() < end, quiet < 5 {
            let start = DispatchTime.now().uptimeNanoseconds
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
            quiet = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 < 5 ? quiet + 1 : 0
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func report(_ name: String, _ values: [String: Double]) {
        let text = values.keys.sorted().map { "\($0)=\(String(format: "%.1f", values[$0]!))" }.joined(separator: " ")
        print("YCODE-PERF \(name) \(text)")
    }

    func openWindow(_ dir: URL) async throws -> (WorkspaceWindowController, [String: Double]) {
        _ = NSApplication.shared
        // YCODE_MAIN_THREAD_WATCHDOG=<ms> also logs each stall with its stack.
        MainThreadWatchdog.startIfRequested()
        let meter = Meter()
        let t0 = Date()
        NSApp.mainMenu = MainMenu.make()
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        wc.showWindow(nil)
        wc.window?.displayIfNeeded()
        let shown = Date().timeIntervalSince(t0) * 1000
        await Self.settle()
        let interactive = Date().timeIntervalSince(t0) * 1000
        let m = meter.stop()
        return (wc, ["shown_ms": shown, "interactive_ms": interactive, "max_main_block_ms": m.max, "main_blocked_ms": m.blockedOver16,
                     "stalls_over_50ms": Double(m.stallsOver50)])
    }

    @Test func launchToFirstWindowInteractive() async throws {
        let dir = try Self.repo(count: 50)
        let (wc, v) = try await openWindow(dir)
        Self.report("launch-small-git", v)
        wc.close()
    }

    @Test func openGitWorkspaceOfThousandsOfFiles() async throws {
        let dir = try Self.repo(count: 4000)
        let (wc, v) = try await openWindow(dir)
        Self.report("open-4000-file-git", v)
        wc.close()
    }

    @Test func openMenusWhileBuilding() async throws {
        let dir = try Self.repo(count: 4000)
        let (wc, _) = try await openWindow(dir)
        let build = Task { await wc.session.build() }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let meter = Meter()
        var perMenu: [Double] = []
        for _ in 0..<3 {
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu else { continue }
                let t = Date()
                menu.delegate?.menuNeedsUpdate?(menu)
                func validate(_ m: NSMenu) {
                    for item in m.items {
                        if item.action != nil { _ = wc.validateMenuItem(item) }
                        if let s = item.submenu { validate(s) }
                    }
                }
                validate(menu)
                perMenu.append(Date().timeIntervalSince(t) * 1000)
                // The user's next click: let the run loop turn.
                await Task.yield()
            }
        }
        let m = meter.stop()
        wc.session.stop()
        _ = await build.value
        let integrate = (NSApp.mainMenu?.items ?? []).firstIndex { $0.title == "Integrate" }
        let menus = (NSApp.mainMenu?.items ?? []).filter { $0.submenu != nil }.count
        let integrateTimes = integrate.map { i in stride(from: i, to: perMenu.count, by: menus).map { perMenu[$0] } } ?? []
        Self.report("menus-while-building", ["menu_open_avg_ms": perMenu.reduce(0, +) / Double(max(1, perMenu.count)),
                                             "menu_open_max_ms": perMenu.max() ?? 0,
                                             "integrate_menu_avg_ms": integrateTimes.reduce(0, +) / Double(max(1, integrateTimes.count)),
                                             "max_main_block_ms": m.max, "main_blocked_ms": m.blockedOver16])
        wc.close()
    }
}
