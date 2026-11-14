// The floating control capsules shared by the macOS canvas and the Linux
// device window (specs/ide/device-hub.md §11.1, §11.2; council round 3
// checklist rows 65 and 67): sizes, glyph pitch, divider, position at the
// bottom of the canvas, the device centred above them. Runs on Linux too.

import Foundation
import Testing
@testable import YcodeDeviceModel

@Suite struct DeviceControlsLayoutTests {
    let duo = DeviceControlsLayout.groups(.init(spec: .iPhoneDuo))

    @Test func groupsFollowTheDevice() {
        #expect(duo == [[.home, .screenshot, .recordScreen], [.rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen]])
        #expect(DeviceControlsLayout.groups(.init(spec: .iPhone18Pro)) == [[.home, .screenshot, .recordScreen], [.rotateLeft]])
        #expect(DeviceControlsLayout.groups(.init(spec: .iPadA16)) == [[.home, .screenshot, .recordScreen], [.rotateLeft]])
        #expect(DeviceControlsLayout.groups(.init(spec: .appleWatchSeries12_46mm)) == [[.digitalCrown, .sideButton, .screenshot, .recordScreen]])
        #expect(DeviceControlsLayout.groups(.init(spec: .visionPro)) == [[.home, .screenshot, .recordScreen], [.resetCamera]])
    }

    @Test func capsulesHaveTheMeasuredSizes() {
        // §11.1: 108 and 145.5 wide, 36.5 tall, 7.5 apart.
        #expect(DeviceControlsLayout.width(of: duo[0]) == 108)
        #expect(DeviceControlsLayout.width(of: duo[1]) == 145.5)
        #expect(DeviceControlsLayout.height == 36.5 && DeviceControlsLayout.gap == 7.5)
        #expect(DeviceControlsLayout.totalWidth(duo) == 108 + 7.5 + 145.5)
        // A lone Rotate: a 40-point capsule.
        #expect(DeviceControlsLayout.width(of: [.rotateLeft]) == 40)
    }

    @Test func glyphsSitOnTheMeasuredPitch() {
        // Capsule 1 at x 279.5: glyphs at 299.5, 333.5, 367.5 (measured 299.5, 334, 367.5).
        #expect(DeviceControlsLayout.glyphCentres(of: duo[0]) == [20, 54, 88])
        // Capsule 2 at x 395: Rotate 415, the poses 452.5, 486.5, 520.5 (measured 415.5, 452.5, 486, 520.5).
        #expect(DeviceControlsLayout.glyphCentres(of: duo[1]) == [20, 57.5, 91.5, 125.5])
        // The divider between Rotate and the poses (measured x 434: 39 inside).
        #expect(DeviceControlsLayout.dividerCentre(of: duo[1]) == 38.75)
        #expect(DeviceControlsLayout.dividerCentre(of: duo[0]) == nil)
    }

    @Test func capsulesFloatAtTheBottomCentredOnTheCanvas() {
        // The round 3 canvas: 820.5 wide, the window 800 tall (the canvas from 52).
        let rects = DeviceControlsLayout.capsuleRects(duo, canvasWidth: 820.5, canvasHeight: 748)
        #expect(rects.count == 2)
        #expect(rects[0].maxY == 748 - 8 && rects[0].height == 36.5 && rects[1].minY == rects[0].minY)
        #expect(abs((rects[0].minX + rects[1].maxX) / 2 - 820.5 / 2) < 0.001)
        #expect(rects[1].minX - rects[0].maxX == 7.5)
        // Measured: x 279.5–387.5 and 395–540.5 (centre 410 of the canvas, ours 410.25).
        #expect(abs(rects[0].minX - 279.5) <= 0.5 && abs(rects[1].maxX - 540.5) <= 0.5)
        let controls = DeviceControlsLayout.controlRects(duo, canvasWidth: 820.5, canvasHeight: 748)
        #expect(controls.map(\.0) == duo.flatMap { $0 })
        #expect(controls.allSatisfy { $0.1.width == 34 && $0.1.height == 36.5 })
    }

    @Test func theDeviceIsCentredBetweenTheTopAndTheCapsules() {
        // §11.2: the frame's centre y 402.75 between the toolbar (52) and the capsules' top (755.5).
        let area = DeviceControlsLayout.deviceArea(canvasWidth: 820.5, canvasHeight: 800, top: 52)
        #expect(area.minY == 52 && area.maxY == 755.5)
        let r = DeviceControlsLayout.deviceRect(device: CGSize(width: 274, height: 379.5), scale: 1, in: area)
        #expect(abs(r.midY - 403.75) < 0.001 && abs(r.midX - 410.25) < 0.001)
    }
}
