import AppKit
import Foundation
import Testing
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 4 on the Device Hub (`specs/ide/device-hub.md` §12,
/// checklist rows 104 and 105) with the round 3 suite's test doubles (no
/// simulator is booted): the compact-window button is enabled whenever the
/// window shows a device, and the canvas floats the control capsules for a
/// device Ycode does not operate, every control disabled.
@MainActor
@Suite(.serialized) struct DeviceHubR4Tests {
    let r3 = DeviceHubR3Tests()

    func openItem(_ w: NSWindow) throws -> NSToolbarItem {
        try #require(w.toolbar?.items.first { $0.itemIdentifier == DeviceHubToolbar.open })
    }

    @Test func compactWindowButtonIsEnabledWithADevice() throws {
        let t = TestDefaults("hub-r4-open")
        let (hub, w) = r3.makeHub(t)
        defer { w.close() }
        let item = try openItem(w)
        for row in [DeviceHubR3Tests.duo, DeviceHubR3Tests.stopped, DeviceHubR3Tests.other] {
            hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == row.identifier }))
            w.toolbar?.validateVisibleItems()
            #expect(item.isEnabled, "\(row.name)")
        }
    }

    @Test func aDeviceYcodeDoesNotRunExplainsInsteadOfOpening() throws {
        let t = TestDefaults("hub-r4-other")
        let (hub, w) = r3.makeHub(t)
        defer { w.close() }
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == DeviceHubR3Tests.other.identifier }))
        w.contentView?.layoutSubtreeIfNeeded()
        // The canvas: the capsules in place, at full contrast with the reason
        // in their tooltips (round 7, row 175).
        #expect(hub.canvas.showsDisabledControls && !hub.canvas.controls.isHidden)
        #expect(hub.canvas.controls.groups.joined().allSatisfy { hub.canvas.controls.button(for: $0)?.isEnabled == true })
        #expect(hub.canvas.controls.configuration.unavailableReason == DeviceCanvasView.notOperatedReason)
        // The button says why there is no window.
        #expect(hub.openCompactWindowFromToolbar() == nil)
        #expect(hub.compactWindows.isEmpty)
        #expect(Self.texts(hub.canvas).contains(DevicesController.compactWindowNotOperated))
    }

    @Test func aStoppedYcodeSimulatorStartsThenOpens() async throws {
        let t = TestDefaults("hub-r4-start")
        let (hub, w) = r3.makeHub(t)
        defer { w.close() }
        var started: [String] = []
        hub.startDevice = { r in started.append(r.identifier); return (true, "") }
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == DeviceHubR3Tests.stopped.identifier }))
        let task = try #require(hub.openCompactWindowFromToolbar())
        await task.value
        #expect(started == [DeviceHubR3Tests.stopped.identifier])
        #expect(hub.allRows.first { $0.identifier == DeviceHubR3Tests.stopped.identifier }?.state == "Booted")
        for (_, c) in hub.compactWindows { c.close() }
    }

    /// The canvas's visible texts, banners included.
    static func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            if let t = v as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(v)
        return out
    }
}
