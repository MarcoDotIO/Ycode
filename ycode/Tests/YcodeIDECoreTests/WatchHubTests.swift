import Foundation
import Testing
import YcodeBuild
import YcodeDeviceModel
@testable import YcodeIDECore

/// watchOS W2 (`specs/simulator/watchos.md` §7.2 W2, §11; `specs/ide/device-hub.md`
/// §4.3, §5.2): a watchOS runtime root gives Device Hub its watches (not run
/// destinations), the runtime's platform is read from `SystemVersion.plist`
/// `ProductName` ("Watch OS"), and watch rows carry the watch family and
/// frame. No network; preferences in a scratch domain.
@MainActor
@Suite(.serialized) struct WatchHubTests {
    static let watchRoot = "/rt/watchOS-27.0-24R362/RuntimeRoot"

    func settings() -> RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode",
                                        runtimeRoot: "/rt/iOS-27.1-24A94401/RuntimeRoot", simdPath: "/data/ycode/bin/ycode-sim")
        s.otherRuntimeRoots = [Self.watchRoot]
        s.runtimeVersion = "27.1"
        s.runtimeVersions = ["/rt/iOS-27.1-24A94401/RuntimeRoot": "27.1", Self.watchRoot: "27.0"]
        return s
    }

    @Test func watchTypesPerRuntimeVersion() {
        #expect(YcodeSimulatorDeviceType.watches.count == 13)
        #expect(YcodeSimulatorDeviceType.watches.allSatisfy { $0.platform == "watchOS" })
        #expect(YcodeSimulatorDeviceType.all.allSatisfy { $0.platform == "iOS" })
        // watchos.md §3.1 "default create" on 27.0: Series 12 46 and 42 mm, Ultra 4, SE 3 44 and 40 mm.
        #expect(YcodeSimulatorDeviceType.watches(onRuntimeVersion: "27.0").map(\.id)
            == ["apple-watch-series-12-46mm", "apple-watch-series-12-42mm", "apple-watch-ultra-4-49mm",
                "apple-watch-se-3-44mm", "apple-watch-se-3-40mm"])
        #expect(YcodeSimulatorDeviceType.watches(onRuntimeVersion: "26.2").map(\.id)
            == ["apple-watch-series-11-46mm", "apple-watch-series-11-42mm", "apple-watch-ultra-3-49mm",
                "apple-watch-se-3-44mm", "apple-watch-se-3-40mm"])
        #expect(YcodeSimulatorDeviceType.watches(onRuntimeVersion: nil).first?.id == "apple-watch-series-12-46mm")
        #expect(YcodeSimulatorDeviceType.named("apple-watch-ultra-4-49mm")?.platform == "watchOS")
        // Every IDE watch type has Ycode's frame.
        for t in YcodeSimulatorDeviceType.watches { #expect(DeviceFrameSpec.named(typeID: t.id)?.family == .watch, "\(t.id)") }
    }

    @Test func watchRowsHaveTheWatchPlatformFamilyAndFrame() {
        let s = settings()
        let remote = RemoteSimulator.hub(s)[s.targets.count]
        let row = DeviceRow.ycodeRemote(remote, running: false)
        #expect(row.platform == "watchOS" && row.osVersion == "27.0" && row.deviceTypeID == "apple-watch-series-12-46mm")
        #expect(!row.isFoldable)
        #expect(HubDevice.family(platform: row.platform, name: row.name) == .watch)
        #expect(DeviceRow.ycodeRemote(RemoteSimulator.all(s)[0], running: false).platform == "iOS")
    }

    @Test func thePlatformIsReadFromSystemVersionAndKeptPerRoot() throws {
        func plist(_ name: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["ProductName": name, "ProductVersion": "27.0", "ProductBuildVersion": "1"],
                                               format: .xml, options: 0)
        }
        #expect(RemoteSimulator.productPlatform(plist: try plist("Watch OS")) == "watchOS")
        #expect(RemoteSimulator.productPlatform(plist: try plist("watchOS")) == "iOS", "only the two-word name is a watch runtime")
        #expect(RemoteSimulator.productPlatform(plist: try plist("xrOS")) == "visionOS")
        #expect(RemoteSimulator.productPlatform(plist: try plist("iPhone OS")) == "iOS")
        #expect(RemoteSimulator.productPlatform(plist: Data("x".utf8)) == nil)
        let t = TestDefaults("watch-hub-platforms")
        defer { t.remove() }
        var s = settings()
        s.save(t.defaults)
        RemoteSimulatorSettings.saveRuntimePlatform("watchOS", root: "/rt/plain", t.defaults)
        var loaded = RemoteSimulatorSettings.load(t.defaults)
        loaded.otherRuntimeRoots = ["/rt/plain"]
        #expect(loaded.runtimePlatforms == ["/rt/plain": "watchOS"])
        #expect(loaded.runtimePlatform(forRoot: "/rt/plain") == "watchOS")
        #expect(loaded.targets.allSatisfy { $0.runtimeRoot != "/rt/plain" })
        #expect(loaded.hubTargets.contains { $0.runtimeRoot == "/rt/plain" && $0.deviceType.platform == "watchOS" })
    }
}
