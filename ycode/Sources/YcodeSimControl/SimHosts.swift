// The simulator hosts ycrun knows (specs/ide/ycrun.md §5). The default
// remote host is the one the IDEs use: its settings are the IDE's own
// defaults (`Ycode.remote.*`, Settings ▸ Components ▸ Simulator Host, and
// `Ycode.runtimeSetup.choices`), in the IDE's defaults domain, so a host set
// up with `ycrun remote setup` is the macOS IDE's run destination and Device
// Hub's, and the devices `ycrun simctl create` makes are Device Hub's created
// devices. More hosts, and this machine's own settings, are kept in
// `~/.config/ycode/ycrun/hosts.json`.

import Foundation
import YcodeIDECore

/// One host's settings.
public struct SimHostEntry: Codable, Equatable, Sendable {
    /// Its name for `--host` ("local" for this machine).
    public var name: String
    /// `user@host`; empty: this machine.
    public var destination: String
    /// Ycode's data folder there (`$YCODE_DATA`): runtimes, devices, apps, run files.
    public var dataDirectory: String
    public var runtimeRoot: String
    public var otherRuntimeRoots: [String] = []
    /// The host-side launcher (`<data>/bin/ycode-sim`, scripts/ycode-sim.sh).
    public var launcher: String
    public var deviceName = "ycode-device"
    public var runtimeVersions: [String: String] = [:]
    public var runtimePlatforms: [String: String] = [:]
    /// Devices made with `ycrun simctl create` (the IDE's host keeps them in the IDE's defaults).
    public var createdDevices: [RemoteCreatedDevice] = []
    /// Where the setup wrote `simhost.env` (empty: `~/.config/ycode`).
    public var configDirectory = ""

    public init(name: String, destination: String, dataDirectory: String, runtimeRoot: String = "", launcher: String = "") {
        self.name = name
        self.destination = destination
        self.dataDirectory = dataDirectory
        self.runtimeRoot = runtimeRoot
        self.launcher = launcher.isEmpty ? dataDirectory + "/bin/ycode-sim" : launcher
    }

    enum CodingKeys: String, CodingKey {
        case name, destination, dataDirectory, runtimeRoot, otherRuntimeRoots, launcher, deviceName, runtimeVersions, runtimePlatforms, createdDevices, configDirectory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        dataDirectory = try c.decodeIfPresent(String.self, forKey: .dataDirectory) ?? ""
        runtimeRoot = try c.decodeIfPresent(String.self, forKey: .runtimeRoot) ?? ""
        otherRuntimeRoots = try c.decodeIfPresent([String].self, forKey: .otherRuntimeRoots) ?? []
        launcher = try c.decodeIfPresent(String.self, forKey: .launcher) ?? dataDirectory + "/bin/ycode-sim"
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "ycode-device"
        runtimeVersions = try c.decodeIfPresent([String: String].self, forKey: .runtimeVersions) ?? [:]
        runtimePlatforms = try c.decodeIfPresent([String: String].self, forKey: .runtimePlatforms) ?? [:]
        createdDevices = try c.decodeIfPresent([RemoteCreatedDevice].self, forKey: .createdDevices) ?? []
        configDirectory = try c.decodeIfPresent(String.self, forKey: .configDirectory) ?? ""
    }

    public var isLocal: Bool { destination.isEmpty }

    /// Two hosts are the same when they log in to the same place and use the
    /// same data folder (one machine may serve two data folders).
    public func isSameHost(as o: SimHostEntry) -> Bool {
        isLocal ? o.isLocal : (!o.isLocal && destination == o.destination && dataDirectory == o.dataDirectory)
    }

    /// "user@sim-host" → "sim-host".
    public static func hostName(of destination: String) -> String {
        RuntimeHostSettings(destination: destination).hostName
    }

    /// The run settings the IDE's simulator code takes (device directories,
    /// runtime targets, launcher commands).
    public var remoteSettings: RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings(destination: destination, dataDirectory: dataDirectory, runtimeRoot: runtimeRoot,
                                        simdPath: launcher, deviceName: deviceName)
        s.otherRuntimeRoots = otherRuntimeRoots
        s.runtimeVersions = runtimeVersions
        s.runtimePlatforms = runtimePlatforms
        s.createdDevices = createdDevices
        s.runtimeVersion = runtimeVersions[runtimeRoot] ?? RemoteSimulatorSettings.version(inPath: runtimeRoot)
        return s
    }
}

/// The hosts file and the IDE's defaults.
public struct SimHostStore: @unchecked Sendable {
    /// The IDE's defaults (the macOS app's domain, or the Linux IDE's).
    public var ide: UserDefaults
    /// `~/.config/ycode/ycrun/hosts.json`.
    public var file: URL
    public var environment: [String: String]

    public init(ide: UserDefaults, file: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.ide = ide
        self.file = file
        self.environment = environment
    }

    /// The IDE's defaults domain: `$YCODE_DEFAULTS_DOMAIN`, else the macOS
    /// app's bundle identifier, else the Linux IDE's (`ycode-ide`, whose
    /// defaults are `~/.config/ycode-ide.plist`; inside the Flatpak, its own
    /// configuration folder, which ycrun shares when it runs there too).
    public static func ideDomain(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let d = environment["YCODE_DEFAULTS_DOMAIN"], !d.isEmpty { return d }
        #if os(macOS)
        return "io.github.MarcoDotIO.Ycode"
        #else
        return "ycode-ide"
        #endif
    }

    /// `$YCRUN_CONFIG_DIR`, else `$XDG_CONFIG_HOME/ycode/ycrun`, else `~/.config/ycode/ycrun`.
    public static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let d = environment["YCRUN_CONFIG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: base).appendingPathComponent("ycode/ycrun")
    }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> SimHostStore {
        let domain = ideDomain(environment: environment)
        return SimHostStore(ide: UserDefaults(suiteName: domain) ?? .standard,
                            file: configDirectory(environment: environment).appendingPathComponent("hosts.json"), environment: environment)
    }

    // MARK: The file

    struct FileContents: Codable { var hosts: [SimHostEntry] }

    public func fileEntries() -> [SimHostEntry] {
        guard let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(FileContents.self, from: d) else { return [] }
        return c.hosts
    }

    public func saveFileEntries(_ hosts: [SimHostEntry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(FileContents(hosts: hosts)).write(to: file, options: .atomic)
    }

    // MARK: The IDE's host

    /// The IDE's simulator host settings (empty destination: none).
    public var ideSettings: RemoteSimulatorSettings { RemoteSimulatorSettings.load(ide) }

    /// The IDE's host as an entry (nil when the IDE names none). Its name is
    /// the file's entry for the same destination, else the host's name.
    public func ideEntry() -> SimHostEntry? {
        let s = ideSettings
        guard !s.destination.isEmpty else { return nil }
        let named = fileEntries().first { $0.destination == s.destination && $0.dataDirectory == s.dataDirectory }
        var e = SimHostEntry(name: named?.name ?? SimHostEntry.hostName(of: s.destination), destination: s.destination,
                             dataDirectory: s.dataDirectory, runtimeRoot: s.runtimeRoot, launcher: s.simdPath)
        e.otherRuntimeRoots = s.otherRuntimeRoots
        e.deviceName = s.deviceName
        e.runtimeVersions = s.runtimeVersions
        e.runtimePlatforms = s.runtimePlatforms
        e.createdDevices = s.createdDevices
        e.configDirectory = RuntimeSetupChoices.load(ide).host.configDirectory
        return e
    }

    /// Every remote host: the IDE's first (the default), then the file's others.
    public func remoteHosts() -> [SimHostEntry] {
        let ideHost = ideEntry()
        let others = fileEntries().filter { e in !e.isLocal && !(ideHost.map { e.isSameHost(as: $0) } ?? false) }
        return (ideHost.map { [$0] } ?? []) + others
    }

    /// A remote host by name or destination; nil name: the default.
    public func remoteHost(named name: String?) -> SimHostEntry? {
        let all = remoteHosts()
        guard let name else { return all.first }
        return all.first { $0.name == name || $0.destination == name || SimHostEntry.hostName(of: $0.destination) == name }
    }

    /// This machine's settings: the file's "local" entry, else from the
    /// environment (`$YCODE_DATA`, else `~/.local/share/ycode`; the launcher
    /// `$YCODE_SIM_LAUNCHER`, else `<data>/bin/ycode-sim`; the runtime
    /// `$YCODE_SIM_RUNTIME`, else found in `<data>/runtimes` when used).
    public func localHost() -> SimHostEntry {
        if let e = fileEntries().first(where: \.isLocal) { return e }
        let data = environment["YCODE_DATA"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/share/ycode"
        var e = SimHostEntry(name: "local", destination: "", dataDirectory: data, runtimeRoot: environment["YCODE_SIM_RUNTIME"] ?? "",
                             launcher: environment["YCODE_SIM_LAUNCHER"] ?? "")
        e.name = "local"
        return e
    }

    /// Whether this entry's settings live in the IDE's defaults.
    public func isIDEHost(_ e: SimHostEntry) -> Bool {
        let s = ideSettings
        return !e.isLocal && e.destination == s.destination && e.dataDirectory == s.dataDirectory
    }

    /// The run settings of a host: the IDE's own (with its boot options) for its host.
    public func settings(for e: SimHostEntry) -> RemoteSimulatorSettings {
        isIDEHost(e) ? ideSettings : e.remoteSettings
    }

    // MARK: Writing

    /// Two entries for the same host: the same name, both this machine, or the same ssh destination.
    static func same(_ a: SimHostEntry, _ b: SimHostEntry) -> Bool {
        a.name == b.name || a.isSameHost(as: b)
    }

    /// Saves a host: into the file (replacing one of the same name or
    /// destination), and, when `makeDefault` or it is the IDE's host, into
    /// the IDE's defaults (`Ycode.remote.*` and the setup wizard's host).
    public func save(_ e: SimHostEntry, makeDefault: Bool = false, tcpPort: Int? = nil, udpPort: Int? = nil) throws {
        let previous = fileEntries().first { Self.same($0, e) }
        var all = fileEntries().filter { !Self.same($0, e) }
        var stored = e
        // Setting a host up again keeps the devices made on it.
        if let previous, previous.isSameHost(as: e) {
            stored.createdDevices = previous.createdDevices + e.createdDevices.filter { c in !previous.createdDevices.contains { $0.directoryName == c.directoryName } }
        }
        if !e.isLocal && (makeDefault || isIDEHost(e)) {
            writeIDE(e, tcpPort: tcpPort, udpPort: udpPort)
            stored.createdDevices = []   // the IDE's defaults keep them
        }
        all.append(stored)
        try saveFileEntries(all)
    }

    /// The IDE's settings for a host (the run settings and the wizard's host).
    public func writeIDE(_ e: SimHostEntry, tcpPort: Int? = nil, udpPort: Int? = nil) {
        var s = RemoteSimulatorSettings.load(ide)
        let sameHost = s.destination == e.destination && s.dataDirectory == e.dataDirectory
        s.destination = e.destination
        s.dataDirectory = e.dataDirectory
        s.runtimeRoot = e.runtimeRoot
        s.otherRuntimeRoots = e.otherRuntimeRoots
        s.simdPath = e.launcher
        s.deviceName = e.deviceName
        s.save(ide)
        for (root, v) in e.runtimeVersions { RemoteSimulatorSettings.saveRuntimeVersion(v, root: root, ide, primary: root == e.runtimeRoot) }
        for (root, p) in e.runtimePlatforms { RemoteSimulatorSettings.saveRuntimePlatform(p, root: root, ide) }
        if !sameHost || !e.createdDevices.isEmpty {
            let keep = sameHost ? RemoteSimulatorSettings.createdDevices(ide) : []
            let merged = keep + e.createdDevices.filter { c in !keep.contains { $0.directoryName == c.directoryName } }
            RemoteSimulatorSettings.saveCreatedDevices(merged, ide)
        }
        var c = RuntimeSetupChoices.load(ide)
        c.useHost = true
        c.host.destination = e.destination
        c.host.dataDirectory = e.dataDirectory
        c.host.configDirectory = e.configDirectory
        if let tcpPort, let udpPort { (c.host.tcpPort, c.host.udpPort) = (tcpPort, udpPort) }
        c.save(ide)
        ide.synchronize()
    }

    /// Removes a host from the file, and from the IDE's settings when it is
    /// the IDE's (its run settings are cleared; nothing on the host changes).
    public func remove(_ e: SimHostEntry) throws {
        try saveFileEntries(fileEntries().filter { !Self.same($0, e) })
        guard isIDEHost(e) else { return }
        var s = RemoteSimulatorSettings.load(ide)
        s.destination = ""
        s.dataDirectory = ""
        s.runtimeRoot = ""
        s.otherRuntimeRoots = []
        s.simdPath = ""
        s.save(ide)
        RemoteSimulatorSettings.saveCreatedDevices([], ide)
        var c = RuntimeSetupChoices.load(ide)
        if c.host.destination == e.destination {
            c.host = RuntimeHostSettings()
            c.useHost = false
            c.save(ide)
        }
        ide.synchronize()
    }

    /// The created devices of a host.
    public func createdDevices(of e: SimHostEntry) -> [RemoteCreatedDevice] {
        isIDEHost(e) ? RemoteSimulatorSettings.createdDevices(ide) : (fileEntries().first { $0.name == e.name }?.createdDevices ?? e.createdDevices)
    }

    public func saveCreatedDevices(_ devices: [RemoteCreatedDevice], of e: SimHostEntry) throws {
        if isIDEHost(e) {
            RemoteSimulatorSettings.saveCreatedDevices(devices, ide)
            ide.synchronize()
            return
        }
        var entries = fileEntries()
        if let i = entries.firstIndex(where: { $0.name == e.name }) {
            entries[i].createdDevices = devices
        } else {
            var n = e
            n.createdDevices = devices
            entries.append(n)
        }
        try saveFileEntries(entries)
    }
}
