// Council round 3 (specs/ide/device-hub.md §11.1, §11.2; checklist rows 65
// and 67): the control capsules' sizes and their place at the bottom of the
// canvas, their buttons' order and commands, the device centred between the
// top and the capsules, and no name or OS label under a stopped device.

#if os(macOS)
import AppKit
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeDeviceUI

@MainActor
@Suite(.serialized) struct DeviceCanvasR3Tests {
    let helper = DeviceWindowTests()

    /// A hub canvas the size of round 3's (820.5 × 748 under a 52-point toolbar).
    func canvas() -> DeviceCanvasView {
        let c = DeviceCanvasView(mode: .hub)
        c.frame = NSRect(x: 0, y: 0, width: 820.5, height: 800)
        c.topInset = 52
        return c
    }

    @Test func capsulesHaveTheMeasuredSizesAndFloatAtTheBottom() {
        let c = canvas()
        let s = helper.session(type: "iphone-duo")
        c.show(session: s)
        helper.live(s, .iPhoneDuo, foldable: true)
        c.layoutSubtreeIfNeeded()
        let caps = c.controls.capsules
        #expect(caps.count == 2)
        #expect(caps.map(\.frame.width) == [108, 145.5] && caps.allSatisfy { $0.frame.height == 36.5 })
        // 7.5 apart; the pair 8 above the bottom edge, centred on the canvas.
        let pair = c.controls.frame
        #expect(caps[1].frame.minX - caps[0].frame.maxX == 7.5)
        #expect(pair.maxY == 800 - 8 && pair.height == 36.5 && pair.width == 261)
        #expect(abs(pair.midX - c.bounds.midX) <= 0.5)
        // The device is centred between the toolbar's bottom and the capsules' top.
        let device = c.frameView.convert(c.frameView.bounds, to: c)
        #expect(abs(device.midY - (52 + pair.minY) / 2) <= 1 && abs(device.midX - c.bounds.midX) <= 1)
        #expect(device.maxY < pair.minY)
        s.close()
    }

    @Test func buttonsAreInTheSpecsOrderAndCarryTheirCommands() {
        let c = canvas()
        let s = helper.session(type: "iphone-duo")
        c.show(session: s)
        helper.live(s, .iPhoneDuo, foldable: true)
        c.layoutSubtreeIfNeeded()
        let order: [DeviceCommand] = [.home, .screenshot, .recordScreen, .rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen]
        #expect(c.controls.groups.flatMap { $0 } == order)
        // Left to right on the 34-point pitch (37.5 across the divider).
        let xs = order.compactMap { c.controls.button(for: $0) }.map { $0.convert($0.bounds, to: c).midX }
        #expect(xs.count == order.count && zip(xs, xs.dropFirst()).allSatisfy { $1 > $0 })
        let steps = zip(xs, xs.dropFirst()).map { $1 - $0 }
        #expect(steps == [34, 34, 7.5 + 20 + 20, 37.5, 34, 34])
        #expect(c.controls.highlightedPose == .poseClosed)
        // Each button sends its command (the canvas carries it out; with the
        // display gone it hands it to its owner).
        var got: [DeviceCommand] = []
        c.commandFallback = { got.append($0); return true }
        s.connection(s.connection, status: DisplayStatus(phase: "booting", uptimeMilliseconds: 1000, guestFrames: 0))
        for cmd in order {
            let b = c.controls.button(for: cmd)!
            _ = b.sendAction(b.action, to: b.target)
        }
        #expect(got == order)
        s.close()
    }

    @Test func aWatchAndAVisionProHaveTheirOwnCapsules() {
        let c = canvas()
        let s = helper.session(type: "vision-pro")
        c.show(session: s)
        c.layoutSubtreeIfNeeded()
        #expect(c.controls.groups == [[.home, .screenshot, .recordScreen], [.resetCamera]])
        #expect(c.controls.capsules.map(\.frame.width) == [108, 40])
        s.close()
    }

    @Test func aStoppedDeviceHasNoLabelAndStartWhereTheControlsFloat() {
        let c = canvas()
        var started = false
        c.onAction = { started = true }
        c.showStopped(spec: .iPhone18Pro, name: "iPhone 18 Pro (Ycode)", os: "iOS 27.1", action: "Start")
        c.layoutSubtreeIfNeeded()
        // No text on the canvas names the device or its OS (§11.2).
        let texts = Self.visibleTexts(in: c)
        #expect(!texts.contains { $0.contains("iPhone 18 Pro") || $0.contains("iOS 27.1") })
        #expect(texts == ["Start"], "\(texts)")
        // Start sits where the capsules float; the frame is centred above it.
        let cap = c.statusActionCapsule.frame
        #expect(cap.maxY == 800 - 8 && cap.height == 36.5 && abs(cap.midX - c.bounds.midX) <= 0.5)
        let device = c.frameView.convert(c.frameView.bounds, to: c)
        #expect(abs(device.midY - (52 + (800 - 8 - 36.5)) / 2) <= 1)
        c.statusActionButton.performClick(nil)
        #expect(started)
        // Starting: a spinner and "Starting…" in the same capsule.
        c.showStopped(spec: .iPhone18Pro, name: "iPhone 18 Pro (Ycode)", os: "iOS 27.1", action: nil, busy: true)
        c.layoutSubtreeIfNeeded()
        #expect(Self.visibleTexts(in: c) == ["Starting…"] && !c.statusActionCapsule.isHidden)
        // A simulator Ycode does not operate: the picture alone.
        c.showStopped(spec: .iPhone18Pro, name: "iPhone 17", os: "iOS 26.4", action: nil)
        c.layoutSubtreeIfNeeded()
        #expect(Self.visibleTexts(in: c).isEmpty && c.statusActionCapsule.isHidden)
    }

    /// The canvas's visible label and button texts.
    static func visibleTexts(in v: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            if let t = v as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
            if let b = v as? NSButton {
                if !b.title.isEmpty { out.append(b.title) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(v)
        return out
    }
}
#endif
