// Council round 7 on the device window (`specs/ide/device-hub.md` §15,
// checklist rows 170–175): Zoom to Fit for every device (the silhouette to
// 0.98 F − 16, the Duo through its 1269-point box), the iPad's tablet
// outline, the iPhone's border and buttons, the subtitle's OS name. Shared
// by both IDEs, so these run on macOS and Linux.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct DeviceFrameR7Tests {
    /// Ycode's area for a window `w` × `h` with the sidebar hidden: the
    /// toolbar 52, its capsules' top 44.5 above the bottom.
    static func area(_ w: Double, _ h: Double) -> CGSize { CGSize(width: w, height: h - 52 - 44.5) }

    /// The body's size and centre in window points at Zoom to Fit, the
    /// drawing centred in the area (from y 52).
    static func fitted(_ g: DeviceFrameGeometry, foldable: Bool = false, _ w: Double, _ h: Double)
        -> (scale: Double, body: CGRect, silhouette: CGRect) {
        let a = area(w, h)
        let s = DeviceZoom.hubFit(geometry: g, foldable: foldable, in: a)
        let r = DeviceControlsLayout.deviceRect(device: g.size, scale: s, in: CGRect(x: 0, y: 52, width: a.width, height: a.height))
        func win(_ b: CGRect) -> CGRect {
            CGRect(x: Double(r.minX) + Double(b.minX) * s, y: Double(r.minY) + Double(b.minY) * s, width: Double(b.width) * s, height: Double(b.height) * s)
        }
        return (s, win(g.body), win(g.outerBox))
    }

    /// The simctl devices of the round: an iPhone 17 (402 × 874) and an iPad
    /// Air 11-inch (820 × 1180) are drawn from the family's usual type.
    static let phone = DeviceFrameSpec.placeholder(for: .phone)
    static let pad = DeviceFrameSpec.placeholder(for: .pad)

    @Test func theRoundsDevicesHaveTheReferencesScreens() {
        #expect(Self.phone.panels[0].pointSize == CGSize(width: 402, height: 874))
        #expect(Self.pad.panels[0].pointSize == CGSize(width: 820, height: 1180))
    }

    // MARK: Row 170

    @Test func theRuleIsTheMeasuredOne() {
        // F = H − 96 from Ycode's area (its capsules half a point taller).
        #expect(DeviceZoom.hubFreeHeight(areaHeight: 800 - 52 - 44.5) == 704)
        #expect(DeviceZoom.hubFitLength(704) == 0.98 * 704 - 16)
        #expect(abs(DeviceZoom.hubFitLength(704) - 673.92) < 1e-9 && abs(DeviceZoom.hubFitLength(804) - 771.92) < 1e-9)
    }

    @Test func theIPhoneFillsTheFreeHeight() {
        let g = DeviceFrameGeometry(spec: Self.phone)
        // No button on its top or bottom edge: the silhouette is the body.
        #expect(g.fitSilhouetteHeight(foldable: false) == Double(g.body.height))
        for (w, h, bw, bh, cy) in [(1100.0, 800.0, 324.5, 674.5, 404.0), (1400, 900, 371.5, 772.5, 454)] {
            let f = Self.fitted(g, w, h)
            #expect(abs(Double(f.body.width) - bw) <= 1 && abs(Double(f.body.height) - bh) <= 1, "\(w): \(f.body.size)")
            #expect(abs(Double(f.body.midY) - cy) <= 0.75 && abs(Double(f.body.midX) - w / 2) <= 0.5, "\(w): centre \(f.body.midX), \(f.body.midY)")
        }
        // Scale 0.740 and 0.848 (the screens 298 × 646.5 and 341 × 741).
        #expect(abs(Self.fitted(g, 1100, 800).scale - 0.740) < 0.002 && abs(Self.fitted(g, 1400, 900).scale - 0.848) < 0.002)
    }

    @Test func theIPadFillsTheFreeHeightWithItsTopButton() {
        let g = DeviceFrameGeometry(spec: Self.pad)
        // The silhouette is the body and the top button, 1304.
        #expect(abs(g.fitSilhouetteHeight(foldable: false) - 1304) < 1e-9)
        for (w, h, bw, bh, cy) in [(1100.0, 800.0, 485.5, 671.0, 404.0), (1400, 900, 556, 769, 454)] {
            let f = Self.fitted(g, w, h)
            #expect(abs(Double(f.body.width) - bw) <= 1 && abs(Double(f.body.height) - bh) <= 1, "\(w): \(f.body.size)")
            // The reference centres the body (the button stands 2 above it).
            #expect(abs(Double(f.body.midY) - cy) <= 0.75, "\(w): centre \(f.body.midY)")
            #expect(abs(Double(f.body.minY - f.silhouette.minY) - 2 * f.scale / 0.5161) < 0.3)
        }
        #expect(abs(Self.fitted(g, 1100, 800).scale - 0.516) < 0.002 && abs(Self.fitted(g, 1400, 900).scale - 0.591) < 0.002)
    }

    @Test func theDuoKeepsItsBoxThroughThe1269PointBox() {
        let g = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 0, posture: .closed)
        #expect(g.fitSilhouetteHeight(foldable: true) == 1269)
        for (w, h, bw, bh) in [(1100.0, 800.0, 274.0, 379.5), (1400, 900, 314, 435)] {
            let f = Self.fitted(g, foldable: true, w, h)
            #expect(abs(Double(f.silhouette.width) - bw) <= 2 && abs(Double(f.silhouette.height) - bh) <= 1.5, "\(w): \(f.silhouette.size)")
        }
        #expect(abs(Self.fitted(g, foldable: true, 1100, 800).scale - 0.531) < 0.001)
        #expect(abs(Self.fitted(g, foldable: true, 1400, 900).scale - 0.608) < 0.001)
        // The open posture keeps the same scale (the box does not change).
        let open = DeviceFrameGeometry(spec: .iPhoneDuo, panelIndex: 1, posture: .openFlat)
        #expect(abs(Self.fitted(open, foldable: true, 1100, 800).scale - Self.fitted(g, foldable: true, 1100, 800).scale) < 1e-9)
    }

    @Test func theWidthCapsANarrowCanvas() {
        // Ycode's decision: the outer box at most the canvas less 8 + 1 % a side.
        let g = DeviceFrameGeometry(spec: Self.pad, clockwiseQuarterTurns: 1)
        let a = CGSize(width: 600, height: 703.5)
        let s = DeviceZoom.hubFit(geometry: g, foldable: false, in: a)
        #expect(abs(Double(g.outerBox.width) * s - (0.98 * 600 - 16)) < 1e-6)
        // A wide canvas: the height decides.
        #expect(DeviceZoom.hubFit(geometry: g, foldable: false, in: CGSize(width: 5000, height: 703.5)) > s)
    }

    // MARK: Row 171: the iPad's tablet outline

    @Test func theIPadIsATablet() throws {
        let g = DeviceFrameGeometry(spec: Self.pad)
        // Body 940 × 1300 (0.724), the screen 60 inside on every side.
        #expect(g.body.size == CGSize(width: 940, height: 1300))
        #expect(abs(Double(g.body.width / g.body.height) - 0.724) < 0.001)
        #expect(g.screen.minX - g.body.minX == 60 && g.body.maxX - g.screen.maxX == 60)
        #expect(g.screen.minY - g.body.minY == 60 && g.body.maxY - g.screen.maxY == 60)
        // Corners: the body about 83, the screen about 19.
        #expect(g.bodyRadii == CornerRadii(all: 83) && g.screenRadii == CornerRadii(all: 19))
        // The band: a light line 2, #2C2C2C 4, then black to the screen.
        typealias P = DeviceFrameGeometry.Palette
        #expect(g.bandRings == [.init(inset: 0, color: P.edge), .init(inset: 2, color: P.greyBand), .init(inset: 6, color: P.inner)])
        #expect(P.greyBand == 0x2C2C2C && (0x62...0x7B).contains(Int(P.edge & 0xFF)))
        let rings = g.bandRingRects
        #expect(rings.count == 3 && rings[2].rect == g.body.insetBy(dx: 6, dy: 6) && rings[2].radii == CornerRadii(all: 77))
        // The top button near the right corner: 91 long, ending 84 from the
        // right edge, 4 out; two volume strips flush with the right edge, 52
        // long, 10 apart, from 121 below the top.
        let top = try #require(g.buttons.first { $0.kind == .top }).rect
        #expect(abs(Double(top.width) - 91) < 1e-6 && abs(Double(g.body.maxX - top.maxX) - 84) < 1e-6)
        #expect(Double(g.body.minY - top.minY) == 4 && !g.buttons.first { $0.kind == .top }!.flush)
        let up = try #require(g.buttons.first { $0.kind == .volumeUp }), down = try #require(g.buttons.first { $0.kind == .volumeDown })
        #expect(up.flush && down.flush)
        #expect(up.rect.maxX == g.body.maxX && down.rect.maxX == g.body.maxX && up.rect.minX > g.body.maxX - 3)
        #expect(abs(Double(up.rect.minY - g.body.minY) - 121) < 1e-6 && abs(Double(up.rect.height) - 52) < 1e-6)
        #expect(abs(Double(down.rect.minY - up.rect.maxY) - 10) < 1e-6)
        // At 1100: 31 window points from the body's edge to the screen.
        #expect(abs(60 * Self.fitted(g, 1100, 800).scale - 31) < 0.3)
        // Turning keeps the flush flag.
        #expect(DeviceFrameGeometry(spec: Self.pad, clockwiseQuarterTurns: 1).buttons.filter(\.flush).count == 2)
    }

    // MARK: Row 172: the iPhone 17's border

    @Test func theIPhonesBorderAndButtons() throws {
        let g = DeviceFrameGeometry(spec: Self.phone)
        // 18.25 from the body's edge to the screen; body 438.5 wide.
        #expect(g.screen.minX - g.body.minX == 18.25 && g.body.width == 438.5)
        #expect(g.bodyRadii == CornerRadii(all: 83))
        typealias P = DeviceFrameGeometry.Palette
        #expect(g.bandRings.map(\.color) == [P.edge, P.greyBand, P.inner] && g.bandRings.map(\.inset) == [0, 2, 6])
        #expect((0x56...0x81).contains(Int(P.edge & 0xFF)))
        // Three on the left (from 159.5, 220, 299; 36.5, 65.5, 65.5 long),
        // one on the right (from 261.5, 103.5 long), in a 911.5 body (Ycode's
        // 910.5 scales them), 4.7 out.
        let k = Double(g.body.height) / 911.5
        let left = g.buttons.filter { $0.rect.minX < g.body.minX }
        #expect(left.map(\.kind) == [.action, .volumeUp, .volumeDown])
        for (b, (y, len)) in zip(left, [(159.5, 36.5), (220, 65.5), (299, 65.5)]) {
            #expect(abs(Double(b.rect.minY - g.body.minY) - y * k) < 1e-6 && abs(Double(b.rect.height) - len * k) < 1e-6, "\(b.kind)")
            #expect(abs(Double(g.body.minX - b.rect.minX) - 4.7) < 1e-9)
        }
        let side = try #require(g.buttons.first { $0.kind == .side }).rect
        #expect(abs(Double(side.minY - g.body.minY) - 261.5 * k) < 1e-6 && abs(Double(side.height) - 103.5 * k) < 1e-6)
        #expect(abs(Double(side.maxX - g.body.maxX) - 4.7) < 1e-9)
        // At 1100: 13.5 window points to the screen.
        #expect(abs(18.25 * Self.fitted(g, 1100, 800).scale - 13.5) < 0.3)
    }

    // MARK: Row 173: the subtitle

    @Test func theSubtitleNamesTheFamilysOS() {
        #expect(DeviceFamily.pad.osTitle("iOS 27.2") == "iPadOS 27.2")
        #expect(DeviceFamily.pad.osTitle("iOS") == "iPadOS")
        #expect(DeviceFamily.phone.osTitle("iOS 27.2") == "iOS 27.2")
        #expect(DeviceFamily.watch.osTitle("watchOS 27.0") == "watchOS 27.0")
        #expect(DeviceFamily.vision.osTitle("xrOS 27.0") == "visionOS 27.0" && DeviceFamily.vision.osTitle("visionOS 27.0") == "visionOS 27.0")
        #expect(DeviceFamily.pad.osTitle("iOSX 1") == "iOSX 1")
        let ipad = HubDevice(id: "p", name: "iPad Air 11-inch (M4)", platform: "iOS", osVersion: "27.2", family: .pad, isSimulator: true, isRunning: true)
        #expect(ipad.osTitle == "iPadOS 27.2")
        let iphone = HubDevice(id: "i", name: "iPhone 17", platform: "iOS", osVersion: "27.2", family: .phone, isSimulator: true, isRunning: true)
        #expect(iphone.osTitle == "iOS 27.2")
    }
}
