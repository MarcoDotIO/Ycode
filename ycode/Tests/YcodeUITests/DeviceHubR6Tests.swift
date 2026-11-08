import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 6 on the device window (`specs/ide/device-hub.md` §14,
/// checklist rows 154–156), in the round's setting: the hub at 1100 × 800,
/// the sidebar hidden, the Settings inspector shown, light, the simctl
/// iPhone Duo in its closed posture. Zoom to Fit draws the cover at about
/// 0.53 (screen 248 × 360, frame 274 × 379.5, 161 above and 163 below);
/// the band is two-tone with the hinge-side step and the cover's buttons;
/// the Zoom to Fit segment is Ycode's magnifier with four arrowheads.
@MainActor
@Suite(.serialized) struct DeviceHubR6Tests {
    func makeHub(_ t: TestDefaults) throws -> (DevicesController, NSWindow) {
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [DeviceHubR5Tests.simctlDuo, DeviceHubR3Tests.other])
        hub.defaults = t.defaults
        let w = hub.makeWindow()
        w.isExcludedFromWindowsMenu = true
        w.appearance = NSAppearance(named: .aqua)
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        w.setContentSize(NSSize(width: 1100, height: 800))
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        w.contentView?.layoutSubtreeIfNeeded()
        hub.placeFirstDividers()
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == DeviceHubR5Tests.simctlDuo.identifier }))
        hub.splitViewItems[0].isCollapsed = true
        w.contentView?.layoutSubtreeIfNeeded()
        return (hub, w)
    }

    /// A rectangle of `v` in the content's top-left coordinates.
    func topLeft(_ r: NSRect, of v: NSView, in w: NSWindow) -> NSRect {
        let c = w.contentView!
        let inWindow = v.convert(r, to: c)
        return c.isFlipped ? inWindow : NSRect(x: inWindow.minX, y: c.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    @Test func zoomToFitDrawsTheCoverAtTheMeasuredScale() throws {
        let t = TestDefaults("hub-r6-scale")
        defer { t.remove() }
        let (hub, w) = try makeHub(t)
        defer { w.close() }
        let canvas = hub.canvas
        #expect(canvas.zoom == .fit && !hub.sidebarShown)
        let f = canvas.frameView, g = f.geometry
        #expect(g.hingeStep != nil, "the cover, closed")
        // Row 154: about 0.53 (the reference 0.532 across, 0.531 down).
        #expect(abs(Double(f.scale) - 0.531) < 0.004, "scale \(f.scale)")
        let screen = topLeft(f.screen.frame, of: f, in: w)
        #expect(abs(screen.width - 248) <= 1.5 && abs(screen.height - 360) <= 1.5, "screen \(screen)")
        let s = f.scale
        let box = g.outerBox
        let outer = topLeft(NSRect(x: box.minX * s, y: box.minY * s, width: box.width * s, height: box.height * s), of: f, in: w)
        #expect(abs(outer.width - 274) <= 2 && abs(outer.height - 379.5) <= 2, "frame \(outer)")
        // Centred between the toolbar's bottom (52) and the capsules' top.
        let capsulesTop = topLeft(canvas.controls.bounds, of: canvas.controls, in: w).minY
        #expect(abs(capsulesTop - 755.5) <= 1, "capsules at \(capsulesTop)")
        #expect(abs(outer.minY - 52 - 161) <= 2.5 && abs(capsulesTop - outer.maxY - 163) <= 2.5,
                "\(outer.minY - 52) above, \(capsulesTop - outer.maxY) below")
        // The body (with its step) centred on the canvas; the screen x 289–537, y 224–584.
        let canvasRect = topLeft(canvas.bounds, of: canvas, in: w)
        let body = g.body.union(g.hingeStep!)
        let bodyRect = topLeft(NSRect(x: body.minX * s, y: body.minY * s, width: body.width * s, height: body.height * s), of: f, in: w)
        #expect(abs(bodyRect.midX - canvasRect.midX) <= 1, "body \(bodyRect) canvas \(canvasRect)")
        #expect(abs(screen.minX - 289) <= 2.5 && abs(screen.minY - 224) <= 2.5, "screen \(screen)")
        Self.record("1100 × 800, inspector shown: scale \(f.scale), screen \(screen), frame \(outer)")
    }

    @Test func zoomToFitFollowsTheWindow() throws {
        let t = TestDefaults("hub-r6-resize")
        defer { t.remove() }
        let (hub, w) = try makeHub(t)
        defer { w.close() }
        let canvas = hub.canvas, f = canvas.frameView
        let at1100 = f.scale
        w.setContentSize(NSSize(width: 1400, height: 1000))
        w.contentView?.layoutSubtreeIfNeeded()
        let free = canvas.deviceArea.size
        #expect(abs(Double(f.scale) - DeviceZoom.hubFit(frame: f.geometry.outerBox.size, in: free)) < 1e-6)
        #expect(f.scale > at1100)
        Self.record("1400 × 1000, inspector shown: canvas \(free), scale \(f.scale)")
        // The inspector hidden at 1100 × 800: a wider canvas, the height still decides.
        w.setContentSize(NSSize(width: 1100, height: 800))
        hub.splitViewItems.last?.isCollapsed = true
        w.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(Double(f.scale) - DeviceZoom.hubFit(frame: f.geometry.outerBox.size, in: canvas.deviceArea.size)) < 1e-6)
        #expect(abs(Double(f.scale) - Double(at1100)) < 0.005)
        Self.record("1100 × 800, inspector hidden: canvas \(canvas.deviceArea.size), scale \(f.scale)")
        // Zoom In steps from the fitted scale.
        canvas.zoomIn()
        if case .scale(let z) = canvas.zoom { #expect(z > Double(at1100)) } else { Issue.record("zoom \(canvas.zoom)") }
    }

    @Test func theBandIsTwoToneWithTheHingeStep() throws {
        let t = TestDefaults("hub-r6-band")
        defer { t.remove() }
        let (hub, w) = try makeHub(t)
        defer { w.close() }
        let f = hub.canvas.frameView
        f.layoutSubtreeIfNeeded()
        let rep = try #require(f.bitmapImageRepForCachingDisplay(in: f.bounds)?.retagging(with: .sRGB))
        f.cacheDisplay(in: f.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / f.bounds.width
        func sample(_ x: CGFloat, _ y: CGFloat) -> UInt32 {
            // The bitmap's rows run top down, as the flipped view's.
            // The pixels as stored (the layers' sRGB fills, written untagged).
            guard let c = rep.colorAt(x: Int(x * k), y: Int(y * k)), c.numberOfComponents >= 3 else { return 0xFFFF_FFFF }
            return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
        }
        func hex(_ v: UInt32) -> String { String(v, radix: 16) }
        let sc = f.screen.frame, midY = sc.midY
        typealias P = DeviceFrameGeometry.Palette
        // Right side: 4.5 of black, then about 4 of mid grey.
        #expect(sample(sc.maxX + 2, midY) == P.inner, "\(hex(sample(sc.maxX + 2, midY)))")
        #expect(sample(sc.maxX + 6.5, midY) == P.outer, "\(hex(sample(sc.maxX + 6.5, midY))) \(hex(sample(sc.maxX + 5, midY))) \(hex(sample(sc.maxX + 7.5, midY)))")
        // Hinge side: black, the band's grey, then the darker step out to 14.5.
        #expect(sample(sc.minX - 2, midY) == P.inner)
        #expect(sample(sc.minX - 12, midY) == P.step, "\(hex(sample(sc.minX - 12, midY)))")
        // The step stops short of the top: above it, at the cover's band, no step.
        let s = f.scale, step = try #require(f.geometry.hingeStep)
        #expect(sample(step.minX * s + 2, step.minY * s - 3) != P.step)
        // The cover's buttons: two bars on the top edge, one on the right.
        let up = f.geometry.buttons[0].rect
        #expect(sample(up.midX * s, up.minY * s + 1) == P.button, "\(hex(sample(up.midX * s, up.minY * s + 1)))")
        #expect(f.geometry.buttons.map(\.kind) == [.volumeUp, .volumeDown, .side])
        if let dir = ProcessInfo.processInfo.environment["YCODE_B6_SHOTS"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent("mac-light-devices-duo-r6.png"))
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent("mac-dark-devices-duo-r6.png"))
        }
    }

    @Test func zoomToFitIsYcodesMagnifierWithFourArrowheads() throws {
        let t = TestDefaults("hub-r6-glyph")
        defer { t.remove() }
        let (_, w) = try makeHub(t)
        defer { w.close() }
        let group = try #require(w.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup }.first { $0.subitems.count == 4 })
        #expect(group.subitems.map(\.label) == ["Zoom Out", "Zoom to Fit", "Zoom To Actual Size", "Zoom In"])
        let fit = try #require(group.subitems[1].image)
        #expect(fit.isTemplate && fit.accessibilityDescription == "Zoom to Fit")
        // The size of the other magnifiers.
        let other = try #require(group.subitems[0].image)
        #expect(fit.size == NSSize(width: 16, height: 15) && abs(fit.size.width - other.size.width) <= 1 && abs(fit.size.height - other.size.height) <= 1,
                "\(fit.size) \(other.size)")
        // Zoom to Fit is the selected segment.
        #expect(group.selectedIndex == 1)
        // Ink in each of the lens's four diagonal corners (the arrowheads).
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = fit.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fit.draw(in: NSRect(origin: .zero, size: fit.size))
        NSGraphicsContext.restoreGraphicsState()
        let c = DeviceControlGlyphs.zoomLensCentre, tip = DeviceControlGlyphs.zoomArrowTip - 0.6
        for (dx, dy) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
            let x = 8 + c.x + dx * tip / 2.0.squareRoot(), y = 7.5 + c.y + dy * tip / 2.0.squareRoot()
            let a = rep.colorAt(x: Int(x * 4), y: Int(y * 4))?.alphaComponent ?? 0
            #expect(a > 0.5, "arrowhead toward (\(dx), \(dy)) at \(x), \(y): \(a)")
        }
        // The lens's centre is empty.
        #expect((rep.colorAt(x: Int((8 + c.x) * 4), y: Int((7.5 + c.y) * 4))?.alphaComponent ?? 1) < 0.2)
    }

    /// Values for the report (`YCODE_B6_VALUES=<file>`).
    static func record(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["YCODE_B6_VALUES"] else { return }
        let data = Data((line + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
