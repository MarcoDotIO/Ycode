import Foundation
import Observation
import YcodeDeviceModel
import YcodeDisplayStream
import YcodeIDECore
import YcodeSimFeatures

/// The Linux IDE's Device Hub (`specs/ide/device-hub.md`, "Ycode decisions
/// (2026-11-17)"), laid out as the macOS hub: a sidebar of devices
/// (Available / Unavailable, search, the shared `HubSidebarModel`), a canvas
/// with the selected device's live screen (`DeviceHubScreen`) or its status
/// with Start, and an inspector with Settings, Reports and Info. It lists the
/// Ycode simulators of every paired simulator host (a host on this computer
/// included), started, shut down and restarted over Ycode's link, and of the
/// hosts `ycrun` set up (`DeviceHubSimHostBackend`: the IDE's host in the
/// `ycode-ide` defaults domain, ycrun's others, and this machine where the
/// placement policy runs devices here), over ssh. The state follows the
/// hosts every 2 seconds while the window shows.
@MainActor
@Observable
public final class DeviceHubShellModel {
    public enum InspectorTab: String, CaseIterable, Sendable {
        case settings, reports, info
        public var title: String { rawValue.capitalized }
        public var symbol: String {
            switch self {
            case .settings: "slider.horizontal.3"
            case .reports: "doc.text"
            case .info: "info.circle"
            }
        }
    }

    @ObservationIgnored public var backend: any DeviceHubBackend
    public private(set) var devices: [DeviceHubDevice] = []
    /// Paired hosts that did not answer.
    public private(set) var offlineHosts: [String] = []
    /// The first list arrived.
    public private(set) var loaded = false
    /// Filter, search and collapsed sections (the macOS hub's model).
    public private(set) var sidebar = HubSidebarModel()
    public private(set) var selectedID: String?
    public var inspectorTab: InspectorTab = .settings
    public var inspectorShown = true
    public var sidebarShown = true
    /// Devices being started or shut down (the canvas shows a spinner).
    public private(set) var busy: Set<String> = []
    /// The banner over the canvas ("Screenshot Saved", a failure), and when it goes.
    public private(set) var banner: String?
    @ObservationIgnored private var bannerUntil: Date?
    /// The live screens of running devices, made on demand.
    @ObservationIgnored public private(set) var screens: [String: DeviceHubScreen] = [:]
    /// The selected running device's settings as last read (nil: unknown).
    public private(set) var settings: DeviceSettingsSnapshot?
    /// The last settings command's failure (title, message), shown under the cards.
    public private(set) var settingsFailure: (title: String, message: String)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    /// Why a device stopped by itself, shown on its picture until it starts again.
    public private(set) var stopReasons: [String: String] = [:]
    /// Devices Shut Down from the hub (their stop is not a failure).
    @ObservationIgnored private var expectedStops: Set<String> = []
    @ObservationIgnored private var refreshing = false
    /// The command in flight (tests await it).
    @ObservationIgnored public private(set) var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored public private(set) var settingsTask: Task<Void, Never>?
    /// Opens a device in the device window (`ycode-sim-viewer --link`); the
    /// view layer installs it.
    @ObservationIgnored public var openDeviceWindow: (DeviceHubDevice) -> Void = { _ in }

    public init(backend: any DeviceHubBackend = DeviceHubAllHostsBackend()) {
        self.backend = backend
    }

    // MARK: Rows

    public var selected: DeviceHubDevice? { selectedID.flatMap { id in devices.first { $0.id == id } } }
    /// The sidebar's rows (sections and devices, filter and search applied).
    public var rows: [HubSidebarRow] { sidebar.rows }

    public func setSearch(_ text: String) { sidebar.search = text }
    public func setFilter(_ f: HubFilter) { sidebar.filter = f }
    public func toggleSection(_ title: String) { sidebar.toggle(section: title) }

    /// Reads every host's devices again (off the main actor).
    @discardableResult
    public func refresh() -> Task<Void, Never>? {
        guard !refreshing else { return nil }
        refreshing = true
        let backend = backend
        return Task { [weak self] in
            let hosts = await Task.detached { backend.list() }.value
            self?.apply(hosts)
            self?.refreshing = false
        }
    }

    /// The hosts' lists as they are now.
    public func apply(_ hosts: [DeviceHubHost]) {
        var list = hosts.flatMap(\.devices)
        // A device that stopped without Shut Down (its boot failed, it
        // crashed): the host's log says why.
        for d in list where d.isStopped && !busy.contains(d.id) {
            guard devices.first(where: { $0.id == d.id })?.isRunning == true, !expectedStops.contains(d.id) else { continue }
            explainStop(d)
        }
        expectedStops.subtract(list.filter(\.isStopped).map(\.id))
        // A device being started or shut down keeps its row until the command ends.
        for (i, d) in list.enumerated() where busy.contains(d.id) {
            if let old = devices.first(where: { $0.id == d.id }) { list[i].state = old.state }
        }
        let offline = hosts.filter(\.offline).map(\.name)
        if list != devices { devices = list }
        if offline != offlineHosts { offlineHosts = offline }
        loaded = true
        var m = sidebar
        m.devices = list.map(\.hubDevice)
        if m != sidebar { sidebar = m }
        // Screens of devices that stopped end; the selection stays if it is listed.
        for (id, s) in screens where !(list.first { $0.id == id }?.isRunning ?? false) {
            s.stop()
            screens[id] = nil
            if let d = list.first(where: { $0.id == id }) ?? devices.first(where: { $0.id == id }) { backend.endDisplay(d) }
        }
        if selectedID == nil || !list.contains(where: { $0.id == selectedID }) { selectedID = sidebar.rows.compactMap(\.device).first?.id ?? list.first?.id }
        if selected?.isRunning != true { settings = nil }
    }

    public func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        settings = nil
        settingsFailure = nil
        if selected?.isRunning == true { refreshSettings() }
    }

    /// Every 2 seconds while the window shows (`onAppear` / `onDisappear`).
    public func startPolling(interval: Double = 2) {
        guard poller == nil else { return }
        refresh()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
                guard let self else { return }
                self.refresh()
                self.expireBanner()
                if self.settings == nil, self.settingsTask == nil, let s = self.selected, s.state == "running",
                   self.screens[s.id]?.isLive == true { self.refreshSettings() }
            }
        }
    }

    /// The window closed: polling and every live screen end.
    public func stopPolling() {
        poller?.cancel()
        poller = nil
        for (id, s) in screens {
            s.stop()
            if let d = devices.first(where: { $0.id == id }) { backend.endDisplay(d) }
        }
        screens = [:]
    }

    // MARK: Live screens

    /// The live screen of a running device (made and connected on first use).
    public func screen(for d: DeviceHubDevice) -> DeviceHubScreen? {
        guard d.isRunning else { return nil }
        if let s = screens[d.id] { return s }
        guard let connect = backend.display(d) else { return nil }
        let s = DeviceHubScreen(deviceID: d.id, connect: connect, spec: d.spec)
        screens[d.id] = s
        s.start()
        return s
    }

    // MARK: Start, Shut Down, Restart

    public func canStart(_ d: DeviceHubDevice) -> Bool { d.isStopped && !busy.contains(d.id) }
    public func canShutDown(_ d: DeviceHubDevice) -> Bool { d.isRunning && !busy.contains(d.id) }

    @discardableResult
    public func start(_ d: DeviceHubDevice? = nil) -> Task<Void, Never>? {
        guard let d = d ?? selected, canStart(d) else { return nil }
        let backend = backend
        stopReasons[d.id] = nil
        return run(d, newState: "booting", failure: "Could not start \(d.name)") { backend.boot(d) }
    }

    @discardableResult
    public func shutDown(_ d: DeviceHubDevice? = nil) -> Task<Void, Never>? {
        guard let d = d ?? selected, canShutDown(d) else { return nil }
        let backend = backend
        expectedStops.insert(d.id)
        screens[d.id]?.stop()
        screens[d.id] = nil
        return run(d, newState: "shutdown", failure: "Could not shut down \(d.name)") { backend.shutdown(d) }
    }

    /// Shut Down, then Start once the host says the device stopped.
    @discardableResult
    public func restart(_ d: DeviceHubDevice? = nil) -> Task<Void, Never>? {
        guard let d = d ?? selected, canShutDown(d) else { return nil }
        let task = Task { [weak self] in
            await self?.shutDown(d)?.value
            guard let self else { return }
            // The launcher saves the device before it exits: wait for the host to say it stopped.
            for _ in 0..<60 {
                if let now = self.devices.first(where: { $0.id == d.id }), now.isStopped { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.refresh()?.value
            }
            guard let again = self.devices.first(where: { $0.id == d.id }) else { return }
            await self.start(again)?.value
        }
        lifecycleTask = task
        return task
    }

    private func run(_ d: DeviceHubDevice, newState: String, failure: String,
                     _ work: @escaping @Sendable () -> (Bool, String)) -> Task<Void, Never> {
        busy.insert(d.id)
        let task = Task { [weak self] in
            let (ok, message) = await Task.detached { work() }.value
            guard let self else { return }
            self.busy.remove(d.id)
            if ok {
                if let i = self.devices.firstIndex(where: { $0.id == d.id }) { self.devices[i].state = newState }
                var m = self.sidebar
                m.devices = self.devices.map(\.hubDevice)
                self.sidebar = m
            } else {
                self.showBanner("\(failure): \(message)", seconds: 5)
            }
            await self.refresh()?.value
        }
        lifecycleTask = task
        return task
    }

    /// Shows why a device stopped by itself: the host log's last error line.
    func explainStop(_ d: DeviceHubDevice) {
        let backend = backend
        Task { [weak self] in
            let lines = await Task.detached { backend.log(d, lines: 40) }.value
            let message = Self.stopMessage(d.name, log: lines)
            self?.stopReasons[d.id] = message
            self?.showBanner(message, seconds: 8)
        }
    }

    /// "<name> stopped: <the log's last error>" (else its last line).
    public static func stopMessage(_ name: String, log: [String]) -> String {
        let lines = log.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let why = lines.last { l in ["cannot", "error", "failed", "denied"].contains { l.localizedCaseInsensitiveContains($0) } } ?? lines.last
        return "\(name) stopped" + (why.map { ": \($0)" } ?? ".")
    }

    // MARK: Controls

    /// The canvas's controls, as the macOS hub's (§4.4): Home and Rotate act
    /// on the live screen, Screenshot saves the server's PNG; Record is not
    /// in the Linux IDE yet (the device window's decision, §I.13).
    public func perform(_ c: DeviceCommand) {
        guard let d = selected, let s = screens[d.id], s.isLive else {
            showBanner(selected?.isRunning == true ? "The display isn\u{2019}t live yet." : Self.startFirst, seconds: 3)
            return
        }
        switch c {
        case .home: s.press(.home)
        case .lock: s.press(.lock)
        case .volumeUp: s.press(.volumeUp)
        case .volumeDown: s.press(.volumeDown)
        case .rotateLeft, .rotateRight:
            guard s.canRotate else { showBanner(Self.noRotation, seconds: 3); return }
            s.rotate(left: c == .rotateLeft)
        case .screenshot:
            s.saveScreenshot(name: d.typeName) { [weak self] url in self?.showBanner(url == nil ? "Screenshot Failed" : "Screenshot Saved") }
        case .recordScreen: showBanner(Self.recordUnavailable, seconds: 3)
        default: break
        }
    }

    public static let startFirst = "Start the simulator to use its controls."
    public static let noRotation = "This device doesn\u{2019}t rotate."
    public static let recordUnavailable = "Record Screen is not in this beta"
    public static let noSettingsMessage = "Start the simulator to customize behavior and appearance."
    /// The canvas with no devices: how to get one.
    public static let noDevicesTitle = "No Devices"
    public static let noDevicesMessage = "Set up a Ycode simulator host with \u{201C}ycrun remote setup\u{201D}, pair one with \u{201C}ycode sim remote pair\u{201D}, or set one up from Window \u{25B8} Downloads, "
        + "then create a device by running an app on it."

    public func showBanner(_ text: String, seconds: Double = 2) {
        banner = text
        bannerUntil = Date().addingTimeInterval(seconds)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            self?.expireBanner()
        }
    }

    func expireBanner() {
        if let u = bannerUntil, Date() >= u {
            banner = nil
            bannerUntil = nil
        }
    }

    // MARK: Settings (simulator-features.md §7.1; the macOS hub's cards)

    public var settingsEnabled: Bool { selected.map { $0.state == "running" && screens[$0.id]?.isLive == true } ?? false }

    /// Reads the selected device's settings (`settings` over the stream).
    @discardableResult
    public func refreshSettings() -> Task<Void, Never>? {
        guard settingsTask == nil, let d = selected, let s = screens[d.id] ?? screen(for: d), s.isLive else { return nil }
        let task = Task { [weak self] in
            let reply = await s.command(["settings"])
            guard let self else { return }
            if self.selectedID == d.id { self.settings = DeviceSettingsSnapshot(reply: reply) }
            self.settingsTask = nil
        }
        settingsTask = task
        return task
    }

    /// One settings command (`ui appearance dark`), then the settings read
    /// again; a failure is shown with the reference's title ("Failed to Set Appearance").
    @discardableResult
    public func applySetting(_ words: [String], failureTitle: String) -> Task<Void, Never>? {
        guard let d = selected, let s = screens[d.id], s.isLive else { return nil }
        let task = Task { [weak self] in
            let reply = await s.command(words)
            guard let self else { return }
            self.settingsFailure = reply.hasPrefix("ok") ? nil : (failureTitle, reply.hasPrefix("error: ") ? String(reply.dropFirst(7)) : reply)
            let state = await s.command(["settings"])
            if self.selectedID == d.id { self.settings = DeviceSettingsSnapshot(reply: state) }
            self.settingsTask = nil
        }
        settingsTask = task
        return task
    }

    public func setAppearance(dark: Bool) {
        applySetting(["ui", "appearance", dark ? "dark" : "light"], failureTitle: "Failed to Set Appearance")
    }

    public func setSwitch(_ s: AccessibilitySwitch, on: Bool) {
        applySetting(["accessibility", s.rawValue, on ? "on" : "off"], failureTitle: "Failed to Set \(s.title)")
    }

    // MARK: Info (§6)

    /// The Info rows (label, value): the macOS hub's, with the host.
    public var infoRows: [(String, String)] {
        guard let d = selected else { return [] }
        return [("Name", d.name), ("OS", "\(d.platform) \(d.osVersion)"), ("Model", d.typeName),
                ("State", Self.stateTitle(d.state)), ("Host", d.host), ("Identifier", d.id), ("Available", "Yes")]
    }

    /// The link's state in words.
    public static func stateTitle(_ s: String) -> String {
        switch s {
        case "running": "Booted"
        case "booting": "Booting"
        case "stopping": "Shutting Down"
        case "shutdown": "Shutdown"
        default: s.capitalized
        }
    }

    /// The window's title and subtitle (§2.1): the device and its OS, or
    /// "Devices" / "No Selection".
    public var title: String { selected?.name ?? "Devices" }
    public var subtitle: String {
        guard let d = selected else { return "No Selection" }
        return d.hubDevice.osTitle + " \u{2014} \(ExperimentalNotice.label)"
    }
}
