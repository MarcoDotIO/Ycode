import Foundation
import YcodeSettings

/// Splits a build-setting value into words: whitespace separates, double
/// and single quotes group, a backslash escapes the next character.
public enum SettingWords {
    public static func split(_ value: String) -> [String] {
        var out: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for c in value {
            if escape { word.append(c); escape = false; inWord = true; continue }
            if c == "\\" { escape = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; inWord = true; continue }
            if c == " " || c == "\t" || c == "\n" {
                if inWord { out.append(word); word = ""; inWord = false }
                continue
            }
            word.append(c)
            inWord = true
        }
        if inWord { out.append(word) }
        return out
    }
}

/// Everything argument generation needs about one target: its sources,
/// its resolved settings and where its headers are.
public struct TargetCompileContext: Sendable {
    public var target: BuildGraph.Target
    /// Resolved build settings (Ycode's resolver or swift-build).
    public var settings: [String: String]
    /// The project's directory (`SRCROOT`): relative paths start there and
    /// compilers run there.
    public var projectDirectory: String
    /// Folders holding the project's headers: quoted includes find any
    /// header of the project by name, as with the build system's header
    /// maps.
    public var projectHeaderDirectories: [String]
    public var isLinuxHost: Bool
    public var hostArchitecture: String

    public init(target: BuildGraph.Target, settings: [String: String], projectDirectory: String,
                projectHeaderDirectories: [String] = [], isLinuxHost: Bool = BuildContext.currentIsLinux,
                hostArchitecture: String = BuildContext.currentArchitecture) {
        self.target = target
        self.settings = settings
        self.projectDirectory = projectDirectory
        self.projectHeaderDirectories = projectHeaderDirectories
        self.isLinuxHost = isLinuxHost
        self.hostArchitecture = hostArchitecture
    }

    func value(_ name: String) -> String { settings[name] ?? "" }
    func isYes(_ name: String, default d: Bool = false) -> Bool {
        let v = value(name).uppercased()
        if v.isEmpty { return d }
        return v == "YES" || v == "TRUE" || v == "1"
    }

    // MARK: Layout of index products (shared with the preparer)

    /// `PRODUCT_MODULE_NAME` (the target name as a C identifier when unset).
    public var moduleName: String {
        let m = value("SWIFT_MODULE_NAME").isEmpty ? value("PRODUCT_MODULE_NAME") : value("SWIFT_MODULE_NAME")
        return m.isEmpty ? MacroOperators.apply("c99extidentifier", argument: nil, to: target.name) : m
    }

    /// `BUILT_PRODUCTS_DIR`: modules of the target land here.
    public var productsDirectory: String { absolute(value("BUILT_PRODUCTS_DIR")) }
    /// The emitted Swift module (`<products>/<Module>.swiftmodule`).
    public var swiftModulePath: String { productsDirectory + "/" + moduleName + ".swiftmodule" }
    /// `<products>/include/<Module>`: the target's public and private
    /// headers (as links), its module map and its generated Objective-C
    /// header, so that `<Module/Header.h>` resolves through `-I <products>/include`.
    public var includeDirectory: String { productsDirectory + "/include/" + moduleName }
    public var moduleMapPath: String { includeDirectory + "/module.modulemap" }
    /// The header the Swift compiler generates for Objective-C callers.
    public var objcHeaderPath: String {
        let n = value("SWIFT_OBJC_INTERFACE_HEADER_NAME")
        return includeDirectory + "/" + (n.isEmpty ? moduleName + "-Swift.h" : n)
    }

    /// A framework or library with public or private headers (or
    /// `DEFINES_MODULE` and headers): it has a Clang module of its own,
    /// which its Swift code imports (`-import-underlying-module`).
    public var exportsClangModule: Bool {
        let exported = target.headers.contains { $0.visibility != .project }
        return (target.isLibrary && exported) || (isYes("DEFINES_MODULE") && !target.headers.isEmpty && !target.isApplication)
    }

    public var architecture: String {
        let a = value("CURRENT_ARCH")
        return a.isEmpty || a == "undefined_arch" ? hostArchitecture : a
    }

    /// The object file a source file compiles to (also its index unit's name).
    public func objectFile(for path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = value("OBJECT_FILE_DIR_normal").isEmpty ? productsDirectory + "/Objects-normal" : absolute(value("OBJECT_FILE_DIR_normal"))
        return dir + "/" + architecture + "/" + base + ".o"
    }

    /// The SDK path, or nil (Linux, or an SDK that is not installed).
    public var sdkPath: String? {
        let s = value("SDKROOT")
        return !isLinuxHost && s.hasPrefix("/") ? s : nil
    }

    /// The target triple: the host's on Linux, else
    /// `<arch>-apple-<os><deployment target>[-simulator]`.
    public var triple: String {
        if isLinuxHost {
            let a = architecture == "arm64" ? "aarch64" : architecture
            return "\(a)-unknown-linux-gnu"
        }
        // swift-build exports the pieces (its own settings).
        let osVersion = value("LLVM_TARGET_TRIPLE_OS_VERSION")
        if !osVersion.isEmpty {
            let vendor = value("LLVM_TARGET_TRIPLE_VENDOR").isEmpty ? "apple" : value("LLVM_TARGET_TRIPLE_VENDOR")
            return "\(architecture)-\(vendor)-\(osVersion)\(value("LLVM_TARGET_TRIPLE_SUFFIX"))"
        }
        let platform = value("PLATFORM_NAME").isEmpty ? PlatformChoice.baseName(value("SDKROOT")) : value("PLATFORM_NAME")
        let (os, key, suffix): (String, String, String) = switch platform {
        case "iphoneos": ("ios", "IPHONEOS_DEPLOYMENT_TARGET", "")
        case "iphonesimulator": ("ios", "IPHONEOS_DEPLOYMENT_TARGET", "-simulator")
        case "appletvos": ("tvos", "TVOS_DEPLOYMENT_TARGET", "")
        case "appletvsimulator": ("tvos", "TVOS_DEPLOYMENT_TARGET", "-simulator")
        case "watchos": ("watchos", "WATCHOS_DEPLOYMENT_TARGET", "")
        case "watchsimulator": ("watchos", "WATCHOS_DEPLOYMENT_TARGET", "-simulator")
        case "xros": ("xros", "XROS_DEPLOYMENT_TARGET", "")
        case "xrsimulator": ("xros", "XROS_DEPLOYMENT_TARGET", "-simulator")
        case "driverkit": ("driverkit", "DRIVERKIT_DEPLOYMENT_TARGET", "")
        default: ("macos", "MACOSX_DEPLOYMENT_TARGET", "")
        }
        let version = value(key).isEmpty ? value("SDK_VERSION") : value(key)
        return "\(architecture)-apple-\(os)\(version)\(suffix)"
    }

    var isDarwinTarget: Bool { !isLinuxHost }

    // MARK: Paths

    func absolute(_ p: String) -> String {
        guard !p.isEmpty else { return p }
        let full = p.hasPrefix("/") ? p : projectDirectory + "/" + p
        return URL(fileURLWithPath: full).standardizedFileURL.path
    }

    /// The paths of a search-path setting, absolute; `dir/**` adds every
    /// folder below `dir` (at most 512).
    public func searchPaths(_ name: String) -> [String] {
        var out: [String] = []
        for word in SettingWords.split(value(name)) {
            if word.hasSuffix("/**") {
                let root = absolute(String(word.dropLast(3)))
                out.append(root)
                var found = 0
                TargetLoader.walk(root, relative: "") { rel, isDir in
                    if isDir && found < 512 { out.append(root + "/" + rel); found += 1 }
                }
            } else {
                out.append(absolute(word))
            }
        }
        return out.uniqued()
    }

    /// `-D` values of `GCC_PREPROCESSOR_DEFINITIONS`.
    var preprocessorDefinitions: [String] { SettingWords.split(value("GCC_PREPROCESSOR_DEFINITIONS")) }

    /// Folders for quoted includes: the target's generated include folder,
    /// the project's header folders, then `USER_HEADER_SEARCH_PATHS`.
    var quoteSearchPaths: [String] {
        ([includeDirectory] + projectHeaderDirectories + searchPaths("USER_HEADER_SEARCH_PATHS")).uniqued()
    }

    /// `HEADER_SEARCH_PATHS`, after `<products>/include` (which the build
    /// system always searches for native targets).
    var headerSearchPaths: [String] { ([productsDirectory + "/include"] + searchPaths("HEADER_SEARCH_PATHS")).uniqued() }

    /// Framework folders: the products folder, `FRAMEWORK_SEARCH_PATHS` and,
    /// for test bundles, the platform's test frameworks.
    var frameworkSearchPaths: [String] {
        var out = [productsDirectory] + searchPaths("FRAMEWORK_SEARCH_PATHS")
        if target.isTest, !value("PLATFORM_DIR").isEmpty { out.append(value("PLATFORM_DIR") + "/Developer/Library/Frameworks") }
        return out.uniqued()
    }
}

/// Compiler arguments for a file of a target, as sourcekit-lsp takes them
/// (`textDocument/sourceKitOptions`: no compiler executable). See
/// `specs/ide/language.md` §Build server, "Compiler arguments", for the
/// setting-to-flag table.
public enum CompilerArguments {
    /// The arguments for `file` (a source or header of the target) in
    /// `language`.
    public static func arguments(for file: String, language: SourceLanguage, in ctx: TargetCompileContext) -> [String] {
        let isHeader = SourceLanguage.isHeader(file)
        if language == .swift && !isHeader { return swift(for: file, in: ctx) }
        let lang: SourceLanguage = language == .swift ? (ctx.target.sources.contains { $0.language == .objectiveCpp } ? .objectiveCpp : .objectiveC) : language
        return clang(for: file, language: lang, in: ctx, isHeader: isHeader)
    }

    /// The Swift compiler's arguments: the whole module (every Swift file
    /// of the target), then this file's index unit output path.
    public static func swift(for file: String?, in ctx: TargetCompileContext) -> [String] {
        var a = swiftModuleArguments(ctx)
        if let file {
            a += ["-index-unit-output-path", ctx.objectFile(for: file)]
            if let flags = ctx.target.sources.first(where: { $0.path == file })?.flags { a += SettingWords.split(flags) }
        }
        return a
    }

    /// The arguments shared by every Swift file of the target (also used to
    /// emit its module).
    public static func swiftModuleArguments(_ ctx: TargetCompileContext) -> [String] {
        var a = ["-module-name", ctx.moduleName]
        a += ctx.target.sources.filter { $0.language == .swift }.map(\.path)
        if let sdk = ctx.sdkPath { a += ["-sdk", sdk] }
        a += ["-target", ctx.triple]
        let version = swiftLanguageVersion(ctx.value("SWIFT_VERSION"))
        if let version { a += ["-swift-version", version] }
        let optimization = ctx.value("SWIFT_OPTIMIZATION_LEVEL")
        if !optimization.isEmpty { a += optimization == "-Owholemodule" ? ["-O"] : [optimization] }
        let testability = ctx.value("SWIFT_ENABLE_TESTABILITY").isEmpty ? "ENABLE_TESTABILITY" : "SWIFT_ENABLE_TESTABILITY"
        if ctx.isYes(testability) { a.append("-enable-testing") }
        if ctx.isYes("SWIFT_ENABLE_APP_EXTENSION", default: ctx.isYes("APPLICATION_EXTENSION_API_ONLY")) { a.append("-application-extension") }
        // A module of one file not named main.swift is a library (the
        // compiler would otherwise read a lone file as top-level code).
        let swiftFiles = ctx.target.sources.filter { $0.language == .swift }
        let lone = swiftFiles.count == 1 && (swiftFiles[0].path as NSString).lastPathComponent != "main.swift"
            && !ctx.isYes("SWIFT_DISABLE_PARSE_AS_LIBRARY")
        if ctx.isYes("SWIFT_LIBRARIES_ONLY") || lone { a.append("-parse-as-library") }
        for c in SettingWords.split(ctx.value("SWIFT_ACTIVE_COMPILATION_CONDITIONS")) { a += ["-D", c] }
        a += languageFeatureFlags(ctx, version: version)
        if ctx.value("SWIFT_OBJC_INTEROP_MODE") == "objcxx" { a.append("-cxx-interoperability-mode=default") }

        // Module and framework search paths.
        for p in ([ctx.productsDirectory] + ctx.searchPaths("SWIFT_INCLUDE_PATHS")).uniqued() { a += ["-I", p] }
        if ctx.target.isTest, !ctx.value("PLATFORM_DIR").isEmpty, ctx.isDarwinTarget {
            a += ["-I", ctx.value("PLATFORM_DIR") + "/Developer/usr/lib"]
        }
        if ctx.isDarwinTarget {
            for p in ctx.frameworkSearchPaths { a += ["-F", p] }
            for p in ctx.searchPaths("SYSTEM_FRAMEWORK_SEARCH_PATHS") { a += ["-Fsystem", p] }
        }

        // The Clang importer: header paths and macros.
        for p in ctx.headerSearchPaths { a += ["-Xcc", "-I", "-Xcc", p] }
        for p in ctx.quoteSearchPaths { a += ["-Xcc", "-iquote", "-Xcc", p] }
        for p in ctx.searchPaths("SYSTEM_HEADER_SEARCH_PATHS") { a += ["-Xcc", "-isystem", "-Xcc", p] }
        for d in ctx.preprocessorDefinitions { a += ["-Xcc", "-D" + d] }

        let bridging = ctx.value("SWIFT_OBJC_BRIDGING_HEADER")
        if !bridging.isEmpty { a += ["-import-objc-header", ctx.absolute(bridging)] }
        if ctx.exportsClangModule && ctx.target.hasSwift { a.append("-import-underlying-module") }

        a += SettingWords.split(ctx.value("OTHER_SWIFT_FLAGS"))
        return a
    }

    /// `SWIFT_VERSION` as `-swift-version` takes it: `5.0` → `5`,
    /// `4.2` → `4.2`, `6.0` → `6`.
    public static func swiftLanguageVersion(_ setting: String) -> String? {
        let s = setting.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".0") { return String(s.dropLast(2)) }
        return s
    }

    /// Concurrency and upcoming-feature settings.
    static func languageFeatureFlags(_ ctx: TargetCompileContext, version: String?) -> [String] {
        var a: [String] = []
        let major = Int(version?.split(separator: ".").first ?? "") ?? 5
        switch ctx.value("SWIFT_STRICT_CONCURRENCY") {
        case "", "minimal": break
        case "targeted": a.append("-strict-concurrency=targeted")
        default: a += ["-enable-upcoming-feature", "StrictConcurrency"]
        }
        if ctx.value("SWIFT_DEFAULT_ACTOR_ISOLATION") == "MainActor" { a.append("-default-isolation=MainActor") }
        if ctx.value("SWIFT_STRICT_MEMORY_SAFETY") == "YES" { a.append("-strict-memory-safety") }
        if ctx.value("SWIFT_ENABLE_BARE_SLASH_REGEX") != "NO" && major < 6 { a.append("-enable-bare-slash-regex") }
        var features: [String] = []
        // Upcoming features named by their settings.
        for (setting, feature) in upcomingFeatures where ctx.value(setting) == "YES" { features.append(feature) }
        // Approachable Concurrency: five upcoming features (in Swift 6
        // mode three of them are already on).
        if ctx.isYes("SWIFT_APPROACHABLE_CONCURRENCY") {
            if major < 6 { features += ["DisableOutwardActorInference", "GlobalActorIsolatedTypesUsability", "InferSendableFromCaptures"] }
            features += ["InferIsolatedConformances", "NonisolatedNonsendingByDefault"]
        }
        for f in features.uniqued() { a += ["-enable-upcoming-feature", f] }
        return a
    }

    /// `SWIFT_UPCOMING_FEATURE_*` settings and the features they turn on
    /// (swift-build's Swift compiler specification).
    static let upcomingFeatures: [(String, String)] = [
        ("SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE", "ConciseMagicFile"),
        ("SWIFT_UPCOMING_FEATURE_FORWARD_TRAILING_CLOSURES", "ForwardTrailingClosures"),
        ("SWIFT_UPCOMING_FEATURE_DEPRECATE_APPLICATION_MAIN", "DeprecateApplicationMain"),
        ("SWIFT_UPCOMING_FEATURE_IMPORT_OBJC_FORWARD_DECLS", "ImportObjcForwardDeclarations"),
        ("SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_ISOLATION", "DisableOutwardActorInference"),
        ("SWIFT_UPCOMING_FEATURE_ISOLATED_DEFAULT_VALUES", "IsolatedDefaultValues"),
        ("SWIFT_UPCOMING_FEATURE_GLOBAL_CONCURRENCY", "GlobalConcurrency"),
        ("SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES", "InferSendableFromCaptures"),
        ("SWIFT_UPCOMING_FEATURE_IMPLICIT_OPEN_EXISTENTIALS", "ImplicitOpenExistentials"),
        ("SWIFT_UPCOMING_FEATURE_REGION_BASED_ISOLATION", "RegionBasedIsolation"),
        ("SWIFT_UPCOMING_FEATURE_DYNAMIC_ACTOR_ISOLATION", "DynamicActorIsolation"),
        ("SWIFT_UPCOMING_FEATURE_NONFROZEN_ENUM_EXHAUSTIVITY", "NonfrozenEnumExhaustivity"),
        ("SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY", "GlobalActorIsolatedTypesUsability"),
        ("SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT", "InternalImportsByDefault"),
        ("SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY", "MemberImportVisibility"),
        ("SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY", "ExistentialAny"),
        ("SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES", "InferIsolatedConformances"),
        ("SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT", "NonisolatedNonsendingByDefault"),
    ]

    /// Clang's arguments for a C-family source (compiled to its object
    /// file) or a header (no output).
    public static func clang(for file: String, language: SourceLanguage, in ctx: TargetCompileContext, isHeader: Bool = false) -> [String] {
        var a = ["-x", language.clangInputType]
        a += ["-target", ctx.triple]
        if let sdk = ctx.sdkPath { a += ["-isysroot", sdk] }
        let objc = language == .objectiveC || language == .objectiveCpp
        let cxx = language == .cpp || language == .objectiveCpp
        if ctx.isYes("CLANG_ENABLE_MODULES") {
            a.append("-fmodules")
            if ctx.exportsClangModule { a.append("-fmodule-name=" + ctx.moduleName) }
        }
        if objc && ctx.isYes("CLANG_ENABLE_OBJC_ARC") { a.append("-fobjc-arc") }
        if objc && ctx.isYes("CLANG_ENABLE_OBJC_WEAK") { a.append("-fobjc-weak") }
        if objc && ctx.value("GCC_ENABLE_OBJC_EXCEPTIONS") == "NO" { a.append("-fno-objc-exceptions") }
        if cxx {
            a += languageStandard(ctx.value("CLANG_CXX_LANGUAGE_STANDARD"))
            let lib = ctx.value("CLANG_CXX_LIBRARY")
            if !lib.isEmpty && lib != "compiler-default" && lib != "libstdc++" { a.append("-stdlib=" + lib) }
        } else {
            let std = ctx.value("GCC_C_LANGUAGE_STANDARD")
            if std == "ansi" { a.append("-ansi") } else { a += languageStandard(std) }
        }
        let optimization = ctx.value("GCC_OPTIMIZATION_LEVEL")
        if !optimization.isEmpty { a.append("-O" + optimization) }
        if ctx.value("ENABLE_NS_ASSERTIONS") == "NO" { a.append("-DNS_BLOCK_ASSERTIONS=1") }
        for d in ctx.preprocessorDefinitions { a.append("-D" + d) }

        for p in ctx.quoteSearchPaths { a += ["-iquote", p] }
        for p in ctx.headerSearchPaths { a += ["-I", p] }
        for p in ctx.searchPaths("SYSTEM_HEADER_SEARCH_PATHS") { a += ["-isystem", p] }
        if ctx.isDarwinTarget {
            for p in ctx.frameworkSearchPaths { a += ["-F", p] }
            for p in ctx.searchPaths("SYSTEM_FRAMEWORK_SEARCH_PATHS") { a += ["-iframework", p] }
        }
        let prefix = ctx.value("GCC_PREFIX_HEADER")
        if !prefix.isEmpty { a += ["-include", ctx.absolute(prefix)] }

        a += SettingWords.split(ctx.value("WARNING_CFLAGS"))
        let other = cxx && !ctx.value("OTHER_CPLUSPLUSFLAGS").isEmpty ? ctx.value("OTHER_CPLUSPLUSFLAGS") : ctx.value("OTHER_CFLAGS")
        a += SettingWords.split(other)
        if let flags = ctx.target.sources.first(where: { $0.path == file })?.flags { a += SettingWords.split(flags) }
        if isHeader { a.append(file) } else { a += ["-c", file, "-o", ctx.objectFile(for: file)] }
        return a
    }

    /// `-std=<value>` unless the compiler's default is asked for.
    static func languageStandard(_ v: String) -> [String] {
        switch v {
        case "", "compiler-default": []
        case "c++0x": ["-std=c++11"]
        case "gnu++0x": ["-std=gnu++11"]
        default: ["-std=" + v]
        }
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
