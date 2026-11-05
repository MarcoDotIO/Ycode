import Foundation

/// `-showBuildSettings -scheme <scheme>` in a Swift package folder: the
/// settings swift-build exports for each build-description target the
/// scheme builds, from SwiftPM's PIF. See
/// `specs/xcodebuild/show-build-settings.md` §7.
enum PackageBuildSettings {
    typealias PIFTarget = (guid: String, name: String, type: String)

    static func run(_ inv: Invocation, package pkg: SwiftPackage, scheme: String, sdk: SDKEntry?, container: Container,
                    context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let destination = try runDestination(inv.destinations.first, context: ctx)
        let plan = PackageCommands.plan(inv, scheme: scheme, sdk: sdk, container: container, runDestination: destination, context: ctx)
        let action = plan.actions.first ?? .build
        let (pifPath, pifTargets) = try pkg.pif(context: ctx)
        let chosen = try targets(package: pkg, scheme: scheme, action: action, requested: inv.targets, pifTargets: pifTargets)
        if !inv.quiet { plan.printCommandLineSettings(ctx.console) }
        let provider = try provider(ctx)
        let all: [[String: String]]
        do {
            all = try provider.settings(pif: URL(fileURLWithPath: pifPath), guids: chosen.map(\.guid), parameters: plan.parameters(action: action))
        } catch {
            throw XcodebuildFailure("Could not resolve build settings: \(error)", exitCode: ExitCode.software)
        }
        ShowBuildSettings.print(targets: chosen.map(\.name), settings: all, action: action, json: inv.json, console: ctx.console)
        return 0
    }

    /// The context's provider, else swift-build through the helper. Ycode's
    /// own resolver reads projects only, so a package needs the helper.
    static func provider(_ ctx: XcodebuildContext) throws(XcodebuildFailure) -> SettingsProvider {
        if let p = ctx.settingsProvider { return p }
        guard let helper = SwiftBuildSettingsProvider.locate(environment: ctx.environment, executableDirectory: ctx.executableDirectory) else {
            throw XcodebuildFailure("Showing a Swift package's build settings needs the ycode-swb helper (swift-build), which was not found. It ships with Ycode; set YCODE_SWB to its path.",
                                    exitCode: ExitCode.software)
        }
        return SwiftBuildSettingsProvider(helper: helper)
    }

    /// The targets of the sections, in order (§7.1): with `-target`, those
    /// targets; else what the action builds. `build` and the other actions:
    /// the products' targets (`<product>-product`, or the product's package
    /// targets when it has none); the test actions add the scheme's test
    /// bundles (`<test>-product`); `docbuild` takes the products' package
    /// targets, as documentation is built per module.
    static func targets(package pkg: SwiftPackage, scheme: String, action: BuildAction, requested: [String],
                        pifTargets: [PIFTarget]) throws(XcodebuildFailure) -> [(guid: String, name: String)] {
        func named(_ guid: String) -> (guid: String, name: String) {
            (guid, pifTargets.first { $0.guid == guid }?.name ?? guid)
        }
        if !requested.isEmpty {
            var out: [(guid: String, name: String)] = []
            for n in requested {
                guard let t = target(named: n, in: pifTargets) else {
                    throw XcodebuildFailure("The package '\(pkg.name)' does not contain a target named '\(n)'.", exitCode: ExitCode.dataError)
                }
                out.append((t.guid, t.name))
            }
            return out
        }
        switch action {
        case .test, .buildForTesting, .testWithoutBuilding:
            let all = pkg.buildTargets(scheme: scheme, includeTests: true, pifTargets: pifTargets)
            let build = pkg.buildTargets(scheme: scheme, includeTests: false, pifTargets: pifTargets)
            let tests = all.filter { g in !build.contains(g) && pifTargets.contains { $0.guid == g && $0.type.contains("unit-test") } }
            return (build + tests).map(named)
        case .docbuild:
            let docs = pkg.documentationTargets(scheme: scheme, pifTargets: pifTargets)
            return (docs.isEmpty ? pkg.buildTargets(scheme: scheme, includeTests: false, pifTargets: pifTargets) : docs).map(named)
        default:
            return pkg.buildTargets(scheme: scheme, includeTests: false, pifTargets: pifTargets).map(named)
        }
    }

    /// A target by the name the sections print: a package target (the
    /// module, `PACKAGE-TARGET:<name>`), else any build-description target
    /// with that name (`greet-product`).
    static func target(named n: String, in pifTargets: [PIFTarget]) -> PIFTarget? {
        pifTargets.first { $0.guid == "PACKAGE-TARGET:" + n } ?? pifTargets.first { $0.name == n }
    }

    /// The run destination (§7.2): `-destination` as for a build, with
    /// `platform=Linux` naming this computer; without one, this computer:
    /// My Mac on macOS, the Linux host on Linux.
    static func runDestination(_ spec: String?, context ctx: XcodebuildContext, isLinux: Bool = isLinuxHost) throws(XcodebuildFailure) -> RunDestination? {
        guard let spec else { return isLinux ? linux(architecture: ctx.hostArchitecture) : .hostMac(architecture: ctx.hostArchitecture) }
        let (generic, fields) = Destinations.parse(spec)
        guard fields["platform"]?.lowercased() == "linux" else { return try Destinations.explicitDestination(spec, context: ctx) }
        return generic ? nil : linux(architecture: fields["arch"] ?? ctx.hostArchitecture)
    }

    /// swift-build's Linux platform and SDK (`linux`), for one architecture
    /// as Linux names it (`aarch64`, `x86_64`).
    static func linux(architecture: String) -> RunDestination {
        let arch = architecture == "arm64" ? "aarch64" : architecture
        return RunDestination(platform: "linux", sdk: "linux", targetArchitecture: arch, supportedArchitectures: [arch])
    }

    static var isLinuxHost: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }
}
