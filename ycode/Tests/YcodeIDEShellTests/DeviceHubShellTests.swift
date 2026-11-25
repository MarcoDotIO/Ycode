import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// A simulator host that answers from memory: `boot` and `shutdown` change
/// the device's state; every request is recorded.
final class FakeHubBackend: DeviceHubBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [DeviceHubHost]
    private(set) var requests: [String] = []
    var failBoot: String?

    init(_ hosts: [DeviceHubHost]) { self.hosts = hosts }

    var recorded: [String] { lock.withLock { requests } }

    func list() -> [DeviceHubHost] { lock.withLock { requests.append("devices"); return hosts } }

    private func set(_ d: DeviceHubDevice, _ state: String) {
        for h in hosts.indices { for i in hosts[h].devices.indices where hosts[h].devices[i].id == d.id { hosts[h].devices[i].state = state } }
    }

    func boot(_ d: DeviceHubDevice) -> (Bool, String) {
        lock.withLock {
            requests.append("boot \(d.host)/\(d.name)")
            if let failBoot { return (false, failBoot) }
            set(d, "running")
            return (true, "\(d.name) starting")
        }
    }

    func shutdown(_ d: DeviceHubDevice) -> (Bool, String) {
        lock.withLock {
            requests.append("shutdown \(d.host)/\(d.name)")
            set(d, "shutdown")
            return (true, "\(d.name) stopped")
        }
    }

    func display(_ d: DeviceHubDevice) -> (@Sendable () throws -> DisplayTransport)? { nil }
}

/// The Linux IDE's Device Hub (`specs/ide/device-hub.md`, "Ycode decisions
/// (2026-11-17)"): the menus open it with or without a workspace; it lists
/// the paired hosts' Ycode simulators in the macOS hub's sections; Start,
/// Shut Down and Restart go to the host; failures say why; the Info rows and
/// the window's title; the live picture's sampling.
@MainActor
struct DeviceHubShellTests {
    static let runtime = "/data/runtimes/iOS-27.1-24A94401/RuntimeRoot"
    static func hosts() -> [DeviceHubHost] {
        [DeviceHubHost(name: "thor", devices: [
            DeviceHubDevice(host: "thor", name: "iPhone 18 Pro", deviceType: "iphone-18-pro", runtime: runtime, state: "shutdown"),
            DeviceHubDevice(host: "thor", name: "Duo", deviceType: "iphone-duo", runtime: runtime, state: "running"),
        ]), DeviceHubHost(name: "lab", devices: [], offline: true)]
    }

    func app() throws -> (ShellAppModel, UserDefaults, String) {
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-shell-hub-\(UUID().uuidString)").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (ShellAppModel(recentProjects: RecentProjects(defaults: defaults)), defaults, suite)
    }

    @Test func manageDevicesAndDeviceHubOpenTheHubWithoutAWorkspace() async throws {
        let (app, defaults, suite) = try app()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeHubBackend(Self.hosts())
        app.deviceHub.backend = fake
        var opened: [String] = []
        app.openWindow = { opened.append($0) }
        #expect(app.workspace == nil)
        // Both items of the menu bar carry showDevices: (Product ▸ Destination ▸ Manage Devices…, Open Developer Tool ▸ Device Hub).
        let items = ShellCommand.table.filter { $0.action == "showDevices:" }
        #expect(items.map(\.title).sorted() == ["Device Hub", "Manage Devices…"])
        for c in items {
            #expect(ShellMenuModel.isEnabled(c, app: app))
            ShellMenuModel.perform(c, app: app)
        }
        #expect(opened == [ShellAppModel.deviceHubWindowID, ShellAppModel.deviceHubWindowID])
        for _ in 0..<100 where !app.deviceHub.loaded { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(app.deviceHub.devices.map(\.name) == ["iPhone 18 Pro", "Duo"])
    }

    @Test func listsTheHostsSimulatorsInTheHubsSections() throws {
        let hub = DeviceHubShellModel(backend: FakeHubBackend([]))
        hub.apply(Self.hosts())
        #expect(hub.rows.first == .header(HubSidebarModel.available, collapsed: false))
        // Sorted by name, as the macOS hub's Sort By ▸ Name.
        #expect(hub.rows.compactMap(\.device).map(\.name) == ["Duo", "iPhone 18 Pro"])
        let duo = try #require(hub.rows.compactMap(\.device).first)
        #expect(duo.isRunning && duo.subtitle == "Simulator" && duo.shortVersion == "27.1")
        #expect(hub.offlineHosts == ["lab"])
        // The first row is selected; the title and subtitle are the device's.
        #expect(hub.selected?.name == "Duo")
        hub.select("thor/iPhone 18 Pro")
        #expect(hub.title == "iPhone 18 Pro" && hub.subtitle.hasPrefix("iOS 27.1"))
        #expect(hub.infoRows.map(\.0) == ["Name", "OS", "Model", "State", "Host", "Identifier", "Available"])
        #expect(hub.infoRows.first { $0.0 == "State" }?.1 == "Shutdown")
        #expect(hub.infoRows.first { $0.0 == "Model" }?.1 == "iPhone 18 Pro")
        hub.setSearch("duo")
        #expect(hub.rows.compactMap(\.device).map(\.name) == ["Duo"])
        hub.setSearch("zzz")
        #expect(hub.sidebar.showsNoResults)
        hub.setSearch("")
        hub.toggleSection(HubSidebarModel.available)
        #expect(hub.rows == [.header(HubSidebarModel.available, collapsed: true)])
    }

    @Test func startShutDownAndRestartGoToTheHost() async throws {
        let fake = FakeHubBackend(Self.hosts())
        let hub = DeviceHubShellModel(backend: fake)
        hub.apply(fake.list())
        let phone = try #require(hub.devices.first)
        #expect(hub.canStart(phone) && !hub.canShutDown(phone))
        let t = try #require(hub.start(phone))
        #expect(hub.busy.contains(phone.id))
        #expect(hub.start(phone) == nil, "one command at a time")
        await t.value
        #expect(!hub.busy.contains(phone.id))
        #expect(hub.devices.first?.state == "running")
        #expect(fake.recorded.contains("boot thor/iPhone 18 Pro"))
        let running = try #require(hub.devices.first)
        await hub.shutDown(running)?.value
        #expect(hub.devices.first?.state == "shutdown")
        // Restart: Shut Down, then Start once the host says it stopped.
        let duo = try #require(hub.devices.last)
        await hub.restart(duo)?.value
        let r = fake.recorded.filter { $0.hasPrefix("boot") || $0.hasPrefix("shutdown") }
        #expect(Array(r.suffix(2)) == ["shutdown thor/Duo", "boot thor/Duo"])
        #expect(hub.devices.last?.state == "running")
    }

    @Test func aFailedStartSaysWhy() async throws {
        let fake = FakeHubBackend(Self.hosts())
        fake.failBoot = "no runtime for iphone-18-pro"
        let hub = DeviceHubShellModel(backend: fake)
        hub.apply(fake.list())
        hub.select("thor/iPhone 18 Pro")
        await hub.start()?.value
        #expect(hub.banner == "Could not start iPhone 18 Pro: no runtime for iphone-18-pro")
        #expect(hub.devices.first?.state == "shutdown")
        // The controls of a stopped device say to start it.
        hub.perform(.home)
        #expect(hub.banner == DeviceHubShellModel.startFirst)
    }

    @Test func aDeviceThatStopsByItselfSaysWhy() async throws {
        let fake = FakeHubBackend(Self.hosts())
        let hub = DeviceHubShellModel(backend: fake)
        hub.apply(fake.list())
        var hosts = Self.hosts()
        hosts[0].devices[1].state = "shutdown"
        hub.apply(hosts)
        for _ in 0..<100 where hub.banner == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(hub.banner == "Duo stopped." && hub.stopReasons["thor/Duo"] == "Duo stopped.")
        #expect(DeviceHubShellModel.stopMessage("Phone", log: ["ycode-simd: started", "ycode-simd: open /dev/kvm failed (errno 13): Permission denied",
                                                                 "ycode-sim: warm boot: the device was not saved"])
                == "Phone stopped: ycode-simd: open /dev/kvm failed (errno 13): Permission denied")
        // A Shut Down from the hub is not a failure.
        let quiet = DeviceHubShellModel(backend: FakeHubBackend(Self.hosts()))
        quiet.apply(Self.hosts())
        await quiet.shutDown(quiet.devices.last!)?.value
        #expect(quiet.banner == nil)
    }

    @Test func theRuntimeNamesTheOS() {
        #expect(DeviceHubDevice.runtimeParts("/x/iOS-27.1-24A94401/RuntimeRoot") == ("iOS", "27.1"))
        #expect(DeviceHubDevice.runtimeParts("/x/xrOS-27.0-24N5/RuntimeRoot") == ("visionOS", "27.0"))
        #expect(DeviceHubDevice.runtimeParts("/x/watchOS-27.1-24R1") == ("watchOS", "27.1"))
        let d = DeviceHubDevice(host: "h", name: "n", deviceType: "ipad-a16", runtime: "/x/iOS-27.1-1/RuntimeRoot", state: "running")
        #expect(d.hubDevice.osTitle == "iPadOS 27.1")
    }

    @Test func thePictureIsSampledAndTurned() {
        // A 4 × 2 BGRX picture: red, green, blue, white over four greys.
        let w = 4, h = 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let colours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (10, 10, 10), (20, 20, 20), (30, 30, 30), (40, 40, 40)]
        for (i, c) in colours.enumerated() { px[i * 4] = c.2; px[i * 4 + 1] = c.1; px[i * 4 + 2] = c.0; px[i * 4 + 3] = 255 }
        func rgb(_ p: DeviceScreenPicture, _ x: Int, _ y: Int) -> [UInt8] { Array(p.rgba[(y * p.width + x) * 4..<(y * p.width + x) * 4 + 3]) }
        px.withUnsafeBytes { b in
            let same = DeviceScreenPicture.sample(bgrx: b.baseAddress!, rowBytes: w * 4, width: w, height: h, rotation: 0, width: 4, height: 2)
            #expect(rgb(same, 0, 0) == [255, 0, 0] && rgb(same, 3, 0) == [255, 255, 255] && rgb(same, 3, 1) == [40, 40, 40])
            #expect(same.rgba[3] == 255)
            // Turned a quarter clockwise: 2 wide, 4 tall; the top row is the old left column, bottom first.
            let turned = DeviceScreenPicture.sample(bgrx: b.baseAddress!, rowBytes: w * 4, width: w, height: h, rotation: 90, width: 2, height: 4)
            #expect(rgb(turned, 0, 0) == [10, 10, 10] && rgb(turned, 1, 0) == [255, 0, 0] && rgb(turned, 1, 3) == [255, 255, 255])
            // Half the size each way: the mean of each 2 × 2 block.
            let half = DeviceScreenPicture.sample(bgrx: b.baseAddress!, rowBytes: w * 4, width: w, height: h, rotation: 0, width: 2, height: 1)
            // (255 + 0 + 10 + 20) / 4, (0 + 255 + 10 + 20) / 4, (0 + 0 + 10 + 20) / 4
            #expect(rgb(half, 0, 0) == [71, 71, 7])
        }
    }
}

/// The live screen end to end with the stand-in host (`DeviceHubStandIn`):
/// Start, the display's hello and pictures sampled for the canvas, Home and
/// a touch reaching the device, Screenshot saved, the Settings card read and
/// changed over the stream, Shut Down ending the screen.
@MainActor
@Suite(.serialized) struct DeviceHubLiveShellTests {
    func wait(_ what: String, seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > end { Issue.record("timed out: \(what)"); return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @Test func aStartedDeviceShowsItsLiveScreenAndTakesTheControls() async throws {
        let standIn = DeviceHubStandInBackend(bootSeconds: 0.2)
        let hub = DeviceHubShellModel(backend: standIn)
        await hub.refresh()?.value
        hub.select("stand-in/iPhone 18 Pro")
        let d = try #require(hub.selected)
        await hub.start(d)?.value
        guard await wait("running", { hub.selected?.state == "running" || { hub.refresh(); return false }() }) else { return }
        let running = try #require(hub.selected)
        let screen = try #require(hub.screen(for: running))
        screen.setCanvas(width: 580, height: 748, pixelDensity: 1)
        guard await wait("a picture", { screen.picture != nil && screen.isLive }) else { return }
        let pic = try #require(screen.picture)
        // The picture is the screen's size in the canvas (points × density).
        #expect(pic.width == Int(screen.layout.screen.width.rounded()) && pic.height == Int(screen.layout.screen.height.rounded()))
        #expect(screen.hasHello && screen.layout.geometry.screen.width > 0)
        // Home and a touch reach the device.
        hub.perform(.home)
        let s = screen.layout.screen
        screen.pointerDown(x: s.x + s.width * 0.1, y: s.y + s.height * 0.1)
        screen.pointerUp(x: s.x + s.width * 0.1, y: s.y + s.height * 0.1)
        _ = await wait("home and touch", { standIn.received(running.id).contains("button home") && standIn.received(running.id).contains("touch") })
        // Screenshot: the server's PNG in the capture folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-hub-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        screen.captureDirectory = dir
        hub.perform(.screenshot)
        _ = await wait("screenshot", { hub.banner == "Screenshot Saved" })
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1 && files.first?.hasPrefix("Screenshot iPhone 18 Pro") == true && files.first?.hasSuffix(".png") == true)
        // Settings over the stream.
        await hub.refreshSettings()?.value
        #expect(hub.settings?.state.appearance == .light)
        #expect(hub.settingsEnabled)
        await hub.applySetting(["ui", "appearance", "dark"], failureTitle: "Failed to Set Appearance")?.value
        #expect(hub.settings?.state.appearance == .dark && hub.settingsFailure == nil)
        #expect(standIn.received(running.id).contains("command ui appearance dark"))
        // Shut Down ends the screen.
        await hub.shutDown(running)?.value
        #expect(hub.selected?.state == "shutdown" && hub.screens[running.id] == nil)
    }
}
