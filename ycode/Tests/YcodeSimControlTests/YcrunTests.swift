import Foundation
import Testing
@testable import YcodeSimControl
import YcodeIDECore

/// Where a device runs (specs/ide/ycrun.md §3): every host kind, and the overrides.
@Suite struct PlacementTests {
    let arm = SimMachine(os: .linux, architecture: "aarch64", kvm: .usable)

    @Test func armLinuxWithKVMRunsLocally() throws {
        #expect(try SimPlacementPolicy.decide(machine: arm, request: .init()).placement == .local)
    }

    @Test func armLinuxWithoutKVMUsesTheHostAndSaysWhy() throws {
        for kvm in [SimMachine.KVM.denied, .absent] {
            let d = try SimPlacementPolicy.decide(machine: SimMachine(os: .linux, architecture: "aarch64", kvm: kvm), request: .init())
            #expect(d.placement == .remote(host: nil))
            #expect(d.reason.contains("kvm"))
        }
        #expect(SimPlacementPolicy.localSupport(SimMachine(os: .linux, architecture: "aarch64", kvm: .denied)).reason.contains("usermod -aG kvm"))
    }

    @Test func x86LinuxUsesTheHost() throws {
        let d = try SimPlacementPolicy.decide(machine: SimMachine(os: .linux, architecture: "x86_64", kvm: .usable), request: .init())
        #expect(d.placement == .remote(host: nil))
        #expect(d.reason.contains("x86-64 Linux"))
    }

    @Test func macUsesTheHostUntilTheMachostSwitch() throws {
        let mac = SimMachine(os: .macOS, architecture: "arm64", kvm: .notApplicable)
        #expect(SimPlacementPolicy.macOSRunsLocally == false)
        let d = try SimPlacementPolicy.decide(machine: mac, request: .init())
        #expect(d.placement == .remote(host: nil))
        #expect(d.reason.contains("remote simulator host"))
        #expect(try SimPlacementPolicy.decide(machine: mac, request: .init(), macOSRunsLocally: true).placement == .local)
        let intel = SimMachine(os: .macOS, architecture: "x86_64", kvm: .notApplicable)
        #expect(try SimPlacementPolicy.decide(machine: intel, request: .init(), macOSRunsLocally: true).placement == .remote(host: nil))
    }

    @Test func overrides() throws {
        #expect(try SimPlacementPolicy.decide(machine: arm, request: .init(remote: true)).placement == .remote(host: nil))
        #expect(try SimPlacementPolicy.decide(machine: arm, request: .init(host: "thor")).placement == .remote(host: "thor"))
        #expect(throws: SimPlacementError.self) { try SimPlacementPolicy.decide(machine: arm, request: .init(local: true, host: "x")) }
        let x86 = SimMachine(os: .linux, architecture: "x86_64", kvm: .absent)
        #expect(throws: SimPlacementError.self) { try SimPlacementPolicy.decide(machine: x86, request: .init(local: true)) }
        #expect(try SimPlacementPolicy.decide(machine: arm, request: .init(local: true)).placement == .local)
    }
}

/// Device types, runtimes, UDIDs and device selection.
@Suite struct DeviceSelectionTests {
    @Test func deviceTypesByIdNameOrSimctlIdentifier() {
        #expect(SimDeviceTypes.named("iphone-duo")?.id == "iphone-duo")
        #expect(SimDeviceTypes.named("iPhone Duo")?.id == "iphone-duo")
        #expect(SimDeviceTypes.named("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")?.id == "iphone-duo")
        #expect(SimDeviceTypes.named("iPad Pro 13-inch (M5)")?.id == "ipad-pro-13-m5")
        #expect(SimDeviceTypes.named("Apple-Watch-Series-12-46mm")?.id == "apple-watch-series-12-46mm")
        #expect(SimDeviceTypes.named("toaster") == nil)
    }

    @Test func runtimeIdentifiers() {
        let r = SimRuntime(platform: "iOS", version: "27.1", root: "/d/runtimes/iOS-27.1/RuntimeRoot")
        #expect(r.identifier == "iOS-27-1")
        #expect(r.name == "iOS 27.1")
        for s in ["iOS-27-1", "iOS 27.1", "27.1", "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "/d/runtimes/iOS-27.1/RuntimeRoot"] { #expect(r.matches(s)) }
        #expect(!r.matches("iOS-27-0"))
    }

    /// The same UDID ycode-simd derives from a device's path (DeviceMode.swift).
    @Test func udidIsStableAndShaped() {
        let a = SimDevice.udid(path: "/data/ycode/devices/ycode-device")
        #expect(a == SimDevice.udid(path: "/data/ycode/devices/ycode-device"))
        #expect(a != SimDevice.udid(path: "/data/ycode/devices/other"))
        #expect(a.count == 36 && a.split(separator: "-").map(\.count) == [8, 4, 4, 4, 12])
        #expect(a == a.uppercased())
    }

    func devices() -> [SimDevice] {
        let rt = SimRuntime(platform: "iOS", version: "27.1", root: "/r")
        func d(_ n: String, _ s: SimDeviceState) -> SimDevice {
            SimDevice(name: n, udid: SimDevice.udid(path: "/d/" + n), directory: "dir-" + n, path: "/d/" + n, type: .iPhoneDuo, runtime: rt,
                      state: s, isCreated: true, host: "h", isLocal: false)
        }
        return [d("A", .shutdown), d("B", .booted)]
    }

    @Test func findsBootedUDIDNameAndDirectory() {
        let list = devices()
        #expect(SimHostContext.find("booted", in: list) == .found(list[1]))
        #expect(SimHostContext.find(list[0].udid.lowercased(), in: list) == .found(list[0]))
        #expect(SimHostContext.find("A", in: list) == .found(list[0]))
        #expect(SimHostContext.find("dir-B", in: list) == .found(list[1]))
        #expect(SimHostContext.find("C", in: list) == .invalid("Invalid device: C"))
        #expect(SimHostContext.find("booted", in: [list[0]]) == .invalid("No devices are booted."))
    }

    @Test func statesParse() {
        #expect(SimHostContext.parseStates("a Booted\nb Shutdown\nc Booting\njunk\n") == ["a": .booted, "b": .shutdown, "c": .booting])
    }

    @Test func displays() throws {
        #expect(try Simctl.displayName(nil) == "active")
        #expect(try Simctl.displayName("internal") == "active")
        #expect(try Simctl.displayName("LCD-1") == "LCD-1")
        #expect(throws: YcrunError.self) { try Simctl.displayName("external") }
    }

    @Test func launchedPIDFromTheRunLog() {
        #expect(Simctl.launchedPID(inLog: "booting\nycode-simd: app install: com.x.A installed\napp launch: launched com.x.A pid 412\n").pid == 412)
        #expect(Simctl.launchedPID(inLog: "app launch: failed (exit 1)\n").failure != nil)
        #expect(Simctl.launchedPID(inLog: "still booting\n").pid == nil)
    }
}

/// `ycrun simctl` verbs against a fake host (no ssh, no simulator).
@Suite struct SimctlVerbTests {
    @Test func listShowsWhereDevicesLiveAndJSON() throws {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Booted\n")
        let env = h.env(Harness.mac)
        #expect(Ycrun.main(["simctl", "list", "devices"], env: env) == 0)
        #expect(h.out.contains { $0.hasPrefix("-- iOS 27.1 (on sim-host, me@sim-host) --") })
        #expect(h.out.contains { $0.contains("iPhone Duo (Ycode) (") && $0.hasSuffix("(Booted)") })
        h.out = []
        #expect(Ycrun.main(["simctl", "list", "-j", "devices"], env: env) == 0)
        let o = try JSONSerialization.jsonObject(with: Data(h.out.joined().utf8)) as! [String: Any]
        let devs = (o["devices"] as! [String: Any])["iOS-27-1"] as! [[String: Any]]
        #expect(devs.first?["state"] as? String == "Booted")
        #expect(devs.first?["placement"] as? String == "remote")
        #expect(devs.first?["host"] as? String == "sim-host")
        #expect(devs.first?["udid"] as? String == SimDevice.udid(path: "/data/ycode/devices/ycode-device"))
        // Every command went to the host with a key only.
        #expect(h.runner.calls.allSatisfy { $0.first == "/usr/bin/ssh" && $0.contains("BatchMode=yes") && $0.contains("me@sim-host") })
    }

    @Test func listDeviceTypesJSON() throws {
        let h = Harness()
        h.configureRemote()
        #expect(Ycrun.main(["simctl", "list", "--json", "devicetypes"], env: h.env()) == 0)
        let o = try JSONSerialization.jsonObject(with: Data(h.out.joined().utf8)) as! [String: Any]
        let t = o["devicetypes"] as! [[String: Any]]
        #expect(t.contains { $0["identifier"] as? String == "iphone-duo" && $0["productFamily"] as? String == "iPhone" })
        #expect(t.contains { $0["identifier"] as? String == "vision-pro" })
    }

    @Test func noHostSaysHowToSetOneUp() {
        let h = Harness()
        #expect(Ycrun.main(["simctl", "list"], env: h.env()) == 1)
        #expect(h.err.joined().contains("ycrun remote setup"))
        #expect(Ycrun.main(["simctl", "list", "devicetypes"], env: h.env()) == 0)
    }

    @Test func createSavesDeviceHubsCreatedDeviceAndPrintsUDID() {
        let h = Harness()
        h.configureRemote()
        #expect(Ycrun.main(["simctl", "create", "My Pad", "iPad (A16)"], env: h.env()) == 0)
        let created = RemoteSimulatorSettings.createdDevices(h.defaults)
        #expect(created.count == 1)
        #expect(created[0].name == "My Pad" && created[0].typeID == "ipad-a16")
        #expect(h.out == [SimDevice.udid(path: "/data/ycode/devices/" + created[0].directoryName)])
        // A watch has no watchOS runtime here.
        #expect(Ycrun.main(["simctl", "create", "W", "apple-watch-series-12-46mm"], env: h.env()) == 1)
        #expect(Ycrun.main(["simctl", "create", "X", "toaster"], env: h.env()) == 1)
    }

    @Test func bootStartsTheLauncherDetachedWithItsDisplay() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Shutdown\n")
        #expect(Ycrun.main(["simctl", "boot", "iPhone Duo (Ycode)"], env: h.env()) == 0)
        let start = h.runner.commands.first { $0.contains("nohup setsid") }!
        #expect(start.contains("/data/ycode/ycrun/ycode-device.pid"))
        #expect(start.contains("--display-server"))
        #expect(start.contains("ycode-sim"))
    }

    @Test func bootOfABootedDeviceFails() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Booted\n")
        #expect(Ycrun.main(["simctl", "boot", "booted"], env: h.env()) == 1)
        #expect(h.err.joined().contains("current state: Booted"))
    }

    @Test func shutdownSignalsTheLauncherItStarted() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Booted\n")
        #expect(Ycrun.main(["simctl", "shutdown", "booted"], env: h.env()) == 0)
        #expect(h.runner.commands.contains { $0.contains("kill -TERM") })
        let h2 = Harness()
        h2.configureRemote()
        h2.runner.on("st() {", 0, "ycode-device Booted\n")
        h2.runner.on("kill -TERM", 3)
        #expect(Ycrun.main(["simctl", "shutdown", "booted"], env: h2.env()) == 1)
        #expect(h2.err.joined().contains("not booted by ycrun"))
    }

    @Test func screenshotWritesThePNG() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Booted\n")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        h.runner.on("--control 'screenshot'", data: png)
        #expect(Ycrun.main(["simctl", "io", "booted", "screenshot", "/tmp/shot.png"], env: h.env()) == 0)
        #expect(h.files["/tmp/shot.png"] == png)
        #expect(Ycrun.main(["simctl", "io", "booted", "screenshot", "--type=jpeg", "x.jpg"], env: h.env()) == YcrunExit.unsupported)
    }

    @Test func uiAndLocationGoToTheLauncher() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Booted\n")
        h.runner.on("--ui 'appearance'", 0, "ok dark\n")
        #expect(Ycrun.main(["simctl", "ui", "booted", "appearance"], env: h.env()) == 0)
        #expect(h.out.last == "dark")
        #expect(Ycrun.main(["simctl", "location", "booted", "set", "41.15,-81.36"], env: h.env()) == 0)
        #expect(h.runner.commands.contains { $0.contains("--location 'set' '41.15,-81.36'") })
    }

    @Test func unsupportedVerbsSaySoWithExit69() {
        let h = Harness()
        h.configureRemote()
        for verb in ["terminate", "openurl", "push", "status_bar"] {
            h.err = []
            #expect(Ycrun.main(["simctl", verb, "booted", "x"], env: h.env()) == YcrunExit.unsupported)
            #expect(h.err.joined().contains("not supported by Ycode's simulator yet"))
        }
        #expect(Ycrun.main(["simctl", "frobnicate"], env: h.env()) == YcrunExit.usage)
    }

    @Test func launchNeedsAnInstalledApp() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Shutdown\n")
        h.runner.on("cat '/data/ycode/ycrun/ycode-device.apps'", 0, "")
        #expect(Ycrun.main(["simctl", "launch", "ycode-device", "com.x.A"], env: h.env()) == 1)
        #expect(h.err.joined().contains("install it first"))
    }

    @Test func launchBootsWithTheAppAndPrintsThePID() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Shutdown\n")
        h.runner.on("cat '/data/ycode/ycrun/ycode-device.apps'", 0, "com.x.A\t/data/ycode/apps/A.app\n")
        h.runner.on("cat '/data/ycode/ycrun/ycode-device.log'", 0, "app launch: launched com.x.A pid 77\n")
        #expect(Ycrun.main(["simctl", "launch", "ycode-device", "com.x.A", "-flag"], env: h.env()) == 0)
        #expect(h.out.last == "com.x.A: 77")
        let start = h.runner.commands.first { $0.contains("nohup setsid") }!
        #expect(start.contains("--install-app") && start.contains("/data/ycode/apps/A.app") && start.contains("--app-arg"))
    }

    @Test func launchPassesSIMCTLChildEnvironment() {
        let h = Harness()
        h.configureRemote()
        h.runner.on("st() {", 0, "ycode-device Shutdown\n")
        h.runner.on("cat '/data/ycode/ycrun/ycode-device.apps'", 0, "com.x.A\t/data/ycode/apps/A.app\n")
        h.runner.on("cat '/data/ycode/ycrun/ycode-device.log'", 0, "launched com.x.A pid 9\n")
        var env = h.env()
        env.environment["SIMCTL_CHILD_FOO"] = "bar"
        #expect(Ycrun.main(["simctl", "launch", "--arch=arm64", "booted-not", "x"], env: env) == 1)
        #expect(Ycrun.main(["simctl", "launch", "ycode-device", "com.x.A"], env: env) == 0)
        #expect(h.runner.commands.contains { $0.contains("--app-env") && $0.contains("FOO=bar") })
    }

    @Test func listJSONToAFileAndBootOptions() {
        let h = Harness()
        h.configureRemote()
        #expect(Ycrun.main(["simctl", "list", "--json-output=/tmp/l.json", "-e", "devicetypes"], env: h.env()) == 0)
        #expect(h.files["/tmp/l.json"].map { String(decoding: $0, as: UTF8.self).contains("iphone-duo") } == true)
        #expect(Ycrun.main(["simctl", "boot", "ycode-device", "--disabledJob=com.x"], env: h.env()) == YcrunExit.unsupported)
        #expect(Ycrun.main(["simctl", "boot", "ycode-device", "--arch=x86_64"], env: h.env()) == YcrunExit.unsupported)
    }

    @Test func createPicksTheNewestCompatibleRuntime() {
        let h = Harness()
        h.configureRemote()
        var s = RemoteSimulatorSettings.load(h.defaults)
        s.otherRuntimeRoots = ["/data/ycode/runtimes/iOS-27.2-24B1/RuntimeRoot"]
        s.save(h.defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.2", root: s.otherRuntimeRoots[0], h.defaults, primary: false)
        #expect(Ycrun.main(["simctl", "create", "P", "iphone-duo"], env: h.env()) == 0)
        #expect(RemoteSimulatorSettings.createdDevices(h.defaults).first?.runtimeRoot == "/data/ycode/runtimes/iOS-27.2-24B1/RuntimeRoot")
    }

    @Test func helpForEveryVerb() {
        let h = Harness()
        for v in ["list", "create", "boot", "launch", "io", "terminate"] {
            #expect(Ycrun.main(["simctl", "help", v], env: h.env()) == 0)
        }
        #expect(h.out.contains { $0.contains("not supported by Ycode's simulator yet") })
    }

    @Test func localPlacementRunsWithoutSSH() {
        let h = Harness()
        h.runner.on("st() {", 0, "")
        #expect(Ycrun.main(["simctl", "--local", "list", "devices"], env: h.env(Harness.linuxARM)) == 0)
        #expect(h.runner.calls.allSatisfy { $0.first == "/bin/sh" })
    }
}

/// `ycrun remote setup` and friends, with fake ssh.
@Suite struct RemoteSetupTests {
    static let reportOK = """
        YCODE-SETUP mode=report version=1
        YCODE-FACT os=Linux
        YCODE-FACT arch=aarch64
        YCODE-FACT kvm=access
        YCODE-FACT data_free_kb=104857600
        YCODE-FACT sim_tree=/home/me/tree/ycode
        YCODE-FACT runtime_root=/data/ycode/runtimes/iOS-27.1-24A1/RuntimeRoot
        YCODE-CHECK setup.kvm ok /dev/kvm is open to me.
        YCODE-DONE pass
        """

    static let systemVersion = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>ProductName</key><string>iPhone OS</string>\
        <key>ProductVersion</key><string>27.1</string><key>ProductBuildVersion</key><string>24A1</string></dict></plist>
        """

    @Test func keyLoginFailurePrintsSSHCopyIDAndNeverAPassword() {
        let h = Harness()
        h.runner.on("printf ycrun-ok", 255, "", err: "me@sim-host: Permission denied (publickey,password).")
        #expect(Ycrun.main(["remote", "setup", "--host", "me@sim-host", "--data", "/data/ycode"], env: h.env()) == 1)
        let e = h.err.joined(separator: "\n")
        #expect(e.contains("ssh-copy-id -i ~/.ssh/id_ed25519.pub me@sim-host"))
        #expect(e.contains("never uses a password"))
        #expect(h.runner.calls.allSatisfy { $0.contains("BatchMode=yes") })
        #expect(h.runner.calls.count == 1)
    }

    @Test func fullSetupWritesTheIDESettingsAndAFirstDevice() {
        let h = Harness()
        h.runner.on("printf ycrun-ok", 0, "ycrun-ok")
        h.runner.on("bash -s", 0, Self.reportOK)
        h.runner.on("SystemVersion.plist'", 0, Self.systemVersion)
        let status = Ycrun.main(["remote", "setup", "--host", "me@sim-host", "--data", "/data/ycode", "--sim-tree", "/home/me/tree/ycode",
                                 "--tcp-port", "47920", "--udp-port", "47921", "--yes"], env: h.env())
        #expect(status == 0, "\(h.err)")
        let s = RemoteSimulatorSettings.load(h.defaults)
        #expect(s.destination == "me@sim-host")
        #expect(s.dataDirectory == "/data/ycode")
        #expect(s.simdPath == "/data/ycode/bin/ycode-sim")
        #expect(s.runtimeRoot == "/data/ycode/runtimes/iOS-27.1-24A1/RuntimeRoot")
        #expect(s.runtimeVersion == "27.1")
        let c = RuntimeSetupChoices.load(h.defaults)
        #expect(c.host.destination == "me@sim-host" && c.host.tcpPort == 47920 && c.useHost)
        #expect(RemoteSimulatorSettings.createdDevices(h.defaults).map(\.name) == ["iPhone Duo"])
        // What both IDEs' Settings ▸ Components ▸ Simulator Host page shows.
        #expect(SimulatorHostPage.value(.host, h.defaults) == "me@sim-host")
        #expect(SimulatorHostPage.value(.dataFolder, h.defaults) == "/data/ycode")
        #expect(SimulatorHostPage.value(.simdPath, h.defaults) == "/data/ycode/bin/ycode-sim")
        #expect(SimulatorHostPage.value(.ports, h.defaults) == "47920/47921")
        // Device Hub's simulators include the first device.
        #expect(RemoteSimulator.hub(RemoteSimulatorSettings.load(h.defaults)).contains { $0.target?.customName == "iPhone Duo" })
        // The script went over ssh on standard input, with the tree and the ports.
        let script = h.runner.calls.first { $0.last?.hasPrefix("bash -s") == true }!
        #expect(script.last!.contains("'--sim-tree' '/home/me/tree/ycode'") && script.last!.contains("'47920'"))
        #expect(h.runner.inputs.contains { $0.map { String(decoding: $0, as: UTF8.self).contains("ycode-host-setup") } ?? false })
        // The launcher's configuration.
        #expect(h.runner.commands.contains { $0.contains("ycode-sim.conf") && $0.contains("YCODE_SIM_TREE=") })
        #expect(!h.runner.commands.contains { $0.contains("sudo") && !$0.contains("echo") })
        #expect(Ycrun.main(["remote", "list"], env: h.env()) == 0)
        #expect(h.out.contains { $0.hasPrefix("sim-host\tme@sim-host\t/data/ycode\tyes") })
    }

    @Test func kvmDeniedPrintsTheGroupFixAndRootStepsButRunsNoSudo() {
        let h = Harness()
        h.runner.on("printf ycrun-ok", 0, "ycrun-ok")
        h.runner.on("bash -s", 0, Self.reportOK.replacingOccurrences(of: "kvm=access", with: "kvm=denied")
            .replacingOccurrences(of: "YCODE-CHECK setup.kvm ok /dev/kvm is open to me.",
                                  with: "YCODE-ROOT kvm-group usermod -aG kvm me\nYCODE-CHECK setup.kvm missing /dev/kvm belongs to the kvm group; me is not in it."))
        h.runner.on("SystemVersion.plist'", 0, Self.systemVersion)
        #expect(Ycrun.main(["remote", "setup", "--host", "me@sim-host", "--data", "/data/ycode", "--sim-tree", "/t", "--yes"], env: h.env()) == 1)
        let e = h.err.joined(separator: "\n")
        #expect(e.contains("usermod -aG kvm"))
        #expect(e.contains("ycrun never runs sudo"))
        // Settings are still saved, so the host is ready once KVM is fixed.
        #expect(RemoteSimulatorSettings.load(h.defaults).destination == "me@sim-host")
        #expect(h.runner.calls.allSatisfy { !$0.contains("sudo") })
    }

    @Test func notArm64IsRefused() {
        let h = Harness()
        h.runner.on("printf ycrun-ok", 0, "ycrun-ok")
        h.runner.on("bash -s", 0, Self.reportOK.replacingOccurrences(of: "arch=aarch64", with: "arch=x86_64"))
        #expect(Ycrun.main(["remote", "setup", "--host", "me@pc", "--data", "/d", "--yes"], env: h.env()) == 1)
        #expect(h.err.joined().contains("must be arm64 Linux"))
        #expect(RemoteSimulatorSettings.load(h.defaults).destination.isEmpty)
    }

    @Test func wizardAsksForWhatIsMissing() {
        let h = Harness()
        h.answers = ["me@sim-host", "~/ycode-data"]
        h.runner.on("printf ycrun-ok", 0, "ycrun-ok")
        h.runner.on("printf %s \"$HOME\"", 0, "/home/me")
        h.runner.on("bash -s", 0, Self.reportOK)
        h.runner.on("SystemVersion.plist'", 0, Self.systemVersion)
        #expect(Ycrun.main(["remote", "setup", "--sim-tree", "/t"], env: h.env(interactive: true)) == 0, "\(h.err)")
        #expect(RemoteSimulatorSettings.load(h.defaults).dataDirectory == "/home/me/ycode-data")
    }

    @Test func twoDataFoldersOnOneMachineAreTwoHosts() {
        let h = Harness()
        h.configureRemote(destination: "me@sim-host", data: "/data/ycode")
        h.runner.on("printf ycrun-ok", 0, "ycrun-ok")
        h.runner.on("bash -s", 0, Self.reportOK)
        h.runner.on("SystemVersion.plist'", 0, Self.systemVersion)
        #expect(Ycrun.main(["remote", "setup", "--host", "me@sim-host", "--name", "second", "--data", "/data/other", "--sim-tree", "/t",
                            "--no-device", "--yes"], env: h.env()) == 0, "\(h.err)")
        // The IDEs keep their host; the second is ycrun's own.
        #expect(RemoteSimulatorSettings.load(h.defaults).dataDirectory == "/data/ycode")
        #expect(h.store.remoteHosts().map(\.dataDirectory) == ["/data/ycode", "/data/other"])
        #expect(h.store.remoteHost(named: "second")?.dataDirectory == "/data/other")
        #expect(Ycrun.main(["remote", "remove", "second"], env: h.env()) == 0)
        #expect(RemoteSimulatorSettings.load(h.defaults).destination == "me@sim-host")
    }

    @Test func settingUpAgainKeepsTheDevices() throws {
        let h = Harness()
        var e = SimHostEntry(name: "local", destination: "", dataDirectory: "/d", runtimeRoot: "/d/r")
        e.createdDevices = [RemoteCreatedDevice(name: "A", typeID: "iphone-duo", runtimeRoot: "/d/r", directoryName: "a")]
        try h.store.save(e)
        try h.store.save(SimHostEntry(name: "local", destination: "", dataDirectory: "/d", runtimeRoot: "/d/r"))
        #expect(h.store.localHost().createdDevices.map(\.name) == ["A"])
    }

    @Test func removeClearsTheIDEHost() {
        let h = Harness()
        h.configureRemote()
        #expect(Ycrun.main(["remote", "remove", "sim-host"], env: h.env()) == 0)
        #expect(RemoteSimulatorSettings.load(h.defaults).destination.isEmpty)
        #expect(Ycrun.main(["remote", "remove", "sim-host"], env: h.env()) == 1)
    }

    @Test func optionsParse() throws {
        let o = try RemoteSetupOptions.parse(["--host", "a@b", "--data", "/d", "--no-device", "--no-default", "--min-free-gb", "20"])
        #expect(o.destination == "a@b" && o.noDevice && o.makeDefault == false && o.minFreeGB == 20)
        #expect(throws: YcrunError.self) { try RemoteSetupOptions.parse(["--local", "--host", "a@b"]) }
        #expect(throws: YcrunError.self) { try RemoteSetupOptions.parse(["--sim-tree", "/t", "--ycode-version", "1"]) }
        #expect(throws: YcrunError.self) { try RemoteSetupOptions.parse(["--bogus"]) }
    }

    @Test func installLinkPlans() {
        #expect(Ycrun.linkPlan(directory: nil, executable: "/A/Ycode.app/Contents/Helpers/ycrun", environment: ["HOME": "/h"], isWritable: { _ in false })
                == .symlink(at: "/h/.local/bin/ycrun", to: "/A/Ycode.app/Contents/Helpers/ycrun"))
        #expect(Ycrun.linkPlan(directory: nil, executable: "/x/ycrun", environment: ["HOME": "/h"], isWritable: { _ in true })
                == .symlink(at: "/usr/local/bin/ycrun", to: "/x/ycrun"))
        guard case .script(let at, let text) = Ycrun.linkPlan(directory: nil, executable: "/app/bin/ycrun",
                                                              environment: ["HOME": "/h", "FLATPAK_ID": "io.github.MarcoDotIO.Ycode"]) else {
            Issue.record("expected a script in a Flatpak")
            return
        }
        #expect(at == "/h/.local/bin/ycrun" && text.contains("flatpak run --command=ycrun io.github.MarcoDotIO.Ycode"))
    }
}

/// The real runner (posix_spawn, waitpid): output, errors, input, and a
/// shell that leaves a detached job behind returns at once (it hung under
/// Foundation's Process on Linux).
@Suite struct RunnerTests {
    @Test func outputErrorsAndInput() {
        let r = ProcessCommandRunner()
        let a = r.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], input: nil, timeout: 30)
        #expect(a.status == 3 && a.text == "out\n" && a.errorText == "err\n")
        let b = r.run(["/bin/sh", "-c", "cat"], input: Data("piped".utf8), timeout: 30)
        #expect(b.ok && b.text == "piped")
        #expect(r.run(["/nonexistent/program"], input: nil, timeout: 5).status == 127)
    }

    @Test func aDetachedJobDoesNotHoldTheCaller() {
        let started = Date()
        let r = ProcessCommandRunner().run(["/bin/sh", "-c", "nohup sh -c 'sleep 5' > /dev/null 2>&1 < /dev/null & echo $!"], input: nil, timeout: 30)
        #expect(r.ok)
        #expect(Date().timeIntervalSince(started) < 4)
        if let pid = Int32(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
    }

    @Test func timeoutEndsTheChild() {
        let started = Date()
        let r = ProcessCommandRunner().run(["/bin/sh", "-c", "exec sleep 30"], input: nil, timeout: 1)
        #expect(r.status == 128 + SIGTERM)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

/// A fresh host's simulator tree: every part checked, the missing ones
/// built, the guest tools copied (specs/ide/ycrun.md §8.3).
@Suite struct TreePartsTests {
    @Test func parseAndBuildOnlyWhatIsMissing() {
        let r = SimTreeParts.parse("PART simd ok\nPART shim missing\nPART hostlibs missing\nPART frameworks ok\nPART translator ok\nPART guesttools missing /t/g\nTREE source\n")
        #expect(r.missing == ["shim", "hostlibs", "guesttools"])
        #expect(r.isSource && r.guestToolsFolder == "/t/g")
        let b = SimTreeParts.buildCommand(tree: "/t", missing: r.missing, jobs: 6)
        #expect(b.contains("SimShim/build.sh") && b.contains("SimHostLibs/build.sh") && !b.contains("Translator/build.sh") && b.contains("J=6"))
        let c = SimTreeParts.checkCommand(tree: "/t", guestTools: nil)
        #expect(c.contains("SimHostLibs/out/libsystem_platform.dylib") && c.contains("SimShim/out/guest-tests/stage7"))
    }

    @Test func guestToolsComeFromTheOptionTheEnvironmentOrTheApp() {
        #expect(SimTreeParts.localGuestTools(option: "/g", environment: [:], executable: "/x/ycrun") == "/g")
        #expect(SimTreeParts.localGuestTools(option: nil, environment: ["YCODE_GUEST_TOOLS": "/e"], executable: "/x/ycrun") == "/e")
        let app = "/A/Ycode.app/Contents/Helpers/ycrun"
        #expect(SimTreeParts.localGuestTools(option: nil, environment: [:], executable: app, exists: { $0 == "/A/Ycode.app/Contents/Resources/simulator-host/guest-tools.tar" })
                == "/A/Ycode.app/Contents/Resources/simulator-host/guest-tools.tar")
        #expect(SimTreeParts.localGuestTools(option: nil, environment: [:], executable: "/app/bin/ycrun", exists: { $0 == "/app/share/ycode/guest-tools.tar" })
                == "/app/share/ycode/guest-tools.tar")
        #expect(SimTreeParts.localGuestTools(option: nil, environment: [:], executable: "/x/ycrun", exists: { _ in false }) == nil)
    }

    @Test func setupBuildsTheMissingPartsAndSaysHowToGetGuestTools() {
        let h = Harness()
        h.runner.on("printf ycrun-ok", 0, "ycrun-ok")
        h.runner.on("bash -s", 0, RemoteSetupTests.reportOK)
        h.runner.on("SystemVersion.plist'", 0, RemoteSetupTests.systemVersion)
        h.runner.on("PART", 0, "PART simd ok\nPART shim missing\nPART hostlibs missing\nPART frameworks ok\nPART translator ok\nPART guesttools missing /t/g\nTREE source\n")
        h.runner.on("guest-tools/ylaunch' ]", 1)
        #expect(Ycrun.main(["remote", "setup", "--host", "me@sim-host", "--data", "/data/ycode", "--sim-tree", "/home/me/tree/ycode", "--yes"], env: h.env()) == 1)
        let build = h.runner.commands.first { $0.contains("SimHostLibs/build.sh") }
        #expect(build != nil && build!.contains("SimShim/build.sh"))
        #expect(h.err.joined(separator: "\n").contains("build-guest-tools.sh"))
        #expect(h.runner.commands.contains { $0.contains("ycode-sim.conf") && $0.contains("YCODE_SIM_TREE=") })
    }

    @Test func ensureKeysKeepsExistingValues() {
        let c = SimTreeParts.ensureKeysCommand(file: "/d/bin/ycode-sim.conf", [("YCODE_SIM_GUEST_TOOLS", "/d/guest-tools")])
        #expect(c.contains("grep -q '^YCODE_SIM_GUEST_TOOLS='") && c.contains(">> '/d/bin/ycode-sim.conf'"))
    }
}
