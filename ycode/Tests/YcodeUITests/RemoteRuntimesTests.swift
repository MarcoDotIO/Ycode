import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// IOS27 (`specs/ide/run.md` §Runtimes and device types): Ycode's remote
/// simulator with more than one runtime root, one destination row per
/// runtime and device type, each with its own device directory, and the
/// run command naming the runtime and the type. No network.
@MainActor
@Suite(.serialized) struct RemoteRuntimesTests {
    func settings() -> RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode",
                                        runtimeRoot: "/rt/iOS-27.1-24A94401/RuntimeRoot", simdPath: "/data/ycode/bin/ycode-sim")
        s.otherRuntimeRoots = ["/rt/iOS-27.0-24A434/RuntimeRoot"]
        s.runtimeVersion = "27.1"
        s.runtimeVersions = ["/rt/iOS-27.1-24A94401/RuntimeRoot": "27.1", "/rt/iOS-27.0-24A434/RuntimeRoot": "27.0"]
        return s
    }

    @Test func menuListsEveryRuntimeAndTypeAndRemembersTheChoice() throws {
        let t = TestDefaults("ios27-menu")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ios27-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        settings().save(p.defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.1", root: "/rt/iOS-27.1-24A94401/RuntimeRoot", p.defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.0", root: "/rt/iOS-27.0-24A434/RuntimeRoot", p.defaults, primary: false)
        var o = ProjectOptions()
        // The fixtures' simulator runtimes predate V(iOS) (templates.md § Notation).
        o.deploymentTarget = "18.0"
        o.productName = "Tour"
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        let proj = try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
        _ = NSApplication.shared
        let state = dir.appendingPathComponent("state.json")
        func window() throws -> WorkspaceWindowController {
            WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: proj)), loadDestinations: false,
                                      startLanguageService: false, openFirstFile: false, userStateURL: state)
        }
        let wc = try window()
        wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: []))
        let sub = wc.destinationMenuModel().rows("Simulators").map { DestinationMenuModel.submenuTitle($0) }
        #expect(sub == ["iPhone Duo (Ycode) 27.1", "iPad (A16) (Ycode) 27.1", "iPad Pro 13-inch (M5) (Ycode) 27.1",
                        "iPhone 18 Pro (Ycode) 27.0", "iPad (A16) (Ycode) 27.0", "iPad Pro 13-inch (M5) (Ycode) 27.0"])
        let pad27 = "ycode-remote-simulator:ipad-pro-13-m5@/rt/iOS-27.0-24A434/RuntimeRoot"
        wc.selectDestinationRow(pad27)
        #expect(wc.session.destination?.identifier == pad27 && wc.session.destination?.osVersion == "27.0")
        // Reopening restores the same runtime and type.
        let again = try window()
        again.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: []))
        #expect(again.session.destination?.identifier == pad27)
        let remote = RemoteSimulator(settings: RemoteSimulatorSettings.load(p.defaults), destination: again.session.destination)
        #expect(remote.remoteDevicePath == "/data/ycode/devices/ycode-device-ipad-pro-13-m5-27.0")
        // The Devices window lists one row per runtime and type.
        let c = DevicesController(devices: [], simulators: [])
        again.configureYcodeRemoteDevice(c, defaults: p.defaults)
        #expect(c.simulators.map { "\($0.name) \($0.osVersion)" } == ["iPhone Duo (Ycode) 27.1", "iPad (A16) (Ycode) 27.1",
                                                                      "iPad Pro 13-inch (M5) (Ycode) 27.1", "iPhone 18 Pro (Ycode) 27.0",
                                                                      "iPad (A16) (Ycode) 27.0", "iPad Pro 13-inch (M5) (Ycode) 27.0"])
        #expect(Set(c.simulators.map(\.identifier)).count == 6)
    }
}
