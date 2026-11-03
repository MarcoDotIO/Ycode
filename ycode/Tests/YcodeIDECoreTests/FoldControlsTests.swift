import Foundation
import Testing
import YcodeDeviceModel
@testable import YcodeIDECore

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
}
