import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 5 on the device window (`specs/ide/device-hub.md` §13,
/// checklist rows 131–132): a foldable's second capsule holds Rotate, the
/// divider and the three posture buttons (146 wide), the current posture in
/// the accent colour, even for a simctl foldable Ycode does not operate
/// (every control disabled, closed current); Rotate is Ycode's own drawing
/// with arrows at two opposite corners.
@MainActor
@Suite(.serialized) struct DeviceHubR5Tests {
    let r3 = DeviceHubR3Tests()

    /// A simctl iPhone Duo (its type known only by name), booted.
    static let simctlDuo = DeviceRow(name: "iPhone Duo", identifier: "UDID-SIMCTL-DUO", platform: "iOS", osVersion: "27.1",
                                     state: "Booted", model: "iPhone Duo", isAvailable: true)

    @Test func aFoldableYcodeDoesNotRunKeepsItsPostureCapsule() throws {
        _ = NSApplication.shared
        let t = TestDefaults("hub-r5-duo")
        defer { t.remove() }
        let hub = DevicesController(devices: [], simulators: [Self.simctlDuo, DeviceHubR3Tests.other])
        hub.defaults = t.defaults
        let w = hub.makeWindow()
        defer { w.close() }
        w.appearance = NSAppearance(named: .darkAqua)
        w.setFrameAutosaveName("")
        w.setContentSize(NSSize(width: 1100, height: 800))
        w.contentView?.layoutSubtreeIfNeeded()
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == Self.simctlDuo.identifier }))
        w.contentView?.layoutSubtreeIfNeeded()
        let controls = hub.canvas.controls
        #expect(hub.canvas.showsDisabledControls && !controls.isHidden)
        #expect(controls.groups == [[.home, .screenshot, .recordScreen], [.rotateLeft, .poseClosed, .posePartiallyOpen, .poseOpen]])
        #expect(controls.capsules.count == 2 && controls.capsules[1].frame.width == 145.5)
        #expect(controls.groups.joined().allSatisfy { controls.button(for: $0)?.isEnabled == false })
        #expect(controls.highlightedPose == .poseClosed)
        // A picture of the window for the report (`YCODE_B5_SHOTS=<folder>`).
        if let dir = ProcessInfo.processInfo.environment["YCODE_B5_SHOTS"], let frame = w.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mac-dark-devices-duo.png"))
        }
        // Ycode's own images: Rotate a template, the postures in their colours.
        let rotate = try #require(controls.button(for: .rotateLeft)?.image)
        #expect(rotate.isTemplate && rotate.accessibilityDescription == "Rotate")
        #expect(abs(rotate.size.width - 21) <= 1 && abs(rotate.size.height - 23.5) <= 1, "\(rotate.size)")
        let closed = try #require(controls.button(for: .poseClosed)?.image)
        #expect(!closed.isTemplate)
        // The current posture's outline is the accent, read back from its image.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(closed.size.width) * 4, pixelsHigh: Int(closed.size.height) * 4,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB))
        rep.size = closed.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            closed.draw(in: NSRect(origin: .zero, size: closed.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        // The left edge of the outline, half way down, and the fill inside.
        let midY = Int(closed.size.height * 2)
        let edge = (0..<rep.pixelsWide / 2).compactMap { x -> NSColor? in
            guard let c = rep.colorAt(x: x, y: midY), c.alphaComponent > 0.9 else { return nil }
            return c
        }.first
        #expect(edge.map { $0.blueComponent > 0.9 && $0.redComponent < 0.1 } == true, "accent outline \(String(describing: edge))")
        let inside = rep.colorAt(x: rep.pixelsWide / 2 - 4, y: midY + 8)
        #expect(inside.map { abs($0.redComponent - 0x2D / 255) < 0.03 && abs($0.blueComponent - 0x6D / 255) < 0.03 } == true,
                "fill #2D4B6D, got \(String(describing: inside))")
    }
}
