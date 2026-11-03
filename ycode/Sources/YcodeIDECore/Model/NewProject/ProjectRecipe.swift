import Foundation
import YcodePlist
import YcodeProject
import YcodeSubprocess

/// A platform's SDK facts (`templates.md` § "Platform rows",
/// `specs/build-settings.md`): SDK, supported platforms, the
/// deployment-target setting, device family, runpath, and the destination
/// a build check uses.
public struct TemplateSDK: Equatable, Sendable {
    public var platform: String
    public var sdkroot: String
    public var supportedPlatforms: String
    /// Deployment-target setting names (more than one for SDK `auto`).
    public var deploymentKeys: [String]
    public var deviceFamily: String?
    /// `LD_RUNPATH_SEARCH_PATHS` for apps.
    public var runpath: [PlistValue]
    /// The destination a build check uses (`generic/platform=…`).
    public var buildDestination: String
    /// The SDK name `xcrun --sdk` takes for `V(p)`.
    var versionSDK: String

    public static let iOS = TemplateSDK(platform: "iOS", sdkroot: "iphoneos", supportedPlatforms: "iphoneos iphonesimulator",
                                        deploymentKeys: ["IPHONEOS_DEPLOYMENT_TARGET"], deviceFamily: "1,2",
                                        runpath: ["$(inherited)", "@executable_path/Frameworks"], buildDestination: "generic/platform=iOS Simulator",
                                        versionSDK: "iphoneos")
    public static let macOS = TemplateSDK(platform: "macOS", sdkroot: "macosx", supportedPlatforms: "macosx",
                                          deploymentKeys: ["MACOSX_DEPLOYMENT_TARGET"], deviceFamily: nil,
                                          runpath: ["$(inherited)", "@executable_path/../Frameworks"], buildDestination: "platform=macOS",
                                          versionSDK: "macosx")
    public static let watchOS = TemplateSDK(platform: "watchOS", sdkroot: "watchos", supportedPlatforms: "watchos watchsimulator",
                                            deploymentKeys: ["WATCHOS_DEPLOYMENT_TARGET"], deviceFamily: "4",
                                            runpath: ["$(inherited)", "@executable_path/Frameworks"], buildDestination: "generic/platform=watchOS Simulator",
                                            versionSDK: "watchos")
    public static let tvOS = TemplateSDK(platform: "tvOS", sdkroot: "appletvos", supportedPlatforms: "appletvos appletvsimulator",
                                         deploymentKeys: ["TVOS_DEPLOYMENT_TARGET"], deviceFamily: "3",
                                         runpath: ["$(inherited)", "@executable_path/Frameworks"], buildDestination: "generic/platform=tvOS Simulator",
                                         versionSDK: "appletvos")
    public static let visionOS = TemplateSDK(platform: "visionOS", sdkroot: "xros", supportedPlatforms: "xros xrsimulator",
                                             deploymentKeys: ["XROS_DEPLOYMENT_TARGET"], deviceFamily: "7",
                                             runpath: ["$(inherited)", "@executable_path/Frameworks"], buildDestination: "generic/platform=visionOS Simulator",
                                             versionSDK: "xros")
    public static let driverKit = TemplateSDK(platform: "DriverKit", sdkroot: "driverkit", supportedPlatforms: "driverkit",
                                              deploymentKeys: ["DRIVERKIT_DEPLOYMENT_TARGET"], deviceFamily: nil, runpath: [],
                                              buildDestination: "generic/platform=DriverKit", versionSDK: "driverkit")
    /// One target for iPhone, iPad, Mac and Apple Vision (SDK `auto`).
    public static let multiplatform = TemplateSDK(platform: "Multiplatform", sdkroot: "auto",
                                                  supportedPlatforms: "iphoneos iphonesimulator macosx xros xrsimulator",
                                                  deploymentKeys: ["IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET", "XROS_DEPLOYMENT_TARGET"],
                                                  deviceFamily: "1,2,7", runpath: [], buildDestination: "platform=macOS", versionSDK: "")

    public static func forTab(_ tab: String) -> TemplateSDK {
        switch tab {
        case "iOS": .iOS
        case "macOS": .macOS
        case "watchOS": .watchOS
        case "tvOS": .tvOS
        case "visionOS": .visionOS
        case "DriverKit": .driverKit
        case "Multiplatform": .multiplatform
        default: .macOS
        }
    }

    /// `V(p)`: the installed SDK's version (major.minor), from `xcrun`
    /// on a Mac; elsewhere, or without the SDK, Ycode's default.
    public static func version(_ key: String) -> String {
        let sdk: String = switch key {
        case "IPHONEOS_DEPLOYMENT_TARGET": "iphoneos"
        case "MACOSX_DEPLOYMENT_TARGET": "macosx"
        case "WATCHOS_DEPLOYMENT_TARGET": "watchos"
        case "TVOS_DEPLOYMENT_TARGET": "appletvos"
        case "XROS_DEPLOYMENT_TARGET": "xros"
        default: "driverkit"
        }
        return SDKVersions.shared.version(sdk)
    }

    /// The platform row: SDK and deployment target(s).
    var platformRow: [(String, PlistValue)] {
        guard sdkroot != "auto" else { return deploymentKeys.map { ($0, .string(Self.version($0))) } }
        return [("SDKROOT", .string(sdkroot))] + deploymentKeys.map { ($0, .string(Self.version($0))) }
    }

    /// Whether Release adds `VALIDATE_PRODUCT = YES`.
    var validatesProduct: Bool { ["iphoneos", "appletvos", "watchos", "xros"].contains(sdkroot) }
}

/// The installed SDK versions, read once.
final class SDKVersions: @unchecked Sendable {
    static let shared = SDKVersions()
    /// Ycode's default when no SDK can be asked (Linux, tests on a host
    /// without the platform).
    static let fallback = "27.0"
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func version(_ sdk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let v = cache[sdk] { return v }
        var v = Self.fallback
        #if os(macOS)
        if let out = try? Subprocess.run("/usr/bin/xcrun", ["--sdk", sdk, "--show-sdk-version"], captureStderr: false), out.status == 0 {
            let parts = out.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
            if parts.count >= 1, Int(parts[0]) != nil { v = parts.prefix(2).joined(separator: ".") + (parts.count == 1 ? ".0" : "") }
        }
        #endif
        cache[sdk] = v
        return v
    }
}

/// A project to generate (`templates.md` § "Generated project, common to
/// all templates"): targets, the files under the project folder and
/// where they go. `makeProject()` builds the pbxproj object by object.
struct ProjectRecipe {
    struct Embed {
        var name: String
        var targets: [String]
        /// `dstSubfolderSpec` (`build-pif.md` §Copy-files destinations).
        var subfolderSpec: String
        var path: String
        var codeSignOnCopy = false

        static func extensions(_ t: [String]) -> Embed { Embed(name: "Embed Foundation Extensions", targets: t, subfolderSpec: "13", path: "") }
        static func watch(_ t: [String]) -> Embed { Embed(name: "Embed Watch Content", targets: t, subfolderSpec: "16", path: "$(CONTENTS_FOLDER_PATH)/Watch") }
    }

    /// A Copy Files phase that copies files, not products (man pages,
    /// public headers): name, `dstSubfolderSpec`, `dstPath`, whether it
    /// runs only when installing.
    struct CopyPhase {
        var subfolderSpec: String
        var path: String
        var deploymentOnly = false
    }

    struct Target {
        enum Kind: Equatable {
            case native
            /// `PBXLegacyTarget`: runs an external build tool.
            case legacy(tool: String, arguments: String)
        }
        var kind = Kind.native
        var name: String
        var productType: String
        var productPath: String
        var productFileType: String
        /// Synchronized folders the target owns (paths under the project folder).
        var folders: [String]
        /// Items of the target's first folder left out of it (Info.plist).
        var exceptions: [String] = []
        var settings: [(String, PlistValue)]
        var debugSettings: [(String, PlistValue)] = []
        var releaseSettings: [(String, PlistValue)] = []
        var phases: [String] = ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"]
        var copyPhases: [CopyPhase] = []
        var dependencies: [String] = []
        var embeds: [Embed] = []
        /// Names of targets whose products this one links (Frameworks phase).
        var links: [String] = []
        /// For test bundles: the target they test (`TestTargetID`).
        var testedTarget: String?
        /// The target's SDK, for multi-SDK projects (its own platform row).
        var sdk: TemplateSDK?
        /// Swift settings (§ "Swift settings"); nil for Objective-C, C, C++.
        var swiftVersion: String? = "5.0"
        /// SDK frameworks linked by name ("Messages", "DriverKit").
        var sdkFrameworks: [String] = []
    }

    var name: String
    var targets: [Target]
    var files: [(String, String)]
    /// The project's platform row; nil for multi-SDK and SDK-`auto`
    /// projects (each target carries its own).
    var projectSDK: TemplateSDK?
    var projectSettings: [(String, PlistValue)] = []
    /// `DEVELOPMENT_TEAM`, when a team is chosen.
    var team: String?
    /// The `ORGANIZATIONNAME` attribute.
    var organizationName: String?
    /// Whether the project-level Swift configuration settings are written.
    var swift = true
    /// A deployment target replacing `V(p)` in every deployment setting
    /// (`ycode new --option deploymentTarget=…`; tests that run on older
    /// simulator runtimes).
    var deploymentOverride: String?

    func deployment(_ s: [(String, PlistValue)]) -> [(String, PlistValue)] {
        guard let v = deploymentOverride else { return s }
        return s.map { $0.0.hasSuffix("_DEPLOYMENT_TARGET") ? ($0.0, .string(v)) : $0 }
    }

    /// The IDE version the project records (`LastUpgradeCheck` and
    /// `CreatedOnToolsVersion`): the reference release Ycode matches.
    static let toolsVersion = "27.1"
    static var toolsVersionDigits: String { toolsVersion.replacingOccurrences(of: ".", with: "").padding(toLength: 4, withPad: "0", startingAt: 0) }

    /// § "Project-level settings in every template".
    static func common() -> [(String, PlistValue)] {
        var s: [(String, PlistValue)] = [
            ("ALWAYS_SEARCH_USER_PATHS", "NO"), ("ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS", "YES"),
            ("CLANG_ANALYZER_NONNULL", "YES"), ("CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION", "YES_AGGRESSIVE"),
            ("CLANG_CXX_LANGUAGE_STANDARD", "gnu++20"), ("CLANG_ENABLE_MODULES", "YES"), ("CLANG_ENABLE_OBJC_ARC", "YES"),
            ("CLANG_ENABLE_OBJC_WEAK", "YES"),
        ]
        for w in ["BLOCK_CAPTURE_AUTORELEASING", "BOOL_CONVERSION", "COMMA", "CONSTANT_CONVERSION", "DEPRECATED_OBJC_IMPLEMENTATIONS",
                  "DOCUMENTATION_COMMENTS", "EMPTY_BODY", "ENUM_CONVERSION", "INFINITE_RECURSION", "INT_CONVERSION", "NON_LITERAL_NULL_CONVERSION",
                  "OBJC_IMPLICIT_RETAIN_SELF", "OBJC_LITERAL_CONVERSION", "QUOTED_INCLUDE_IN_FRAMEWORK_HEADER", "RANGE_LOOP_ANALYSIS",
                  "STRICT_PROTOTYPES", "SUSPICIOUS_MOVE", "UNREACHABLE_CODE", "_DUPLICATE_METHOD_MATCH"] {
            s.append(("CLANG_WARN_\(w)", "YES"))
        }
        s += [("CLANG_WARN_DIRECT_OBJC_ISA_USAGE", "YES_ERROR"), ("CLANG_WARN_OBJC_ROOT_CLASS", "YES_ERROR"),
              ("CLANG_WARN_UNGUARDED_AVAILABILITY", "YES_AGGRESSIVE"), ("COPY_PHASE_STRIP", "NO"), ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
              ("ENABLE_USER_SCRIPT_SANDBOXING", "YES"), ("GCC_C_LANGUAGE_STANDARD", "gnu17"), ("GCC_NO_COMMON_BLOCKS", "YES"),
              ("GCC_WARN_64_TO_32_BIT_CONVERSION", "YES"), ("GCC_WARN_ABOUT_RETURN_TYPE", "YES_ERROR"), ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
              ("GCC_WARN_UNINITIALIZED_AUTOS", "YES_AGGRESSIVE"), ("GCC_WARN_UNUSED_FUNCTION", "YES"), ("GCC_WARN_UNUSED_VARIABLE", "YES"),
              ("LOCALIZATION_PREFERS_STRING_CATALOGS", "YES"), ("MTL_FAST_MATH", "YES")]
        return s
    }

    /// Settings that are the project's platform row, dropped from a target
    /// that repeats them.
    static let platformKeys: Set<String> = ["SDKROOT", "IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET", "WATCHOS_DEPLOYMENT_TARGET",
                                            "TVOS_DEPLOYMENT_TARGET", "XROS_DEPLOYMENT_TARGET", "DRIVERKIT_DEPLOYMENT_TARGET"]

    func makeProject() throws -> PBXProj {
        var p = try PBXProj(parsing: "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {}; rootObject = 000000000000000000000000; }\n")
        func obj(_ attrs: [(String, PlistValue)]) -> String {
            let id = p.makeObjectID()
            p[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
            return id
        }
        func strings(_ ids: [String]) -> PlistValue { .array(ids.map(PlistValue.string)) }
        func sorted(_ s: [(String, PlistValue)]) -> PlistDictionary {
            var d = PlistDictionary()
            for (k, v) in s { d[k] = v }
            return PlistDictionary(d.keys.sorted().map { ($0, d[$0]!) })
        }
        func config(_ n: String, _ settings: [(String, PlistValue)]) -> String {
            obj([("isa", "XCBuildConfiguration"), ("buildSettings", .dictionary(sorted(settings))), ("name", .string(n))])
        }
        func list(_ ids: [String]) -> String {
            obj([("isa", "XCConfigurationList"), ("buildConfigurations", strings(ids)), ("defaultConfigurationIsVisible", "0"),
                 ("defaultConfigurationName", "Release")])
        }
        let projectID = p.makeObjectID()
        p[projectID] = PBXObject(id: projectID, attributes: PlistDictionary([("isa", "PBXProject")]))

        var productIDs: [String: String] = [:]
        var folderIDs: [String: String] = [:]
        var folderOrder: [String] = []
        for t in targets where t.kind == .native {
            productIDs[t.name] = obj([("isa", "PBXFileReference"), ("explicitFileType", .string(t.productFileType)), ("includeInIndex", "0"),
                                      ("path", .string(t.productPath)), ("sourceTree", "BUILT_PRODUCTS_DIR")])
        }
        var targetIDs: [String: String] = [:]
        for t in targets {
            let id = p.makeObjectID()
            targetIDs[t.name] = id
            p[id] = PBXObject(id: id, attributes: PlistDictionary([("isa", "PBXNativeTarget")]))
        }
        for t in targets {
            for (i, f) in t.folders.enumerated() where folderIDs[f] == nil {
                var attrs: [(String, PlistValue)] = [("isa", "PBXFileSystemSynchronizedRootGroup")]
                if i == 0, !t.exceptions.isEmpty {
                    let ex = obj([("isa", "PBXFileSystemSynchronizedBuildFileExceptionSet"),
                                  ("membershipExceptions", .array(t.exceptions.map(PlistValue.string))),
                                  ("target", .string(targetIDs[t.name]!))])
                    attrs.append(("exceptions", strings([ex])))
                }
                attrs += [("path", .string(f)), ("sourceTree", "<group>")]
                folderIDs[f] = obj(attrs)
                folderOrder.append(f)
            }
        }
        // SDK frameworks: one reference each, in a Frameworks group.
        var sdkRefs: [String: String] = [:]
        for t in targets { for f in t.sdkFrameworks where sdkRefs[f] == nil {
            sdkRefs[f] = obj([("isa", "PBXFileReference"), ("lastKnownFileType", "wrapper.framework"), ("name", .string("\(f).framework")),
                              ("path", .string("System/Library/Frameworks/\(f).framework")), ("sourceTree", "SDKROOT")])
        } }
        var targetAttributes = PlistDictionary()
        for t in targets {
            let id = targetIDs[t.name]!
            var phases: [String] = []
            for isa in t.phases {
                var files: [String] = []
                if isa == "PBXFrameworksBuildPhase" {
                    files = (t.links.compactMap { productIDs[$0] } + t.sdkFrameworks.compactMap { sdkRefs[$0] })
                        .map { obj([("isa", "PBXBuildFile"), ("fileRef", .string($0))]) }
                }
                phases.append(obj([("isa", .string(isa)), ("buildActionMask", "2147483647"), ("files", strings(files)),
                                   ("runOnlyForDeploymentPostprocessing", "0")]))
            }
            for c in t.copyPhases {
                phases.append(obj([("isa", "PBXCopyFilesBuildPhase"), ("buildActionMask", "2147483647"), ("dstPath", .string(c.path)),
                                   ("dstSubfolderSpec", .string(c.subfolderSpec)), ("files", .array([])),
                                   ("runOnlyForDeploymentPostprocessing", c.deploymentOnly ? "1" : "0")]))
            }
            for e in t.embeds {
                let attrs: PlistValue = e.codeSignOnCopy ? ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]] : ["ATTRIBUTES": ["RemoveHeadersOnCopy"]]
                let files = e.targets.compactMap { productIDs[$0] }.map { ref in
                    obj([("isa", "PBXBuildFile"), ("fileRef", .string(ref)), ("settings", attrs)])
                }
                phases.append(obj([("isa", "PBXCopyFilesBuildPhase"), ("buildActionMask", "2147483647"), ("dstPath", .string(e.path)),
                                   ("dstSubfolderSpec", .string(e.subfolderSpec)), ("files", strings(files)), ("name", .string(e.name)),
                                   ("runOnlyForDeploymentPostprocessing", "0")]))
            }
            var deps: [String] = []
            for d in t.dependencies {
                guard let dep = targetIDs[d] else { continue }
                let proxy = obj([("isa", "PBXContainerItemProxy"), ("containerPortal", .string(projectID)), ("proxyType", "1"),
                                 ("remoteGlobalIDString", .string(dep)), ("remoteInfo", .string(d))])
                deps.append(obj([("isa", "PBXTargetDependency"), ("target", .string(dep)), ("targetProxy", .string(proxy))]))
            }
            // Target settings: the platform row (multi-SDK) or without it.
            var s = t.settings
            var release = t.releaseSettings
            if let sdk = t.sdk {
                s.removeAll { Self.platformKeys.contains($0.0) }
                s = sdk.platformRow + s
                if sdk.validatesProduct { release.append(("VALIDATE_PRODUCT", "YES")) }
            } else if let ps = projectSDK {
                let row = Dictionary(ps.platformRow, uniquingKeysWith: { a, _ in a })
                // Hosted unit tests keep a copy of the deployment target.
                let keepDeployment = t.productType.hasSuffix("unit-test") && t.settings.contains { $0.0 == "TEST_HOST" }
                s.removeAll { k, v in row[k] == v && !(keepDeployment && k != "SDKROOT") }
            }
            if t.kind == .native { s.append(("CODE_SIGN_STYLE", "Automatic")) }
            if let team { s.append(("DEVELOPMENT_TEAM", .string(team))) }
            if let v = t.swiftVersion, t.kind == .native {
                s += [("SWIFT_VERSION", .string(v)), ("SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY", "YES"),
                      ("SWIFT_APPROACHABLE_CONCURRENCY", "YES")]
                if t.productType == "com.apple.product-type.application" || t.productType.hasPrefix("com.apple.product-type.app-extension") {
                    s.append(("SWIFT_DEFAULT_ACTOR_ISOLATION", "MainActor"))
                }
            }
            let configs = list([config("Debug", deployment(s + t.debugSettings)), config("Release", deployment(s + release))])
            var attrs: [(String, PlistValue)]
            switch t.kind {
            case .native:
                attrs = [("isa", "PBXNativeTarget"), ("buildConfigurationList", .string(configs)),
                         ("buildPhases", strings(phases)), ("buildRules", .array([])), ("dependencies", strings(deps))]
                if !t.folders.isEmpty { attrs.append(("fileSystemSynchronizedGroups", strings(t.folders.compactMap { folderIDs[$0] }))) }
                attrs += [("name", .string(t.name)), ("packageProductDependencies", .array([])), ("productName", .string(t.name)),
                          ("productReference", .string(productIDs[t.name]!)), ("productType", .string(t.productType))]
            case .legacy(let tool, let arguments):
                attrs = [("isa", "PBXLegacyTarget"), ("buildArgumentsString", .string(arguments)), ("buildConfigurationList", .string(configs)),
                         ("buildPhases", strings(phases)), ("buildToolPath", .string(tool)), ("buildWorkingDirectory", ""),
                         ("dependencies", strings(deps)), ("name", .string(t.name)), ("passBuildSettingsInEnvironment", "1"),
                         ("productName", .string(t.name))]
            }
            p[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
            var ta: [(String, PlistValue)] = [("CreatedOnToolsVersion", .string(Self.toolsVersion))]
            if let tested = t.testedTarget, let tid = targetIDs[tested] { ta.append(("TestTargetID", .string(tid))) }
            targetAttributes[id] = .dictionary(PlistDictionary(ta))
        }
        let products = obj([("isa", "PBXGroup"), ("children", strings(targets.compactMap { productIDs[$0.name] })), ("name", "Products"),
                            ("sourceTree", "<group>")])
        var mainChildren = folderOrder.compactMap { folderIDs[$0] }
        if !sdkRefs.isEmpty {
            mainChildren.append(obj([("isa", "PBXGroup"), ("children", strings(sdkRefs.keys.sorted().compactMap { sdkRefs[$0] })), ("name", "Frameworks"),
                                     ("sourceTree", "<group>")]))
        }
        let main = obj([("isa", "PBXGroup"), ("children", strings(mainChildren + [products])), ("sourceTree", "<group>")])
        var debug = Self.common() + projectSettings + [
            ("DEBUG_INFORMATION_FORMAT", "dwarf"), ("ENABLE_TESTABILITY", "YES"), ("GCC_DYNAMIC_NO_PIC", "NO"), ("GCC_OPTIMIZATION_LEVEL", "0"),
            ("GCC_PREPROCESSOR_DEFINITIONS", ["DEBUG=1", "$(inherited)"]), ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"), ("ONLY_ACTIVE_ARCH", "YES"),
        ]
        var release = Self.common() + projectSettings + [
            ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"), ("ENABLE_NS_ASSERTIONS", "NO"), ("MTL_ENABLE_DEBUG_INFO", "NO"),
        ]
        if swift {
            debug += [("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG $(inherited)"), ("SWIFT_OPTIMIZATION_LEVEL", "-Onone")]
            release.append(("SWIFT_COMPILATION_MODE", "wholemodule"))
        }
        if let ps = projectSDK {
            debug += ps.platformRow
            release += ps.platformRow
            if ps.validatesProduct { release.append(("VALIDATE_PRODUCT", "YES")) }
        }
        let projectList = list([config("Debug", deployment(debug)), config("Release", deployment(release))])
        var attributes: [(String, PlistValue)] = [("BuildIndependentTargetsInParallel", "1"),
                                                  ("LastSwiftUpdateCheck", .string(Self.toolsVersionDigits)),
                                                  ("LastUpgradeCheck", .string(Self.toolsVersionDigits))]
        if let o = organizationName, !o.isEmpty { attributes.append(("ORGANIZATIONNAME", .string(o))) }
        attributes.append(("TargetAttributes", .dictionary(targetAttributes)))
        p[projectID] = PBXObject(id: projectID, attributes: PlistDictionary([
            ("isa", "PBXProject"), ("attributes", .dictionary(PlistDictionary(attributes))),
            ("buildConfigurationList", .string(projectList)), ("developmentRegion", "en"), ("hasScannedForEncodings", "0"),
            ("knownRegions", .array(["en", "Base"])), ("mainGroup", .string(main)), ("minimizedProjectReferenceProxies", "1"),
            ("preferredProjectObjectVersion", "77"), ("productRefGroup", .string(products)), ("projectDirPath", ""), ("projectRoot", ""),
            ("targets", strings(targets.compactMap { targetIDs[$0.name] })),
        ]))
        p.rootObject = projectID
        return p
    }
}
