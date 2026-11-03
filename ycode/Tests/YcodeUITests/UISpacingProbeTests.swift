import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// A probe of Ycode's own windows for the spacing audit
/// (`specs/ide/metrics.md`): with `YCODE_UI_PROBE_DIR` set it writes a
/// frame dump of every view (window points, origin at the top left) and a
/// window snapshot per state there. It never runs without the variable.
@MainActor
@Suite(.serialized) struct UISpacingProbeTests {
    nonisolated static let probeDir = ProcessInfo.processInfo.environment["YCODE_UI_PROBE_DIR"]

    /// A package "Demo" (as the reference was observed with): two sources
    /// and a test target.
    static func demoPackage() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ui-probe-\(UUID().uuidString)").resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("Demo")
        for sub in ["Sources/Demo", "Tests/DemoTests"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\"), .testTarget(name: \"DemoTests\", dependencies: [\"Demo\"])])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Model {\n    public var value = 1\n}\n".write(to: dir.appendingPathComponent("Sources/Demo/Model.swift"), atomically: true, encoding: .utf8)
        try "public func helper() -> Int {\n    1\n}\n".write(to: dir.appendingPathComponent("Sources/Demo/Helper.swift"), atomically: true, encoding: .utf8)
        try "import Testing\n@Test func t() {}\n".write(to: dir.appendingPathComponent("Tests/DemoTests/DemoTests.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test(.enabled(if: probeDir != nil)) func probeWindows() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.probeDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefs = IsolatedPreferences("ui-probe")
        defer { prefs.restore() }
        let dir = try Self.demoPackage()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        let win = try #require(wc.window)
        if ProcessInfo.processInfo.environment["YCODE_UI_PROBE_APPEARANCE"] == "light" { win.appearance = NSAppearance(named: .aqua) }
        wc.applyDefaultLayout()
        wc.open(path: dir.appendingPathComponent("Sources/Demo/Model.swift").path, line: nil)
        win.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: win, name: "workspace", to: out)
        wc.editor.showFindBar(replace: false)
        win.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: win, name: "workspace-find", to: out)
        wc.editor.hideFindBar()
        wc.toggleDebugArea(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: win, name: "workspace-debug", to: out)
        wc.toggleDebugArea(nil)
        let testsFile = dir.appendingPathComponent("Tests/DemoTests/DemoTests.swift").path
        wc.navigator.setTests(TestDiscovery.tests(in: "import Testing\n@Test func one() {}\n@Test func two() {}\n", file: testsFile), results: [:])
        for (i, name) in [(1, "nav-sourcecontrol"), (3, "nav-find"), (4, "nav-issues"), (5, "nav-tests"), (8, "nav-reports")] {
            wc.navigator.select(i)
            win.contentView?.layoutSubtreeIfNeeded()
            try Self.write(window: win, name: name, to: out)
        }
        wc.navigator.select(0)
        win.close()

        // The Welcome window.
        let td = TestDefaults("ui-probe-welcome")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        recents.note(dir)
        let welcome = WelcomeWindowController(recents: recents)
        let ww = try #require(welcome.window)
        ww.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: ww, name: "welcome", to: out)
        ww.close()

        // Settings: General and Editing.
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        let sw = try #require(settings.window)
        sw.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: sw, name: "settings-general", to: out)
        settings.select(7)
        sw.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: sw, name: "settings-editing", to: out)
        sw.close()

        // Device Hub with one shut-down simulator row (no simctl).
        let row = DeviceRow(name: "Phone (Ycode)", identifier: "probe-1", platform: "iOS", osVersion: "27.1", state: "Shutdown",
                            model: "Ycode Simulator", isAvailable: true, isYcodeRemote: true, isFoldable: false)
        let hub = DevicesController(devices: [], simulators: [row])
        let hw = hub.makeWindow()
        hw.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        hub.show(.simulators)
        hub.select(row: 0)
        hw.contentView?.layoutSubtreeIfNeeded()
        try Self.write(window: hw, name: "device-hub", to: out)
        hw.close()
    }

    static func write(window win: NSWindow, name: String, to out: URL) throws {
        let frame = try #require(win.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        var lines = ["window \(win.frame.size) content \(win.contentLayoutRect)"]
        dump(frame, in: frame, depth: 0, into: &lines)
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
        shot(win, out.appendingPathComponent("\(name)-shot.png"))
    }

    /// `screencapture -l` of the window (Ycode's own window, ordered behind
    /// every other window so it never covers anything): the system draws
    /// the glass, which `cacheDisplay` leaves out.
    static func shot(_ win: NSWindow, _ url: URL) {
        let wasVisible = win.isVisible
        if !wasVisible { win.orderBack(nil) }
        win.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(win.windowNumber)", url.path]
        try? p.run()
        p.waitUntilExit()
        if !wasVisible { win.orderOut(nil) }
    }

    /// One line per view: depth, class, frame (x, y from the top left, w, h).
    static func dump(_ v: NSView, in frame: NSView, depth: Int, into lines: inout [String]) {
        let r = v.convert(v.bounds, to: nil)
        let top = frame.bounds.height - r.maxY
        let pad = String(repeating: " ", count: depth)
        var label = ""
        if let t = v as? NSTextField {
            label = " \"\(t.stringValue.prefix(30))\""
            if t.cell?.wraps == false, t.intrinsicContentSize.width > t.frame.width + 0.5, t.frame.width > 0 { label += " TRUNCATED" }
        }
        else if let b = v as? NSButton { label = " [\(b.title.prefix(20))|\(b.accessibilityTitle() ?? "")]" }
        if let id = v.identifier?.rawValue { label += " #\(id)" }
        func f(_ x: CGFloat) -> String { String(format: "%.1f", x) }
        lines.append(pad + "\(type(of: v)) x \(f(r.minX)) y \(f(top)) w \(f(r.width)) h \(f(r.height))" + (v.isHidden ? " HIDDEN" : "") + label)
        if let s = v as? NSScrollView {
            lines.append(pad + " insets top \(f(s.contentInsets.top)) bottom \(f(s.contentInsets.bottom)) auto \(s.automaticallyAdjustsContentInsets)"
                         + " clip bounds y \(f(s.contentView.bounds.minY))")
        }
        if let o = v as? NSOutlineView {
            lines.append(pad + " style \(o.style.rawValue) row0 in outline y \(f(o.rect(ofRow: 0).minY))")
            for row in 0..<min(o.numberOfRows, 12) {
                let rr = o.convert(o.rect(ofRow: row), to: nil)
                let cell = o.convert(o.frameOfCell(atColumn: 0, row: row), to: nil)
                let tri = o.convert(o.frameOfOutlineCell(atRow: row), to: nil)
                lines.append(pad + " row \(row) level \(o.level(forRow: row)) x \(f(rr.minX)) y \(f(frame.bounds.height - rr.maxY)) h \(f(rr.height))"
                             + " cell x \(f(cell.minX)) disclosure x \(f(tri.minX)) w \(f(tri.width)) indent \(f(o.indentationPerLevel))")
            }
        }
        for s in v.subviews { dump(s, in: frame, depth: depth + 1, into: &lines) }
    }
}
