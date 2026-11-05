// Apple's downloadable index and the selection rule
// (`specs/simulator/runtime-downloads.md` §1–§3): which simulator runtimes
// exist, which one fits a platform, build, version or SDK on an arm64 host,
// and the Metal Toolchain entries. The index is a public property list; Ycode
// fetches it for the user who asked (route B) and keeps one copy in its own
// folder for the refresh interval. Portable (macOS and Linux).

import Foundation

extension SimPlatform {
    /// The device platform the index names (`com.apple.platform.iphoneos`, §2.1).
    public var devicePlatformIdentifier: String {
        switch self {
        case .iOS: "com.apple.platform.iphoneos"
        case .watchOS: "com.apple.platform.watchos"
        case .tvOS: "com.apple.platform.appletvos"
        case .visionOS: "com.apple.platform.xros"
        }
    }

    /// The MobileAsset type of its runtimes (§4.1).
    public var assetType: String {
        switch self {
        case .iOS: "com.apple.MobileAsset.iOSSimulatorRuntime"
        case .watchOS: "com.apple.MobileAsset.watchOSSimulatorRuntime"
        case .tvOS: "com.apple.MobileAsset.appleTVOSSimulatorRuntime"
        case .visionOS: "com.apple.MobileAsset.xrOSSimulatorRuntime"
        }
    }

    /// The SDK canonical-name prefix of the device platform (`iphoneos27.1`).
    public var sdkPrefix: String {
        switch self {
        case .iOS: "iphoneos"
        case .watchOS: "watchos"
        case .tvOS: "appletvos"
        case .visionOS: "xros"
        }
    }

    public static func fromDevicePlatform(_ id: String) -> SimPlatform? {
        allCases.first { $0.devicePlatformIdentifier == id }
    }
}

/// One runtime in the index (`downloadables[]`, §2.1).
public struct RuntimeIndexEntry: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var identifier: String
    public var name: String
    public var platform: SimPlatform
    /// Four parts; the fourth is the beta number (0 = release).
    public var fullVersion: String
    /// `simulatorVersion.version` ("27.1").
    public var version: String
    /// `simulatorVersion.buildUpdate`: the key (§2.1).
    public var build: String
    /// Absent on old entries (the universal/x86 kind).
    public var architectures: [String]?
    public var contentType: String
    public var downloadMethod: String?
    public var authentication: String?
    public var fileSize: Int64
    public var minXcodeVersion: String?
    public var maxXcodeVersion: String?
    public var minHostVersion: String?
    public var maxHostVersion: String?
    public var excludedHostArchitectures: [String]?

    public var id: String { "\(platform.rawValue)|\(build)|\((architectures ?? []).joined(separator: ","))" }

    /// The beta number, 0 for a release.
    public var betaNumber: Int {
        let parts = fullVersion.split(separator: ".")
        return parts.count >= 4 ? Int(parts[3]) ?? 0 : 0
    }
    public var isRelease: Bool { betaNumber == 0 }
    /// Fetched through MobileAsset (no Apple sign-in).
    public var isMobileAsset: Bool { downloadMethod == "mobileAsset" }
    /// A legacy entry that needs Apple's developer sign-in: listed, never fetched (§1, §6.4).
    public var needsSignIn: Bool { !isMobileAsset }

    /// "tvOS 27.2 (24K150)", with "beta 3" for betas.
    public var title: String { "\(platform.title) \(version)\(isRelease ? "" : " beta \(betaNumber)") (\(build))" }
}

/// A component (`otherDownloadables[]`, §2.3), e.g. the Metal Toolchain.
public struct RuntimeComponentEntry: Sendable, Equatable, Codable {
    public var assetType: String
    public var identifier: String
    public var name: String
    public var build: String
    public var fileSize: Int64
    public var downloadMethod: String?

    /// The MobileAsset type of a component (`metalToolchain` → `com.apple.MobileAsset.MetalToolchain`).
    public var mobileAssetType: String? { assetType == "metalToolchain" ? "com.apple.MobileAsset.MetalToolchain" : nil }
}

/// `sdkToSimulatorMappings[]` (§2.2).
public struct RuntimeSDKMapping: Sendable, Equatable, Codable {
    public var sdkIdentifier: String
    public var sdkBuild: String
    public var simulatorBuild: String
    /// `preferred`, `available`, `unavailable`; absent means available.
    public var affinity: String
}

/// `xcodeToOtherDownloadablesMappings[]` (§2.3).
public struct RuntimeComponentMapping: Sendable, Equatable, Codable {
    public var assetType: String
    public var assetBuild: String
    public var xcodeBuild: String?
    public var affinity: String
}

public struct RuntimeIndex: Sendable, Equatable {
    public static let url = URL(string: "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex")!

    public var refreshInterval: TimeInterval
    public var runtimes: [RuntimeIndexEntry]
    public var sdkMappings: [RuntimeSDKMapping]
    public var components: [RuntimeComponentEntry]
    public var componentMappings: [RuntimeComponentMapping]

    public init(refreshInterval: TimeInterval = 86400, runtimes: [RuntimeIndexEntry] = [], sdkMappings: [RuntimeSDKMapping] = [],
                components: [RuntimeComponentEntry] = [], componentMappings: [RuntimeComponentMapping] = []) {
        self.refreshInterval = refreshInterval
        self.runtimes = runtimes
        self.sdkMappings = sdkMappings
        self.components = components
        self.componentMappings = componentMappings
    }

    /// Parses the property list (§2). Entries of other categories or
    /// platforms are skipped.
    public static func parse(_ data: Data) throws -> RuntimeIndex {
        guard let top = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw RuntimeDownloadError.badIndex("not a dictionary")
        }
        var index = RuntimeIndex(refreshInterval: TimeInterval(int64(top["refreshInterval"]) ?? 86400))
        for d in top["downloadables"] as? [[String: Any]] ?? [] {
            guard (d["category"] as? String ?? "simulator") == "simulator",
                  let p = (d["platform"] as? String).flatMap(SimPlatform.fromDevicePlatform),
                  let sim = d["simulatorVersion"] as? [String: Any],
                  let version = sim["version"] as? String, let build = sim["buildUpdate"] as? String else { continue }
            let host = d["hostRequirements"] as? [String: Any] ?? [:]
            index.runtimes.append(RuntimeIndexEntry(
                identifier: d["identifier"] as? String ?? "", name: d["name"] as? String ?? "", platform: p,
                fullVersion: d["version"] as? String ?? version, version: version, build: build,
                architectures: d["architectures"] as? [String], contentType: d["contentType"] as? String ?? "",
                downloadMethod: d["downloadMethod"] as? String, authentication: d["authentication"] as? String,
                fileSize: int64(d["fileSize"]) ?? 0,
                minXcodeVersion: host["minXcodeVersion"] as? String, maxXcodeVersion: host["maxXcodeVersion"] as? String,
                minHostVersion: host["minHostVersion"] as? String, maxHostVersion: host["maxHostVersion"] as? String,
                excludedHostArchitectures: host["excludedHostArchitectures"] as? [String]))
        }
        for m in top["sdkToSimulatorMappings"] as? [[String: Any]] ?? [] {
            guard let sdk = m["sdkBuildUpdate"] as? String, let sim = m["simulatorBuildUpdate"] as? String else { continue }
            index.sdkMappings.append(RuntimeSDKMapping(sdkIdentifier: m["sdkIdentifier"] as? String ?? "", sdkBuild: sdk, simulatorBuild: sim,
                                                       affinity: m["affinity"] as? String ?? "available"))
        }
        for c in top["otherDownloadables"] as? [[String: Any]] ?? [] {
            guard let type = c["assetType"] as? String, let build = c["assetBuildUpdate"] as? String else { continue }
            index.components.append(RuntimeComponentEntry(assetType: type, identifier: c["identifier"] as? String ?? "", name: c["name"] as? String ?? "",
                                                          build: build, fileSize: int64(c["fileSizeBytes"]) ?? 0, downloadMethod: c["downloadMethod"] as? String))
        }
        for m in top["xcodeToOtherDownloadablesMappings"] as? [[String: Any]] ?? [] {
            guard let type = m["assetType"] as? String, let build = m["assetBuildUpdate"] as? String else { continue }
            index.componentMappings.append(RuntimeComponentMapping(assetType: type, assetBuild: build, xcodeBuild: m["xcodeBuildUpdate"] as? String,
                                                                   affinity: m["affinity"] as? String ?? "available"))
        }
        return index
    }

    static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let i = v as? Int { return Int64(i) }
        return nil
    }

    /// The Metal Toolchain for an Xcode build (§2.3), else the newest one.
    public func metalToolchain(build: String? = nil, xcodeBuild: String? = RuntimeSelection.parityXcodeBuild) -> RuntimeComponentEntry? {
        let all = components.filter { $0.assetType == "metalToolchain" && $0.downloadMethod == "mobileAsset" }
        if let build { return all.first { $0.build == build } }
        if let xcodeBuild, let m = componentMappings.first(where: { $0.assetType == "metalToolchain" && $0.xcodeBuild == xcodeBuild }) {
            return all.first { $0.build == m.assetBuild }
        }
        return all.last
    }
}

/// What the user asked for (§3's input).
public struct RuntimeRequest: Sendable, Equatable {
    public var platform: SimPlatform
    public var build: String?
    public var version: String?
    /// Ycode's chosen SDK build, when one is known.
    public var sdkBuild: String?
    /// Always arm64 (§3 step 4, Ycode decision).
    public var architecture: String = "arm64"

    public init(platform: SimPlatform, build: String? = nil, version: String? = nil, sdkBuild: String? = nil) {
        self.platform = platform
        self.build = build
        self.version = version
        self.sdkBuild = sdkBuild
    }
}

/// The host facts the selection looks at (§3 step 5).
public struct RuntimeSelectionHost: Sendable, Equatable {
    /// The Xcode version Ycode declares parity with.
    public var xcodeVersion: String
    /// The macOS version on a Mac; nil on Linux (host versions are then ignored).
    public var macOSVersion: String?
    public var architecture: String

    public init(xcodeVersion: String = RuntimeSelection.parityXcodeVersion, macOSVersion: String? = nil, architecture: String = "arm64") {
        self.xcodeVersion = xcodeVersion
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    public static var current: RuntimeSelectionHost {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return RuntimeSelectionHost(macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", architecture: SetupMachine.current.architecture)
        #else
        return RuntimeSelectionHost(macOSVersion: nil, architecture: SetupMachine.current.architecture)
        #endif
    }
}

public enum RuntimeSelection {
    /// Xcode 27.1 (27A9269), the reference Ycode matches.
    public static let parityXcodeVersion = "27.1"
    public static let parityXcodeBuild = "27A9269"

    /// The runtimes the platform offers that Ycode can fetch: MobileAsset
    /// entries, arm64-only (§3 steps 1 and 4), not excluded by the host
    /// (step 5). Newest first.
    public static func candidates(_ index: RuntimeIndex, platform: SimPlatform, host: RuntimeSelectionHost = RuntimeSelectionHost()) -> [RuntimeIndexEntry] {
        sorted(index.runtimes.filter { e in
            e.platform == platform && e.isMobileAsset && e.architectures == ["arm64"] && fits(e, host: host)
        })
    }

    /// Entries Ycode lists but cannot fetch (legacy, signed-in downloads).
    public static func signInOnly(_ index: RuntimeIndex, platform: SimPlatform) -> [RuntimeIndexEntry] {
        sorted(index.runtimes.filter { $0.platform == platform && $0.needsSignIn })
    }

    /// Step 5: the host requirements.
    public static func fits(_ e: RuntimeIndexEntry, host: RuntimeSelectionHost) -> Bool {
        let cmp = SimRuntimeRecord.compareVersions
        if let min = e.minXcodeVersion, cmp(host.xcodeVersion, min) == .orderedAscending { return false }
        if let max = e.maxXcodeVersion, cmp(host.xcodeVersion, max) == .orderedDescending { return false }
        if let mac = host.macOSVersion {
            if let min = e.minHostVersion, cmp(mac, min) == .orderedAscending { return false }
            if let max = e.maxHostVersion, cmp(mac, max) == .orderedDescending { return false }
        }
        if let excluded = e.excludedHostArchitectures, excluded.contains(host.architecture) { return false }
        return true
    }

    /// The selection rule (§3): a build, else a version, else the SDK's
    /// mapping (preferred, then available, never unavailable), else the
    /// highest release; ties go to the highest build.
    public static func select(_ index: RuntimeIndex, _ r: RuntimeRequest, host: RuntimeSelectionHost = RuntimeSelectionHost()) throws -> RuntimeIndexEntry {
        let all = candidates(index, platform: r.platform, host: host)
        if let build = r.build {
            if let e = all.first(where: { $0.build == build }) { return e }
            if index.runtimes.contains(where: { $0.platform == r.platform && $0.build == build && $0.needsSignIn }) {
                throw RuntimeDownloadError.needsSignIn("\(r.platform.title) \(build)")
            }
            throw RuntimeDownloadError.noRuntime("Apple's index has no arm64 \(r.platform.title) runtime with build \(build) for Xcode \(host.xcodeVersion).")
        }
        if let version = r.version {
            let v = all.filter { SimRuntimeRecord.compareVersions($0.version, version) == .orderedSame }
            if let best = v.first(where: \.isRelease) ?? v.first { return best }
            throw RuntimeDownloadError.noRuntime("Apple's index has no arm64 \(r.platform.title) \(version) runtime for Xcode \(host.xcodeVersion).")
        }
        if let sdk = r.sdkBuild {
            let rows = index.sdkMappings.filter { $0.sdkBuild == sdk && $0.affinity != "unavailable" }
            for affinity in ["preferred", "available"] {
                let builds = Set(rows.filter { $0.affinity == affinity }.map(\.simulatorBuild))
                if let e = all.first(where: { builds.contains($0.build) }) { return e }
            }
        }
        if let e = all.first(where: \.isRelease) { return e }
        throw RuntimeDownloadError.noRuntime("Apple's index lists no arm64 \(r.platform.title) runtime that Ycode can fetch.")
    }

    /// Newest version first; a release before its betas, later betas
    /// first; then the highest build.
    public static func sorted(_ list: [RuntimeIndexEntry]) -> [RuntimeIndexEntry] {
        list.sorted { a, b in
            let c = SimRuntimeRecord.compareVersions(a.version, b.version)
            if c != .orderedSame { return c == .orderedDescending }
            let ra = a.isRelease ? Int.max : a.betaNumber, rb = b.isRelease ? Int.max : b.betaNumber
            if ra != rb { return ra > rb }
            return a.build > b.build
        }
    }
}

/// The index on disk (§6.2 step 1): one copy for this user, refreshed after
/// `refreshInterval` with the ETag (an unchanged index costs a 304).
public struct RuntimeIndexCache: Sendable {
    public var folder: String
    public init(folder: String) { self.folder = folder }

    var directory: String { folder + "/.index" }
    var file: String { directory + "/index2.dvtdownloadableindex" }
    var metaFile: String { directory + "/meta.json" }

    struct Meta: Codable {
        var etag: String?
        var fetchedAt: Date
        var refreshInterval: TimeInterval
    }

    /// The index: the cached copy while fresh, else a conditional GET.
    public func load(transport: any RuntimeTransport, now: Date = Date(), force: Bool = false) async throws -> RuntimeIndex {
        let fm = FileManager.default
        let meta = fm.contents(atPath: metaFile).flatMap { try? JSONDecoder.iso.decode(Meta.self, from: $0) }
        let cached = fm.contents(atPath: file)
        if !force, let meta, let cached, now.timeIntervalSince(meta.fetchedAt) < meta.refreshInterval, let i = try? RuntimeIndex.parse(cached) {
            return i
        }
        let r = try await transport.get(RuntimeIndex.url, etag: cached == nil ? nil : meta?.etag)
        let data: Data
        if r.status == 304, let cached { data = cached }
        else if r.status == 200 { data = r.body }
        else { throw RuntimeDownloadError.network("Apple's runtime index answered HTTP \(r.status).") }
        let index = try RuntimeIndex.parse(data)
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if r.status == 200 { try data.write(to: URL(fileURLWithPath: file), options: .atomic) }
        let m = Meta(etag: r.etag ?? meta?.etag, fetchedAt: now, refreshInterval: index.refreshInterval)
        try JSONEncoder.iso.encode(m).write(to: URL(fileURLWithPath: metaFile), options: .atomic)
        return index
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
