import Foundation
import Testing
@testable import YcodeBuild

@Suite struct DestinationTests {
    let simctl = Data("""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
        {"udid": "S1", "name": "Phone A", "isAvailable": true, "state": "Shutdown"},
        {"udid": "S2", "name": "Phone B", "isAvailable": false, "state": "Shutdown"}],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"udid": "S3", "name": "Phone A", "isAvailable": true, "state": "Booted"}],
      "com.apple.CoreSimulator.SimRuntime.xrOS-3-0": [
        {"udid": "S4", "name": "Headset", "isAvailable": true}],
      "com.apple.CoreSimulator.SimRuntime.Unknown-1-0": [{"udid": "S5", "name": "X"}]
    }}
    """.utf8)
    let devicectl = Data("""
    {"info": {}, "result": {"devices": [
      {"identifier": "X1", "deviceProperties": {"name": "Test Phone", "osVersionNumber": "27.0"},
       "hardwareProperties": {"platform": "iOS", "udid": "0000-AAAA", "reality": "physical"}},
      {"identifier": "X2", "deviceProperties": {"name": "Sim"},
       "hardwareProperties": {"platform": "iOS", "udid": "S1", "reality": "simulated"}}]}}
    """.utf8)

    @Test func parsesListings() {
        let sims = DestinationCatalog.simulators(fromSimctlJSON: simctl)
        #expect(Set(sims.compactMap(\.identifier)) == ["S1", "S3", "S4"])
        #expect(sims.first { $0.identifier == "S4" }?.platform == "visionOS")
        #expect(sims.first { $0.identifier == "S1" }?.specifier == "platform=iOS Simulator,id=S1")
        let devs = DestinationCatalog.devices(fromDevicectlJSON: devicectl)
        #expect(devs == [Destination(name: "Test Phone", specifier: "platform=iOS,id=0000-AAAA", platform: "iOS",
                                     kind: .device, osVersion: "27.0", identifier: "0000-AAAA")])
    }

    @Test func groupsLikeThePopUp() {
        let g = DestinationCatalog.groups(devices: DestinationCatalog.devices(fromDevicectlJSON: devicectl),
                                          simulators: DestinationCatalog.simulators(fromSimctlJSON: simctl))
        #expect(g.map(\.title) == ["My Mac", "Build", "iOS Device", "iOS Simulators", "visionOS Device", "visionOS Simulators"])
        #expect(g[2].destinations.map(\.name) == ["Test Phone", "Any iOS Device (arm64)"])
        // Same-named simulators keep their names (rows show the OS version), newest first.
        #expect(g[3].destinations.map(\.name) == ["Any iOS Simulator Device", "Phone A", "Phone A"])
        #expect(g[3].destinations.map(\.osVersion) == [nil, "27.0", "26.4"])
        #expect(g[3].destinations[0].specifier == "generic/platform=iOS Simulator")
    }

    #if os(macOS)
    /// The live listing (read-only) always starts with the Mac.
    @Test func liveListing() {
        let g = DestinationCatalog.load()
        #expect(g.first?.destinations.first == .myMac)
        print("destination groups:", g.map { "\($0.title)=\($0.destinations.count)" })
    }
    #endif
}
