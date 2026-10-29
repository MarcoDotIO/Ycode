import AppKit
import YcodeDeviceModel
import YcodeDeviceUI
import YcodeSubprocess

/// A device or simulator of the hub's sidebar. See `specs/ide/devices.md`
/// and `specs/ide/device-hub.md`.
public struct DeviceRow: Equatable, Sendable {
    public var name: String
    public var identifier: String
    public var platform: String
    public var osVersion: String
    /// `Booted` / `Shutdown` (simulators); pairing/connection (devices).
    public var state: String
    /// Device type / model.
    public var model: String
    public var isAvailable: Bool
    /// Ycode's remote simulator (the only row Ycode can erase).
    public var isYcodeRemote = false
    /// The device type folds (`foldable.md` §8.3 E1): the row offers the
    /// fold controls.
    public var isFoldable = false
    /// Ycode's device type id (its frame in the hub's canvas; nil: not a
    /// Ycode simulator).
    public var deviceTypeID: String?

    /// Ycode's remote simulator as a Simulators row: "Booted" while a run
    /// uses it, else "Shutdown" (its state is saved between runs).
    public static func ycodeRemote(_ remote: RemoteSimulator, running: Bool) -> DeviceRow {
        let s = remote.settings
        // One row per runtime and device type (run.md §Runtimes and device types).
        return DeviceRow(name: remote.target?.name ?? RemoteSimulator.deviceName, identifier: "\(s.destination):\(remote.remoteDevicePath)",
                         platform: "iOS", osVersion: remote.runtimeVersion ?? "", state: running ? "Booted" : "Shutdown",
                         model: remote.target.map { "\($0.deviceType.name), Ycode Simulator (Linux)" } ?? "Ycode Simulator (Linux)",
                         isAvailable: true, isYcodeRemote: true, isFoldable: remote.isFoldable,
                         deviceTypeID: remote.target?.deviceType.id)
    }
}

public enum DevicesList {
    static let runtimePlatforms = ["iOS": "iOS", "watchOS": "watchOS", "tvOS": "tvOS", "xrOS": "visionOS", "visionOS": "visionOS"]

    /// `xcrun simctl list -j`: devices by runtime; runtime names and model
    /// names come from the `runtimes` and `devicetypes` lists when present.
    public static func simulators(simctlJSON data: Data) -> [DeviceRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var typeNames: [String: String] = [:]
        for t in root["devicetypes"] as? [[String: Any]] ?? [] {
            if let id = t["identifier"] as? String, let n = t["name"] as? String { typeNames[id] = n }
        }
        var versions: [String: String] = [:]
        for r in root["runtimes"] as? [[String: Any]] ?? [] {
            if let id = r["identifier"] as? String, let v = r["version"] as? String { versions[id] = v }
        }
        var out: [DeviceRow] = []
        for (runtime, devices) in byRuntime {
            let tail = runtime.split(separator: ".").last.map(String.init) ?? runtime
            let parts = tail.split(separator: "-").map(String.init)
            guard let first = parts.first, let platform = runtimePlatforms[first] else { continue }
            let version = versions[runtime] ?? parts.dropFirst().joined(separator: ".")
            for d in devices {
                guard let name = d["name"] as? String, let udid = d["udid"] as? String else { continue }
                let type = d["deviceTypeIdentifier"] as? String ?? ""
                out.append(DeviceRow(name: name, identifier: udid, platform: platform, osVersion: version,
                                     state: d["state"] as? String ?? "", model: typeNames[type] ?? type.split(separator: ".").last.map(String.init) ?? "",
                                     isAvailable: d["isAvailable"] as? Bool ?? true))
            }
        }
        // Versions compare numerically ("17.5" before "17.10").
        return out.sorted {
            if $0.platform != $1.platform { return $0.platform < $1.platform }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.osVersion.compare($1.osVersion, options: .numeric) == .orderedAscending
        }
    }

    /// `xcrun devicectl list devices --json-output`: physical devices.
    public static func devices(devicectlJSON data: Data) -> [DeviceRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            guard (hw["reality"] as? String ?? "physical") == "physical", let name = props["name"] as? String else { return nil }
            let pairing = conn["pairingState"] as? String ?? ""
            let tunnel = conn["tunnelState"] as? String ?? ""
            return DeviceRow(name: name, identifier: d["identifier"] as? String ?? hw["udid"] as? String ?? "",
                             platform: hw["platform"] as? String ?? "", osVersion: props["osVersionNumber"] as? String ?? "",
                             state: [pairing, tunnel].filter { !$0.isEmpty }.joined(separator: ", "),
                             model: hw["marketingName"] as? String ?? hw["productType"] as? String ?? "", isAvailable: true)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    #if os(macOS)
    /// Runs the two read-only listing commands.
    public static func load() -> (devices: [DeviceRow], simulators: [DeviceRow]) {
        func run(_ args: [String]) -> Data? {
            MainThreadGuard.blockingCall("xcrun \(args.joined(separator: " "))")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        }
        let sims = run(["simctl", "list", "-j"]).map(simulators(simctlJSON:)) ?? []
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = run(["devicectl", "list", "devices", "--json-output", file.path, "-q"])
        let devs = (try? Data(contentsOf: file)).map(devices(devicectlJSON:)) ?? []
        return (devs, sims)
    }
    #endif
}

/// Device Hub (`specs/ide/device-hub.md` §2.1, §3, §5, §6), opened by
/// Product ▸ Destination ▸ Manage Devices… (⇧⌘2): a sidebar of devices and
/// simulators in Available / Unavailable sections with a search field and
/// the Add Device and Filter menus; a canvas with the selected device's
/// live screen in Ycode's frame, or its status view with Start; an
/// inspector with Settings, Reports and Info. Ycode's remote simulators can
/// be started, shut down, folded, rotated, shown in a compact window and
/// erased; other simulators and devices are listed read-only.
@MainActor
public final class DevicesController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate, DeviceMenuTarget {
    /// The Filter menu's choices in the words of the earlier Devices /
    /// Simulators switch: `devices` = Physical Devices, `simulators` =
    /// Simulators, `all` = All Devices.
    public enum Section: Int { case devices, simulators, all }
    public enum InspectorTab: Int, CaseIterable { case settings, reports, info }
    public enum InfoTab: Int, CaseIterable { case info, apps, profiles }

    public private(set) var devices: [DeviceRow]
    public private(set) var simulators: [DeviceRow]
    public private(set) var selected: DeviceRow?
    /// The sidebar's state (filter, search, sort, collapsed sections).
    public private(set) var sidebarModel = HubSidebarModel()
    public private(set) var inspectorTab: InspectorTab = .settings
    public private(set) var infoTab: InfoTab = .info
    /// Info rows the user hid (Edit Visibility).
    public private(set) var hiddenInfoRows: Set<String> = []
    public private(set) var editingInfoVisibility = false
    /// Where the hub keeps its state (§2.1 Persistence).
    public var defaults: UserDefaults = Preferences.shared.defaults

    let table = NSTableView()
    let searchField = NSSearchField()
    let details = NSStackView()
    public let canvas = DeviceCanvasView(mode: .hub)
    private let sidebarVC = NSViewController()
    private let canvasVC = NSViewController()
    private let inspectorVC = NSViewController()
    private let inspectorContent = FlippedStack()
    private let noResults = NSStackView()
    private var tableRows: [HubSidebarRow] = []
    private var inspectorItem: NSSplitViewItem?
    private var sidebarItem: NSSplitViewItem?
    private var statePoll: Timer?
    private lazy var toolbarController = DeviceHubToolbar(owner: self)

    public init(devices: [DeviceRow], simulators: [DeviceRow]) {
        self.devices = devices
        self.simulators = simulators
        super.init(nibName: nil, bundle: nil)
        rebuildModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The camera setting of Ycode's simulators (DevicesController+Camera.swift):
    /// reads and writes `RemoteSimulatorSettings.camera`. Set by the window.
    public var cameraSetting: (get: () -> String, set: (String) -> Void)?

    // MARK: Rows

    /// Every row, physical devices first, then the simulators in their
    /// list order (Ycode's own last). Ycode decision for the default order
    /// (Q10): the order Ycode lists them; Sort By sorts.
    var allRows: [DeviceRow] { devices + simulators }

    private func hubDevice(_ r: DeviceRow) -> HubDevice {
        let family = r.deviceTypeID.flatMap { DeviceFrameSpec.named(typeID: $0)?.family } ?? HubDevice.family(platform: r.platform, name: r.name)
        let physical = devices.contains { $0.identifier == r.identifier }
        let running = physical ? r.state.contains("connected") && !r.state.contains("disconnected") : r.state == "Booted"
        // A device that is not connected is listed under Unavailable (§5.1).
        let reachable = !physical || !(r.state.contains("disconnected") || r.state.contains("unavailable"))
        return HubDevice(id: r.identifier, name: r.name, platform: r.platform, osVersion: r.osVersion, family: family,
                         isSimulator: !physical, model: r.model, isRunning: running, isAvailable: r.isAvailable && reachable)
    }

    private func rebuildModel() {
        var m = sidebarModel
        m.devices = allRows.map(hubDevice)
        sidebarModel = m
        tableRows = currentRows
    }

    /// The sidebar's rows: the model's sections, in Ycode's order unless Sort By chose one.
    var currentRows: [HubSidebarRow] { sortChosen ? sidebarModel.rows : Self.unsortedRows(sidebarModel) }

    /// The device rows shown (filter and search applied), in sidebar order.
    public var rows: [DeviceRow] {
        currentRows.compactMap { $0.device }.compactMap { d in allRows.first { $0.identifier == d.id } }
    }

    /// The filter as the earlier switch's section.
    public var section: Section {
        switch sidebarModel.filter {
        case .physical: .devices
        case .simulators: .simulators
        case .all: .all
        }
    }

    /// Filter ▸ Physical Devices / Simulators / All Devices.
    public func show(_ s: Section) {
        setFilter(s == .devices ? .physical : s == .simulators ? .simulators : .all)
        select(row: 0)
    }

    public func setFilter(_ f: HubFilter) {
        sidebarModel.filter = f
        defaults.set(f.rawValue, forKey: Self.filterKey)
        reloadSidebar()
    }

    public func setSort(_ s: HubSort?) {
        sidebarModel.sort = s ?? .name
        sortChosen = s != nil
        reloadSidebar()
    }
    private(set) var sortChosen = false

    /// The sidebar's search (§5.1).
    public func setSearch(_ text: String) {
        sidebarModel.search = text
        if searchField.stringValue != text { searchField.stringValue = text }
        reloadSidebar()
    }

    public func toggleSection(_ title: String) {
        sidebarModel.toggle(section: title)
        defaults.set(Array(sidebarModel.collapsed), forKey: Self.collapsedKey)
        reloadSidebar()
    }

    private func reloadSidebar() {
        tableRows = currentRows
        let m = sidebarModel
        guard isViewLoaded else { return }
        table.reloadData()
        noResults.isHidden = !m.showsNoResults
        (noResults.arrangedSubviews.dropFirst().first as? NSTextField)?.stringValue = m.noResultsTitle
        if let sel = selected, let i = tableRows.firstIndex(where: { $0.device?.id == sel.identifier }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    /// The model's rows in the given device order (no sort).
    static func unsortedRows(_ m: HubSidebarModel) -> [HubSidebarRow] {
        let q = m.search.trimmingCharacters(in: .whitespaces)
        let shown = m.devices.filter { m.filter.includes($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        var out: [HubSidebarRow] = []
        for (title, list) in [(HubSidebarModel.available, shown.filter(\.isAvailable)), (HubSidebarModel.unavailable, shown.filter { !$0.isAvailable })]
        where !list.isEmpty {
            let collapsed = m.collapsed.contains(title)
            out.append(.header(title, collapsed: collapsed))
            if !collapsed { out += list.map { .device($0) } }
        }
        return out
    }

    // MARK: Ycode's remote simulators

    /// Adds Ycode's remote simulator to the list (or replaces it).
    public func setYcodeRemote(_ row: DeviceRow?) { setYcodeRemote(rows: row.map { [$0] } ?? []) }

    /// Ycode's remote simulators, one row per runtime and device type (or
    /// replaces them); a selected one stays selected when it is still listed.
    public func setYcodeRemote(rows newRows: [DeviceRow]) {
        // A device that is not running starts closed when it boots (§7).
        for r in newRows where r.state != "Booted" { hingeAngles[r.identifier] = nil }
        simulators.removeAll { $0.isYcodeRemote }
        simulators.append(contentsOf: newRows)
        rebuildModel()
        reloadSidebar()
        if let sel = selected, sel.isYcodeRemote {
            selected = newRows.first { $0.identifier == sel.identifier } ?? newRows.first
            if isViewLoaded { showDetails() }
        }
    }

    /// Replaces one remote row (same identifier).
    public func updateYcodeRemote(_ row: DeviceRow) {
        guard let i = simulators.firstIndex(where: { $0.isYcodeRemote && $0.identifier == row.identifier }) else { return }
        if row.state != "Booted" { hingeAngles[row.identifier] = nil }
        let changed = simulators[i].state != row.state
        simulators[i] = row
        rebuildModel()
        reloadSidebar()
        if row.state != "Booted" { closeLink(row.identifier) }
        if selected?.identifier == row.identifier {
            selected = row
            if row.state != "Booted" { settingsSnapshot = nil } else if settingsSnapshot == nil, settingsControlsEnabled { refreshSettings() }
            if isViewLoaded, changed { showDetails() } else if isViewLoaded { updateInspector() }
        }
    }

    /// The remote rows as they are now (polled while the window is open:
    /// runs and started devices change the rows' state). Set by the window.
    public var currentRemoteRows: (() -> [DeviceRow])?

    // MARK: Folding Ycode's remote iPhone Duo (`foldable.md` §8.3 E1–E2)

    /// The pose presets in the reference's words (device-hub.md §4.4) and their hinge angles.
    public static let foldPresets: [(title: String, angle: Int)] = DevicePosture.allCases.map { ($0.title, $0.angle) }
    /// Sends a control command to the row's running device: (succeeded,
    /// reply). Set by the window.
    public var foldDevice: ((DeviceRow, [String]) async -> (Bool, String))?
    /// The hinge angle per row, as Ycode last commanded or read it (the
    /// check mark; the guest reports no posture back, E2).
    public private(set) var hingeAngles: [String: Int] = [:]
    /// What the last fold command reported.
    public private(set) var foldStatus: String?
    /// The command in flight (tests await it).
    public private(set) var foldTask: Task<Void, Never>?

    // MARK: Settings of a running Ycode simulator (DevicesController+Settings.swift)

    /// Sends a settings command to the row's device: (succeeded, reply). Set by the window.
    public var deviceSettings: ((DeviceRow, [String]) async -> (Bool, String))?
    /// The selected device's settings as last read (nil: unknown).
    public internal(set) var settingsSnapshot: DeviceSettingsSnapshot?
    /// The location last chosen per row (the guest cannot report it).
    public internal(set) var chosenLocations: [String: String] = [:]
    /// The command or read in flight (tests await it).
    public internal(set) var settingsTask: Task<Void, Never>?
    /// Shows a failure: (title, message). Default: an alert; tests record it.
    public var presentSettingsFailure: (String, String) -> Void = { DevicesController.runSettingsFailureAlert($0, $1) }
    /// The settings pane's width (the inspector less its insets).
    public static var settingsPaneWidth: CGFloat = 360

    /// The pose commands apply to a foldable row only…
    public var foldControlsShown: Bool { selected?.isFoldable == true }
    /// …and work while its device runs.
    public var foldControlsEnabled: Bool { foldControlsShown && selected?.state == "Booted" && foldDevice != nil }

    /// The selected row's hinge angle (nil: unknown).
    public var hingeAngle: Int? { selected.flatMap { hingeAngles[$0.identifier] } }

    /// Folds the selected device: a preset or any angle 0…180 (a sweep).
    @discardableResult
    public func fold(to angle: Int) -> Task<Void, Never>? {
        let a = min(180, max(0, angle))
        return sendFold(["fold", String(a)], angle: a, status: "Folding to \(a)°…")
    }

    /// Rotate Left / Rotate Right: the device's next orientation.
    @discardableResult
    public func rotate(left: Bool) -> Task<Void, Never>? {
        sendFold(["rotate", left ? "left" : "right"], angle: nil, status: left ? "Rotating left…" : "Rotating right…")
    }

    /// Reads the device's fold (its `state`): the check mark follows a
    /// restored device too.
    @discardableResult
    public func refreshFold() -> Task<Void, Never>? {
        guard foldControlsEnabled, let row = selected, let foldDevice, foldTask == nil else { return nil }
        let task = Task { [weak self] in
            let (ok, reply) = await foldDevice(row, ["state"])
            guard let self else { return }
            if ok, let a = RemoteSimulator.hingeAngle(stateReply: reply) { self.hingeAngles[row.identifier] = a }
            self.foldTask = nil
            if self.isViewLoaded, self.selected?.identifier == row.identifier { self.updateInspector() }
        }
        foldTask = task
        return task
    }

    private func sendFold(_ words: [String], angle: Int?, status: String) -> Task<Void, Never>? {
        guard foldControlsEnabled, let row = selected, let foldDevice, foldTask == nil else { return nil }
        foldStatus = status
        if isViewLoaded { updateInspector() }
        let task = Task { [weak self] in
            let (ok, reply) = await foldDevice(row, words)
            guard let self else { return }
            if ok, let angle { self.hingeAngles[row.identifier] = angle }
            self.foldStatus = ok ? (angle.map { "At \($0)°" } ?? "Rotated") : (reply.isEmpty ? "Failed" : reply)
            self.foldTask = nil
            if self.isViewLoaded { self.updateInspector() }
        }
        foldTask = task
        return task
    }

    @objc func foldPresetChosen(_ sender: Any?) {
        let index = (sender as? NSSegmentedControl)?.selectedSegment ?? (sender as? NSMenuItem)?.tag ?? -1
        guard Self.foldPresets.indices.contains(index) else { return }
        fold(to: Self.foldPresets[index].angle)
    }
    @objc func rotateLeftChosen(_ sender: Any?) { rotate(left: true) }
    @objc func rotateRightChosen(_ sender: Any?) { rotate(left: false) }

    // MARK: Start, Shut Down, Restart (§4.1, §7; Ycode's remote simulators)

    /// Starts a stopped device: (succeeded, message). Set by the window.
    public var startDevice: ((DeviceRow) async -> (Bool, String))?
    /// Shuts a running device down (force: no save). Set by the window.
    public var shutDownDevice: ((DeviceRow, Bool) async -> (Bool, String))?
    /// The live display of a running device (nil: none). Set by the window.
    public var makeDisplayLink: ((DeviceRow) -> RemoteDisplayLink?)?
    /// Devices being started or shut down (the canvas shows a spinner).
    public private(set) var busyDevices: Set<String> = []
    public private(set) var lifecycleTask: Task<Void, Never>?
    /// Each running device's display (shared by the canvas and its compact window).
    public private(set) var links: [String: RemoteDisplayLink] = [:]
    /// The compact windows, by device.
    public private(set) var compactWindows: [String: DeviceWindowController] = [:]

    func canStart(_ r: DeviceRow) -> Bool { r.isYcodeRemote && r.state != "Booted" && startDevice != nil && !busyDevices.contains(r.identifier) }
    func canShutDown(_ r: DeviceRow) -> Bool { r.isYcodeRemote && r.state == "Booted" && shutDownDevice != nil && !busyDevices.contains(r.identifier) }

    /// Device ▸ Start (the status view's Start).
    @discardableResult
    public func start(_ r: DeviceRow) -> Task<Void, Never>? {
        guard canStart(r), let startDevice else { return nil }
        busyDevices.insert(r.identifier)
        refreshCanvas()
        let task = Task { [weak self] in
            let (ok, message) = await startDevice(r)
            guard let self else { return }
            self.busyDevices.remove(r.identifier)
            if ok {
                var b = r
                b.state = "Booted"
                self.updateYcodeRemote(b)
            } else {
                self.canvas.showBanner(message, seconds: 4)
            }
            self.lifecycleTask = nil
            self.refreshCanvas()
        }
        lifecycleTask = task
        return task
    }

    /// Device ▸ Shut Down / Force Shut Down.
    @discardableResult
    public func shutDown(_ r: DeviceRow, force: Bool = false) -> Task<Void, Never>? {
        guard canShutDown(r), let shutDownDevice else { return nil }
        busyDevices.insert(r.identifier)
        refreshCanvas()
        let task = Task { [weak self] in
            let (ok, message) = await shutDownDevice(r, force)
            guard let self else { return }
            self.busyDevices.remove(r.identifier)
            if ok {
                var b = r
                b.state = "Shutdown"
                self.updateYcodeRemote(b)
            } else {
                self.canvas.showBanner(message, seconds: 4)
            }
            self.lifecycleTask = nil
            self.refreshCanvas()
        }
        lifecycleTask = task
        return task
    }

    /// Device ▸ Restart: Shut Down, then Start.
    @discardableResult
    public func restart(_ r: DeviceRow) -> Task<Void, Never>? {
        guard canShutDown(r) else { return nil }
        let task = Task { [weak self] in
            await self?.shutDown(r)?.value
            guard let self, let again = self.allRows.first(where: { $0.identifier == r.identifier }) else { return }
            await self.start(again)?.value
        }
        return task
    }

    /// The display link of a running row (made on demand).
    func link(for r: DeviceRow) -> RemoteDisplayLink? {
        guard r.state == "Booted" else { return nil }
        if let l = links[r.identifier] { return l }
        guard let l = makeDisplayLink?(r) else { return nil }
        links[r.identifier] = l
        return l
    }

    func closeLink(_ id: String) {
        compactWindows[id]?.close()
        compactWindows[id] = nil
        links.removeValue(forKey: id)?.close()
    }

    /// Open in New Window (§2.2): the device's compact window (one per
    /// device; a second request brings it forward). It shows the same live
    /// display as the canvas.
    @discardableResult
    public func openInNewWindow(_ r: DeviceRow? = nil) -> DeviceWindowController? {
        guard let r = r ?? selected, let l = link(for: r) else { NSSound.beep(); return nil }
        if let w = compactWindows[r.identifier] { w.window?.makeKeyAndOrderFront(nil); return w }
        let w = DeviceWindowController(session: l.session, kind: .compact)
        w.defaults = defaults
        w.handlesKeyEquivalents = true
        w.onExpand = { [weak self, weak w] in
            // Expand (Q5, Ycode decision): the hub comes forward with the
            // device selected and the compact window closes.
            guard let self else { return }
            if let i = self.rows.firstIndex(where: { $0.identifier == r.identifier }) { self.select(row: i) }
            self.view.window?.makeKeyAndOrderFront(nil)
            w?.close()
        }
        w.extraMoreItems = { [weak self] in self?.lifecycleItems(for: r) ?? [] }
        w.onClose = { [weak self] in self?.compactWindows[r.identifier] = nil }
        compactWindows[r.identifier] = w
        w.present()
        return w
    }

    @objc func openInNewWindowChosen(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let id = item.representedObject as? String, let r = allRows.first(where: { $0.identifier == id }) {
            openInNewWindow(r)
        } else {
            openInNewWindow()
        }
    }

    // MARK: Context menu (Q6, Ycode decision)

    /// The context menu of a row (§5.2): Start or Shut Down and Restart,
    /// Open in New Window, the iPhone Duo's poses and Rotate Left / Right,
    /// and Erase All Content and Settings… for Ycode's simulators; nothing
    /// for others (Ycode cannot operate them).
    public func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        guard rows.indices.contains(row), rows[row].isYcodeRemote else { return menu }
        menu.autoenablesItems = false
        let r = rows[row]
        for i in lifecycleItems(for: r) { menu.addItem(i) }
        let open = NSMenuItem(title: "Open in New Window", action: #selector(openInNewWindowChosen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = r.identifier
        open.isEnabled = r.state == "Booted" && makeDisplayLink != nil
        menu.addItem(open)
        menu.addItem(.separator())
        if r.isFoldable {
            let on = r.state == "Booted" && foldDevice != nil && foldTask == nil && selected?.identifier == r.identifier
            let current = hingeAngles[r.identifier]
            for (i, p) in Self.foldPresets.enumerated() {
                let f = NSMenuItem(title: p.title, action: #selector(foldPresetChosen(_:)), keyEquivalent: "")
                f.target = self
                f.tag = i
                f.state = current == p.angle ? .on : .off
                f.isEnabled = on
                menu.addItem(f)
            }
            for (title, action) in [("Rotate Left", #selector(rotateLeftChosen(_:))), ("Rotate Right", #selector(rotateRightChosen(_:)))] {
                let x = NSMenuItem(title: title, action: action, keyEquivalent: "")
                x.target = self
                x.isEnabled = on
                menu.addItem(x)
            }
            menu.addItem(.separator())
        }
        let item = NSMenuItem(title: Self.eraseTitle, action: #selector(eraseChosen(_:)), keyEquivalent: "")
        item.target = self
        item.tag = row
        item.isEnabled = eraseTask == nil && eraseDevice != nil
        menu.addItem(item)
        return menu
    }

    /// Start (or Shut Down and Restart) for a row, and Force Shut Down.
    func lifecycleItems(for r: DeviceRow) -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = r.identifier
            i.isEnabled = enabled
            return i
        }
        guard r.isYcodeRemote else { return [] }
        if r.state == "Booted" {
            return [item("Shut Down", #selector(shutDownChosen(_:)), enabled: canShutDown(r)),
                    item("Restart", #selector(restartChosen(_:)), enabled: canShutDown(r)),
                    item("Force Shut Down", #selector(forceShutDownChosen(_:)), enabled: canShutDown(r)), .separator()]
        }
        return [item("Start", #selector(startChosen(_:)), enabled: canStart(r)), .separator()]
    }

    private func row(from sender: Any?) -> DeviceRow? {
        if let id = (sender as? NSMenuItem)?.representedObject as? String { return allRows.first { $0.identifier == id } }
        return selected
    }
    @objc func startChosen(_ sender: Any?) { if let r = row(from: sender) { start(r) } }
    @objc func shutDownChosen(_ sender: Any?) { if let r = row(from: sender) { shutDown(r) } }
    @objc func forceShutDownChosen(_ sender: Any?) { if let r = row(from: sender) { shutDown(r, force: true) } }
    @objc func restartChosen(_ sender: Any?) { if let r = row(from: sender) { restart(r) } }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let clicked = table.clickedRow
        guard tableRows.indices.contains(clicked), let d = tableRows[clicked].device,
              let i = rows.firstIndex(where: { $0.identifier == d.id }) else { return }
        // The fold commands act on the selected row: the clicked one.
        if selected?.identifier != d.id { select(row: i) }
        for item in contextMenu(forRow: i).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: Erasing Ycode's remote simulator

    public static let eraseTitle = "Erase All Content and Settings…"
    /// Asks before erasing (default: an alert). Tests answer it.
    public var confirmErase: (DeviceRow) -> Bool = { DevicesController.runEraseAlert($0) }
    /// Erases the row's device: (succeeded, message). Set by the window.
    public var eraseDevice: ((DeviceRow) async -> (Bool, String))?
    /// What the last erase reported ("Erasing…", "Erased", the error).
    public private(set) var eraseStatus: String?
    /// The erase in flight (tests await it).
    public private(set) var eraseTask: Task<Void, Never>?

    @objc func eraseChosen(_ item: NSMenuItem) { erase(row: item.tag) }

    /// Erases a row's device after the confirmation.
    @discardableResult
    public func erase(row: Int) -> Task<Void, Never>? {
        guard eraseTask == nil, rows.indices.contains(row), rows[row].isYcodeRemote, let eraseDevice else { return nil }
        let d = rows[row]
        guard confirmErase(d) else { return nil }
        setEraseStatus("Erasing…")
        let task = Task { [weak self] in
            let (ok, message) = await eraseDevice(d)
            guard let self else { return }
            self.setEraseStatus(ok ? "Erased" : message)
            self.eraseTask = nil
        }
        eraseTask = task
        return task
    }

    private func setEraseStatus(_ s: String) {
        eraseStatus = s
        if isViewLoaded, selected?.isYcodeRemote == true { updateInspector() }
    }

    /// The confirmation: an alert with Erase and Cancel.
    static func runEraseAlert(_ d: DeviceRow) -> Bool {
        let a = NSAlert()
        a.messageText = "Are you sure you want to erase “\(d.name)”?"
        a.informativeText = "All of its apps, their data and its settings will be deleted, and its saved state will be discarded. The next run starts a new device. You can’t undo this action."
        a.addButton(withTitle: "Erase")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: Views

    public override func loadView() {
        super.loadView()
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
    }

    private var placedDividers = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        // FEAT-IMPL's settings boxes fit the inspector (280 less its insets).
        Self.settingsPaneWidth = 256
        splitView.dividerStyle = .thin
        sidebarVC.view = makeSidebar()
        canvasVC.view = makeCanvas()
        inspectorVC.view = makeInspector()
        let side = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        side.minimumThickness = 200
        side.maximumThickness = 360
        side.canCollapse = true
        let center = NSSplitViewItem(viewController: canvasVC)
        center.minimumThickness = 320
        let inspector: NSSplitViewItem
        if #available(macOS 14.0, *) { inspector = NSSplitViewItem(inspectorWithViewController: inspectorVC) } else {
            inspector = NSSplitViewItem(viewController: inspectorVC)
        }
        inspector.minimumThickness = 280
        inspector.maximumThickness = 420
        inspector.canCollapse = true
        for i in [side, center, inspector] { addSplitViewItem(i) }
        sidebarItem = side
        inspectorItem = inspector
        reloadSidebar()
        if selected == nil { select(row: 0) } else { showDetails() }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        // The sidebar 240 wide and the inspector 280 (§2.1) the first time
        // (afterwards the saved widths).
        let saved = splitView.autosaveName.map { UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil } ?? false
        if !saved, !placedDividers {
            placedDividers = true
            splitView.setPosition(240, ofDividerAt: 0)
            splitView.setPosition(max(520, view.bounds.width - 280), ofDividerAt: 1)
        }
        statePoll?.invalidate()
        statePoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollRemoteRows() } }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        statePoll?.invalidate()
        statePoll = nil
    }

    /// The remote rows' state follows runs and started devices.
    func pollRemoteRows() {
        // A device that was booting when it was selected: its settings and
        // fold are read once its display is live.
        if let r = selected, r.state == "Booted", links[r.identifier]?.session.isLive == true {
            if settingsSnapshot == nil, settingsTask == nil, settingsControlsEnabled { refreshSettings() }
            if foldControlsEnabled, hingeAngles[r.identifier] == nil, foldTask == nil { refreshFold() }
        }
        guard let now = currentRemoteRows?() else { return }
        for r in now {
            guard let old = simulators.first(where: { $0.isYcodeRemote && $0.identifier == r.identifier }),
                  old.state != r.state, !busyDevices.contains(r.identifier) else { continue }
            updateYcodeRemote(r)
        }
    }

    private func makeSidebar() -> NSView {
        let root = NSView()
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        let c = NSTableColumn(identifier: .init("d"))
        table.addTableColumn(c)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.target = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Devices")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glass.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        glass.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        let msg = NSTextField(wrappingLabelWithString: HubSidebarModel.noResultsMessage)
        msg.textColor = .secondaryLabelColor
        msg.alignment = .center
        for v in [glass, title, msg] { noResults.addArrangedSubview(v) }
        noResults.orientation = .vertical
        noResults.spacing = 6
        noResults.isHidden = true
        for v in [searchField, scroll, noResults] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            noResults.centerXAnchor.constraint(equalTo: root.centerXAnchor), noResults.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            noResults.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
        ])
        return root
    }

    private func makeCanvas() -> NSView {
        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        canvas.handlesKeyEquivalents = true
        canvas.showsBezels = defaults.object(forKey: Self.bezelsKey) as? Bool ?? true
        if let z = defaults.string(forKey: Self.zoomKey).flatMap(DeviceZoomMode.init(storedValue:)) { canvas.zoom = z }
        canvas.onAction = { [weak self] in if let r = self?.selected { self?.start(r) } }
        canvas.onZoomChange = { [weak self] in
            guard let self else { return }
            self.defaults.set(self.canvas.zoom.storedValue, forKey: Self.zoomKey)
            self.toolbarController.updateZoom()
        }
        canvas.onCaptureChange = { [weak self] on in self?.toolbarController.updateCapture(on) }
        canvas.commandFallback = { [weak self] c in self?.performWithoutDisplay(c) ?? false }
        return root
    }

    /// Commands that work without a live display: the fold and rotation of
    /// a running Ycode simulator go through its control socket (ssh).
    func performWithoutDisplay(_ c: DeviceCommand) -> Bool {
        switch c {
        case .poseClosed: return fold(to: 0) != nil
        case .posePartiallyOpen: return fold(to: 90) != nil
        case .poseOpen: return fold(to: 180) != nil
        case .rotateLeft: return rotate(left: true) != nil
        case .rotateRight: return rotate(left: false) != nil
        default: return false
        }
    }

    private func makeInspector() -> NSView {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = inspectorContent
        inspectorContent.orientation = .vertical
        inspectorContent.alignment = .leading
        inspectorContent.spacing = 10
        inspectorContent.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        inspectorContent.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspectorContent.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            inspectorContent.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            inspectorContent.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 0
        return root
    }

    // MARK: Selection

    public func select(row: Int) {
        selected = rows.indices.contains(row) ? rows[row] : nil
        multipleSelection = []
        foldStatus = nil
        if foldControlsEnabled, let d = selected, hingeAngles[d.identifier] == nil { refreshFold() }
        settingsSnapshot = nil
        if settingsControlsEnabled { refreshSettings() }
        if let s = selected { defaults.set(s.identifier, forKey: Self.selectionKey) }
        guard isViewLoaded else { return }
        if let s = selected, let i = tableRows.firstIndex(where: { $0.device?.id == s.identifier }), !table.selectedRowIndexes.contains(i) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        showDetails()
    }

    /// Several rows selected (the canvas says so; double-click opens a
    /// compact window for each).
    public private(set) var multipleSelection: [DeviceRow] = []

    /// Refreshes everything that shows the selection.
    func showDetails() {
        updateInspector()
        refreshCanvas()
        updateWindowTitle()
        toolbarController.update()
    }

    /// The canvas for the selection (§4.1).
    func refreshCanvas() {
        guard isViewLoaded else { return }
        if multipleSelection.count > 1 { canvas.showMessage("Multiple Devices Selected"); return }
        guard let r = selected else { canvas.showMessage("No Selection"); return }
        let d = hubDevice(r)
        let spec = r.deviceTypeID.flatMap(DeviceFrameSpec.named(typeID:))
            ?? DeviceFrameSpec.matching(pixelWidth: d.family == .pad ? 1640 : 1206, pixelHeight: d.family == .pad ? 2360 : 2622,
                                        scale: d.family == .pad ? 2 : 3)
        if busyDevices.contains(r.identifier) {
            canvas.showStopped(spec: spec, name: r.name, os: d.osTitle, action: nil, busy: true)
        } else if r.isYcodeRemote, r.state == "Booted", let l = link(for: r) {
            canvas.show(session: l.session)
        } else if r.isYcodeRemote {
            canvas.showStopped(spec: spec, name: r.name, os: d.osTitle, action: r.state == "Booted" ? nil : "Start")
        } else {
            // Other simulators and devices: listed only (Ycode does not operate them).
            canvas.showStopped(spec: spec, name: r.name, os: d.osTitle, action: nil)
        }
    }

    func updateWindowTitle() {
        guard let w = view.window else { return }
        if let r = selected, multipleSelection.count <= 1 {
            w.title = r.name
            w.subtitle = hubDevice(r).osTitle
        } else {
            w.title = "Devices"
            w.subtitle = "No Selection"
        }
    }

    // MARK: Inspector (§6)

    public func selectInspectorTab(_ t: InspectorTab) {
        inspectorTab = t
        defaults.set(t.rawValue, forKey: Self.tabKey)
        if inspectorItem?.isCollapsed == true { inspectorItem?.animator().isCollapsed = false }
        updateInspector()
        toolbarController.updateTabs()
    }

    public func selectInfoTab(_ t: InfoTab) {
        infoTab = t
        defaults.set(t.rawValue, forKey: Self.infoTabKey)
        updateInspector()
    }

    /// The Info rows (label, value), the hidden ones left out.
    public var detailRows: [(String, String)] {
        guard let d = selected else { return [("No Selection", "")] }
        let physical = devices.contains { $0.identifier == d.identifier }
        var out = [("Name", d.name), ("OS", "\(d.platform) \(d.osVersion)"), ("Model", d.model),
                   (physical ? "Connection" : "State", d.state), ("Identifier", d.identifier), ("Available", d.isAvailable ? "Yes" : "No")]
        if d.isYcodeRemote, let eraseStatus { out.append(("Erase", eraseStatus)) }
        if d.isFoldable {
            out.append(("Fold", hingeAngle.map { a in "\(a)°" + (Self.foldPresets.first { $0.angle == a }.map { " (\($0.title))" } ?? "") }
                        ?? (d.state == "Booted" ? "Unknown" : "Closed when it boots")))
            if let foldStatus { out.append(("Fold Status", foldStatus)) }
        }
        return out.filter { editingInfoVisibility || !hiddenInfoRows.contains($0.0) }
    }

    /// Rebuilds the inspector's content for the tab.
    func updateInspector() {
        guard isViewLoaded else { return }
        inspectorContent.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch inspectorTab {
        case .settings:
            if let r = selected, r.isYcodeRemote {
                inspectorContent.addArrangedSubview(settingsControls())
                if cameraControlsShown { inspectorContent.addArrangedSubview(cameraControls()) }
            } else {
                let text = selected == nil ? "No Selection"
                    : "No settings are available for the selected device. Ycode changes the settings of its own simulators."
                inspectorContent.addArrangedSubview(Self.secondary(text))
            }
        case .reports:
            inspectorContent.addArrangedSubview(Self.secondary(selected == nil ? "No Selection" : "No Diagnostic Reports"))
        case .info:
            let seg = NSSegmentedControl(labels: ["Info", "Apps", "Profiles"], trackingMode: .selectOne, target: self, action: #selector(infoTabChosen(_:)))
            seg.selectedSegment = infoTab.rawValue
            seg.segmentDistribution = .fillEqually
            seg.translatesAutoresizingMaskIntoConstraints = false
            inspectorContent.addArrangedSubview(seg)
            seg.widthAnchor.constraint(equalTo: inspectorContent.widthAnchor, constant: -24).isActive = true
            switch infoTab {
            case .info: buildInfo()
            case .apps: inspectorContent.addArrangedSubview(Self.secondary(selected == nil ? "No Selection" : "No Apps"))
            case .profiles: inspectorContent.addArrangedSubview(Self.secondary(selected == nil ? "No Selection" : "No Profiles"))
            }
        }
    }

    private func buildInfo() {
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = detailRows
        for (i, (l, v)) in rows.enumerated() {
            let label = NSTextField(labelWithString: l)
            label.font = .systemFont(ofSize: 12)
            let value = NSTextField(labelWithString: v)
            value.isSelectable = true
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [label, value]
            if editingInfoVisibility {
                let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(infoVisibilityToggled(_:)))
                check.state = hiddenInfoRows.contains(l) ? .off : .on
                check.identifier = .init(l)
                views.insert(check, at: 0)
            }
            let row = NSStackView(views: views)
            row.distribution = .fill
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            row.identifier = .init("info-\(l)")
            details.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                details.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: details.widthAnchor, constant: -20).isActive = true
            }
        }
        let group = GroupBoxView(content: details)
        inspectorContent.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: inspectorContent.widthAnchor, constant: -24).isActive = true
        let edit = NSButton(title: editingInfoVisibility ? "Done" : "Edit Visibility", target: self, action: #selector(editVisibility(_:)))
        edit.bezelStyle = .push
        edit.controlSize = .small
        inspectorContent.addArrangedSubview(edit)
        inspectorContent.setCustomSpacing(12, after: group)
        // Centred under the box.
        edit.centerXAnchor.constraint(equalTo: group.centerXAnchor).isActive = true
    }

    static func secondary(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = .secondaryLabelColor
        l.identifier = .init("inspector-message")
        return l
    }

    @objc func infoTabChosen(_ sender: NSSegmentedControl) { selectInfoTab(InfoTab(rawValue: sender.selectedSegment) ?? .info) }

    @objc func editVisibility(_ sender: Any?) {
        editingInfoVisibility.toggle()
        updateInspector()
    }

    @objc func infoVisibilityToggled(_ sender: NSButton) {
        guard let l = sender.identifier?.rawValue else { return }
        if sender.state == .on { hiddenInfoRows.remove(l) } else { hiddenInfoRows.insert(l) }
        defaults.set(Array(hiddenInfoRows), forKey: Self.hiddenInfoKey)
    }

    /// Edit Visibility for tests: hides or shows a row.
    public func setInfoRow(_ label: String, visible: Bool) {
        if visible { hiddenInfoRows.remove(label) } else { hiddenInfoRows.insert(label) }
        defaults.set(Array(hiddenInfoRows), forKey: Self.hiddenInfoKey)
        updateInspector()
    }

    // MARK: Sidebar table

    public func numberOfRows(in t: NSTableView) -> Int { tableRows.count }

    public func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = tableRows[row] { return 28 }
        return 46
    }

    public func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { tableRows[row].device != nil }

    public func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool { false }

    public func tableViewSelectionDidChange(_ n: Notification) {
        let picked = table.selectedRowIndexes.compactMap { tableRows.indices.contains($0) ? tableRows[$0].device : nil }
        let rowsNow = picked.compactMap { d in allRows.first { $0.identifier == d.id } }
        if rowsNow.count > 1 {
            selected = rowsNow.first
            multipleSelection = rowsNow
            showDetails()
            return
        }
        guard let d = rowsNow.first, let i = rows.firstIndex(where: { $0.identifier == d.identifier }) else { return }
        if selected?.identifier != d.identifier || multipleSelection.count > 1 { select(row: i) }
    }

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        switch tableRows[row] {
        case .header(let title, let collapsed):
            let b = NSButton(title: title, target: self, action: #selector(headerClicked(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11, weight: .semibold)
            b.contentTintColor = .secondaryLabelColor
            b.alignment = .left
            b.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            b.imagePosition = .imageTrailing
            b.identifier = .init(title)
            b.setAccessibilityLabel(title)
            let v = NSView()
            b.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(b)
            NSLayoutConstraint.activate([b.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), b.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4)])
            return v
        case .device(let d):
            return DeviceHubRowView(device: d)
        }
    }

    @objc func headerClicked(_ sender: NSButton) { if let t = sender.identifier?.rawValue { toggleSection(t) } }

    @objc func rowDoubleClicked(_ sender: Any?) {
        // Double-click opens a compact window for each selected running device (§2.2).
        let picked = table.selectedRowIndexes.compactMap { tableRows.indices.contains($0) ? tableRows[$0].device : nil }
        for d in picked { if let r = allRows.first(where: { $0.identifier == d.id }), r.state == "Booted" { openInNewWindow(r) } }
    }

    @objc func searchChanged(_ sender: NSSearchField) { setSearch(sender.stringValue) }

    // MARK: DeviceMenuTarget

    public var activeCanvas: DeviceCanvasView? { canvas }

    // MARK: Window and persistence (§2.1)

    static let selectionKey = "Ycode.deviceHub.selection"
    static let tabKey = "Ycode.deviceHub.inspectorTab"
    static let infoTabKey = "Ycode.deviceHub.infoTab"
    static let collapsedKey = "Ycode.deviceHub.collapsedSections"
    static let filterKey = "Ycode.deviceHub.filter"
    static let sidebarKey = "Ycode.deviceHub.sidebarShown"
    static let zoomKey = "Ycode.deviceHub.zoom"
    static let bezelsKey = "Ycode.deviceHub.bezels"
    static let hiddenInfoKey = "Ycode.deviceHub.hiddenInfoRows"

    /// Restores the hub's saved state: filter, collapsed sections, the
    /// inspector tab and sub-tab, hidden Info rows, the selected device.
    public func restoreState() {
        if let f = defaults.string(forKey: Self.filterKey).flatMap(HubFilter.init(rawValue:)) { sidebarModel.filter = f }
        sidebarModel.collapsed = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
        inspectorTab = InspectorTab(rawValue: defaults.integer(forKey: Self.tabKey)) ?? .settings
        infoTab = InfoTab(rawValue: defaults.integer(forKey: Self.infoTabKey)) ?? .info
        hiddenInfoRows = Set(defaults.stringArray(forKey: Self.hiddenInfoKey) ?? [])
        reloadSidebar()
        if let id = defaults.string(forKey: Self.selectionKey), let i = rows.firstIndex(where: { $0.identifier == id }) {
            select(row: i)
        } else {
            select(row: 0)
        }
        if isViewLoaded, defaults.object(forKey: Self.sidebarKey) as? Bool == false { sidebarItem?.isCollapsed = true }
    }

    /// The hub window (§2.1): 1100 × 800 at first, unified toolbar without
    /// background, sidebar and inspector full height, the selected device
    /// as title and its OS as subtitle; frame and split widths kept.
    public func makeWindow() -> NSWindow {
        let w = NSWindow(contentViewController: self)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.titleVisibility = .visible
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }
        w.setContentSize(NSSize(width: 1100, height: 800))
        w.contentMinSize = NSSize(width: 800, height: 500)
        w.isReleasedWhenClosed = false
        w.tabbingIdentifier = "YcodeDeviceHub"
        toolbarController.install(on: w)
        splitView.autosaveName = "YcodeDeviceHub"
        w.setFrameAutosaveName("YcodeDeviceHub")
        updateWindowTitle()
        return w
    }

    /// View ▸ Hide Sidebar / Show Sidebar (§2.1): the window keeps its
    /// width; the canvas takes the space.
    @objc public func toggleHubSidebar(_ sender: Any?) {
        guard let s = sidebarItem else { return }
        s.animator().isCollapsed.toggle()
        defaults.set(!s.isCollapsed, forKey: Self.sidebarKey)
    }

    public var sidebarShown: Bool { sidebarItem?.isCollapsed == false }

    /// Ends the displays (the window closes).
    public func closeLinks() {
        for id in Array(links.keys) where compactWindows[id] == nil { links.removeValue(forKey: id)?.close() }
    }
}

/// The inspector's rounded group box (§6, §8: grouped-form style).
final class GroupBoxView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        identifier = .init("info-box")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }
}

/// A sidebar row (§5.2): a 32-point disc with Ycode's device-class glyph
/// (coloured on white while running, grey on grey otherwise), the name over
/// "Simulator" or the model, and the OS version at the trailing edge.
final class DeviceHubRowView: NSView {
    let device: HubDevice

    init(device d: HubDevice) {
        device = d
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let disc = NSView()
        disc.wantsLayer = true
        disc.layer?.cornerRadius = 16
        disc.layer?.backgroundColor = (d.isRunning ? NSColor.white : NSColor.quaternaryLabelColor).cgColor
        if d.isRunning {
            disc.layer?.borderWidth = 0.5
            disc.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        // Ycode's own glyph (no product symbols, AGENTS.md rule 5): lit while running.
        let glyph = NSImageView(image: DeviceGlyph.of(d.family).image(height: d.family == .vision ? 11 : 18, lit: d.isRunning))
        glyph.contentTintColor = d.isRunning ? .controlAccentColor : .secondaryLabelColor
        let name = NSTextField(labelWithString: d.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(labelWithString: d.subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let version = NSTextField(labelWithString: d.shortVersion)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.setContentHuggingPriority(.required, for: .horizontal)
        version.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [disc, glyph, text, version] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            disc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 32), disc.heightAnchor.constraint(equalToConstant: 32),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 8), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: version.leadingAnchor, constant: -6),
            version.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), version.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel("\(d.name), \(d.subtitle), \(d.osTitle)\(d.isRunning ? ", running" : "")")
        identifier = .init("hub-row-\(d.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
