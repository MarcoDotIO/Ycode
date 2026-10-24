import Foundation
import YcodeWorkspace

/// A Swift package folder opened directly (a `Package.swift` and no project
/// or workspace), described and turned into a build description by the
/// toolchain's open-source SwiftPM (`swift package describe`,
/// `show-dependencies`, `dump-pif`). See `specs/xcodebuild/packages.md`.
struct SwiftPackage {
    struct Product { var name: String; var isExecutable: Bool; var targets: [String] }
    struct Target { var name: String; var type: String; var dependencies: [String]; var path: String }
    struct Dependency { var name: String; var path: String; var isLocal: Bool; var version: String }

    /// The folder as the reference tool prints it (`/private` prefix removed).
    var directory: String
    var name: String
    var products: [Product]
    var targets: [Target]
    var dependencies: [Dependency]
    /// Where SwiftPM keeps its own state (outside the package folder).
    var scratch: String
    var swift: String

    /// One scheme per product; with several products also `<name>-Package`.
    var schemeNames: [String] {
        var names = products.map(\.name)
        if products.count > 1 { names.append(name + "-Package") }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var packageSchemeName: String { name + "-Package" }

    /// Test targets of a scheme: all of them for the package scheme and for
    /// the primary product (the first executable product, else the first
    /// product); none for other products.
    func testTargets(scheme: String) -> [String] {
        let tests = targets.filter { $0.type == "test" }.map(\.name)
        if scheme == packageSchemeName && products.count > 1 { return tests }
        let primary = products.first(where: \.isExecutable) ?? products.first
        return primary?.name == scheme ? tests : []
    }

    static func swiftTool(_ ctx: XcodebuildContext) -> String {
        if let dev = ctx.developerDirectory {
            let p = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        for dir in (ctx.environment["PATH"] ?? "/usr/bin").split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/swift") {
            return "\(dir)/swift"
        }
        return "/usr/bin/swift"
    }

    func swiftPM(_ args: [String], context ctx: XcodebuildContext) throws(XcodebuildFailure) -> String {
        let r = TestActions.run(swift, ["package", "--package-path", directory, "--scratch-path", scratch] + args, environment: ctx.environment)
        guard r.status == 0 else {
            throw XcodebuildFailure("Could not read the package at \(directory) (swift package \(args.first ?? "") failed).", exitCode: ExitCode.dataError)
        }
        return r.output
    }

    /// Reads the package in `dir`.
    static func load(directory dir: String, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> SwiftPackage {
        let shown = PathText.withoutPrivatePrefix(URL(fileURLWithPath: dir).standardizedFileURL.path)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ycodebuild-spm/" + DerivedDataName.hash(shown)).path
        var p = SwiftPackage(directory: shown, name: URL(fileURLWithPath: shown).lastPathComponent, products: [], targets: [],
                             dependencies: [], scratch: scratch, swift: swiftTool(ctx))
        let describe = try p.swiftPM(["describe", "--type", "json"], context: ctx)
        guard let d = try? JSONSerialization.jsonObject(with: Data(describe.utf8)) as? [String: Any] else {
            throw XcodebuildFailure("Could not read the package at \(shown).", exitCode: ExitCode.dataError)
        }
        p.name = d["name"] as? String ?? p.name
        p.products = (d["products"] as? [[String: Any]] ?? []).compactMap { pr in
            guard let n = pr["name"] as? String else { return nil }
            let type = pr["type"] as? [String: Any] ?? [:]
            return Product(name: n, isExecutable: type.keys.contains("executable"), targets: pr["targets"] as? [String] ?? [])
        }
        p.targets = (d["targets"] as? [[String: Any]] ?? []).compactMap { t in
            guard let n = t["name"] as? String else { return nil }
            return Target(name: n, type: t["type"] as? String ?? "", dependencies: (t["target_dependencies"] as? [String] ?? []) + (t["product_dependencies"] as? [String] ?? []),
                          path: shown + "/" + (t["path"] as? String ?? "Sources/" + n))
        }
        if let deps = try? p.swiftPM(["show-dependencies", "--format", "json"], context: ctx),
           let root = try? JSONSerialization.jsonObject(with: Data(deps.utf8)) as? [String: Any] {
            var seen = Set<String>()
            func walk(_ node: [String: Any]) {
                for c in node["dependencies"] as? [[String: Any]] ?? [] {
                    guard let name = c["name"] as? String, seen.insert(name).inserted else { continue }
                    let path = c["path"] as? String ?? ""
                    let url = c["url"] as? String ?? path
                    let local = url.hasPrefix("/")
                    p.dependencies.append(Dependency(name: name, path: local ? PathText.withoutPrivatePrefix(url) : url, isLocal: local,
                                                     version: c["version"] as? String ?? ""))
                    walk(c)
                }
            }
            walk(root)
        }
        return p
    }

    /// The `Resolve Package Graph` report: the package, then its dependencies.
    func printReport(_ console: Console) {
        console.out("Resolve Package Graph")
        console.out()
        console.out()
        console.out("Resolved source packages:")
        console.out("  \(name): \(directory)")
        for d in dependencies { console.out("  \(d.name): \(d.path) @ \(d.isLocal ? "local" : d.version)") }
        console.out()
    }

    /// The build description from SwiftPM, written to a file.
    func pif(context ctx: XcodebuildContext) throws(XcodebuildFailure) -> (path: String, targets: [(guid: String, name: String, type: String)]) {
        let text = try swiftPM(["dump-pif"], context: ctx)
        let path = scratch + "/ycodebuild.pif.json"
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) } catch {
            throw XcodebuildFailure("cannot write \(path): \(error)", exitCode: ExitCode.software)
        }
        let objects = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []
        let targets: [(guid: String, name: String, type: String)] = objects.compactMap { o in
            guard o["type"] as? String == "target", let c = o["contents"] as? [String: Any], let guid = c["guid"] as? String else { return nil }
            return (guid, c["name"] as? String ?? "", c["productTypeIdentifier"] as? String ?? c["type"] as? String ?? "")
        }
        return (path, targets)
    }

    /// What `docbuild` builds for a scheme: the package targets of its
    /// products (documentation is compiled per module).
    func documentationTargets(scheme: String, pifTargets: [(guid: String, name: String, type: String)]) -> [String] {
        let chosen = scheme == packageSchemeName && products.count > 1 ? products : products.filter { $0.name == scheme }
        var out: [String] = []
        for p in chosen {
            for t in p.targets where pifTargets.contains(where: { $0.guid == "PACKAGE-TARGET:" + t }) && !out.contains("PACKAGE-TARGET:" + t) {
                out.append("PACKAGE-TARGET:" + t)
            }
        }
        return out
    }

    /// The scheme's library products as coverage reports them: the product
    /// name and its package-framework name `<name>_<hash>_PackageProduct`,
    /// the hash being the one in the PIF's `PACKAGE-TARGET:<name>-<hash>-dynamic`
    /// target (products without such a target are left out).
    func coverageLibraries(scheme: String, pifTargets: [(guid: String, name: String, type: String)]) -> [(name: String, framework: String)] {
        let chosen = scheme == packageSchemeName && products.count > 1 ? products : products.filter { $0.name == scheme }
        return chosen.filter { !$0.isExecutable }.compactMap { p in
            let prefix = "PACKAGE-TARGET:" + p.name + "-", suffix = "-dynamic"
            guard let g = pifTargets.first(where: { $0.guid.hasPrefix(prefix) && $0.guid.hasSuffix(suffix) })?.guid,
                  g.count > prefix.count + suffix.count else { return nil }
            let hash = g.dropFirst(prefix.count).dropLast(suffix.count)
            return (p.name, p.name + "_" + hash + "_PackageProduct")
        }
    }

    /// Build-description targets of a scheme: the products' (and tests')
    /// product targets, which depend on the package targets.
    func buildTargets(scheme: String, includeTests: Bool, pifTargets: [(guid: String, name: String, type: String)]) -> [String] {
        func target(_ n: String) -> String? { pifTargets.first { $0.guid == "PACKAGE-TARGET:" + n }?.guid }
        func product(_ n: String) -> String? { pifTargets.first { $0.name == n + "-product" && $0.guid.hasPrefix("PACKAGE-PRODUCT:") }?.guid }
        let chosen = scheme == packageSchemeName && products.count > 1 ? products : products.filter { $0.name == scheme }
        var out: [String] = []
        for p in chosen {
            let g = product(p.name).map { [$0] } ?? p.targets.compactMap(target)
            out += g.filter { !out.contains($0) }
        }
        if includeTests { out += testTargets(scheme: scheme).compactMap(product).filter { !out.contains($0) } }
        return out
    }
}

/// Commands run in a package folder. See `specs/xcodebuild/packages.md`.
enum PackageCommands {
    /// The folder holds a package and nothing the other commands open.
    static func applies(_ inv: Invocation, cwd: String) -> Bool {
        guard inv.project == nil, inv.workspace == nil, FileManager.default.fileExists(atPath: cwd + "/Package.swift") else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cwd)) ?? []
        guard !entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) else { return false }
        return inv.scheme != nil || inv.has("-list") || inv.has("-showBuildSettings") || inv.has("-resolvePackageDependencies")
    }

    static func run(_ inv: Invocation, sdk: SDKEntry?, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let console = ctx.console
        let pkg = try SwiftPackage.load(directory: ctx.cwd, context: ctx)
        if !inv.quiet { pkg.printReport(console) }
        let container = Container(kind: .workspace, url: URL(fileURLWithPath: pkg.directory), projects: [], displayName: pkg.name)
        if inv.has("-resolvePackageDependencies") { return try ResolvePackages.run(inv, package: pkg, context: ctx) }
        if inv.has("-list") {
            if inv.json {
                console.out(JSONText.render(["workspace": ["name": pkg.name, "schemes": pkg.schemeNames]]))
                return 0
            }
            console.out("Information about workspace \"\(pkg.name)\":")
            console.out("    Schemes:")
            for s in pkg.schemeNames { console.out("        " + s) }
            console.out()
            return 0
        }
        guard let schemeName = inv.scheme else {
            throw XcodebuildFailure("Unable to open workspace '\(ctx.cwd)', and no scheme name was provided.", exitCode: ExitCode.dataError)
        }
        guard pkg.schemeNames.contains(schemeName) else {
            throw XcodebuildFailure("The workspace named \"\(pkg.name)\" does not contain a scheme named \"\(schemeName)\". The \"-list\" option can be used to find the names of the schemes in the workspace.", exitCode: ExitCode.dataError)
        }
        if inv.has("-showdestinations") {
            // Packages build for every platform.
            let compatible = Destinations.packageListing(context: ctx)
            console.out()
            console.out()
            console.out("\tDestinations compatible with the \"\(schemeName)\" scheme:")
            for c in compatible { console.out("\t\t" + c) }
            return 0
        }
        let actions = inv.actions.isEmpty ? [BuildAction.build] : inv.actions
        let tests = pkg.testTargets(scheme: schemeName)
        if !inv.has("-showBuildSettings"), actions.contains(where: { $0 == .test || $0 == .testWithoutBuilding }), tests.isEmpty {
            throw XcodebuildFailure("Scheme \(schemeName) is not currently configured for the test action.", exitCode: ExitCode.noInput, trailingBlank: true)
        }
        if let spec = inv.destinations.first { printDestinationWarning(spec, context: ctx) }
        // The reference tool prints no build settings for package schemes.
        if inv.has("-showBuildSettings") {
            if inv.json { console.out(JSONText.render([Any]())) }
            return 0
        }
        guard let spec = inv.destinations.first else {
            throw XcodebuildFailure("Building a Swift package requires that a destination is provided using the \"-destination\" option. The \"-showdestinations\" option can be used to list the available destinations.", exitCode: ExitCode.software)
        }
        let (pifPath, pifTargets) = try pkg.pif(context: ctx)
        var overrides: [(String, String)] = []
        if !inv.archs.isEmpty { overrides.append(("ARCHS", inv.archs.joined(separator: " "))) }
        if let sdk { overrides.append(("SDKROOT", inv.sdk!.contains("/") ? sdk.path : sdk.canonicalName)) }
        for (k, v) in inv.overrides { overrides.removeAll { $0.0 == k }; overrides.append((k, v)) }
        let derivedData = inv.derivedDataPath.map { PathText.withoutPrivatePrefix(URL(fileURLWithPath: $0.hasPrefix("/") ? $0 : ctx.cwd + "/" + $0).standardizedFileURL.path) }
        let arena = Arena.forContainer(container, derivedDataPath: derivedData, derivedDataRoot: ctx.derivedDataRoot)
        let ref = Scheme.BuildableReference(blueprintIdentifier: schemeName, buildableName: schemeName, blueprintName: schemeName,
                                            referencedContainer: "container:")
        var scheme = Scheme.autocreated(for: ref, isTestBundle: false, isRunnable: false)
        scheme.name = schemeName
        let configuration = inv.configuration ?? "Debug"
        var plan = Plan(container: container, scheme: scheme, actions: actions, targets: [], configuration: configuration,
                        overrides: overrides, xcconfig: inv.xcconfig.map { ($0, $0.hasPrefix("/") ? $0 : ctx.cwd + "/" + $0) },
                        arena: arena, runDestination: try Destinations.explicitDestination(spec, context: ctx))
        plan.package = Plan.PackageBuild(pif: pifPath, build: pkg.buildTargets(scheme: schemeName, includeTests: false, pifTargets: pifTargets),
                                         tests: pkg.buildTargets(scheme: schemeName, includeTests: true, pifTargets: pifTargets)
                                             .filter { g in pifTargets.contains { $0.guid == g && $0.type.contains("unit-test") } },
                                         targets: pkg.targets.map { ($0.name, $0.path, $0.type == "test") },
                                         documentation: pkg.documentationTargets(scheme: schemeName, pifTargets: pifTargets),
                                         coverageLibraries: pkg.coverageLibraries(scheme: schemeName, pifTargets: pifTargets))
        // Package test runs gather code coverage unless turned off.
        if actions.contains(where: { $0 == .test || $0 == .testWithoutBuilding || $0 == .buildForTesting }),
           inv.value("-enableCodeCoverage").map({ $0.uppercased() == "YES" }) ?? true {
            plan.coverage = true
            let buildFolder = URL(fileURLWithPath: arena.buildProductsPath).deletingLastPathComponent().path
            plan.synthesized += [("CLANG_COVERAGE_MAPPING", "YES"), ("CLANG_PROFILE_DATA_DIRECTORY", buildFolder + "/ProfileData")]
        }
        return try BuildActions.run(inv, plan: plan, context: ctx)
    }

    /// The "first of multiple matching destinations" warning for a macOS
    /// destination: My Mac in each architecture and variant it runs.
    static func printDestinationWarning(_ spec: String, context ctx: XcodebuildContext) {
        let (_, fields) = Destinations.parse(spec)
        guard (fields["platform"] ?? "macOS") == "macOS", fields["variant"] == nil else { return }
        let id = Destinations.macProvisioningUDID().map { ", id:\($0)" } ?? ""
        var lines: [String] = []
        let archs = fields["arch"].map { [$0] } ?? (ctx.hostArchitecture == "arm64" ? ["arm64", "x86_64"] : ["x86_64"])
        for a in archs { lines.append("{ platform:macOS, arch:\(a)\(id), name:My Mac }") }
        for a in archs { lines.append("{ platform:macOS, arch:\(a), variant:Mac Catalyst\(id), name:My Mac }") }
        if ctx.hostArchitecture == "arm64" {
            lines.append("{ platform:macOS, arch:arm64, variant:DriverKit\(id), name:My Mac }")
            lines.append("{ platform:macOS, arch:arm64, variant:Designed for [iPad,iPhone]\(id), name:My Mac }")
            if fields["arch"] == nil {
                lines.append("{ platform:macOS, arch:arm64e.x1, variant:Designed for [iPad,iPhone]\(id), name:My Mac }")
                lines.append("{ platform:macOS, arch:arm64_32, variant:Designed for [iPad,iPhone]\(id), name:My Mac }")
            }
        }
        ctx.console.warning("Using the first of multiple matching destinations:\n" + lines.joined(separator: "\n"))
    }
}
