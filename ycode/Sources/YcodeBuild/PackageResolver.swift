import Foundation
import YcodeProject
import YcodeSubprocess

/// Resolves a project's Swift package references with git and SwiftPM's
/// public command line, and writes `Package.resolved`. See
/// `specs/ide/package-dependencies.md` §Resolution.
public struct PackageResolver: Sendable {
    public struct ResolveError: Error, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    /// A semantic version `major.minor.patch` (pre-release/build text kept
    /// for display; pre-releases sort before their release).
    public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        public var major: Int, minor: Int, patch: Int
        public var prerelease: String
        public init?(_ text: String) {
            var t = Substring(text)
            if t.hasPrefix("v") { t = t.dropFirst() }
            let core = t.split(separator: "-", maxSplits: 1)
            let nums = core.first?.split(separator: ".").map { Int($0) } ?? []
            guard (1...3).contains(nums.count), nums.allSatisfy({ $0 != nil }) else { return nil }
            major = nums[0]!; minor = nums.count > 1 ? nums[1]! : 0; patch = nums.count > 2 ? nums[2]! : 0
            prerelease = core.count > 1 ? String(core[1]) : ""
        }
        public var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-\(prerelease)") }
        public static func < (a: Self, b: Self) -> Bool {
            if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
            if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
            return a.prerelease < b.prerelease
        }
    }

    /// One entry of `Package.resolved`.
    public struct Pin: Equatable, Sendable {
        public var identity: String
        public var location: String
        public var revision: String
        public var version: String?
        public var branch: String?
        public var checkout: URL
    }

    /// Where checkouts go (`<DerivedData>/<project>/SourcePackages/checkouts`).
    public var checkoutsDirectory: URL

    public init(checkoutsDirectory: URL) { self.checkoutsDirectory = checkoutsDirectory }

    // MARK: Versions

    /// Tag names that are versions, from `git ls-remote --tags`.
    public static func availableVersions(url: String) throws -> [(Version, tag: String)] {
        let out = try git(["ls-remote", "--tags", url], in: nil)
        var seen = Set<String>()
        return out.split(separator: "\n").compactMap { line -> (Version, String)? in
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/") else { return nil }
            var tag = String(ref.dropFirst("refs/tags/".count))
            if tag.hasSuffix("^{}") { tag.removeLast(3) }
            guard seen.insert(tag).inserted, let v = Version(tag) else { return nil }
            return (v, tag)
        }.sorted { $0.0 < $1.0 }
    }

    /// The highest version the rule allows, ignoring pre-releases unless
    /// the rule names one.
    public static func select(_ r: SwiftPackageRequirement, from versions: [(Version, tag: String)]) -> (Version, tag: String)? {
        func ok(_ v: Version) -> Bool {
            switch r {
            case .upToNextMajor(let m):
                guard let lo = Version(m) else { return false }
                return v >= lo && v.major == lo.major && (v.prerelease.isEmpty || !lo.prerelease.isEmpty)
            case .upToNextMinor(let m):
                guard let lo = Version(m) else { return false }
                return v >= lo && v.major == lo.major && v.minor == lo.minor && (v.prerelease.isEmpty || !lo.prerelease.isEmpty)
            case .exact(let e): return Version(e) == v
            case .range(let a, let b):
                guard let lo = Version(a), let hi = Version(b) else { return false }
                return v >= lo && v < hi && v.prerelease.isEmpty
            case .branch, .revision: return false
            }
        }
        return versions.last { ok($0.0) }
    }

    // MARK: Resolution

    /// Package identity: the lowercased last URL/path component without `.git`.
    public static func identity(of location: String) -> String {
        var last = location.split(separator: "/").last.map(String.init) ?? location
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.lowercased()
    }

    /// Clones (or updates) a remote package and checks out what the rule selects.
    public func resolve(url: String, requirement: SwiftPackageRequirement) throws -> Pin {
        let id = Self.identity(of: url)
        let dir = checkoutsDirectory.appendingPathComponent(id)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            _ = try Self.git(["fetch", "--tags", "--force", "origin"], in: dir)
        } else {
            try fm.createDirectory(at: checkoutsDirectory, withIntermediateDirectories: true)
            _ = try Self.git(["clone", "--quiet", url, dir.path], in: nil)
        }
        var version: String?, branch: String?
        let ref: String
        switch requirement {
        case .branch(let b): ref = "origin/\(b)"; branch = b
        case .revision(let r): ref = r
        default:
            guard let (v, tag) = Self.select(requirement, from: try Self.availableVersions(url: url)) else {
                throw ResolveError("No version of \(id) matches \(requirement.summary)")
            }
            ref = "refs/tags/\(tag)"; version = v.description
        }
        _ = try Self.git(["checkout", "--quiet", "--detach", ref], in: dir)
        let rev = try Self.git(["rev-parse", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        return Pin(identity: id, location: url, revision: rev, version: version, branch: branch, checkout: dir)
    }

    /// The project's remote references as resolution roots.
    public static func roots(of proj: PBXProj) -> [(url: String, requirement: SwiftPackageRequirement)] {
        proj.packageReferences.compactMap { ref in
            guard case .remote(let url, let r) = ref.location else { return nil }
            return (url, r ?? .branch("main"))
        }
    }

    /// Resolves every remote reference of a project and their dependencies.
    /// Local packages need no pin.
    public func resolve(_ proj: PBXProj) throws -> [Pin] {
        try resolveGraph(Self.roots(of: proj))
    }

    /// Product names a package declares, from `swift package dump-package`.
    public static func products(ofPackageAt dir: URL) throws -> [String] {
        let json = try run("/usr/bin/env", ["swift", "package", "--package-path", dir.path, "dump-package"], in: nil)
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let products = obj["products"] as? [[String: Any]] else { throw ResolveError("Unreadable manifest at \(dir.path)") }
        return products.compactMap { $0["name"] as? String }
    }

    /// `Package.resolved` (format version 2) for pins, sorted by identity.
    public static func resolvedFile(_ pins: [Pin]) -> Data {
        let list: [[String: Any]] = pins.sorted { $0.identity < $1.identity }.map { p in
            var state: [String: Any] = ["revision": p.revision]
            if let v = p.version { state["version"] = v }
            if let b = p.branch { state["branch"] = b }
            return ["identity": p.identity, "kind": "remoteSourceControl", "location": p.location, "state": state]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["pins": list, "version": 2], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// `<project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
    public static func resolvedFileURL(xcodeprojURL: URL) -> URL {
        xcodeprojURL.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    }

    /// Resolves and writes `Package.resolved` next to the project.
    @discardableResult
    public func resolveAndWrite(_ proj: PBXProj, xcodeprojURL: URL) throws -> [Pin] {
        let pins = try resolve(proj)
        let url = Self.resolvedFileURL(xcodeprojURL: xcodeprojURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hash = Self.originHash(rootLocations: Self.roots(of: proj).map(\.url))
        try Self.resolvedFileV3(pins, originHash: hash).write(to: url, options: .atomic)
        return pins
    }

    // MARK: Processes

    static func git(_ args: [String], in dir: URL?) throws -> String {
        try run("/usr/bin/env", ["git"] + args, in: dir, environment: ["GIT_TERMINAL_PROMPT": "0"])
    }

    static func run(_ exe: String, _ args: [String], in dir: URL?, environment: [String: String] = [:]) throws -> String {
        MainThreadGuard.blockingCall("\(exe) \(args.prefix(2).joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ResolveError("\(args.prefix(3).joined(separator: " ")) failed: \(String(decoding: edata, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
