import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeDeviceUI
@testable import YcodeIDECore
import YcodeIDEShell
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The macOS half of the cross-platform parity audit
/// (`specs/ide/cross-platform-parity.md`; the Linux half is
/// `YCODE_IDE_PARITY5`, `ShellDriver+Parity5.swift`). With
/// `YCODE_B5_PARITY_DIR=<folder>` it makes the two Merger repositories of
/// `scripts/linux-ui-parity/make-parity5.sh` and writes, in light and dark,
/// `mac-<appearance>-<state>.png` (the window alone, ordered behind every
/// other window, at the display's scale) and `mac-<appearance>-<state>.txt`:
/// the window's size and scale, then one line per visible text field,
/// button and identified view with its frame in points from the window's
/// top left, and for texts the font's size, weight and colour. The states
/// are the Linux walk's; the windows are drawn as the active app's key
/// windows (`KeyLook`; `YCODE_B5_PARITY_INACTIVE=1` leaves them inactive).
/// It never runs without the variable.
@MainActor
@Suite(.serialized) struct CrossPlatformParityShotTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_B5_PARITY_DIR"]

    func pump(_ s: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// The Linux window is the focused one, so the macOS windows are drawn
    /// as key windows of the active app (selection, source lists, window
    /// buttons and toolbar glyphs in their active colours), without
    /// activating the app: for this test only, `isKeyWindow`, `isMainWindow`
    /// and `NSApplication.isActive` answer yes.
    enum KeyLook {
        nonisolated(unsafe) static var saved: [(Method, IMP)] = []
        static func on() {
            func force(_ cls: AnyClass, _ sel: Selector) {
                guard let m = class_getInstanceMethod(cls, sel) else { return }
                let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
                saved.append((m, method_setImplementation(m, imp_implementationWithBlock(yes))))
            }
            force(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))
            force(NSWindow.self, #selector(getter: NSWindow.isMainWindow))
            force(NSApplication.self, #selector(getter: NSApplication.isActive))
        }
        static func off() {
            for (m, imp) in saved.reversed() { method_setImplementation(m, imp) }
            saved = []
        }
    }

    @Test(.enabled(if: outDir != nil)) func states() async throws {
        for appearance in ["light", "dark"] { try await states(appearance) }
    }

    func states(_ appearance: String) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let repos = out.appendingPathComponent("repos-\(appearance)")
        try? FileManager.default.removeItem(at: repos)
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/bin/sh")
        make.arguments = [ycodeDir.appendingPathComponent("scripts/linux-ui-parity/make-parity5.sh").path, repos.path]
        make.standardOutput = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        let rest = repos.appendingPathComponent("rest/Merger")
        let look = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let prefs = IsolatedPreferences("b5-parity-\(appearance)")
        defer { prefs.restore() }
        if ProcessInfo.processInfo.environment["YCODE_B5_PARITY_INACTIVE"] == nil { KeyLook.on() }
        defer { KeyLook.off() }
        // Ordering a titled window in moves it onto a display unless this is on.
        MergeSheetR5UITests.Offscreen.on()
        defer { MergeSheetR5UITests.Offscreen.off() }
        func shot(_ win: NSWindow, _ state: String) {
            win.contentView?.superview?.layoutSubtreeIfNeeded()
            win.displayIfNeeded()
            Self.write(win, name: "mac-\(appearance)-\(state)", to: out)
        }
        // Off every screen and behind everything (the window server still draws it).
        let origin = NSPoint(x: -6000, y: -6000)

        // The main window, 1400 × 880, in the dirty copy.
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: rest)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        let win = try #require(wc.window)
        win.appearance = look
        win.isExcludedFromWindowsMenu = true
        wc.applyDefaultLayout()
        win.setFrame(NSRect(origin: origin, size: NSSize(width: 1400, height: 880)), display: true)
        win.orderBack(nil)
        await wc.sourceControl.idle()
        if wc.editor.fileURL != nil { wc.closeDocument(nil) }
        wc.inspector.show(file: nil)
        pump()
        shot(win, "empty")
        let sample = rest.appendingPathComponent("Sources/Merger/Sample.swift").path
        wc.open(path: sample, line: nil)
        wc.editor.textView.setSelectedRange(NSRange(location: 60, length: 0))
        pump()
        shot(win, "rest")
        wc.showDebugArea(true)
        pump()
        shot(win, "debug")
        wc.showDebugArea(false)
        wc.splitEditor(nil)
        pump()
        shot(win, "split")
        // The issue stepper in both panes with a project warning (row 139).
        wc.session.packageIssues = [Diagnostic(severity: .warning, message: "Update to recommended settings", location: nil)]
        pump()
        shot(win, "stepper")
        wc.session.packageIssues = []
        // Back to one pane, nothing open.
        for e in wc.editorArea.allEditors.dropFirst() { wc.editorArea.closePane(e) }
        wc.closeDocument(nil)
        pump(0.2)
        wc.open(path: rest.appendingPathComponent("Sources/Merger/Stripes.png").path, line: nil)
        pump(1.0)
        shot(win, "image")
        wc.open(path: sample, line: nil)
        wc.navigator.select(1)
        wc.sourceControl.setMode(.changes)
        await wc.sourceControl.idle()
        pump()
        shot(win, "changes")
        wc.sourceControl.setMode(.repositories)
        await wc.sourceControl.idle()
        pump()
        shot(win, "repositories")
        // 1100 × 880: the file at rest.
        wc.navigator.select(0)
        win.setFrame(NSRect(origin: origin, size: NSSize(width: 1100, height: 880)), display: true)
        pump()
        shot(win, "narrow")
        // Split at 1100 (row 115: both panes wrap at the same column).
        wc.splitEditor(nil)
        pump()
        shot(win, "narrow-split")
        win.close()

        // The merge alert and sheet, in the clean copy.
        let merger = repos.appendingPathComponent("merge/Merger")
        let mc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: merger)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        let mw = try #require(mc.window)
        mw.appearance = look
        mw.isExcludedFromWindowsMenu = true
        mc.applyDefaultLayout()
        mw.setFrame(NSRect(origin: origin, size: NSSize(width: 1400, height: 880)), display: true)
        mw.orderBack(nil)
        await mc.sourceControl.idle()
        if mc.editor.fileURL != nil { mc.closeDocument(nil) }
        mc.navigator.select(1)
        mc.sourceControl.setMode(.repositories)
        await mc.sourceControl.idle()
        mc.sourceControl.run(.merge("feature"))
        pump(0.8)
        shot(mw, "alert")
        if let alert = mc.sourceControl.mergeOverlay?.alert {
            alert.merge(nil)
            await mc.sourceControl.idle()
            if let sheet = mc.sourceControl.mergeSheet { await sheet.idle() }
            pump(1.0)
            shot(mw, "sheet")
            // The sheet is a window of its own below the toolbar (merge-sheet.md
            // §14.1): the shot adds it at its place, past the window's bottom.
            if let sw = mc.sourceControl.mergeOverlay?.sheetWindow {
                Self.composite(parent: mw, child: sw, name: "mac-\(appearance)-sheet", to: out)
            }
            // The merge stays in the scratch repository: Cancel would ask
            // with an application-modal alert.
        }
        mw.close()

        // Welcome, with the repository as the one recent project.
        let td = TestDefaults("b5-parity-welcome-\(appearance)")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        recents.note(rest)
        let welcome = WelcomeWindowController(recents: recents)
        let ww = try #require(welcome.window)
        ww.appearance = look
        ww.isExcludedFromWindowsMenu = true
        ww.setFrameOrigin(origin)
        ww.orderBack(nil)
        pump()
        shot(ww, "welcome")
        ww.close()

        // Settings: General, Editing, Components, Simulators (the simulator-host page).
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        let sw = try #require(settings.window)
        sw.appearance = look
        sw.isExcludedFromWindowsMenu = true
        sw.setFrameOrigin(origin)
        sw.orderBack(nil)
        for page in ["General", "Editing", "Components", "Simulators"] {
            settings.show(page: page)
            pump(0.4)
            shot(sw, "settings-\(page.lowercased())")
        }
        sw.close()

        // The simulator runtime wizard's host step (the Linux IDE's simulator-host page).
        // On a simulator host, as the Linux IDE always is (the host step is only offered then).
        var choices = RuntimeSetupChoices()
        choices.useHost = true
        choices.save(td.defaults)
        let session = RuntimeSetupSession(defaults: td.defaults)
        let rwc = RuntimeSetupWindowController(session: session)
        rwc.answerConfirmation = { _ in false }
        session.show(.host)
        let rw = try #require(rwc.window)
        rw.appearance = look
        rw.isExcludedFromWindowsMenu = true
        rwc.assistant.finishTransition()
        rw.setFrameOrigin(origin)
        rw.orderBack(nil)
        pump(0.8)
        shot(rw, "runtime-host")
        rw.close()

        // The device window: a booted Ycode simulator (no live picture), at 1100 × 800.
        let hub = DevicesController(devices: [], simulators: [DeviceHubR3Tests.duo, DeviceHubR3Tests.stopped, DeviceHubR3Tests.other])
        hub.defaults = td.defaults
        hub.deviceSettings = { _, words in words == ["settings"] ? (true, SimulatorSettingsUITests.reply) : (true, "ok") }
        let hw = hub.makeWindow()
        hw.appearance = look
        hw.isExcludedFromWindowsMenu = true
        hw.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        hw.setContentSize(NSSize(width: 1100, height: 800))
        hw.setFrameOrigin(origin)
        hw.orderBack(nil)
        hw.contentView?.layoutSubtreeIfNeeded()
        hub.placeFirstDividers()
        if let i = hub.rows.firstIndex(where: { $0.identifier == DeviceHubR3Tests.duo.identifier }) { hub.select(row: i) }
        await hub.settingsTask?.value
        pump(0.8)
        shot(hw, "devices")
        hw.close()
    }

    // MARK: Writing

    /// Replaces `<name>.png` (the parent alone) with the parent and `child`
    /// at its place, as tall as both need; keeps the child alone as
    /// `<name>-window.png`.
    static func composite(parent: NSWindow, child: NSWindow, name: String, to out: URL) {
        let childURL = out.appendingPathComponent("\(name)-window.png"), parentURL = out.appendingPathComponent("\(name).png")
        UISpacingProbeTests.shot(child, childURL)
        guard let p = NSBitmapImageRep(data: (try? Data(contentsOf: parentURL)) ?? Data()),
              let c = NSBitmapImageRep(data: (try? Data(contentsOf: childURL)) ?? Data()) else { return }
        let k = CGFloat(p.pixelsWide) / parent.frame.width
        let dx = (child.frame.minX - parent.frame.minX) * k, top = (parent.frame.maxY - child.frame.maxY) * k
        let w = p.pixelsWide, h = max(p.pixelsHigh, Int((top + CGFloat(c.pixelsHigh)).rounded(.up)))
        guard let o = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: o)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        p.draw(in: NSRect(x: 0, y: CGFloat(h - p.pixelsHigh), width: CGFloat(p.pixelsWide), height: CGFloat(p.pixelsHigh)))
        c.draw(in: NSRect(x: dx, y: CGFloat(h) - top - CGFloat(c.pixelsHigh), width: CGFloat(c.pixelsWide), height: CGFloat(c.pixelsHigh)),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? o.representation(using: .png, properties: [:])?.write(to: parentURL)
    }

    static func write(_ win: NSWindow, name: String, to out: URL) {
        UISpacingProbeTests.shot(win, out.appendingPathComponent("\(name).png"))
        guard let frame = win.contentView?.superview else { return }
        var lines = [String(format: "window %.1f %.1f scale %.1f", win.frame.width, win.frame.height, win.backingScaleFactor)]
        win.effectiveAppearance.performAsCurrentDrawingAppearance {
            describe(frame, height: frame.bounds.height, into: &lines)
        }
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    static func hex(_ c: NSColor?) -> String {
        guard let s = c?.usingColorSpace(.sRGB) else { return "-" }
        func b(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X/%.2f", b(s.redComponent), b(s.greenComponent), b(s.blueComponent), s.alphaComponent)
    }

    static func font(_ f: NSFont?) -> String {
        guard let f else { return "-" }
        let traits = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        return String(format: "size=%.1f weight=%.2f", f.pointSize, weight)
    }

    /// One line per visible text field, button, segmented control, text
    /// view and identified view: kind, "text", x y w h (points, top left).
    static func describe(_ v: NSView, height: CGFloat, into lines: inout [String]) {
        guard !v.isHidden, v.alphaValue > 0.01 else { return }
        let r = v.convert(v.bounds, to: nil)
        let box = String(format: "%.1f %.1f %.1f %.1f", r.minX, height - r.maxY, r.width, r.height)
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'") + "\"" }
        let id = v.identifier?.rawValue ?? (v.accessibilityIdentifier().isEmpty ? nil : v.accessibilityIdentifier())
        let idPart = id.map { " id=\($0.replacingOccurrences(of: " ", with: "_"))" } ?? ""
        if let t = v as? NSTextField, !t.stringValue.isEmpty {
            lines.append("text \(quoted(t.stringValue)) \(box) \(font(t.font)) color=\(hex(t.textColor)) class=\(type(of: v))\(idPart)")
        } else if let b = v as? NSButton {
            lines.append("button \(quoted(b.title)) \(box) \(font(b.font)) class=\(type(of: v))\(idPart) ax=\(quoted(b.accessibilityTitle() ?? ""))")
        } else if let s = v as? NSSegmentedControl {
            let labels = (0..<s.segmentCount).map { s.label(forSegment: $0) ?? "" }.joined(separator: "|")
            lines.append("segments \(quoted(labels)) \(box) \(font(s.font)) selected=\(s.selectedSegment)\(idPart)")
        } else if let t = v as? NSTextView {
            lines.append("textview \(box) \(font(t.font)) bg=\(hex(t.backgroundColor)) class=\(type(of: v))\(idPart)")
        } else if id != nil || v is NSScrollView || v is NSSplitView || v is NSVisualEffectView || v is NSImageView || v is NSBox {
            lines.append("view \(box) class=\(type(of: v))\(idPart)")
        }
        for s in v.subviews { describe(s, height: height, into: &lines) }
    }
}
