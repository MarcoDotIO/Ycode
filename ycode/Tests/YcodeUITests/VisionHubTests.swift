import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Device Hub ▸ Add Device ▸ Apple Vision Pro… (IDE-SMALL, `device-hub.md`
/// §I.11): with a visionOS runtime set up the item creates an Apple Vision
/// Pro of Ycode's (Name, OS Version "visionOS 27.0", Model "Apple Vision
/// Pro"); its row is a visionOS device, Start boots it with the launcher
/// (`--device-type vision-pro` on the visionOS runtime root) and Delete…
/// erases it on the host. ssh is a local stand-in and the launcher a
/// script that logs its arguments: no network.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct VisionHubTests {
    static let iosRoot = "/rr/iOS-27.0-24A434/RuntimeRoot"
    static let visionRoot = "/rr/xrOS-27.0-24O353/RuntimeRoot"

    /// Boots print a line and stay until they are interrupted (as the
    /// launcher does); `--erase` removes the device directory; control
    /// commands answer at once (Device Hub asks a booted device for its
    /// settings; a boot-like answer kept that call, and a child process,
    /// alive until the end of the run).
    static let launcher = #"""
    #!/bin/sh
    R="$(dirname "$0")/.."
    echo "$@" >> "$R/launcher.log"
    # A control command (`--device D --control …`) answers and ends.
    [ "$1" = --device ] && [ "$3" = --control ] && { echo "ok"; exit 0; }
    case "$1" in
      --erase) rm -rf "$3"; echo "erased $3" ;;
      --device) mkdir -p "$2"; echo "ycode-simd: booted"; trap 'exit 0' INT TERM; while :; do sleep 0.2; done ;;
      list-pairs) echo '{"pairs":{}}' ;;
      *) echo "error: unknown"; exit 64 ;;
    esac
    """#

    struct Remote {
        let root: URL
        let settings: RemoteSimulatorSettings
        var log: String { (try? String(contentsOf: root.appendingPathComponent("launcher.log"), encoding: .utf8)) ?? "" }
        var devices: URL { root.appendingPathComponent("data/devices") }
    }

    func makeRemote(vision: Bool) throws -> Remote {
        let root = ycodeDir.appendingPathComponent(".build-ide/vision-hub-\(UUID().uuidString.prefix(8))")
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
        try writeExecutable(Self.launcher, simd)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/devices"), withIntermediateDirectories: true)
        var s = RemoteSimulatorSettings(destination: "tester@fakehost", dataDirectory: root.appendingPathComponent("data").path,
                                        runtimeRoot: Self.iosRoot, simdPath: simd.path, deviceName: "dev", ssh: ssh.path)
        s.otherRuntimeRoots = vision ? [Self.visionRoot] : []
        s.runtimeVersion = "27.0"
        return Remote(root: root, settings: s)
    }

    func withHub(_ r: Remote, _ body: @MainActor (DevicesController, UserDefaults) async throws -> Void) async throws {
        let t = TestDefaults("vision-hub")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-vision-hub-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared, oldStore = RemotePairsStore.shared.defaults
        Preferences.shared = p
        RemotePairsStore.shared.defaults = t.defaults
        defer {
            Preferences.shared = old
            RemotePairsStore.shared.defaults = oldStore
            NotificationCenter.default.post(name: Preferences.didChange, object: nil)
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        r.settings.save(p.defaults)
        RemoteSimulatorSettings.saveRuntimeVersion("27.0", root: Self.iosRoot, p.defaults)
        RemoteSimulatorSettings.saveRuntimePlatform("iOS", root: Self.iosRoot, p.defaults)
        if r.settings.otherRuntimeRoots.contains(Self.visionRoot) {
            RemoteSimulatorSettings.saveRuntimeVersion("27.0", root: Self.visionRoot, p.defaults, primary: false)
            RemoteSimulatorSettings.saveRuntimePlatform("visionOS", root: Self.visionRoot, p.defaults)
        }
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false,
                                           userStateURL: dir.appendingPathComponent("state.json"))
        let c = DevicesController(devices: [], simulators: [])
        wc.configureYcodeRemoteDevice(c, defaults: p.defaults, ssh: r.settings.ssh)
        c.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        c.pairing.confirm = { _, _, _ in true }
        try await body(c, p.defaults)
    }

    @Test func addDeviceCreatesStartsAndDeletesAVisionPro() async throws {
        let r = try makeRemote(vision: true)
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await withHub(r) { c, defaults in
            // The visionOS runtime gives a fixed row and enables the item;
            // the iPhone rows and run destinations are unchanged.
            let s = RemoteSimulatorSettings.load(defaults)
            #expect(s.visionTargets.map(\.name) == ["Apple Vision Pro (Ycode)"])
            #expect(s.targets.allSatisfy { $0.deviceType.platform == "iOS" })
            #expect(c.rows.contains { $0.name == "Apple Vision Pro (Ycode)" && $0.platform == "visionOS" })
            let add = DeviceHubToolbar.addItems(target: nil, hub: c)
            let item = try #require(add.first { $0.title == "Apple Vision Pro…" })
            #expect(item.isEnabled && item.action == #selector(DevicesController.newVisionDeviceChosen(_:)))
            #expect(add.first { $0.title == "Apple TV…" }?.isEnabled == false)

            // The form: Name (placeholder the model), OS Version, Model.
            var shown: HubDeviceForm?
            c.pairing.presentForm = { form, done in
                shown = form
                form.vision?.name.stringValue = "Test Vision"
                done(true)
            }
            c.presentNewVisionDevice()
            let form = try #require(shown)
            #expect(form.kind == .newVision && form.button == "Create" && form.watch == nil)
            #expect(form.vision?.os.itemTitles == ["visionOS 27.0"])
            #expect(form.vision?.model.itemTitles == ["Apple Vision Pro"])
            #expect(form.vision?.name.placeholderString == "Apple Vision Pro")
            let created = RemoteSimulatorSettings.createdDevices(defaults)
            #expect(created.map(\.name) == ["Test Vision"] && created.map(\.typeID) == ["vision-pro"] && created.map(\.runtimeRoot) == [Self.visionRoot])
            let row = try #require(c.rows.first { $0.name == "Test Vision" })
            #expect(row.platform == "visionOS" && row.isCreated && row.osVersion == "27.0")
            #expect(c.selected?.name == "Test Vision")
            // Not a run destination of iOS schemes.
            #expect(!RemoteSimulatorSettings.load(defaults).targets.contains { $0.deviceDirectoryName == created[0].directoryName })

            // Start: the launcher boots it on the visionOS runtime.
            let dir = r.devices.appendingPathComponent(created[0].directoryName).path
            await c.start(row)?.value
            #expect(c.rows.first { $0.name == "Test Vision" }?.state == "Booted")
            for _ in 0..<50 where !r.log.contains("--device") { try await Task.sleep(nanoseconds: 100_000_000) }
            #expect(r.log.contains("--device \(dir) --runtime-root \(Self.visionRoot) --device-type vision-pro"), "\(r.log)")
            // Delete… is refused while it runs; after Shut Down it erases it.
            let booted = try #require(c.rows.first { $0.name == "Test Vision" })
            #expect(c.pairingMenuItems(for: booted).first { $0.title == "Delete…" }?.isEnabled == false)
            await c.shutDown(booted)?.value
            let stopped = try #require(c.rows.first { $0.name == "Test Vision" })
            c.delete(stopped)
            await c.pairing.task?.value
            #expect(r.log.contains("--erase --device \(dir)"), "\(r.log)")
            #expect(RemoteSimulatorSettings.createdDevices(defaults).isEmpty)
            #expect(!c.rows.contains { $0.name == "Test Vision" })
            #expect(!FileManager.default.fileExists(atPath: dir))
        }
    }

    @Test func noVisionRuntimeLeavesTheItemDisabled() async throws {
        let r = try makeRemote(vision: false)
        defer { try? FileManager.default.removeItem(at: r.root) }
        try await withHub(r) { c, _ in
            #expect(!c.canCreateVisionDevices)
            #expect(DeviceHubToolbar.addItems(target: nil, hub: c).first { $0.title == "Apple Vision Pro…" }?.isEnabled == false)
            #expect(!c.rows.contains { $0.platform == "visionOS" })
        }
    }

    /// A runtime root whose platform was not read yet counts as visionOS
    /// when its path names xrOS or visionOS.
    @Test func runtimePlatformFromThePath() {
        let s = RemoteSimulatorSettings(destination: "h", dataDirectory: "/d", runtimeRoot: Self.iosRoot, simdPath: "/s", deviceName: "dev")
        #expect(s.runtimePlatform(forRoot: Self.visionRoot) == "visionOS")
        #expect(s.runtimePlatform(forRoot: "/rr/visionOS-26.4/RuntimeRoot") == "visionOS")
        #expect(s.runtimePlatform(forRoot: Self.iosRoot) == "iOS")
        #expect(YcodeSimulatorDeviceType.named("vision-pro")?.platform == "visionOS")
        var t = RemoteSimulatorTarget(runtimeRoot: Self.visionRoot, deviceType: .visionPro, deviceDirectoryName: "x", isPrimary: false)
        t.runtimeVersion = "27.0"
        #expect(t.destination.platform == "visionOS" && t.destination.specifier == "generic/platform=visionOS Simulator")
        #expect(t.deviceTypeArguments == ["--device-type", "vision-pro"])
    }
}
