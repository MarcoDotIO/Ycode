import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 10, group B, on the macOS hub (`specs/ide/fidelity-council.md`
/// "Round 10", rows 249–252), with the round's watch (Apple Watch Series 12
/// (46mm), watchOS 27.2, dark): the case at its real size (250 × 295 device
/// points, 167 × 197 at Physical Size on a 109-point-per-inch display, the
/// body 731 tall at Zoom to Fit in 1400 × 900), the case's rim, band and fade
/// to black with no visible screen edge, the crown and side button
/// rim-outlined and dark inside, and the capsule's Digital Crown first.
/// Offscreen; `YCODE_B10_SHOTS=<dir>` saves pictures and
/// `YCODE_B10_VALUES=<file>` appends the measured values.
@MainActor
@Suite(.serialized) struct DeviceHubR10Tests {
    let r9 = DeviceHubR9Tests()
    let r7 = DeviceHubR7Tests()

    static func record(_ line: String) {
        print("R10B " + line)
        guard let path = ProcessInfo.processInfo.environment["YCODE_B10_VALUES"] else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(("mac " + line + "\n").utf8))
            h.closeFile()
        }
    }

    static func shot(_ w: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B10_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// The frame view drawn into a bitmap at 1x (one pixel a view point).
    static func render(_ v: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width), pixelsHigh: Int(v.bounds.height),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    /// A pixel's grey level (the mean of its sRGB channels, 0–255) over the
    /// dark canvas (#1D1D1E: the frame view alone is drawn on nothing).
    static func grey(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, over background: Double = 0x1D) -> Double {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return -1 }
        let a = Double(c.alphaComponent)
        return Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255 * a + background * (1 - a)
    }

    // MARK: Row 249

    @Test func theWatchIsItsCasesRealSize() throws {
        let t = TestDefaults("hub-r10-size")
        defer { t.remove() }
        let (hub, w) = try r9.makeHub(t, rows: [DeviceHubR7Tests.iPhone17, DeviceHubR9Tests.watch], width: 1400, height: 900, sidebar: false,
                                      inspector: false)
        defer { w.close() }
        #expect(hub.canvas.zoom == .actual, "Physical Size first")
        let f = hub.canvas.frameView, g = f.geometry, s = f.scale
        // The case: the screen plus 21 at the sides and 23.5 at the top and bottom, the crown 13 out.
        #expect(g.body.size == CGSize(width: 250, height: 295) && g.outerBox.width == 263)
        let ppi = hub.canvas.displayPointsPerInch ?? 109
        let body = (w: Double(g.body.width) * s, h: Double(g.body.height) * s), crown = Double(g.outerBox.width) * s
        // On the round's display (109 points per inch): 169 × 197, 178 with the crown (the reference's
        // body includes about 1 point of the rim's glow each side).
        let at109 = 2.0 / 326 * 109
        #expect(abs(250 * at109 - 167.2) < 0.2 && abs(295 * at109 - 197.3) < 0.2 && abs(263 * at109 - 175.9) < 0.2)
        Self.record(String(format: "row 249 Physical Size at %.1f ppi: body %.1f × %.1f, %.1f with the crown (at 109 ppi: %.1f × %.1f, %.1f; ref 169 × 197, 178)",
                           ppi, body.w, body.h, crown, 250 * at109, 295 * at109, 263 * at109))
        Self.shot(w, "mac-r10-249-watch-physical.png")
        for (ww, wh, inspector, refH) in [(CGFloat(1400), CGFloat(900), false, 731.0), (1100, 800, true, 639)] {
            w.setContentSize(NSSize(width: ww, height: wh))
            hub.splitViewItems[2].isCollapsed = !inspector
            w.contentView?.layoutSubtreeIfNeeded()
            hub.canvas.zoomToFit()
            w.contentView?.layoutSubtreeIfNeeded()
            let k = f.scale, h = Double(g.body.height) * k
            #expect(abs(h - refH) <= 2, "\(Int(ww)): body \(h) tall")
            Self.record(String(format: "row 249 Zoom to Fit %dx%d: body %.1f × %.1f, crown %.1f out (ref body %@, crown 32 out)", Int(ww), Int(wh),
                               Double(g.body.width) * k, h, DeviceFrameGeometry.crownProtrusion * k, ww == 1400 ? "628 × 731" : "550 × 639"))
            Self.shot(w, "mac-r10-249-watch-fit-\(Int(ww)).png")
        }
    }

    // MARK: Rows 250–251

    @Test func theCaseHasASoftRimABandAndBlackToTheScreen() throws {
        let t = TestDefaults("hub-r10-case")
        defer { t.remove() }
        let (hub, w) = try r9.makeHub(t, rows: [DeviceHubR7Tests.iPhone17, DeviceHubR9Tests.watch], width: 1400, height: 900, sidebar: false,
                                      inspector: false)
        defer { w.close() }
        hub.canvas.zoomToFit()
        w.contentView?.layoutSubtreeIfNeeded()
        let f = hub.canvas.frameView, g = f.geometry, s = Double(f.scale)
        #expect(g.drawsWatchCase)
        f.layoutSubtreeIfNeeded()
        let rep = try Self.render(f)
        // Along the left side at the body's middle, from the outer edge inwards (view points = pixels).
        let y = Int((Double(g.body.midY) * s).rounded()), x0 = Double(g.body.minX) * s
        let profile = (0..<Int(20 * s)).map { Self.grey(rep, Int(x0) + $0, y) }
        let peak = try #require(profile.indices.max { profile[$0] < profile[$1] })
        // The rim's core peaks about 3.6 device points in at about #5C.
        #expect(abs(Double(peak) / s - 3.6) <= 1.2, "peak at \(Double(peak) / s) device points")
        #expect(abs(profile[peak] - 0x5C) <= 6, "peak \(profile[peak])")
        // The band #1F about 7 in; black from about 12.4 in to the screen.
        #expect(abs(profile[Int(7.4 * s)] - 0x1F) <= 4, "band \(profile[Int(7.4 * s)])")
        #expect(profile[Int(13 * s)] <= 2 && profile[Int(19 * s)] <= 2, "black \(profile[Int(13 * s)]) \(profile[Int(19 * s)])")
        // The screen's corner is not outlined: the case is black where it meets the screen.
        let sx = Int((Double(g.screen.minX) * s).rounded()) - 2
        #expect(Self.grey(rep, sx, y) <= 2, "next to the screen \(Self.grey(rep, sx, y))")
        Self.record("row 250 Zoom to Fit 1400x900, the left side from the outer edge (grey per point): "
                    + profile.prefix(Int(14 * s)).map { String(format: "%.0f", $0) }.joined(separator: " "))
        // Row 251: the crown dark inside, with ridges on its outer part; the side button rim-outlined and dark inside.
        let crown = try #require(g.buttons.first { $0.kind == .crown }).rect
        let side = try #require(g.buttons.first { $0.kind == .sideButton }).rect
        let inside = Self.grey(rep, Int((Double(g.body.maxX) + 4) * s), Int((Double(crown.midY) + 1.5) * s))
        #expect(inside <= 0x1A, "crown inside \(inside)")
        let ridgeRow = Int((Double(crown.midY)) * s), ridgeX = Int((Double(crown.maxX) - 3) * s)
        #expect(Self.grey(rep, ridgeX, ridgeRow) > Self.grey(rep, ridgeX, ridgeRow + Int(1.5 * s)) + 8, "a ridge")
        let sideRim = (0..<Int(4 * s)).map { Self.grey(rep, Int(Double(side.maxX) * s) - 1 - $0, Int(Double(side.midY) * s)) }
        #expect((sideRim.max() ?? 0) >= 0x48, "side button rim \(sideRim)")
        Self.record(String(format: "row 251: crown inside %.0f, side button rim peak %.0f; crown %.1f out, %.1f tall at %.1f–%.1f %%; "
                           + "side button %.1f out, %.1f tall at %.1f–%.1f %%", inside, sideRim.max() ?? 0,
                           (Double(crown.maxX) - Double(g.body.maxX)) * s, Double(crown.height) * s,
                           (Double(crown.minY) - Double(g.body.minY)) / Double(g.body.height) * 100,
                           (Double(crown.maxY) - Double(g.body.minY)) / Double(g.body.height) * 100,
                           (Double(side.maxX) - Double(g.body.maxX)) * s, Double(side.height) * s,
                           (Double(side.minY) - Double(g.body.minY)) / Double(g.body.height) * 100,
                           (Double(side.maxY) - Double(g.body.minY)) / Double(g.body.height) * 100))
        Self.shot(w, "mac-r10-250-watch-case-fit-1400.png")
        // Light: the same structure.
        w.appearance = NSAppearance(named: .aqua)
        w.contentView?.layoutSubtreeIfNeeded()
        f.needsDisplay = true
        let light = try Self.render(f)
        #expect(abs(Self.grey(light, Int(x0) + peak, y) - profile[peak]) <= 2)
        Self.shot(w, "mac-r10-250-watch-case-fit-1400-light.png")
    }

    // MARK: Row 252

    @Test func theCapsuleHasTheCrownFirst() throws {
        let t = TestDefaults("hub-r10-capsule")
        defer { t.remove() }
        let (hub, w) = try r9.makeHub(t, rows: [DeviceHubR7Tests.iPhone17, DeviceHubR9Tests.watch], width: 1400, height: 900, sidebar: false,
                                      inspector: false)
        defer { w.close() }
        hub.canvas.zoomToFit()
        w.contentView?.layoutSubtreeIfNeeded()
        let row = hub.canvas.controls
        #expect(row.groups == [[.digitalCrown, .sideButton, .screenshot, .recordScreen]])
        var xs: [CGFloat] = []
        for c in [DeviceCommand.digitalCrown, .sideButton] {
            let b = try #require(row.button(for: c))
            let img = try #require(b.image)
            #expect(img.size == NSSize(width: 17, height: 15), "\(c): \(img.size)")
            xs.append(r7.topLeft(b.bounds, of: b, in: w).midX)
        }
        #expect(xs[0] < xs[1])
        #expect(row.button(for: .digitalCrown)?.toolTip?.hasPrefix("Digital Crown") == true)
        Self.record("row 252: capsule [Digital Crown · Side Button · Screenshot · Record], glyphs 17 × 15 at x \(xs.map { Double($0) })")
        Self.shot(w, "mac-r10-252-watch-capsule.png")
    }
}
