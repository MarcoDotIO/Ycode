import Foundation
import Testing
import YcodeSimFeatures
@testable import YcodeIDECore

/// FEAT (`specs/ide/devices.md` §Settings, `debug.md` §Environment
/// Overrides; `specs/simulator/simulator-features.md` §7): the settings
/// boxes of a running Ycode simulator in Devices and Simulators, the debug
/// bar's Environment Overrides and Simulate Location, and the commands they
/// send. No network: the commands go to stand-ins.
@MainActor
@Suite(.serialized) struct SimulatorSettingsUITests {
    static let reply = """
        ok appearance dark
        liquid-glass 0.40 tinted
        content-size extra-large
        larger-accessibility-sizes off
        color-filter deuteranopia 0.50
        reduce-motion on
        increase-contrast off
        show-borders on
        reduce-transparency off
        voiceover off
        voiceover-running no
        volume 35
        output none
        input system
        agent pid 109
        changes 3
        """

    @Test func snapshotFromTheSettingsReply() {
        let s = DeviceSettingsSnapshot(reply: Self.reply)!
        #expect(s.state.appearance == .dark && s.state.glassOpacity == 0.4 && s.state.glassLook == .tinted)
        #expect(s.state.contentSize == .extraLarge && s.state.colorFilter == .deuteranopia && s.state.colorFilterIntensity == 0.5)
        #expect(s.state.isOn(.reduceMotion) && s.state.isOn(.showBorders) && !s.state.isOn(.voiceOver))
        #expect(s.volume == 35 && s.output == "none" && s.input == "system")
        #expect(DeviceSettingsSnapshot(reply: "error: no agent") == nil)
    }

    @Test func remoteRunsTakeOverrides() {
        var s = RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode",
                                        runtimeRoot: "/rt/iOS-27.1-24A94401/RuntimeRoot", simdPath: "/data/ycode/bin/ycode-sim")
        s.runtimeVersion = "27.1"
        let r = RemoteSimulator.all(s).first!
        #expect(r.runCommand(app: URL(fileURLWithPath: "/tmp/A.app"), bundleID: "dev.a").contains("--launch 'dev.a' --environment-overrides"))
        #expect(r.controlCommand(["ui", "appearance", "dark"]).hasSuffix("--control 'ui' 'appearance' 'dark'"))
    }
}
