import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeDeviceUI
@testable import YcodeIDECore
@testable import YcodeUI

/// Council round 8, row 196, on the macOS hub: an iPad of a type Ycode has
/// no frame for, named by its user in lower case ("ycode-test-council-ipad",
/// the round's device), as `simctl list -j` lists it, is drawn with the
/// tablet outline at Zoom to Fit (556 × 769 at 1400 × 900, 485.5 × 671 at
/// 1100 × 800) under the subtitle "iPadOS 27.2", whether or not the listing
/// names the type. Offscreen; `YCODE_B8_SHOTS=<dir>` saves pictures.
@MainActor
@Suite(.serialized) struct DeviceHubR8Tests {
    let r7 = DeviceHubR7Tests()

    /// The round's simulators as simctl lists them, with or without the
    /// device-type table.
    static func listing(withTypes: Bool) -> [DeviceRow] {
        let types = withTypes ? #","devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4","name":"iPad Air 11-inch (M4)"}]"# : ""
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"name":"ycode-test-council-ipad","udid":"UDID-COUNCIL-IPAD","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"}]}"#
            + types + "}"
        return DevicesList.simulators(simctlJSON: Data(json.utf8))
    }

    func hub(_ t: TestDefaults, _ rows: [DeviceRow], width: CGFloat, height: CGFloat) throws -> (DevicesController, NSWindow) {
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: rows + [DeviceHubR7Tests.iPhone17])
        hub.defaults = t.defaults
        let w = hub.makeWindow()
        w.isExcludedFromWindowsMenu = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.setFrameAutosaveName("")
        hub.splitView.autosaveName = nil
        w.setContentSize(NSSize(width: width, height: height))
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderBack(nil)
        w.contentView?.layoutSubtreeIfNeeded()
        hub.placeFirstDividers()
        hub.select(row: try #require(hub.rows.firstIndex { $0.identifier == "UDID-COUNCIL-IPAD" }))
        hub.splitViewItems[0].isCollapsed = true
        hub.splitViewItems[2].isCollapsed = true
        w.contentView?.layoutSubtreeIfNeeded()
        return (hub, w)
    }

    @Test(arguments: [true, false])
    func anIPadOfAnUnknownTypeIsATabletWithIPadOS(_ withTypes: Bool) throws {
        let rows = Self.listing(withTypes: withTypes)
        let row = try #require(rows.first)
        #expect(row.name == "ycode-test-council-ipad" && row.deviceTypeID == nil)
        #expect(DeviceFrameSpec.named(name: row.model) == nil, "a type Ycode has a frame for: \(row.model)")
        for (ww, wh, bw, bh) in [(CGFloat(1100), CGFloat(800), 485.5, 671.0), (1400, 900, 556, 769)] {
            let t = TestDefaults("hub-r8-ipad-\(withTypes)-\(Int(ww))")
            defer { t.remove() }
            let (hub, w) = try hub(t, rows, width: ww, height: wh)
            defer { w.close() }
            #expect(hub.canvas.zoom == .fit)
            #expect(w.title == "ycode-test-council-ipad" && w.subtitle == "iPadOS 27.2", "\(w.subtitle)")
            let f = hub.canvas.frameView
            #expect(f.geometry.body.size == CGSize(width: 940, height: 1300) && f.geometry.screenRadii == CornerRadii(all: 19))
            let b = r7.body(hub, w)
            #expect(abs(b.width - bw) <= 1.5 && abs(b.height - bh) <= 1.5, "\(ww): body \(b)")
            #expect(abs(b.midY - (52 + (wh - 96) / 2)) <= 1.5 && abs(b.midX - ww / 2) <= 1.5)
            print("R8A row 196 (types \(withTypes)): \(Int(ww)) × \(Int(wh)) body \(b.width) × \(b.height), subtitle \(w.subtitle)")
            if withTypes { DeviceHubR7Tests.shotB8(w, "mac-r8-196-ipad-\(Int(ww)).png") }
        }
    }
}

extension DeviceHubR7Tests {
    static func shotB8(_ w: NSWindow, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["YCODE_B8_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        UISpacingProbeTests.shot(w, URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
