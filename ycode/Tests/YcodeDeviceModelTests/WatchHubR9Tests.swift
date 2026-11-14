// Council round 9, group D (specs/ide/fidelity-council.md "Round 9", rows
// 231 and 234; device-hub.md §4.4, §15.2): the shared rules both IDEs draw
// the watch with. Zoom to Fit fits a watch through a box a little taller
// than its silhouette (body, crown and side button), so the silhouette is
// 638 tall at 1100 × 800 and 732 at 1400 × 900; the watch's capsule holds
// the side button, the Digital Crown, Screenshot and Record.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct WatchHubR9Tests {
    /// The hub's areas in the round's windows: the canvas width by the
    /// space between the toolbar (52) and Ycode's capsules (44.5 up).
    static let area1100 = CGSize(width: 820, height: 800 - 52 - 44.5)
    static let area1400 = CGSize(width: 1400, height: 900 - 52 - 44.5)

    @Test func zoomToFitFitsTheWatchsBoxNotItsSilhouette() throws {
        let g = DeviceFrameGeometry(spec: .appleWatchSeries12_46mm)
        // The silhouette: the 250 × 295 body (round 10, row 249), the crown standing 13 out on the right.
        #expect(g.outerBox.size == CGSize(width: 263, height: 295))
        let box = try #require(g.reservedFitHeight)
        #expect(abs(box - 295 / DeviceFrameGeometry.watchFitShare) < 1e-9 && g.fitSilhouetteHeight(foldable: false) == box)
        for (area, ref) in [(Self.area1100, 638.0), (Self.area1400, 732.0)] {
            let s = DeviceZoom.hubFit(geometry: g, foldable: false, in: area)
            let h = 295 * s, w = 263 * s
            #expect(abs(h - ref) <= 1, "\(area): \(w) × \(h)")
            // Inside the stage with room round it, height-bound (the width is not the limit).
            #expect(h <= DeviceZoom.hubFitLength(DeviceZoom.hubFreeHeight(areaHeight: Double(area.height))) && w < Double(area.width) - 32)
            // The whole drawing (its clear margin round the crown included) fits the area too: no scrolling.
            #expect(Double(g.size.height) * s <= Double(area.height) && Double(g.size.width) * s <= Double(area.width))
        }
        // Every watch type gets its own box; the bare screen (no bezel) and other families none.
        for spec in DeviceFrameSpec.watches {
            let w = DeviceFrameGeometry(spec: spec)
            #expect(w.reservedFitHeight.map { abs($0 * DeviceFrameGeometry.watchFitShare - Double(w.outerBox.height)) < 1e-9 } == true, "\(spec.typeID)")
            #expect(DeviceFrameGeometry(spec: spec, bezels: false).reservedFitHeight == nil)
        }
        #expect(DeviceFrameGeometry(spec: .iPhone18Pro).reservedFitHeight == nil && DeviceFrameGeometry(spec: .iPadA16).reservedFitHeight == nil)
        // Phones and iPads keep round 7's rule.
        let phone = DeviceFrameGeometry(spec: .iPhone18Pro)
        #expect(phone.fitSilhouetteHeight(foldable: false) == Double(phone.outerBox.height))
        #expect(DeviceFrameGeometry(spec: .iPhoneDuo).fitSilhouetteHeight(foldable: true) == DeviceFrameGeometry.foldableFitBox)
    }

    @Test func theWatchsCapsuleHoldsItsTwoHardwareControlsThenScreenshotAndRecord() {
        let d = DeviceControlsLayout.Device(spec: .appleWatchSeries12_46mm)
        #expect(d.watch && !d.showsHome && !d.rotates)
        let groups = DeviceControlsLayout.groups(d)
        // Round 10 (row 252): the Digital Crown first.
        #expect(groups == [[.digitalCrown, .sideButton, .screenshot, .recordScreen]])
        // One capsule about 143 wide (142: 20 + 3 × 34 + 20), 36.5 tall, centred, 8 above the bottom.
        #expect(DeviceControlsLayout.width(of: groups[0]) == 142)
        #expect(DeviceControlsLayout.glyphCentres(of: groups[0]) == [20, 54, 88, 122])
        let r = DeviceControlsLayout.capsuleRects(groups, canvasWidth: 1400, canvasHeight: 848)
        #expect(r == [CGRect(x: 629, y: 848 - 8 - 36.5, width: 142, height: 36.5)])
        // Other devices are unchanged.
        #expect(DeviceControlsLayout.groups(.init(spec: .iPhone18Pro)) == [[.home, .screenshot, .recordScreen], [.rotateLeft]])
        #expect(!DeviceControlsLayout.Device(spec: .iPadA16).watch)
        #expect(DeviceCommand.sideButton.title == "Side Button" && DeviceCommand.digitalCrown.title == "Digital Crown")
        #expect(DeviceCommand.sideButton.keyEquivalent == nil && DeviceCommand.digitalCrown.keyEquivalent == nil)
    }
    // Round 9's hardware glyphs (a case with a knob or a bar) are superseded by
    // round 10's row 252: `WatchR10Tests`.
}
