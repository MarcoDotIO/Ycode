import Foundation
import YcodeBuild
import YcodeProject
import YcodeSubprocess

/// The Swift packages a project or workspace uses, as PIF objects that
/// `XcodePIF` adds to its workspace, so that targets can link package
/// products (`specs/ide/build-pif.md` §Package products).
///
/// Ycode does not write package PIF itself. It writes a generated root
/// package whose dependencies are every package the container references
/// (local folders, and the checkouts of remote packages at their pinned
/// revisions) and runs SwiftPM's own generator on it,
/// `swift package dump-pif` (open source). From that PIF it keeps each
/// package's project and targets and drops the generated root and SwiftPM's
/// "Aggregate" project.
public struct PackageGraphPIF: @unchecked Sendable {
    /// A product of a package: the PIF target named `<product>-product`.
    public struct Product: Equatable, Sendable {
        public var name: String
        public var guid: String
        /// `packageProduct` (a static library product), or `standard`.
        public var targetType: String
        /// `productTypeIdentifier` of a standard target (`…library.dynamic`,
        /// `…tool`); empty for `packageProduct` targets.
        public var productType: String

        /// A dynamic library product: linked, and embedded in applications.
        public var isDynamic: Bool {
            productType == "com.apple.product-type.library.dynamic" || productType == "com.apple.product-type.framework"
        }
    }

    /// One package of the graph.
    public struct Package: Equatable, Sendable {
        /// SwiftPM's identity: the folder name, lowercased.
        public var identity: String
        public var directory: String
        public var projectGUID: String
        public var products: [String: Product]
        /// Host-built targets (build-tool plug-ins, macros) by name.
        public var pluginTargets: [String: String] = [:]
    }

    public var packages: [Package] = []
    /// Package project and target objects, in SwiftPM's order.
    public var objects: [[String: Any]] = []
    /// Signatures of the package projects, for the workspace's `projects`.
    public var projectSignatures: [String] = []
    /// SwiftPM's warnings, minus the ones the generated root causes.
    public var warnings: [String] = []
    /// What build-tool plug-ins applied to project targets produced, by
    /// `<project path>|<target id>` (`ProjectPlugins`).
    public var pluginOutputs: [String: ProjectPlugins.TargetOutputs] = [:]

    public init() {}

    public func package(identity: String) -> Package? { packages.first { $0.identity == identity } }

    /// The product target of `product`; `identity` narrows the search to one
    /// package (else the first package with such a product).
    public func product(_ name: String, identity: String?) -> Product? {
        if let identity { return package(identity: identity)?.products[name] }
        return packages.lazy.compactMap { $0.products[name] }.first
    }

    /// Every product target GUID that is a dynamic library.
    public var dynamicProductGUIDs: Set<String> {
        Set(packages.flatMap { $0.products.values.filter(\.isDynamic).map(\.guid) })
    }

    // MARK: Host tools of build-tool plug-ins

    /// SwiftPM runs a package's build-tool plug-ins while it writes the PIF
    /// and names the tools they run by where its own build would put them,
    /// `<scratch>/out/Products/<configuration>/<tool>`. swift-build builds
    /// those tools (the plug-in target's dependencies, for the host) into
    /// `$(BUILD_DIR)/$(CONFIGURATION)` of the client's build; the custom
    /// tasks are rewritten to that path (their strings are macro
    /// expressions).
    /// Folders that `relocateHostTools` maps to `$(BUILD_DIR)/$(CONFIGURATION)`.
    public private(set) var hostToolPrefixes: [String] = []

    /// A path or command-line word with host-tool folders relocated.
    public func relocated(_ s: String) -> String {
        var out = s
        for p in hostToolPrefixes where out.contains(p) { out = out.replacingOccurrences(of: p, with: "$(BUILD_DIR)/$(CONFIGURATION)") }
        return out
    }

    public mutating func relocateHostTools(scratchDirectory: String) {
        var prefixes: [String] = []
        for base in Set([scratchDirectory, URL(fileURLWithPath: scratchDirectory).resolvingSymlinksInPath().path,
                         URL(fileURLWithPath: scratchDirectory).standardizedFileURL.path]) {
            for c in ["Debug", "Release"] { prefixes.append(base + "/out/Products/" + c) }
        }
        // Longest first, so that no prefix rewrites part of another.
        prefixes.sort { $0.count > $1.count }
        hostToolPrefixes = prefixes
        func rewrite(_ v: Any) -> Any {
            if let s = v as? String {
                var out = s
                for p in prefixes where out.contains(p) { out = out.replacingOccurrences(of: p, with: "$(BUILD_DIR)/$(CONFIGURATION)") }
                return out
            }
            if let a = v as? [Any] { return a.map(rewrite) }
            if let d = v as? [String: Any] { return d.mapValues(rewrite) }
            return v
        }
        // swift-build caches PIF objects by signature (SwiftPM's are content
        // hashes), so a rewritten target gets a signature of its own.
        var renamed: [String: String] = [:]
        for i in objects.indices {
            guard var c = objects[i]["contents"] as? [String: Any], let tasks = c["customTasks"] as? [Any], !tasks.isEmpty,
                  let signature = objects[i]["signature"] as? String else { continue }
            let rewritten = rewrite(tasks)
            c["customTasks"] = rewritten
            objects[i]["contents"] = c
            let text = (try? JSONSerialization.data(withJSONObject: rewritten, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let newSignature = signature + "-ycode-" + MD5.hex(text)
            objects[i]["signature"] = newSignature
            renamed[signature] = newSignature
        }
        guard !renamed.isEmpty else { return }
        for i in objects.indices where objects[i]["type"] as? String == "project" {
            guard var c = objects[i]["contents"] as? [String: Any], let targets = c["targets"] as? [String] else { continue }
            c["targets"] = targets.map { renamed[$0] ?? $0 }
            objects[i]["contents"] = c
            // The project's own signature changes with its target list.
            if targets.contains(where: { renamed[$0] != nil }), let s = objects[i]["signature"] as? String {
                let newSignature = s + "-ycode-" + MD5.hex(targets.map { renamed[$0] ?? $0 }.joined(separator: ","))
                objects[i]["signature"] = newSignature
                if let j = projectSignatures.firstIndex(of: s) { projectSignatures[j] = newSignature }
            }
        }
    }

    // MARK: Reading SwiftPM's PIF

    /// Keeps the package projects of `swift package dump-pif` output and
    /// their targets; drops the workspace, the project of the generated root
    /// at `rootDirectory` and the aggregate project.
    public static func parse(_ data: Data, rootDirectory: String) throws -> PackageGraphPIF {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PIFGenerator.GenerationError.unsupported("swift package dump-pif printed no PIF")
        }
        let root = URL(fileURLWithPath: rootDirectory).standardizedFileURL.path
        var targetsBySignature: [String: [String: Any]] = [:]
        for o in list where o["type"] as? String == "target" {
            if let s = o["signature"] as? String { targetsBySignature[s] = o }
        }
        var out = PackageGraphPIF()
        for o in list where o["type"] as? String == "project" {
            guard let c = o["contents"] as? [String: Any], let signature = o["signature"] as? String else { continue }
            let dir = URL(fileURLWithPath: c["projectDirectory"] as? String ?? "").standardizedFileURL.path
            let targetSignatures = c["targets"] as? [String] ?? []
            let targetNames = targetSignatures.compactMap { (targetsBySignature[$0]?["contents"] as? [String: Any])?["name"] as? String }
            let isAggregate = c["guid"] as? String == "AGGREGATE"
                || (!targetNames.isEmpty && targetNames.allSatisfy { $0 == "AllIncludingTests" || $0 == "AllExcludingTests" })
            if dir == root || isAggregate { continue }
            var package = Package(identity: URL(fileURLWithPath: dir).lastPathComponent.lowercased(), directory: dir,
                                  projectGUID: c["guid"] as? String ?? "", products: [:])
            out.objects.append(o)
            out.projectSignatures.append(signature)
            for s in targetSignatures {
                guard let t = targetsBySignature[s] else { continue }
                out.objects.append(t)
                guard let tc = t["contents"] as? [String: Any], let name = tc["name"] as? String, let guid = tc["guid"] as? String else { continue }
                if tc["productTypeIdentifier"] as? String == "com.apple.product-type.tool.host-build", package.pluginTargets[name] == nil {
                    package.pluginTargets[name] = guid
                }
                guard name.hasSuffix("-product") else { continue }
                let type = tc["type"] as? String ?? "standard"
                // Test products are aggregates; they are never linked.
                if type == "aggregate" { continue }
                let product = String(name.dropLast("-product".count))
                package.products[product] = Product(name: product, guid: guid, targetType: type,
                                                    productType: tc["productTypeIdentifier"] as? String ?? "")
            }
            out.packages.append(package)
        }
        return out
    }
}

/// Finds a container's packages, brings remote ones to their pinned
/// revisions and runs SwiftPM's PIF generator on them.
public struct PackageGraphLoader: Sendable {
    public var container: Container
    /// `SourcePackages` folder: checkouts in `checkouts/`, the generated root
    /// package in `ycode-package-graph/`, SwiftPM's scratch folder in
    /// `ycode-package-graph-build/`.
    public var sourcePackagesDirectory: URL
    /// The `swift` driver whose SwiftPM generates the PIF.
    public var swift: String
    /// Resolve remote packages that `Package.resolved` does not pin yet.
    public var resolveMissingPins = true

    public init(container: Container, sourcePackagesDirectory: URL, swift: String = PackageGraphLoader.defaultSwift()) {
        self.container = container
        self.sourcePackagesDirectory = sourcePackagesDirectory
        self.swift = swift
    }

    /// The toolchain's `swift`: `DEVELOPER_DIR`'s default toolchain, else PATH.
    public static func defaultSwift(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var candidates: [String] = []
        if let dev = environment["DEVELOPER_DIR"] { candidates.append(dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift") }
        for dir in (environment["PATH"] ?? "/usr/bin").split(separator: ":") { candidates.append("\(dir)/swift") }
        candidates.append("/usr/bin/swift")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/swift"
    }

    /// The IDE's default `SourcePackages` folder for a container:
    /// `~/Library/Caches/Ycode/SourcePackages/<name>-<hash>` (the folder that
    /// holds the IDE's checkouts, `PackageDependencyModel.defaultCheckouts`).
    public static func defaultSourcePackages(for url: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        var h: UInt64 = 1469598103934665603
        for b in url.standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let name = url.deletingPathExtension().lastPathComponent + "-" + String(h, radix: 36)
        return caches.appendingPathComponent("Ycode/SourcePackages/\(name)")
    }

    /// A referenced package: a local folder or a remote repository.
    public struct Reference: Equatable, Sendable {
        public var local: String?
        public var remote: String?
        public var identity: String {
            if let local { return URL(fileURLWithPath: local).lastPathComponent.lowercased() }
            return PackageResolver.identity(of: remote ?? "")
        }
    }

    /// Every package reference of every project, in order, without repeats.
    public var references: [Reference] {
        var out: [Reference] = []
        for p in container.projects {
            for r in LocalPackages.references(in: p) {
                let ref = Reference(local: r.local, remote: r.remote)
                if !out.contains(ref) { out.append(ref) }
            }
        }
        return out
    }

    /// Whether any project of the container references a package.
    public var usesPackages: Bool { !references.isEmpty }

    var resolvedFile: URL { container.workspacePath.appendingPathComponent("xcshareddata/swiftpm/Package.resolved") }

    /// The checkouts of every pinned package, after bringing each to its
    /// pinned revision (resolving first when a remote reference is not
    /// pinned).
    public func pinnedCheckouts() throws -> [PackageResolver.Pin] {
        let roots: [(url: String, requirement: SwiftPackageRequirement)] = {
            var out: [(url: String, requirement: SwiftPackageRequirement)] = []
            for p in container.projects {
                for r in PackageResolver.roots(of: p.proj) where !out.contains(where: { $0.url == r.url }) { out.append(r) }
            }
            return out
        }()
        guard !roots.isEmpty else { return [] }
        let resolver = PackageResolver(checkoutsDirectory: sourcePackagesDirectory.appendingPathComponent("checkouts"))
        var pins = resolver.readResolvedFile(resolvedFile) ?? []
        let pinned = Set(pins.map(\.identity))
        if roots.contains(where: { !pinned.contains(PackageResolver.identity(of: $0.url)) }) {
            guard resolveMissingPins else {
                throw PIFGenerator.GenerationError.unsupported("packages are not resolved: run Resolve Package Versions")
            }
            pins = try resolver.resolveGraph(roots)
            try FileManager.default.createDirectory(at: resolvedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PackageResolver.resolvedFileV3(pins, originHash: PackageResolver.originHash(rootLocations: roots.map(\.url)))
                .write(to: resolvedFile, options: .atomic)
        }
        for p in pins { try resolver.checkout(identity: p.identity, location: p.location, revision: p.revision) }
        return pins
    }

    /// The generated root manifest: one `.package(path:)` per package. A
    /// local package overrides a remote package of the same identity, as a
    /// root dependency overrides a transitive one in SwiftPM.
    public static func rootManifest(packageDirectories: [String]) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var text = """
        // swift-tools-version: 5.9
        // Generated by Ycode: the packages of one project or workspace, for
        // `swift package dump-pif` (specs/ide/build-pif.md). Do not edit.
        import PackageDescription

        let package = Package(
            name: "ycode-package-graph",
            dependencies: [

        """
        for d in packageDirectories { text += "        .package(path: \(literal(d))),\n" }
        text += "    ]\n)\n"
        return text
    }

    /// The package directories of the generated root: local references
    /// first, then the checkouts of pins whose identity no local package has.
    public func packageDirectories(pins: [PackageResolver.Pin]) -> [String] {
        var out: [String] = []
        var identities = Set<String>()
        for r in references {
            guard let local = r.local, identities.insert(r.identity).inserted else { continue }
            out.append(URL(fileURLWithPath: local).standardizedFileURL.path)
        }
        for p in pins where identities.insert(p.identity).inserted { out.append(p.checkout.standardizedFileURL.path) }
        return out
    }

    /// Writes the root package and runs SwiftPM's PIF generator on it. Nil
    /// when the container references no package.
    public func load() throws -> PackageGraphPIF? {
        guard usesPackages else { return nil }
        let dirs = packageDirectories(pins: try pinnedCheckouts())
        for d in dirs where !FileManager.default.fileExists(atPath: d + "/Package.swift") {
            throw PIFGenerator.GenerationError.unsupported("no Package.swift in \(d)")
        }
        let root = sourcePackagesDirectory.appendingPathComponent("ycode-package-graph")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = Data(Self.rootManifest(packageDirectories: dirs).utf8)
        let manifestURL = root.appendingPathComponent("Package.swift")
        // Rewritten only when it changes, so SwiftPM's manifest cache stays valid.
        if FileManager.default.contents(atPath: manifestURL.path) != manifest { try manifest.write(to: manifestURL, options: .atomic) }
        let scratch = sourcePackagesDirectory.appendingPathComponent("ycode-package-graph-build")
        let (status, out, err) = Self.run(swift, ["package", "--package-path", root.path, "--scratch-path", scratch.path, "dump-pif"])
        guard status == 0 else {
            let message = err.split(separator: "\n").filter { $0.contains("error:") }.joined(separator: "\n")
            throw PIFGenerator.GenerationError.unsupported("swift package dump-pif failed: \(message.isEmpty ? err : message)")
        }
        var graph = try PackageGraphPIF.parse(out, rootDirectory: root.path)
        // Plug-ins applied to project targets (their commands name host
        // tools in the scratch folder too, relocated below).
        if container.projects.contains(where: { p in p.targets.contains { !ProjectPlugins.applied($0, in: p.proj).isEmpty } }) {
            graph.pluginOutputs = try ProjectPlugins.run(container: container, graph: graph, sourcePackages: sourcePackagesDirectory,
                                                         scratch: scratch, toolchain: try ProjectPlugins.Toolchain.locate(swift: swift))
        }
        graph.relocateHostTools(scratchDirectory: scratch.path)
        let missing = Self.missingProducts(container, graph)
        if !missing.isEmpty {
            throw PIFGenerator.GenerationError.unsupported(missing.map { "Missing package product '\($0)'" }.joined(separator: "\n"))
        }
        graph.warnings = err.split(separator: "\n").map(String.init).filter { line in
            line.contains("warning:") && !line.contains("'ycode-package-graph'") && !line.contains("Conflicting identity")
        }
        return graph
    }

    /// Products that targets depend on but no package of the graph has.
    static func missingProducts(_ container: Container, _ graph: PackageGraphPIF) -> [String] {
        var out: [String] = []
        for p in container.projects {
            for t in p.targets {
                for id in t.references("packageProductDependencies") {
                    guard let name = p.proj[id]?.string("productName"), !name.hasPrefix("plugin:"),
                          graph.product(name, identity: nil) == nil, !out.contains(name) else { continue }
                    out.append(name)
                }
            }
        }
        return out
    }

    static func run(_ tool: String, _ args: [String]) -> (Int32, Data, String) {
        MainThreadGuard.blockingCall("swift package dump-pif")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return (-1, Data(), "cannot run \(tool)") }
        // stderr is read on another thread so that neither pipe fills up.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        let errHandle = err.fileHandleForReading
        // A thread, not a global queue (see Subprocess.run).
        Thread { box.data = errHandle.readDataToEndOfFile(); group.leave() }.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, data, String(decoding: box.data, as: UTF8.self))
    }
}
