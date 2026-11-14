import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 9, group D, on the macOS hub (`specs/ide/fidelity-council.md`
/// "Round 9", rows 231–235; `specs/ide/device-hub.md` §4.2, §4.4, §5.1, §5.2,
/// §15.2), with the round's watch: an Apple Watch Series 12 (46mm) on
/// watchOS 27.2, dark. Zoom to Fit fits the watch, crown included, in the
/// stage (about 549 × 638 at 1100 × 800 with the inspector, 629 × 732 at
/// 1400 × 900 without) with no scroll bars; a watch shown for the first time
/// opens at Physical Size; the sidebar scrolls the selected row into view;
/// the watch's capsule holds 4 buttons; the "Available" header has no
/// chevron, its ink at x 16 in #737374. Offscreen; `YCODE_B9_SHOTS=<dir>`
/// saves pictures and `YCODE_B9_VALUES=<file>` appends the measured values.
@MainActor
@Suite(.serialized) struct DeviceHubR9Tests {
    static let watch = DeviceRow(name: "ycode-test-council-watch", identifier: "UDID-COUNCIL-WATCH", platform: "watchOS", osVersion: "27.2",
                                 state: "Booted", model: "Apple Watch Series 12 (46mm)", isAvailable: true)
    let r7 = DeviceHubR7Tests()

    /// Other simulators before the watch, so a long list puts it far down.
    static func others(_ n: Int) -> [DeviceRow] {
        (0..<n).map { i in
            DeviceRow(name: String(format: "iPhone %02d", i), identifier: "UDID-OTHER-\(i)", platform: "iOS", osVersion: "27.2",
                      state: "Shutdown", model: "iPhone 17", isAvailable: true)
        }
    }

    func makeHub(_ t: TestDefaults, rows: [DeviceRow], width: CGFloat, height: CGFloat, sidebar: Bool, inspector: Bool,
                 restore: Bool = false) throws -> (DevicesController, NSWindow) {
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: rows)
        hub.defaults = t.defaults
        let w = hub.makeWindow()
        w.isExcludedFromWindowsMenu = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        w.setContentSize(NSSize(width: width, height: height))
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        w.contentView?.layoutSubtreeIfNeeded()
        hub.placeFirstDividers()
        if restore { hub.restoreState() } else { hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == Self.watch.identifier })) }
        hub.splitViewItems[0].isCollapsed = !sidebar
        hub.splitViewItems[2].isCollapsed = !inspector
        w.contentView?.layoutSubtreeIfNeeded()
        hub.revealSelection()
        return (hub, w)
    }

    /// The watch's silhouette (body, crown and side button) in the window's top-left coordinates.
    func silhouette(_ hub: DevicesController, _ w: NSWindow) -> NSRect {
        let f = hub.canvas.frameView, b = f.geometry.outerBox, s = f.scale
        return r7.topLeft(NSRect(x: b.minX * s, y: b.minY * s, width: b.width * s, height: b.height * s), of: f, in: w)
    }

    static func record(_ line: String) {
        print("R9D " + line)
        guard let path = ProcessInfo.processInfo.environment["YCODE_B9_VALUES"] else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(("mac " + line + "\n").utf8))
            h.closeFile()
        }
    }

    static func shot(_ w: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B9_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    // MARK: Row 231

    @Test(arguments: [(CGFloat(1100), CGFloat(800), true, 549.0, 638.0), (1400, 900, false, 629, 732)])
    func zoomToFitFitsTheWatchCrownIncludedWithoutScrollBars(_ c: (CGFloat, CGFloat, Bool, Double, Double)) throws {
        let (ww, wh, inspector, refW, refH) = c
        let t = TestDefaults("hub-r9-fit-\(Int(ww))")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, rows: [DeviceHubR7Tests.iPhone17, Self.watch], width: ww, height: wh, sidebar: false, inspector: inspector)
        defer { w.close() }
        // The council pressed Zoom to Fit (W02, W03).
        hub.canvas.zoomToFit()
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(hub.canvas.zoom == .fit && w.subtitle == "watchOS 27.2", "\(w.subtitle)")
        let g = hub.canvas.frameView.geometry
        #expect(g.buttons.map(\.kind) == [.crown, .sideButton])
        let s = silhouette(hub, w)
        // The height is the rule's (§15.2 with the watch's box, row 231).
        #expect(abs(s.height - refH) <= 1.5, "\(Int(ww)): silhouette \(s)")
        // Inside the stage: below the toolbar, above the capsules, inside the canvas.
        let canvasWidth = ww - (inspector ? 280 : 0)
        #expect(s.minY >= 52 + 8 && s.maxY <= wh - 44.5 - 8, "\(s)")
        #expect(s.minX >= 8 && s.maxX <= canvasWidth - 8, "\(s)")
        #expect(abs((s.minY + s.maxY) / 2 - (52 + (wh - 96.5) / 2)) <= 1.5, "centred between the toolbar and the capsules: \(s)")
        // No scroll bars: the document is no larger than the clip view.
        let sv = try #require(hub.canvas.frameView.enclosingScrollView)
        let doc = try #require(sv.documentView).frame.size, clip = sv.contentView.bounds.size
        #expect(doc.width <= clip.width + 0.5 && doc.height <= clip.height + 0.5, "document \(doc) clip \(clip)")
        #expect(sv.verticalScroller?.isHidden != false || !sv.hasVerticalScroller || doc.height <= clip.height + 0.5)
        Self.record("row 231 \(Int(ww))x\(Int(wh)): silhouette \(String(format: "%.1f × %.1f", s.width, s.height)) (ref \(refW) × \(refH)), "
                    + "body \(String(format: "%.1f", Double(g.body.width) * hub.canvas.frameView.scale)) wide, y \(String(format: "%.1f–%.1f", s.minY, s.maxY)), "
                    + "document \(doc) in clip \(clip)")
        Self.shot(w, "mac-r9-231-watch-fit-\(Int(ww)).png")
    }

    // MARK: Row 232

    @Test func aWatchShownForTheFirstTimeOpensAtPhysicalSize() throws {
        let t = TestDefaults("hub-r9-opening")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, rows: [DeviceHubR7Tests.iPhone17, Self.watch], width: 1100, height: 800, sidebar: true, inspector: true)
        defer { w.close() }
        #expect(hub.canvas.zoom == .actual, "the third segment (Physical Size)")
        let group = try #require(w.toolbar?.items.first { $0.itemIdentifier == DeviceHubToolbar.zoom } as? NSToolbarItemGroup)
        #expect(group.selectedIndex == 2)
        // Physical Size: the watch at its real size on this display (2 pixels a point, 326 per inch).
        let ppi = hub.canvas.displayPointsPerInch ?? 110
        #expect(abs(hub.canvas.effectiveScale - 2.0 / 326 * ppi) < 1e-6)
        let s = silhouette(hub, w)
        Self.record("row 232: opens at segment \(group.selectedIndex) (Physical Size), silhouette \(String(format: "%.1f × %.1f", s.width, s.height)) "
                    + "at \(String(format: "%.1f", ppi)) points per inch (ref 177 × 196 on a 1x display)")
        Self.shot(w, "mac-r9-232-watch-opening.png")
        // The first showing's zoom is not the window's remembered zoom: another device shows at Zoom to Fit…
        #expect(t.defaults.string(forKey: DevicesController.zoomKey) == nil)
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == DeviceHubR7Tests.iPhone17.identifier }))
        #expect(hub.canvas.zoom == .fit && group.selectedIndex == 1)
        // …and the watch, shown again, at the window's remembered zoom.
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == Self.watch.identifier }))
        #expect(hub.canvas.zoom == .fit)
        #expect(t.defaults.stringArray(forKey: DevicesController.shownWatchesKey) == [Self.watch.identifier])
    }

    @Test func aZoomChosenOnTheFirstShowingIsRemembered() throws {
        let t = TestDefaults("hub-r9-opening-chosen")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, rows: [DeviceHubR7Tests.iPhone17, Self.watch], width: 1100, height: 800, sidebar: true, inspector: true)
        defer { w.close() }
        #expect(hub.canvas.zoom == .actual)
        hub.canvas.zoomToFit()
        #expect(t.defaults.string(forKey: DevicesController.zoomKey) == "fit")
        hub.canvas.zoomToActualSize()
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == DeviceHubR7Tests.iPhone17.identifier }))
        #expect(hub.canvas.zoom == .actual, "the person's choice is the window's zoom")
        // Other devices are not affected by a first showing: a phone keeps the window's zoom.
        let t2 = TestDefaults("hub-r9-opening-phone")
        defer { t2.remove() }
        let hub2 = DevicesController(devices: [], simulators: [DeviceHubR7Tests.iPhone17])
        hub2.defaults = t2.defaults
        _ = hub2.view
        hub2.select(row: 0)
        #expect(hub2.canvas.zoom == .fit)
    }

    // MARK: Row 233

    @Test(arguments: [false, true])
    func theSidebarScrollsTheSelectedRowIntoView(_ restore: Bool) throws {
        let t = TestDefaults("hub-r9-reveal-\(restore)")
        defer { t.remove() }
        if restore { t.defaults.set(Self.watch.identifier, forKey: DevicesController.selectionKey) }
        let (hub, w) = try makeHub(t, rows: Self.others(40) + [Self.watch], width: 1100, height: 800, sidebar: true, inspector: true,
                                   restore: restore)
        defer { w.close() }
        #expect(hub.selected?.identifier == Self.watch.identifier)
        let table = hub.table
        let i = table.selectedRow
        #expect(i >= 0 && table.numberOfRows > 30)
        let row = table.rect(ofRow: i), visible = table.visibleRect
        #expect(visible.contains(row), "row \(row) visible \(visible)")
        Self.record("row 233 (\(restore ? "window opened with it selected" : "selected")): row \(i) at y \(row.minY) in visible \(visible.minY)–\(visible.maxY)")
        if !restore { Self.shot(w, "mac-r9-233-sidebar-reveal.png") }
        // Selecting the first row again scrolls back.
        hub.select(row: 0)
        #expect(table.visibleRect.contains(table.rect(ofRow: table.selectedRow)))
    }

    // MARK: Row 234

    @Test func theWatchsCapsuleHoldsFourButtons() throws {
        let t = TestDefaults("hub-r9-capsule")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, rows: [DeviceHubR7Tests.iPhone17, Self.watch], width: 1400, height: 900, sidebar: false, inspector: false)
        defer { w.close() }
        hub.canvas.zoomToFit()
        w.contentView?.layoutSubtreeIfNeeded()
        let row = hub.canvas.controls
        #expect(row.groups == [[.digitalCrown, .sideButton, .screenshot, .recordScreen]])   // row 252
        #expect(row.capsules.count == 1)
        let cap = r7.topLeft(try #require(row.capsules.first).bounds, of: try #require(row.capsules.first), in: w)
        #expect(abs(cap.width - 142) < 0.5 && abs(cap.height - 36.5) < 0.5, "\(cap)")
        #expect(abs(cap.midX - 700) <= 1 && abs(cap.maxY - (900 - 8)) <= 0.5, "\(cap)")
        var centres: [CGFloat] = []
        for c in DeviceControlsLayout.watchGroup {
            let b = try #require(row.button(for: c))
            #expect(b.image != nil && b.isEnabled, "\(c)")
            centres.append(r7.topLeft(b.bounds, of: b, in: w).midX)
        }
        for (a, b) in zip(centres, centres.dropFirst()) { #expect(abs(b - a - 34) < 0.5) }
        #expect(row.button(for: .sideButton)?.toolTip?.hasPrefix("Side Button") == true)
        #expect(row.button(for: .digitalCrown)?.toolTip?.hasPrefix("Digital Crown") == true)
        // A device Ycode does not run says why when a hardware control is pressed.
        hub.canvas.perform(.digitalCrown)
        Self.record("row 234: one capsule \(cap.width) × \(cap.height) at x \(cap.minX), glyph centres \(centres.map { Double($0) })")
        Self.shot(w, "mac-r9-234-watch-capsule.png")
    }

    // MARK: Row 235

    @Test func theAvailableHeaderHasNoChevronAndTheReferencesGrey() throws {
        let t = TestDefaults("hub-r9-header")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, rows: [DeviceHubR7Tests.iPhone17, Self.watch], width: 1100, height: 800, sidebar: true, inspector: true)
        defer { w.close() }
        let table = hub.table
        let header = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? HubSectionHeaderView)
        #expect(header.title == "Available" && header.chevron == nil)
        #expect(!header.subviews.contains { $0 is NSImageView } && !header.subviews.contains { $0 is NSButton })
        var c = NSColor.clear
        w.appearance?.performAsCurrentDrawingAppearance { c = HubSectionHeaderView.textColor.usingColorSpace(.sRGB) ?? .clear }
        #expect(Self.hex(c) == 0x737374, "\(String(format: "%06X", Self.hex(c)))")
        // The title's ink in window points, from the header's own drawing.
        let ink = try #require(Self.ink(of: header))
        let inWindow = r7.topLeft(ink, of: header, in: w)
        #expect(abs(inWindow.minX - 16) <= 0.75, "ink \(inWindow)")
        // The capital A's top and bottom (its first 6 points of ink): cap height y 110–119.
        let capital = try #require(Self.ink(of: header, columns: ink.minX..<(ink.minX + 6)))
        let cap = r7.topLeft(capital, of: header, in: w)
        #expect(abs(cap.minY - 110) <= 1 && abs(cap.maxY - 119) <= 1.5, "A \(cap)")
        // A click still collapses and expands; collapsed, a chevron says so.
        header.mouseUp(with: try #require(Self.click(at: header)))
        let collapsed = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? HubSectionHeaderView)
        #expect(collapsed.collapsed && collapsed.chevron != nil && hub.rows.isEmpty)
        hub.toggleSection("Available")
        Self.record("row 235: \"Available\" ink x \(String(format: "%.1f", inWindow.minX)), y \(String(format: "%.1f–%.1f", inWindow.minY, inWindow.maxY)), "
                    + String(format: "#%06X", Self.hex(c)) + ", A cap y \(String(format: "%.1f–%.1f", cap.minY, cap.maxY)), no chevron")
        Self.shot(w, "mac-r9-235-available-header.png")
    }

    static func hex(_ c: NSColor) -> UInt32 {
        UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
    }

    /// The box of the pixels a view draws (alpha over 0.25), in its own points (flipped as the view is).
    static func ink(of v: NSView, columns: Range<CGFloat>? = nil) -> NSRect? {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25
                && columns.map({ $0.contains(CGFloat(x) / sx) }) ?? true {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run top down; the view's y runs as the view is flipped.
        let top = CGFloat(minY) / sy, bottom = CGFloat(maxY + 1) / sy
        let y = v.isFlipped ? top : v.bounds.height - bottom
        return NSRect(x: CGFloat(minX) / sx, y: y, width: CGFloat(maxX + 1 - minX) / sx, height: bottom - top)
    }

    static func click(at v: NSView) -> NSEvent? {
        let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: 0, windowNumber: v.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
    }
}
