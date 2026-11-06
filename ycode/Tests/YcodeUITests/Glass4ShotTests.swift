import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let shotsEnabled = ProcessInfo.processInfo.environment["YCODE_G4_SHOTS"] != nil

/// Screenshots of the council round 3 main-window states (rows 68–82), in
/// light and dark, into `.build-ide/b3-shots/` (opt-in: `YCODE_G4_SHOTS=1`).
/// Ycode's own windows only, ordered behind every other window.
@MainActor
@Suite(.serialized, .enabled(if: shotsEnabled)) struct Glass4ShotTests {
    let out = ycodeDir.appendingPathComponent(".build-ide/b3-shots")

    func shoot(_ win: NSWindow, _ name: String) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        win.contentView?.layoutSubtreeIfNeeded()
        win.displayIfNeeded()
        UISpacingProbeTests.shot(win, out.appendingPathComponent("g4-\(name).png"))
    }

    func bands() -> String {
        var s = "import Foundation\n\n// " + String(repeating: "\u{2588}", count: 110) + "\n\n"
        for _ in 0..<30 {
            for _ in 0..<3 { s += "let s = \"" + String(repeating: "\u{2588}", count: 60) + "\"\n" }
            s += "\n\n\n"
        }
        return s
    }

    @Test(arguments: ["light", "dark"]) func mainWindow(_ mode: String) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        let fc = FidelityCouncilTests()
        let dir = try fc.project("g4-shots-\(mode)")
        try bands().write(to: dir.appendingPathComponent("GlassScroll/Bands.swift"), atomically: true, encoding: .utf8)
        let wc = try fc.window(dir)
        let win = try #require(wc.window)
        win.appearance = appearance
        win.setFrame(NSRect(x: 40, y: 40, width: 1400, height: 880), display: true)
        win.orderBack(nil)
        func pump(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        // 74: the empty editor.
        if wc.editor.fileURL != nil { wc.closeDocument(nil) }
        pump()
        shoot(win, "74-empty-editor-\(mode)")
        // 78, 79: Long.swift at rest (jump bar text, File inspector).
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        pump()
        shoot(win, "78-79-long-at-rest-\(mode)")
        // 72: Stripes.png selected.
        wc.open(path: dir.appendingPathComponent("GlassScroll/Stripes.png").path, line: nil)
        pump()
        shoot(win, "72-image-\(mode)")
        // 68, 75: Bands.swift with the bands under the bars.
        wc.open(path: dir.appendingPathComponent("GlassScroll/Bands.swift").path, line: nil)
        let clip = wc.editor.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -wc.editor.scrollView.contentInsets.top + 130))
        wc.editor.scrollView.reflectScrolledClipView(clip)
        pump()
        shoot(win, "68-75-bands-under-bars-\(mode)")
        // 69: the navigator scrolled under the selector capsule.
        wc.navigator.select(0)
        wc.navigator.outlineView.expandItem(nil, expandChildren: true)
        let nclip = wc.navigator.scrollView.contentView
        nclip.scroll(to: NSPoint(x: 0, y: nclip.bounds.minY + 40))
        wc.navigator.scrollView.reflectScrolledClipView(nclip)
        pump()
        shoot(win, "69-selector-capsule-\(mode)")
        // 71, 81: Editor Pane On Right with Long.swift.
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.split(sideBySide: true)
        pump()
        shoot(win, "71-81-split-panes-\(mode)")
        // 77: a narrower window, split (274-point panes).
        win.setFrame(NSRect(x: 40, y: 40, width: 1100, height: 880), display: true)
        pump()
        shoot(win, "77-narrow-split-minimap-\(mode)")
        win.close()
    }

    @Test(arguments: ["light", "dark"]) func welcome(_ mode: String) throws {
        _ = NSApplication.shared
        let td = TestDefaults("g4-shots-welcome-\(mode)")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        let win = try #require(w.window)
        win.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        shoot(win, "80-welcome-\(mode)")
        win.close()
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
        shoot(win, "82-repositories-\(mode)")
        win.close()
    }
}
