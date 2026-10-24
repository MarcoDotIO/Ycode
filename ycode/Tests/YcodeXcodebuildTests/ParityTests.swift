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
