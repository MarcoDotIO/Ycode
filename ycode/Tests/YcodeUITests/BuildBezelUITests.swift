import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeIDEShell
@testable import YcodeUI

/// The result bezel (`specs/ide/build-notifications.md`): Product ▸ Build
/// of a real package (SwiftPM) through the window's build action, once
/// clean and once with a deliberate error. The window is never put on
/// screen: the test routes as if it were in front and photographs its
/// content view offscreen.
private let hudYcodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct BuildBezelUITests {
    static let out = hudYcodeDir.appendingPathComponent(".build-ide/snapshots")

    func package(_ dir: URL, error: Bool) throws {
        let src = dir.appendingPathComponent("Sources/Hud")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Hud\", targets: [.executableTarget(name: \"Hud\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try (error ? "let n: Int = \"one\"\nprint(n)\n" : "print(\"Hello, bezel\")\n")
            .write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    }

    func snapshot(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try data.write(to: Self.out.appendingPathComponent(name))
    }

    func waitForBuild(_ s: WorkspaceSession) async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        for _ in 0..<2400 where s.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Waits (up to 20 s: the main actor is shared with the whole suite)
    /// for the bezel to be removed.
    func waitGone(_ wc: WorkspaceWindowController) async {
        for _ in 0..<200 where wc.buildBezelView != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    func withPrefs(_ body: () async throws -> Void) async throws {
        let t = TestDefaults("build-hud")
        let old = Preferences.shared
        Preferences.shared = Preferences(defaults: t.defaults)
        defer {
            Preferences.shared = old
            t.remove()
        }
        try await body()
    }

    @Test func buildShowsTheResultBezelThenItGoes() async throws {
        try await withPrefs {
            _ = NSApplication.shared
            let dir = hudYcodeDir.appendingPathComponent(".build-ide/build-hud/Hud-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try package(dir, error: false)
            let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
            session.engine = PackageBuildEngine()
            let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
            let window = try #require(wc.window)
            window.appearance = NSAppearance(named: .aqua)
            wc.applyDefaultLayout()
            wc.notificationWindowStateOverride = .frontmost
            wc.bezelReduceMotionOverride = false
            let content = try #require(window.contentView)

            // A clean build: "Build Succeeded" in the bezel, centred.
            wc.buildProduct(nil)
            await waitForBuild(session)
            #expect(session.activity == .finished("Build Succeeded"))
            #expect(wc.buildBezelTitle == "Build Succeeded")
            let v = try #require(wc.buildBezelView)
            #expect(v.superview === content && v.frame.size == NSSize(width: 200, height: 200))
            #expect(abs(v.frame.midX - content.bounds.midX) <= 1 && abs(v.frame.midY - content.bounds.midY) <= 1)
            #expect(v.hitTest(NSPoint(x: v.frame.midX, y: v.frame.midY)) == nil)
            try snapshot(content, "build-hud-mac-succeeded.png")
            // It fades and is removed (after 1.6 + 0.35 s when idle).
            await waitGone(wc)
            #expect(wc.buildBezelTitle == nil && wc.buildBezelView == nil)

            // A deliberate error: "Build Failed", in dark mode.
            try package(dir, error: true)
            window.appearance = NSAppearance(named: .darkAqua)
            wc.buildProduct(nil)
            await waitForBuild(session)
            #expect(session.activity == .finished("Build Failed"))
            #expect(session.displayedIssues.contains { $0.severity == .error })
            #expect(wc.buildBezelTitle == "Build Failed")
            #expect(wc.buildBezelShowCount == 2)
            try snapshot(content, "build-hud-mac-failed.png")
            await waitGone(wc)
            #expect(wc.buildBezelView == nil)

            // Repeated results replace the bezel (one view, the newest
            // title) and the replacement keeps its full time.
            wc.applyBehaviors(for: .finished("Build Succeeded"))
            let first = try #require(wc.buildBezelView)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            wc.applyBehaviors(for: .finished("Build Failed"))
            #expect(wc.buildBezelView === first && wc.buildBezelTitle == "Build Failed")
            #expect(content.subviews.filter { $0 is BuildBezelView }.count == 1)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(wc.buildBezelTitle == "Build Failed")
            await waitGone(wc)
            #expect(wc.buildBezelView == nil)

            // Reduce Motion: removed at 1.6 s with no fade.
            wc.bezelReduceMotionOverride = true
            let started = Date()
            wc.applyBehaviors(for: .finished("Build Succeeded"))
            await waitGone(wc)
            #expect(wc.buildBezelView == nil && Date().timeIntervalSince(started) >= BezelTimeline.visibleDuration)

            // The window not in front: a system notification, no bezel.
            wc.notificationWindowStateOverride = BuildNotificationPolicy.WindowState(isVisible: true, isMinimized: true, isKey: false, appIsActive: true)
            wc.applyBehaviors(for: .finished("Build Failed"))
            #expect(wc.buildBezelView == nil)
            #expect(wc.systemNotices.map(\.title) == ["Build Failed"])

            // Without the Notify action nothing shows.
            var b = Preferences.shared.behavior(.buildFails)
            b.notify = false
            Preferences.shared.setBehavior(b, for: .buildFails)
            wc.notificationWindowStateOverride = .frontmost
            wc.applyBehaviors(for: .finished("Build Failed"))
            #expect(wc.buildBezelView == nil && wc.systemNotices.count == 1)
            window.close()
        }
    }
}
