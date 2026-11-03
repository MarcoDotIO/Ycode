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
    /// The platform of the runtimes it runs on: "iOS", or "watchOS" for the
    /// Apple Watch types (`specs/simulator/watchos.md` §3.1).
    public var platform = "iOS"
    /// The newest runtime version on which a watch type is offered (the
    /// end of its "default create" range, watchos.md §3.1); nil: no limit.
    public var newestDefaultRuntimeVersion: String?

    public init(id: String, name: String, minRuntimeVersion: String) {
        self.id = id
        self.name = name
        self.minRuntimeVersion = minRuntimeVersion
    }

    static func watch(_ id: String, _ name: String, _ min: String, through newest: String? = nil) -> YcodeSimulatorDeviceType {
        var t = YcodeSimulatorDeviceType(id: id, name: name, minRuntimeVersion: min)
        t.platform = "watchOS"
        t.newestDefaultRuntimeVersion = newest
        return t
    }

    /// The Apple Watch types (watchos.md §3.1, ycode-simd's ids), with the
    /// runtime versions each is created on by default.
    public static let watches: [YcodeSimulatorDeviceType] = [
        watch("apple-watch-series-12-46mm", "Apple Watch Series 12 (46mm)", "27.0"),
        watch("apple-watch-series-12-42mm", "Apple Watch Series 12 (42mm)", "27.0"),
        watch("apple-watch-ultra-4-49mm", "Apple Watch Ultra 4 (49mm)", "27.0"),
        watch("apple-watch-series-11-46mm", "Apple Watch Series 11 (46mm)", "26.0", through: "26.99"),
        watch("apple-watch-series-11-42mm", "Apple Watch Series 11 (42mm)", "26.0", through: "26.99"),
        watch("apple-watch-series-10-46mm", "Apple Watch Series 10 (46mm)", "11.0", through: "11.99"),
        watch("apple-watch-series-10-42mm", "Apple Watch Series 10 (42mm)", "11.0", through: "11.99"),
        watch("apple-watch-series-9-45mm", "Apple Watch Series 9 (45mm)", "10.0", through: "10.99"),
        watch("apple-watch-series-9-41mm", "Apple Watch Series 9 (41mm)", "10.0", through: "10.99"),
        watch("apple-watch-ultra-3-49mm", "Apple Watch Ultra 3 (49mm)", "26.0", through: "26.99"),
        watch("apple-watch-ultra-2-49mm", "Apple Watch Ultra 2 (49mm)", "10.0", through: "11.99"),
        watch("apple-watch-se-3-44mm", "Apple Watch SE 3 (44mm)", "26.0"),
        watch("apple-watch-se-3-40mm", "Apple Watch SE 3 (40mm)", "26.0"),
    ]

    /// The watch types a watchOS runtime of this version offers: those
    /// created on it by default (Ycode decision, from watchos.md §3.1's
    /// "default create" column: on 27.0 Series 12 46 and 42 mm, Ultra 4 and
    /// SE 3 44 and 40 mm), Series 12 (46mm) first; an unknown version
    /// offers the newest generation.
    public static func watches(onRuntimeVersion version: String?) -> [YcodeSimulatorDeviceType] {
        let v = (version?.isEmpty ?? true) ? watches[0].minRuntimeVersion : version!
        return watches.filter { t in
            t.runs(onRuntimeVersion: v)
                && t.newestDefaultRuntimeVersion.map { DestinationCatalog.compareVersions(v, $0) != .orderedDescending } ?? true
        }
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

    /// Apple Vision Pro (`ycode-simd`'s `vision-pro`; visionos.md §3, V-1):
    /// the one type of the visionOS (xrOS) runtimes.
    public static let visionPro: YcodeSimulatorDeviceType = {
        var t = YcodeSimulatorDeviceType(id: "vision-pro", name: "Apple Vision Pro", minRuntimeVersion: "1.0")
        t.platform = "visionOS"
        return t
    }()

    /// The visionOS types a runtime of this version offers.
    public static func visions(onRuntimeVersion version: String?) -> [YcodeSimulatorDeviceType] {
        [visionPro].filter { $0.runs(onRuntimeVersion: version) }
    }

    public static func named(_ id: String) -> YcodeSimulatorDeviceType? { (all + watches + [visionPro]).first { $0.id == id } }

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
    /// The name the user gave a device created in Device Hub (nil: the
    /// type's row name, "<device type> (Ycode)").
    public var customName: String?

    package init(runtimeRoot: String, runtimeVersion: String? = nil, deviceType: YcodeSimulatorDeviceType, deviceDirectoryName: String, isPrimary: Bool,
                 customName: String? = nil) {
        self.runtimeRoot = runtimeRoot
        self.runtimeVersion = runtimeVersion
        self.deviceType = deviceType
        self.deviceDirectoryName = deviceDirectoryName
        self.isPrimary = isPrimary
        self.customName = customName
    }

    /// A watch type's target (its runs build for the watchOS simulator).
    public var isWatch: Bool { deviceType.platform == "watchOS" }

    /// An Apple Vision Pro target (a visionOS runtime).
    public var isVision: Bool { deviceType.platform == "visionOS" }

    /// Whether this is a device the user created (its identifier names its directory).
    public var isCreated: Bool { customName != nil }

    /// The destination identifier: `ycode-remote-simulator` for the primary
    /// target, else `ycode-remote-simulator:<type id>@<runtime root>`.
    public var identifier: String {
        if isPrimary { return RemoteSimulator.identifier }
        if isCreated { return "\(RemoteSimulator.identifier):device:\(deviceDirectoryName)" }
        return "\(RemoteSimulator.identifier):\(deviceType.id)@\(runtimeRoot)"
    }

    /// The row's name: "<device type> (Ycode)"; the row title adds the
    /// runtime version ("iPhone Duo (Ycode) 27.1").
    public var name: String { customName ?? "\(deviceType.name) (Ycode)" }

    /// The destination row. A watch builds for the generic watchOS
    /// simulator (`watchos.md` §8: the `watchsimulator` SDK).
    public var destination: Destination {
        var d = RemoteSimulator.destination
        d.name = name
        d.identifier = identifier
        d.osVersion = runtimeVersion
        if isWatch {
            d.platform = "watchOS"
            d.specifier = "generic/platform=watchOS Simulator"
        } else if isVision {
            d.platform = "visionOS"
            d.specifier = "generic/platform=visionOS Simulator"
        }
        return d
    }

    /// `--device-type <id>` unless it is ycode-simd's default type.
    public var deviceTypeArguments: [String] {
        deviceType == YcodeSimulatorDeviceType.simdDefault ? [] : ["--device-type", deviceType.id]
    }

    /// A path-safe tag for a runtime: its version, else the last path
    /// component of the root with other characters replaced.
    package static func runtimeTag(root: String, version: String?) -> String {
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

    /// A runtime root's platform: the one read from the host
    /// (`SystemVersion.plist` `ProductName`), else "watchOS" or "visionOS"
    /// when the runtime's own name says so (`xrOS` or `visionOS`), else "iOS".
    public func runtimePlatform(forRoot root: String) -> String {
        if let p = runtimePlatforms[root] { return p }
        let name = Self.runtimeName(inPath: root)
        if name.range(of: "watchOS", options: .caseInsensitive) != nil { return "watchOS" }
        if name.range(of: "xrOS", options: .caseInsensitive) != nil || name.range(of: "visionOS", options: .caseInsensitive) != nil { return "visionOS" }
        return "iOS"
    }

    /// The path component that names the runtime: the last one, past a
    /// runtime bundle's `Contents/Resources/RuntimeRoot` ("xrOS-27.0-24O353",
    /// "watchOS_27.0.simruntime"). Only it counts: the directories above
    /// are the user's (a checkout named "visionos-…" made every runtime
    /// under it a visionOS one, and an iOS root gave no run destinations).
    static func runtimeName(inPath root: String) -> String {
        var comps = root.split(separator: "/").map(String.init)
        while let last = comps.last, ["RuntimeRoot", "Resources", "Contents"].contains(last) { comps.removeLast() }
        return comps.last ?? ""
    }

    /// Every iOS run destination: for each iOS runtime root (primary first),
    /// each device type that runs on its version, then the phones the user
    /// created. The primary root's first type keeps the device directory
    /// `deviceName`; the others get `<deviceName>-<type id>-<runtime
    /// version>`. Watches are `watchTargets` (since W6, `device-pairing.md`
    /// §13: run destinations of watchOS schemes).
    public var targets: [RemoteSimulatorTarget] { iOSTargets + createdTargets.filter { !$0.isWatch && !$0.isVision } }

    /// The created devices whose runtime root is still set up and whose
    /// type runs on it.
    public var createdTargets: [RemoteSimulatorTarget] {
        let roots = Set(allRuntimeRoots)
        return createdDevices.compactMap { c in
            guard roots.contains(c.runtimeRoot), let type = YcodeSimulatorDeviceType.named(c.typeID) else { return nil }
            let version = runtimeVersion(forRoot: c.runtimeRoot)
            guard runtimePlatform(forRoot: c.runtimeRoot) == type.platform, type.runs(onRuntimeVersion: version) else { return nil }
            return RemoteSimulatorTarget(runtimeRoot: c.runtimeRoot, runtimeVersion: version, deviceType: type,
                                         deviceDirectoryName: c.directoryName, isPrimary: false, customName: c.name)
        }
    }

    /// The fixed rows of the iOS runtime roots.
    private var iOSTargets: [RemoteSimulatorTarget] {
        var out: [RemoteSimulatorTarget] = []
        for (i, root) in allRuntimeRoots.enumerated() where runtimePlatform(forRoot: root) == "iOS" {
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

    /// Device Hub's Ycode simulators: the iOS targets, the watches, then
    /// the Vision Pros.
    public var hubTargets: [RemoteSimulatorTarget] { targets + watchTargets + visionTargets }

    /// The Vision Pros: one per visionOS runtime root (directory
    /// `<deviceName>-vision-pro-<runtime version>`), then the ones the user
    /// created (Add Device ▸ Apple Vision Pro…). Device Hub rows; they are
    /// not run destinations yet (`device-hub.md` §I.11).
    public var visionTargets: [RemoteSimulatorTarget] {
        var out: [RemoteSimulatorTarget] = []
        for root in allRuntimeRoots where runtimePlatform(forRoot: root) == "visionOS" {
            let version = runtimeVersion(forRoot: root)
            for type in YcodeSimulatorDeviceType.visions(onRuntimeVersion: version) {
                let dir = "\(deviceName)-\(type.id)-\(RemoteSimulatorTarget.runtimeTag(root: root, version: version))"
                out.append(RemoteSimulatorTarget(runtimeRoot: root, runtimeVersion: version, deviceType: type,
                                                 deviceDirectoryName: dir, isPrimary: false))
            }
        }
        return out + createdTargets.filter(\.isVision)
    }

    /// The watches: for each watchOS runtime root the watch types it offers
    /// (`YcodeSimulatorDeviceType.watches(onRuntimeVersion:)`), each with
    /// its own device directory `<deviceName>-<type id>-<runtime version>`,
    /// then the watches the user created.
    public var watchTargets: [RemoteSimulatorTarget] {
        var out: [RemoteSimulatorTarget] = []
        for root in allRuntimeRoots where runtimePlatform(forRoot: root) == "watchOS" {
            let version = runtimeVersion(forRoot: root)
            for type in YcodeSimulatorDeviceType.watches(onRuntimeVersion: version) {
                let dir = "\(deviceName)-\(type.id)-\(RemoteSimulatorTarget.runtimeTag(root: root, version: version))"
                out.append(RemoteSimulatorTarget(runtimeRoot: root, runtimeVersion: version, deviceType: type,
                                                 deviceDirectoryName: dir, isPrimary: false))
            }
        }
        return out + createdTargets.filter(\.isWatch)
    }

    /// The target a destination names (its identifier; a phone-with-watch
    /// destination names its phone), else the first one.
    public func target(for destination: Destination?) -> RemoteSimulatorTarget? {
        let all = hubTargets
        if let id = destination?.identifier {
            if let t = all.first(where: { $0.identifier == id }) { return t }
            if let dir = RemotePairedDestination.phoneDirectory(identifier: id), let t = all.first(where: { $0.deviceDirectoryName == dir }) { return t }
        }
        return targets.first
    }

    /// The target whose device directory this is.
    public func target(directory: String) -> RemoteSimulatorTarget? { hubTargets.first { $0.deviceDirectoryName == directory } }
}
