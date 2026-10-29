import Foundation
import YcodeBuild

/// A device type Ycode's simulator can boot (`ycode-simd --device-type`;
/// `specs/simulator/ipad.md` §4, `specs/ide/run.md` §Runtimes and device
/// types). The IDE knows the ids, names and the runtime versions each type
/// runs on; `ycode-simd` has the device data.
public struct YcodeSimulatorDeviceType: Equatable, Sendable {
    /// `ycode-simd --device-type` id.
    public let id: String
    /// The device type's name, as the reference lists it.
    public let name: String
    /// The oldest runtime version the type runs on (the device type's
    /// `minRuntimeVersion`, ipad.md §3.2).
    public let minRuntimeVersion: String

    public init(id: String, name: String, minRuntimeVersion: String) {
        self.id = id
        self.name = name
        self.minRuntimeVersion = minRuntimeVersion
    }

    public static let iPhoneDuo = YcodeSimulatorDeviceType(id: "iphone-duo", name: "iPhone Duo", minRuntimeVersion: "27.1")
    public static let iPhone18Pro = YcodeSimulatorDeviceType(id: "iphone-18-pro", name: "iPhone 18 Pro", minRuntimeVersion: "27.0")
    public static let iPadA16 = YcodeSimulatorDeviceType(id: "ipad-a16", name: "iPad (A16)", minRuntimeVersion: "18.3")
    public static let iPadPro13M5 = YcodeSimulatorDeviceType(id: "ipad-pro-13-m5", name: "iPad Pro 13-inch (M5)", minRuntimeVersion: "26.0")

    /// Every type, in menu order: phones (newest runtime first), then iPads.
    public static let all: [YcodeSimulatorDeviceType] = [iPhoneDuo, iPhone18Pro, iPadA16, iPadPro13M5]
    static let phones: [YcodeSimulatorDeviceType] = [iPhoneDuo, iPhone18Pro]

    /// `ycode-simd`'s default (`--device-type` is left out for it, so a
    /// device and its snapshots from before device types keep matching).
    public static let simdDefault = iPhoneDuo

    public static func named(_ id: String) -> YcodeSimulatorDeviceType? { all.first { $0.id == id } }

    /// The type folds (two integrated displays; `specs/simulator/foldable.md`
    /// §8.3 E1): the iPhone Duo. Its rows get the fold controls.
    public var isFoldable: Bool { id == Self.iPhoneDuo.id }

    /// Whether the type runs on a runtime of this version (unknown: yes).
    public func runs(onRuntimeVersion version: String?) -> Bool {
        guard let version, !version.isEmpty else { return true }
        return DestinationCatalog.compareVersions(version, minRuntimeVersion) != .orderedAscending
    }

    /// The types a runtime of this version runs, in menu order. The first
    /// is the runtime's default type. Of the iPhones only the newest that
    /// runs on the version is offered (iphone-types.md §5 I3: iPhone Duo on
    /// 27.1, iPhone 18 Pro on 27.0); an unknown version offers every type.
    public static func supported(onRuntimeVersion version: String?) -> [YcodeSimulatorDeviceType] {
        guard let version, !version.isEmpty else { return all }
        let phone = phones.first { $0.runs(onRuntimeVersion: version) }
        return all.filter { $0.runs(onRuntimeVersion: version) && (!phones.contains($0) || $0 == phone) }
    }
}

/// One run destination of Ycode's remote simulator: a runtime root on the
/// host and a device type, with its own device directory (so its data,
/// snapshot and saved state are per runtime and type).
public struct RemoteSimulatorTarget: Equatable, Sendable {
    public var runtimeRoot: String
    /// The runtime's version (read from the host, else from the path).
    public var runtimeVersion: String?
    public var deviceType: YcodeSimulatorDeviceType
    /// The device directory name under `<data>/devices`.
    public var deviceDirectoryName: String
    /// The first runtime root's default type: its identifier and device
    /// directory are the ones Ycode used before runtimes and types were
    /// choosable, so a remembered choice and an existing device stay.
    public var isPrimary: Bool

    /// The destination identifier: `ycode-remote-simulator` for the primary
    /// target, else `ycode-remote-simulator:<type id>@<runtime root>`.
    public var identifier: String {
        isPrimary ? RemoteSimulator.identifier : "\(RemoteSimulator.identifier):\(deviceType.id)@\(runtimeRoot)"
    }

    /// The row's name: "<device type> (Ycode)"; the row title adds the
    /// runtime version ("iPhone Duo (Ycode) 27.1").
    public var name: String { "\(deviceType.name) (Ycode)" }

    /// The destination row.
    public var destination: Destination {
        var d = RemoteSimulator.destination
        d.name = name
        d.identifier = identifier
        d.osVersion = runtimeVersion
        return d
    }

    /// `--device-type <id>` unless it is ycode-simd's default type.
    public var deviceTypeArguments: [String] {
        deviceType == YcodeSimulatorDeviceType.simdDefault ? [] : ["--device-type", deviceType.id]
    }

    /// A path-safe tag for a runtime: its version, else the last path
    /// component of the root with other characters replaced.
    static func runtimeTag(root: String, version: String?) -> String {
        if let version, !version.isEmpty { return version }
        let comps = root.split(separator: "/").map(String.init).filter { $0 != "RuntimeRoot" && !$0.isEmpty }
        let base = comps.last ?? "runtime"
        return String(base.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" })
    }
}

extension RemoteSimulatorSettings {
    /// Settings ▸ Simulators help for "Other runtime roots".
    public static let runtimesHelp = "More simulator runtimes on the host, separated by commas. Each runtime adds a run destination for every device type it supports (for example iOS 27.0 with iPads and its full app set). Every runtime and device type has its own device, so data and saved state are kept apart."

    /// The primary runtime root, then the other ones (duplicates and empty
    /// entries dropped).
    public var allRuntimeRoots: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in [runtimeRoot] + otherRuntimeRoots {
            let t = r.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    /// Other runtime roots from the settings text: separated by commas or new lines.
    public static func runtimeRoots(fromText text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A runtime root's version: the one read from the host, else one in its path.
    public func runtimeVersion(forRoot root: String) -> String? {
        if root == runtimeRoot, let runtimeVersion { return runtimeVersion }
        return runtimeVersions[root] ?? Self.version(inPath: root)
    }

    /// Every run destination: for each runtime root (primary first), each
    /// device type that runs on its version. The primary root's first type
    /// keeps the device directory `deviceName`; the others get
    /// `<deviceName>-<type id>-<runtime version>`.
    public var targets: [RemoteSimulatorTarget] {
        var out: [RemoteSimulatorTarget] = []
        for (i, root) in allRuntimeRoots.enumerated() {
            let version = runtimeVersion(forRoot: root)
            for (j, type) in YcodeSimulatorDeviceType.supported(onRuntimeVersion: version).enumerated() {
                let primary = i == 0 && j == 0 && type == .simdDefault
                let dir = primary ? deviceName : "\(deviceName)-\(type.id)-\(RemoteSimulatorTarget.runtimeTag(root: root, version: version))"
                out.append(RemoteSimulatorTarget(runtimeRoot: root, runtimeVersion: version, deviceType: type,
                                                 deviceDirectoryName: dir, isPrimary: primary))
            }
        }
        return out
    }

    /// The target a destination names (its identifier), else the first one.
    public func target(for destination: Destination?) -> RemoteSimulatorTarget? {
        let all = targets
        if let id = destination?.identifier, let t = all.first(where: { $0.identifier == id }) { return t }
        return all.first
    }
}
