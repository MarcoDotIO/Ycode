import Foundation
import YcodeProject

/// Builds the settings stack for a target (or the project) of a pbxproj:
///
///     defaults < builtins < project xcconfig < project < target xcconfig < target < overrides
///
/// See `specs/build-settings.md` §3.
public struct ProjectSettingsBuilder {
    /// The parsed project.
    public var proj: PBXProj
    /// The `.xcodeproj` bundle; relative paths resolve against its parent.
    public var xcodeprojURL: URL
    /// The `.xcodeproj` name without the extension (`PROJECT_NAME`).
    public var projectName: String
    /// The lowest level (platform, SDK, and spec defaults). Empty for now.
    /// Callers can supply one.
    public var defaults = SettingsLevel(name: "defaults")
    /// Command-line style overrides (`NAME=value`), the highest level.
    public var overrides: [String: String] = [:]
    /// Replaces a `<DEVELOPER_DIR>` prefix in xcconfig include paths; when
    /// nil, such an include is skipped with a diagnostic.
    public var developerDirectory: String?
    /// Resolves an `SDKROOT` value to an installed SDK.
    public var sdkLookup: (String) -> SDKCatalog.SDK? = { _ in nil }

    /// Takes `projectName` from the last path component of `xcodeprojURL`.
    public init(proj: PBXProj, xcodeprojURL: URL) {
        self.proj = proj
        self.xcodeprojURL = xcodeprojURL
        projectName = xcodeprojURL.deletingPathExtension().lastPathComponent
    }

    /// The result of `resolve(target:configuration:)`.
    public struct Resolved {
        /// The evaluator over the full level stack.
        public var settings: BuildSettings
        /// The levels above `builtins` (the ones the project defines).
        public var definedLevelNames: [String]
        /// Missing configurations and unreadable or invalid xcconfig files,
        /// found while building the stack.
        public var diagnostics: [String]
    }

    /// Resolves settings for `targetName` (nil = project level) in `configuration`.
    public func resolve(target targetName: String?, configuration: String) throws -> Resolved {
        var diagnostics: [String] = []
        let projectDir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = proj.parentMap()
        guard let project = proj.project else { throw SettingsError.noProject }
        let target = try targetName.map { name in
            guard let t = proj.targets.first(where: { $0.string("name") == name }) else { throw SettingsError.noSuchTarget(name) }
            return t
        }

        // A configuration missing from the project falls back to the
        // project's default configuration, for every level.
        let projectConfigs = proj.buildConfigurations(listID: project.string("buildConfigurationList"))
        var configuration = configuration
        if !projectConfigs.contains(where: { $0.string("name") == configuration }),
           let fallback = proj.objects[project.string("buildConfigurationList") ?? ""]?.string("defaultConfigurationName") {
            diagnostics.append("configuration '\(configuration)' not found; using '\(fallback)'")
            configuration = fallback
        }

        func config(of owner: PBXObject) -> PBXObject? {
            let configs = proj.buildConfigurations(listID: owner.string("buildConfigurationList"))
            if let c = configs.first(where: { $0.string("name") == configuration }) { return c }
            let fallback = proj.objects[owner.string("buildConfigurationList") ?? ""]?.string("defaultConfigurationName")
            return configs.first { $0.string("name") == fallback }
        }

        func levels(for owner: PBXObject, prefix: String) -> [SettingsLevel] {
            guard let cfg = config(of: owner) else {
                diagnostics.append("\(prefix): no configuration named \(configuration)")
                return []
            }
            var out: [SettingsLevel] = []
            if let xcconfigPath = xcconfigPath(cfg, projectDir: projectDir, parents: parents) {
                do {
                    let x = try XCConfig(contentsOf: URL(fileURLWithPath: xcconfigPath), developerDirectory: developerDirectory)
                    diagnostics += x.diagnostics
                    out.append(SettingsLevel(name: "\(prefix)-xcconfig", assignments: x.assignments))
                } catch {
                    diagnostics.append("\(prefix): unable to open base configuration \(xcconfigPath)")
                }
            }
            let bs = cfg["buildSettings"]?.dictionary.map { d in d.compactMap { k, v in v.settingText.map { (key: k, value: $0) } } } ?? []
            out.append(SettingsLevel(name: prefix, buildSettings: bs))
            return out
        }

        var builtins: [String: String] = [
            "PROJECT_DIR": projectDir.path,
            "SRCROOT": projectDir.path,
            "SOURCE_ROOT": projectDir.path,
            "PROJECT_NAME": projectName,
            "PROJECT": projectName,
            "PROJECT_FILE_PATH": xcodeprojURL.path,
            "CONFIGURATION": configuration,
            "ACTION": "build",
        ]
        if let t = target {
            builtins["TARGET_NAME"] = t.string("name") ?? ""
            builtins["TARGETNAME"] = t.string("name") ?? ""
        }

        var stack = [defaults, SettingsLevel(name: "builtins", literals: builtins)]
        stack += levels(for: project, prefix: "project")
        if let t = target { stack += levels(for: t, prefix: "target") }
        if !overrides.isEmpty {
            stack.append(SettingsLevel(name: "overrides", assignments: overrides.keys.sorted().compactMap { k in
                SettingAssignment.splitKey(k).map { SettingAssignment(name: $0.name, conditions: $0.conditions, value: overrides[k]!, origin: "overrides") }
            }))
        }

        // The SDK condition depends on SDKROOT, which is itself a setting:
        // resolve once without it, then again with the canonical SDK name.
        // An SDK that is not installed matches by its literal SDKROOT value.
        var context: ConditionContext = ["config": configuration, "variant": "normal"]
        let sdkroot = BuildSettings(levels: stack, context: context)["SDKROOT"]
        let sdk = sdkLookup(sdkroot)
        if let sdk { context["sdk"] = sdk.canonicalName } else if !sdkroot.isEmpty { context["sdk"] = sdkroot }
        let base = BuildSettings(levels: stack, context: context)
        let derived = DerivedSettings.compute(base, .init(
            targetClass: target?.isa, productType: target?.string("productType"), platform: sdk?.platform, sdkPath: sdk?.path))
        stack.append(SettingsLevel(name: "derived", literals: derived))
        let settings = BuildSettings(levels: stack, context: context)
        diagnostics += settings.diagnostics
        let defined = stack.map(\.name).drop { $0 != "builtins" }.dropFirst().filter { $0 != "derived" }
        return Resolved(settings: settings, definedLevelNames: Array(defined), diagnostics: diagnostics)
    }

    /// The xcconfig a configuration is based on. It is either a file reference
    /// or (Xcode 16+) a path relative to a synchronized folder.
    func xcconfigPath(_ cfg: PBXObject, projectDir: URL, parents: [String: String]) -> String? {
        if let ref = cfg.string("baseConfigurationReference") {
            return proj.resolvedPath(of: ref, projectDirectory: projectDir, parents: parents)
        }
        if let anchor = cfg.string("baseConfigurationReferenceAnchor"),
           let rel = cfg.string("baseConfigurationReferenceRelativePath"),
           let base = proj.resolvedPath(of: anchor, projectDirectory: projectDir, parents: parents) {
            return URL(fileURLWithPath: base).appendingPathComponent(rel).path
        }
        return nil
    }
}

public enum SettingsError: Error, CustomStringConvertible {
    case noProject
    case noSuchTarget(String)
    public var description: String {
        switch self {
        case .noProject: "project has no root PBXProject"
        case .noSuchTarget(let t): "no target named '\(t)'"
        }
    }
}

import YcodePlist

extension PlistValue {
    /// A build-setting value as text. Arrays are joined with spaces, and
    /// elements that contain whitespace are quoted, as in `buildSettings`
    /// lists.
    var settingText: String? {
        switch self {
        case .string(let s): s
        case .array(let a):
            a.compactMap(\.string).map { s in
                s.contains(where: { $0 == " " || $0 == "\t" }) && !s.hasPrefix("\"") ? "\"\(s)\"" : s
            }.joined(separator: " ")
        default: nil
        }
    }
}
