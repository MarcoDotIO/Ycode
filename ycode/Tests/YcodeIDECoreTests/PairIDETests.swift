import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Round W6 (PAIR-IDE, `specs/simulator/device-pairing.md` §13): the host's
/// pairs as `ycode-sim list-pairs --json` lists them, the pairing commands,
/// devices created in Device Hub, watch and phone-with-watch run
/// destinations (§11.4), the companion iOS app of a watch app, and the
/// commands that install a watch app through the pairing agent. No network;
/// preferences in a scratch domain.
@MainActor
@Suite(.serialized) struct PairIDETests {
    static let iosRoot = "/rt/iOS-27.0-24A434/RuntimeRoot"
    static let watchRoot = "/rt/watchOS-27.0-24R362/RuntimeRoot"

    func settings() -> RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode",
                                        runtimeRoot: Self.iosRoot, simdPath: "/data/ycode/bin/ycode-sim", deviceName: "dev")
        s.otherRuntimeRoots = [Self.watchRoot]
        s.runtimeVersion = "27.0"
        s.runtimeVersions = [Self.iosRoot: "27.0", Self.watchRoot: "27.0"]
        s.runtimePlatforms = [Self.iosRoot: "iOS", Self.watchRoot: "watchOS"]
        return s
    }

    static let listing = """
    ycode-sim: a status line first
    {
      "pairs" : {
        "a14c1055-1f81-4d7b-a25c-710d1d9a7dc1" : {
          "phone" : { "name" : "iPhone 18 Pro [dev-phone]", "state" : "Booted", "udid" : "3381bcad-0000-0000-0000-000000000001" },
          "state" : "(active, connected)",
          "watch" : { "name" : "Apple Watch Series 12 (46mm) [dev-watch]", "state" : "Booted", "udid" : "71ef2e8d-0000-0000-0000-000000000002" }
        },
        "B0000000-0000-0000-0000-000000000003" : {
          "phone" : { "name" : "iPhone 18 Pro [dev-phone]", "state" : "Booted", "udid" : "3381BCAD-0000-0000-0000-000000000001" },
          "state" : "(inactive, disconnected)",
          "watch" : { "name" : "Apple Watch Ultra 4 (49mm) [dev-ultra]", "state" : "Shutdown", "udid" : "U" }
        },
        "C0000000-0000-0000-0000-000000000004" : {
          "phone" : { "name" : "? [missing]", "state" : "Shutdown", "udid" : "X" },
          "state" : "(active, disconnected)",
          "watch" : { "name" : "Apple Watch SE 3 (44mm) [dev-se]", "state" : "Shutdown", "udid" : "Y" }
        }
      }
    }
    """

    // MARK: Listing

    @Test func listPairsJSONIsParsed() throws {
        let pairs = try #require(RemotePairListing.parse(Data(Self.listing.utf8)))
        // The pair whose phone directory is missing is left out.
        #expect(pairs.count == 2)
        let a = try #require(pairs.first { $0.active })
        #expect(a.id == "A14C1055-1F81-4D7B-A25C-710D1D9A7DC1")
        #expect(a.phoneDirectory == "dev-phone" && a.watchDirectory == "dev-watch")
        #expect(a.phoneTypeName == "iPhone 18 Pro" && a.watchTypeName == "Apple Watch Series 12 (46mm)")
        #expect(a.connected && a.watchBooted && a.phoneBooted)
        #expect(a.phoneUDID == "3381BCAD-0000-0000-0000-000000000001")
        #expect(a.stateText == "(active, connected)")
        let b = try #require(pairs.first { !$0.active })
        #expect(!b.connected && !b.watchBooted && b.stateText == "(inactive, disconnected)")
        #expect(RemotePairListing.parse(Data("no pairs".utf8)) == nil)
        #expect(RemotePairListing.parse(Data(#"{"pairs": {}}"#.utf8)) == [])
        #expect(RemotePairListing.split(name: "Apple Watch Ultra 4 (49mm) [d]") == ("Apple Watch Ultra 4 (49mm)", "d"))
        #expect(RemotePairListing.split(name: "? [missing]").directory == nil)
        #expect(RemotePairListing.split(name: "plain").directory == nil)
        // The pairing helpers.
        let p = RemotePairing(pairs)
        #expect(p.activePair(phone: "dev-phone")?.watchDirectory == "dev-watch")
        #expect(p.pairs(ofDirectory: "dev-phone").map(\.watchDirectory) == ["dev-watch", "dev-ultra"])
        #expect(p.isPaired(watch: "dev-ultra") && !p.isPaired(watch: "dev-other"))
    }

    @Test func pairOutputGivesThePairID() {
        #expect(RemoteSimulator.pairID(fromPairOutput: "ycode-simd: note\na14c1055-1f81-4d7b-a25c-710d1d9a7dc1\n") == "A14C1055-1F81-4D7B-A25C-710D1D9A7DC1")
        #expect(RemoteSimulator.pairID(fromPairOutput: "ycode-simd: refused") == nil)
    }

    // MARK: Commands

    @Test func pairingCommandsNameTheDeviceSet() throws {
        let s = settings()
        let phone = RemoteSimulator(settings: s, target: s.targets[0])
        let watch = RemoteSimulator(settings: s, target: s.watchTargets[0])
        #expect(phone.deviceSetPath == "/data/ycode/devices")
        #expect(phone.listPairsCommand == "exec env YCODE_SIM_DEVICE_SET='/data/ycode/devices' '/data/ycode/bin/ycode-sim' 'list-pairs' '--json'")
        #expect(phone.unpairCommand("P1") == "exec env YCODE_SIM_DEVICE_SET='/data/ycode/devices' '/data/ycode/bin/ycode-sim' 'unpair' 'P1'")
        #expect(phone.activateCommand("P1").hasSuffix("'pair-activate' 'P1'"))
        let pair = phone.pairCommand(watch: watch)
        // The type records of devices that never booted come first, then the pair (watch first).
        #expect(pair.contains("printf '%s\\n' 'apple-watch-series-12-46mm' > '/data/ycode/devices/dev-apple-watch-series-12-46mm-27.0'/ycode-device-type"))
        #expect(phone.remoteDevicePath == "/data/ycode/devices/dev-iphone-18-pro-27.0")
        #expect(pair.contains("printf '%s\\n' 'iphone-18-pro' > '/data/ycode/devices/dev-iphone-18-pro-27.0'/ycode-device-type"))
        #expect(pair.hasSuffix("'pair' '/data/ycode/devices/dev-apple-watch-series-12-46mm-27.0' '/data/ycode/devices/dev-iphone-18-pro-27.0'"))
        #expect(pair.contains("[ -e '/data/ycode/devices/dev-iphone-18-pro-27.0'/data/var/run/launchd_bootstrap.plist ]"), "a booted device keeps its record")
    }

    @Test func typeRecordCommandWritesOnlyWhenMissing() throws {
        let dir = ycodeDir.appendingPathComponent(".build-ide/pair-ide-type-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dev = dir.appendingPathComponent("devices/new one").path
        func run(_ c: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", c]
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        #expect(run(RemoteSimulator.typeRecordCommand(devicePath: dev, typeID: "iphone-18-pro")) == 0)
        #expect((try? String(contentsOfFile: dev + "/ycode-device-type", encoding: .utf8)) == "iphone-18-pro\n")
        try "ipad-a16\n".write(toFile: dev + "/ycode-device-type", atomically: true, encoding: .utf8)
        #expect(run(RemoteSimulator.typeRecordCommand(devicePath: dev, typeID: "iphone-18-pro")) == 0)
        #expect((try? String(contentsOfFile: dev + "/ycode-device-type", encoding: .utf8)) == "ipad-a16\n", "an existing record is kept")
    }

    @Test func watchAppCommandsGoThroughThePairingAgent() {
        let s = settings()
        let watch = RemoteSimulator(settings: s, target: s.watchTargets[0])
        let dev = "/data/ycode/devices/dev-apple-watch-series-12-46mm-27.0"
        #expect(watch.isWatch && !RemoteSimulator(settings: s, target: s.targets[0]).isWatch)
        #expect(watch.stagedAppsDirectory == dev + "/data/tmp/ycode-apps")
        let app = URL(fileURLWithPath: "/build/WCProbe.app/Watch/WCProbeWatch.app")
        let args = watch.stageArguments(app)
        #expect(args.last == "tester@sim-host:\(dev)/data/tmp/ycode-apps/WCProbeWatch.app/")
        #expect(args.contains("/build/WCProbe.app/Watch/WCProbeWatch.app/"))
        let install = watch.installAppCommand(app)
        #expect(install == "g=$(cat '\(dev)/ycode-device-path' 2>/dev/null); [ -n \"$g\" ] || g='\(dev)'; "
            + "exec '/data/ycode/bin/ycode-sim' --device '\(dev)' --control pairing agent 'installApp' \"path=$g\"'/data/tmp/ycode-apps/WCProbeWatch.app'")
        #expect(watch.openAppCommand(bundleID: "dev.ycode.wcprobe.watchkitapp")
            == "exec '/data/ycode/bin/ycode-sim' --device '\(dev)' --control pairing agent 'openApp' 'bundleID=dev.ycode.wcprobe.watchkitapp'")
        #expect(watch.pairingStateCommand.hasSuffix("--control 'pairing' 'state'"))
        #expect(RemoteSimulator.agentIsUp(stateReply: "ok 71EF: agent up; no pairs"))
        #expect(!RemoteSimulator.agentIsUp(stateReply: "ok 71EF: agent not up; no pairs"))
        #expect(!RemoteSimulator.agentIsUp(stateReply: "error: no running device"))
    }

    @Test func theGuestPathOfTheStagedAppFollowsTheDeviceRecord() throws {
        // The install command run by a shell: with and without ycode-device-path.
        let root = ycodeDir.appendingPathComponent(".build-ide/pair-ide-gp-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("ycode-sim")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/devices/w"), withIntermediateDirectories: true)
        try "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        var s = settings()
        s.dataDirectory = root.appendingPathComponent("data").path
        s.simdPath = launcher.path
        let t = RemoteSimulatorTarget(runtimeRoot: Self.watchRoot, runtimeVersion: "27.0", deviceType: YcodeSimulatorDeviceType.watches[0],
                                      deviceDirectoryName: "w", isPrimary: false)
        let watch = RemoteSimulator(settings: s, target: t)
        func run(_ c: String) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", c]
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let app = URL(fileURLWithPath: "/x/W.app")
        #expect(run(watch.installAppCommand(app)).hasSuffix("installApp\npath=\(watch.remoteDevicePath)/data/tmp/ycode-apps/W.app\n"))
        try "/guest/dev\n".write(toFile: watch.remoteDevicePath + "/ycode-device-path", atomically: true, encoding: .utf8)
        #expect(run(watch.installAppCommand(app)).hasSuffix("path=/guest/dev/data/tmp/ycode-apps/W.app\n"))
    }

    @Test func longDeviceNamesGetShortDisplaySockets() {
        var s = settings()
        s.dataDirectory = "/media/someone/DATA_VOLUME/work/ide-remote/an-area-name"
        let watch = RemoteSimulator(settings: s, target: s.watchTargets[0])
        #expect(watch.displaySocketPath.utf8.count <= 100)
        #expect(watch.displaySocketPath.hasPrefix(s.dataDirectory + "/display/d-") && watch.displaySocketPath.hasSuffix(".sock"))
        #expect(watch.displaySocketPath == RemoteSimulator(settings: s, target: s.watchTargets[0]).displaySocketPath, "stable")
        #expect(watch.displaySocketPath != RemoteSimulator(settings: s, target: s.watchTargets[1]).displaySocketPath)
        #expect(watch.startCommand.contains("unix:\(watch.displaySocketPath)"))
        // A short one keeps its directory's name.
        s.dataDirectory = "/data"
        #expect(RemoteSimulator(settings: s, target: s.watchTargets[0]).displaySocketPath == "/data/display/dev-apple-watch-series-12-46mm-27.0.sock")
    }

    // MARK: Created devices

    @Test func createdDevicesAreTargetsWithTheirOwnDirectories() throws {
        let t = TestDefaults("pair-ide-created")
        defer { t.remove() }
        var s = settings()
        s.save(t.defaults)
        RemoteSimulatorSettings.saveRuntimePlatform("watchOS", root: Self.watchRoot, t.defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.0", root: Self.watchRoot, t.defaults, primary: false)
        RemoteSimulatorSettings.saveRuntimeVersion("27.0", root: Self.iosRoot, t.defaults)
        let phone = RemoteSimulatorSettings.createDevice(name: "My Phone", type: .iPhone18Pro, runtimeRoot: Self.iosRoot, t.defaults)
        let watch = RemoteSimulatorSettings.createDevice(name: "  ", type: YcodeSimulatorDeviceType.watches[0], runtimeRoot: Self.watchRoot, t.defaults)
        #expect(phone.directoryName.hasPrefix("dev-iphone-18-pro-27.0-") && phone.directoryName.count == "dev-iphone-18-pro-27.0-".count + 8)
        #expect(watch.name == "Apple Watch Series 12 (46mm)", "an empty name is the model's")
        // A device of a type its root does not run is not a target.
        RemoteSimulatorSettings.saveCreatedDevices(RemoteSimulatorSettings.createdDevices(t.defaults)
            + [RemoteCreatedDevice(name: "Wrong", typeID: "apple-watch-ultra-4-49mm", runtimeRoot: Self.iosRoot, directoryName: "x")], t.defaults)
        s = RemoteSimulatorSettings.load(t.defaults)
        #expect(s.createdDevices.count == 3)
        let p = try #require(s.targets.first { $0.deviceDirectoryName == phone.directoryName })
        #expect(p.name == "My Phone" && p.isCreated && !p.isWatch && p.deviceType == .iPhone18Pro)
        #expect(p.identifier == "ycode-remote-simulator:device:\(phone.directoryName)")
        let w = try #require(s.watchTargets.first { $0.deviceDirectoryName == watch.directoryName })
        #expect(w.isWatch && w.runtimeRoot == Self.watchRoot)
        #expect(!s.hubTargets.contains { $0.deviceDirectoryName == "x" })
        #expect(s.target(directory: watch.directoryName) == w)
        // save() does not write them (a Settings pane loaded before a device was created keeps it).
        var stale = s
        stale.createdDevices = []
        stale.save(t.defaults)
        #expect(RemoteSimulatorSettings.load(t.defaults).createdDevices.count == 3)
        RemoteSimulatorSettings.removeCreatedDevice(directory: "x", t.defaults)
        #expect(RemoteSimulatorSettings.load(t.defaults).createdDevices.map(\.directoryName) == [phone.directoryName, watch.directoryName])
        // A row of a created device.
        let row = DeviceRow.ycodeRemote(RemoteSimulator(settings: s, target: p), running: false)
        #expect(row.isCreated && row.deviceDirectory == phone.directoryName && row.name == "My Phone")
        // The new-device choices.
        #expect(s.runtimeRoots(platform: "watchOS").map(\.root) == [Self.watchRoot])
        #expect(s.newDeviceTypes(platform: "watchOS", root: Self.watchRoot).first?.id == "apple-watch-series-12-46mm")
        #expect(s.newDeviceTypes(platform: "iOS", root: Self.iosRoot).map(\.id) == ["iphone-18-pro"])
    }

    // MARK: Destinations (§11.4)

    @Test func watchesAndPhonesWithAnActiveWatchAreDestinations() throws {
        let s = settings()
        let phone = s.targets[0], watch = s.watchTargets[0]
        #expect(phone.deviceType == .iPhone18Pro)
        let pairs = [RemoteDevicePair(id: "P1", watchDirectory: watch.deviceDirectoryName, phoneDirectory: phone.deviceDirectoryName, active: true),
                     RemoteDevicePair(id: "P2", watchDirectory: s.watchTargets[1].deviceDirectoryName, phoneDirectory: phone.deviceDirectoryName, active: false)]
        let rows = RemoteSimulator.destinations(s, pairs: pairs)
        #expect(rows.count == s.targets.count + s.watchTargets.count + 1)
        let w = try #require(rows.first { $0.identifier == watch.identifier })
        #expect(w.platform == "watchOS" && w.specifier == "generic/platform=watchOS Simulator" && w.osVersion == "27.0" && w.isYcodeRemoteSimulator)
        let paired = try #require(rows.last)
        #expect(paired.isYcodePairedDestination && paired.isYcodeRemoteSimulator)
        #expect(paired.identifier == "ycode-remote-simulator:paired:\(phone.deviceDirectoryName)")
        #expect(paired.name == "iPhone 18 Pro (Ycode) with Apple Watch Series 12 (46mm) (Ycode)")
        #expect(paired.platform == "watchOS" && paired.specifier == "generic/platform=watchOS Simulator" && paired.osVersion == "27.0")
        // Its phone and active watch; the phone is the destination's simulator.
        let both = try #require(s.pairedTargets(for: paired, pairs: pairs))
        #expect(both.phone == phone && both.watch == watch)
        #expect(s.target(for: paired) == phone)
        #expect(RemoteSimulator(settings: s, destination: w).isWatch)
        // Without an active pair: no such row, and the run reports §11.4.
        let inactive = pairs.map { var p = $0; p.active = false; return p }
        #expect(!RemoteSimulator.destinations(s, pairs: inactive).contains { $0.isYcodePairedDestination })
        #expect(s.pairedTargets(for: paired, pairs: inactive) == nil)
        #expect(s.pairedTargets(for: paired, pairs: []) == nil)
        #expect(RemoteWatchRunError.noPairedWatch == "The install is directed to a paired Apple Watch, but there isn't one.")
        #expect(RemoteWatchRunError.selectPairedPhone == "Select an iPhone Run Destination with a paired Apple Watch.")
    }

    @Test func theDestinationMenuListsWatchRowsForWatchSchemesOnly() {
        let s = settings()
        let pairs = [RemoteDevicePair(id: "P1", watchDirectory: s.watchTargets[0].deviceDirectoryName, phoneDirectory: s.targets[0].deviceDirectoryName, active: true)]
        let remote = RemoteSimulator.destinations(s, pairs: pairs)
        // A watchOS scheme: the watches and the phone with its watch; the phones are incompatible.
        let watchMenu = DestinationMenuModel(current: nil, devices: [], simulators: remote, platforms: ["watchOS"], deploymentTargets: ["watchOS": "27.0"])
        let sims = watchMenu.rows("Simulators")
        #expect(sims.count == s.watchTargets.count + 1)
        #expect(sims.contains { $0.isYcodePairedDestination })
        #expect(watchMenu.incompatible.contains { $0.name.hasPrefix("iPhone 18 Pro (Ycode)") && $0.name.hasSuffix("(mismatched platform)") })
        // A newer deployment target: every watch row is incompatible (§11.4: older watches are listed so).
        let newer = DestinationMenuModel(current: nil, devices: [], simulators: remote, platforms: ["watchOS"], deploymentTargets: ["watchOS": "28.0"])
        #expect(newer.rows("Simulators").isEmpty)
        #expect(newer.incompatible.contains { $0.isYcodePairedDestination && $0.name.hasSuffix("(OS version lower than deployment target)") })
        // An iOS scheme: no watch rows.
        let iosMenu = DestinationMenuModel(current: nil, devices: [], simulators: remote, platforms: ["iOS"])
        #expect(iosMenu.rows("Simulators").allSatisfy { $0.platform == "iOS" })
        #expect(iosMenu.rows("Simulators").count == s.targets.count)
    }

    // MARK: The companion iOS app

    @Test func theSampleWatchAppHasItsCompanion() throws {
        let url = ycodeDir.appendingPathComponent("Samples/WatchSamples/WatchSamples.xcodeproj")
        let model = try WorkspaceModel(url: url)
        let proj = try #require(model.projects.values.first)
        #expect(WatchCompanion.companionTargets(of: "WCProbeWatch", in: proj) == ["WCProbe"])
        #expect(WatchCompanion.companionTargets(of: "WCProbe", in: proj).isEmpty)
        #expect(WatchCompanion.platforms(ofTarget: "WCProbeWatch", in: proj) == ["watchOS"])
        #expect(WatchCompanion.platforms(ofTarget: "WCProbe", in: proj) == ["iOS"])
        #expect(WatchCompanion.deploymentTarget(ofTarget: "WCProbeWatch", platform: "watchOS", in: proj) == "27.0")
        #expect(model.companionScheme(watchScheme: "WCProbeWatch") == "WCProbe")
        #expect(model.companionScheme(watchScheme: "WCProbe") == nil)
        #expect(model.platforms(scheme: "WCProbeWatch") == ["watchOS"])
        #expect(model.schemeNames.contains("WCProbeWatch") && model.schemeNames.contains("WCProbe"))
    }

    @Test func theEmbeddedWatchAppIsFoundInTheIOSApp() throws {
        let app = ycodeDir.appendingPathComponent(".build-ide/pair-ide-app-\(UUID().uuidString.prefix(8))/Probe.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(RemoteSimulator.embeddedWatchApp(in: app) == nil)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Watch/Z.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Watch/A.app"), withIntermediateDirectories: true)
        #expect(RemoteSimulator.embeddedWatchApp(in: app)?.lastPathComponent == "A.app")
    }

    // MARK: The pairs the IDE keeps

    @Test func thePairsAreKeptAndChangesAreAnnounced() throws {
        let t = TestDefaults("pair-ide-store")
        defer { t.remove() }
        let store = RemotePairsStore(defaults: t.defaults)
        #expect(store.current().isEmpty)
        final class Count: @unchecked Sendable { var n = 0 }
        let posted = Count()
        let token = NotificationCenter.default.addObserver(forName: RemotePairsStore.didChange, object: store, queue: nil) { _ in posted.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let p = [RemoteDevicePair(id: "P", watchDirectory: "w", phoneDirectory: "p", active: true)]
        store.set(p)
        store.set(p)
        #expect(posted.n == 1, "an unchanged listing is not announced")
        #expect(RemotePairsStore(defaults: t.defaults).current() == p, "kept across launches")
    }
}
