import AppKit
import Foundation
import Testing
import YcodeDeviceModel
@testable import YcodeUI

/// FOLD (`specs/simulator/foldable.md` §8.3 E1–E3): the fold controls of
/// Ycode's remote iPhone Duo in Devices and Simulators, the control command
/// the IDE sends through ssh, and the reply it reads. No network.
@MainActor
@Suite(.serialized) struct FoldControlsTests {
    func settings() -> RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode",
                                        runtimeRoot: "/rt/iOS-27.1-24A94401/RuntimeRoot", simdPath: "/data/ycode/bin/ycode-sim")
        s.otherRuntimeRoots = ["/rt/iOS-27.0-24A434/RuntimeRoot"]
        s.runtimeVersion = "27.1"
        s.runtimeVersions = ["/rt/iOS-27.1-24A94401/RuntimeRoot": "27.1", "/rt/iOS-27.0-24A434/RuntimeRoot": "27.0"]
        return s
    }

    @Test func onlyTheIPhoneDuoFolds() {
        let all = RemoteSimulator.all(settings())
        let foldable = all.filter(\.isFoldable).map { $0.target!.deviceType.id }
        #expect(foldable == ["iphone-duo"])
        let rows = all.map { DeviceRow.ycodeRemote($0, running: true) }
        #expect(rows.filter(\.isFoldable).map(\.name) == ["iPhone Duo (Ycode)"])
    }

    @Test func controlCommandAndStateReply() {
        let duo = RemoteSimulator.all(settings()).first { $0.isFoldable }!
        #expect(duo.controlCommand(["fold", "half"])
            == "exec '/data/ycode/bin/ycode-sim' --device '\(duo.remoteDevicePath)' --control 'fold' 'half'")
        #expect(RemoteSimulator.hingeAngle(stateReply: "ok angle 180° (Open Flat), inner side, portrait; showing LCD-1") == 180)
        #expect(RemoteSimulator.hingeAngle(stateReply: "error: this device type does not fold") == nil)
    }

    func row(foldable: Bool, booted: Bool, name: String = "iPhone Duo (Ycode)") -> DeviceRow {
        DeviceRow(name: name, identifier: "h:/data/ycode/devices/\(name)", platform: "iOS", osVersion: "27.1",
                  state: booted ? "Booted" : "Shutdown", model: "Ycode Simulator (Linux)", isAvailable: true,
                  isYcodeRemote: true, isFoldable: foldable)
    }

    @Test func controlsForAFoldableRowOnly() async {
        let duo = row(foldable: true, booted: true), pad = row(foldable: false, booted: true, name: "iPad (A16) (Ycode)")
        let c = DevicesController(devices: [], simulators: [duo, pad])
        var sent: [[String]] = []
        c.foldDevice = { _, words in
            sent.append(words)
            return words == ["state"] ? (true, "ok angle 0° (Closed), cover side, portrait; showing LCD") : (true, "ok " + words.joined(separator: " "))
        }
        c.show(.simulators)
        c.select(row: 0)
        await c.foldTask?.value
        #expect(c.foldControlsShown && c.foldControlsEnabled)
        #expect(sent == [["state"]] && c.hingeAngle == 0)
        // The pose buttons and the slider send a sweep to the angle; the check mark follows.
        await c.fold(to: 180)?.value
        #expect(sent.last == ["fold", "180"] && c.hingeAngle == 180 && c.foldStatus == "At 180°")
        // The row's context menu: Shut Down / Restart / Force Shut Down, Open
        // in New Window, the poses in the reference's words, rotation, erase.
        let menu = c.contextMenu(forRow: 0)
        #expect(menu.items.map(\.title) == ["Shut Down", "Restart", "Force Shut Down", "", "Open in New Window", "",
                                            "Closed", "Partially Open", "Open", "Rotate Left", "Rotate Right", "", DevicesController.eraseTitle])
        let item = { (t: String) in menu.items.first { $0.title == t }! }
        #expect(item("Open").state == .on && item("Closed").state == .off && item("Closed").isEnabled)
        await c.rotate(left: true)?.value
        #expect(sent.last == ["rotate", "left"])
        #expect(c.detailRows.contains { $0.0 == "Fold" && $0.1 == "180° (Open)" })
        // Without a live display, the canvas's pose and rotate commands use the control socket.
        #expect(c.performWithoutDisplay(.posePartiallyOpen))
        await c.foldTask?.value
        #expect(sent.last == ["fold", "90"] && c.hingeAngle == 90)
        // An iPad row has none of it.
        c.select(row: 1)
        #expect(!c.foldControlsShown && !c.foldControlsEnabled)
        #expect(c.contextMenu(forRow: 1).items.map(\.title) == ["Shut Down", "Restart", "Force Shut Down", "", "Open in New Window", "",
                                                                DevicesController.eraseTitle])
        #expect(c.fold(to: 90) == nil && !c.performWithoutDisplay(.poseOpen))
    }

    @Test func aStoppedDeviceStartsClosedAndCannotFold() async {
        let c = DevicesController(devices: [], simulators: [row(foldable: true, booted: true)])
        c.foldDevice = { _, w in (true, w == ["state"] ? "ok angle 90° (Half Open)" : "ok") }
        c.show(.simulators)
        await c.foldTask?.value
        #expect(c.hingeAngle == 90)
        // The run ends: the angle is forgotten (the next boot starts closed).
        c.setYcodeRemote(rows: [row(foldable: true, booted: false)])
        #expect(c.hingeAngle == nil && c.foldControlsShown && !c.foldControlsEnabled)
        #expect(c.detailRows.contains { $0.0 == "Fold" && $0.1 == "Closed when it boots" })
        #expect(c.contextMenu(forRow: 0).items.filter { DevicePosture.allCases.map(\.title).contains($0.title) }.allSatisfy { !$0.isEnabled })
        // The canvas shows the stopped device with Start (no pose controls without a device).
        _ = c.view
        #expect(c.canvas.stateDescription == "stopped")
    }
}
