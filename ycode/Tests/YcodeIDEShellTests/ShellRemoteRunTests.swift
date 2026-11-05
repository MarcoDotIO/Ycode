import Foundation
import Testing
import YcodeBuild
import YcodeIDECore
import YcodeSimLink
@testable import YcodeIDEShell

/// Run on a Ycode simulator host from the Linux shell (sim-link.md §10).
struct ShellRemoteRunTests {
    @Test func destinationsCarryHostAndDevice() throws {
        let d = ShellRemoteRun.destination(host: "thor", device: LinkDeviceInfo(name: "p18", deviceType: "iphone-18-pro",
                                                                                runtime: "/rt/iOS-27.0-24A434/RuntimeRoot", state: "running"))
        #expect(d.name == "p18 (thor)" && d.platform == "iOS" && d.osVersion == "27.0" && d.deviceType == "iphone-18-pro")
        #expect(d.specifier == "generic/platform=iOS Simulator")
        let t = try #require(ShellRemoteRun.target(of: d))
        #expect(t.host == "thor" && t.device == "p18")
        #expect(ShellRemoteRun.target(of: .myMac) == nil)
    }

    @Test func buildCommandAndBuiltApp() throws {
        #expect(ShellRemoteRun.buildCommand(project: "/p/A.xcodeproj", scheme: "A", derivedData: "/dd", script: "/s")
                == ["/s", "/p/A.xcodeproj", "A", "/dd"])
        let dd = FileManager.default.temporaryDirectory.appendingPathComponent("rr-\(UUID().uuidString)")
        let products = dd.appendingPathComponent("Products/Debug-iphonesimulator")
        try FileManager.default.createDirectory(at: products.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: products.appendingPathComponent("A.app"), withIntermediateDirectories: true)
        #expect(ShellRemoteRun.builtApp(derivedData: dd.path, scheme: "A")?.lastPathComponent == "A.app")
        #expect(ShellRemoteRun.builtApp(derivedData: dd.path, scheme: "B")?.lastPathComponent == "A.app")
        #expect(ShellRemoteRun.builtApp(derivedData: "/nonexistent", scheme: "A") == nil)
        #expect(ShellRemoteRun.derivedDataRoot(environment: ["XDG_CACHE_HOME": "/c"]).path == "/c/ycode/remote-run")
        #expect(ShellRemoteRun.derivedDataRoot(environment: ["XDG_CACHE_HOME": "relative"]).path.hasSuffix("/.cache/ycode/remote-run"))
    }

    @Test func headsetHook() {
        let vp = ShellRemoteRun.destination(host: "thor", device: LinkDeviceInfo(name: "vp", deviceType: "vision-pro",
                                                                                 runtime: "/rt/xrOS-27.0-24M362/RuntimeRoot", state: "running"))
        #expect(ShellRemoteRun.headsetArguments(destination: vp, toHeadset: true, viewerOptions: ["--foveate"])
                == ["view", "vp", "--link", "--host", "thor", "--", "--foveate"])
        #expect(ShellRemoteRun.headsetArguments(destination: vp, toHeadset: false) == ["desktop", "vp", "--link", "--host", "thor"])
        let phone = ShellRemoteRun.destination(host: "thor", device: LinkDeviceInfo(name: "p18", deviceType: "iphone-18-pro",
                                                                                    runtime: "/rt/iOS-27.0-24A434/RuntimeRoot", state: "running"))
        #expect(ShellRemoteRun.headsetArguments(destination: phone, toHeadset: true) == nil)
        // `ycode sim remote view … --xr --background | --desktop` maps onto the same commands.
        #expect(HeadsetCLI.remoteView(["--host", "thor", "view", "vp", "--xr", "--background", "--foveate"])?.headset
                == ["view", "vp", "--link", "--host", "thor", "--", "--foveate"])
        let back = HeadsetCLI.remoteView(["view", "vp", "--desktop"])
        #expect(back?.headset == ["desktop", "vp"] && back?.viewer == ["view", "vp"])
        #expect(HeadsetCLI.remoteView(["view", "vp", "--desktop", "--no-window"])?.viewer == nil)
        #expect(HeadsetCLI.remoteView(["view", "vp", "--xr"]) == nil)
    }
}
