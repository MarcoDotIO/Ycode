import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Round 7 group D's pictures of the macOS IDE (with `YCODE_B7_SHOTS=<folder>`):
/// the navigator's logos, the Ycode mark and the selector glyphs; the
/// window restored on reopen; the Widths row; the Welcome row; the alert.
/// Every window stays off the displays (the offscreen-safe shot).
@MainActor
@Suite(.serialized) struct CouncilRound7ShotTests {
    nonisolated static let out = ProcessInfo.processInfo.environment["YCODE_B7_SHOTS"]

    /// A project with a file of every logo's language and a few without one.
    func polyglot() throws -> URL {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build-ide/b7-polyglot")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("Sources/Poly")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Poly\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for f in ["App.swift", "tool.py", "core.cpp", "core.c", "web.js", "web.ts", "lib.rs", "main.go", "task.rb", "Main.java",
                  "Main.kt", "index.html", "style.css", "README.md", "data.json", "build.sh", "Bridge.m", "Shaders.metal", "Info.plist"] {
            try "\n".write(to: src.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test(.enabled(if: out != nil)) func shots() throws {
        let out = URL(fileURLWithPath: Self.out!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (look, name) in [(NSAppearance(named: .darkAqua)!, "dark"), (NSAppearance(named: .aqua)!, "light")] {
            // The navigator with every logo.
            let dir = try polyglot()
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                               startLanguageService: false, openFirstFile: false)
            let win = try #require(wc.window)
            win.appearance = look
            win.isExcludedFromWindowsMenu = true
            wc.applyDefaultLayout()
            win.setFrame(NSRect(x: -9000, y: -9000, width: 1400, height: 880), display: false)
            wc.navigator.outlineView.expandItem(nil, expandChildren: true)
            wc.open(path: dir.appendingPathComponent("Sources/Poly/App.swift").path, line: nil)
            UISpacingProbeTests.shot(win, out.appendingPathComponent("mac-\(name)-window-logos.png"))
            win.close()
            // The navigator alone, drawn over the sidebar's colour (the glass
            // draws nothing off the displays).
            let nav = NavigatorAreaController()
            let nw = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 280, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            nw.isReleasedWhenClosed = false
            nw.appearance = look
            nw.contentView = nav.view
            nav.view.frame = NSRect(x: 0, y: 0, width: 280, height: 640)
            nav.setProjectTree(try WorkspaceModel(url: dir).root)
            nav.select(0)
            nav.outlineView.expandItem(nil, expandChildren: true)
            nav.view.layoutSubtreeIfNeeded()
            Self.draw(nav.view, over: name == "dark" ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.96, alpha: 1),
                      to: out.appendingPathComponent("mac-\(name)-navigator-logos.png"))
            nw.close()

            // Restore on reopen: the split, the active pane, the inspector.
            let fc = FidelityCouncilTests()
            let gdir = try fc.project("b7-shot-restore-\(name)")
            let state = gdir.appendingPathComponent("ycode-ui-state.json")
            var s = WorkspaceUserState()
            s.editorLayout = WorkspaceEditorLayout(panes: [.init(path: gdir.appendingPathComponent("GlassScroll/Long.swift").path, topLine: 12),
                                                           .init(path: gdir.appendingPathComponent("GlassScroll/Models/Model01.swift").path)],
                                                   focused: 1)
            s.inspector = WorkspaceInspectorState(isShown: true, tab: 0)
            s.save(to: state)
            let rc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: gdir.appendingPathComponent("GlassScroll.xcodeproj"))),
                                               loadDestinations: false, startLanguageService: false, openFirstFile: false, userStateURL: state)
            let rw = try #require(rc.window)
            rw.appearance = look
            rw.isExcludedFromWindowsMenu = true
            rw.setFrame(NSRect(x: -9000, y: -9000, width: 1400, height: 880), display: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            UISpacingProbeTests.shot(rw, out.appendingPathComponent("mac-\(name)-reopen.png"))
            // The Widths row at 1180.
            rw.setFrame(NSRect(x: -9000, y: -9000, width: 1180, height: 880), display: false)
            UISpacingProbeTests.shot(rw, out.appendingPathComponent("mac-\(name)-widths.png"))
            rc.session.isIndexing = true
            UISpacingProbeTests.shot(rw, out.appendingPathComponent("mac-\(name)-indexing.png"))
            rc.session.isIndexing = false
            rw.close()

            // Welcome, with the council's path.
            let td = TestDefaults("b7-shot-welcome-\(name)")
            defer { td.remove() }
            let recents = RecentProjects(defaults: td.defaults)
            recents.note(gdir.appendingPathComponent("GlassScroll.xcodeproj"))
            let welcome = WelcomeWindowController(recents: recents)
            let ww = try #require(welcome.window)
            ww.appearance = look
            ww.isExcludedFromWindowsMenu = true
            ww.setFrameOrigin(NSPoint(x: -9000, y: -9000))
            welcome.table.selectRowIndexes([0], byExtendingSelection: false)
            UISpacingProbeTests.shot(ww, out.appendingPathComponent("mac-\(name)-welcome.png"))
            ww.close()

            // The merge alert alone.
            let alert = MergeAlertView(branch: "feature", current: "main")
            let aw = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 460, height: 172), styleMask: [.borderless], backing: .buffered, defer: false)
            aw.isReleasedWhenClosed = false
            aw.appearance = look
            aw.contentView?.addSubview(alert)
            alert.setFrameOrigin(NSPoint(x: 20, y: 20))
            UISpacingProbeTests.shot(aw, out.appendingPathComponent("mac-\(name)-alert.png"))
            aw.close()
        }
    }

    /// A view drawn at 2x over a solid colour, to a PNG.
    static func draw(_ v: NSView, over fill: NSColor, to url: URL) {
        let size = v.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let cached = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.effectiveAppearance.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: cached) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSRect(origin: .zero, size: size).fill()
        cached.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
