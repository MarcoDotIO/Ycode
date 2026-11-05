import Foundation
import YcodeDeviceModel
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
    /// A Ycode simulator's device directory name under `<data>/devices`
    /// (its pairs name it, `RemoteDevicePair`).
    public var deviceDirectory: String?
    /// A device the user created in Device Hub (it can be deleted).
    public var isCreated = false

    /// Ycode's remote simulator as a Simulators row: "Booted" while a run
    /// uses it, else "Shutdown" (its state is saved between runs).
    public static func ycodeRemote(_ remote: RemoteSimulator, running: Bool) -> DeviceRow {
        let s = remote.settings
        // One row per runtime and device type (run.md §Runtimes and device types).
        return DeviceRow(name: remote.target?.name ?? RemoteSimulator.deviceName, identifier: "\(s.destination):\(remote.remoteDevicePath)",
                         platform: remote.target?.deviceType.platform ?? "iOS", osVersion: remote.runtimeVersion ?? "",
                         state: running ? "Booted" : "Shutdown",
                         model: remote.target.map { "\($0.deviceType.name), Ycode Simulator (Linux)" } ?? "Ycode Simulator (Linux)",
                         isAvailable: true, isYcodeRemote: true, isFoldable: remote.isFoldable,
                         deviceTypeID: remote.target?.deviceType.id, deviceDirectory: remote.deviceDirectoryName,
                         isCreated: remote.target?.isCreated ?? false)
    }

    /// A shut-down Ycode simulator row with no simulator behind it (the
    /// layout probe's Device Hub, `LayoutProbe`).
    public static func shutDownYcodeSimulator(name: String, identifier: String) -> DeviceRow {
        DeviceRow(name: name, identifier: identifier, platform: "iOS", osVersion: "27.1", state: "Shutdown",
                  model: "Ycode Simulator", isAvailable: true, isYcodeRemote: true, isFoldable: false)
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
