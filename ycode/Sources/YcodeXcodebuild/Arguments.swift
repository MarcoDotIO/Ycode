import Foundation

/// The xcodebuild command-line grammar. See `specs/xcodebuild/cli.md` §1.
public struct OptionSpec: Sendable {
    public enum Arity: Sendable { case flag, value }
    public var name: String
    public var arity: Arity
    public var repeatable: Bool
    /// Argument placeholder for `-help` (empty for flags).
    public var placeholder: String
    /// Ycode's own one-line description for `-help`.
    public var summary: String
}

public enum BuildAction: String, CaseIterable, Sendable {
    case build
    case buildForTesting = "build-for-testing"
    case analyze, archive, test
    case testWithoutBuilding = "test-without-building"
    case docbuild, installsrc, install, clean

    /// The banner word: `** <WORD> SUCCEEDED **`.
    public var bannerWord: String {
        switch self {
        case .build: "BUILD"
        case .buildForTesting: "TEST BUILD"
        case .analyze: "ANALYZE"
        case .archive: "ARCHIVE"
        case .test: "TEST"
        case .testWithoutBuilding: "TEST EXECUTE"
        case .docbuild: "BUILD DOCUMENTATION"
        case .installsrc: "INSTALLSRC"
        case .install: "INSTALL"
        case .clean: "CLEAN"
        }
    }
}

/// The parsed command line.
public struct Invocation: Sendable {
    /// The arguments as given (without the tool name).
    public var arguments: [String]
    public var actions: [BuildAction] = []
    public var flags: Set<String> = []
    /// Value options in order of appearance.
    public var values: [(name: String, value: String)] = []
    /// `NAME=value` overrides in order of appearance (empty names dropped).
    public var overrides: [(name: String, value: String)] = []
    /// `-userdefault=value` user defaults in order of appearance.
    public var userDefaults: [(name: String, value: String)] = []
    /// `-sdk` given without a value (allowed with `-version`).
    public var sdkWithoutValue = false
    /// Trailing info items for `-version` (words after `-version` that are
    /// not actions).
    public var infoItems: [String] = []

    public init(arguments: [String]) { self.arguments = arguments }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
    public func value(_ name: String) -> String? { values.last { $0.name == name }?.value }
    public func all(_ name: String) -> [String] { values.filter { $0.name == name }.map(\.value) }

    public var project: String? { value("-project") }
    public var workspace: String? { value("-workspace") }
    public var scheme: String? { value("-scheme") }
    public var targets: [String] { all("-target") }
    public var configuration: String? { value("-configuration") }
    public var sdk: String? { value("-sdk") }
    public var archs: [String] { all("-arch") }
    public var destinations: [String] { all("-destination") }
    public var derivedDataPath: String? { value("-derivedDataPath") }
    public var xcconfig: String? { value("-xcconfig") }
    public var json: Bool { has("-json") }
    public var quiet: Bool { has("-quiet") || has("-json") }
}

/// A failure that ends the run with an xcodebuild-style message.
public struct XcodebuildFailure: Error, Equatable, Sendable {
    /// Message lines, each printed as `xcodebuild: error: <line>`.
    public var messages: [String]
    public var exitCode: Int32
    /// Followed by a blank line and the option help.
    public var withUsage = false
    /// Followed by one blank line.
    public var trailingBlank = false

    public init(_ message: String, exitCode: Int32, withUsage: Bool = false, trailingBlank: Bool = false) {
        messages = [message]
        self.exitCode = exitCode
        self.withUsage = withUsage
        self.trailingBlank = trailingBlank
    }

    public init(messages: [String], exitCode: Int32) {
        self.messages = messages
        self.exitCode = exitCode
    }
}

/// `sysexits.h` codes used by xcodebuild.
public enum ExitCode {
    public static let ok: Int32 = 0
    public static let usage: Int32 = 64
    public static let dataError: Int32 = 65
    public static let noInput: Int32 = 66
    public static let software: Int32 = 70
    public static let config: Int32 = 78
}

public enum ArgumentParser {
    static func flag(_ n: String, _ s: String) -> OptionSpec { OptionSpec(name: n, arity: .flag, repeatable: false, placeholder: "", summary: s) }
    static func value(_ n: String, _ p: String, _ s: String, repeatable: Bool = false) -> OptionSpec {
        OptionSpec(name: n, arity: .value, repeatable: repeatable, placeholder: p, summary: s)
    }

    /// Every option, in `-help` order.
    public static let options: [OptionSpec] = [
        flag("-usage", "print the usage lines"),
        flag("-help", "print the usage lines and every option"),
        flag("-verbose", "print more status output"),
        flag("-license", "(Xcode installation management; not supported)"),
        flag("-checkFirstLaunchStatus", "(Xcode installation management; not supported)"),
        flag("-runFirstLaunch", "(Xcode installation management; not supported)"),
        flag("-checkForNewerComponents", "(Xcode installation management; not supported)"),
        flag("-downloadAllPlatforms", "(Xcode installation management; not supported)"),
        flag("-prepareDeviceSupport", "(device support; not supported)"),
        value("-platform", "PLATFORM", "platform for device support"),
        value("-osVersion", "VERSION", "OS version for device support"),
        value("-modelCode", "CODE", "model code for device support"),
        value("-architecture", "ARCH", "architecture for device support"),
        value("-downloadPlatform", "NAME", "(Xcode installation management; not supported)"),
        value("-importPlatform", "DMG_Path", "(Xcode installation management; not supported)"),
        value("-downloadComponent", "NAME", "(Xcode installation management; not supported)"),
        value("-importComponent", "NAME", "(Xcode installation management; not supported)"),
        value("-deleteComponent", "NAME", "(Xcode installation management; not supported)"),
        value("-showComponent", "NAME", "(Xcode installation management; not supported)"),
        value("-buildVersion", "VERSION", "version of a platform or component to download"),
        value("-architectureVariant", "VARIANT", "architecture variant of a platform to download"),
        value("-project", "NAME", "use the project NAME (.xcodeproj)"),
        value("-target", "NAME", "build the target NAME (no scheme)", repeatable: true),
        flag("-alltargets", "build every target of the project (no scheme)"),
        value("-workspace", "NAME", "use the workspace NAME (.xcworkspace)"),
        value("-scheme", "NAME", "use the scheme NAME"),
        value("-configuration", "NAME", "use the build configuration NAME"),
        value("-xcconfig", "PATH", "apply the assignments in the xcconfig file PATH as overrides"),
        value("-arch", "ARCH", "build for ARCH (overrides ARCHS)", repeatable: true),
        value("-sdk", "SDK", "base SDK, by name or path (overrides SDKROOT)"),
        value("-toolchain", "NAME", "use the toolchain with this name or identifier"),
        value("-destination", "DESTINATIONSPECIFIER", "run destination, key=value pairs separated by commas", repeatable: true),
        value("-destination-timeout", "TIMEOUT", "seconds to wait for a destination"),
        flag("-parallelizeTargets", "build independent targets in parallel"),
        value("-jobs", "NUMBER", "maximum number of concurrent build tasks"),
        value("-maximum-concurrent-test-device-destinations", "NUMBER", "maximum device destinations tested at once"),
        value("-maximum-concurrent-test-simulator-destinations", "NUMBER", "maximum simulator destinations tested at once"),
        value("-parallel-testing-enabled", "YES|NO", "override the scheme's parallel testing setting"),
        value("-parallel-testing-worker-count", "NUMBER", "exact number of parallel test runners"),
        value("-maximum-parallel-testing-workers", "NUMBER", "maximum number of parallel test runners"),
        flag("-quiet", "print only warnings, errors and requested data"),
        flag("-hideShellScriptEnvironment", "do not print shell script environments in the log"),
        flag("-showsdks", "list the installed SDKs"),
        flag("-showdestinations", "list the run destinations of a scheme"),
        flag("-showTestPlans", "list the test plans of a scheme"),
        flag("-showBuildSettings", "print the resolved build settings"),
        flag("-showBuildSettingsForIndex", "(index build settings; not supported)"),
        flag("-list", "list targets, configurations and schemes"),
        value("-convert-project", "FORMAT", "(project conversion; not supported)"),
        value("-find-executable", "NAME", "(not supported)"),
        value("-find-library", "NAME", "(not supported)"),
        flag("-version", "print the tool version; with -sdk, SDK details"),
        value("-enableAddressSanitizer", "YES|NO", "turn the address sanitizer on or off"),
        value("-enableThreadSanitizer", "YES|NO", "turn the thread sanitizer on or off"),
        value("-enableUndefinedBehaviorSanitizer", "YES|NO", "turn the undefined behavior sanitizer on or off"),
        value("-resultBundlePath", "PATH", "where to write a result bundle (not written yet)"),
        value("-resultStreamPath", "PATH", "where to write a result stream (not written yet)"),
        value("-resultBundleVersion", "3", "result bundle version"),
        value("-clonedSourcePackagesDirPath", "PATH", "directory for checked-out packages"),
        value("-derivedDataPath", "PATH", "directory for build products and intermediates"),
        value("-archivePath", "PATH", "where archives are written or read"),
        flag("-exportArchive", "(archive export; not supported)"),
        flag("-exportNotarizedApp", "(notarized export; not supported)"),
        value("-exportOptionsPlist", "PATH", "archive export options"),
        value("-enableCodeCoverage", "YES|NO", "turn code coverage on or off for tests"),
        value("-enableCodesizeProfile", "YES|NO", "produce code size profiling output"),
        value("-codesizeProfileOutputDir", "PATH", "directory for code size profiling output"),
        value("-exportPath", "PATH", "destination of an export"),
        value("-importPath", "PATH", "source of an import"),
        flag("-skipUnavailableActions", "skip scheme actions that cannot be performed"),
        flag("-exportLocalizations", "export localizations to localization catalogs (.xcloc)"),
        flag("-importLocalizations", "import localizations from a localization catalog or XLIFF file"),
        value("-localizationPath", "PATH", "XLIFF localization files"),
        value("-exportLanguage", "LANGUAGE", "language to export", repeatable: true),
        value("-defaultLanguage", "LANGUAGE", "source language of an export"),
        flag("-includeScreenshots", "include screenshots in a localization export"),
        flag("-mergeImport", "merge a localization import"),
        value("-xctestrun", "PATH", "test run specification"),
        value("-testProductsPath", "PATH", "test products"),
        value("-enablePerformanceTestsDiagnostics", "YES|NO", "collect performance test diagnostics"),
        value("-testPlan", "NAME", "test plan of the scheme"),
        value("-only-testing", "TEST-IDENTIFIER", "run only these tests", repeatable: true),
        value("-skip-testing", "TEST-IDENTIFIER", "skip these tests", repeatable: true),
        value("-test-timeouts-enabled", "YES|NO", "enable test timeouts"),
        value("-default-test-execution-time-allowance", "SECONDS", "default time allowance per test"),
        value("-maximum-test-execution-time-allowance", "SECONDS", "maximum time allowance per test"),
        value("-test-iterations", "NUMBER", "run tests NUMBER times"),
        flag("-retry-tests-on-failure", "retry failing tests"),
        flag("-run-tests-until-failure", "repeat tests until one fails"),
        value("-test-repetition-relaunch-enabled", "YES|NO", "relaunch for each repetition"),
        value("-only-test-configuration", "NAME", "run only this test configuration", repeatable: true),
        value("-skip-test-configuration", "NAME", "skip this test configuration", repeatable: true),
        value("-collect-test-diagnostics", "on-failure|never", "collect diagnostics on failure"),
        value("-testLanguage", "LANGUAGE", "run tests in this language"),
        value("-testRegion", "REGION", "run tests in this region"),
        flag("-enumerate-tests", "list tests without running them"),
        value("-test-enumeration-style", "STYLE", "flat or hierarchical"),
        value("-test-enumeration-format", "FORMAT", "text or json"),
        value("-test-enumeration-output-path", "PATH", "where to write the enumeration (- for stdout)"),
        flag("-resolvePackageDependencies", "resolve the Swift package dependencies"),
        flag("-disableAutomaticPackageResolution", "use only the versions in Package.resolved"),
        flag("-onlyUsePackageVersionsFromResolvedFile", "use only the versions in Package.resolved"),
        flag("-skipPackageUpdates", "do not update package dependencies"),
        flag("-disablePackageRepositoryCache", "do not cache package repositories"),
        flag("-skipPackagePluginValidation", "do not validate package plugins"),
        flag("-skipMacroValidation", "do not validate macros"),
        value("-packageCachePath", "PATH", "package caches"),
        value("-packageAuthorizationProvider", "keychain|netrc", "credential store for packages"),
        value("-defaultPackageRegistryURL", "URL", "default package registry"),
        value("-packageDependencySCMToRegistryTransformation", "MODE", "none, useRegistryIdentity or useRegistryIdentityAndSources"),
        flag("-skipPackageSignatureValidation", "do not validate package signatures"),
        value("-packageFingerprintPolicy", "warn|strict", "package fingerprint policy"),
        value("-packageSigningEntityPolicy", "warn|strict", "package signing entity policy"),
        flag("-json", "print JSON (implies -quiet)"),
        flag("-allowProvisioningUpdates", "(provisioning; accepted, no effect)"),
        flag("-allowProvisioningDeviceRegistration", "(provisioning; accepted, no effect)"),
        value("-authenticationKeyPath", "PATH", "App Store Connect key"),
        value("-authenticationKeyID", "ID", "App Store Connect key identifier"),
        value("-authenticationKeyIssuerID", "ID", "App Store Connect issuer identifier"),
        value("-scmProvider", "system|xcode", "Git implementation"),
        flag("-showBuildTimingSummary", "print a summary of task timings"),
        flag("-create-xcframework", "(XCFramework creation; not supported)"),
        value("-framework", "PATH", "framework for -create-xcframework", repeatable: true),
        value("-library", "PATH", "library for -create-xcframework", repeatable: true),
        value("-headers", "PATH", "headers for -create-xcframework", repeatable: true),
        value("-debug-symbols", "PATH", "debug symbols for -create-xcframework", repeatable: true),
        value("-output", "PATH", "output of -create-xcframework"),
        value("-dumpPIF", "PATH", "(not supported)"),
    ]

    static let byName: [String: OptionSpec] = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0) })

    /// Options whose attached form `-name:VALUE` is accepted.
    static let attachedValueOptions: Set<String> = ["-only-testing", "-skip-testing"]

    public static func parse(_ args: [String]) throws(XcodebuildFailure) -> Invocation {
        var inv = Invocation(arguments: args)
        var i = 0
        while i < args.count {
            let a = args[i]
            i += 1
            if a.hasPrefix("-") {
                if a == "-dry-run" {
                    throw XcodebuildFailure("option '-dry-run' is no longer supported", exitCode: ExitCode.usage, withUsage: true)
                }
                var name = a
                var inline: String?
                if let eq = a.firstIndex(of: "="), byName[String(a[..<eq])]?.arity == .value {
                    name = String(a[..<eq])
                    inline = String(a[a.index(after: eq)...])
                } else if let colon = a.firstIndex(of: ":"), attachedValueOptions.contains(String(a[..<colon])) {
                    name = String(a[..<colon])
                    inline = String(a[a.index(after: colon)...])
                }
                // `-userdefault=value`: a user default for this run.
                if byName[name] == nil, inline == nil, let eq = a.firstIndex(of: "=") {
                    let key = String(a[a.index(after: a.startIndex)..<eq])
                    if !key.isEmpty { inv.userDefaults.append((key, String(a[a.index(after: eq)...]))) }
                    continue
                }
                guard let spec = byName[name] else {
                    throw XcodebuildFailure("invalid option '\(a)'", exitCode: ExitCode.usage, withUsage: true)
                }
                switch spec.arity {
                case .flag:
                    inv.flags.insert(name)
                case .value:
                    let v: String
                    if let inline { v = inline }
                    else if i < args.count {
                        // `-sdk` may stand alone with `-version` (`-version -sdk`).
                        if name == "-sdk", args[i].hasPrefix("-") {
                            inv.sdkWithoutValue = true
                            continue
                        }
                        v = args[i]
                        i += 1
                    } else if name == "-sdk" {
                        inv.sdkWithoutValue = true
                        continue
                    } else {
                        throw XcodebuildFailure("option '\(name)' requires an argument", exitCode: ExitCode.usage, withUsage: true)
                    }
                    if !spec.repeatable, inv.values.contains(where: { $0.name == name }) {
                        throw XcodebuildFailure("option '\(name)' may only be provided once", exitCode: ExitCode.usage, withUsage: true)
                    }
                    inv.values.append((name, v))
                }
            } else if let eq = a.firstIndex(of: "=") {
                let n = String(a[..<eq])
                if !n.isEmpty { inv.overrides.append((n, String(a[a.index(after: eq)...]))) }
            } else if let action = BuildAction(rawValue: a) {
                inv.actions.append(action)
            } else {
                // An info item for `-version`; otherwise an unknown action
                // (reported once the container is open).
                inv.infoItems.append(a)
            }
        }
        if inv.sdkWithoutValue && !inv.has("-version") {
            throw XcodebuildFailure("-sdk must be supplied with an argument unless used with -version", exitCode: ExitCode.usage)
        }
        if let jobs = inv.value("-jobs"), (Int(jobs) ?? 0) < 1 {
            throw XcodebuildFailure("You cannot specify -jobs with less than 1 job.", exitCode: ExitCode.usage)
        }
        return inv
    }
}
