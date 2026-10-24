import Foundation
import YcodePlist
import YcodeProject
import YcodeSettings

/// Project-editor content that follows `specs/ide/reference-ui-3.md` §1:
/// section orders, captions, tables and menus, computed from the project.
extension ProjectEditorModel {
    // MARK: General

    /// The General tab's collapsible sections, in display order.
    public static let generalSectionTitles = [
        "Supported Destinations", "Minimum Deployments", "Identity", "Deployment Info",
        "App Icons and Launch Screen", "Frameworks, Libraries, and Embedded Content",
        "Development Assets", "Supported Intents",
    ]

    /// iPhone/iPad devices the target supports: the Deployment Info
    /// orientation rows. Status bar and scene rows appear only with one.
    public func deploymentInfoDevices(target: String, configuration: String) -> [String] {
        supportedDestinations(target: target, configuration: configuration).map(\.name).filter { $0 == "iPhone" || $0 == "iPad" }
    }

    /// Whether the target has an iOS destination (launch screen, intents).
    public func hasIOSDestination(target: String, configuration: String) -> Bool {
        supportedDestinations(target: target, configuration: configuration).contains { $0.sdk == "iOS" }
    }

    /// General sections for this target's platforms, in display order.
    /// Deployment Info holds only iPhone/iPad rows, so a target without
    /// them (for example macOS only) does not show it.
    public func generalSections(target: String, configuration: String) -> [String] {
        let devices = deploymentInfoDevices(target: target, configuration: configuration)
        return Self.generalSectionTitles.filter { $0 != "Deployment Info" || !devices.isEmpty }
    }

    public static let generalEmptyTexts = [
        "Frameworks, Libraries, and Embedded Content": "Add frameworks, libraries, and embedded content here",
        "Development Assets": "Add development assets here",
        "Supported Intents": "Add intents eligible for in-app handling here",
    ]

    public struct Destination: Equatable, Sendable {
        public var name: String
        public var sdk: String
    }

    /// Supported Destinations rows, Ycode's reading of the platform settings.
    public func supportedDestinations(target: String, configuration: String) -> [Destination] {
        guard let s = resolve(target: target, configuration: configuration)?.settings else { return [] }
        return Self.destinations(
            platforms: s["SUPPORTED_PLATFORMS"].split(separator: " ").map(String.init),
            sdkroot: s["SDKROOT"], families: s["TARGETED_DEVICE_FAMILY"],
            catalyst: s["SUPPORTS_MACCATALYST"] == "YES",
            macDesigned: s["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] == "YES",
            visionDesigned: s["SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD"] == "YES")
    }

    public static func destinations(platforms: [String], sdkroot: String, families: String, catalyst: Bool,
                                    macDesigned: Bool, visionDesigned: Bool) -> [Destination] {
        let p = Set(platforms.isEmpty ? [sdkroot] : platforms)
        var out: [Destination] = []
        if p.contains("iphoneos") || p.contains("iphonesimulator") {
            let fam = Set(families.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            if fam.isEmpty || fam.contains("1") { out.append(.init(name: "iPhone", sdk: "iOS")) }
            if fam.contains("2") { out.append(.init(name: "iPad", sdk: "iOS")) }
            if catalyst { out.append(.init(name: "Mac (Mac Catalyst)", sdk: "iOS")) }
            else if macDesigned { out.append(.init(name: "Mac (Designed for iPad)", sdk: "iOS")) }
            if visionDesigned && !p.contains("xros") { out.append(.init(name: "Apple Vision (Designed for iPad)", sdk: "iOS")) }
        }
        if p.contains("macosx") { out.append(.init(name: "Mac", sdk: "macOS")) }
        if p.contains("xros") || p.contains("xrsimulator") { out.append(.init(name: "Apple Vision", sdk: "visionOS")) }
        if p.contains("appletvos") || p.contains("appletvsimulator") { out.append(.init(name: "Apple TV", sdk: "tvOS")) }
        if p.contains("watchos") || p.contains("watchsimulator") { out.append(.init(name: "Apple Watch", sdk: "watchOS")) }
        return out
    }

    /// Minimum Deployments rows: (SDK, deployment-target setting, value).
    public func minimumDeployments(target: String, configuration: String) -> [(sdk: String, setting: String, value: String)] {
        guard let s = resolve(target: target, configuration: configuration)?.settings else { return [] }
        let map = ["iOS": "IPHONEOS_DEPLOYMENT_TARGET", "macOS": "MACOSX_DEPLOYMENT_TARGET", "visionOS": "XROS_DEPLOYMENT_TARGET",
                   "tvOS": "TVOS_DEPLOYMENT_TARGET", "watchOS": "WATCHOS_DEPLOYMENT_TARGET"]
        var seen: [String] = []
        for d in supportedDestinations(target: target, configuration: configuration) where !seen.contains(d.sdk) { seen.append(d.sdk) }
        return seen.compactMap { sdk in map[sdk].map { (sdk, $0, s[$0]) } }
    }

    // MARK: Signing

    public static let signingScopes = ["All", "Debug", "Release"]
    public static let automaticSigningCaption = "Xcode will create and update profiles, app IDs, and certificates."
    public static let emptyCapabilitiesText = "Add capabilities by clicking the \u{201C}+\u{201D} button above."
    public static let capabilityLibraryTitle = "Capabilities"

    public struct SigningBox: Equatable, Sendable {
        public var platform: String
        public var provisioningProfile: String
        public var certificate: String
        /// Status lines; a warning pair when no team is set.
        public var status: [String]
    }

    /// One box per platform the target supports.
    public func signingBoxes(target: String, configuration: String) -> [SigningBox] {
        guard let s = resolve(target: target, configuration: configuration)?.settings else { return [] }
        let auto = s["CODE_SIGN_STYLE"] != "Manual"
        let team = s["DEVELOPMENT_TEAM"]
        var sdks: [String] = []
        for d in supportedDestinations(target: target, configuration: configuration) where !sdks.contains(d.sdk) { sdks.append(d.sdk) }
        return sdks.map { sdk in
            let cert = s["CODE_SIGN_IDENTITY"]
            return SigningBox(platform: sdk,
                              provisioningProfile: auto ? "Xcode Managed Profile" : (s["PROVISIONING_PROFILE_SPECIFIER"].isEmpty ? "None" : s["PROVISIONING_PROFILE_SPECIFIER"]),
                              certificate: cert.isEmpty || cert == "-" ? (cert == "-" ? "Sign to Run Locally" : "Apple Development") : cert,
                              status: team.isEmpty ? Self.noTeamWarning(target: target) : [])
        }
    }

    public static func noTeamWarning(target: String) -> [String] {
        ["Signing for \u{201C}\(target)\u{201D} requires a development team.",
         "Select a development team in the Signing & Capabilities editor."]
    }

    /// The capability library's footer error, when no team is set.
    public func capabilityLibraryError(target: String, configuration: String) -> [String]? {
        resolve(target: target, configuration: configuration)?.settings["DEVELOPMENT_TEAM"].isEmpty ?? true
            ? ["Error Loading Capabilities", "No development team is set. Select a team in the Signing & Capabilities editor."] : nil
    }

    /// The library list: alphabetical, filtered by name.
    public static func capabilityLibrary(filter: String = "") -> [Capability] {
        let q = filter.lowercased()
        return Capability.allCases.filter { q.isEmpty || $0.rawValue.lowercased().contains(q) }.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: Resource Tags

    public static let resourceTagScopes = ["All", "Prefetched"]
    public static let resourceTagsEmptyText = "Click the \u{201C}+\u{201D} button above to add a resource tag."

    // MARK: Info

    public static let readableInfoKeys = [
        "CFBundleName": "Bundle name", "CFBundleIdentifier": "Bundle identifier",
        "CFBundleInfoDictionaryVersion": "InfoDictionary version",
        "CFBundleShortVersionString": "Bundle version string (short)", "CFBundleVersion": "Bundle version",
        "CFBundleExecutable": "Executable file", "LSRequiresIPhoneOS": "Application requires iPhone environment",
        "UIApplicationSceneManifest": "Application Scene Manifest",
        "UISupportedInterfaceOrientations": "Supported interface orientations",
        "CFBundlePackageType": "Bundle OS Type code", "UILaunchScreen": "Launch Screen",
        "CFBundleDevelopmentRegion": "Default localization",
        "UIApplicationSupportsIndirectInputEvents": "Application supports indirect input events",
        "CFBundleDisplayName": "Bundle display name", "NSHumanReadableCopyright": "Copyright (human-readable)",
        "LSApplicationCategoryType": "Application Category", "LSMinimumSystemVersion": "Minimum system version",
        "NSPrincipalClass": "Principal class", "NSMainStoryboardFile": "Main storyboard file base name",
        "UISupportedInterfaceOrientations~iphone": "Supported interface orientations (iPhone)",
        "UISupportedInterfaceOrientations~ipad": "Supported interface orientations (iPad)",
        "UIApplicationSupportsMultipleScenes": "Enable Multiple Windows", "UISceneConfigurations": "Scene Configuration",
        "UIMainStoryboardFile": "Main storyboard file base name", "UILaunchStoryboardName": "Launch screen interface file base name",
        "UIStatusBarHidden": "Status bar is initially hidden", "UIStatusBarStyle": "Status bar style",
        "UIRequiredDeviceCapabilities": "Required device capabilities", "UIRequiresFullScreen": "Requires full screen",
        "ITSAppUsesNonExemptEncryption": "App Uses Non-Exempt Encryption", "LSUIElement": "Application is agent (UIElement)",
        "CFBundleDocumentTypes": "Document types", "CFBundleURLTypes": "URL types",
        "UTExportedTypeDeclarations": "Exported Type Identifiers", "UTImportedTypeDeclarations": "Imported Type Identifiers",
    ]

    public static func readableKey(_ key: String) -> String { readableInfoKeys[key] ?? key }

    /// "Custom iOS Target Properties" etc.
    public func infoSectionTitle(target: String, configuration: String) -> String {
        "Custom \(supportedDestinations(target: target, configuration: configuration).first?.sdk ?? "macOS") Target Properties"
    }

    /// The collapsed sections below the table, with their counts.
    public func infoTypeSections(target: String, configuration: String) -> [String] {
        let dict = infoDictionary(target: target, configuration: configuration)
        return [("Document Types", "CFBundleDocumentTypes"), ("Exported Type Identifiers", "UTExportedTypeDeclarations"),
                ("Imported Type Identifiers", "UTImportedTypeDeclarations"), ("URL Types", "CFBundleURLTypes")].map { title, key in
            let n: Int = if case .array(let a)? = dict.first(where: { $0.key == key })?.value { a.count } else { 0 }
            return "\(title) (\(n))"
        }
    }

    func infoDictionary(target: String, configuration: String) -> [PropertyListEntry] {
        guard let file = resolve(target: target, configuration: configuration)?.settings["INFOPLIST_FILE"], !file.isEmpty else { return [] }
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : proj.projectDirectory(xcodeprojURL: xcodeprojURL).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url), let doc = try? PropertyListDocument(data: data), case .dictionary(let d) = doc.root else { return [] }
        return d
    }

    /// Info rows with readable key names (the table's display form).
    public func readableInfoRows(target: String, configuration: String) -> [InfoRow] {
        infoItems(target: target, configuration: configuration).map { InfoRow(key: $0.key, type: $0.type, value: $0.value) }
    }

    /// A row of the Info table: the raw and readable key, the type, the
    /// value as shown, and a container's children (reference-ui-5.md
    /// §11.1.5, P5).
    public struct InfoItem: Equatable, Sendable {
        public var rawKey: String
        public var key: String
        public var type: String
        public var value: String
        public var children: [InfoItem]
        public var isContainer: Bool { type == "Array" || type == "Dictionary" }
    }

    /// Keys a generated Info.plist always holds, with the build setting
    /// each value comes from (the build system's Info.plist generation,
    /// public build-setting reference). `LSRequiresIPhoneOS` is iOS only.
    static let generatedInfoKeys: [(key: String, value: PropertyListItem)] = [
        ("CFBundleName", .string("$(PRODUCT_NAME)")), ("CFBundleIdentifier", .string("$(PRODUCT_BUNDLE_IDENTIFIER)")),
        ("CFBundleInfoDictionaryVersion", .string("6.0")), ("CFBundleShortVersionString", .string("$(MARKETING_VERSION)")),
        ("CFBundleVersion", .string("$(CURRENT_PROJECT_VERSION)")), ("CFBundleExecutable", .string("$(EXECUTABLE_NAME)")),
        ("LSRequiresIPhoneOS", .bool(true)), ("CFBundlePackageType", .string("$(PRODUCT_BUNDLE_PACKAGE_TYPE)")),
        ("CFBundleDevelopmentRegion", .string("$(DEVELOPMENT_LANGUAGE)")),
    ]

    /// The order the reference shows a generated iOS app's keys in
    /// (reference-ui-3.md §1.7); other keys follow in their own order.
    static let infoKeyOrder = [
        "CFBundleName", "CFBundleIdentifier", "CFBundleInfoDictionaryVersion", "CFBundleShortVersionString", "CFBundleVersion",
        "CFBundleExecutable", "LSRequiresIPhoneOS", "UIApplicationSceneManifest", "UISupportedInterfaceOrientations",
        "UISupportedInterfaceOrientations~iphone", "UISupportedInterfaceOrientations~ipad", "CFBundlePackageType", "UILaunchScreen", "CFBundleDevelopmentRegion", "UIApplicationSupportsIndirectInputEvents",
    ]

    /// Info.plist keys whose `INFOPLIST_KEY_*` value is a Boolean.
    static let booleanInfoKeys: Set<String> = [
        "LSRequiresIPhoneOS", "UIApplicationSupportsIndirectInputEvents", "UIStatusBarHidden", "UIRequiresFullScreen",
        "UIApplicationSupportsMultipleScenes", "ITSAppUsesNonExemptEncryption", "LSUIElement", "UIFileSharingEnabled",
        "LSSupportsOpeningDocumentsInPlace", "UISupportsDocumentBrowser", "NSSupportsSuddenTermination", "NSSupportsAutomaticTermination",
    ]

    /// The Info.plist key and value an `INFOPLIST_KEY_*` setting produces;
    /// nil for a setting that produces none (a `_Generation` set to NO).
    static func generatedInfoEntry(setting name: String, definition: String) -> PropertyListEntry? {
        var key = String(name.dropFirst("INFOPLIST_KEY_".count))
        if key.hasSuffix("_Generation") {
            guard definition.uppercased() == "YES" else { return nil }
            key = String(key.dropLast("_Generation".count))
            let value: PropertyListItem = key == "UIApplicationSceneManifest"
                ? .dictionary([.init(key: "UIApplicationSupportsMultipleScenes", value: .bool(true))]) : .dictionary([])
            return .init(key: key, value: value)
        }
        for (suffix, device) in [("_iPhone", "iphone"), ("_iPad", "ipad")] where key.hasSuffix(suffix) {
            key = String(key.dropLast(suffix.count)) + "~" + device
        }
        if key.hasPrefix("UISupportedInterfaceOrientations") {
            return .init(key: key, value: .array(definition.split(separator: " ").map { .string(String($0)) }))
        }
        if booleanInfoKeys.contains(key) {
            return .init(key: key, value: .bool(["YES", "TRUE", "1"].contains(definition.uppercased())))
        }
        return .init(key: key, value: .string(definition))
    }

    /// The Info table: for a generated Info.plist the generated keys (values
    /// from build settings shown as `$(…)`), the `INFOPLIST_KEY_*` settings
    /// (their definitions, unexpanded) and the file's keys; else the file's
    /// keys in file order. Keys have their readable names.
    public func infoItems(target: String, configuration: String) -> [InfoItem] {
        guard let r = resolve(target: target, configuration: configuration) else { return [] }
        var entries: [PropertyListEntry] = []
        func put(_ e: PropertyListEntry) {
            if let i = entries.firstIndex(where: { $0.key == e.key }) { entries[i] = e } else { entries.append(e) }
        }
        let generated = generatesInfoPlist(target: target, configuration: configuration)
        if generated {
            let ios = supportedDestinations(target: target, configuration: configuration).contains { $0.sdk == "iOS" }
            for g in Self.generatedInfoKeys where ios || g.key != "LSRequiresIPhoneOS" { put(.init(key: g.key, value: g.value)) }
            for n in r.settings.names where n.hasPrefix("INFOPLIST_KEY_") {
                if let e = Self.generatedInfoEntry(setting: n, definition: definition(n, in: r.settings) ?? r.settings[n]) { put(e) }
            }
        }
        for e in infoDictionary(target: target, configuration: configuration) { put(e) }
        if generated {
            let rank = Dictionary(uniqueKeysWithValues: Self.infoKeyOrder.enumerated().map { ($1, $0) })
            entries = entries.enumerated().sorted { a, b in
                (rank[a.element.key] ?? Int.max, a.offset) < (rank[b.element.key] ?? Int.max, b.offset)
            }.map(\.element)
        }
        return entries.map { Self.infoItem(key: $0.key, $0.value) }
    }

    static func infoItem(key: String, _ v: PropertyListItem) -> InfoItem {
        let children: [InfoItem] = switch v {
        case .dictionary(let d): d.map { infoItem(key: $0.key, $0.value) }
        case .array(let a): a.enumerated().map { infoItem(key: "Item \($0.offset)", $0.element) }
        default: []
        }
        return InfoItem(rawKey: key, key: readableKey(key), type: v.typeName, value: v.summary, children: children)
    }

    /// A setting's own text at the most specific level that assigns it
    /// (target, its xcconfig, project, its xcconfig), unexpanded.
    func definition(_ name: String, in s: BuildSettings) -> String? {
        for level in ["target", "target-xcconfig", "project", "project-xcconfig"] {
            if let t = s.assignedText(name, inLevel: level) { return t }
        }
        return nil
    }

    // MARK: Build settings

    public static let basicSections: [(section: String, settings: [(name: String, title: String)])] = [
        ("Deployment", [("INSTALL_PATH", "Installation Directory"), ("STRIP_INSTALLED_PRODUCT", "Strip Linked Product"),
                        ("TARGETED_DEVICE_FAMILY", "Targeted Device Families")]),
        ("Info.plist Values", [("INFOPLIST_KEY_UIApplicationSceneManifest_Generation", "Application Scene Manifest (Generation)"),
                               ("INFOPLIST_KEY_UILaunchScreen_Generation", "Launch Screen (Generation)"),
                               ("INFOPLIST_KEY_UISupportedInterfaceOrientations", "Supported Interface Orientations"),
                               ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents", "Supports Indirect Events")]),
        ("Linking - General", [("LD_RUNPATH_SEARCH_PATHS", "Runpath Search Paths")]),
        ("Packaging", [("GENERATE_INFOPLIST_FILE", "Generate Info.plist File"), ("INFOPLIST_FILE", "Info.plist File"),
                       ("PRODUCT_BUNDLE_IDENTIFIER", "Product Bundle Identifier"), ("PRODUCT_NAME", "Product Name")]),
        ("Signing", [("CODE_SIGN_STYLE", "Code Signing Style")]),
        ("Versioning", [("CURRENT_PROJECT_VERSION", "Current Project Version"), ("MARKETING_VERSION", "Marketing Version")]),
        ("Swift Compiler - Language", [("SWIFT_VERSION", "Swift Language Version")]),
    ]

    public static var settingTitles: [String: String] {
        Dictionary(basicSections.flatMap(\.settings).map { ($0.name, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    public struct SettingSection: Equatable, Sendable {
        public var title: String
        public var names: [String]
    }

    /// Basic view sections; User-Defined lists customized settings with no
    /// known title, by raw name.
    public func basicSettingSections(target: String?, configuration: String) -> [SettingSection] {
        var out = Self.basicSections.map { SettingSection(title: $0.section, names: $0.settings.map(\.name)) }
        guard let s = resolve(target: target, configuration: configuration)?.settings else { return out }
        let levels = target == nil ? Set(["project"]) : Set(["target", "project"])
        let titled = Set(Self.settingTitles.keys)
        let user = s.names.filter { s.isAssigned($0, inLevels: levels) && !titled.contains($0) && !Self.knownSettingNames.contains($0) }.sorted()
        if !user.isEmpty { out.append(SettingSection(title: "User-Defined", names: user)) }
        return out
    }

    /// Settings that belong to a named section in the full view (not
    /// User-Defined).
    static let knownSettingNames: Set<String> = Set(basicSettings).union([
        "ASSETCATALOG_COMPILER_APPICON_NAME", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "IPHONEOS_DEPLOYMENT_TARGET",
        "ENABLE_PREVIEWS", "SWIFT_EMIT_LOC_STRINGS", "INFOPLIST_KEY_CFBundleDisplayName", "ALWAYS_SEARCH_USER_PATHS",
        "CLANG_ENABLE_MODULES", "ENABLE_USER_SCRIPT_SANDBOXING", "ENABLE_STRICT_OBJC_MSGSEND", "MTL_ENABLE_DEBUG_INFO",
        "ONLY_ACTIVE_ARCH", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "SWIFT_COMPILATION_MODE", "VALIDATE_PRODUCT", "COPY_PHASE_STRIP",
        "ENABLE_TESTABILITY", "ENABLE_NS_ASSERTIONS", "GCC_PREPROCESSOR_DEFINITIONS", "GCC_C_LANGUAGE_STANDARD",
        "CLANG_CXX_LANGUAGE_STANDARD", "LOCALIZATION_PREFERS_STRING_CATALOGS", "SWIFT_APPROACHABLE_CONCURRENCY",
        "SWIFT_DEFAULT_ACTOR_ISOLATION", "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY", "STRING_CATALOG_GENERATE_SYMBOLS",
        "XROS_DEPLOYMENT_TARGET", "TVOS_DEPLOYMENT_TARGET", "WATCHOS_DEPLOYMENT_TARGET", "SUPPORTS_MACCATALYST",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD", "DEAD_CODE_STRIPPING",
    ])

    /// Whether a setting is drawn bold: defined at the shown level.
    public func isDefinedAtShownLevel(_ name: String, target: String?, configuration: String) -> Bool {
        guard let s = resolve(target: target, configuration: configuration)?.settings else { return false }
        return s.isAssigned(name, inLevels: target == nil ? ["project", "project-xcconfig"] : ["target", "target-xcconfig"])
    }

    /// Levels view column titles: Setting | Resolved | target | project | platform default.
    public func levelsColumnTitles(target: String?) -> [String] {
        ["Setting", "Resolved"] + (target.map { [$0] } ?? []) + [projectName, Self.platformDefaultTitle(proj: proj, target: target, model: self)]
    }

    static func platformDefaultTitle(proj: PBXProj, target: String?, model: ProjectEditorModel) -> String {
        let sdk = model.configurations(of: target).defaultName.flatMap { model.resolve(target: target, configuration: $0)?.settings["SDKROOT"] } ?? ""
        return switch sdk {
        case "iphoneos": "iOS Default"
        case "xros": "visionOS Default"
        case "appletvos": "tvOS Default"
        case "watchos": "watchOS Default"
        default: "macOS Default"
        }
    }

    public static let multipleValues = "<Multiple values>"

    /// Per-configuration values; the collapsed row shows `<Multiple values>`
    /// when they differ, and expands to one row per configuration.
    public func valuesByConfiguration(_ name: String, target: String?) -> (collapsed: String, perConfiguration: [(String, String)]?) {
        let pairs = configurations(of: target).names.map { ($0, resolve(target: target, configuration: $0)?.settings[name] ?? "") }
        guard Set(pairs.map(\.1)).count > 1 else { return (pairs.first?.1 ?? "", nil) }
        return (Self.multipleValues, pairs)
    }

    // MARK: Build phases

    public static func phaseTitle(_ name: String, count: Int) -> String {
        "\(name) (\(count) item\(count == 1 ? "" : "s"))"
    }

    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "cxx", "metal", "s", "intentdefinition"]
    static let ignoredExtensions: Set<String> = ["h", "hpp", "plist", "entitlements", "xcconfig", "md"]

    /// Files of the target's synchronized folders, as "<file> …in <folder>",
    /// split into the Compile Sources and Copy Bundle Resources phases.
    public func synchronizedPhaseItems(target name: String) -> (sources: [String], resources: [String]) {
        guard let t = target(named: name) else { return ([], []) }
        let dir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        var sources: [String] = [], resources: [String] = []
        let fm = FileManager.default
        for g in t.references("fileSystemSynchronizedGroups").compactMap({ proj[$0] }) {
            guard let path = g.string("path") else { continue }
            let folder = (path as NSString).lastPathComponent
            let root = dir.appendingPathComponent(path)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            var files: [(String, String)] = []
            for case let u as URL in e {
                let ext = u.pathExtension.lowercased()
                // Bundles (asset catalogs, storyboards) are one resource.
                if ["xcassets", "xcstrings", "storyboard", "xib", "bundle", "lproj", "xcdatamodeld", "rcproject"].contains(ext) {
                    files.append((u.lastPathComponent, ext)); e.skipDescendants(); continue
                }
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                files.append((u.lastPathComponent, ext))
            }
            for (f, ext) in files.sorted(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }) {
                let row = "\(f) \u{2026}in \(folder)"
                if Self.sourceExtensions.contains(ext) { sources.append(row) }
                else if !Self.ignoredExtensions.contains(ext) { resources.append(row) }
            }
        }
        return (sources, resources)
    }

    public struct PhaseMenuItem: Equatable, Sendable {
        public var title: String
        public var isa: String
        public var enabled: Bool
        /// A separator follows this item.
        public var separatorAfter: Bool
    }

    /// The Build Phases "+" menu. Kinds that exist once per target are
    /// disabled when present; Headers applies only to library/framework
    /// targets; Carbon resources never apply to modern targets.
    public func addPhaseMenu(target name: String) -> [PhaseMenuItem] {
        let t = target(named: name)
        let present = Set((t.map { proj.buildPhases(ofTarget: $0.id) } ?? []).map(\.isa))
        let type = t?.string("productType") ?? ""
        let headersApply = type.contains("framework") || type.contains("library")
        return [
            PhaseMenuItem(title: "New Copy Files Phase", isa: "PBXCopyFilesBuildPhase", enabled: true, separatorAfter: false),
            PhaseMenuItem(title: "New Run Script Phase", isa: "PBXShellScriptBuildPhase", enabled: true, separatorAfter: true),
            PhaseMenuItem(title: "New Headers Phase", isa: "PBXHeadersBuildPhase", enabled: headersApply && !present.contains("PBXHeadersBuildPhase"), separatorAfter: false),
            PhaseMenuItem(title: "New Copy Bundle Resources Phase", isa: "PBXResourcesBuildPhase", enabled: !present.contains("PBXResourcesBuildPhase"), separatorAfter: false),
            PhaseMenuItem(title: "New Compile Sources Phase", isa: "PBXSourcesBuildPhase", enabled: !present.contains("PBXSourcesBuildPhase"), separatorAfter: false),
            PhaseMenuItem(title: "New Link Binary With Libraries Phase", isa: "PBXFrameworksBuildPhase", enabled: !present.contains("PBXFrameworksBuildPhase"), separatorAfter: false),
            PhaseMenuItem(title: "New Build Carbon Resources Phase", isa: "PBXRezBuildPhase", enabled: false, separatorAfter: false),
        ]
    }

    /// Phases that have a trash button (all but Target Dependencies and
    /// Run Build Tool Plug-ins).
    public static func phaseIsRemovable(_ title: String) -> Bool {
        !["Target Dependencies", "Run Build Tool Plug-ins"].contains(title)
    }

    // MARK: Build rules

    public static let buildRuleScopes = ["All", "Custom"]

    public struct RuleSection: Equatable, Sendable {
        public var title: String
        public var process: String
        public var using: String
    }

    /// Build Rules sections, sorted by rule name.
    public func ruleSections(target name: String) -> [RuleSection] { ruleSectionIDs(target: name).map(\.section) }

    // MARK: Project ▸ Info

    public struct ProjectInfo: Equatable, Sendable {
        /// (configuration name, base configuration file name or nil).
        public var configurations: [String]
        public var baseFiles: [String?]
        public var commandLineConfiguration: String?
        public var parallelizeCommandLine: Bool
        public var localizations: [(name: String, isDefault: Bool)]
        public var usesBaseInternationalization: Bool
        public static func == (a: Self, b: Self) -> Bool {
            a.configurations == b.configurations && a.baseFiles == b.baseFiles && a.commandLineConfiguration == b.commandLineConfiguration
                && a.parallelizeCommandLine == b.parallelizeCommandLine && a.usesBaseInternationalization == b.usesBaseInternationalization
                && a.localizations.map(\.name) == b.localizations.map(\.name) && a.localizations.map(\.isDefault) == b.localizations.map(\.isDefault)
        }
    }

    public static let noConfigurationsText = "No Configurations Set"
    public static let parallelizeTitle = "Parallelize build for command-line builds (does not apply when using schemes)"

    public var projectInfo: ProjectInfo {
        let listID = proj.project?.string("buildConfigurationList")
        let configs = proj.buildConfigurations(listID: listID)
        let regions = proj.project?["knownRegions"]?.array?.compactMap(\.string) ?? []
        let dev = proj.project?.string("developmentRegion") ?? "en"
        let names = Locale(identifier: "en")
        return ProjectInfo(
            configurations: configs.compactMap { $0.string("name") },
            baseFiles: configs.map { c in c.string("baseConfigurationReference").flatMap { proj[$0] }.flatMap { $0.string("name") ?? $0.string("path").map { ($0 as NSString).lastPathComponent } } },
            commandLineConfiguration: proj[listID ?? ""]?.string("defaultConfigurationName"),
            parallelizeCommandLine: proj.project?["attributes"]?.dictionary?["BuildIndependentTargetsInParallel"]?.string.map { $0 == "1" || $0 == "YES" } ?? true,
            localizations: regions.filter { $0 != "Base" }.map { r in
                let label = names.localizedString(forIdentifier: r) ?? r
                return ("\(label)\(r == dev ? " (Development Language)" : "")", r == dev)
            },
            usesBaseInternationalization: regions.contains("Base"))
    }

    // MARK: Package Dependencies

    public static let packagesEmptyText = "Add packages here"
    public static func packagesHeader(count: Int) -> String { "Packages (\(count) item\(count == 1 ? "" : "s"))" }

    // MARK: Project file inspector

    /// Compatibility pop-up titles with the objectVersion each writes,
    /// newest first (specs/formats/pbxproj.md, Project format). "Xcode 16.0" records
    /// `preferredProjectObjectVersion`; older ones record
    /// `compatibilityVersion` (specs/formats/pbxproj.md).
    public static let compatibilityVersions: [(title: String, objectVersion: Int)] = [
        ("Xcode 16.0", 77), ("Xcode 15.3", 63), ("Xcode 15.0", 60), ("Xcode 14.0", 56), ("Xcode 13.0", 55),
        ("Xcode 12.0", 54), ("Xcode 11.4", 53), ("Xcode 11.0", 52), ("Xcode 10.0", 51), ("Xcode 9.3", 50),
        ("Xcode 8.0", 48), ("Xcode 6.3", 47), ("Xcode 3.2", 46), ("Xcode 3.1", 45),
    ]

    /// Compatibility pop-up title for an objectVersion.
    public static func compatibility(objectVersion: String) -> String {
        let v = Int(objectVersion) ?? 0
        return compatibilityVersions.first { $0.objectVersion <= v }?.title ?? "Xcode 3.1"
    }

    /// The project's compatibility: its `compatibilityVersion`, else its
    /// `preferredProjectObjectVersion`, else its objectVersion.
    public var compatibility: String {
        if let c = proj.project?.string("compatibilityVersion"), Self.compatibilityVersions.contains(where: { $0.title == c }) { return c }
        if let p = proj.project?.string("preferredProjectObjectVersion") { return Self.compatibility(objectVersion: p) }
        return Self.compatibility(objectVersion: proj.objectVersion)
    }

    /// Chooses a Compatibility title: sets objectVersion and the matching
    /// PBXProject attribute.
    public mutating func setCompatibility(_ title: String) {
        guard let entry = Self.compatibilityVersions.first(where: { $0.title == title }), var p = proj.project else { return }
        proj.objectVersion = String(entry.objectVersion)
        if entry.objectVersion >= 77 {
            p["compatibilityVersion"] = nil
            p["preferredProjectObjectVersion"] = .string(String(entry.objectVersion))
        } else {
            p["preferredProjectObjectVersion"] = nil
            p["compatibilityVersion"] = .string(title)
        }
        proj[p.id] = p
    }

    /// "Minimize Project References": `minimizedProjectReferenceProxies = 1`,
    /// or the key removed.
    public mutating func setMinimizeProjectReferences(_ on: Bool) {
        guard var p = proj.project else { return }
        p["minimizedProjectReferenceProxies"] = on ? .string("1") : nil
        proj[p.id] = p
    }

    public struct ProjectDocumentSection: Equatable, Sendable {
        public var compatibility: String
        public var minimizeProjectReferences: Bool
        public var strictlyValidate: Bool
        public var organization: String
        public var classPrefix: String
    }

    public var projectDocumentSection: ProjectDocumentSection {
        let attrs = proj.project?["attributes"]?.dictionary
        let minimized = proj.project?.string("minimizedProjectReferenceProxies")
        return ProjectDocumentSection(
            compatibility: compatibility,
            minimizeProjectReferences: minimized == "1" || minimized == "YES",
            strictlyValidate: false,
            organization: attrs?["ORGANIZATIONNAME"]?.string ?? "",
            classPrefix: attrs?["CLASSPREFIX"]?.string ?? "")
    }
}
