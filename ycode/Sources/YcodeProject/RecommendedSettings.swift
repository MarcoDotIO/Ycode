import Foundation
import YcodePlist

/// Ycode's project validation (`specs/ide/issues.md` §1, §5, §6; P-120):
/// compares a project's build settings with the recommended set and lists
/// the changes the checklist sheet offers. Any change makes the project
/// report one file-less warning, "Update to recommended settings".
///
/// The rows are the spec's (§5), in its order; Ycode's own choices for what
/// the spec leaves open (§7) are recorded in `issues.md` §8:
/// - A target's row reads its configuration's value, falling back to the
///   project's configuration of the same name; a project row reads the
///   project's configurations only. A value that starts with `YES` counts as
///   set (a stricter `YES_ERROR` or `YES_AGGRESSIVE` is never weakened).
/// - A key a configuration does not set, whose value would come from an
///   `.xcconfig` base configuration, is left alone (it is not known here).
/// - Perform Changes writes exactly the keys a row names, in the
///   configurations that lack them, and the running version into
///   `LastUpgradeCheck`; nothing else.
/// - Only a project whose `LastUpgradeCheck` is missing or older than the
///   running version is checked (§1 item 5).
public enum RecommendedSettings {
    /// The warning's text in the issue navigator (§3).
    public static let warningMessage = "Update to recommended settings"

    /// The IDE version Ycode records and checks against, as four digits
    /// (`LastUpgradeCheck`, `templates.md`): the reference release, 27.1.
    public static let ideVersionDigits = "2710"

    /// The project's `LastUpgradeCheck` (nil: missing).
    public static func lastUpgradeCheck(_ proj: PBXProj) -> String? {
        proj.project?["attributes"]?.dictionary?["LastUpgradeCheck"]?.string
    }

    /// Whether the project is checked at all (§1 item 5): its
    /// `LastUpgradeCheck` is missing or lower than the running version. A
    /// project created or updated by this version is not.
    public static func isCheckDue(_ proj: PBXProj, ideVersion: String = ideVersionDigits) -> Bool {
        guard let v = lastUpgradeCheck(proj), let have = Int(v), let running = Int(ideVersion) else { return true }
        return have < running
    }

    /// The checklist's groups, in order (§5).
    public enum Group: String, CaseIterable, Sendable, Equatable {
        case assetCatalog = "Asset Catalog"
        case buildSettings = "Build Settings"
        case localization = "Localization"
    }

    /// One setting written into one configuration.
    public struct Edit: Equatable, Sendable {
        public var configurationID: String
        public var key: String
        public var value: String
        public init(configurationID: String, key: String, value: String) {
            self.configurationID = configurationID
            self.key = key
            self.value = value
        }
    }

    /// One row of the checklist: its title, explanation (and a bulleted list
    /// for the recommended warnings), whether it starts checked, and the
    /// settings Perform Changes writes for it.
    public struct Change: Equatable, Sendable, Identifiable {
        public var id: String
        public var group: Group
        public var title: String
        public var explanation: String
        public var bullets: [String]
        public var isCheckedByDefault: Bool
        public var edits: [Edit]
    }

    /// A recommended compiler warning: its build setting, the value Perform
    /// Changes writes, and the title the list shows.
    public struct Warning: Equatable, Sendable {
        public var key: String
        public var value: String
        public var title: String
    }

    /// The recommended compiler warnings: the warning settings every new
    /// project gets (`specs/ide/templates.md`, project-level settings), so
    /// a project made from a template has none missing. Titles after the
    /// build settings' public titles. The full list the reference offers is
    /// open (`issues.md` §7 item 1); Ycode offers no warning it cannot name.
    public static let recommendedWarnings: [Warning] = [
        Warning(key: "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING", value: "YES", title: "Block Capture of Autoreleasing"),
        Warning(key: "CLANG_WARN__DUPLICATE_METHOD_MATCH", value: "YES", title: "Duplicate Method Definitions"),
        Warning(key: "CLANG_WARN_BOOL_CONVERSION", value: "YES", title: "Implicit Boolean Conversions"),
        Warning(key: "CLANG_WARN_COMMA", value: "YES", title: "Suspicious Commas"),
        Warning(key: "CLANG_WARN_CONSTANT_CONVERSION", value: "YES", title: "Implicit Constant Conversions"),
        Warning(key: "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS", value: "YES", title: "Overriding Deprecated Objective-C Methods"),
        Warning(key: "CLANG_WARN_DIRECT_OBJC_ISA_USAGE", value: "YES_ERROR", title: "Direct Usage of 'isa'"),
        Warning(key: "CLANG_WARN_DOCUMENTATION_COMMENTS", value: "YES", title: "Documentation Comments"),
        Warning(key: "CLANG_WARN_EMPTY_BODY", value: "YES", title: "Empty Loop Bodies"),
        Warning(key: "CLANG_WARN_ENUM_CONVERSION", value: "YES", title: "Implicit Enum Conversions"),
        Warning(key: "CLANG_WARN_INFINITE_RECURSION", value: "YES", title: "Infinite Recursion"),
        Warning(key: "CLANG_WARN_INT_CONVERSION", value: "YES", title: "Implicit Integer to Pointer Conversions"),
        Warning(key: "CLANG_WARN_NON_LITERAL_NULL_CONVERSION", value: "YES", title: "Implicit Non-Literal Null Conversions"),
        Warning(key: "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF", value: "YES", title: "Implicit Retain of 'self' Within Blocks"),
        Warning(key: "CLANG_WARN_OBJC_LITERAL_CONVERSION", value: "YES", title: "Implicit Objective-C Literal Conversions"),
        Warning(key: "CLANG_WARN_OBJC_ROOT_CLASS", value: "YES_ERROR", title: "Unintentional Root Class"),
        Warning(key: "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER", value: "YES", title: "Quoted Include in Framework Header"),
        Warning(key: "CLANG_WARN_RANGE_LOOP_ANALYSIS", value: "YES", title: "Range-based Loop Analysis"),
        Warning(key: "CLANG_WARN_STRICT_PROTOTYPES", value: "YES", title: "Strict Prototypes"),
        Warning(key: "CLANG_WARN_SUSPICIOUS_MOVE", value: "YES", title: "Suspicious Moves"),
        Warning(key: "CLANG_WARN_UNGUARDED_AVAILABILITY", value: "YES_AGGRESSIVE", title: "Unguarded Availability"),
        Warning(key: "CLANG_WARN_UNREACHABLE_CODE", value: "YES", title: "Unreachable Code"),
        Warning(key: "GCC_WARN_64_TO_32_BIT_CONVERSION", value: "YES", title: "Implicit Conversion to 32 Bit Type"),
        Warning(key: "GCC_WARN_ABOUT_RETURN_TYPE", value: "YES_ERROR", title: "Mismatched Return Type"),
        Warning(key: "GCC_WARN_UNDECLARED_SELECTOR", value: "YES", title: "Undeclared Selector"),
        Warning(key: "GCC_WARN_UNINITIALIZED_AUTOS", value: "YES_AGGRESSIVE", title: "Uninitialized Variables"),
        Warning(key: "GCC_WARN_UNUSED_FUNCTION", value: "YES", title: "Unused Functions"),
        Warning(key: "GCC_WARN_UNUSED_VARIABLE", value: "YES", title: "Unused Variables"),
    ]

    // MARK: Texts (§5)

    static let weakTitle = "Enable Weak References in Manual Retain Release"
    static let deadCodeTitle = "Enable Dead Code Stripping"
    static func weakExplanation(_ configuration: String) -> String {
        "Enabling weak references in manual retain release is recommended. This will set the CLANG_ENABLE_OBJC_WEAK setting to \"YES\" for the \"\(configuration)\" configuration."
    }
    static let deadCodeExplanation = "Enabling dead code stripping is recommended. This will update the DEAD_CODE_STRIPPING build setting."
    static let warningsExplanation = "This will enable the following recommended compiler warnings:"
    /// The reference's text was recorded up to the setting's name (§7 item 1);
    /// Ycode ends it as the dead-code row does.
    static let sandboxingExplanation = "Enabling user script sandboxing is recommended to ensure correctness of the build. This will enable the ENABLE_USER_SCRIPT_SANDBOXING build setting."
    static let assetSymbolsExplanation = "Generate asset symbol extensions on Apple framework color and image types."
    static let stringSymbolsExplanation = "Generate Swift code to access manually-added strings in your String Catalogs."

    // MARK: Detection

    /// The changes the checklist offers for `proj`, grouped and in the
    /// spec's order; empty when the project has the recommended settings.
    /// `projectDirectory` (the folder holding the `.xcodeproj`) lets the
    /// check look into synchronized folders for an asset catalog or a String
    /// Catalog; without it only the project's file references count.
    /// The rows the checklist offers: none for a project whose
    /// `LastUpgradeCheck` is current (§1 item 5; `gated: false` lists the
    /// rows whatever it says, for tests and measures).
    public static func changes(in proj: PBXProj, projectName: String, projectDirectory: URL? = nil, gated: Bool = true) -> [Change] {
        guard let project = proj.project, !gated || isCheckDue(proj) else { return [] }
        let projectConfigs = proj.buildConfigurations(listID: project.string("buildConfigurationList"))
        guard !projectConfigs.isEmpty else { return [] }
        let catalogs = catalogKinds(in: proj, projectDirectory: projectDirectory)

        // The project configurations a project-level setting is missing from.
        func missingAtProject(_ key: String) -> [PBXObject] {
            projectConfigs.filter { c in
                if let v = setting(c, key) { return !isSet(v) }
                return c.string("baseConfigurationReference") == nil
            }
        }
        func projectEdits(_ key: String, _ value: String = "YES") -> [Edit] {
            missingAtProject(key).map { Edit(configurationID: $0.id, key: key, value: value) }
        }

        var out: [Change] = []
        // Asset Catalog (unchecked, as the reference leaves it).
        if catalogs.assets {
            let key = "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"
            let edits = projectEdits(key)
            if !edits.isEmpty {
                out.append(Change(id: "asset-symbols", group: .assetCatalog, title: "Enable Generated Asset Symbol Extensions",
                                  explanation: assetSymbolsExplanation, bullets: [], isCheckedByDefault: false, edits: edits))
            }
        }
        // Build Settings: each native target's rows, in project order.
        for t in proj.targets where t.isa == "PBXNativeTarget" {
            let name = t.string("name") ?? ""
            let configs = proj.buildConfigurations(listID: t.string("buildConfigurationList"))
            func missing(_ c: PBXObject, _ key: String) -> Bool {
                if let v = setting(c, key) { return !isSet(v) }
                let fallback = projectConfigs.first { $0.string("name") == c.string("name") }
                if let f = fallback, let v = setting(f, key) { return !isSet(v) }
                return c.string("baseConfigurationReference") == nil && fallback?.string("baseConfigurationReference") == nil
            }
            for c in configs where missing(c, "CLANG_ENABLE_OBJC_WEAK") {
                let config = c.string("name") ?? ""
                out.append(Change(id: "weak|\(t.id)|\(c.id)", group: .buildSettings, title: "Target '\(name)' - \(weakTitle)",
                                  explanation: weakExplanation(config), bullets: [], isCheckedByDefault: true,
                                  edits: [Edit(configurationID: c.id, key: "CLANG_ENABLE_OBJC_WEAK", value: "YES")]))
            }
            let strip = configs.filter { missing($0, "DEAD_CODE_STRIPPING") }
            if !strip.isEmpty {
                out.append(Change(id: "strip|\(t.id)", group: .buildSettings, title: "Target '\(name)' \u{2014} \(deadCodeTitle)",
                                  explanation: deadCodeExplanation, bullets: [], isCheckedByDefault: true,
                                  edits: strip.map { Edit(configurationID: $0.id, key: "DEAD_CODE_STRIPPING", value: "YES") }))
            }
        }
        // The project's rows.
        var warningEdits: [Edit] = [], warningTitles: [String] = []
        for w in recommendedWarnings {
            let edits = projectEdits(w.key, w.value)
            if !edits.isEmpty { warningEdits += edits; warningTitles.append(w.title) }
        }
        if !warningEdits.isEmpty {
            out.append(Change(id: "warnings", group: .buildSettings, title: "Project '\(projectName)' - Enable Recommended Warnings",
                              explanation: warningsExplanation, bullets: warningTitles, isCheckedByDefault: true, edits: warningEdits))
        }
        let strip = projectEdits("DEAD_CODE_STRIPPING")
        if !strip.isEmpty {
            out.append(Change(id: "strip|project", group: .buildSettings, title: "Project '\(projectName)' \u{2014} \(deadCodeTitle)",
                              explanation: deadCodeExplanation, bullets: [], isCheckedByDefault: true, edits: strip))
        }
        let sandbox = projectEdits("ENABLE_USER_SCRIPT_SANDBOXING")
        if !sandbox.isEmpty {
            out.append(Change(id: "sandboxing", group: .buildSettings, title: "Enable User Script Sandboxing",
                              explanation: sandboxingExplanation, bullets: [], isCheckedByDefault: true, edits: sandbox))
        }
        // Localization.
        if catalogs.strings {
            let edits = projectEdits("STRING_CATALOG_GENERATE_SYMBOLS")
            if !edits.isEmpty {
                out.append(Change(id: "string-symbols", group: .localization,
                                  title: "Project '\(projectName)' \u{2014} Enable String Catalog Symbol Generation",
                                  explanation: stringSymbolsExplanation, bullets: [], isCheckedByDefault: true, edits: edits))
            }
        }
        return out
    }

    /// The project needs the warning: at least one change is offered.
    public static func needsUpdate(_ proj: PBXProj, projectName: String, projectDirectory: URL? = nil) -> Bool {
        !changes(in: proj, projectName: projectName, projectDirectory: projectDirectory).isEmpty
    }

    /// Writes the changes' settings (Perform Changes). Every other object
    /// and key is left as it was, so the writer reproduces its bytes.
    /// With at least one change, the project's `LastUpgradeCheck` becomes
    /// the running version (§1 item 5, Ycode's choice: the warning goes and
    /// the unchecked rows are not offered again by this version). No
    /// changes (Cancel): nothing is written.
    public static func apply(_ changes: [Change], to proj: inout PBXProj, ideVersion: String = ideVersionDigits) {
        guard !changes.isEmpty else { return }
        for c in changes {
            for e in c.edits { proj.setBuildSetting(e.key, .string(e.value), configuration: e.configurationID) }
        }
        markUpgradeChecked(&proj, ideVersion: ideVersion)
    }

    /// Writes `LastUpgradeCheck = <ideVersion>` into the project's
    /// attributes (created when missing); every other key stays.
    public static func markUpgradeChecked(_ proj: inout PBXProj, ideVersion: String = ideVersionDigits) {
        guard var project = proj.project else { return }
        var attributes = project["attributes"]?.dictionary ?? PlistDictionary()
        attributes["LastUpgradeCheck"] = .string(ideVersion)
        project["attributes"] = .dictionary(attributes)
        proj[project.id] = project
    }

    // MARK: Helpers

    static func setting(_ config: PBXObject, _ key: String) -> String? {
        guard let v = config["buildSettings"]?.dictionary?[key] else { return nil }
        return v.string ?? v.array?.compactMap(\.string).joined(separator: " ")
    }

    /// `YES`, `YES_ERROR`, `YES_AGGRESSIVE` (any case).
    static func isSet(_ value: String) -> Bool { value.uppercased().hasPrefix("YES") }

    /// Whether the project holds an asset catalog and a String Catalog: a
    /// file reference to one, or one inside a synchronized folder.
    static func catalogKinds(in proj: PBXProj, projectDirectory: URL?) -> (assets: Bool, strings: Bool) {
        var assets = false, strings = false
        func note(_ name: String) {
            switch (name as NSString).pathExtension.lowercased() {
            case "xcassets": assets = true
            case "xcstrings": strings = true
            default: break
            }
        }
        for o in proj.objects.values where o.isa == "PBXFileReference" {
            note(o.string("path") ?? "")
            if let t = o.string("lastKnownFileType") ?? o.string("explicitFileType") {
                if t == "folder.assetcatalog" { assets = true }
                if t == "text.json.xcstrings" { strings = true }
            }
        }
        guard !(assets && strings), let dir = projectDirectory else { return (assets, strings) }
        let parents = proj.parentMap()
        for g in proj.objects(isa: "PBXFileSystemSynchronizedRootGroup") {
            guard let path = proj.resolvedPath(of: g.id, projectDirectory: dir, parents: parents) else { continue }
            walk(URL(fileURLWithPath: path), depth: 0, note)
            if assets && strings { break }
        }
        return (assets, strings)
    }

    /// A shallow look through a folder (at most six levels, hidden items and
    /// bundles skipped) for catalogs.
    private static func walk(_ dir: URL, depth: Int, _ note: (String) -> Void) {
        guard depth < 6, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !SynchronizedFolder.isHidden(name) {
            note(name)
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext.isEmpty else { continue }
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { walk(url, depth: depth + 1, note) }
        }
    }
}
