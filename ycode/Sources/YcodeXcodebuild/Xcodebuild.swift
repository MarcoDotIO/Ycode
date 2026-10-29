import Foundation
import YcodeProject
import YcodeWorkspace

/// Ycode's own version, printed by `-version` in the reference tool's
/// two-line format. See `specs/xcodebuild/info-commands.md` §1.
public enum YcodeVersion {
    public static let product = "Ycode"
    public static let version = "0.1"
    public static let build = "0.1.0-dev"
}

/// Everything a run depends on besides the arguments.
public struct XcodebuildContext {
    public var cwd: String
    public var environment: [String: String]
    /// Printed in the "Command line invocation" header.
    public var toolPath: String
    public var developerDirectory: String?
    public var home: String
    /// The DerivedData folder (`-IDECustomDerivedDataLocation=<dir>`); nil =
    /// `~/Library/Developer/Xcode/DerivedData`.
    public var derivedDataLocation: String?
    /// The folder that holds each container's DerivedData folder.
    public var derivedDataRoot: String { derivedDataLocation ?? home + "/Library/Developer/Xcode/DerivedData" }
    public var user: String
    public var hostArchitecture: String
    public var console: Console
    /// Overrides how settings are evaluated (tests); nil = automatic.
    public var settingsProvider: SettingsProvider?
    /// Directory of the running executable (to find helper tools).
    public var executableDirectory: String?

    public init(cwd: String, environment: [String: String], toolPath: String, developerDirectory: String?,
                home: String, user: String, hostArchitecture: String, console: Console,
                settingsProvider: SettingsProvider? = nil, executableDirectory: String? = nil) {
        self.cwd = cwd
        self.environment = environment
        self.toolPath = toolPath
        self.developerDirectory = developerDirectory
        self.home = home
        self.user = user
        self.hostArchitecture = hostArchitecture
        self.console = console
        self.settingsProvider = settingsProvider
        self.executableDirectory = executableDirectory
    }

    /// The context of the current process.
    public static func current(console: Console = .standard()) -> XcodebuildContext {
        let env = ProcessInfo.processInfo.environment
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "ycodebuild")
        let toolPath = (Bundle.main.executableURL ?? exe).standardizedFileURL.resolvingSymlinksInPath().path
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return XcodebuildContext(
            cwd: FileManager.default.currentDirectoryPath, environment: env, toolPath: toolPath,
            developerDirectory: Workspace.activeDeveloperDirectory(), home: env["HOME"] ?? NSHomeDirectory(),
            user: env["USER"] ?? NSUserName(), hostArchitecture: arch, console: console,
            executableDirectory: URL(fileURLWithPath: toolPath).deletingLastPathComponent().path)
    }
}

public enum Xcodebuild {
    /// Runs one command line; returns the exit status.
    public static func run(_ arguments: [String], context: XcodebuildContext) -> Int32 {
        let console = context.console
        defer { console.flushDeferred() }
        do {
            return try runChecked(arguments, context: context)
        } catch {
            console.report(error)
            return error.exitCode
        }
    }

    static func runChecked(_ arguments: [String], context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let inv = try ArgumentParser.parse(arguments)
        let console = ctx.console
        var ctx = ctx
        if let d = inv.userDefaults.last(where: { $0.name == "IDECustomDerivedDataLocation" })?.value, !d.isEmpty {
            ctx.derivedDataLocation = URL(fileURLWithPath: d.hasPrefix("/") ? d : ctx.cwd + "/" + d).standardizedFileURL.path
        }

        if inv.has("-help") { console.err(HelpText.help); return 0 }
        if inv.has("-usage") { console.err(HelpText.usage); return 0 }

        if inv.has("-exportArchive") {
            var missing: [String] = []
            if inv.value("-exportOptionsPlist") == nil { missing.append("The flag -exportOptionsPlist is required when specifying -exportArchive.") }
            if inv.value("-archivePath") == nil { missing.append("The flag -archivePath is required when specifying -exportArchive.") }
            if !missing.isEmpty { throw XcodebuildFailure(messages: missing, exitCode: ExitCode.usage) }
            return Archives.export(inv, context: ctx)
        }
        for (flag, feature) in [("-exportNotarizedApp", "-exportNotarizedApp"), ("-create-xcframework", "-create-xcframework"),
                                ("-showBuildSettingsForIndex", "-showBuildSettingsForIndex"),
                                ("-license", "Xcode installation management (-license)"),
                                ("-checkFirstLaunchStatus", "Xcode installation management (-checkFirstLaunchStatus)"),
                                ("-runFirstLaunch", "Xcode installation management (-runFirstLaunch)"),
                                ("-downloadAllPlatforms", "Xcode installation management (-downloadAllPlatforms)"),
                                ("-prepareDeviceSupport", "device support preparation")] where inv.has(flag) {
            throw unsupported(feature)
        }
        for opt in ["-downloadPlatform", "-importPlatform", "-downloadComponent", "-importComponent", "-deleteComponent",
                    "-showComponent", "-find-executable", "-find-library", "-convert-project", "-dumpPIF"] where inv.value(opt) != nil {
            throw unsupported(opt)
        }

        let sdks = SDKRegistry(developerDirectory: ctx.developerDirectory ?? "")
        if inv.has("-version") { return try InfoCommands.version(inv, sdks: sdks, context: ctx) }
        if inv.has("-showsdks") { return InfoCommands.showsdks(inv, sdks: sdks, context: ctx) }

        // Checks that need no container.
        if inv.project != nil && inv.workspace != nil {
            throw XcodebuildFailure("You cannot specify both an Xcode project and a workspace.", exitCode: ExitCode.usage)
        }
        if inv.has("-alltargets") && !inv.targets.isEmpty {
            throw XcodebuildFailure("You cannot specify -alltargets and also specify individual targets.", exitCode: ExitCode.usage)
        }
        var resolvedSDK: SDKEntry?
        if let s = inv.sdk {
            guard let e = sdks.lookup(s, relativeTo: ctx.cwd) else {
                throw XcodebuildFailure("SDK \"\(s)\" cannot be located.", exitCode: ExitCode.usage)
            }
            resolvedSDK = e
        }
        let isInfo = inv.has("-list") || inv.has("-showBuildSettings") || inv.has("-showdestinations") || inv.has("-showTestPlans")
        if inv.workspace != nil, inv.scheme == nil, !inv.has("-list") {
            throw XcodebuildFailure("If you specify a workspace then you must also specify a scheme.  Use -list to see the schemes in this workspace.", exitCode: ExitCode.usage)
        }
        if !isInfo, inv.derivedDataPath != nil, inv.scheme == nil, inv.value("-testProductsPath") == nil, inv.value("-xctestrun") == nil {
            throw XcodebuildFailure("The flag -scheme, -testProductsPath, or -xctestrun is required when specifying -derivedDataPath.", exitCode: ExitCode.usage)
        }

        if let (path, _) = ResultBundleSession.requestedPath(inv, cwd: ctx.cwd), FileManager.default.fileExists(atPath: path) {
            throw XcodebuildFailure("Existing file at -resultBundlePath \"\(ResultBundleSession.standardized(path))\"", exitCode: ExitCode.usage)
        }

        if !inv.quiet {
            console.out("Command line invocation:")
            console.out("    " + ([ctx.toolPath] + arguments.map(ShellQuote.quote)).joined(separator: " "))
            console.out()
        }

        if inv.has("-showdestinations") && inv.scheme == nil {
            throw XcodebuildFailure("-showdestinations requires a workspace and scheme.", exitCode: ExitCode.usage)
        }
        if let word = inv.infoItems.first {
            throw XcodebuildFailure("Unknown build action '\(word)'.", exitCode: ExitCode.dataError)
        }
        if inv.actions.contains(.installsrc) && inv.scheme != nil {
            throw XcodebuildFailure("Cannot use the installsrc action with -scheme.", exitCode: ExitCode.usage)
        }
        if !inv.destinations.isEmpty && inv.scheme == nil && !inv.has("-list") && inv.value("-xctestrun") == nil {
            console.warning("Ignoring provided run destination because no scheme was passed.")
        }

        // test-without-building from a test run file needs no container.
        if let run = inv.value("-xctestrun") {
            guard inv.actions == [.testWithoutBuilding] || inv.actions.isEmpty || inv.actions == [.test] else {
                throw Xcodebuild.unsupported("-xctestrun with actions other than test-without-building")
            }
            let path = run.hasPrefix("/") ? run : ctx.cwd + "/" + run
            let file = try XCTestRunFile.read(path, developerDirectory: ctx.developerDirectory ?? "")
            let started = Date()
            let session = XCTestRunFile.resultBundleSession(inv, file: file, xctestrun: path, started: started, context: ctx)
            session?.0.announceIfExplicit(console)
            console.outDeferred("Testing started")
            let outcome = TestActions.execute(TestActions.applySelection(inv, to: file.targets), quiet: inv.quiet, context: ctx)
            if let (s, plan) = session {
                s.record(.init(commandName: "Test", taskName: "Action", title: file.scheme.map { "Testing project \(file.container ?? "") with scheme \($0)" },
                               started: started, ended: Date(), build: nil, tests: outcome, testPlanName: plan, testRequested: true),
                         quiet: inv.quiet, console: console, announceWritten: false)
            }
            return TestActions.report(outcome, action: .testWithoutBuilding, resultBundle: session?.0.displayPath, quiet: inv.quiet, console: console) ? 0 : ExitCode.dataError
        }

        if inv.has("-exportLocalizations") { return try Localization.export(inv, context: ctx) }
        if inv.has("-importLocalizations") { return try Localization.importLocalizations(inv, context: ctx) }
        if PackageCommands.applies(inv, cwd: ctx.cwd) { return try PackageCommands.run(inv, sdk: resolvedSDK, context: ctx) }
        let container = try ContainerLocator.open(inv, cwd: ctx.cwd)

        if inv.has("-resolvePackageDependencies") { return try ResolvePackages.run(inv, container: container, context: ctx) }
        let cloned = inv.value("-clonedSourcePackagesDirPath").map { ($0.hasPrefix("/") ? $0 : ctx.cwd + "/" + $0) + "/checkouts" }
        if !inv.quiet { PackageReport.print(container, derivedDataRoot: ctx.derivedDataRoot, checkouts: cloned, console: console) }
        if inv.has("-list") { return InfoCommands.list(inv, container: container, context: ctx) }

        var plan = try Plan.make(inv, container: container, context: ctx, sdk: resolvedSDK)
        if inv.has("-showdestinations") { return InfoCommands.showdestinations(inv, plan: plan, context: ctx) }
        if inv.has("-showTestPlans") { return InfoCommands.showTestPlans(inv, plan: plan, context: ctx) }
        if !inv.quiet { plan.printCommandLineSettings(console) }
        if inv.has("-showBuildSettings") { return try ShowBuildSettings.run(inv, plan: &plan, context: ctx) }
        return try BuildActions.run(inv, plan: plan, context: ctx)
    }

    static func unsupported(_ feature: String) -> XcodebuildFailure {
        XcodebuildFailure("ycodebuild does not support \(feature) yet.", exitCode: ExitCode.software)
    }
}

/// What a scheme or legacy invocation resolves to: targets, configuration,
/// parameters. See `specs/xcodebuild/show-build-settings.md` §2.
struct Plan {
    var container: Container
    var scheme: Scheme?
    var actions: [BuildAction]
    var targets: [SettingsTarget]
    var configuration: String
    var overrides: [(String, String)]
    var xcconfig: (given: String, absolute: String)?
    var arena: Arena?
    var runDestination: RunDestination?
    var synthesized: [(String, String)] = []
    /// Tests collect code coverage (scheme setting or -enableCodeCoverage).
    var coverage = false
    /// A Swift package opened directly: SwiftPM's build description and
    /// the targets a scheme builds and tests (`packages.md`).
    struct PackageBuild {
        var pif: String
        var build: [String]
        var tests: [String]
        /// Package targets (name, absolute folder, is a test target), for coverage.
        var targets: [(name: String, path: String, isTest: Bool)] = []
        /// What `docbuild` builds: the products' package targets.
        var documentation: [String] = []
        /// The scheme's library products for coverage (name, package framework).
        var coverageLibraries: [(name: String, framework: String)] = []
    }
    var package: PackageBuild?
    /// The build system action when it is not the scheme action's
    /// (`exportloc` for localization export).
    var parameterAction: String?
    /// `regular` or `legacy` build locations, when not decided by the scheme.
    var locationStyle: String?

    func parameters(action: BuildAction) -> BuildParameters {
        var p = BuildParameters(action: action == .clean ? "clean" : action.rawValue == "build-for-testing" ? "build" : action.rawValue,
                                configuration: configuration, arena: arena, runDestination: runDestination,
                                overrides: overrides, xcconfigPath: xcconfig?.absolute)
        p.synthesized = synthesized
        if let a = parameterAction { p.action = a }
        if action == .archive, let locations = archiveLocations { p.synthesized += locations.settings }
        return p
    }

    /// Where `archive` builds: `<Intermediates>/ArchiveIntermediates/<scheme>/…`
    /// (`specs/xcodebuild/archive.md` §2).
    struct ArchiveLocations {
        var base: String
        var dstroot: String { base + "/InstallationBuildProductsLocation" }
        var objroot: String { base + "/IntermediateBuildFilesPath" }
        var symroot: String { base + "/BuildProductsPath" }
        var precomps: String { base + "/PrecompiledHeaders" }
        var settings: [(String, String)] {
            [("DSTROOT", dstroot), ("OBJROOT", objroot), ("SYMROOT", symroot), ("SHARED_PRECOMPS_DIR", precomps),
             // Folders the distribution steps read, and archive-only switches.
             ("ASSET_PACK_FOLDER_PATH", dstroot + "/OnDemandResources"),
             ("ASSETCATALOG_COMPILER_FLATTENED_APP_ICON_PATH", symroot + "/ProductIcon.png"),
             ("MESSAGES_APPLICATION_EXTENSION_SUPPORT_FOLDER_PATH", symroot + "/MessagesApplicationExtensionSupport"),
             ("MESSAGES_APPLICATION_SUPPORT_FOLDER_PATH", symroot + "/MessagesApplicationSupport"),
             ("SIGNATURE_METADATA_FOLDER_PATH", symroot + "/Signatures"),
             ("SWIFT_STDLIB_TOOL_UNSIGNED_DESTINATION_DIR", symroot + "/SwiftSupport"),
             ("WATCHKIT_2_SUPPORT_FOLDER_PATH", symroot + "/WatchKitSupport2"),
             ("ENABLE_SIGNATURE_AGGREGATION", "YES"), ("INDEX_ENABLE_DATA_STORE", "NO")]
        }
    }

    var archiveLocations: ArchiveLocations? {
        guard let scheme, let arena else { return nil }
        return ArchiveLocations(base: arena.buildIntermediatesPath + "/ArchiveIntermediates/" + scheme.name)
    }

    static func make(_ inv: Invocation, container: Container, context ctx: XcodebuildContext, sdk: SDKEntry?) throws(XcodebuildFailure) -> Plan {
        let actions = inv.actions.isEmpty ? [BuildAction.build] : inv.actions
        var overrides: [(String, String)] = []
        if !inv.archs.isEmpty { overrides.append(("ARCHS", inv.archs.joined(separator: " "))) }
        if let sdk { overrides.append(("SDKROOT", inv.sdk!.contains("/") ? sdk.path : sdk.canonicalName)) }
        // Later assignments of the same name win.
        for (k, v) in inv.overrides {
            overrides.removeAll { $0.0 == k }
            overrides.append((k, v))
        }
        let xcconfig = inv.xcconfig.map { x in (x, x.hasPrefix("/") ? x : ctx.cwd + "/" + x) }

        if let schemeName = inv.scheme {
            let schemes = container.schemes(user: ctx.user)
            guard let scheme = schemes.first(where: { $0.name == schemeName }) else {
                let kind = container.kind == .workspace ? "workspace" : "project"
                throw XcodebuildFailure("The \(kind) named \"\(container.name)\" does not contain a scheme named \"\(schemeName)\". The \"-list\" option can be used to find the names of the schemes in the \(kind).", exitCode: ExitCode.dataError)
            }
            let first = actions.first ?? .build
            let schemeAction: Scheme.Action
            switch first {
            case .test, .buildForTesting, .testWithoutBuilding: schemeAction = .testing
            case .archive: schemeAction = .archiving
            case .analyze: schemeAction = .analyzing
            default: schemeAction = .running
            }
            var targets: [SettingsTarget] = []
            if !inv.targets.isEmpty, let main = container.projects.first {
                for n in inv.targets {
                    guard let t = main.target(named: n) else {
                        throw XcodebuildFailure("The project '\(main.url.lastPathComponent)' does not contain a target named '\(n)'.", exitCode: ExitCode.dataError)
                    }
                    targets.append(SettingsTarget(project: main, target: t))
                }
            } else {
                for e in scheme.buildEntries where e.actions.contains(schemeAction) {
                    guard let p = container.project(for: e.reference, schemeBundle: scheme.url),
                          let t = p.proj[e.reference.blueprintIdentifier] ?? p.target(named: e.reference.blueprintName) else { continue }
                    targets.append(SettingsTarget(project: p, target: t))
                }
                if schemeAction == .testing {
                    for tt in scheme.testables where !tt.skipped {
                        guard let p = container.project(for: tt.reference, schemeBundle: scheme.url),
                              let t = p.proj[tt.reference.blueprintIdentifier],
                              !targets.contains(where: { $0.target.id == t.id && $0.project.url == p.url }) else { continue }
                        targets.append(SettingsTarget(project: p, target: t))
                    }
                }
            }
            let actionElement: String = switch schemeAction {
            case .testing: "TestAction"
            case .archiving: "ArchiveAction"
            case .analyzing: "AnalyzeAction"
            case .profiling: "ProfileAction"
            default: "LaunchAction"
            }
            var configuration = inv.configuration ?? scheme.configuration(for: actionElement)
            if let c = inv.configuration, let p = targets.first?.project ?? container.projects.first, !p.configurationNames.contains(c) {
                ctx.console.warning("Configuration \(c) is not in the project. Building default configuration.")
                ctx.console.err()
                configuration = p.defaultConfigurationName
            }
            let derivedData = inv.derivedDataPath.map { PathText.withoutPrivatePrefix(URL(fileURLWithPath: $0.hasPrefix("/") ? $0 : ctx.cwd + "/" + $0).standardizedFileURL.path) }
            let arena = Arena.forContainer(container, derivedDataPath: derivedData, derivedDataRoot: ctx.derivedDataRoot)
            let (dest, deviceSettings) = try Destinations.runDestination(for: inv.destinations, targets: targets, configuration: configuration, overrides: overrides,
                                                                         generic: schemeAction == .archiving, context: ctx)
            var synthesized = deviceSettings
            // Code coverage: from the scheme, or -enableCodeCoverage YES|NO.
            let coverage = schemeAction != .archiving && (inv.value("-enableCodeCoverage").map { $0.uppercased() == "YES" } ?? AutocreatedScheme.collectsCoverage(scheme))
            if coverage {
                let buildFolder = URL(fileURLWithPath: arena.buildProductsPath).deletingLastPathComponent().path
                synthesized += [("CLANG_COVERAGE_MAPPING", "YES"), ("CLANG_PROFILE_DATA_DIRECTORY", buildFolder + "/ProfileData")]
            }
            var plan = Plan(container: container, scheme: scheme, actions: actions, targets: targets, configuration: configuration,
                            overrides: overrides, xcconfig: xcconfig, arena: arena, runDestination: dest, synthesized: synthesized)
            plan.coverage = coverage
            return plan
        }

        guard let main = container.mainProject else {
            throw XcodebuildFailure("If you specify a workspace then you must also specify a scheme.  Use -list to see the schemes in this workspace.", exitCode: ExitCode.usage)
        }
        var targets: [SettingsTarget] = []
        if inv.has("-alltargets") {
            targets = main.targets.filter { ProjectPIF.targetKind($0) != nil }.map { SettingsTarget(project: main, target: $0) }
            // The reference tool lists the first target once more at the end.
            if let first = targets.first { targets.append(first) }
        } else if !inv.targets.isEmpty {
            for n in inv.targets {
                guard let t = main.target(named: n) else {
                    throw XcodebuildFailure("The project '\(main.url.lastPathComponent)' does not contain a target named '\(n)'.", exitCode: ExitCode.dataError)
                }
                targets.append(SettingsTarget(project: main, target: t))
            }
        } else if let first = main.targets.first(where: { ProjectPIF.targetKind($0) != nil }) {
            targets = [SettingsTarget(project: main, target: first)]
        }
        var configuration = inv.configuration ?? main.defaultConfigurationName
        if let c = inv.configuration, !main.configurationNames.contains(c) {
            ctx.console.warning("Configuration \(c) is not in the project. Building default configuration.")
            ctx.console.err()
            configuration = main.defaultConfigurationName
        }
        return Plan(container: container, scheme: nil, actions: actions, targets: targets, configuration: configuration,
                    overrides: overrides, xcconfig: xcconfig, arena: nil, runDestination: nil)
    }

    /// "Build settings from command line:" and "…from configuration file …"
    /// sections (cli.md §3, show-build-settings.md §1).
    func printCommandLineSettings(_ console: Console) {
        if !overrides.isEmpty {
            console.out("Build settings from command line:")
            for (k, v) in overrides.sorted(by: { $0.0 < $1.0 }) { console.out("    \(k) = \(v)") }
            console.out()
        }
        if let x = xcconfig {
            console.out("Build settings from configuration file '\(x.given)':")
            for (k, v) in XcconfigListing.assignments(path: x.absolute).sorted(by: { $0.0 < $1.0 }) { console.out("    \(k) = \(v)") }
            console.out()
        }
    }
}

/// Paths as the reference tool prints them.
enum PathText {
    /// `/private/tmp/x` → `/tmp/x` (also `/private/var`, `/private/etc`):
    /// the top-level name is a link into `/private`.
    static func withoutPrivatePrefix(_ p: String) -> String {
        guard p.hasPrefix("/private/") else { return p }
        let rest = p.dropFirst("/private".count)
        let top = "/" + (rest.dropFirst().split(separator: "/").first.map(String.init) ?? "")
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: top),
              dest == "private" + top || dest == "/private" + top else { return p }
        return String(rest)
    }
}

/// The plain `NAME = value` lines of an xcconfig, for the header listing.
enum XcconfigListing {
    static func assignments(path: String) -> [(String, String)] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            out.removeAll { $0.0 == name }
            out.append((name, value))
        }
        return out
    }
}
