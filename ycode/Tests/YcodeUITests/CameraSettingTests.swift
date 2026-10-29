import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// Settings ▸ Simulators ▸ Camera (specs/simulator/camera.md "Ycode
/// implementation", specs/ide/run.md): off by default and not passed; once
/// chosen, every run passes `--camera <mode>` (the device keeps the last value).
@MainActor @Suite struct CameraSettingTests {
    @Test func cameraIsOffAndUnsaidUntilChosen() throws {
        let t = TestDefaults("camera-setting")
        defer { t.remove() }
        let prefs = Preferences(defaults: t.defaults)
        let pane = SimulatorsSettingsPane(prefs: prefs)
        _ = pane.view
        pane.update { $0.destination = "u@h"; $0.dataDirectory = "/d"; $0.runtimeRoot = "/r"; $0.simdPath = "/s" }
        let app = URL(fileURLWithPath: "/tmp/Probe.app")
        var s = RemoteSimulatorSettings.load(t.defaults)
        #expect(s.camera == "off" && !s.cameraChosen)
        #expect(!RemoteSimulator(settings: s).runCommand(app: app, bundleID: "dev.ycode.CameraProbe").contains("--camera"))
        #expect(pane.rowTitles.contains("Camera"))
        pane.choose("Host webcam", inRow: "Camera")
        s = RemoteSimulatorSettings.load(t.defaults)
        #expect(s.camera == "on" && s.cameraChosen)
        #expect(RemoteSimulator(settings: s).runCommand(app: app, bundleID: "dev.ycode.CameraProbe")
            .hasSuffix(" '--camera' 'on'"))
        pane.choose("Synthetic pattern", inRow: "Camera")
        #expect(RemoteSimulatorSettings.load(t.defaults).camera == "synthetic")
        // Turned off again: said explicitly, so the device forgets its camera.
        pane.choose("Off", inRow: "Camera")
        s = RemoteSimulatorSettings.load(t.defaults)
        #expect(s.camera == "off" && s.cameraChosen)
        #expect(RemoteSimulator(settings: s).cameraArguments == ["--camera", "off"])
        // An unknown stored value reads as off.
        t.defaults.set("bogus", forKey: "Ycode.remote.camera")
        #expect(RemoteSimulatorSettings.load(t.defaults).camera == "off")
    }
}

/// Device Hub ▸ a Ycode simulator ▸ Settings ▸ Camera (specs/ide/devices.md
/// §Camera): the same setting as Settings ▸ Simulators, on Ycode rows only.
@MainActor @Suite struct CameraDevicesTests {
    @Test func ycodeRowsShowTheSharedCameraSetting() {
        let t = TestDefaults("camera-devices")
        defer { t.remove() }
        var s = RemoteSimulatorSettings(destination: "u@h", dataDirectory: "/d", runtimeRoot: "/r/iOS-27.1-24A94401/RuntimeRoot", simdPath: "/s")
        s.save(t.defaults)
        let ycode = DeviceRow(name: "iPhone 18 Pro (Ycode)", identifier: "u@h:/d/devices/x", platform: "iOS", osVersion: "27.1",
                              state: "Shutdown", model: "Ycode Simulator (Linux)", isAvailable: true, isYcodeRemote: true)
        let other = DeviceRow(name: "iPhone", identifier: "UDID", platform: "iOS", osVersion: "27.1", state: "Shutdown",
                              model: "iPhone", isAvailable: true)
        let c = DevicesController(devices: [], simulators: [ycode, other])
        c.cameraSetting = DevicesController.cameraSetting(t.defaults)
        c.show(.simulators)
        c.select(row: 0)
        _ = c.view
        #expect(c.cameraControlsShown && c.cameraTitle == "Off" && c.inspectorTab == .settings)
        let box = c.cameraControls()
        #expect(box.identifier?.rawValue == "camera-controls")
        let popUp = (box as? NSBox)?.contentView?.subviews.compactMap { $0 as? NSPopUpButton }.first
        #expect(popUp?.itemTitles == DevicesController.cameraTitles && popUp?.titleOfSelectedItem == "Off")
        c.chooseCamera("Host webcam")
        s = RemoteSimulatorSettings.load(t.defaults)
        #expect(s.camera == "on" && s.cameraChosen && c.cameraTitle == "Host webcam")
        #expect(RemoteSimulator(settings: s).cameraArguments == ["--camera", "on"])
        // The hub's Start passes it too.
        #expect(RemoteSimulator(settings: s).startCommand.hasSuffix(" '--camera' 'on'"))
        c.chooseCamera("Nonsense")
        #expect(RemoteSimulatorSettings.load(t.defaults).camera == "on")
        c.chooseCamera("Off")
        #expect(RemoteSimulatorSettings.load(t.defaults).camera == "off")
        // Other simulators have no Ycode camera.
        c.select(row: 1)
        #expect(!c.cameraControlsShown)
    }
}
