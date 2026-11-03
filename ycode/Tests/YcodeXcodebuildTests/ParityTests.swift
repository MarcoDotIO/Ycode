import Foundation
import Testing
@testable import YcodeXcodebuild

/// Placement of target-level warnings, destination listings and local
/// package schemes (`specs/xcodebuild/build-actions.md`, `info-commands.md`,
/// `packages.md`).
@Suite struct ParityDetailTests {
    @Test func deferredTargetWarnings() {
        let capture = CapturingConsole()
        var log = BuildLog(quiet: false, console: capture.console, schemeName: "Tool", projectName: "Tool")
        log.deferTargetIssues = true
        log.handle(["kind": "targetStarted", "id": 0, "name": "Tool", "projectName": "Tool"])
        log.handle(["kind": "warning", "message": "target warning", "locationContext": ["locationType": "target", "targetID": 0]])
        log.handle(["kind": "taskStarted", "id": 1, "targetID": 0, "ruleInfo": "Touch /x"])
        log.handle(["kind": "taskComplete", "id": 1, "result": "success"])
        log.handle(["kind": "buildCompleted", "result": "ok"])
        _ = log.finish(action: .archive)
        #expect(capture.stdout.hasSuffix("\nwarning: target warning (in target 'Tool' from project 'Tool')\n** ARCHIVE SUCCEEDED **\n\n"))
        #expect(capture.stdout.hasPrefix("Touch /x (in target 'Tool' from project 'Tool')\n"))
    }

    @Test func simulatorListing() {
        let devices = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-4":[{"name":"iPad mini","udid":"A","isAvailable":true},{"name":"iPad Pro","udid":"B","isAvailable":true},{"name":"Gone","udid":"G","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.tvOS-26-5":[{"name":"Apple TV","udid":"C","isAvailable":true}]}}"#
        let runtimes = #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-4","version":"26.4.1"}]}"#
        let e = Simulators.entries(devicesJSON: Data(devices.utf8), runtimesJSON: Data(runtimes.utf8))
        // Platform order, then names in byte order ("Pro" before "mini"); full runtime versions.
        #expect(e.map(\.udid) == ["C", "B", "A"])
        #expect(e[1].os == "26.4.1" && e[0].os == "26.5" && e[0].platform == "tvOS Simulator")
    }

    /// device-pairing.md §14.2: a watchOS scheme lists a phone whose active
    /// paired watch is a watchOS simulator as the phone itself; the watches
    /// under their own names; an iOS scheme is unchanged.
    @Test func phoneWithActiveWatchIsAWatchSchemeDestination() {
        let devices = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"name":"iPhone 18 Pro","udid":"P1","isAvailable":true},{"name":"iPhone 18","udid":"P2","isAvailable":true},{"name":"iPhone Air","udid":"P3","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.watchOS-27-0":[{"name":"Watch A","udid":"W1","isAvailable":true},{"name":"Watch B","udid":"W2","isAvailable":true}]}}"#
        let runtimes = #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","version":"27.0"},{"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-27-0","version":"27.0"}]}"#
        let sims = Simulators.entries(devicesJSON: Data(devices.utf8), runtimesJSON: Data(runtimes.utf8))
        // P1 + W1 active; P2's pair inactive; P3's watch is not an available simulator.
        let pairs = #"{"pairs":{"A":{"watch":{"name":"Watch A","udid":"W1","state":"Shutdown"},"phone":{"name":"iPhone 18 Pro","udid":"P1","state":"Booted"},"state":"(active, disconnected)"},"B":{"watch":{"name":"Watch B","udid":"W2"},"phone":{"name":"iPhone 18","udid":"P2"},"state":"(inactive, disconnected)"},"C":{"watch":{"name":"Gone","udid":"W9"},"phone":{"name":"iPhone Air","udid":"P3"},"state":"(active, connected)"}}}"#
        let phones = Simulators.phonesWithActiveWatch(pairsJSON: Data(pairs.utf8), simulators: sims)
        #expect(phones == ["P1"])
        #expect(Simulators.phonesWithActiveWatch(pairsJSON: nil, simulators: sims).isEmpty)
        let err: (String, String) -> String = { n, p in "\(n) \(p)" }
        let watch = Destinations.simulatorLines(sims, phonesWithWatch: phones, supportedPlatforms: ["watchsimulator", "watchos"], arch: "arm64", error: err)
        #expect(watch.compatible == ["{ platform:watchOS Simulator, arch:arm64, id:W1, OS:27.0, name:Watch A }",
                                     "{ platform:watchOS Simulator, arch:arm64, id:W2, OS:27.0, name:Watch B }",
                                     "{ platform:iOS Simulator, arch:arm64, id:P1, OS:27.0, name:iPhone 18 Pro }"])
        #expect(watch.incompatible.count == 2 && watch.incompatible.allSatisfy { !$0.contains("id:P1,") })
        let ios = Destinations.simulatorLines(sims, phonesWithWatch: phones, supportedPlatforms: ["iphonesimulator", "iphoneos"], arch: "arm64", error: err)
        #expect(ios.compatible.count == 3 && ios.incompatible.count == 2 && ios.incompatible.allSatisfy { $0.contains("watchOS Simulator") })
    }

    @Test func physicalDevices() {
        let json = #"{"result":{"devices":[{"hardwareProperties":{"reality":"physical","platform":"iOS","udid":"P","cpuType":{"name":"arm64e"}},"deviceProperties":{"name":"Phone"},"connectionProperties":{"transportType":"localNetwork"}},{"hardwareProperties":{"reality":"physical","platform":"watchOS","udid":"W","cpuType":{"name":"arm64_32"}},"deviceProperties":{"name":"Watch"},"connectionProperties":{}},{"hardwareProperties":{"reality":"simulated","platform":"iOS","udid":"S"},"deviceProperties":{"name":"Sim"},"connectionProperties":{"transportType":"sameMachine"}}]}}"#
        let d = PhysicalDevices.entries(devicectlJSON: Data(json.utf8))
        #expect(d == [DeviceEntry(platform: "iOS", arch: "arm64", deviceArch: "arm64e", udid: "P", name: "Phone")])
    }

    @Test func folderPackageTestSchemes() {
        let manifest = """
        products: [.library(name: "GreeterLib", targets: ["Greeter"]), .executable(name: "Tool", targets: ["Tool"])],
        targets: [.testTarget(name: "GreeterTests"), .testTarget(name: "GreeterLibTests"), .testTarget(name: "ToolTests"), .testTarget(name: "InnerTests")]
        """
        var p = LocalPackage(directory: "/p", products: LocalPackages.productNames(manifest), name: "Greeter", isPackageReference: true,
                             testTargets: LocalPackages.testTargetNames(manifest))
        #expect(p.schemeNames == ["GreeterLib", "Tool"])
        p.addedAsFolder = true
        #expect(p.schemeNames == ["GreeterLib", "Tool", "GreeterTests", "InnerTests"])
    }
}
