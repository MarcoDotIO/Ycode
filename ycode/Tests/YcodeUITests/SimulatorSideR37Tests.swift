import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// R37 (`specs/ide/reference-ui-5.md` §0, §11.5, §11.6): Ycode's remote
/// simulator in the Simulators section with its runtime version (R1),
/// its run status and Stop with the save at the stop (R2, `snapshot.md`
/// §12.2), erasing it (`run.md` §Warm boot item 7), the preview activity
/// text (P15), and Debug View Hierarchy / Memory Graph as disabled
/// placeholders (D4). ssh, rsync and the launcher are local stand-ins: no
/// network.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct SimulatorSideR37Tests {
    // MARK: Fixtures

    /// A private Preferences installed as `shared` for `body`.
    func withPrefs(_ tag: String, _ body: (Preferences, URL) async throws -> Void) async throws {
        let t = TestDefaults("r37-\(tag)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r37-\(tag)-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(p, dir)
    }

    func iosApp(in dir: URL, name: String = "Tour") throws -> URL {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = .none
        o.setStorage(.none)
        return try ProjectTemplate.app.create(platform: "iOS", options: o, in: dir)
    }

    func sim(_ name: String, _ version: String) -> Destination {
        Destination(name: name, specifier: "platform=iOS Simulator,id=\(name)-\(version)", platform: "iOS", kind: .simulator,
                    osVersion: version, identifier: "\(name)-\(version)")
    }

    func window(_ proj: URL, state: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        return WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: proj)), loadDestinations: false,
                                         startLanguageService: false, openFirstFile: false, userStateURL: state)
    }

    /// Stand-ins in a fresh folder: `fake-ssh` (drops the options and the
    /// destination and runs the command with /bin/sh; logs every call;
    /// delays the run command when `delay-run` exists; fails `kill` when
    /// `fail-kill` exists), a slow `rsync` when asked, and the launcher.
    struct Remote {
        let root: URL
        let settings: RemoteSimulatorSettings
        var remote: RemoteSimulator { RemoteSimulator(settings: settings) }
        var log: String { (try? String(contentsOf: root.appendingPathComponent("ssh.log"), encoding: .utf8)) ?? "" }
        var data: URL { root.appendingPathComponent("data") }
        func touch(_ name: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }
    }

    func makeRemote(_ tag: String, launcher: String, slowRsync: Bool = false, runtimeRoot: String? = nil) throws -> Remote {
        let root = ycodeDir.appendingPathComponent(".build-ide/r37-\(tag)-\(UUID().uuidString.prefix(8))")
        let ssh = root.appendingPathComponent("bin/fake-ssh")
        try writeExecutable("""
        #!/bin/sh
        echo "$@" >> "\(root.path)/ssh.log"
        while [ $# -gt 0 ]; do
          case "$1" in
            -o|-l|-p|-i) shift 2 ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        shift
        case "$*" in
          kill\\ *) [ -e "\(root.path)/fail-kill" ] && exit 255 ;;
          *YCODE-REMOTE-PID*) [ -e "\(root.path)/delay-run" ] && sleep 1 ;;
        esac
        exec /bin/sh -c "$*"
        """, ssh)
        let rsync = root.appendingPathComponent("bin/rsync")
        try writeExecutable("""
        #!/bin/sh
        \(slowRsync ? "sleep 1.5" : "")
        exec /usr/bin/rsync "$@"
        """, rsync)
        let simd = root.appendingPathComponent("bin/ycode-sim")
        try writeExecutable(launcher, simd)
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var s = RemoteSimulatorSettings(destination: "tester@fakehost", dataDirectory: data.path, runtimeRoot: runtimeRoot ?? root.appendingPathComponent("rr").path,
                                        simdPath: simd.path, deviceName: "dev1", ssh: ssh.path, rsync: rsync.path)
        s.runtimeVersion = RemoteSimulatorSettings.version(inPath: s.runtimeRoot)
        return Remote(root: root, settings: s)
    }

    func app(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("build/Remote.app")
        try writeInfoPlist(app, id: "dev.ycode.remote", exe: "Remote")
        try "binary".write(to: app.appendingPathComponent("Remote"), atomically: true, encoding: .utf8)
        return app
    }

    func session() throws -> WorkspaceSession {
        WorkspaceSession(model: try WorkspaceModel(url: try WindowSnapshotTests().samplePackage()))
    }

    // MARK: R1: the remote simulator's row

    @Test func runtimeVersionFromPathPlistAndDefaults() throws {
        #expect(RemoteSimulatorSettings.version(inPath: "/rt/iOS_27.1.simruntime/Contents/Resources/RuntimeRoot") == "27.1")
        #expect(RemoteSimulatorSettings.version(inPath: "/rr/iOS 27.1") == "27.1")
        #expect(RemoteSimulatorSettings.version(inPath: "/data/ycode/runtime") == nil)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ProductName": "x", "ProductVersion": "27.1"], format: .binary, options: 0)
        #expect(RemoteSimulator.productVersion(plist: plist) == "27.1")
        #expect(RemoteSimulator.productVersion(plist: Data("nope".utf8)) == nil)

        let t = TestDefaults("r37-version")
        defer { t.remove() }
        var s = RemoteSimulatorSettings(destination: "u@h", dataDirectory: "/d", runtimeRoot: "/data/rt", simdPath: "/s")
        s.save(t.defaults)
        #expect(RemoteSimulatorSettings.load(t.defaults).runtimeVersion == nil)
        RemoteSimulatorSettings.saveRuntimeVersion("27.1", root: "/data/rt", t.defaults)
        #expect(RemoteSimulatorSettings.load(t.defaults).runtimeVersion == "27.1")
        // Another runtime root: the remembered version no longer applies.
        s.runtimeRoot = "/data/rt2"
        s.save(t.defaults)
        #expect(RemoteSimulatorSettings.load(t.defaults).runtimeVersion == nil)
        #expect(!RemoteSimulatorSettings.hasRuntimeVersion(for: "/data/rt2", t.defaults))

        // The row: "<device name> <runtime version>"; identity by identifier.
        let d = RemoteSimulator.destination(runtimeVersion: "27.1")
        #expect(d.name == "Ycode Simulator" && d.osVersion == "27.1" && d.isYcodeRemoteSimulator && RemoteSimulator.destination.isYcodeRemoteSimulator)
        #expect(DestinationMenuModel.submenuTitle(d) == "Ycode Simulator 27.1")
        #expect(!sim("iPhone 17", "27.1").isYcodeRemoteSimulator)
    }

    @Test func remoteSimulatorSortsWithTheSimulatorsByRuntime() {
        let sims = [sim("iPhone 17", "26.4"), sim("iPad Air", "27.1"), sim("iPhone 18", "27.1")]
        let model = DestinationMenuModel(current: nil, devices: [], simulators: sims + [RemoteSimulator.destination(runtimeVersion: "27.1")],
                                         platforms: ["iOS"], designedForIPad: true)
        #expect(model.sections.map(\.title) == ["Devices", "Simulators", "Build"])
        #expect(model.rows("Simulators").map(DestinationMenuModel.submenuTitle) == ["iPhone 18 27.1", "iPad Air 27.1", "Ycode Simulator 27.1", "iPhone 17 26.4"])
        // An older runtime sorts lower.
        let older = DestinationMenuModel(current: nil, devices: [], simulators: sims + [RemoteSimulator.destination(runtimeVersion: "26.0")], platforms: ["iOS"])
        #expect(older.rows("Simulators").last?.isYcodeRemoteSimulator == true)
        // Version unknown: with the newest runtime, and the row has no version.
        let unknown = DestinationMenuModel(current: nil, devices: [], simulators: sims + [RemoteSimulator.destination], platforms: ["iOS"])
        #expect(unknown.rows("Simulators").map(DestinationMenuModel.submenuTitle) == ["iPhone 18 27.1", "iPad Air 27.1", "Ycode Simulator", "iPhone 17 26.4"])
        // A Mac product: incompatible, like the other iOS simulators.
        let mac = DestinationMenuModel(current: nil, devices: [], simulators: sims + [RemoteSimulator.destination(runtimeVersion: "27.1")], platforms: ["macOS"])
        #expect(mac.rows("Simulators").isEmpty)
        #expect(mac.incompatible.contains { $0.isYcodeRemoteSimulator && $0.name == "Ycode Simulator (mismatched platform)" })
    }

    @Test func destinationMenusListTheRemoteSimulatorUnderSimulators() async throws {
        try await withPrefs("menu") { p, dir in
            var remote = RemoteSimulatorSettings()
            remote.destination = "tester@sim-host"
            remote.dataDirectory = "/data/ycode"
            remote.runtimeRoot = "/data/ycode/iOS_27.1.simruntime"
            remote.simdPath = "/data/ycode/bin/ycode-sim"
            remote.save(p.defaults)
            let wc = try window(try iosApp(in: dir), state: dir.appendingPathComponent("state.json"))
            wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: [sim("iPhone 17", "26.4"), sim("iPhone 18", "27.1")]))
            let menu = try #require(wc.destinationPopUp.menu)
            let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            // No section of its own (§11.5).
            #expect(!titles.contains("Ycode"))
            let simsHeader = try #require(titles.firstIndex(of: "Simulators"))
            let buildHeader = try #require(titles.firstIndex(of: "Build"))
            let remoteIndex = try #require(menu.items.firstIndex { ($0.representedObject as? String) == RemoteSimulator.identifier })
            #expect(remoteIndex > simsHeader && remoteIndex < buildHeader)
            // The pop-up row: the name, then the version right-aligned.
            #expect(menu.items[remoteIndex].title.hasPrefix("Ycode Simulator"))
            #expect(menu.items[remoteIndex].attributedTitle?.string == "Ycode Simulator\t27.1")
            // Newest runtime first: iPhone 18 (27.1), the remote (27.1), iPhone 17 (26.4).
            let rowTitles = menu.items[(simsHeader + 1)..<buildHeader].filter { !$0.isSeparatorItem }.map { $0.title.components(separatedBy: "\t")[0] }
            #expect(rowTitles == ["iPhone 18", "Ycode Simulator", "iPhone 17"])

            // Product ▸ Destination: the same row, "<name> <version>", under Simulators.
            let bar = MainMenu.make()
            let sub = try #require(bar.item(withTitle: "Product")?.submenu?.item(withTitle: "Destination")?.submenu)
            DynamicMenus.fillDestinations(sub, model: wc.destinationMenuModel(), current: wc.session.destination, target: wc)
            let subTitles = sub.items.map { $0.isSeparatorItem ? "—" : $0.title }
            let s = try #require(subTitles.firstIndex(of: "Simulators"))
            #expect(Array(subTitles[(s + 1)...(s + 3)]) == ["iPhone 18 27.1", "Ycode Simulator 27.1", "iPhone 17 26.4"])
            #expect(subTitles.filter { $0.hasPrefix("Ycode Simulator") }.count == 1)

            // Choosing it selects the remote simulator (with its version).
            wc.selectDestinationRow(RemoteSimulator.identifier)
            #expect(wc.session.destination?.isYcodeRemoteSimulator == true && wc.session.destination?.osVersion == "27.1")
            #expect(WorkspaceWindowController.symbol(for: wc.session.destination!) == "candybarphone")
        }
    }

    @Test func runtimeVersionIsReadFromTheHostOnce() async throws {
        let r = try makeRemote("version", launcher: "#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: r.root) }
        let core = URL(fileURLWithPath: r.settings.runtimeRoot).appendingPathComponent("System/Library/CoreServices")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["ProductVersion": "27.1"], format: .xml, options: 0)
            .write(to: core.appendingPathComponent("SystemVersion.plist"))
        #expect(r.remote.runtimeVersionCommand == "cat '\(core.path)/SystemVersion.plist'")
        #expect(r.remote.readRuntimeVersion() == "27.1")
        #expect(r.log.contains("-o BatchMode=yes tester@fakehost cat"))

        try await withPrefs("probe") { p, dir in
            r.settings.save(p.defaults)
            let wc = try window(try iosApp(in: dir), state: dir.appendingPathComponent("state.json"))
            wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: [sim("iPhone 17", "26.4")]))
            #expect(wc.destinationMenuModel().rows("Simulators").first { $0.isYcodeRemoteSimulator }?.osVersion == nil)
            await wc.refreshRemoteRuntimeVersion(defaults: p.defaults, ssh: r.settings.ssh)?.value
            #expect(RemoteSimulatorSettings.load(p.defaults).runtimeVersion == "27.1")
            #expect(wc.destinationMenuModel().rows("Simulators").first?.isYcodeRemoteSimulator == true)
            #expect(wc.destinationMenuModel().rows("Simulators").first?.osVersion == "27.1")
            // Known now: no second ssh call.
            #expect(wc.refreshRemoteRuntimeVersion(defaults: p.defaults, ssh: r.settings.ssh) == nil)
        }
    }

    // MARK: Erase

    static let eraseLauncher = """
    #!/bin/sh
    echo "launcher args: $*"
    [ "$1" = --erase ] || exit 64
    echo "ycode-sim: erased $3"
    """

    @Test func eraseRunsTheLauncherThroughSSH() async throws {
        let r = try makeRemote("erase", launcher: Self.eraseLauncher)
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.remote.eraseCommand == "exec '\(r.settings.simdPath)' --erase --device '\(r.data.path)/devices/dev1'")
        let s = try session()
        let (ok, message) = await s.eraseRemoteSimulator(remote: r.remote)
        #expect(ok && message == "Erased")
        #expect(r.log.contains("-o BatchMode=yes tester@fakehost exec"))
        #expect(s.consoleText(.debugger).contains("ycode-sim: erased \(r.data.path)/devices/dev1"))

        // A failing launcher: the message says so.
        let bad = try makeRemote("erase-bad", launcher: "#!/bin/sh\necho 'ycode-sim: --erase needs --device' >&2\nexit 64\n")
        defer { try? FileManager.default.removeItem(at: bad.root) }
        let (ok2, m2) = await s.eraseRemoteSimulator(remote: bad.remote)
        #expect(!ok2 && m2 == "Erase failed (status 64): ycode-sim: --erase needs --device")

        // Not set up; and refused while this workspace runs an app on it.
        #expect(await s.eraseRemoteSimulator(remote: RemoteSimulator(settings: RemoteSimulatorSettings())).0 == false)
        let app = try app(in: r.root)
        s.simulatorRun = SimulatorRunState(target: .remote(destination: "tester@fakehost"), app: try #require(AppBundle(url: app)))
        let (ok3, m3) = await s.eraseRemoteSimulator(remote: r.remote)
        #expect(!ok3 && m3 == "Stop the run on Ycode Simulator before erasing it.")
        s.simulatorRun = nil
    }

    @Test func devicesWindowErasesTheRemoteSimulatorAfterConfirmation() async throws {
        let r = try makeRemote("devices", launcher: Self.eraseLauncher, runtimeRoot: "/rr/iOS 27.1")
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await withPrefs("devices") { p, dir in
            r.settings.save(p.defaults)
            let wc = try window(try iosApp(in: dir), state: dir.appendingPathComponent("state.json"))
            let other = DeviceRow(name: "Phone A", identifier: "A", platform: "iOS", osVersion: "26.4", state: "Shutdown", model: "Phone A", isAvailable: true)
            let c = DevicesController(devices: [], simulators: [other])
            wc.configureYcodeRemoteDevice(c, defaults: p.defaults, ssh: r.settings.ssh)
            c.view.frame = NSRect(x: 0, y: 0, width: 820, height: 480)
            c.show(.simulators)
            #expect(c.simulators.map(\.name) == ["Phone A", "Ycode Simulator"])
            let row = try #require(c.simulators.last)
            #expect(row.isYcodeRemote && row.osVersion == "27.1" && row.state == "Shutdown" && row.identifier == "tester@fakehost:\(r.data.path)/devices/dev1")

            // Only the remote row has the command.
            #expect(c.contextMenu(forRow: 0).items.isEmpty)
            let menu = c.contextMenu(forRow: 1)
            #expect(menu.items.map(\.title) == ["Erase All Content and Settings…"] && menu.items[0].isEnabled)

            // Cancelled: nothing runs.
            var asked: [String] = []
            c.confirmErase = { asked.append($0.name); return false }
            #expect(c.erase(row: 1) == nil)
            #expect(asked == ["Ycode Simulator"] && !r.log.contains("--erase"))
            #expect(c.erase(row: 0) == nil && asked.count == 1)

            // Confirmed: the launcher erases the device.
            c.confirmErase = { _ in true }
            c.select(row: 1)
            let task = try #require(c.erase(row: 1))
            #expect(c.eraseStatus == "Erasing…")
            await task.value
            #expect(c.eraseStatus == "Erased")
            #expect(c.detailRows.contains { $0 == ("Erase", "Erased") })
            #expect(r.log.contains("--erase --device '\(r.data.path)/devices/dev1'"))
            #expect(wc.session.consoleText(.debugger).contains("ycode-sim: erased"))
        }
        // Not set up: no row.
        try await withPrefs("devices-none") { _, dir in
            let wc = try window(try iosApp(in: dir), state: dir.appendingPathComponent("state.json"))
            let c = DevicesController(devices: [], simulators: [])
            wc.configureYcodeRemoteDevice(c)
            #expect(c.simulators.isEmpty)
        }
    }

    // MARK: R2: run status and Stop with the save at the stop

    /// A launcher stand-in like the real one at a stop: the first SIGINT
    /// "saves" and reports it, then keeps the connection open (ycode-simd's
    /// teardown); a second SIGINT ends it.
    static let savingLauncher = """
    #!/bin/sh
    n=0
    trap 'n=$((n+1)); if [ $n -ge 2 ]; then echo "closed"; exit 130; fi; echo "snapshot: exiting after the snapshot"; echo "ycode-sim: warm boot: the device was saved; the next run continues from it"' INT
    echo "ycode-sim: warm boot: restoring the device"
    echo "launch dev.ycode.remote: ok"
    echo "launched dev.ycode.remote pid 42"
    echo "hello from the remote app"
    while true; do sleep 0.1; done
    """

    @Test func stopSavesTheDeviceAndClosesWhenTheLauncherReportsIt() async throws {
        let r = try makeRemote("stop", launcher: Self.savingLauncher)
        defer { try? FileManager.default.removeItem(at: r.root) }
        let s = try session()
        await s.runOnRemoteSimulator(app: try app(in: r.root), remote: r.remote)
        #expect(await waitUntil(20) { s.console.contains("hello from the remote app") && s.simulatorRun?.remotePID != nil })
        #expect(s.activity == .running("Running Remote on Ycode Simulator (3 of 3)"))
        // The launcher's own lines are Ycode status, not program output.
        #expect(s.consoleText(.debugger).contains("ycode-sim: warm boot: restoring the device"))
        #expect(!s.consoleText(.target).contains("ycode-sim:") && s.consoleText(.target).contains("hello from the remote app"))
        let pid = try #require(s.simulatorRun?.remotePID)
        s.stopSimulatorRun(remote: r.remote)
        #expect(s.activity == .running("Stopping Remote — saving Ycode Simulator…"))
        #expect(await waitUntil(20) { s.simulatorRun == nil })
        #expect(r.log.contains("tester@fakehost kill -INT \(pid)"))
        #expect(s.consoleText(.debugger).contains("ycode-sim: warm boot: the device was saved"))
        #expect(s.console.contains("Ycode Simulator stopped"))
        #expect(s.activity == .finished("Finished running Remote"))
    }

    @Test func stopWithWarmBootOffAndWhenTheSignalFails() async throws {
        // The fake simd ends on SIGINT; the signal through ssh fails, so the
        // connection is closed (the local SIGINT).
        let r = try makeRemote("stop-fail", launcher: """
        #!/bin/sh
        trap 'echo "stopped by SIGINT"; exit 130' INT
        echo "launched dev.ycode.remote pid 42"
        while true; do sleep 0.1; done
        """)
        defer { try? FileManager.default.removeItem(at: r.root) }
        var cold = r.settings
        cold.warmBoot = false
        let remote = RemoteSimulator(settings: cold)
        let s = try session()
        await s.runOnRemoteSimulator(app: try app(in: r.root), remote: remote)
        #expect(await waitUntil(20) { s.console.contains("launched dev.ycode.remote") && s.simulatorRun?.remotePID != nil })
        r.touch("fail-kill")
        s.stopSimulatorRun(remote: remote)
        #expect(s.activity == .running("Stopping Remote…"))
        #expect(await waitUntil(20) { s.simulatorRun == nil })
        #expect(s.console.contains("the stop signal did not reach tester@fakehost (ssh status 255)"))
        #expect(s.console.contains("stopped by SIGINT"))
        // A stopped run is not a failed run.
        #expect(s.activity == .finished("Finished running Remote"))
    }

    @Test func stopAfterTheGraceTimeAndBeforeThePid() async throws {
        // Ignores the first SIGINT silently (a save that never reports).
        let r = try makeRemote("stop-grace", launcher: """
        #!/bin/sh
        n=0
        trap 'n=$((n+1)); if [ $n -ge 2 ]; then exit 130; fi' INT
        echo "launched dev.ycode.remote pid 42"
        while true; do sleep 0.1; done
        """)
        defer { try? FileManager.default.removeItem(at: r.root) }
        var remote = r.remote
        remote.stopGrace = 1
        let s = try session()
        await s.runOnRemoteSimulator(app: try app(in: r.root), remote: remote)
        #expect(await waitUntil(20) { s.console.contains("launched dev.ycode.remote") && s.simulatorRun?.remotePID != nil })
        s.stopSimulatorRun(remote: remote)
        #expect(await waitUntil(20) { s.simulatorRun == nil })
        #expect(s.console.contains("did not end 1 s after Stop; closing the connection"))

        // Stop before the pid line: the signal goes out when it arrives.
        r.touch("delay-run")
        await s.runOnRemoteSimulator(app: try app(in: r.root), remote: remote)
        #expect(s.simulatorRun?.remotePID == nil)
        s.stopSimulatorRun(remote: remote)
        #expect(await waitUntil(20) { s.simulatorRun == nil })
        #expect(r.log.components(separatedBy: "tester@fakehost kill -INT").count == 3)
    }

    @Test func secondStopClosesAtOnceAndStopDuringUploadLaunchesNothing() async throws {
        let r = try makeRemote("stop-upload", launcher: Self.savingLauncher, slowRsync: true)
        defer { try? FileManager.default.removeItem(at: r.root) }
        let s = try session()
        let app = try app(in: r.root)
        let run = Task { await s.runOnRemoteSimulator(app: app, remote: r.remote) }
        #expect(await waitUntil(10) { s.simulatorRun != nil })
        s.stopSimulatorRun(remote: r.remote)
        await run.value
        #expect(s.simulatorRun == nil && s.activity == .idle)
        #expect(s.console.contains("stopped before Remote was launched"))
        #expect(!r.log.contains("YCODE-REMOTE-PID"))

        // A second Stop does not wait for the save.
        var slow = r.remote
        slow.stopGrace = 600
        var fast = r.settings
        fast.rsync = "/usr/bin/rsync"
        let remote = RemoteSimulator(settings: fast)
        await s.runOnRemoteSimulator(app: app, remote: remote)
        #expect(await waitUntil(20) { s.console.contains("hello from the remote app") && s.simulatorRun?.remotePID != nil })
        s.stopSimulatorRun(remote: slow)
        s.stopSimulatorRun(remote: slow)
        #expect(await waitUntil(20) { s.simulatorRun == nil })
    }

    // MARK: P15: the preview activity text

    @Test func previewFamilyAndActivityText() async throws {
        #expect(WorkspaceWindowController.family(ofDeviceNamed: "iPhone 17 Pro") == "iPhone")
        #expect(WorkspaceWindowController.family(ofDeviceNamed: "iPad Air 13-inch (M3)") == "iPad")
        #expect(WorkspaceWindowController.family(ofDeviceNamed: "Apple Vision Pro") == "Apple Vision")
        #expect(WorkspaceWindowController.family(ofDeviceNamed: "Apple Watch Series 10 (46mm)") == "Apple Watch")
        let sims = [sim("iPhone 17", "26.4"), sim("iPad Air", "27.1"), sim("iPhone 18", "27.1")]
        #expect(WorkspaceWindowController.previewFamily(platform: "iOS", destination: nil, simulators: sims) == "iPhone")
        #expect(WorkspaceWindowController.previewFamily(platform: "iOS", destination: sims[1], simulators: sims) == "iPad")
        #expect(WorkspaceWindowController.previewFamily(platform: "iOS", destination: RemoteSimulator.destination, simulators: sims) == "iPhone")
        #expect(WorkspaceWindowController.previewFamily(platform: "iOS", destination: nil, simulators: []) == "iOS")
        #expect(WorkspaceWindowController.previewFamily(platform: "macOS", destination: nil, simulators: sims) == nil)
        #expect(WorkspaceWindowController.previewFamily(platform: nil, destination: nil, simulators: sims) == nil)

        try await withPrefs("preview") { _, dir in
            let wc = try window(try iosApp(in: dir), state: dir.appendingPathComponent("state.json"))
            wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: sims))
            #expect(wc.previewActivityText == "Preparing iPhone Simulator")
            wc.activityView.status = "Build Succeeded • Today at 10:00"
            let token = wc.beginPreviewActivity()
            #expect(token != nil && wc.activityView.status == "Preparing iPhone Simulator" && wc.activityView.isBusy)
            // A newer preview build takes over; the older one's end changes nothing.
            let newer = wc.beginPreviewActivity()
            wc.endPreviewActivity(token)
            #expect(wc.activityView.status == "Preparing iPhone Simulator")
            wc.endPreviewActivity(newer)
            #expect(wc.activityView.status == "Build Succeeded • Today at 10:00" && !wc.activityView.isBusy)
        }
        // A package previews on the Mac: no simulator text.
        let pkg = try WindowSnapshotTests().samplePackage()
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: pkg)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        #expect(wc.previewActivityText == nil && wc.beginPreviewActivity() == nil)
    }

    // MARK: D4: disabled placeholders

    @Test func viewHierarchyAndMemoryGraphAreDisabledPlaceholders() throws {
        _ = NSApplication.shared
        let debug = DebugAreaController()
        _ = debug.view
        for tip in ["Debug View Hierarchy", "Debug Memory Graph"] {
            let b = try #require(debug.barButtonViews.first { $0.toolTip == tip })
            #expect(!b.isEnabled && b.action == nil)
        }
        let backtrace = try #require(debug.barButtonViews.first { $0.toolTip == "Enable Backtrace in Editor" })
        #expect(backtrace.isEnabled)
        let bar = MainMenu.make()
        let item = try #require(bar.item(withTitle: "Debug")?.submenu?.item(withTitle: "View Debugging")?.submenu?.item(withTitle: "Capture View Hierarchy"))
        #expect(item.action != Selector(("debugViewHierarchy:")))
    }
}
