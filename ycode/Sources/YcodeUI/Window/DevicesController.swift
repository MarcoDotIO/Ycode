import AppKit
import YcodeSubprocess

/// Devices and Simulators: read-only lists. See `specs/ide/devices.md`.
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

    /// Ycode's remote simulator as a Simulators row: "Booted" while a run
    /// uses it, else "Shutdown" (its state is saved between runs).
    public static func ycodeRemote(_ remote: RemoteSimulator, running: Bool) -> DeviceRow {
        let s = remote.settings
        return DeviceRow(name: RemoteSimulator.deviceName, identifier: "\(s.destination):\(remote.remoteDevicePath)", platform: "iOS",
                         osVersion: s.runtimeVersion ?? "", state: running ? "Booted" : "Shutdown", model: "Ycode Simulator (Linux)",
                         isAvailable: true, isYcodeRemote: true)
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

/// Window ▸ Devices and Simulators (⇧⌘2): a Devices / Simulators switch,
/// the list, and the selected entry's details. Read-only, except that
/// Ycode's remote simulator can be erased from its context menu.
@MainActor
public final class DevicesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    public enum Section: Int { case devices, simulators }
    public private(set) var section: Section = .devices
    public private(set) var devices: [DeviceRow]
    public private(set) var simulators: [DeviceRow]
    public private(set) var selected: DeviceRow?
    let switcher = NSSegmentedControl(labels: ["Devices", "Simulators"], trackingMode: .selectOne, target: nil, action: nil)
    let table = NSTableView()
    let details = NSStackView()

    public init(devices: [DeviceRow], simulators: [DeviceRow]) {
        self.devices = devices
        self.simulators = simulators
        super.init(nibName: nil, bundle: nil)
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

    /// Adds Ycode's remote simulator to the Simulators list (or replaces it).
    public func setYcodeRemote(_ row: DeviceRow?) {
        simulators.removeAll { $0.isYcodeRemote }
        if let row { simulators.append(row) }
        if isViewLoaded { table.reloadData() }
        if selected?.isYcodeRemote == true { selected = row; if isViewLoaded { showDetails() } }
    }

    /// The context menu of a row: Erase All Content and Settings… for Ycode's
    /// remote simulator (disabled while an erase runs); nothing for others.
    public func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        guard rows.indices.contains(row), rows[row].isYcodeRemote else { return menu }
        let item = NSMenuItem(title: Self.eraseTitle, action: #selector(eraseChosen(_:)), keyEquivalent: "")
        item.target = self
        item.tag = row
        item.isEnabled = eraseTask == nil && eraseDevice != nil
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for i in contextMenu(forRow: table.clickedRow).items {
            i.menu?.removeItem(i)
            menu.addItem(i)
        }
    }

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
        if isViewLoaded, selected?.isYcodeRemote == true { showDetails() }
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var rows: [DeviceRow] { section == .devices ? devices : simulators }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 820, height: 480))
        switcher.selectedSegment = 0
        switcher.target = self
        switcher.action = #selector(switched)
        let c = NSTableColumn(identifier: .init("d"))
        table.addTableColumn(c)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        details.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        for v in [switcher, scroll, details] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), switcher.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor), scroll.widthAnchor.constraint(equalToConstant: 260),
            details.topAnchor.constraint(equalTo: scroll.topAnchor), details.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
        ])
        view = root
        select(row: 0)
    }

    public func show(_ s: Section) {
        section = s
        if isViewLoaded { switcher.selectedSegment = s.rawValue; table.reloadData() }
        select(row: 0)
    }

    @objc private func switched() { show(Section(rawValue: switcher.selectedSegment) ?? .devices) }

    public func select(row: Int) {
        selected = rows.indices.contains(row) ? rows[row] : nil
        guard isViewLoaded else { return }
        if selected != nil, table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
        showDetails()
    }

    /// The details pane: (label, value).
    public var detailRows: [(String, String)] {
        guard let d = selected else { return [(section == .devices ? "No Devices Connected" : "No Simulators", "")] }
        let rows = [("Name", d.name), ("Model", d.model), ("OS Version", "\(d.platform) \(d.osVersion)"),
                    (section == .devices ? "Connection" : "State", d.state), ("Identifier", d.identifier),
                    ("Available", d.isAvailable ? "Yes" : "No")]
        return rows + (d.isYcodeRemote ? eraseStatus.map { [("Erase", $0)] } ?? [] : [])
    }

    func showDetails() {
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (l, v) in detailRows {
            let label = NSTextField(labelWithString: l)
            label.font = .boldSystemFont(ofSize: 11)
            details.addArrangedSubview(label)
            if !v.isEmpty {
                let value = NSTextField(labelWithString: v)
                value.isSelectable = true
                details.addArrangedSubview(value)
            }
        }
    }

    public func numberOfRows(in t: NSTableView) -> Int { rows.count }

    public func tableViewSelectionDidChange(_ n: Notification) {
        if table.selectedRow >= 0 { select(row: table.selectedRow) }
    }

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let d = rows[row]
        let title = NSTextField(labelWithString: d.name)
        title.font = .systemFont(ofSize: 12)
        let sub = NSTextField(labelWithString: "\(d.platform) \(d.osVersion)\(d.state.isEmpty ? "" : " · \(d.state)")")
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        let s = NSStackView(views: [title, sub])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 1
        return s
    }
}
