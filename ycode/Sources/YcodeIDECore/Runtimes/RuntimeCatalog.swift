// Simulator runtimes as the runtime wizard sees them
// (`specs/simulator/runtime-onboarding.md` §7, §8, §11.3): one row model for
// a runtime registered with this Mac's CoreSimulator, a runtime Ycode copied
// into its own data folder (this machine or a simulator host), and a runtime
// file the user picked. Everything here only reads: the listings come from
// `simctl runtime list -j` and `simctl list runtimes -j` (run by the
// checker), and a bundle or RuntimeRoot is recognised by its property lists.
// Portable (macOS and Linux).

import Foundation

/// A simulator platform (§1): its names in the listings and on screen.
public enum SimPlatform: String, Sendable, CaseIterable, Codable, Comparable {
    case iOS, watchOS, tvOS, visionOS

    public var title: String { rawValue }

    /// The token in runtime identifiers and image lists (`xrOS` for visionOS).
    public var runtimeToken: String { self == .visionOS ? "xrOS" : rawValue }

    /// `com.apple.platform.<name>` of the simulator platform.
    public var platformIdentifier: String {
        switch self {
        case .iOS: "com.apple.platform.iphonesimulator"
        case .watchOS: "com.apple.platform.watchsimulator"
        case .tvOS: "com.apple.platform.appletvsimulator"
        case .visionOS: "com.apple.platform.xrsimulator"
        }
    }

    /// The name `xcodebuild -downloadPlatform` takes (§1), for the note that
    /// tells the user how to get one with their own Xcode.
    public var downloadName: String { rawValue }

    /// Typical sizes (§4.5): the disk image and the unpacked RuntimeRoot, in
    /// bytes, for free-space checks before Ycode knows the real size.
    public var typicalImageBytes: Int64 {
        switch self {
        case .iOS: 8 << 30
        case .visionOS: 7 << 30
        case .watchOS, .tvOS: 4 << 30
        }
    }
    public var typicalUnpackedBytes: Int64 { typicalImageBytes * 2 }

    public static func < (a: SimPlatform, b: SimPlatform) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// From any of its spellings: `iOS`, `xrOS`, `visionOS`, a platform
    /// identifier, a runtime identifier, or a `SystemVersion.plist`
    /// `ProductName` ("iPhone OS", "Watch OS", "xrOS", "Apple TVOS").
    public init?(name: String) {
        let n = name.lowercased()
        if n.contains("xr") || n.contains("vision") { self = .visionOS }
        else if n.contains("watch") { self = .watchOS }
        else if n.contains("tv") { self = .tvOS }
        else if n.contains("iphone") || n.contains("ios") { self = .iOS }
        else { return nil }
    }
}

/// Where a runtime is.
public enum RuntimeLocation: Sendable, Equatable, Hashable, Codable {
    /// Registered with this Mac's CoreSimulator, or in Ycode's folder on this machine.
    case thisMachine
    /// On a simulator host (its ssh destination or link name).
    case host(String)

    public var title: String {
        switch self {
        case .thisMachine: "This machine"
        case .host(let h): h
        }
    }
}

/// Who manages a runtime, which decides whether Ycode may remove it.
public enum RuntimeOwner: Sendable, Equatable, Hashable, Codable {
    /// Registered with the Mac's CoreSimulator (by Xcode or another tool):
    /// listed read-only; it is managed in the IDE that installed it.
    case coreSimulator
    /// Copied or installed by Ycode into its own data folder (this folder).
    case ycode(folder: String)
    /// A runtime root on a host that Ycode did not copy (named in the host's
    /// configuration or in Settings ▸ Simulators): listed, never removed.
    case external
}

/// One runtime (§11.3's row model).
public struct SimRuntimeRecord: Sendable, Equatable, Hashable, Identifiable, Codable {
    public var platform: SimPlatform
    public var version: String
    public var build: String
    /// `com.apple.CoreSimulator.SimRuntime.<token>-<major>-<minor>`, when known.
    public var identifier: String?
    /// The disk image's size (CoreSimulator), else the copied RuntimeRoot's.
    public var sizeBytes: Int64?
    /// The RuntimeRoot's size on disk, when known (what a copy moves).
    public var unpackedBytes: Int64?
    /// `Ready`, `Unusable`, … (§7.1.1); Ycode's copies are `Ready` when complete.
    public var state: String
    public var architectures: [String]
    public var lastUsed: String?
    public var location: RuntimeLocation
    public var owner: RuntimeOwner
    /// The simulated file system (`…/Contents/Resources/RuntimeRoot`).
    public var runtimeRoot: String?
    /// CoreSimulator's disk-image UUID (never used to delete: §Decisions).
    public var imageUUID: String?
    /// `simctl list runtimes` says it is available (nil: not listed there).
    public var isAvailable: Bool?
    public var availabilityError: String?

    public init(platform: SimPlatform, version: String, build: String, identifier: String? = nil, sizeBytes: Int64? = nil,
                unpackedBytes: Int64? = nil, state: String = "Ready", architectures: [String] = ["arm64"], lastUsed: String? = nil,
                location: RuntimeLocation = .thisMachine, owner: RuntimeOwner = .coreSimulator, runtimeRoot: String? = nil,
                imageUUID: String? = nil, isAvailable: Bool? = nil, availabilityError: String? = nil) {
        self.platform = platform
        self.version = version
        self.build = build
        self.identifier = identifier
        self.sizeBytes = sizeBytes
        self.unpackedBytes = unpackedBytes
        self.state = state
        self.architectures = architectures
        self.lastUsed = lastUsed
        self.location = location
        self.owner = owner
        self.runtimeRoot = runtimeRoot
        self.imageUUID = imageUUID
        self.isAvailable = isAvailable
        self.availabilityError = availabilityError
    }

    /// Version and build are the key (§1: the identifier is not unique).
    public var id: String { "\(location.title)|\(platform.rawValue)|\(version)|\(build)" }

    /// "iOS 27.0 (24A434)".
    public var title: String { "\(platform.title) \(version) (\(build))" }

    /// Usable for a device: `Ready`, and not marked unavailable.
    public var isUsable: Bool { state == "Ready" && isAvailable != false }

    /// Ycode may remove only what it copied or installed itself.
    public var isRemovable: Bool {
        if case .ycode = owner { return true }
        return false
    }

    /// The folder name Ycode gives its copy: `<token>-<version>-<build>`,
    /// the shape the run destinations read platform and version from.
    public var folderName: String { RuntimeFolders.name(platform: platform, version: version, build: build) }

    /// The size text of the row: "7.3 GB", with the unpacked size when it differs.
    public var sizeText: String {
        switch (sizeBytes, unpackedBytes) {
        case let (s?, u?) where s != u: "\(RuntimeSize.format(s)) (\(RuntimeSize.format(u)) unpacked)"
        case let (s?, _): RuntimeSize.format(s)
        case let (nil, u?): RuntimeSize.format(u)
        default: "Size unknown"
        }
    }

    /// Compares dotted versions numerically ("27.10" > "27.9").
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Sizes as the reference's command line prints them (§4.5): binary units,
/// one decimal; written "GB"/"MB" on screen (the convention is binary).
public enum RuntimeSize {
    public static func format(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(bytes)
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(bytes) bytes" }
        return String(format: "%.1f %@", v, units[i])
    }

    /// One line explaining the convention, shown once in the wizard.
    public static let convention = "Sizes use binary units (1 GB = 1,024 MB), as simctl prints them."
}

/// Where Ycode keeps the runtimes it copies.
public enum RuntimeFolders {
    /// The marker in each of Ycode's runtime folders: what it is, and that Ycode made it.
    public static let marker = "ycode-runtime.json"
    /// The suffix of a copy in progress (a resumable transfer).
    public static let incomingSuffix = ".incoming"

    /// `<token>-<version>-<build>`.
    public static func name(platform: SimPlatform, version: String, build: String) -> String {
        "\(platform.runtimeToken)-\(version)-\(build)"
    }

    /// This machine's folder: `$YCODE_RUNTIMES_DIR`, else
    /// `~/Library/Developer/Ycode/Runtimes` (macOS) or
    /// `$XDG_DATA_HOME/ycode/runtimes` (`~/.local/share/ycode/runtimes`).
    public static func local(environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: String = NSHomeDirectory()) -> String {
        if let d = environment["YCODE_RUNTIMES_DIR"], !d.isEmpty { return d }
        #if os(macOS)
        return home + "/Library/Developer/Ycode/Runtimes"
        #else
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        return data + "/ycode/runtimes"
        #endif
    }

    /// A simulator host's folder: `<data directory>/runtimes`.
    public static func host(dataDirectory: String) -> String { dataDirectory + "/runtimes" }

    /// Whether `path` is one runtime folder directly inside `folder` (the
    /// only shape Remove deletes; nothing above it, nothing outside it).
    public static func isRuntimeFolder(_ path: String, inside folder: String) -> Bool {
        let f = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        guard !f.isEmpty, path.hasPrefix(f + "/") else { return false }
        let rest = path.dropFirst(f.count + 1)
        return !rest.isEmpty && !rest.contains("/") && rest != "." && rest != ".." && !rest.hasPrefix(".")
    }
}

/// What the marker file says (JSON).
public struct RuntimeMarker: Codable, Sendable, Equatable {
    public var platform: String
    public var version: String
    public var build: String
    public var identifier: String?
    /// Where it was copied from ("CoreSimulator on <Mac>", a file name).
    public var source: String
    public var copiedAt: String
    public var sizeBytes: Int64?

    public init(platform: String, version: String, build: String, identifier: String?, source: String, copiedAt: String, sizeBytes: Int64?) {
        self.platform = platform
        self.version = version
        self.build = build
        self.identifier = identifier
        self.source = source
        self.copiedAt = copiedAt
        self.sizeBytes = sizeBytes
    }

    public init(_ r: SimRuntimeRecord, source: String, date: Date = Date()) {
        self.init(platform: r.platform.rawValue, version: r.version, build: r.build, identifier: r.identifier, source: source,
                  copiedAt: ISO8601DateFormatter().string(from: date), sizeBytes: r.unpackedBytes ?? r.sizeBytes)
    }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: (try? e.encode(self)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - CoreSimulator's listings (§7.1, §7.6)

public enum SimctlRuntimeListing {
    /// `simctl runtime list -j` (images, keyed by UUID) joined to `simctl
    /// list runtimes -j` (availability, RuntimeRoot) on identifier and build
    /// (§8.1). Images missing from the second listing keep `isAvailable`
    /// nil; runtimes that are not images (bundled, legacy) are added from
    /// the second listing. Sorted by platform, then newest version first.
    public static func parse(images: Data, runtimes: Data?) -> [SimRuntimeRecord] {
        var out: [SimRuntimeRecord] = []
        let listed = runtimes.map(parseRuntimes) ?? []
        if let obj = try? JSONSerialization.jsonObject(with: images) as? [String: Any] {
            for (uuid, value) in obj {
                guard let v = value as? [String: Any] else { continue }
                let rid = v["runtimeIdentifier"] as? String
                let plat = (v["platformIdentifier"] as? String).flatMap(platform(fromPlatformIdentifier:))
                    ?? rid.flatMap { SimPlatform(name: $0) }
                guard let platform = plat, let version = v["version"] as? String else { continue }
                let build = v["build"] as? String ?? ""
                var r = SimRuntimeRecord(platform: platform, version: version, build: build, identifier: rid,
                                         sizeBytes: int64(v["sizeBytes"]), state: v["state"] as? String ?? "Unknown",
                                         architectures: v["supportedArchitectures"] as? [String] ?? [],
                                         lastUsed: v["lastUsedAt"] as? String, owner: .coreSimulator,
                                         imageUUID: v["identifier"] as? String ?? uuid)
                if let bundle = v["runtimeBundlePath"] as? String { r.runtimeRoot = bundle + "/Contents/Resources/RuntimeRoot" }
                if let l = listed.first(where: { $0.identifier == rid && $0.build == build }) {
                    r.isAvailable = l.isAvailable
                    r.availabilityError = l.availabilityError
                    r.runtimeRoot = l.runtimeRoot ?? r.runtimeRoot
                    if r.lastUsed == nil { r.lastUsed = l.lastUsed }
                }
                out.append(r)
            }
        }
        for l in listed where !out.contains(where: { $0.identifier == l.identifier && $0.build == l.build }) { out.append(l) }
        return sorted(out)
    }

    /// `simctl list runtimes -j`'s `runtimes[]`.
    public static func parseRuntimes(_ data: Data) -> [SimRuntimeRecord] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["runtimes"] as? [[String: Any]] else { return [] }
        return list.compactMap { v in
            guard let p = (v["platform"] as? String).flatMap({ SimPlatform(name: $0) }), let version = v["version"] as? String else { return nil }
            // lastUsage: per architecture; 0001-01-01 means never (§7.6).
            let used = (v["lastUsage"] as? [String: String])?.values.filter { !$0.hasPrefix("0001-") }.max()
            return SimRuntimeRecord(platform: p, version: version, build: v["buildversion"] as? String ?? "", identifier: v["identifier"] as? String,
                                    state: "Ready", architectures: v["supportedArchitectures"] as? [String] ?? [], lastUsed: used,
                                    owner: .coreSimulator, runtimeRoot: v["runtimeRoot"] as? String,
                                    isAvailable: v["isAvailable"] as? Bool, availabilityError: v["availabilityError"] as? String)
        }
    }

    public static func platform(fromPlatformIdentifier id: String) -> SimPlatform? {
        SimPlatform.allCases.first { $0.platformIdentifier == id }
    }

    public static func sorted(_ list: [SimRuntimeRecord]) -> [SimRuntimeRecord] {
        list.sorted { a, b in
            if a.platform != b.platform { return a.platform < b.platform }
            let c = SimRuntimeRecord.compareVersions(a.version, b.version)
            if c != .orderedSame { return c == .orderedDescending }
            return a.build > b.build
        }
    }

    static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let i = v as? Int { return Int64(i) }
        return nil
    }
}

// MARK: - Bundles and RuntimeRoots (§8.3)

/// What a file or folder the user picked is.
public enum RuntimeFileKind: Sendable, Equatable {
    /// A runtime disk image (`.dmg`): on a Mac it is handed to `simctl
    /// runtime add` or `xcodebuild -importPlatform` (Ycode does not open it).
    case diskImage
    /// A `.simruntime` bundle.
    case bundle
    /// A bare RuntimeRoot, or a folder whose `RuntimeRoot` is one.
    case runtimeRoot
    case unknown
}

public enum RuntimeBundleReader {
    public static let systemVersionPath = "System/Library/CoreServices/SystemVersion.plist"

    /// Classifies a path by looking at it (no file is changed).
    public static func kind(of path: String, fileManager fm: FileManager = .default) -> RuntimeFileKind {
        if path.lowercased().hasSuffix(".dmg") { return .diskImage }
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { return .unknown }
        if fm.fileExists(atPath: path + "/Contents/Info.plist") && fm.fileExists(atPath: path + "/Contents/Resources/RuntimeRoot") { return .bundle }
        if fm.fileExists(atPath: path + "/" + systemVersionPath) || fm.fileExists(atPath: path + "/RuntimeRoot/" + systemVersionPath) { return .runtimeRoot }
        return .unknown
    }

    /// The RuntimeRoot inside a bundle, a folder holding one, or the root itself.
    public static func runtimeRoot(of path: String, fileManager fm: FileManager = .default) -> String? {
        for candidate in [path + "/Contents/Resources/RuntimeRoot", path + "/RuntimeRoot", path]
        where fm.fileExists(atPath: candidate + "/" + systemVersionPath) {
            return candidate
        }
        return nil
    }

    /// Reads a bundle or RuntimeRoot: platform, version and build from
    /// `SystemVersion.plist`, the identifier from the bundle's `Info.plist`
    /// (or the folder's Ycode marker), the size from the files on disk when
    /// `measure` is set. Nil when it is not a runtime.
    public static func read(_ path: String, location: RuntimeLocation = .thisMachine, owner: RuntimeOwner? = nil, measure: Bool = false,
                            fileManager fm: FileManager = .default) -> SimRuntimeRecord? {
        guard let root = runtimeRoot(of: path, fileManager: fm),
              let sv = fm.contents(atPath: root + "/" + systemVersionPath) else { return nil }
        let info = fm.contents(atPath: path + "/Contents/Info.plist")
        let profile = fm.contents(atPath: path + "/Contents/Resources/profile.plist")
        guard var r = record(systemVersion: sv, info: info, profile: profile, location: location, owner: owner ?? .coreSimulator) else { return nil }
        r.runtimeRoot = root
        if let m = fm.contents(atPath: path + "/" + RuntimeFolders.marker), let marker = try? JSONDecoder().decode(RuntimeMarker.self, from: m) {
            r.identifier = r.identifier ?? marker.identifier
            r.unpackedBytes = marker.sizeBytes
        }
        if measure { r.unpackedBytes = directorySize(root, fileManager: fm) }
        return r
    }

    /// A record from the property lists' bytes (a host's files arrive this way).
    public static func record(systemVersion: Data, info: Data? = nil, profile: Data? = nil, location: RuntimeLocation, owner: RuntimeOwner) -> SimRuntimeRecord? {
        guard let sv = plist(systemVersion), let name = sv["ProductName"] as? String, let version = sv["ProductVersion"] as? String else { return nil }
        let infoP = info.flatMap(plist)
        let profileP = profile.flatMap(plist)
        let platform = (profileP?["platformIdentifier"] as? String).flatMap(SimctlRuntimeListing.platform(fromPlatformIdentifier:))
            ?? SimPlatform(name: name) ?? .iOS
        let archs = profileP?["supportedArchs"] as? [String] ?? ["arm64"]
        return SimRuntimeRecord(platform: platform, version: version, build: sv["ProductBuildVersion"] as? String ?? "",
                                identifier: infoP?["CFBundleIdentifier"] as? String, architectures: archs, location: location, owner: owner)
    }

    static func plist(_ d: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
    }

    /// Bytes of regular files under a folder (symbolic links not followed).
    public static func directorySize(_ path: String, fileManager fm: FileManager = .default) -> Int64 {
        guard let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    /// Ycode's runtimes in a folder on this machine: each subfolder with a
    /// marker and a RuntimeRoot (a `.incoming` one is a copy in progress
    /// and is not listed).
    public static func ycodeRuntimes(in folder: String, fileManager fm: FileManager = .default) -> [SimRuntimeRecord] {
        let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        return SimctlRuntimeListing.sorted(names.compactMap { n in
            guard !n.hasPrefix("."), !n.hasSuffix(RuntimeFolders.incomingSuffix) else { return nil }
            let p = folder + "/" + n
            guard fm.fileExists(atPath: p + "/" + RuntimeFolders.marker) else { return nil }
            return read(p, owner: .ycode(folder: p))
        })
    }
}
