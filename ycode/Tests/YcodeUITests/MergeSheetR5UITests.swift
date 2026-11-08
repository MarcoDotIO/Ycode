import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 5 on the merge workflow (`specs/ide/merge-sheet.md` §13.2,
/// §14; checklist rows 125–130): the sheet in a window of its own hanging
/// below the workspace window, its buttons, the focus moving into the panes,
/// the ruler, and the alert's and the sheet's buttons found and pressed
/// through the accessibility API from outside the view tree, the way the
/// capture tool's driver does it.
///
/// The accessibility test orders the workspace window in **off every
/// display** (origin −6000, −6000; the offscreen guard stops AppKit from
/// moving it onto a screen) so the window server serves it to accessibility; nothing
/// appears on screen, and the window is ordered out before anything could
/// ask a question.
@MainActor
@Suite(.serialized) struct MergeSheetR5UITests {
    let base = MergeSheetUITests()
    typealias Repo = MergeSheetUITests.Repo

    // MARK: Row 125: the sheet below the window

    /// The sheet is a window of its own, attached below the toolbar: in the
    /// 880-point window it ends at 908, 28 below the parent, which is
    /// neither moved nor resized; Cancel is at y 866–886, 19 below the box.
    @Test func sheetIsItsOwnWindowHangingBelowTheParent() async throws {
        let r = try Repo("r5-window")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: true)
        let parent = try #require(wc.window)
        let before = parent.frame
        let sheet = try await base.openSheet(wc)
        let overlay = try #require(wc.sourceControl.mergeOverlay)
        let sw = try #require(overlay.sheetWindow)
        #expect(sheet.view.window === sw && sw !== parent)
        #expect(parent.frame == before, "the parent is not moved or resized")
        // The sheet's frame in the parent: x 24–1376, top at the toolbar's
        // bottom, bottom 28 below the parent's bottom edge.
        let f = sw.sheetFrame(in: parent)
        let tb = overlay.toolbarBottom
        #expect(f.minX == 24 && f.width == 1352 && abs(f.minY - tb) < 0.01, "\(f)")
        #expect(abs(f.maxY - (880 + 28 + (tb - 52))) <= 0.5, "sheet bottom \(f.maxY) with the toolbar at \(tb)")
        // Never constrained to a screen.
        #expect(sw.constrainFrameRect(sw.frame, to: NSScreen.main) == sw.frame)
        #expect(sw.styleMask == [.borderless] && !sw.isOpaque && sw.hasShadow && sw.canBecomeKey && !sw.canBecomeMain)
        // The box to 847, the buttons 19 below it, 20 tall, radius 6, the
        // sheet's bottom 22 below them; all inside the sheet's window.
        let box = base.windowRect(sheet.sheetView.box, sheet.sheetView.box.bounds, wc)
        let cancel = base.windowRect(sheet.cancelButton, sheet.cancelButton.bounds, wc)
        let merge = base.windowRect(sheet.mergeButton, sheet.mergeButton.bounds, wc)
        #expect(abs(box.maxY - (880 - 33)) <= 0.5, "box to \(box.maxY)")
        #expect(abs(cancel.minY - box.maxY - 19) <= 0.5 && cancel.height == 20 && merge.height == 20, "\(cancel) \(merge)")
        #expect(abs(f.maxY - cancel.maxY - 22) <= 0.5)
        #expect(cancel.minX == 1176 && cancel.maxX == 1260 && merge.minX == 1272 && merge.maxX == 1356, "\(cancel) \(merge)")
        #expect(sheet.cancelButton.cornerRadius == 6 && sheet.mergeButton.cornerRadius == 6)
        #expect(sheet.view.layer?.cornerRadius == 16)
        // The part below the parent is drawn: Cancel's fill, read back from
        // the sheet's window below y 880.
        let s = try base.snapshot(wc)
        #expect(s.height >= f.maxY - 0.5, "the snapshot holds the whole sheet")
        #expect(base.same(s.color(cancel.minX + 10, cancel.midY), MergeSheetPalette.dark.button), "Cancel #2E2F30")
        #expect(base.same(s.color(merge.minX + 6, merge.midY), MergeSheetPalette.dark.disabledButton), "Merge disabled #252627")
        #expect(base.same(s.color(f.midX, f.maxY - 8), MergeSheetPalette.dark.sheet), "the sheet's fill below the window")
        base.shot(wc, "r5-dark-sheet-below")

        // A taller window: the sheet follows (the box 33 above its bottom).
        parent.setFrame(NSRect(x: before.minX, y: before.minY - 120, width: 1400, height: 1000), display: false)
        overlay.layoutSubtreeIfNeeded()
        let f2 = sw.sheetFrame(in: parent)
        #expect(abs(f2.maxY - (1000 + 28 + (tb - 52))) <= 0.5 && f2.minX == 24, "\(f2)")
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
        #expect(sw.parent == nil && !sw.isVisible)
    }

    // MARK: Rows 126, 127, 129

    /// Row 126: the buttons' colours and shape in both appearances.
    @Test func sheetButtonsAreRoundedRectanglesWithTheMeasuredFills() {
        let d = MergeSheetPalette.dark
        #expect(d.button == 0x2E2F30 && d.buttonLabel == 0xDFDFDF && d.disabledButton == 0x252627 && d.disabledButtonLabel == 0x5B5C5C)
        #expect(MergeSheetMetrics.buttonHeight == 20 && MergeSheetMetrics.buttonGap == 19 && MergeSheetMetrics.bottomMargin == 22
                && MergeSheetMetrics.buttonCornerRadius == 6)
        _ = NSApplication.shared
        let b = MergeButton(title: "Cancel")
        b.appearance = NSAppearance(named: .darkAqua)
        b.cornerRadius = 6
        b.frame = NSRect(x: 0, y: 0, width: 84, height: 20)
        if let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) {
            b.cacheDisplay(in: b.bounds, to: rep)
            let k = CGFloat(rep.pixelsWide) / 84
            // A radius-6 corner leaves its pixel at (1, 1) empty; a capsule's
            // (radius 10) would also leave (3, 3) empty; this one fills it.
            #expect((rep.colorAt(x: Int(1 * k), y: Int(1 * k))?.alphaComponent ?? 1) < 0.5)
            #expect((rep.colorAt(x: Int(3.5 * k), y: Int(3.5 * k))?.alphaComponent ?? 0) > 0.9)
        }
    }

    /// Row 127: a click on a token moves the focus into the panes; the file
    /// list's selection turns grey (#464546) and its badge red (#FF4245)
    /// with a white letter. A click in the list brings the accent back.
    @Test func tokenClickMovesFocusIntoThePanes() async throws {
        let r = try Repo("r5-focus")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: true)
        let sheet = try await base.openSheet(wc)
        let p = MergeSheetPalette.dark
        let sw = try #require(wc.sourceControl.mergeOverlay?.sheetWindow)
        #expect(sw.firstResponder === sheet.fileList && sheet.fileList.hasListFocus)
        let rowIndex = try #require(sheet.fileRows.firstIndex { $0.path == sheet.state.currentFile })
        let row = base.windowRect(sheet.fileList, sheet.fileList.rowFrame(rowIndex), wc)
        let badge = NSPoint(x: row.maxX - CGFloat(MergeSheetMetrics.badgeTrailing) - 2, y: row.midY - 4)
        var s = try base.snapshot(wc)
        #expect(base.same(s.color(row.minX + 4, row.midY), p.selection), "focused: the accent selection")
        #expect(base.same(s.color(badge.x, badge.y), p.badge), "focused: a white badge")

        // The click on the first token (the Choose menu is not shown: the
        // window is not on screen).
        let t = try #require(sheet.canvas.tokenRect(forHunk: 0))
        let inWindow = sheet.canvas.convert(NSPoint(x: t.midX, y: t.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                                     windowNumber: sw.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        sheet.canvas.mouseDown(with: click)
        #expect(sw.firstResponder === sheet.canvas && !sheet.fileList.hasListFocus)
        #expect(p.fileRow(selected: true, listFocused: false) == .init(fill: 0x464546, ink: nil, badge: 0xFF4245, badgeLetter: 0xFFFFFF))
        s = try base.snapshot(wc)
        #expect(base.same(s.color(row.minX + 4, row.midY), p.unfocusedSelection), "the grey selection")
        #expect(base.same(s.color(badge.x, badge.y), p.rowBadge), "a red badge")
        base.shot(wc, "r5-dark-focus-panes")

        // Back in the list: the accent again.
        sheet.fileList.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: sheet.fileList.convert(NSPoint(x: 5, y: 3), to: nil), modifierFlags: [], timestamp: 0, windowNumber: sw.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(sheet.fileList.hasListFocus)
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }

    /// Row 129: the ruler in dark: an 11-wide knob #A2A2A2 over the whole
    /// track when the file fits, the marks over it at (line − 0.5) ÷ lines
    /// of the track, conflicts #FDB9B5, the clean change #D4D4D4.
    @Test func rulerKnobAndMarks() async throws {
        let r = try Repo("r5-ruler")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: true)
        let sheet = try await base.openSheet(wc)
        let p = MergeSheetPalette.dark
        #expect(p.rulerKnob == 0xA2A2A2 && p.rulerConflict == 0xFDB9B5 && p.rulerClean == 0xD4D4D4)
        let ruler = sheet.ruler
        let knob = try #require(ruler.knobRect)
        #expect(knob.minX == 1 && knob.width == 11 && knob.minY == 3 && abs(knob.maxY - (ruler.bounds.height - 3)) < 0.01, "\(knob)")
        // Lines of the right pane where each change starts.
        let rows = sheet.canvas.rows
        // Counted as an editor counts them: the empty line after the final
        // line break too (§15.3).
        let lines = rows.compactMap(\.right).count + 1
        let starts = rows.filter(\.isFirstOfHunk).compactMap { $0.right?.number }
        #expect(sheet.ruler.marks.map(\.position) == starts.map { (Double($0) - 0.5) / Double(lines) })
        let s = try base.snapshot(wc)
        let rr = base.windowRect(ruler, ruler.bounds, wc)
        #expect(base.same(s.color(rr.minX + 6, rr.minY + 20), p.rulerKnob ?? 0), "the knob")
        for m in ruler.marks {
            let y = rr.minY + ruler.markRect(m.position).minY + 0.5
            #expect(base.same(s.color(rr.minX + 6, y), m.isConflict ? p.rulerConflict : p.rulerClean), "mark at \(y)")
        }
        // Light shows no knob (§4.4).
        ruler.appearance = NSAppearance(named: .aqua)
        #expect(ruler.knobRect == nil)
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await wc.sourceControl.idle(); return wc.sourceControl.mergeOverlay == nil }
    }

    // MARK: Row 130: accessibility from outside the view tree

    /// Kept for the suites that call it: the process-wide offscreen guard
    /// (`CYcodeTestOffscreen`, README "Nothing on screen") already keeps
    /// every window where it is put, off every display, for the whole run.
    enum Offscreen {
        static func on() {}
        static func off() {}
    }

    /// The outside tool: a Swift script run by `xcrun swift` in a process
    /// of its own. It follows the capture tool's driver (§13.2): from the
    /// application element of `pid`, breadth first through the children
    /// attribute only (depth 40, at most 30,000 elements, 3-second
    /// messaging timeout), the first element whose role and title attribute
    /// match (case ignored, "..." read as "…"). It prints one line of
    /// `key=value` pairs: the roles on the path, enabled, the actions, the
    /// frame (top-left screen space), whether the system-wide hit test (or,
    /// off every display, the application's) at its centre lands on it or
    /// inside it, whether its parent names it the default or the cancel
    /// button, and with `press` the press's result and time.
    static let driver = #"""
    import ApplicationServices
    import Foundation
    let args = CommandLine.arguments
    let pid = pid_t(args[1])!, role = args[2], title = args[3], press = args.count > 4 && args[4] == "press"
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    func norm(_ s: String) -> String { s.replacingOccurrences(of: "...", with: "\u{2026}").lowercased() }
    var queue: [(AXUIElement, Int, [String])] = [(app, 0, [])]
    var seen = 0
    var found: (AXUIElement, [String])?
    while !queue.isEmpty, seen < 30_000, found == nil {
        let (e, depth, path) = queue.removeFirst()
        seen += 1
        let r = attr(e, kAXRoleAttribute) as? String ?? ""
        if r == role, let t = attr(e, kAXTitleAttribute) as? String, norm(t) == norm(title) { found = (e, path + [r]); break }
        guard depth < 40, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        for k in kids { queue.append((k, depth + 1, path + [r])) }
    }
    guard let (e, path) = found else { print("found=0 seen=\(seen)"); exit(0) }
    var out = ["found=1", "path=" + path.joined(separator: ">"), "seen=\(seen)"]
    out.append("enabled=\((attr(e, kAXEnabledAttribute) as? Bool) == true ? 1 : 0)")
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    out.append("actions=" + ((names as? [String]) ?? []).joined(separator: ","))
    var pt = CGPoint.zero, sz = CGSize.zero
    if let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) {
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
    }
    out.append("frame=\(pt.x),\(pt.y),\(sz.width),\(sz.height)")
    func lands(_ hit: AXUIElement?) -> Bool {
        var x = hit, hops = 0
        while let h = x, hops < 10 {
            if CFEqual(h, e) { return true }
            var p: pid_t = 0
            AXUIElementGetPid(h, &p)
            if p != pid { return false }
            x = attr(h, kAXParentAttribute).map { $0 as! AXUIElement }
            hops += 1
        }
        return false
    }
    var hit: AXUIElement?
    let cx = Float(pt.x + sz.width / 2), cy = Float(pt.y + sz.height / 2)
    let systemHit = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), cx, cy, &hit) == .success && lands(hit)
    hit = nil
    let appHit = AXUIElementCopyElementAtPosition(app, cx, cy, &hit) == .success && lands(hit)
    out.append("systemHit=\(systemHit ? 1 : 0)")
    out.append("appHit=\(appHit ? 1 : 0)")
    if let parent = attr(e, kAXParentAttribute).map({ $0 as! AXUIElement }) {
        out.append("parentRole=\(attr(parent, kAXRoleAttribute) as? String ?? "")")
        out.append("isDefault=\(attr(parent, kAXDefaultButtonAttribute).map { CFEqual($0, e) } == true ? 1 : 0)")
        out.append("isCancel=\(attr(parent, kAXCancelButtonAttribute).map { CFEqual($0, e) } == true ? 1 : 0)")
    }
    if press {
        let t0 = Date()
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        out.append("press=\(r.rawValue)")
        out.append("pressTime=\(Date().timeIntervalSince(t0))")
    }
    print(out.joined(separator: " "))
    """#

    /// Runs the driver against this process and returns its answer, turning
    /// the main run loop meanwhile (accessibility requests are served on it).
    func drive(_ role: String, _ title: String, press: Bool = false, in dir: URL) throws -> [String: String] {
        let script = dir.appendingPathComponent("ax-driver.swift")
        if !FileManager.default.fileExists(atPath: script.path) { try Self.driver.write(to: script, atomically: true, encoding: .utf8) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["swift", script.path, "\(getpid())", role, title] + (press ? ["press"] : [])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if p.isRunning { p.terminate() }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("MergeSheetR5UITests: driver \(title): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        var out: [String: String] = [:]
        for pair in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// AppKit's screen rectangle in the accessibility API's top-left space.
    func topLeft(_ r: NSRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// AppKit's own accessibility hit test (what the window serves once the
    /// window server has found it) at the centre of `button`: the button,
    /// or an element whose nearest button ancestor is it.
    func appKitHitTest(_ button: NSView) -> Bool {
        guard let w = button.window else { return false }
        let r = w.convertToScreen(button.convert(button.bounds, to: nil))
        var e: Any? = w.accessibilityHitTest(NSPoint(x: r.midX, y: r.midY))
        for _ in 0..<10 {
            guard let x = e else { return false }
            if (x as AnyObject) === button { return true }
            e = (x as? NSAccessibilityProtocol)?.accessibilityParent()
        }
        return false
    }

    /// The accessibility frame covers the drawn rectangle, at most 1.5
    /// points larger on each side (AppKit adds a point around a control).
    func covers(_ ax: NSRect, _ drawn: NSRect) -> Bool {
        ax.insetBy(dx: -0.01, dy: -0.01).contains(drawn) && ax.insetBy(dx: 1.5, dy: 1.5).width <= drawn.width + 0.01
            && ax.insetBy(dx: 1.5, dy: 1.5).height <= drawn.height + 0.01
    }

    func axFrame(_ s: String?) -> NSRect? {
        guard let v = s?.split(separator: ",").compactMap({ Double($0) }), v.count == 4 else { return nil }
        return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    /// Row 130: with the alert up in a running window, an outside process
    /// following the driver's search from the application element finds
    /// exactly the drawn Merge button (role button, title "Merge", enabled,
    /// the press action, its frame on the drawn button, the hit test at its
    /// centre in this app), the alert names Merge its default and Cancel its
    /// cancel button, and its press opens the merge sheet, whose Cancel and
    /// Merge are found the same way.
    @Test func alertAndSheetButtonsFromAnotherProcess() async throws {
        guard AXIsProcessTrusted() else {
            print("MergeSheetR5UITests: not trusted for accessibility; the outside-in test needs it")
            return
        }
        let r = try Repo("r5-ax")
        defer { r.cleanUp() }
        let wc = try await r.window(dark: true)
        let win = try #require(wc.window)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // The accessibility server starts with the application's launch.
        NSApp.finishLaunching()
        Offscreen.on()
        defer { Offscreen.off() }
        win.isExcludedFromWindowsMenu = true
        win.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: false)
        win.orderBack(nil)
        defer { win.orderOut(nil) }
        // Never on a display.
        try #require(win.frame.origin == NSPoint(x: -6000, y: -6000), "the window must stay off every display")
        try #require(!NSScreen.screens.contains { $0.frame.intersects(win.frame) })

        let scm = wc.sourceControl
        let alert = try #require(scm.presentMergeAlert(branch: "feature"))
        win.contentView?.superview?.layoutSubtreeIfNeeded()
        let m = try drive(kAXButtonRole, "Merge", in: r.folder)
        let c = try drive(kAXButtonRole, "Cancel", in: r.folder)
        #expect(m["found"] == "1", "Merge found from the application element through children only")
        let path = (m["path"] ?? "").split(separator: ">").map(String.init)
        #expect(path.first == kAXApplicationRole && path.contains(kAXWindowRole) && path.dropLast().last == kAXSheetRole, "\(path)")
        #expect(path.count <= 5, "application → window → sheet → button, at most one more level: \(path)")
        #expect(m["enabled"] == "1" && (m["actions"] ?? "").split(separator: ",").contains(Substring(kAXPressAction)))
        let drawn = topLeft(win.convertToScreen(alert.mergeButton.convert(alert.mergeButton.bounds, to: nil)))
        let f = try #require(axFrame(m["frame"]))
        #expect(covers(f, drawn), "\(f) against \(drawn)")
        // Off every display the window server finds no window at the
        // button's centre, so the outside hit test cannot reach the app
        // there; AppKit's hit test inside the window must land on it.
        #expect(m["systemHit"] == "1" || m["appHit"] == "1" || appKitHitTest(alert.mergeButton), "hit test at the button's centre")
        #expect(appKitHitTest(alert.mergeButton) && appKitHitTest(alert.cancelButton))
        #expect(m["parentRole"] == kAXSheetRole && m["isDefault"] == "1" && c["isCancel"] == "1")

        // The press opens the merge sheet, within the 3-second timeout.
        let pressed = try drive(kAXButtonRole, "Merge", press: true, in: r.folder)
        #expect(pressed["press"] == "0" && (Double(pressed["pressTime"] ?? "9") ?? 9) < 3, "\(pressed)")
        await waitFor("source control") { await scm.idle() }
        let sheet = try #require(scm.mergeSheet)
        await waitFor("the merge sheet") { await sheet.idle() }
        let sw = try #require(scm.mergeOverlay?.sheetWindow)
        #expect(sw.isVisible && sw.parent === win && !NSScreen.screens.contains { $0.frame.intersects(sw.frame) })

        // The sheet's Cancel and Merge, found the same way.
        let sc = try drive(kAXButtonRole, "Cancel", in: r.folder)
        let sm = try drive(kAXButtonRole, "Merge", in: r.folder)
        #expect(sc["found"] == "1" && sm["found"] == "1")
        #expect(sc["parentRole"] == kAXSheetRole && sc["isCancel"] == "1" && sm["isDefault"] == "1", "\(sc) \(sm)")
        #expect(sm["enabled"] == "0", "Merge disabled while a conflict is undecided")
        let drawnMerge = topLeft(sw.convertToScreen(sheet.mergeButton.convert(sheet.mergeButton.bounds, to: nil)))
        #expect(axFrame(sm["frame"]).map { covers($0, drawnMerge) } == true, "\(sm["frame"] ?? "") \(drawnMerge)")
        #expect(sm["systemHit"] == "1" || sm["appHit"] == "1" || appKitHitTest(sheet.mergeButton))
        #expect(appKitHitTest(sheet.mergeButton) && appKitHitTest(sheet.cancelButton))
        // The sheet's drawn controls too: a token, the Flat segment.
        func hitLabel(_ v: NSView, _ r: NSRect) -> String? {
            let s = sw.convertToScreen(v.convert(r, to: nil))
            return (sw.accessibilityHitTest(NSPoint(x: s.midX, y: s.midY)) as? NSAccessibilityProtocol)?.accessibilityLabel()
        }
        let token = try #require(sheet.canvas.tokenRect(forHunk: 0))
        #expect(hitLabel(sheet.canvas, token)?.hasPrefix("Change 1 of 3") == true, "\(hitLabel(sheet.canvas, token) ?? "nil")")
        #expect(hitLabel(sheet.fileList, sheet.fileList.segmentFrames.flat) == "Flat")

        // Out of the window server before Cancel (which asks only on screen).
        win.orderOut(nil)
        sheet.cancelButton.performClick(nil)
        await eventually("the abort") { await scm.idle(); return scm.mergeOverlay == nil }
    }
}
