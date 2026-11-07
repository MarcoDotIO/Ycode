// Council round 4 (specs/ide/device-hub.md §12.1; checklist row 104): the
// control capsules show for a booted Ycode simulator (a live test session,
// no real simulator), and a device Ycode does not operate gets them too,
// every control disabled, in the same place; the dark glyph and divider
// colours.

#if os(macOS)
import AppKit
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeDeviceUI

@MainActor
@Suite(.serialized) struct DeviceCanvasR4Tests {
    let helper = DeviceWindowTests()
    let r3 = DeviceCanvasR3Tests()

    @Test func aBootedYcodeSimulatorShowsBothCapsulesEnabled() {
        let c = r3.canvas()
        let s = helper.session(type: "iphone-duo")
        c.show(session: s)
        helper.live(s, .iPhoneDuo, foldable: true)
        c.layoutSubtreeIfNeeded()
        #expect(!c.controls.isHidden && !c.showsDisabledControls)
        #expect(c.controls.capsules.map(\.frame.width) == [108, 145.5])
        #expect(c.controls.frame.maxY == 800 - 8 && abs(c.controls.frame.midX - c.bounds.midX) <= 0.5)
        for cmd: DeviceCommand in [.home, .screenshot, .recordScreen, .poseClosed, .posePartiallyOpen, .poseOpen] {
            #expect(c.controls.button(for: cmd)?.isEnabled == true, "\(cmd)")
        }
        s.close()
    }

    @Test func aDeviceYcodeDoesNotOperateShowsTheCapsulesDisabled() {
        let c = r3.canvas()
        // Ycode's choice for §12.1 question 2: the capsules float in place,
        // every control disabled, so the device keeps its place.
        c.showStopped(spec: .iPhoneDuo, name: "iPhone Duo", os: "iOS 27.1", action: nil)
        c.layoutSubtreeIfNeeded()
        #expect(c.showsDisabledControls && !c.controls.isHidden && c.statusActionCapsule.isHidden)
        #expect(c.controls.groups == [[.home, .screenshot, .recordScreen], [.rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen]])
        #expect(c.controls.capsules.map(\.frame.width) == [108, 145.5])
        let pair = c.controls.frame
        #expect(pair.maxY == 800 - 8 && pair.height == 36.5 && abs(pair.midX - c.bounds.midX) <= 0.5)
        #expect(c.controls.groups.joined().allSatisfy { c.controls.button(for: $0)?.isEnabled == false })
        // The device centred between the toolbar's bottom and the capsules' top.
        let device = c.frameView.convert(c.frameView.bounds, to: c)
        #expect(abs(device.midY - (52 + pair.minY) / 2) <= 1 && device.maxY < pair.minY)
        // No texts: the capsules carry glyphs only.
        #expect(DeviceCanvasR3Tests.visibleTexts(in: c).isEmpty)
        // A stopped Ycode simulator keeps Start in their place instead.
        c.showStopped(spec: .iPhoneDuo, name: "iPhone Duo (Ycode)", os: "iOS 27.1", action: "Start")
        c.layoutSubtreeIfNeeded()
        #expect(c.controls.isHidden && !c.statusActionCapsule.isHidden)
        // A watch: its own group, disabled.
        c.showStopped(spec: .appleWatchSeries12_46mm, name: "Watch", os: "watchOS 27", action: nil)
        c.layoutSubtreeIfNeeded()
        #expect(!c.controls.isHidden && c.controls.groups.first?.contains(.home) == false)
    }

    @Test func darkGlyphsAndDivider() {
        let dark = NSAppearance(named: .darkAqua)!, light = NSAppearance(named: .aqua)!
        func srgb(_ c: NSColor, _ a: NSAppearance) -> UInt32 {
            var out: UInt32 = 0
            a.performAsCurrentDrawingAppearance {
                let s = c.usingColorSpace(.sRGB)!
                out = UInt32((s.redComponent * 255).rounded()) << 16 | UInt32((s.greenComponent * 255).rounded()) << 8
                    | UInt32((s.blueComponent * 255).rounded())
            }
            return out
        }
        #expect(srgb(DeviceControlsRow.glyphColor, dark) == 0xFFFFFF && srgb(DeviceControlsRow.glyphColor, light) == 0x000000)
        #expect(srgb(DeviceControlsRow.dividerColor, dark) == 0x505052 && srgb(DeviceControlsRow.dividerColor, light) == 0xE9E9E9)
        #expect(DeviceControlsLayout.dividerHeight == 15)
        let c = r3.canvas()
        let s = helper.session(type: "iphone-duo")
        c.show(session: s)
        helper.live(s, .iPhoneDuo, foldable: true)
        c.layoutSubtreeIfNeeded()
        let divider = c.controls.capsules[1].subviews.flatMap(\.subviews).first { $0.identifier?.rawValue == "device-controls-divider" }
        #expect(divider?.frame.height == 15 && divider.map { abs($0.frame.midY - 36.5 / 2) <= 0.5 } == true)
        s.close()
    }
}
#endif
