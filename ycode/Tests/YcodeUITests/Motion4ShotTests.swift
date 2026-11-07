import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let shotsEnabled = ProcessInfo.processInfo.environment["YCODE_M4_SHOTS"] != nil

/// Screenshots of the council round 4 group D states (rows 109–114), in
/// light and dark, into `.build-ide/b4-shots/` (opt-in: `YCODE_M4_SHOTS=1`).
/// Ycode's own windows only, ordered behind every other window.
@MainActor
@Suite(.serialized, .enabled(if: shotsEnabled)) struct Motion4ShotTests {
    let out = ycodeDir.appendingPathComponent(".build-ide/b4-shots")

    func shoot(_ win: NSWindow, _ name: String) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()
        UISpacingProbeTests.shot(win, out.appendingPathComponent("m4-\(name).png"))
    }

    func pump(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    @Test(arguments: ["light", "dark"]) func mainWindow(_ mode: String) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let fc = FidelityCouncilTests()
        let dir = try fc.project("m4-shots-\(mode)")
        let wc = try fc.window(dir)
        let win = try #require(wc.window)
        win.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        win.setFrame(NSRect(x: 40, y: 40, width: 1400, height: 880), display: true)
        win.orderBack(nil)
        defer { win.close() }
        // 110, 111: nothing open: the empty jump bar and inspector, the
        // bottom bars with the filled breakpoints tag.
        if wc.editor.fileURL != nil { wc.closeDocument(nil) }
        wc.inspector.show(file: nil)
        pump()
        shoot(win, "110-111-empty-\(mode)")
        // 109: a large image: the image editor at once, empty, "--".
        let big = dir.appendingPathComponent("GlassScroll/Big.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2100, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 3,
                                                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: big)
        wc.open(path: big.path, line: nil)
        shoot(win, "109-image-switched-\(mode)")
    }

    @Test(arguments: ["light", "dark"]) func repositories(_ mode: String) async throws {
        _ = NSApplication.shared
        let dir = try SourceControlTests().makeRepo()
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false)
        let win = try #require(wc.window)
        win.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        wc.applyDefaultLayout()
        win.setFrame(NSRect(x: 40, y: 40, width: 1400, height: 880), display: true)
        await wc.sourceControl.idle()
        if wc.editor.fileURL != nil { wc.closeDocument(nil) }
        wc.navigator.select(1)
        wc.sourceControl.setMode(.repositories)
        try await Task.sleep(nanoseconds: 400_000_000)
        shoot(win, "111-114-repositories-\(mode)")
        win.close()
    }

    @Test(arguments: ["light", "dark"]) func welcome(_ mode: String) throws {
        _ = NSApplication.shared
        let td = TestDefaults("m4-shots-welcome-\(mode)")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        let dir = try FidelityCouncilTests().project("m4-welcome-\(mode)")
        recents.note(dir.appendingPathComponent("GlassScroll.xcodeproj"))
        let w = WelcomeWindowController(recents: recents)
        let win = try #require(w.window)
        win.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        shoot(win, "112-welcome-\(mode)")
        win.close()
    }
}
