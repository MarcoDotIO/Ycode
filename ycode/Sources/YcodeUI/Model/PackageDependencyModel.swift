import Foundation
import YcodeBuild
import YcodeProject

/// Adding, listing and resolving a project's package dependencies. See
/// `specs/ide/package-dependencies.md`.
public struct PackageDependencyModel: Sendable {
    public var proj: PBXProj
    public let xcodeprojURL: URL
    public var resolver: PackageResolver
    /// The last resolution's pins, by package identity.
    public private(set) var pins: [String: PackageResolver.Pin] = [:]

    public init(proj: PBXProj, xcodeprojURL: URL, checkoutsDirectory: URL? = nil) {
        self.proj = proj
        self.xcodeprojURL = xcodeprojURL
        resolver = PackageResolver(checkoutsDirectory: checkoutsDirectory ?? Self.defaultCheckouts(for: xcodeprojURL))
    }

    /// `~/Library/Caches/Ycode/SourcePackages/<project>-<hash>/checkouts`.
    public static func defaultCheckouts(for xcodeprojURL: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var h: UInt64 = 1469598103934665603
        for b in xcodeprojURL.standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let name = xcodeprojURL.deletingPathExtension().lastPathComponent + "-" + String(h, radix: 36)
        return caches.appendingPathComponent("Ycode/SourcePackages/\(name)/checkouts")
    }

    public var projectDirectory: URL { proj.projectDirectory(xcodeprojURL: xcodeprojURL) }

    /// Whether the text typed in the sheet is a local path (absolute,
    /// `~`, `./`, `../`, or an existing folder) rather than a URL.
    public static func isLocalPath(_ s: String) -> Bool {
        if s.hasPrefix("file://") { return false }
        return s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix(".") || !s.contains("://") && !s.contains("@")
    }

    /// A path relative to the project directory, written with `../` steps.
    public func relativePath(to url: URL) -> String {
        let base = projectDirectory.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        var i = 0
        while i < min(base.count, target.count) && base[i] == target[i] { i += 1 }
        let parts = Array(repeating: "..", count: base.count - i) + target[i...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Adds a package and returns its products: a remote one is resolved
    /// (cloned and checked out) first; a local one is read in place.
    public mutating func addPackage(_ location: String, requirement: SwiftPackageRequirement) throws -> (id: String, products: [String]) {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        if Self.isLocalPath(trimmed) {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, relativeTo: projectDirectory).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) else {
                throw PackageResolver.ResolveError("No Package.swift in \(url.path)")
            }
            let products = try PackageResolver.products(ofPackageAt: url)
            let id = proj.addLocalPackage(relativePath: relativePath(to: url))
            return (id, products)
        }
        let pin = try resolver.resolve(url: trimmed, requirement: requirement)
        let products = try PackageResolver.products(ofPackageAt: pin.checkout)
        pins[pin.identity] = pin
        let id = proj.addRemotePackage(url: trimmed, requirement: requirement)
        return (id, products)
    }

    /// Links products into a target (by name).
    public mutating func link(_ products: [String], package: String, target name: String) {
        guard let t = proj.targets.first(where: { $0.string("name") == name }) else { return }
        for p in products { proj.addPackageProduct(p, package: package, toTarget: t.id) }
    }

    /// Resolves every remote package and writes `Package.resolved`.
    @discardableResult
    public mutating func resolveAll() throws -> [PackageResolver.Pin] {
        let all = try resolver.resolveAndWrite(proj, xcodeprojURL: xcodeprojURL)
        for p in all { pins[p.identity] = p }
        return all
    }

    /// Versions recorded in `Package.resolved`, by identity.
    public func recordedVersions() -> [String: String] {
        guard let data = try? Data(contentsOf: PackageResolver.resolvedFileURL(xcodeprojURL: xcodeprojURL)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["pins"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for p in list {
            guard let id = p["identity"] as? String, let st = p["state"] as? [String: Any] else { continue }
            // Only a resolved version; branch- or revision-pinned packages show none (package-dependencies.md).
            if let v = st["version"] as? String { out[id] = v }
        }
        return out
    }

    /// One row of the Package Dependencies tab.
    public struct Row: Equatable, Sendable {
        public var id: String
        public var name: String
        public var location: String
        public var rule: String
        public var products: [String]
    }

    public var rows: [Row] {
        proj.packageReferences.map { ref in
            let products = proj.objects.values.filter { $0.isa == "XCSwiftPackageProductDependency" && $0.string("package") == ref.id }
                .compactMap { $0.string("productName") }.sorted()
            switch ref.location {
            case .remote(let url, let r): return Row(id: ref.id, name: ref.displayName, location: url, rule: r?.summary ?? "", products: products)
            case .local(let p): return Row(id: ref.id, name: ref.displayName, location: p, rule: "Local", products: products)
            }
        }
    }

    /// The navigator's Package Dependencies section: one row per package
    /// (name and resolved version), listing its checkout or local folder.
    public func navigatorSection() -> NavigatorNode? {
        let refs = proj.packageReferences
        guard !refs.isEmpty else { return nil }
        let versions = recordedVersions()
        let kids = refs.map { ref -> NavigatorNode in
            switch ref.location {
            case .remote(let url, _):
                let id = PackageResolver.identity(of: url)
                let dir = pins[id]?.checkout ?? resolver.checkoutsDirectory.appendingPathComponent(id)
                let name = ref.displayName + (versions[id].map { " " + $0 } ?? "")
                let exists = FileManager.default.fileExists(atPath: dir.path)
                return NavigatorNode(name: name, kind: .container, path: exists ? dir.path : nil, objectID: ref.id,
                                     children: exists ? NavigatorTree.directory(dir.path) : [])
            case .local(let p):
                let dir = projectDirectory.appendingPathComponent(p).standardizedFileURL
                return NavigatorNode(name: ref.displayName, kind: .container, path: dir.path, objectID: ref.id,
                                     children: NavigatorTree.directory(dir.path))
            }
        }
        return NavigatorNode(name: "Package Dependencies", kind: .group, path: nil, children: kids)
    }
}
