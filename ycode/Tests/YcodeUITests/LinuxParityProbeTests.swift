import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeIDEShell
import YcodeProject
@testable import YcodeUI

/// The macOS half of the Linux IDE's paired screenshots (`docs/PARITY.md`
/// §5.10). With `YCODE_PARITY_DIR` and `YCODE_PARITY_PACKAGE` (the Greeter
/// package of `scripts/linux-ui-parity/make-demo.sh`) set, it opens the
/// package in a real workspace window at 1400 × 900 and writes, per state
/// and appearance, `mac-<appearance>-<state>.png` (the window's frame view
/// drawn with `cacheDisplay`, so the window is never put on screen) and
/// `mac-<appearance>-<state>.txt` (every view's frame, as
/// `UISpacingProbeTests` dumps it). `scripts/linux-ui-parity/compose.py`
/// pairs them with the Linux shell's. It never runs without the variables.
@MainActor
@Suite(.serialized) struct LinuxParityProbeTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_PARITY_DIR"]
    nonisolated static let package = ProcessInfo.processInfo.environment["YCODE_PARITY_PACKAGE"]

    @Test(.enabled(if: outDir != nil && package != nil)) func pairedStates() async throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefs = IsolatedPreferences("linux-parity")
        defer { prefs.restore() }
        let dir = URL(fileURLWithPath: try #require(Self.package))
        let only = ProcessInfo.processInfo.environment["YCODE_PARITY_APPEARANCES"]?.split(separator: ",").map(String.init)
        for appearance in only ?? ["light", "dark"] {
            try await states(dir, appearance: appearance, out: out)
        }
    }

    func states(_ dir: URL, appearance: String, out: URL) async throws {
        let look = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        func shot(_ win: NSWindow, _ state: String) throws {
            win.contentView?.layoutSubtreeIfNeeded()
            try Self.write(window: win, name: "mac-\(appearance)-\(state)", to: out)
        }

        // Welcome, with the package as the one recent project.
        let td = TestDefaults("linux-parity-welcome")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        recents.note(dir)
        let welcome = WelcomeWindowController(recents: recents)
        let ww = try #require(welcome.window)
        ww.appearance = look
        try shot(ww, "welcome")
        ww.close()

        // Settings ▸ General.
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        let sw = try #require(settings.window)
        sw.appearance = look
        try shot(sw, "settings")
        sw.close()

        // The workspace: nothing selected, then Greeting.swift open.
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        session.engine = PackageBuildEngine()
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false, openFirstFile: false)
        let win = try #require(wc.window)
        win.appearance = look
        wc.applyDefaultLayout()
        wc.notificationWindowStateOverride = .frontmost
        wc.bezelReduceMotionOverride = true
        try shot(win, "workspace")
        // The file's path as the project tree has it (the model standardizes
        // the folder's path), so the jump bar finds its groups.
        let greeting = session.model.root.allFiles.first { $0.name == "Greeting.swift" }?.path
        wc.open(path: greeting ?? dir.appendingPathComponent("Sources/GreeterCore/Greeting.swift").path, line: nil)
        try shot(win, "file")

        // The inspector hidden, then shown again.
        wc.inspectorItem.isCollapsed = true
        try shot(win, "inspector-hidden")
        wc.inspectorItem.isCollapsed = false
        win.contentView?.layoutSubtreeIfNeeded()

        // Find in Workspace: "Greeting".
        wc.findInWorkspace(nil)
        wc.navigator.findField.stringValue = "Greeting"
        wc.navigator.find("Greeting")
        try shot(win, "find")

        // A failed build: the bezel, then the Issue navigator.
        wc.buildProduct(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        for _ in 0..<2400 where session.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        if wc.buildBezelView != nil { try shot(win, "bezel") }
        for _ in 0..<40 where wc.buildBezelView != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        wc.navigator.select(4)
        try shot(win, "issues")

        // The debug area with the build's output.
        wc.showDebugArea(true)
        try shot(win, "debug")
        wc.showDebugArea(false)
        win.close()
    }

    static func write(window win: NSWindow, name: String, to out: URL) throws {
        let frame = try #require(win.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        var lines = ["window \(win.frame.size) content \(win.contentLayoutRect)"]
        UISpacingProbeTests.dump(frame, in: frame, depth: 0, into: &lines)
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
    }
}
