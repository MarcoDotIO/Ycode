import Foundation
import YcodePlist

/// A remote package's version rule, as stored in the `requirement`
/// dictionary of an `XCRemoteSwiftPackageReference`. See
/// `specs/ide/package-dependencies.md`.
public enum SwiftPackageRequirement: Equatable, Sendable {
    case upToNextMajor(from: String)
    case upToNextMinor(from: String)
    case exact(String)
    case range(from: String, to: String)
    case branch(String)
    case revision(String)

    /// The `kind` value written to the project file.
    public var kind: String {
        switch self {
        case .upToNextMajor: "upToNextMajorVersion"
        case .upToNextMinor: "upToNextMinorVersion"
        case .exact: "exactVersion"
        case .range: "versionRange"
        case .branch: "branch"
        case .revision: "revision"
        }
    }

    /// The menu title of the rule in the Add Package sheet.
    public var ruleTitle: String {
        switch self {
        case .upToNextMajor: "Up to Next Major Version"
        case .upToNextMinor: "Up to Next Minor Version"
        case .exact: "Exact Version"
        case .range: "Range of Versions"
        case .branch: "Branch"
        case .revision: "Commit"
        }
    }

    public var plist: PlistValue {
        var pairs: [(String, PlistValue)] = [("kind", .string(kind))]
        switch self {
        case .upToNextMajor(let v), .upToNextMinor(let v): pairs.append(("minimumVersion", .string(v)))
        case .exact(let v): pairs.append(("version", .string(v)))
        case .range(let a, let b): pairs += [("maximumVersion", .string(b)), ("minimumVersion", .string(a))]
        case .branch(let b): pairs.append(("branch", .string(b)))
        case .revision(let r): pairs.append(("revision", .string(r)))
        }
        return .dictionary(PlistDictionary(pairs))
    }

    public init?(plist: PlistValue?) {
        guard let d = plist?.dictionary, let kind = d["kind"]?.string else { return nil }
        let s = { (k: String) in d[k]?.string ?? "" }
        switch kind {
        case "upToNextMajorVersion": self = .upToNextMajor(from: s("minimumVersion"))
        case "upToNextMinorVersion": self = .upToNextMinor(from: s("minimumVersion"))
        case "exactVersion": self = .exact(s("version"))
        case "versionRange": self = .range(from: s("minimumVersion"), to: s("maximumVersion"))
        case "branch": self = .branch(s("branch"))
        case "revision": self = .revision(s("revision"))
        default: return nil
        }
    }

    /// A short description for the Package Dependencies tab ("1.5.0 – Next Major").
    public var summary: String {
        switch self {
        case .upToNextMajor(let v): "\(v) – Next Major"
        case .upToNextMinor(let v): "\(v) – Next Minor"
        case .exact(let v): v
        case .range(let a, let b): "\(a) – \(b)"
        case .branch(let b): "Branch: \(b)"
        case .revision(let r): "Commit: \(r.prefix(7))"
        }
    }
}

/// One package reference of a project, remote or local.
public struct SwiftPackageReference: Equatable, Sendable {
    public enum Location: Equatable, Sendable {
        case remote(url: String, requirement: SwiftPackageRequirement?)
        case local(relativePath: String)
    }
    public var id: String
    public var location: Location

    /// The name shown in the navigator: the last URL component without
    /// `.git`, or the local folder's name.
    public var displayName: String {
        switch location {
        case .remote(let url, _): PBXProjWriter.repositoryName(url)
        case .local(let p): (p as NSString).lastPathComponent
        }
    }
}

extension PBXProj {
    /// The project's package references in `packageReferences` order.
    public var packageReferences: [SwiftPackageReference] {
        (project?.references("packageReferences") ?? []).compactMap { id in
            guard let o = self[id] else { return nil }
            switch o.isa {
            case "XCRemoteSwiftPackageReference":
                return SwiftPackageReference(id: id, location: .remote(url: o.string("repositoryURL") ?? "",
                                                                       requirement: SwiftPackageRequirement(plist: o["requirement"])))
            case "XCLocalSwiftPackageReference":
                return SwiftPackageReference(id: id, location: .local(relativePath: o.string("relativePath") ?? ""))
            default: return nil
            }
        }
    }

    /// Product dependencies (`XCSwiftPackageProductDependency`) of a target, in order.
    public func packageProducts(ofTarget id: String) -> [(id: String, name: String, package: String?)] {
        (self[id]?.references("packageProductDependencies") ?? []).compactMap { pid in
            guard let o = self[pid] else { return nil }
            return (pid, o.string("productName") ?? "", o.string("package"))
        }
    }

    private mutating func appendReference(_ ref: String, key: String, to owner: String) {
        guard var o = self[owner] else { return }
        o[key] = .array((o[key]?.array ?? []) + [.string(ref)])
        self[owner] = o
    }

    private mutating func removeReference(_ ref: String, key: String, from owner: String, dropEmpty: Bool = false) {
        guard var o = self[owner], o[key] != nil else { return }
        let rest = o.references(key).filter { $0 != ref }
        o[key] = rest.isEmpty && dropEmpty ? nil : .array(rest.map(PlistValue.string))
        self[owner] = o
    }

    /// Adds a language code to the project's `knownRegions` (kept in
    /// order; no-op when present).
    public mutating func addKnownRegion(_ code: String) {
        guard var p = project, !p.references("knownRegions").contains(code) else { return }
        p["knownRegions"] = .array(p.references("knownRegions").map(PlistValue.string) + [.string(code)])
        self[rootObject] = p
    }

    /// Adds an `XCRemoteSwiftPackageReference` to the project's
    /// `packageReferences`. Returns its ID.
    @discardableResult
    public mutating func addRemotePackage(url: String, requirement: SwiftPackageRequirement) -> String {
        let id = makeObjectID()
        self[id] = PBXObject(id: id, attributes: PlistDictionary([
            ("isa", .string("XCRemoteSwiftPackageReference")),
            ("repositoryURL", .string(url)),
            ("requirement", requirement.plist),
        ]))
        appendReference(id, key: "packageReferences", to: rootObject)
        return id
    }

    /// Adds an `XCLocalSwiftPackageReference` (path relative to the
    /// project directory). Returns its ID.
    @discardableResult
    public mutating func addLocalPackage(relativePath: String) -> String {
        let id = makeObjectID()
        self[id] = PBXObject(id: id, attributes: PlistDictionary([
            ("isa", .string("XCLocalSwiftPackageReference")),
            ("relativePath", .string(relativePath)),
        ]))
        appendReference(id, key: "packageReferences", to: rootObject)
        return id
    }

    /// Changes a remote package's version rule.
    public mutating func setRequirement(_ r: SwiftPackageRequirement, ofPackage id: String) {
        guard var o = self[id], o.isa == "XCRemoteSwiftPackageReference" else { return }
        o["requirement"] = r.plist
        self[id] = o
    }

    /// Links a package product into a target: an
    /// `XCSwiftPackageProductDependency` in the target's
    /// `packageProductDependencies`, and a `PBXBuildFile` with `productRef`
    /// in its frameworks phase (created after the sources phase if missing).
    /// Returns the product dependency's ID.
    @discardableResult
    public mutating func addPackageProduct(_ name: String, package: String, toTarget target: String) -> String {
        let id = makeObjectID()
        var attrs: [(String, PlistValue)] = [("isa", .string("XCSwiftPackageProductDependency"))]
        // Written for local packages too (OPEN QUESTION in the spec).
        attrs.append(("package", .string(package)))
        attrs.append(("productName", .string(name)))
        self[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
        appendReference(id, key: "packageProductDependencies", to: target)
        let phase = buildPhases(ofTarget: target).first { $0.isa == "PBXFrameworksBuildPhase" }?.id ?? addFrameworksPhase(to: target)
        let bf = makeObjectID()
        self[bf] = PBXObject(id: bf, attributes: PlistDictionary([("isa", .string("PBXBuildFile")), ("productRef", .string(id))]))
        appendReference(bf, key: "files", to: phase)
        return id
    }

    private mutating func addFrameworksPhase(to target: String) -> String {
        let id = makeObjectID()
        self[id] = PBXObject(id: id, attributes: PlistDictionary([
            ("isa", .string("PBXFrameworksBuildPhase")),
            ("buildActionMask", .string("2147483647")),
            ("files", .array([])),
            ("runOnlyForDeploymentPostprocessing", .string("0")),
        ]))
        guard var t = self[target] else { return id }
        var phases = t.references("buildPhases")
        let after = phases.firstIndex { self[$0]?.isa == "PBXSourcesBuildPhase" }.map { $0 + 1 } ?? phases.count
        phases.insert(id, at: after)
        t["buildPhases"] = .array(phases.map(PlistValue.string))
        self[target] = t
        return id
    }

    /// Unlinks a product dependency: removes it from every target, and its
    /// build files.
    public mutating func removePackageProduct(_ id: String) {
        for bf in objects.values where bf.isa == "PBXBuildFile" && bf.string("productRef") == id { removeBuildFile(bf.id) }
        for t in objects.values where t.references("packageProductDependencies").contains(id) {
            removeReference(id, key: "packageProductDependencies", from: t.id)
        }
        self[id] = nil
    }

    /// Removes a package reference and every product dependency on it.
    public mutating func removePackage(_ id: String) {
        for o in objects.values where o.isa == "XCSwiftPackageProductDependency" && o.string("package") == id {
            removePackageProduct(o.id)
        }
        removeReference(id, key: "packageReferences", from: rootObject, dropEmpty: true)
        self[id] = nil
    }
}
