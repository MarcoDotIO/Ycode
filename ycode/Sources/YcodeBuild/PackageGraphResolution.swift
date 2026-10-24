import Foundation
import YcodeProject

/// Transitive resolution and `Package.resolved` version 3. See
/// `specs/ide/package-dependencies.md` §Resolution.
extension PackageResolver {
    /// A dependency a package manifest declares.
    public struct ManifestDependency: Equatable, Sendable {
        public var location: String
        public var requirement: SwiftPackageRequirement
    }

    /// Remote dependencies from `swift package dump-package` (file-system
    /// dependencies are not followed yet).
    public static func dependencies(ofPackageAt dir: URL) throws -> [ManifestDependency] {
        let json = try run("/usr/bin/env", ["swift", "package", "--package-path", dir.path, "dump-package"], in: nil)
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        return (obj["dependencies"] as? [[String: Any]] ?? []).compactMap { d in
            guard let sc = (d["sourceControl"] as? [[String: Any]])?.first,
                  let loc = sc["location"] as? [String: Any] else { return nil }
            let remote = loc["remote"] as? [Any]
            // `local`: a repository on disk (a file URL in the manifest).
            let url = (remote?.first as? [String: Any])?["urlString"] as? String ?? remote?.first as? String
                ?? (loc["local"] as? [String])?.first
            guard let url, let req = sc["requirement"] as? [String: Any] else { return nil }
            let r: SwiftPackageRequirement
            if let range = (req["range"] as? [[String: Any]])?.first,
               let lo = range["lowerBound"] as? String, let hi = range["upperBound"] as? String {
                r = .range(from: lo, to: hi)
            } else if let v = (req["exact"] as? [String])?.first {
                r = .exact(v)
            } else if let b = (req["branch"] as? [String])?.first {
                r = .branch(b)
            } else if let rev = (req["revision"] as? [String])?.first {
                r = .revision(rev)
            } else { return nil }
            return ManifestDependency(location: url, requirement: r)
        }
    }

    /// A requirement as a half-open version interval (nil for branch/revision).
    static func interval(_ r: SwiftPackageRequirement) -> (lo: Version, hi: Version)? {
        switch r {
        case .upToNextMajor(let v):
            guard let lo = Version(v) else { return nil }
            return (lo, Version("\(lo.major + 1).0.0")!)
        case .upToNextMinor(let v):
            guard let lo = Version(v) else { return nil }
            return (lo, Version("\(lo.major).\(lo.minor + 1).0")!)
        case .exact(let v):
            guard let lo = Version(v) else { return nil }
            return (lo, Version("\(lo.major).\(lo.minor).\(lo.patch + 1)")!)
        case .range(let a, let b):
            guard let lo = Version(a), let hi = Version(b) else { return nil }
            return (lo, hi)
        case .branch, .revision: return nil
        }
    }

    /// Resolves the project's packages and everything they depend on. Each
    /// package gets the highest version every requirement on it allows;
    /// when none does, or a branch/commit meets a version rule, resolution
    /// fails naming the requirements.
    public func resolveGraph(_ roots: [(url: String, requirement: SwiftPackageRequirement)]) throws -> [Pin] {
        struct Constraint { var requirement: SwiftPackageRequirement; var from: String }
        var constraints: [String: [Constraint]] = [:]
        var locations: [String: String] = [:]
        var pins: [String: Pin] = [:]
        var queue: [String] = []
        func add(_ url: String, _ r: SwiftPackageRequirement, from: String) {
            let id = Self.identity(of: url)
            if locations[id] == nil { locations[id] = url }
            constraints[id, default: []].append(Constraint(requirement: r, from: from))
            if !queue.contains(id) { queue.append(id) }
        }
        for r in roots { add(r.url, r.requirement, from: "the project") }
        var rounds = 0
        while let id = queue.first {
            queue.removeFirst()
            rounds += 1
            guard rounds < 500 else { throw ResolveError("Dependency resolution did not settle") }
            let cs = constraints[id] ?? []
            let describe = cs.map { "\($0.from) requires \($0.requirement.summary)" }.joined(separator: "; ")
            let refs = cs.compactMap { c -> SwiftPackageRequirement? in Self.interval(c.requirement) == nil ? c.requirement : nil }
            let effective: SwiftPackageRequirement
            if let first = refs.first {
                guard refs.allSatisfy({ $0 == first }), refs.count == cs.count else {
                    throw ResolveError("Dependencies could not be resolved: \(id): \(describe)")
                }
                effective = first
            } else {
                var lo = Version("0.0.0")!, hi = Version("999999.0.0")!
                for c in cs { let i = Self.interval(c.requirement)!; lo = max(lo, i.lo); hi = min(hi, i.hi) }
                guard lo < hi else { throw ResolveError("Dependencies could not be resolved: \(id): \(describe)") }
                let versions = try Self.availableVersions(url: locations[id]!)
                guard let pick = versions.last(where: { $0.0 >= lo && $0.0 < hi && ($0.0.prerelease.isEmpty || !lo.prerelease.isEmpty) }) else {
                    throw ResolveError("Dependencies could not be resolved: no version of \(id) satisfies \(describe)")
                }
                if let existing = pins[id], existing.version == pick.0.description { continue }
                effective = .exact(pick.tag)
            }
            let pin = try resolve(url: locations[id]!, requirement: effective)
            pins[id] = pin
            for d in try Self.dependencies(ofPackageAt: pin.checkout) { add(d.location, d.requirement, from: "\(id) \(pin.version ?? pin.branch ?? "")") }
        }
        return pins.values.sorted { $0.identity < $1.identity }
    }

    /// `originHash` for `Package.resolved` version 3: SHA-256 (lowercase
    /// hex) of the root manifests' contents followed by the root
    /// dependencies' location strings, as SwiftPM's open source defines it.
    /// An Xcode project has no root manifest, so only the locations count
    /// (an OPEN QUESTION in the spec).
    public static func originHash(rootManifests: [String] = [], rootLocations: [String]) -> String {
        SHA256.hex(Array((rootManifests.joined() + rootLocations.joined()).utf8))
    }

    /// `Package.resolved` version 3: `originHash`, then the pins.
    public static func resolvedFileV3(_ pins: [Pin], originHash: String) -> Data {
        let list: [[String: Any]] = pins.sorted { $0.identity < $1.identity }.map { p in
            var state: [String: Any] = ["revision": p.revision]
            if let v = p.version { state["version"] = v }
            if let b = p.branch { state["branch"] = b }
            return ["identity": p.identity, "kind": "remoteSourceControl", "location": p.location, "state": state]
        }
        let obj: [String: Any] = ["originHash": originHash, "pins": list, "version": 3]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }
}

/// A small SHA-256 (FIPS 180-4), so the hash is the same on every platform
/// without extra dependencies.
enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ message: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bitLength = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for t in 0..<16 {
                let b = chunk + t * 4
                w[t] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for t in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[t] &+ w[t]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
