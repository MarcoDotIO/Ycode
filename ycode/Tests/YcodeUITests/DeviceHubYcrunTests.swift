import AppKit
import Foundation
import Testing
@testable import YcodeDeviceModel
@testable import YcodeIDECore
import YcodeSimControl
@testable import YcodeUI

/// The macOS hub and devices `ycrun` booted (`specs/ide/ycrun.md` §11): a
/// device with a live pid file in `<data>/ycrun` on the host is listed as
/// running, and Shut Down stops it as `ycrun simctl shutdown` does (SIGTERM
/// to that pid). The host is a folder here and `ssh` a stand-in that runs
/// the command with `/bin/sh`; the "launcher" is a `sleep` this test starts
/// and stops by its exact pid. No window is shown.
@MainActor
@Suite(.serialized) struct DeviceHubYcrunTests {
    private static let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let iosRoot = "/rr/iOS-27.1-24A94401/RuntimeRoot"

    func makeHost(_ tag: String) throws -> (root: URL, settings: RemoteSimulatorSettings) {
        let root = Self.ycodeDir.appendingPathComponent(".build-ide/hub-ycrun-\(tag)-\(UUID().uuidString.prefix(8))")
        let ssh = root.appendingPathComponent("bin/fake-ssh")
        try writeExecutable("""
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) shift 2 ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        shift
        exec /bin/sh -c "$*"
        """, ssh)
        let simd = root.appendingPathComponent("bin/ycode-sim")
        try writeExecutable("#!/bin/sh\nexit 1\n", simd)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/devices"), withIntermediateDirectories: true)
        var s = RemoteSimulatorSettings(destination: "tester@fakehost", dataDirectory: root.appendingPathComponent("data").path,
                                        runtimeRoot: Self.iosRoot, simdPath: simd.path, deviceName: "dev", ssh: ssh.path)
        s.runtimeVersion = "27.1"
        return (root, s)
    }

    /// A process standing in for the launcher ycrun started (its pid in the pid file).
    func startLauncher() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["300"]
        try p.run()
        return p
    }

    @Test func aDeviceYcrunBootedIsRunningAndShutDownSendsSIGTERMToItsPid() async throws {
        let t = TestDefaults("hub-ycrun")
        let (root, settings) = try makeHost("stop")
        let launcher = try startLauncher()
        defer {
            if launcher.isRunning { kill(launcher.processIdentifier, SIGKILL) }
            t.remove()
            try? FileManager.default.removeItem(at: root)
        }
        settings.save(t.defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.1", root: Self.iosRoot, t.defaults)
        RemoteSimulatorSettings.saveRuntimePlatform("iOS", root: Self.iosRoot, t.defaults)
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [])
        hub.configureStandalone(defaults: t.defaults, ssh: settings.ssh, simctl: nil)
        hub.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let row = try #require(hub.simulators.first { $0.isYcodeRemote })
        #expect(row.state == "Shutdown")
        // ycrun booted it: `<data>/ycrun/<device>.pid` names a live launcher.
        let remote = try #require(RemoteSimulator.hub(RemoteSimulatorSettings.load(t.defaults)).first {
            "\(settings.destination):\($0.remoteDevicePath)" == row.identifier
        })
        let dir = DevicesController.deviceDirectory(remote)
        let pidFile = YcrunDeviceFiles.pidFile(data: settings.dataDirectory, directory: dir)
        try FileManager.default.createDirectory(atPath: YcrunDeviceFiles.stateDirectory(data: settings.dataDirectory), withIntermediateDirectories: true)
        try "\(launcher.processIdentifier)\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        // A dead pid file is not a running device.
        try "999999\n".write(toFile: YcrunDeviceFiles.pidFile(data: settings.dataDirectory, directory: "gone"), atomically: true, encoding: .utf8)
        await hub.pollYcrun(force: true)?.value
        #expect(hub.ycrunBooted == [dir])
        let booted = try #require(hub.simulators.first { $0.identifier == row.identifier })
        #expect(booted.state == "Booted")
        #expect(hub.canShutDown(booted))
        // Shut Down: SIGTERM to the launcher, the pid file removed, the row shut down.
        await hub.shutDown(booted)?.value
        launcher.waitUntilExit()
        #expect(launcher.terminationReason == .uncaughtSignal && launcher.terminationStatus == SIGTERM)
        #expect(!FileManager.default.fileExists(atPath: pidFile))
        #expect(hub.simulators.first { $0.identifier == row.identifier }?.state == "Shutdown")
        await hub.pollYcrun(force: true)?.value
        #expect(hub.ycrunBooted.isEmpty)
        #expect(hub.simulators.first { $0.identifier == row.identifier }?.state == "Shutdown")
    }

    @Test func aHostThatDoesNotAnswerKeepsTheLastAnswer() async throws {
        let t = TestDefaults("hub-ycrun-offline")
        var (root, settings) = try makeHost("offline")
        defer { t.remove(); try? FileManager.default.removeItem(at: root) }
        settings.ssh = "/usr/bin/false"
        settings.save(t.defaults)
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [])
        hub.configureStandalone(defaults: t.defaults, ssh: settings.ssh, simctl: nil)
        hub.ycrunBooted = ["dev"]
        await hub.pollYcrun(force: true)?.value
        #expect(hub.ycrunBooted == ["dev"])
    }
}
