import Foundation
import YcodeProject
import YcodePlist

/// Generates a Project Interchange Format (PIF) description of a pbxproj
/// project for swift-build. The PIF is a JSON array of top-level objects
/// (`workspace`, `project`, `target`), each `{signature, type, contents}`.
/// See `specs/ide/build-pif.md`.
public struct PIFGenerator {
    public enum GenerationError: Error, CustomStringConvertible {
        case noMainGroup
        case unsupported(String)
        public var description: String {
            switch self {
            case .noMainGroup: "the project has no main group"
            case .unsupported(let m): "unsupported by the PIF generator: \(m)"
            }
        }
    }

    public let proj: PBXProj
    public let xcodeprojURL: URL

    public init(proj: PBXProj, xcodeprojURL: URL) {
        self.proj = proj
        self.xcodeprojURL = xcodeprojURL.standardizedFileURL
    }

    /// Product types this generator emits targets for (the simplest cases).
    public static let supportedProductTypes: Set<String> = [
        "com.apple.product-type.tool", "com.apple.product-type.library.static",
        "com.apple.product-type.application", "com.apple.product-type.framework",
        "com.apple.product-type.library.dynamic",
    ]

    /// GUIDs are the pbxproj object IDs, prefixed so that objects of
    /// different projects in one workspace stay unique.
    func guid(_ id: String) -> String { "\(proj.rootObject)-\(id)" }

    var projectDirectory: URL { proj.projectDirectory(xcodeprojURL: xcodeprojURL) }

    /// File references that are some target's product.
    var productReferences: Set<String> { Set(proj.targets.compactMap { $0.string("productReference") }) }

    // MARK: Objects

    public func workspaceSignature() -> String { "WORKSPACE@\(xcodeprojURL.path)" }
    public func projectSignature() -> String { "PROJECT@\(guid(proj.rootObject))" }
    public func targetSignature(_ id: String) -> String { "TARGET@\(guid(id))" }

    /// The whole PIF: workspace, project and its supported targets.
    public func pif() throws -> JSONValue {
        .array([.object(["signature": .string(workspaceSignature()), "type": "workspace", "contents": workspaceContents()])]
               + (try projectObjects()))
    }

    /// Targets the PIF describes: supported native targets.
    var pifTargets: [PBXObject] {
        proj.targets.filter { Self.supportedProductTypes.contains($0.string("productType") ?? "") && $0.isa == "PBXNativeTarget" }
    }

    /// The project object and its target objects (no workspace).
    public func projectObjects() throws -> [JSONValue] {
        let targets = pifTargets
        guard !targets.isEmpty else { throw GenerationError.unsupported("no application, framework, library or command-line tool target") }
        // Every target must be supported: a dependency on a skipped one
        // could not be resolved.
        if let other = proj.targets.first(where: { t in !targets.contains { $0.id == t.id } }) {
            throw GenerationError.unsupported("target \(other.string("name") ?? other.id) (\(other.string("productType") ?? other.isa))")
        }
        var objects: [JSONValue] = [
            .object(["signature": .string(projectSignature()), "type": "project", "contents": try projectContents(targets: targets)]),
        ]
        for t in targets {
            objects.append(.object(["signature": .string(targetSignature(t.id)), "type": "target", "contents": try targetContents(t)]))
        }
        return objects
    }

    /// One PIF for several projects (an `.xcworkspace`).
    public static func workspacePIF(projects: [(PBXProj, URL)], workspaceURL: URL) throws -> JSONValue {
        let generators = projects.map { PIFGenerator(proj: $0.0, xcodeprojURL: $0.1) }
        var objects: [JSONValue] = [.object([
            "signature": .string("WORKSPACE@\(workspaceURL.standardizedFileURL.path)"), "type": "workspace",
            "contents": .object([
                "guid": .string("WORKSPACE-\(workspaceURL.standardizedFileURL.path)"),
                "name": .string(workspaceURL.deletingPathExtension().lastPathComponent),
                "path": .string(workspaceURL.appendingPathComponent("contents.xcworkspacedata").path),
                "projects": .array(generators.map { .string($0.projectSignature()) }),
            ]),
        ])]
        for g in generators { objects += try g.projectObjects() }
        return .array(objects)
    }

    /// The target that produces a file reference, if it is a product.
    func producingTarget(of fileRef: String) -> PBXObject? {
        proj.targets.first { $0.string("productReference") == fileRef }
    }

    /// `dstSubfolderSpec` of a copy-files phase → PIF destination subfolder.
    static func destinationSubfolder(spec: String?) -> String? {
        switch spec {
        case "0": "<absolute>"
        case "1": "$(WRAPPER_NAME)"
        case "6": "$(EXECUTABLE_FOLDER_PATH)"
        case "7": "$(UNLOCALIZED_RESOURCES_FOLDER_PATH)"
        case "10": "$(FRAMEWORKS_FOLDER_PATH)"
        case "11": "$(SHARED_FRAMEWORKS_FOLDER_PATH)"
        case "12": "$(SHARED_SUPPORT_FOLDER_PATH)"
        case "13": "$(PLUGINS_FOLDER_PATH)"
        case "15": "$(JAVA_FOLDER_PATH)"
        case "16": "<builtProductsDir>"
        default: nil
        }
    }

    func workspaceContents() -> JSONValue {
        .object([
            "guid": .string("WORKSPACE-\(proj.rootObject)"),
            "name": .string(xcodeprojURL.deletingPathExtension().lastPathComponent),
            "path": .string(xcodeprojURL.appendingPathComponent("project.xcworkspace/contents.xcworkspacedata").path),
            "projects": [.string(projectSignature())],
        ])
    }

    func projectContents(targets: [PBXObject]) throws -> JSONValue {
        guard let project = proj.project, let main = project.string("mainGroup") else { throw GenerationError.noMainGroup }
        let list = project.string("buildConfigurationList")
        return .object([
            "guid": .string(guid(proj.rootObject)),
            "path": .string(xcodeprojURL.path),
            "projectDirectory": .string(projectDirectory.path),
            "projectName": .string(xcodeprojURL.deletingPathExtension().lastPathComponent),
            "projectIsPackage": "false",
            "targets": .array(targets.map { .string(targetSignature($0.id)) }),
            "groupTree": reference(main),
            "buildConfigurations": .array(configurations(list)),
            "defaultConfigurationName": .string(proj[list ?? ""]?.string("defaultConfigurationName") ?? "Release"),
            "developmentRegion": .string(project.string("developmentRegion") ?? "en"),
            "knownRegions": .array((project["knownRegions"]?.array ?? []).compactMap { $0.string.map(JSONValue.string) }),
            "classPrefix": .string(project["attributes"]?.dictionary?["CLASSPREFIX"]?.string ?? ""),
        ])
    }

    /// A group or file reference, recursively. Paths and source trees are
    /// passed through; the root group is anchored at the project directory.
    func reference(_ id: String, isRoot: Bool = true) -> JSONValue {
        guard let obj = proj[id] else { return .null }
        var out: [String: JSONValue] = ["guid": .string(guid(id))]
        if isRoot {
            // The root group is relative to `projectDirectory` and is
            // named after the project.
            out["sourceTree"] = "<group>"
            out["path"] = ""
            out["name"] = .string(xcodeprojURL.deletingPathExtension().lastPathComponent)
        } else {
            out["sourceTree"] = .string(obj.string("sourceTree") ?? "<group>")
            out["path"] = .string(obj.string("path") ?? "")
        }
        if let n = obj.string("name") { out["name"] = .string(n) }
        switch obj.isa {
        case "PBXGroup", "PBXVariantGroup":
            out["type"] = obj.isa == "PBXGroup" ? "group" : "variantGroup"
            out["name"] = out["name"] ?? .string(obj.string("path").map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
            out["children"] = .array(obj.references("children").compactMap {
                let r = reference($0, isRoot: false)
                return r == .null ? nil : r
            })
        case "PBXFileReference":
            // Product references belong to their target in PIF, not to the
            // group tree.
            if productReferences.contains(id) { return .null }
            out["type"] = "file"
            out["fileType"] = .string(obj.string("lastKnownFileType") ?? obj.string("explicitFileType") ?? "file")
        default:
            return .null // synchronized folders etc. are not supported yet
        }
        return .object(out)
    }

    func configurations(_ listID: String?) -> [JSONValue] {
        proj.buildConfigurations(listID: listID).map { c in
            var settings: [String: JSONValue] = [:]
            for (k, v) in c["buildSettings"]?.dictionary ?? PlistDictionary() {
                if let s = v.string { settings[k] = .string(s) }
                else if let a = v.array { settings[k] = .array(a.compactMap { $0.string.map(JSONValue.string) }) }
            }
            var out: [String: JSONValue] = ["guid": .string(guid(c.id)), "name": .string(c.string("name") ?? ""),
                                            "buildSettings": .object(settings)]
            if let base = c.string("baseConfigurationReference") { out["baseConfigurationFileReference"] = .string(guid(base)) }
            return .object(out)
        }
    }

    func targetContents(_ t: PBXObject) throws -> JSONValue {
        let productType = t.string("productType") ?? ""
        var phases: [JSONValue] = []
        for pid in t.references("buildPhases") {
            guard let phase = proj[pid] else { continue }
            let type: String
            switch phase.isa {
            case "PBXSourcesBuildPhase": type = "com.apple.buildphase.sources"
            case "PBXFrameworksBuildPhase": type = "com.apple.buildphase.frameworks"
            case "PBXHeadersBuildPhase": type = "com.apple.buildphase.headers"
            case "PBXResourcesBuildPhase": type = "com.apple.buildphase.resources"
            case "PBXCopyFilesBuildPhase": type = "com.apple.buildphase.copy-files"
            default: throw GenerationError.unsupported("build phase \(phase.isa)")
            }
            let files: [JSONValue] = phase.references("files").compactMap { bf in
                guard let buildFile = proj[bf], let ref = buildFile.string("fileRef") else { return nil }
                var out: [String: JSONValue] = ["guid": .string(guid(bf))]
                // A product of another target is referenced through that target.
                if let producer = producingTarget(of: ref) {
                    out["targetReference"] = .string(guid(producer.id))
                } else {
                    out["fileReference"] = .string(guid(ref))
                }
                let attrs = buildFile["settings"]?.dictionary?["ATTRIBUTES"]?.array?.compactMap(\.string) ?? []
                if attrs.contains("CodeSignOnCopy") { out["codeSignOnCopy"] = "true" }
                if attrs.contains("RemoveHeadersOnCopy") { out["removeHeadersOnCopy"] = "true" }
                return .object(out)
            }
            var phaseObject: [String: JSONValue] = ["guid": .string(guid(pid)), "type": .string(type), "buildFiles": .array(files)]
            if phase.isa == "PBXCopyFilesBuildPhase" {
                guard let dest = Self.destinationSubfolder(spec: phase.string("dstSubfolderSpec")) else {
                    throw GenerationError.unsupported("copy-files destination \(phase.string("dstSubfolderSpec") ?? "?")")
                }
                phaseObject["destinationSubfolder"] = .string(dest)
                phaseObject["destinationSubpath"] = .string(phase.string("dstPath") ?? "")
                phaseObject["runOnlyForDeploymentPostprocessing"] = phase.string("runOnlyForDeploymentPostprocessing") == "1" ? "true" : "false"
            }
            phases.append(.object(phaseObject))
        }
        let productName = t.string("productReference").flatMap { proj[$0]?.string("path") } ?? (t.string("name") ?? "")
        return .object([
            "guid": .string(guid(t.id)),
            "name": .string(t.string("name") ?? ""),
            "type": "standard",
            "productTypeIdentifier": .string(productType),
            "productReference": .object(["guid": .string(guid(t.string("productReference") ?? t.id + "-product")),
                                         "name": .string(productName), "type": "product"]),
            "provisioningSourceData": .array(proj.buildConfigurations(listID: t.string("buildConfigurationList")).map { c in
                .object(["configurationName": .string(c.string("name") ?? ""), "provisioningStyle": .number(1),
                         "bundleIdentifierFromInfoPlist": ""])
            }),
            "buildPhases": .array(phases),
            "buildRules": [],
            "dependencies": .array(t.references("dependencies").compactMap { dep in
                // In-project dependencies name their target directly.
                guard let target = proj[dep]?.string("target") else { return nil }
                return .object(["guid": .string(guid(target))])
            }),
            "buildConfigurations": .array(configurations(t.string("buildConfigurationList"))),
        ])
    }
}

/// A minimal JSON value for writing PIF (YcodeBuild has no JSON type of
/// its own; this one keeps key order stable by sorting).
public indirect enum JSONValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    case null
    case bool(Bool)
    case number(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(stringLiteral v: String) { self = .string(v) }
    public init(arrayLiteral v: JSONValue...) { self = .array(v) }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }

    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): NSNumber(value: b)
        case .number(let n): NSNumber(value: n)
        case .string(let s): s
        case .array(let a): a.map(\.foundation)
        case .object(let o): o.mapValues(\.foundation)
        }
    }

    public func serialized(pretty: Bool = true) throws -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: foundation, options: opts)
    }
}
