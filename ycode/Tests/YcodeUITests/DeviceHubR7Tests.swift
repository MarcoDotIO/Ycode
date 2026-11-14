import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 7 on the device window (`specs/ide/device-hub.md` §15,
/// checklist rows 170–175), in the round's setting: the hub at 1100 × 800
/// and 1400 × 900, the sidebar and the inspector hidden, dark, the simctl
/// iPhone 17 and iPad Air 11-inch (M4) Ycode does not run. Zoom to Fit fits
/// each one's silhouette to the free height (iPhone 324.5 × 674.5 and
/// 371.5 × 772.5, iPad 485.5 × 671 and 556 × 769); the iPad has its tablet
/// outline; the subtitle says iPadOS; the toolbar's resize toggle is the
/// outline layout glyph with no separator, the compact-window arrows rise,
/// no tab is selected with the inspector hidden; the capsules' glyphs are at
/// full contrast with the reason in their tooltips. With
/// `YCODE_B7_SHOTS=<dir>` it saves pictures of each step (offscreen).
@MainActor
@Suite(.serialized) struct DeviceHubR7Tests {
    static let iPhone17 = DeviceRow(name: "iPhone 17", identifier: "UDID-SIMCTL-IPHONE17", platform: "iOS", osVersion: "27.2",
                                    state: "Booted", model: "iPhone 17", isAvailable: true)
    static let iPadAir = DeviceRow(name: "iPad Air 11-inch (M4)", identifier: "UDID-SIMCTL-IPADAIR", platform: "iOS", osVersion: "27.2",
                                   state: "Booted", model: "iPad Air 11-inch (M4)", isAvailable: true)

    func makeHub(_ t: TestDefaults, _ row: DeviceRow, width: CGFloat = 1100, height: CGFloat = 800) throws -> (DevicesController, NSWindow) {
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [Self.iPhone17, Self.iPadAir, DeviceHubR5Tests.simctlDuo])
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
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == row.identifier }))
        hub.splitViewItems[0].isCollapsed = true
        hub.splitViewItems[2].isCollapsed = true
        w.contentView?.layoutSubtreeIfNeeded()
        return (hub, w)
    }

    func topLeft(_ r: NSRect, of v: NSView, in w: NSWindow) -> NSRect {
        let c = w.contentView!
        let inWindow = v.convert(r, to: c)
        return c.isFlipped ? inWindow : NSRect(x: inWindow.minX, y: c.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// The body's rectangle in the window's top-left coordinates.
    func body(_ hub: DevicesController, _ w: NSWindow) -> NSRect {
        let f = hub.canvas.frameView, b = f.geometry.body, s = f.scale
        return topLeft(NSRect(x: b.minX * s, y: b.minY * s, width: b.width * s, height: b.height * s), of: f, in: w)
    }

    static func shot(_ w: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B7_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    static func record(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["YCODE_B7_VALUES"] else { return }
        let data = Data((line + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    // MARK: Rows 170–172

    @Test func everyDeviceFitsTheFreeHeight() throws {
        let cases: [(DeviceRow, CGFloat, CGFloat, Double, Double, String)] = [
            (Self.iPhone17, 1100, 800, 324.5, 674.5, "06-iphone17-1100"), (Self.iPhone17, 1400, 900, 371.5, 772.5, "07-iphone17-1400"),
            (Self.iPadAir, 1100, 800, 485.5, 671, "08-ipad-1100"), (Self.iPadAir, 1400, 900, 556, 769, "09-ipad-1400"),
        ]
        for (row, ww, wh, bw, bh, name) in cases {
            let t = TestDefaults("hub-r7-\(name)")
            defer { t.remove() }
            let (hub, w) = try makeHub(t, row, width: ww, height: wh)
            defer { w.close() }
            #expect(hub.canvas.zoom == .fit && !hub.inspectorShown)
            let b = body(hub, w)
            #expect(abs(b.width - bw) <= 1.5 && abs(b.height - bh) <= 1.5, "\(name): body \(b)")
            // Centred between y 52 and H − 44 and on the window.
            #expect(abs(b.midY - (52 + (wh - 96) / 2)) <= 1.5 && abs(b.midX - ww / 2) <= 1.5, "\(name): centre \(b.midX), \(b.midY)")
            let screen = topLeft(hub.canvas.frameView.screen.frame, of: hub.canvas.frameView, in: w)
            Self.record("\(name): scale \(hub.canvas.frameView.scale), body \(b), screen \(screen)")
            Self.shot(w, "mac-dark-device-\(name).png")
        }
    }

    @Test func theIPadHasItsTabletOutlineDrawn() throws {
        let t = TestDefaults("hub-r7-ipad-band")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, Self.iPadAir)
        defer { w.close() }
        let f = hub.canvas.frameView
        f.layoutSubtreeIfNeeded()
        #expect(f.geometry.body.size == CGSize(width: 940, height: 1300))
        let rep = try #require(f.bitmapImageRepForCachingDisplay(in: f.bounds)?.retagging(with: .sRGB))
        f.cacheDisplay(in: f.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / f.bounds.width
        func sample(_ x: CGFloat, _ y: CGFloat) -> UInt32 {
            guard let c = rep.colorAt(x: Int(x * k), y: Int(y * k)), c.numberOfComponents >= 3 else { return 0xFFFF_FFFF }
            return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
        }
        // Within a few levels per channel (the 1-point line is anti-aliased at its edges).
        func near(_ a: UInt32, _ b: UInt32, _ tol: Int = 14) -> Bool {
            [16, 8, 0].allSatisfy { abs(Int((a >> UInt32($0)) & 0xFF) - Int((b >> UInt32($0)) & 0xFF)) <= tol }
        }
        let s = f.scale, g = f.geometry, midY = g.body.midY * s
        typealias P = DeviceFrameGeometry.Palette
        // Left side, outside in: the light line, the #2C2C2C band, black (26.5 wide at 1100).
        #expect(near(sample((g.body.minX + 1) * s, midY), P.edge), "\(String(sample((g.body.minX + 1) * s, midY), radix: 16))")
        #expect(near(sample((g.body.minX + 4) * s, midY), P.greyBand), "\(String(sample((g.body.minX + 4) * s, midY), radix: 16))")
        #expect(sample((g.body.minX + 30) * s, midY) == P.inner)
        // The volume strips flush with the right edge, lighter.
        let up = try #require(g.buttons.first { $0.kind == .volumeUp }).rect
        #expect(near(sample((up.maxX - 1) * s, up.midY * s), P.flushButton), "\(String(sample((up.maxX - 1) * s, up.midY * s), radix: 16))")
    }

    // MARK: Row 173

    @Test func theSubtitleSaysIPadOS() throws {
        let t = TestDefaults("hub-r7-subtitle")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, Self.iPadAir)
        defer { w.close() }
        #expect(w.title == "iPad Air 11-inch (M4)" && w.subtitle == "iPadOS 27.2")
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == Self.iPhone17.identifier }))
        #expect(w.subtitle == "iOS 27.2")
    }

    // MARK: Row 174

    @Test func theToolbarsGlyphsAndStates() throws {
        let t = TestDefaults("hub-r7-toolbar")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, Self.iPadAir)
        defer { w.close() }
        let tb = try #require(w.toolbar)
        tb.validateVisibleItems()
        func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? { tb.items.first { $0.itemIdentifier == id } }
        // Capture Keyboard and the resize toggle: plain items (no segmented
        // separator), the toggle Ycode's layout glyph, dimmed.
        let capture = try #require(item(DeviceHubToolbar.captureKeyboard)), resize = try #require(item(DeviceHubToolbar.resize))
        #expect(!(capture is NSToolbarItemGroup) && !(resize is NSToolbarItemGroup))
        let order = tb.items.map(\.itemIdentifier)
        #expect(order.firstIndex(of: DeviceHubToolbar.resize) == order.firstIndex(of: DeviceHubToolbar.captureKeyboard).map { $0 + 1 })
        #expect(resize.image?.isTemplate == true && resize.image?.accessibilityDescription == "Enter resize mode" && !resize.isEnabled)
        // The compact-window button: Ycode's arrows on the rising diagonal.
        let open = try #require(item(DeviceHubToolbar.open))
        #expect(open.image?.isTemplate == true && open.image?.accessibilityDescription == "Open in New Window")
        // The inspector hidden: no tab selected.
        let tabs = try #require(item(DeviceHubToolbar.tabs) as? NSToolbarItemGroup)
        #expect(tabs.subitems.indices.allSatisfy { !tabs.isSelected(at: $0) }, "selected \(tabs.selectedIndex)")
        // Shown again (a tab chosen): that tab selected.
        hub.selectInspectorTab(.settings)
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(hub.inspectorShown && tabs.selectedIndex == 0)
        hub.splitViewItems[2].isCollapsed = true
        #expect(tabs.subitems.indices.allSatisfy { !tabs.isSelected(at: $0) })
        // Capture Keyboard off (no live device): drawn plain.
        if #available(macOS 26.0, *) { #expect(capture.style == .plain) }
    }

    // MARK: Row 175

    @Test func theCapsulesGlyphsAreAtFullContrast() throws {
        let t = TestDefaults("hub-r7-capsules")
        defer { t.remove() }
        let (hub, w) = try makeHub(t, Self.iPadAir)
        defer { w.close() }
        let controls = hub.canvas.controls
        #expect(hub.canvas.showsDisabledControls && !controls.isHidden)
        #expect(controls.groups == [[.home, .screenshot, .recordScreen], [.rotateLeft]])
        for c in controls.groups.joined() {
            let b = try #require(controls.button(for: c))
            #expect(b.isEnabled, "\(c)")
            #expect(b.toolTip?.hasSuffix(DeviceCanvasView.notOperatedReason) == true, "\(c): \(b.toolTip ?? "")")
        }
        // Home is Ycode's grid of rounded squares.
        #expect(controls.button(for: .home)?.image?.accessibilityDescription == "Home" && controls.button(for: .home)?.image?.isTemplate == true)
        // A press says why nothing happens.
        hub.canvas.perform(.home)
        #expect(hub.canvas.bannerText == DeviceCanvasView.notOperatedReason)
        Self.shot(w, "mac-dark-device-09-ipad-capsules.png")
    }
}
