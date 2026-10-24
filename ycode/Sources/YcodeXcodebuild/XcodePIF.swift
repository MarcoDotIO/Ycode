import Foundation
import YcodeProject
import YcodePlist

/// Generates the PIF (Project Interchange Format) for a whole container, in
/// the shape the reference tool sends to swift-build. Unlike
/// `YcodeBuild.PIFGenerator` (which serves the IDE's build engine) it covers
/// every target kind, sub-projects, workspaces and synchronized folders, and
/// uses the reference tool's GUID scheme so that settings that embed GUIDs
/// (`PROJECT_GUID`, intermediate paths) come out the same.
/// See `specs/xcodebuild/show-build-settings.md` §3.
public struct XcodePIF {
    public let container: Container
    /// Things the PIF could not express (package products, unknown phases).
    public private(set) var notes: [String] = []

    public init(container: Container) { self.container = container }

    // MARK: GUIDs

    /// `md5(<workspace name>)`.
    public var workspaceGUID: String { MD5.hex(container.name) }

    /// `md5(<project path relative to the workspace's directory>)`.
    public func projectGUID(_ p: LoadedProject) -> String {
        MD5.hex(Self.relativePath(p.url.standardizedFileURL.path, from: container.baseDirectory.standardizedFileURL.path))
    }

    /// `<project GUID><md5(object id)>`.
    func guid(_ p: LoadedProject, _ id: String) -> String { projectGUID(p) + MD5.hex(id) }

    public func targetGUID(_ p: LoadedProject, _ target: PBXObject) -> String { guid(p, target.id) }

    static func relativePath(_ path: String, from base: String) -> String {
        let a = path.split(separator: "/").map(String.init)
        let b = base.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: b.count - i) + a[i...]).joined(separator: "/")
    }

    // MARK: Whole PIF

    public func objects() -> [[String: Any]] {
        var out: [[String: Any]] = []
        out.append(["signature": "WORKSPACE@" + workspaceGUID, "type": "workspace", "contents": [
            "guid": workspaceGUID,
            "name": container.name,
            "path": container.workspacePath.path,
            "projects": container.projects.map { "PROJECT@" + projectGUID($0) },
        ] as [String: Any]])
        for p in container.projects {
            var gen = ProjectPIF(pif: self, project: p)
            out.append(["signature": "PROJECT@" + projectGUID(p), "type": "project", "contents": gen.projectContents()])
            for t in p.targets {
                guard let contents = gen.targetContents(t) else { continue }
                out.append(["signature": "TARGET@" + guid(p, t.id), "type": "target", "contents": contents])
            }
        }
        return out
    }

    public func serialized() throws -> Data {
        try JSONSerialization.data(withJSONObject: objects(), options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// PIF for one project.
struct ProjectPIF {
    let pif: XcodePIF
    let project: LoadedProject
    var proj: PBXProj { project.proj }
    let parents: [String: String]
    /// Product reference id → target id.
    let productOwners: [String: String]
    /// Files found in synchronized folders, per root group id: (guid, relative path, file type).
    var synchronizedFiles: [String: [(guid: String, path: String, type: String)]] = [:]

    init(pif: XcodePIF, project: LoadedProject) {
        self.pif = pif
        self.project = project
        parents = project.proj.parentMap()
        var owners: [String: String] = [:]
        for t in project.proj.targets { if let r = t.string("productReference") { owners[r] = t.id } }
        productOwners = owners
    }

    func guid(_ id: String) -> String { pif.guid(project, id) }

    // MARK: Project

    mutating func projectContents() -> [String: Any] {
        let root = proj.project
        let list = root?.string("buildConfigurationList")
        var c: [String: Any] = [
            "guid": pif.projectGUID(project),
            "path": project.url.path,
            "projectDirectory": project.directory.path,
            "targets": proj.targets.filter { Self.targetKind($0) != nil }.map { "TARGET@" + guid($0.id) },
            "buildConfigurations": configurations(list),
            "defaultConfigurationName": project.defaultConfigurationName,
            "developmentRegion": root?.string("developmentRegion") ?? "en",
            "classPrefix": (root?["attributes"]?.dictionary?["CLASSPREFIX"]?.string) ?? "",
            "appPreferencesBuildSettings": [String: Any](),
        ]
        if let regions = root?["knownRegions"]?.array?.compactMap(\.string) { c["knownRegions"] = regions }
        if let main = root?.string("mainGroup"), let tree = reference(main, isRoot: true) { c["groupTree"] = tree }
        return c
    }

    func configurations(_ listID: String?) -> [[String: Any]] {
        proj.buildConfigurations(listID: listID).map { cfg in
            var settings: [String: Any] = [:]
            for (k, v) in cfg["buildSettings"]?.dictionary ?? PlistDictionary() {
                if let s = v.string { settings[k] = s } else if let a = v.array { settings[k] = a.compactMap(\.string) }
            }
            var out: [String: Any] = ["guid": guid(cfg.id), "name": cfg.string("name") ?? "", "buildSettings": settings]
            if let base = cfg.string("baseConfigurationReference") {
                out["baseConfigurationFileReference"] = guid(base)
            } else if let anchor = cfg.string("baseConfigurationReferenceAnchor"),
                      let rel = cfg.string("baseConfigurationReferenceRelativePath") {
                out["baseConfigurationFileReference"] = synchronizedGUID(anchor, rel)
            }
            return out
        }
    }

    // MARK: Group tree

    func synchronizedGUID(_ root: String, _ relative: String) -> String { guid(root + "/" + relative) }

    mutating func reference(_ id: String, isRoot: Bool = false) -> [String: Any]? {
        guard let obj = proj[id] else { return nil }
        var out: [String: Any] = ["guid": guid(id), "sourceTree": obj.string("sourceTree") ?? "<group>", "path": obj.string("path") ?? ""]
        switch obj.isa {
        case "PBXGroup", "PBXVariantGroup", "XCVersionGroup":
            out["type"] = obj.isa == "PBXGroup" ? "group" : obj.isa == "PBXVariantGroup" ? "variantGroup" : "versionGroup"
            out["name"] = obj.string("name") ?? obj.string("path").map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? (isRoot ? project.name : "")
            var children: [[String: Any]] = []
            for child in obj.references("children") {
                if var r = reference(child) {
                    if obj.isa == "PBXVariantGroup", let region = proj[child]?.string("name") { r["regionVariantName"] = region }
                    children.append(r)
                }
            }
            out["children"] = children
            if obj.isa == "XCVersionGroup" { out["fileType"] = obj.string("versionGroupType") ?? "wrapper.xcdatamodel" }
        case "PBXFileReference":
            if productOwners[id] != nil { return nil }
            out["type"] = "file"
            out["fileType"] = obj.string("lastKnownFileType") ?? obj.string("explicitFileType") ?? FileTypes.type(forPath: obj.string("path") ?? "")
            if let n = obj.string("name") { out["name"] = n }
            if obj.string("fileEncoding") == "4" || (out["fileType"] as? String)?.hasPrefix("sourcecode") == true
                || (out["fileType"] as? String)?.hasPrefix("text") == true {
                out["fileTextEncoding"] = "utf-8"
            }
        case "PBXFileSystemSynchronizedRootGroup":
            out["type"] = "group"
            out["name"] = obj.string("name") ?? obj.string("path") ?? ""
            let dir = proj.resolvedPath(of: id, projectDirectory: project.directory, parents: parents) ?? ""
            out["children"] = synchronizedChildren(root: id, directory: dir, relative: "")
        default:
            return nil // reference proxies and others live elsewhere
        }
        return out
    }

    /// Expands a synchronized folder from disk: directories become groups
    /// (bundle-like ones become files), files become file references.
    mutating func synchronizedChildren(root: String, directory: String, relative: String) -> [[String: Any]] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var out: [[String: Any]] = []
        for n in names {
            let full = directory + "/" + n
            let rel = relative.isEmpty ? n : relative + "/" + n
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            let type = FileTypes.type(forPath: n)
            if isDir.boolValue && !FileTypes.isBundleLike(n) {
                out.append(["guid": synchronizedGUID(root, rel), "type": "group", "name": n, "path": n, "sourceTree": "<group>",
                            "children": synchronizedChildren(root: root, directory: full, relative: rel)])
            } else {
                out.append(["guid": synchronizedGUID(root, rel), "type": "file", "path": n, "sourceTree": "<group>", "fileType": type])
                synchronizedFiles[root, default: []].append((synchronizedGUID(root, rel), rel, type))
            }
        }
        return out
    }

    // MARK: Targets

    static func targetKind(_ t: PBXObject) -> String? {
        switch t.isa {
        case "PBXNativeTarget": "standard"
        case "PBXAggregateTarget": "aggregate"
        case "PBXLegacyTarget": "external"
        default: nil
        }
    }

    mutating func targetContents(_ t: PBXObject) -> [String: Any]? {
        guard let kind = Self.targetKind(t) else { return nil }
        let name = t.string("name") ?? ""
        var c: [String: Any] = [
            "guid": guid(t.id), "name": name, "type": kind,
            "buildConfigurations": configurations(t.string("buildConfigurationList")),
            "dependencies": dependencies(t),
            "customTasks": [Any](),
        ]
        switch kind {
        case "external":
            c["toolPath"] = t.string("buildToolPath") ?? "/usr/bin/make"
            c["arguments"] = t.string("buildArgumentsString") ?? "$(ACTION)"
            c["workingDirectory"] = t.string("buildWorkingDirectory") ?? "$(PROJECT_DIR)"
            c["passBuildSettingsInEnvironment"] = (t.string("passBuildSettingsInEnvironment") ?? "1") == "1" ? "true" : "false"
            c["buildPhases"] = [Any]()
        case "aggregate":
            c["buildPhases"] = buildPhases(t)
        default:
            c["buildPhases"] = buildPhases(t)
            c["buildRules"] = buildRules(t)
            c["productTypeIdentifier"] = t.string("productType") ?? ""
            let productName = t.string("productReference").flatMap { proj[$0]?.string("path") } ?? name
            c["productReference"] = ["guid": guid(t.string("productReference") ?? (t.id + "-product")), "name": productName, "type": "product"]
            if let lang = predominantLanguage(t) { c["predominantSourceCodeLanguage"] = lang }
            c["provisioningSourceData"] = provisioningSourceData(t)
        }
        return c
    }

    func dependencies(_ t: PBXObject) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for d in t.references("dependencies") {
            guard let dep = proj[d] else { continue }
            if let target = dep.string("target"), proj[target] != nil {
                out.append(["guid": guid(target), "platformFilters": [Any]()])
            } else if let proxyID = dep.string("targetProxy"), let g = remoteTargetGUID(proxyID) {
                out.append(["guid": g, "platformFilters": [Any]()])
            }
        }
        return out
    }

    /// The GUID of the target a `PBXContainerItemProxy` names, in this
    /// project or a referenced one.
    func remoteTargetGUID(_ proxyID: String) -> String? {
        guard let proxy = proj[proxyID], let remote = proxy.string("remoteGlobalIDString"),
              let portal = proxy.string("containerPortal") else { return nil }
        if portal == proj.rootObject { return guid(remote) }
        guard let path = proj.resolvedPath(of: portal, projectDirectory: project.directory, parents: parents),
              let other = pif.container.projects.first(where: { $0.url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path })
        else { return nil }
        return pif.guid(other, remote)
    }

    static let phaseTypes: [String: String] = [
        "PBXSourcesBuildPhase": "com.apple.buildphase.sources",
        "PBXFrameworksBuildPhase": "com.apple.buildphase.frameworks",
        "PBXHeadersBuildPhase": "com.apple.buildphase.headers",
        "PBXResourcesBuildPhase": "com.apple.buildphase.resources",
        "PBXCopyFilesBuildPhase": "com.apple.buildphase.copy-files",
        "PBXShellScriptBuildPhase": "com.apple.buildphase.shell-script",
        "PBXRezBuildPhase": "com.apple.buildphase.rez",
        "PBXAppleScriptBuildPhase": "com.apple.buildphase.applescript",
    ]

    /// `dstSubfolderSpec` numbers (and newer `dstSubfolder` names).
    static let copyDestinations: [String: String] = [
        "0": "", "1": "$(WRAPPER_NAME)", "6": "$(EXECUTABLE_FOLDER_PATH)", "7": "$(UNLOCALIZED_RESOURCES_FOLDER_PATH)",
        "10": "$(FRAMEWORKS_FOLDER_PATH)", "11": "$(SHARED_FRAMEWORKS_FOLDER_PATH)", "12": "$(SHARED_SUPPORT_FOLDER_PATH)",
        "13": "$(PLUGINS_FOLDER_PATH)", "15": "$(JAVA_FOLDER_PATH)", "16": "<builtProductsDir>",
        "Absolute": "", "Wrapper": "$(WRAPPER_NAME)", "Executables": "$(EXECUTABLE_FOLDER_PATH)",
        "Resources": "$(UNLOCALIZED_RESOURCES_FOLDER_PATH)", "Frameworks": "$(FRAMEWORKS_FOLDER_PATH)",
        "SharedFrameworks": "$(SHARED_FRAMEWORKS_FOLDER_PATH)", "SharedSupport": "$(SHARED_SUPPORT_FOLDER_PATH)",
        "PlugIns": "$(PLUGINS_FOLDER_PATH)", "JavaResources": "$(JAVA_FOLDER_PATH)", "ProductsDirectory": "<builtProductsDir>",
    ]

    func buildPhases(_ t: PBXObject) -> [[String: Any]] {
        var phases: [[String: Any]] = []
        let synchronized = t.references("fileSystemSynchronizedGroups")
        for pid in t.references("buildPhases") {
            guard let phase = proj[pid], let type = Self.phaseTypes[phase.isa] else { continue }
            var files = phase.references("files").compactMap { buildFile($0, phaseISA: phase.isa) }
            // Members of synchronized folders join the phase their type
            // belongs to.
            if phase.isa == "PBXSourcesBuildPhase" || phase.isa == "PBXResourcesBuildPhase" {
                for root in synchronized {
                    let excluded = synchronizedExclusions(root: root, target: t.id)
                    for f in synchronizedFiles[root] ?? [] where !excluded.contains(f.path) {
                        let wanted = FileTypes.phase(forType: f.type, path: f.path)
                        if (wanted == "sources") == (phase.isa == "PBXSourcesBuildPhase") && wanted != nil {
                            files.append(["guid": guid(pid + "/" + root + "/" + f.path), "fileReference": f.guid,
                                          "codeSignOnCopy": "false", "removeHeadersOnCopy": "false", "platformFilters": [Any]()])
                        }
                    }
                }
            }
            var out: [String: Any] = ["guid": guid(pid), "type": type, "buildFiles": files]
            switch phase.isa {
            case "PBXCopyFilesBuildPhase":
                let spec = phase.string("dstSubfolder") ?? phase.string("dstSubfolderSpec") ?? "0"
                out["destinationSubfolder"] = Self.copyDestinations[spec] ?? ""
                out["destinationSubpath"] = phase.string("dstPath") ?? ""
                out["runOnlyForDeploymentPostprocessing"] = phase.string("runOnlyForDeploymentPostprocessing") == "1" ? "true" : "false"
            case "PBXShellScriptBuildPhase":
                out["name"] = phase.string("name") ?? "Run Script"
                out["shellPath"] = phase.string("shellPath") ?? "/bin/sh"
                out["scriptContents"] = phase.string("shellScript") ?? ""
                out["originalObjectID"] = pid
                for (k, src) in [("inputFilePaths", "inputPaths"), ("outputFilePaths", "outputPaths"),
                                 ("inputFileListPaths", "inputFileListPaths"), ("outputFileListPaths", "outputFileListPaths")] {
                    out[k] = phase.references(src)
                }
                out["emitEnvironment"] = phase.string("showEnvVarsInLog") == "0" ? "false" : "true"
                out["alwaysOutOfDate"] = phase.string("alwaysOutOfDate") == "1" ? "true" : "false"
                out["alwaysRunForInstallHdrs"] = "false"
                out["runOnlyForDeploymentPostprocessing"] = phase.string("runOnlyForDeploymentPostprocessing") == "1" ? "true" : "false"
                out["sandboxingOverride"] = "basedOnBuildSetting"
                if let dep = phase.string("dependencyFile") {
                    out["dependencyFileFormat"] = "makefile"
                    out["dependencyFilePaths"] = [dep]
                }
            default: break
            }
            phases.append(out)
        }
        return phases
    }

    /// Paths excluded from a target by `membershipExceptions`.
    func synchronizedExclusions(root: String, target: String) -> Set<String> {
        var out: Set<String> = []
        for ex in proj[root]?.references("exceptions") ?? [] {
            guard let e = proj[ex], e.string("target") == target || e.string("target") == nil else { continue }
            out.formUnion(e.references("membershipExceptions"))
        }
        return out
    }

    func buildFile(_ id: String, phaseISA: String) -> [String: Any]? {
        guard let bf = proj[id] else { return nil }
        var out: [String: Any] = ["guid": guid(id), "platformFilters": [Any]()]
        if let ref = bf.string("fileRef") {
            if let owner = productOwners[ref] {
                out["targetReference"] = guid(owner)
            } else if proj[ref]?.isa == "PBXReferenceProxy", let proxy = proj[ref]?.string("remoteRef"), let g = remoteTargetGUID(proxy) {
                out["targetReference"] = g
            } else {
                out["fileReference"] = guid(ref)
            }
        } else {
            return nil // package products are not expressed yet
        }
        let settings = bf["settings"]?.dictionary
        let attributes = Set(settings?["ATTRIBUTES"]?.array?.compactMap(\.string) ?? [])
        out["codeSignOnCopy"] = attributes.contains("CodeSignOnCopy") ? "true" : "false"
        out["removeHeadersOnCopy"] = attributes.contains("RemoveHeadersOnCopy") ? "true" : "false"
        if attributes.contains("Weak") { out["shouldLinkWeakly"] = "true" }
        if phaseISA == "PBXHeadersBuildPhase" {
            if attributes.contains("Public") { out["headerVisibility"] = "public" } else if attributes.contains("Private") { out["headerVisibility"] = "private" }
        }
        if let flags = settings?["COMPILER_FLAGS"]?.string, !flags.isEmpty { out["additionalCompilerOptions"] = flags }
        return out
    }

    func buildRules(_ t: PBXObject) -> [[String: Any]] {
        t.references("buildRules").compactMap { rid in
            guard let r = proj[rid] else { return nil }
            var out: [String: Any] = ["guid": guid(rid), "name": r.string("name") ?? "",
                                      "fileTypeIdentifier": r.string("fileType") ?? "pattern.proxy",
                                      "compilerSpecificationIdentifier": r.string("compilerSpec") ?? "com.apple.compilers.proxy.script"]
            if let p = r.string("filePatterns") { out["filePatterns"] = p }
            if let s = r.string("script") { out["scriptContents"] = s }
            out["inputFilePaths"] = r.references("inputFiles")
            out["outputFilePaths"] = r.references("outputFiles")
            out["outputFilesCompilerFlags"] = r.references("outputFilesCompilerFlags")
            out["runOncePerArchitecture"] = r.string("runOncePerArchitecture") == "0" ? "false" : "true"
            return out
        }
    }

    func predominantLanguage(_ t: PBXObject) -> String? {
        var counts: [String: Int] = [:]
        func count(_ type: String) {
            let lang: String? = switch type {
            case "sourcecode.swift": "Swift"
            case "sourcecode.c.c": "C"
            case "sourcecode.c.objc": "Objective-C"
            case "sourcecode.cpp.objcpp": "Objective-C-Plus-Plus"
            case "sourcecode.cpp.cpp": "C-Plus-Plus"
            default: nil
            }
            if let lang { counts[lang, default: 0] += 1 }
        }
        for pid in t.references("buildPhases") where proj[pid]?.isa == "PBXSourcesBuildPhase" {
            for bf in proj[pid]?.references("files") ?? [] {
                guard let ref = proj[bf]?.string("fileRef"), let f = proj[ref] else { continue }
                count(f.string("lastKnownFileType") ?? f.string("explicitFileType") ?? FileTypes.type(forPath: f.string("path") ?? ""))
            }
        }
        for root in t.references("fileSystemSynchronizedGroups") { for f in synchronizedFiles[root] ?? [] { count(f.type) } }
        guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else { return nil }
        return "Xcode.SourceCodeLanguage." + best.key
    }

    func provisioningSourceData(_ t: PBXObject) -> [[String: Any]] {
        let attrStyle = proj.project?["attributes"]?.dictionary?["TargetAttributes"]?.dictionary?[t.id]?.dictionary?["ProvisioningStyle"]?.string
        let projectConfigs = proj.buildConfigurations(listID: proj.project?.string("buildConfigurationList"))
        return proj.buildConfigurations(listID: t.string("buildConfigurationList")).map { cfg in
            let name = cfg.string("name") ?? ""
            let style = cfg["buildSettings"]?.dictionary?["CODE_SIGN_STYLE"]?.string
                ?? projectConfigs.first { $0.string("name") == name }?["buildSettings"]?.dictionary?["CODE_SIGN_STYLE"]?.string
                ?? attrStyle
            var bundleID = ""
            if let plist = cfg["buildSettings"]?.dictionary?["INFOPLIST_FILE"]?.string, !plist.contains("$") {
                let path = plist.hasPrefix("/") ? plist : project.directory.path + "/" + plist
                if let data = FileManager.default.contents(atPath: path),
                   let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    bundleID = d["CFBundleIdentifier"] as? String ?? ""
                }
            }
            return ["configurationName": name, "provisioningStyle": style == "Automatic" ? 0 : 1, "bundleIdentifierFromInfoPlist": bundleID]
        }
    }
}

/// File types by extension (for synchronized folders and untyped files).
enum FileTypes {
    static let byExtension: [String: String] = [
        "swift": "sourcecode.swift", "c": "sourcecode.c.c", "m": "sourcecode.c.objc", "mm": "sourcecode.cpp.objcpp",
        "cpp": "sourcecode.cpp.cpp", "cc": "sourcecode.cpp.cpp", "cxx": "sourcecode.cpp.cpp", "h": "sourcecode.c.h",
        "hpp": "sourcecode.cpp.h", "metal": "sourcecode.metal", "s": "sourcecode.asm", "xcassets": "folder.assetcatalog",
        "storyboard": "file.storyboard", "xib": "file.xib", "strings": "text.plist.strings", "xcstrings": "text.json.xcstrings",
        "plist": "text.plist.xml", "json": "text.json", "xcconfig": "text.xcconfig", "entitlements": "text.plist.entitlements",
        "png": "image.png", "jpg": "image.jpeg", "jpeg": "image.jpeg", "pdf": "image.pdf", "md": "net.daringfireball.markdown",
        "txt": "text", "xcdatamodeld": "wrapper.xcdatamodeld", "mlmodel": "file.mlmodel", "intentdefinition": "file.intentdefinition",
        "docc": "folder.documentationcatalog", "xctestplan": "text", "rcproject": "file.rcproject", "usdz": "file.usdz",
        "lproj": "folder", "bundle": "wrapper.plug-in", "framework": "wrapper.framework", "a": "archive.ar", "dylib": "compiled.mach-o.dylib",
        "modulemap": "sourcecode.module-map", "y": "sourcecode.yacc", "l": "sourcecode.lex", "mig": "sourcecode.mig", "defs": "sourcecode.mig",
    ]

    static func type(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? "file"
    }

    static func isBundleLike(_ name: String) -> Bool {
        ["xcassets", "xcdatamodeld", "bundle", "framework", "docc", "rcproject", "app", "appex", "xcframework", "scnassets", "lproj"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    /// The phase a synchronized-folder file belongs to: "sources",
    /// "resources" or nil (not built).
    static func phase(forType type: String, path: String) -> String? {
        if type.hasPrefix("sourcecode.") {
            return type.hasSuffix(".h") || type == "sourcecode.module-map" ? nil : "sources"
        }
        switch type {
        case "wrapper.xcdatamodeld", "file.mlmodel", "file.intentdefinition", "folder.documentationcatalog": return "sources"
        case "text.xcconfig", "text.plist.entitlements": return nil
        case "text.plist.xml" where (path as NSString).lastPathComponent == "Info.plist": return nil
        case "text.xctestplan": return nil
        default: return path.hasSuffix(".xctestplan") ? nil : "resources"
        }
    }
}
