import Foundation
import YcodeBuild

// Pairs of Ycode's remote simulators in the IDE (`specs/simulator/device-pairing.md`
// P-8, §13; `specs/ide/device-hub.md` §I.9): the host's pair records as
// `ycode-sim list-pairs --json` lists them, the launcher commands that pair,
// unpair and activate, and the devices the user creates for a pair.

/// One pair of Ycode simulators on the host (`device-pairing.md` §2.1, §8.2).
public struct RemoteDevicePair: Equatable, Sendable, Codable {
    /// The pair's UUID (`ycode-sim pair` prints it).
    public var id: String
    /// The devices' directory names under `<data>/devices`.
    public var watchDirectory: String
    public var phoneDirectory: String
    public var watchUDID: String
    public var phoneUDID: String
    /// The device types' names ("Apple Watch Series 12 (46mm)").
    public var watchTypeName: String
    public var phoneTypeName: String
    /// The phone's active pair (a phone has at most one).
    public var active: Bool
    /// Both devices run and their endpoints are registered (§8.2).
    public var connected: Bool
    public var watchBooted: Bool
    public var phoneBooted: Bool

    public init(id: String, watchDirectory: String, phoneDirectory: String, watchUDID: String = "", phoneUDID: String = "",
                watchTypeName: String = "", phoneTypeName: String = "", active: Bool, connected: Bool = false,
                watchBooted: Bool = false, phoneBooted: Bool = false) {
        self.id = id
        self.watchDirectory = watchDirectory
        self.phoneDirectory = phoneDirectory
        self.watchUDID = watchUDID
        self.phoneUDID = phoneUDID
        self.watchTypeName = watchTypeName
        self.phoneTypeName = phoneTypeName
        self.active = active
        self.connected = connected
        self.watchBooted = watchBooted
        self.phoneBooted = phoneBooted
    }

    /// "(active, connected)" as `list-pairs` writes it.
    public var stateText: String { "(\(active ? "active" : "inactive"), \(connected ? "connected" : "disconnected"))" }
}

/// `ycode-sim list-pairs --json` (`device-pairing.md` §2.2, §8.2):
/// `{"pairs": {<UUID>: {"watch": {name, udid, state}, "phone": {…}, "state": "(active, connected)"}}}`,
/// where a device's name is "<device type> [<directory name>]".
public enum RemotePairListing {
    /// The pairs of a listing, sorted by phone, then watch directory; nil
    /// when the data is not a listing.
    public static func parse(_ data: Data) -> [RemoteDevicePair]? {
        // The launcher may print status lines before the JSON object.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let pairs = root["pairs"] as? [String: Any] else { return nil }
        var out: [RemoteDevicePair] = []
        for (id, value) in pairs {
            guard let p = value as? [String: Any], let w = p["watch"] as? [String: Any], let ph = p["phone"] as? [String: Any] else { continue }
            let (wType, wDir) = split(name: w["name"] as? String ?? "")
            let (pType, pDir) = split(name: ph["name"] as? String ?? "")
            guard let wDir, let pDir else { continue }
            let state = p["state"] as? String ?? ""
            out.append(RemoteDevicePair(id: id.uppercased(), watchDirectory: wDir, phoneDirectory: pDir,
                                        watchUDID: (w["udid"] as? String ?? "").uppercased(), phoneUDID: (ph["udid"] as? String ?? "").uppercased(),
                                        watchTypeName: wType, phoneTypeName: pType,
                                        active: state.hasPrefix("(active"), connected: state.contains(" connected"),
                                        watchBooted: w["state"] as? String == "Booted", phoneBooted: ph["state"] as? String == "Booted"))
        }
        return out.sorted { ($0.phoneDirectory, $0.watchDirectory) < ($1.phoneDirectory, $1.watchDirectory) }
    }

    /// "Apple Watch Series 12 (46mm) [ycode-device-…]" → the type's name and
    /// the directory name; a device whose directory is gone ("[missing]")
    /// has none.
    public static func split(name: String) -> (type: String, directory: String?) {
        guard name.hasSuffix("]"), let open = name.range(of: " [", options: .backwards) else { return (name, nil) }
        let dir = String(name[open.upperBound..<name.index(before: name.endIndex)])
        return (String(name[..<open.lowerBound]), dir.isEmpty || dir == "missing" ? nil : dir)
    }
}

/// A device the user created in Device Hub (Pair Watch… with a new watch,
/// iPhone with Paired Watch…): a name, a device type and a runtime root, with
/// its own device directory. **Ycode decision** (`device-hub.md` §I.9): the
/// list is kept in the user's defaults like the rest of Settings ▸
/// Simulators; the host keeps the device's data.
public struct RemoteCreatedDevice: Equatable, Sendable, Codable {
    public var name: String
    public var typeID: String
    public var runtimeRoot: String
    /// Its directory name under `<data>/devices`.
    public var directoryName: String

    public init(name: String, typeID: String, runtimeRoot: String, directoryName: String) {
        self.name = name
        self.typeID = typeID
        self.runtimeRoot = runtimeRoot
        self.directoryName = directoryName
    }

    /// A new device's directory: `<device name>-<type id>-<runtime tag>-<8 hex digits>`.
    public static func directoryName(deviceName: String, typeID: String, runtimeTag: String, unique: String = UUID().uuidString) -> String {
        let hex = unique.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(deviceName)-\(typeID)-\(runtimeTag)-\(hex)"
    }
}

extension RemoteSimulatorSettings {
    /// The defaults key of the created devices (a JSON array).
    public static let createdDevicesKey = "Ycode.remote.createdDevices"

    /// The created devices kept in the defaults. `save(_:)` never writes
    /// them (a Settings pane opened before a device was created would drop
    /// it); `saveCreatedDevices` does.
    public static func createdDevices(_ d: UserDefaults) -> [RemoteCreatedDevice] {
        guard let data = d.data(forKey: createdDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteCreatedDevice].self, from: data)) ?? []
    }

    public static func saveCreatedDevices(_ devices: [RemoteCreatedDevice], _ d: UserDefaults) {
        d.set(try? JSONEncoder().encode(devices), forKey: createdDevicesKey)
    }
}

// MARK: - Phone-with-watch destinations (§11.4, P-9)

/// The run destination of a phone with an active paired watch: a watchOS
/// scheme's app runs on the phone's active watch (`device-pairing.md` §11.4:
/// the watch scheme lists every phone with an active paired watch).
/// Identifier `ycode-remote-simulator:paired:<phone directory>`; the watch
/// is the phone's active one when the run starts.
public enum RemotePairedDestination {
    public static let prefix = RemoteSimulator.identifier + ":paired:"
    public static func identifier(phoneDirectory: String) -> String { prefix + phoneDirectory }
    public static func phoneDirectory(identifier: String) -> String? {
        identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : nil
    }
    /// The row's title: "<phone> with <watch>". **Ycode decision**: the
    /// reference's title for this row was not observed (§9 Q2, §13 Q14).
    public static func title(phone: String, watch: String) -> String { "\(phone) with \(watch)" }
}

extension Destination {
    /// A phone-with-watch destination of Ycode's remote simulator.
    public var isYcodePairedDestination: Bool { identifier.map { $0.hasPrefix(RemotePairedDestination.prefix) } ?? false }
}

extension RemoteSimulatorSettings {
    /// One destination per phone target with an active pair whose watch is
    /// one of the watch targets: platform watchOS (it runs a watch app), the
    /// generic watchOS simulator's specifier, the watch's runtime version
    /// (so a watch older than the scheme's deployment target is listed as
    /// incompatible, §11.4).
    public func pairedDestinations(_ pairs: [RemoteDevicePair]) -> [Destination] {
        let watches = watchTargets
        return targets.compactMap { phone in
            guard let pair = pairs.first(where: { $0.phoneDirectory == phone.deviceDirectoryName && $0.active }),
                  let watch = watches.first(where: { $0.deviceDirectoryName == pair.watchDirectory }) else { return nil }
            var d = watch.destination
            d.name = RemotePairedDestination.title(phone: phone.name, watch: watch.name)
            d.identifier = RemotePairedDestination.identifier(phoneDirectory: phone.deviceDirectoryName)
            return d
        }
    }

    /// The phone and its active watch of a phone-with-watch destination;
    /// nil when the phone has no active paired watch now.
    public func pairedTargets(for destination: Destination?, pairs: [RemoteDevicePair]) -> (phone: RemoteSimulatorTarget, watch: RemoteSimulatorTarget)? {
        guard let id = destination?.identifier, let dir = RemotePairedDestination.phoneDirectory(identifier: id),
              let phone = targets.first(where: { $0.deviceDirectoryName == dir }) else { return nil }
        return pairedWatch(of: phone, pairs: pairs).map { (phone, $0) }
    }

    /// A phone target's active paired watch target.
    public func pairedWatch(of phone: RemoteSimulatorTarget, pairs: [RemoteDevicePair]) -> RemoteSimulatorTarget? {
        guard let pair = pairs.first(where: { $0.phoneDirectory == phone.deviceDirectoryName && $0.active }) else { return nil }
        return watchTargets.first { $0.deviceDirectoryName == pair.watchDirectory }
    }
}

// MARK: - New devices (Device Hub's forms)

extension RemoteSimulatorSettings {
    /// The runtime roots of a platform ("iOS", "watchOS") with their
    /// versions: a new device's OS Version choices, primary root first.
    public func runtimeRoots(platform: String) -> [(root: String, version: String?)] {
        allRuntimeRoots.filter { runtimePlatform(forRoot: $0) == platform }.map { ($0, runtimeVersion(forRoot: $0)) }
    }

    /// The device types a new device may have on a runtime root: the watch
    /// types it offers (watchOS), Apple Vision Pro (visionOS), or its iPhone (iOS: the newest phone that
    /// runs on the version, the rule of the destination rows).
    public func newDeviceTypes(platform: String, root: String) -> [YcodeSimulatorDeviceType] {
        let version = runtimeVersion(forRoot: root)
        if platform == "watchOS" { return YcodeSimulatorDeviceType.watches(onRuntimeVersion: version) }
        if platform == "visionOS" { return YcodeSimulatorDeviceType.visions(onRuntimeVersion: version) }
        return YcodeSimulatorDeviceType.supported(onRuntimeVersion: version).filter { YcodeSimulatorDeviceType.phones.contains($0) }
    }

    /// Records a new device (its directory is made on the host when it is
    /// paired or first started).
    @discardableResult
    public static func createDevice(name: String, type: YcodeSimulatorDeviceType, runtimeRoot: String, _ d: UserDefaults) -> RemoteCreatedDevice {
        let settings = load(d)
        let tag = RemoteSimulatorTarget.runtimeTag(root: runtimeRoot, version: settings.runtimeVersion(forRoot: runtimeRoot))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = RemoteCreatedDevice(name: trimmed.isEmpty ? type.name : trimmed, typeID: type.id, runtimeRoot: runtimeRoot,
                                         directoryName: RemoteCreatedDevice.directoryName(deviceName: settings.deviceName, typeID: type.id, runtimeTag: tag))
        saveCreatedDevices(createdDevices(d) + [device], d)
        return device
    }

    /// Forgets a created device.
    public static func removeCreatedDevice(directory: String, _ d: UserDefaults) {
        saveCreatedDevices(createdDevices(d).filter { $0.directoryName != directory }, d)
    }
}

// MARK: - Commands

extension RemoteSimulator {
    /// The device set: `<data>/devices` (every IDE device directory is in it).
    public var deviceSetPath: String { "\(settings.dataDirectory)/devices" }

    /// The launcher with the device set named (`YCODE_SIM_DEVICE_SET`), so
    /// every pairing command reads and writes the same records.
    func pairingCommand(_ words: [String]) -> String {
        "exec env YCODE_SIM_DEVICE_SET=\(Self.quote(deviceSetPath)) \(Self.quote(settings.simdPath))" + words.map { " " + Self.quote($0) }.joined()
    }

    /// `ycode-sim list-pairs --json`.
    public var listPairsCommand: String { pairingCommand(["list-pairs", "--json"]) }

    /// Makes sure a device directory that never booted has its type record
    /// (`ycode-device-type`, what a boot writes), so it can be paired before
    /// its first boot (`ycode-simd` refuses a directory without a type;
    /// `device-pairing.md` §8.2 "Devices"). A directory that has one is not
    /// touched.
    public static func typeRecordCommand(devicePath: String, typeID: String) -> String {
        let d = quote(devicePath)
        return "{ [ -e \(d)/ycode-device-type ] || [ -e \(d)/data/var/run/launchd_bootstrap.plist ] || { mkdir -p \(d) && printf '%s\\n' \(quote(typeID)) > \(d)/ycode-device-type; }; }"
    }

    /// `ycode-sim pair <watch> <phone>` (either order works; the watch
    /// first, as `simctl pair` takes them), both type records first.
    public func pairCommand(watch: RemoteSimulator) -> String {
        let records = [watch, self].compactMap { r in r.target.map { Self.typeRecordCommand(devicePath: r.remoteDevicePath, typeID: $0.deviceType.id) } }
        return (records + [pairingCommand(["pair", watch.remoteDevicePath, remoteDevicePath])]).joined(separator: " && ")
    }

    /// `ycode-sim unpair <pair>`: the watch is shut down and erased (P-3).
    public func unpairCommand(_ pairID: String) -> String { pairingCommand(["unpair", pairID]) }

    /// `ycode-sim pair-activate <pair>`.
    public func activateCommand(_ pairID: String) -> String { pairingCommand(["pair-activate", pairID]) }

    /// Runs a pairing command through ssh: (status, output). Blocks: call it
    /// off the main actor.
    public func runPairing(_ command: String) -> (Int32, String) {
        runLocal(settings.ssh, sshArguments(command))
    }

    /// Reads the host's pairs (nil when they cannot be read). Blocks.
    public func readPairs() -> [RemoteDevicePair]? {
        let (status, data) = runLocalData(settings.ssh, sshArguments(listPairsCommand), errors: false)
        guard status == 0 else { return nil }
        return RemotePairListing.parse(data)
    }

    /// The new pair's UUID in `ycode-sim pair`'s output (its last line that is one).
    public static func pairID(fromPairOutput text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { UUID(uuidString: $0) != nil }.map { $0.uppercased() }
    }

    /// The device directory's name (its pairs name it so).
    public var deviceDirectoryName: String { target?.deviceDirectoryName ?? settings.deviceName }
}

// MARK: - The pairs the IDE knows

/// The host's pairs as the IDE last read them (`list-pairs --json`),
/// kept in the defaults so destinations stay put across launches.
/// Changes post `didChange`.
@MainActor
public final class RemotePairsStore {
    public static let shared = RemotePairsStore()
    public static let didChange = Notification.Name("YcodeRemotePairsDidChange")
    public static let defaultsKey = "Ycode.remote.pairs"

    /// Where the pairs are kept (the IDE's preferences; a test's domain).
    public var defaults: UserDefaults = .standard {
        didSet { if defaults !== oldValue { loaded = false; pairs = [] } }
    }
    public private(set) var pairs: [RemoteDevicePair] = []
    private var loaded = false

    public init(defaults: UserDefaults? = nil) {
        if let defaults { self.defaults = defaults }
    }

    /// The pairs (from the defaults until the host was read).
    public func current() -> [RemoteDevicePair] {
        if !loaded {
            loaded = true
            if let data = defaults.data(forKey: Self.defaultsKey), let p = try? JSONDecoder().decode([RemoteDevicePair].self, from: data) { pairs = p }
        }
        return pairs
    }

    /// Replaces the pairs (a listing read from the host).
    public func set(_ p: [RemoteDevicePair]) {
        loaded = true
        guard p != pairs else { return }
        pairs = p
        defaults.set(try? JSONEncoder().encode(p), forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Reads the host's pairs; false when they could not be read.
    @discardableResult
    public func refresh(_ remote: RemoteSimulator) async -> Bool {
        guard remote.settings.isConfigured, let p = await Task.detached(operation: { remote.readPairs() }).value else { return false }
        set(p)
        return true
    }
}

/// What a device's pairs mean for Device Hub and the destinations.
public struct RemotePairing: Equatable, Sendable {
    public var pairs: [RemoteDevicePair]
    public init(_ pairs: [RemoteDevicePair]) { self.pairs = pairs }

    /// A phone's pairs (active first), or a watch's (at most one).
    public func pairs(ofDirectory dir: String) -> [RemoteDevicePair] {
        pairs.filter { $0.phoneDirectory == dir || $0.watchDirectory == dir }.sorted { $0.active && !$1.active }
    }

    /// A phone's active pair.
    public func activePair(phone dir: String) -> RemoteDevicePair? { pairs.first { $0.phoneDirectory == dir && $0.active } }

    /// Whether a watch is paired (a watch pairs with one phone, §2.3).
    public func isPaired(watch dir: String) -> Bool { pairs.contains { $0.watchDirectory == dir } }
}
