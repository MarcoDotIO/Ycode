// A host's devices, runtimes and device types as `simctl` names them
// (specs/ide/ycrun.md §6). The devices are the IDE's: every runtime root's
// device types (`RemoteSimulatorSettings.hubTargets`) and the devices made
// with `create` (Device Hub's created devices), each a directory under
// `<data>/devices`. A device's UDID is ycode-simd's own: derived from its
// directory's path, so the device reports the same one.

import Foundation
import YcodeIDECore

public enum SimDeviceState: String, Sendable, Codable {
    case shutdown = "Shutdown"
    case booting = "Booting"
    case booted = "Booted"
}

/// A simulator runtime on a host (a RuntimeRoot).
public struct SimRuntime: Equatable, Sendable {
    /// "iOS", "watchOS", "visionOS".
    public var platform: String
    public var version: String?
    public var build: String?
    public var root: String

    public init(platform: String, version: String?, build: String? = nil, root: String) {
        self.platform = platform
        self.version = version
        self.build = build
        self.root = root
    }

    /// "iOS 27.1".
    public var name: String { platform + " " + (version ?? "(unknown version)") }

    /// Ycode's identifier: "iOS-27-1" (Ycode decision, shaped like simctl's
    /// runtime identifiers without their vendor prefix); the root's tag
    /// when the version is unknown.
    public var identifier: String {
        guard let version, !version.isEmpty else { return platform + "-" + RemoteSimulatorTarget.runtimeTag(root: root, version: nil) }
        return platform + "-" + version.replacingOccurrences(of: ".", with: "-")
    }

    /// Whether an argument names this runtime: its identifier (with or
    /// without simctl's `com.apple.CoreSimulator.SimRuntime.` prefix), its
    /// name, its version, or its root.
    public func matches(_ s: String) -> Bool {
        if s == root || s == root + "/" { return true }
        let n = SimDeviceTypes.normalized(s.replacingOccurrences(of: SimDeviceTypes.appleRuntimePrefix, with: ""))
        if n == SimDeviceTypes.normalized(identifier) || n == SimDeviceTypes.normalized(name) { return true }
        if let version, s == version { return true }
        return false
    }
}

/// The device types ycode-simd boots.
public enum SimDeviceTypes {
    public static let appleTypePrefix = "com.apple.CoreSimulator.SimDeviceType."
    public static let appleRuntimePrefix = "com.apple.CoreSimulator.SimRuntime."

    /// Every type, phones and iPads first, then the watches and Vision Pro.
    public static var all: [YcodeSimulatorDeviceType] {
        YcodeSimulatorDeviceType.all + YcodeSimulatorDeviceType.watches + [YcodeSimulatorDeviceType.visionPro]
    }

    /// Letters and digits, lower case: "iPad Pro 13-inch (M5)" → "ipadpro13inchm5".
    public static func normalized(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A type by its id ("iphone-duo"), its name ("iPhone Duo"), or a
    /// simctl-style identifier ("com.apple.CoreSimulator.SimDeviceType.iPhone-Duo").
    public static func named(_ s: String) -> YcodeSimulatorDeviceType? {
        if let t = YcodeSimulatorDeviceType.named(s) { return t }
        let n = normalized(s.hasPrefix(appleTypePrefix) ? String(s.dropFirst(appleTypePrefix.count)) : s)
        return all.first { normalized($0.id) == n || normalized($0.name) == n }
    }

    /// The product family simctl reports ("iPhone", "iPad", "Apple Watch", "Apple Vision").
    public static func productFamily(_ t: YcodeSimulatorDeviceType) -> String {
        switch t.platform {
        case "watchOS": return "Apple Watch"
        case "visionOS": return "Apple Vision"
        default: return t.id.hasPrefix("ipad") ? "iPad" : "iPhone"
        }
    }
}

/// One device.
public struct SimDevice: Equatable, Sendable {
    public var name: String
    public var udid: String
    /// The directory name under `<data>/devices`.
    public var directory: String
    public var path: String
    public var type: YcodeSimulatorDeviceType
    public var runtime: SimRuntime
    public var state: SimDeviceState
    /// Made with `create` (or Device Hub's Add Device); else a runtime's own device.
    public var isCreated: Bool
    /// "local" or the host's name.
    public var host: String
    public var isLocal: Bool

    /// ycode-simd's UDID for a device directory (DeviceMode.swift's
    /// `stableUDID`): two FNV-1a 64-bit hashes of the absolute path, as a
    /// version-8 style UUID.
    public static func udid(path: String) -> String {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            return h
        }
        var bytes = withUnsafeBytes(of: fnv(0xCBF2_9CE4_8422_2325).bigEndian, Array.init)
            + withUnsafeBytes(of: fnv(0x8422_2325_CBF2_9CE4).bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let c = Array(bytes.map { String(format: "%02X", $0) }.joined())
        return [String(c[0..<8]), String(c[8..<12]), String(c[12..<16]), String(c[16..<20]), String(c[20..<32])].joined(separator: "-")
    }
}

/// A host ready for commands: its settings, where its commands run, and its devices.
public struct SimHostContext: Sendable {
    public var entry: SimHostEntry
    public var settings: RemoteSimulatorSettings
    public var shell: SimShell
    /// "local" or the host's name.
    public var label: String

    public init(entry: SimHostEntry, settings: RemoteSimulatorSettings, shell: SimShell) {
        self.entry = entry
        self.settings = settings
        self.shell = shell
        self.label = entry.isLocal ? "local" : entry.name
    }

    public var data: String { settings.dataDirectory }
    /// ycrun's own files on the host: `<data>/ycrun/<device>.pid`, `.log`, `.apps`.
    public var stateDirectory: String { YcrunDeviceFiles.stateDirectory(data: data) }
    public func pidFile(_ d: SimDevice) -> String { YcrunDeviceFiles.pidFile(data: data, directory: d.directory) }
    public func logFile(_ d: SimDevice) -> String { YcrunDeviceFiles.logFile(data: data, directory: d.directory) }
    public func appsFile(_ d: SimDevice) -> String { stateDirectory + "/" + d.directory + ".apps" }

    /// The runtimes this host is set up with (the primary root first).
    public var runtimes: [SimRuntime] {
        settings.allRuntimeRoots.map {
            SimRuntime(platform: settings.runtimePlatform(forRoot: $0), version: settings.runtimeVersion(forRoot: $0), root: $0)
        }
    }

    /// The devices, all shut down (`withStates` asks the host).
    public var devices: [SimDevice] {
        let rts = runtimes
        return settings.hubTargets.map { t in
            let path = settings.dataDirectory + "/devices/" + t.deviceDirectoryName
            let rt = rts.first { $0.root == t.runtimeRoot }
                ?? SimRuntime(platform: t.deviceType.platform, version: t.runtimeVersion, root: t.runtimeRoot)
            return SimDevice(name: t.name, udid: SimDevice.udid(path: path), directory: t.deviceDirectoryName, path: path,
                             type: t.deviceType, runtime: rt, state: .shutdown, isCreated: t.isCreated, host: label, isLocal: entry.isLocal)
        }
    }

    /// The IDE's simulator object for a device (its launcher commands).
    public func remote(_ d: SimDevice) -> RemoteSimulator {
        RemoteSimulator(settings: settings, target: settings.target(directory: d.directory))
    }

    // MARK: State

    /// One command that prints `<directory> Booted|Booting|Shutdown` per
    /// device. A device ycrun started is Booted once the launcher's log says
    /// it reached the home screen ("home screen at …", cold or restored;
    /// with warm boot off the launcher says nothing and the control socket
    /// decides); until then it is Booting while its launcher runs. A device
    /// another program started (no pid file) is Booted while its control
    /// socket answers. Its control socket answers early in a cold boot,
    /// before there is a screen to capture, so it alone is not enough.
    public func stateCommand(_ list: [SimDevice]) -> String {
        let launcher = shq(settings.simdPath)
        var s = "st() { if [ -f \"$2\" ] && kill -0 \"$(cat \"$2\")\" 2>/dev/null; then "
            + "if grep -q 'ycode-sim: home screen at' \"$3\" 2>/dev/null; then echo Booted; "
            + "elif ! grep -q 'ycode-sim: warm boot' \"$3\" 2>/dev/null && \(launcher) --device \"$1\" --control state >/dev/null 2>&1; then echo Booted; "
            + "else echo Booting; fi; "
            + "elif \(launcher) --device \"$1\" --control state >/dev/null 2>&1; then echo Booted; else echo Shutdown; fi; }; "
        for d in list {
            s += "printf '%s %s\\n' \(shq(d.directory)) \"$(st \(shq(d.path)) \(shq(pidFile(d))) \(shq(logFile(d))))\"; "
        }
        return s + "true"
    }

    public static func parseStates(_ text: String) -> [String: SimDeviceState] {
        var out: [String: SimDeviceState] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let s = SimDeviceState(rawValue: parts[1]) else { continue }
            out[parts[0]] = s
        }
        return out
    }

    /// The devices with their states (one command on the host).
    public func withStates(_ list: [SimDevice]? = nil) -> [SimDevice] {
        let list = list ?? devices
        guard !list.isEmpty else { return [] }
        let r = shell.run(stateCommand(list), timeout: 60)
        let states = Self.parseStates(r.text)
        return list.map { var d = $0; d.state = states[d.directory] ?? .shutdown; return d }
    }

    // MARK: Finding a device

    public enum Lookup: Equatable, Sendable {
        case found(SimDevice)
        case invalid(String)
    }

    /// simctl's device argument: `booted` (the booted device), a UDID, or a
    /// name (also a device directory's name).
    public static func find(_ arg: String, in list: [SimDevice]) -> Lookup {
        if arg == "booted" {
            if let d = list.first(where: { $0.state == .booted }) { return .found(d) }
            return .invalid("No devices are booted.")
        }
        if let d = list.first(where: { $0.udid.caseInsensitiveCompare(arg) == .orderedSame }) { return .found(d) }
        if let d = list.first(where: { $0.name == arg }) ?? list.first(where: { $0.directory == arg }) { return .found(d) }
        return .invalid("Invalid device: \(arg)")
    }
}
