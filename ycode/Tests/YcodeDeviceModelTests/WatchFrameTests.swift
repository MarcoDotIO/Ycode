// watchOS W2 (specs/simulator/watchos.md §3.1, §7.2 W2; specs/ide/device-hub.md
// §4.3): the thirteen watch types as the device windows see them, the frame
// Ycode draws round a watch (body from the corner radii, the Digital Crown
// and the side button on the right edge, the Action button on an Ultra),
// the viewer's sizes for a watch, and the hub's family for watch rows.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct WatchFrameTests {
    /// watchos.md §3.1: id, model, screen pixels, corner radius, Ultra.
    static let table: [(String, String, Int, Int, Double, Bool)] = [
        ("apple-watch-series-12-46mm", "Watch8,3", 416, 496, 50, false),
        ("apple-watch-series-12-42mm", "Watch8,4", 374, 446, 44, false),
        ("apple-watch-ultra-4-49mm", "Watch8,1", 422, 514, 57, true),
        ("apple-watch-series-11-46mm", "Watch7,18", 416, 496, 50, false),
        ("apple-watch-series-11-42mm", "Watch7,17", 374, 446, 44, false),
        ("apple-watch-series-10-46mm", "Watch7,9", 416, 496, 50, false),
        ("apple-watch-series-10-42mm", "Watch7,8", 374, 446, 44, false),
        ("apple-watch-series-9-45mm", "Watch7,4", 396, 484, 42.5, false),
        ("apple-watch-series-9-41mm", "Watch7,3", 352, 430, 38.5, false),
        ("apple-watch-ultra-3-49mm", "Watch7,12", 422, 514, 57, true),
        ("apple-watch-ultra-2-49mm", "Watch7,5", 410, 502, 54, true),
        ("apple-watch-se-3-44mm", "Watch7,16", 368, 448, 34, false),
        ("apple-watch-se-3-40mm", "Watch7,13", 324, 394, 28, false),
    ]

    @Test func thirteenWatchSpecs() throws {
        #expect(DeviceFrameSpec.watches.map(\.typeID) == Self.table.map(\.0))
        #expect(Set(DeviceFrameSpec.all.map(\.typeID)).count == DeviceFrameSpec.all.count, "ids are unique")
        for (id, model, w, h, radius, ultra) in Self.table {
            let s = try #require(DeviceFrameSpec.named(typeID: id))
            #expect(s.family == .watch && s.modelIdentifier == model && s.hasActionButton == ultra, "\(id)")
            #expect(s.panels.count == 1 && s.hasFrame && !s.isFoldable && !s.rotates && !s.hasVolumeButtons, "\(id)")
            let p = s.panels[0]
            #expect(p.name == "LCD" && p.pixelWidth == w && p.pixelHeight == h && p.scale == 2 && p.pixelsPerInch == 326, "\(id)")
            #expect(p.cornerRadii == CornerRadii(all: radius) && p.uprightQuarterTurns == 0, "\(id)")
            #expect(p.uprightPointSize == CGSize(width: Double(w) / 2, height: Double(h) / 2), "\(id)")
        }
        #expect(DeviceFrameSpec.appleWatchSeries12_46mm.typeID == "apple-watch-series-12-46mm")
        // Phones and iPads still rotate and have volume buttons.
        #expect(DeviceFrameSpec.iPhone18Pro.rotates && DeviceFrameSpec.iPadA16.hasVolumeButtons && !DeviceFrameSpec.visionPro.rotates)
    }

    @Test func theHelloFindsTheWatch() {
        // By type id, by model, by size (the first type of that size).
        #expect(DeviceFrameSpec.matching(typeID: "apple-watch-se-3-40mm", pixelWidth: 1, pixelHeight: 1, scale: 1).typeID == "apple-watch-se-3-40mm")
        #expect(DeviceFrameSpec.matching(model: "Watch8,1", pixelWidth: 1, pixelHeight: 1, scale: 2).typeID == "apple-watch-ultra-4-49mm")
        #expect(DeviceFrameSpec.matching(pixelWidth: 416, pixelHeight: 496, scale: 2) == .appleWatchSeries12_46mm)
        // An unknown watch-sized screen or watch model is drawn as a watch.
        let small = DeviceFrameSpec.matching(pixelWidth: 400, pixelHeight: 480, scale: 2)
        #expect(small.typeID == "unknown" && small.family == .watch && small.panels[0].pixelsPerInch == 326)
        let model = DeviceFrameSpec.matching(model: "Watch9,9", pixelWidth: 500, pixelHeight: 600, scale: 2)
        #expect(model.family == .watch)
        #expect(DeviceFrameSpec.matching(pixelWidth: 1000, pixelHeight: 2000, scale: 3).family == .phone)
        #expect(DeviceFrameSpec.placeholder(for: .watch) == .appleWatchSeries12_46mm)
        #expect(DeviceFrameSpec.placeholder(for: .pad) == .iPadA16 && DeviceFrameSpec.placeholder(for: .phone) == .iPhone18Pro)
    }

    @Test func theWatchFrameIsConcentricWithTheCrownAndSideButtonOnTheRight() throws {
        let g = DeviceFrameGeometry(spec: .appleWatchSeries12_46mm)
        // Council round 10, row 249: 21 at the sides, 23.5 at the top and bottom.
        let b = DeviceFrameGeometry.band(.watch), e = DeviceFrameGeometry.watchEndBorder, m = DeviceFrameGeometry.margin(.watch)
        #expect(m == DeviceFrameGeometry.crownProtrusion && b == 21 && e == 23.5)
        // 416 × 496 @2 = 208 × 248 points.
        // The crown's room at the sides only.
        #expect(g.screen == CGRect(x: m + b, y: e, width: 208, height: 248))
        #expect(g.body == CGRect(x: m, y: 0, width: 208 + 2 * b, height: 248 + 2 * e))
        #expect(g.size == CGSize(width: 208 + 2 * b + 2 * m, height: 248 + 2 * e))
        #expect(g.screenRadii == CornerRadii(all: 50) && g.bodyRadii == CornerRadii(all: 50 + b))
        #expect(g.buttons.map(\.kind) == [.crown, .sideButton])
        let crown = try #require(g.buttons.first { $0.kind == .crown }).rect
        let side = try #require(g.buttons.first { $0.kind == .sideButton }).rect
        // Both stand out of the right edge; the crown further, above the side button.
        #expect(crown.minX < g.body.maxX && crown.maxX == g.body.maxX + DeviceFrameGeometry.crownProtrusion)
        #expect(side.minX < g.body.maxX && side.maxX == g.body.maxX + DeviceFrameGeometry.watchButtonProtrusion)
        #expect(crown.maxY < side.minY && crown.width > side.width && side.height > crown.height)
        // Everything fits the drawing; the screen is at its centre.
        for btn in g.buttons { #expect(CGRect(origin: .zero, size: g.size).contains(btn.rect), "\(btn.kind)") }
        #expect(g.screen.midX == g.size.width / 2 && g.screen.midY == g.size.height / 2)
        // Hit testing and titles.
        #expect(g.button(at: CGPoint(x: crown.maxX - 1, y: crown.midY)) == .crown)
        #expect(g.button(at: CGPoint(x: side.midX, y: side.midY)) == .sideButton)
        #expect(DeviceFrameGeometry.ButtonKind.crown.title == "Digital Crown" && DeviceFrameGeometry.ButtonKind.sideButton.title == "Side Button")
    }

    @Test func anUltraHasTheActionButtonOnTheLeft() throws {
        let spec = try #require(DeviceFrameSpec.named(typeID: "apple-watch-ultra-4-49mm"))
        let g = DeviceFrameGeometry(spec: spec)
        #expect(g.buttons.map(\.kind) == [.crown, .sideButton, .action])
        let action = try #require(g.buttons.first { $0.kind == .action }).rect
        #expect(action.minX < g.body.minX && action.maxX > g.body.minX)
        #expect(g.screen.size == CGSize(width: 211, height: 257) && g.screenRadii == CornerRadii(all: 57))
    }

    @Test func everyWatchFrameFollowsItsRadiusAndHidingTheBezelLeavesTheScreen() {
        for spec in DeviceFrameSpec.watches {
            let g = DeviceFrameGeometry(spec: spec)
            let r = spec.panels[0].cornerRadii.topLeft
            #expect(g.bodyRadii == CornerRadii(all: r + DeviceFrameGeometry.band(.watch)), "\(spec.typeID)")
            #expect(g.screen.size == spec.panels[0].uprightPointSize, "\(spec.typeID)")
            let bare = DeviceFrameGeometry(spec: spec, bezels: false)
            #expect(bare.buttons.isEmpty && bare.body == bare.screen && bare.size == spec.panels[0].uprightPointSize, "\(spec.typeID)")
            #expect(bare.screenRadii == CornerRadii(all: r), "\(spec.typeID)")
        }
    }

    @Test func compactWindowAndZoomForAWatch() {
        let g = DeviceFrameGeometry(spec: .appleWatchSeries12_46mm)
        // 276 × 295 points with the frame (round 10: the 250 × 295 case and the crown's 13 at each side).
        #expect(g.size == CGSize(width: 276, height: 295))
        // The default window is the minimum width; the watch fills it with the side margins.
        let s = CompactWindowLayout.defaultScale(device: g.size)
        #expect(abs(s - (CompactWindowLayout.minimumWidth - 2 * CompactWindowLayout.sideMargin) / 276) < 1e-9)
        let c = CompactWindowLayout.contentSize(device: g.size, scale: s)
        #expect(Double(c.width) == CompactWindowLayout.minimumWidth)
        #expect(Double(c.height) == (295 * s + CompactWindowLayout.chromeHeight()).rounded(), "\(c) \(s)")
        // Resizing keeps the aspect.
        let wide = CompactWindowLayout.constrainedContentSize(device: g.size, proposed: CGSize(width: 552 + 34, height: 10))
        #expect(wide.width == 586 && wide.height == (295 * 2 + CompactWindowLayout.chromeHeight()).rounded())
        // Physical size: 2 pixels a point at 326 per inch.
        let p = DeviceZoom.physical(panel: DeviceFrameSpec.appleWatchSeries12_46mm.panels[0], displayPointsPerInch: 110)
        #expect(abs(p - 2.0 / 326 * 110) < 1e-9)
        // Zoom to Fit in a hub canvas 580 × 800 less the control row.
        let fit = DeviceZoom.fit(g.size, in: CGSize(width: 580, height: 800 - 57))
        #expect(abs(fit - min((580 - 48) / 276.0, (743 - 48) / 295.0)) < 1e-9)
    }

    @Test func watchRowsHaveTheWatchFamily() {
        #expect(HubDevice.family(platform: "watchOS", name: "Ycode") == .watch)
        #expect(HubDevice.family(platform: "iOS", name: "Apple Watch Series 12 (46mm) (Ycode)") == .watch)
        #expect(HubDevice.family(platform: "iOS", name: "iPhone 18 Pro") == .phone)
        #expect(HubDevice.family(platform: "visionOS", name: "Apple Vision Pro") == .vision)
    }

    /// Council round 8: an iPad of a type Ycode has no frame for, named by
    /// its user in lower case, was drawn as a phone with "iOS" under it.
    @Test func anUnknownIPadTypeIsAnIPadWhateverItsName() {
        let type = "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"
        let d = HubDevice.family(platform: "iOS", name: "ycode-test-council-ipad", typeID: type, model: "iPad Air 11-inch (M4)")
        #expect(d == .pad)
        #expect(HubDevice.family(platform: "iOS", name: "Test", typeID: type) == .pad)
        #expect(HubDevice.family(platform: "iOS", name: "my-ipad") == .pad)
        #expect(HubDevice.family(platform: "iOS", name: "iPad named phone", typeID: "com.apple.CoreSimulator.SimDeviceType.iPhone-17") == .phone)
        #expect(DeviceFamily.pad.osTitle("iOS 27.2") == "iPadOS 27.2")
        #expect(DeviceFrameSpec.placeholder(for: .pad).family == .pad)
    }
}
