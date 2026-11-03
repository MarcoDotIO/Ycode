import Foundation
import YcodeProject
import YcodeSettings
import YcodeWorkspace
import YcodeXcodebuild

/// What the build server computes settings for: the configuration, the
/// destination, where index products go and the host. See
/// `specs/ide/language.md` §Build server.
public struct BuildContext: Sendable {
    /// The build configuration (nil: the scheme's run configuration, else
    /// `Debug` when the project has it, else the project's default).
    public var configuration: String?
    /// A destination specifier (`platform=iOS Simulator,arch=arm64`, …).
    public var destination: String?
    /// The container's derived-data folder (`<root>/<name>-<hash>`); index
    /// products, intermediates and the index store live under its
    /// `Index.noindex`.
    public var derivedDataFolder: String
    public var developerDirectory: String?
    public var hostArchitecture: String
    /// True on Linux: no Apple SDKs; Swift compiles for the host.
    public var isLinuxHost: Bool

    public init(configuration: String? = nil, destination: String? = nil, derivedDataFolder: String,
                developerDirectory: String? = nil, hostArchitecture: String = BuildContext.currentArchitecture,
                isLinuxHost: Bool = BuildContext.currentIsLinux) {
        self.configuration = configuration
        self.destination = destination
        self.derivedDataFolder = derivedDataFolder
        self.developerDirectory = developerDirectory
        self.hostArchitecture = hostArchitecture
        self.isLinuxHost = isLinuxHost
    }

    public var indexRoot: String { derivedDataFolder + "/Index.noindex" }
    public var productsRoot: String { indexRoot + "/Build/Products" }
    public var intermediatesRoot: String { indexRoot + "/Build/Intermediates.noindex" }
    /// Where compilers write index data (`-index-store-path`).
    public var indexStorePath: String { indexRoot + "/DataStore" }
    /// sourcekit-lsp's own database over the index store.
    public var indexDatabasePath: String { indexRoot + "/ycode-index-db" }

    #if arch(arm64)
    public static let currentArchitecture = "arm64"
    #else
    public static let currentArchitecture = "x86_64"
    #endif
    #if os(Linux)
    public static let currentIsLinux = true
    #else
    public static let currentIsLinux = false
    #endif

    /// The default derived-data root: `~/Library/Developer/Ycode/DerivedData`
    /// on macOS, `$XDG_CACHE_HOME/ycode/DerivedData` (or
    /// `~/.cache/ycode/DerivedData`) on Linux.
    public static func defaultDerivedDataRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        if currentIsLinux {
            return (environment["XDG_CACHE_HOME"] ?? home + "/.cache") + "/ycode/DerivedData"
        }
        return home + "/Library/Developer/Ycode/DerivedData"
    }

    /// `<root>/<name>-<hash of the container path>`, the folder naming
    /// Ycode's ycodebuild uses.
    public static func derivedDataFolder(for container: URL, root: String) -> String {
        let name = container.deletingPathExtension().lastPathComponent
        return root + "/" + DerivedDataName.folder(name: name, path: container.standardizedFileURL.path)
    }
}

/// The SDK a target is indexed for. A device SDK becomes its simulator
/// (indexing does not need a device); a destination on the same platform
/// family wins. See `specs/ide/language.md` §Build server, "Destination".
public enum PlatformChoice {
    static let simulatorOf = ["iphoneos": "iphonesimulator", "appletvos": "appletvsimulator", "watchos": "watchsimulator",
                              "xros": "xrsimulator"]
    static let deviceOf = Dictionary(uniqueKeysWithValues: simulatorOf.map { ($1, $0) })

    /// `iPhoneOS18.0.sdk` → `iphoneos`, `iphonesimulator27.0` → `iphonesimulator`.
    public static func baseName(_ sdkroot: String) -> String {
        var s = (sdkroot as NSString).lastPathComponent.lowercased()
        if s.hasSuffix(".sdk") { s = String(s.dropLast(4)) }
        while let last = s.last, last.isNumber || last == "." { s.removeLast() }
        return s
    }

    /// The platform family: `iphoneos` and `iphonesimulator` are one.
    static func family(_ base: String) -> String { deviceOf[base] ?? base }

    /// The SDK of a destination specifier (`platform=iOS Simulator` →
    /// `iphonesimulator`), nil when it names none.
    public static func sdk(forDestination spec: String) -> String? {
        let fields = Dictionary(spec.split(separator: ",").compactMap { part -> (String, String)? in
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { return nil }
            return (kv[0].replacingOccurrences(of: "generic/", with: ""), kv[1])
        }, uniquingKeysWith: { a, _ in a })
        if let sdk = fields["sdk"] { return baseName(sdk) }
        switch fields["platform"]?.lowercased() {
        case "macos", "mac catalyst"?: return "macosx"
        case "ios": return "iphoneos"
        case "ios simulator": return "iphonesimulator"
        case "tvos": return "appletvos"
        case "tvos simulator": return "appletvsimulator"
        case "watchos": return "watchos"
        case "watchos simulator": return "watchsimulator"
        case "visionos", "xros": return "xros"
        case "visionos simulator", "xros simulator": return "xrsimulator"
        case "driverkit": return "driverkit"
        default: return nil
        }
    }

    /// The `arch=` of a destination specifier.
    public static func architecture(forDestination spec: String) -> String? {
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "arch" { return kv[1] }
        }
        return nil
    }

    /// The SDK to index a target for: from `SDKROOT` (`auto` or empty:
    /// the first of `SUPPORTED_PLATFORMS`), replaced by the destination's
    /// SDK when that is on a platform the target supports; device SDKs
    /// become simulators unless the destination names the device.
    public static func sdk(sdkroot: String, supportedPlatforms: String, destinationSDK: String?) -> String {
        let supported = supportedPlatforms.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { baseName(String($0)) }
        let base = baseName(sdkroot)
        let candidates = (base.isEmpty || base == "auto") ? supported : [base] + supported
        if let d = destinationSDK, candidates.contains(where: { family($0) == family(d) }) { return d }
        guard let first = candidates.first else { return "macosx" }
        return simulatorOf[first] ?? first
    }
}

/// Produces each target's build settings for indexing.
public protocol IndexSettingsSource: Sendable {
    /// Settings per target identifier.
    func settings(for targets: [BuildGraph.Target], in graph: BuildGraph, context: BuildContext) throws -> [String: [String: String]]
}

/// Ycode's own settings engine (`YcodeSettings`): the project's levels over
/// a defaults level with the build-location and naming defaults the
/// compiler arguments need (values from swift-build's open-source
/// specifications), for the chosen SDK.
public struct ResolverSettingsSource: IndexSettingsSource {
    public init() {}

    public func settings(for targets: [BuildGraph.Target], in graph: BuildGraph, context: BuildContext) throws -> [String: [String: String]] {
        let catalog = context.developerDirectory.map { SDKCatalog(developerDirectory: $0) }
        var out: [String: [String: String]] = [:]
        let destinationSDK = context.destination.flatMap(PlatformChoice.sdk(forDestination:))
        let arch = context.destination.flatMap(PlatformChoice.architecture(forDestination:)) ?? context.hostArchitecture
        for t in targets {
            let p = graph.project(of: t)
            let configuration = Self.configuration(context.configuration, project: p)
            // First pass: the target's own SDKROOT and platforms.
            var builder = ProjectSettingsBuilder(proj: p.proj, xcodeprojURL: p.url)
            builder.developerDirectory = context.developerDirectory
            let first = try builder.resolve(target: t.name, configuration: configuration).settings
            let sdkName = PlatformChoice.sdk(sdkroot: first["SDKROOT"], supportedPlatforms: first["SUPPORTED_PLATFORMS"],
                                             destinationSDK: destinationSDK)
            let sdk = catalog?.lookup(sdkName)
            builder.sdkLookup = { name in catalog?.lookup(name) }
            builder.defaults = Self.defaults(sdkName: sdkName, sdk: sdk, arch: arch, context: context)
            builder.overrides = ["SDKROOT": sdk?.canonicalName ?? sdkName]
            var all = try builder.resolve(target: t.name, configuration: configuration).settings.all()
            // Without an installed SDK (Linux) the setting stays a name.
            if sdk == nil { all["SDKROOT"] = context.isLinuxHost ? "" : sdkName }
            out[t.id] = all
        }
        return out
    }

    /// The configuration to use: the requested one when the project has
    /// it, else Debug, else the project's default.
    static func configuration(_ requested: String?, project p: LoadedProject) -> String {
        if let r = requested, p.configurationNames.contains(r) { return r }
        if p.configurationNames.contains("Debug") { return "Debug" }
        return p.defaultConfigurationName
    }

    /// `EFFECTIVE_PLATFORM_NAME`: `-<sdk>` except for macOS.
    static func effectivePlatformName(_ sdkName: String) -> String {
        sdkName == "macosx" || sdkName.isEmpty ? "" : "-" + sdkName
    }

    /// The defaults level. Expressions are evaluated with the target's own
    /// levels above them, so a project that sets `PRODUCT_NAME` or
    /// `SYMROOT` still wins.
    static func defaults(sdkName: String, sdk: SDKCatalog.SDK?, arch: String, context: BuildContext) -> SettingsLevel {
        let pairs: [(key: String, value: String)] = [
            ("PRODUCT_NAME", "$(TARGET_NAME)"),
            ("PRODUCT_MODULE_NAME", "$(PRODUCT_NAME:c99extidentifier)"),
            ("SWIFT_MODULE_NAME", "$(PRODUCT_MODULE_NAME)"),
            ("SWIFT_OBJC_INTERFACE_HEADER_NAME", "$(SWIFT_MODULE_NAME)-Swift.h"),
            ("BUILD_DIR", "$(SYMROOT)"),
            ("CONFIGURATION_BUILD_DIR", "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"),
            ("BUILT_PRODUCTS_DIR", "$(CONFIGURATION_BUILD_DIR)"),
            ("PROJECT_TEMP_ROOT", "$(OBJROOT)"),
            ("PROJECT_TEMP_DIR", "$(PROJECT_TEMP_ROOT)/$(PROJECT_NAME).build"),
            ("CONFIGURATION_TEMP_DIR", "$(PROJECT_TEMP_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)"),
            ("TARGET_TEMP_DIR", "$(CONFIGURATION_TEMP_DIR)/$(TARGET_NAME).build"),
            ("TEMP_DIR", "$(TARGET_TEMP_DIR)"),
            ("OBJECT_FILE_DIR", "$(TEMP_DIR)/Objects"),
            ("OBJECT_FILE_DIR_normal", "$(OBJECT_FILE_DIR)-normal"),
            ("DERIVED_FILE_DIR", "$(TEMP_DIR)/DerivedSources"),
            ("CURRENT_VARIANT", "normal"),
        ]
        var literals: [String: String] = [
            "SYMROOT": context.productsRoot,
            "OBJROOT": context.intermediatesRoot,
            "PLATFORM_NAME": sdkName,
            "EFFECTIVE_PLATFORM_NAME": effectivePlatformName(sdkName),
            "CURRENT_ARCH": arch,
            "NATIVE_ARCH": context.hostArchitecture,
            "arch": arch,
            "ARCHS": arch,
        ]
        if let dev = context.developerDirectory {
            literals["DEVELOPER_DIR"] = dev
            literals["TOOLCHAIN_DIR"] = dev + "/Toolchains/XcodeDefault.xctoolchain"
            if let platform = sdk?.platform { literals["PLATFORM_DIR"] = dev + "/Platforms/\(platform).platform" }
        }
        if let v = sdk?.version { literals["SDK_VERSION"] = v }
        var level = SettingsLevel(name: "defaults", buildSettings: pairs)
        level.assignments += SettingsLevel(name: "defaults", literals: literals).assignments
        return level
    }
}

/// swift-build's settings (through the `ycode-swb` helper, as ycodebuild
/// uses them), for the same SDK choice. Used when the helper is installed.
public struct SwiftBuildSettingsSource: IndexSettingsSource {
    public var helper: String
    public init(helper: String) { self.helper = helper }

    public func settings(for targets: [BuildGraph.Target], in graph: BuildGraph, context: BuildContext) throws -> [String: [String: String]] {
        // The SDK per target comes from Ycode's resolver; swift-build then
        // evaluates every setting for it.
        let base = try ResolverSettingsSource().settings(for: targets, in: graph, context: context)
        let provider = SwiftBuildSettingsProvider(helper: helper)
        let arena = Arena.forContainer(graph.container, derivedDataPath: context.indexRoot, derivedDataRoot: "")
        var out: [String: [String: String]] = [:]
        var groups: [String: [BuildGraph.Target]] = [:]
        for t in targets { groups[base[t.id]?["PLATFORM_NAME"] ?? "", default: []].append(t) }
        let arch = context.destination.flatMap(PlatformChoice.architecture(forDestination:)) ?? context.hostArchitecture
        for (sdk, group) in groups {
            let configuration = base[group[0].id]?["CONFIGURATION"] ?? "Debug"
            var overrides: [(String, String)] = [("ARCHS", arch), ("ONLY_ACTIVE_ARCH", "YES")]
            if !sdk.isEmpty { overrides.append(("SDKROOT", sdk)) }
            let params = BuildParameters(action: "build", configuration: configuration, arena: arena, overrides: overrides)
            let list = try provider.settings(container: graph.container, targets: group.map {
                SettingsTarget(graph.project(of: $0), graph.project(of: $0).proj[$0.objectID]!)
            }, parameters: params)
            for (t, s) in zip(group, list) { out[t.id] = s.isEmpty ? base[t.id] : s }
        }
        return out
    }
}
