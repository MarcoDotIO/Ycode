import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeDeviceModel
@testable import YcodeIDECore
@testable import YcodeUI

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

    @Test func aWatchRuntimeGivesHubDevicesAndWatchDestinations() {
        let s = settings()
        #expect(s.runtimePlatform(forRoot: Self.watchRoot) == "watchOS")
        #expect(s.runtimePlatform(forRoot: "/rt/iOS-27.1-24A94401/RuntimeRoot") == "iOS")
        // iOS targets: the iOS root's; the watches are run destinations of watchOS schemes (since W6, device-pairing.md §13).
        #expect(s.targets.allSatisfy { $0.runtimeRoot != Self.watchRoot && $0.deviceType.platform == "iOS" })
        #expect(RemoteSimulator.destinations(s).count == s.targets.count + s.watchTargets.count)
        #expect(RemoteSimulator.destinations(s).dropFirst(s.targets.count).allSatisfy { $0.platform == "watchOS" })
        // The hub: the run destinations, then the watches.
        let hub = s.hubTargets
        #expect(Array(hub.prefix(s.targets.count)) == s.targets)
        let watches = hub.dropFirst(s.targets.count)
        #expect(watches.map(\.deviceType.id).first == "apple-watch-series-12-46mm" && watches.count == 5)
        #expect(watches.allSatisfy { $0.runtimeRoot == Self.watchRoot && !$0.isPrimary && $0.runtimeVersion == "27.0" })
        #expect(watches.first?.deviceDirectoryName == "ycode-device-apple-watch-series-12-46mm-27.0")
        #expect(watches.first?.name == "Apple Watch Series 12 (46mm) (Ycode)")
        // Its start command names the watch type and the watch runtime.
        let remote = RemoteSimulator.hub(s)[s.targets.count]
        #expect(remote.startCommand.contains("'--device-type' 'apple-watch-series-12-46mm'"), "\(remote.startCommand)")
        #expect(remote.startCommand.contains(Self.watchRoot))
        // Previews never use a watch.
        #expect(WorkspaceWindowController.previewSimulators(s).allSatisfy { $0.runtimeRoot != Self.watchRoot })
    }
}
