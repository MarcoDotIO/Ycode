import Foundation
import YcodeProject
import YcodePlist
import YcodeBuild

/// Generates the PIF (Project Interchange Format) for a whole container, in
/// the shape the reference tool sends to swift-build. Unlike
/// `YcodeBuild.PIFGenerator` (which serves the IDE's build engine) it covers
/// every target kind, sub-projects, workspaces and synchronized folders, and
/// uses the reference tool's GUID scheme so that settings that embed GUIDs
/// (`PROJECT_GUID`, intermediate paths) come out the same.
/// See `specs/xcodebuild/show-build-settings.md` §3.
public struct XcodePIF {
    public let container: Container
    /// The container's Swift packages (`PackageGraphLoader`). Without them
    /// build files and dependencies naming package products are left out.
    public var packages: PackageGraphPIF?
    /// Things the PIF could not express (package products, unknown phases).
    public private(set) var notes: [String] = []

    public init(container: Container, packages: PackageGraphPIF? = nil) {
        self.container = container
        self.packages = packages
    }

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

    /// The package products a project target links, as its PIF target's
    /// dependencies name them (no build-tool plug-ins; products missing from
    /// the package graph are left out). The build server uses them.
    public func packageProducts(_ p: LoadedProject, _ target: PBXObject) -> [PackageGraphPIF.Product] {
        let project = ProjectPIF(pif: self, project: p)
        return target.references("packageProductDependencies").compactMap(project.packageProduct)
    }

    static func relativePath(_ path: String, from base: String) -> String {
        let a = path.split(separator: "/").map(String.init)
        let b = base.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: b.count - i) + a[i...]).joined(separator: "/")
    }

    // MARK: Whole PIF

    /// Signatures carry a hash of the object's contents
    /// (`<KIND>@<guid>_hash=<md5>`): swift-build keeps build descriptions by
    /// the signatures of the objects they come from, so an edited target, or
    /// a project whose packages changed, must not keep its old signature.
    static func signature(_ kind: String, _ guid: String, _ contents: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return kind + "@" + guid + "_hash=" + MD5.hex(String(decoding: data, as: UTF8.self))
    }

    public func objects() -> [[String: Any]] {
        var projects: [[String: Any]] = []
        for p in container.projects {
            let gen = ProjectPIF(pif: self, project: p)
            var project = gen.projectContents()
            var targets: [[String: Any]] = []
            for t in p.targets {
                guard let contents = gen.targetContents(t) else { continue }
                targets.append(["signature": Self.signature("TARGET", guid(p, t.id), contents), "type": "target", "contents": contents])
            }
            project["targets"] = targets.compactMap { $0["signature"] as? String }
            projects.append(["signature": Self.signature("PROJECT", projectGUID(p), project), "type": "project", "contents": project])
            projects += targets
        }
        let workspace: [String: Any] = [
            "guid": workspaceGUID,
            "name": container.name,
            "path": container.workspacePath.path,
            "projects": projects.filter { $0["type"] as? String == "project" }.compactMap { $0["signature"] as? String }
                + (packages?.projectSignatures ?? []),
        ]
        // The package projects and their targets (SwiftPM's PIF) follow.
        return [["signature": Self.signature("WORKSPACE", workspaceGUID, workspace), "type": "workspace", "contents": workspace]]
            + projects + (packages?.objects ?? [])
    }

    /// Warnings about the synchronized folders of the named targets (all
    /// targets when nil): missing folders, and targets that compile no
    /// source file although they take files from synchronized folders.
    public func synchronizedFolderWarnings(targetNames: [String]? = nil) -> [String] {
        container.projects.flatMap { p in
            let gen = ProjectPIF(pif: self, project: p)
            return p.targets.filter { t in targetNames.map { $0.contains(t.string("name") ?? "") } ?? true }.flatMap(gen.synchronizedWarnings)
        }
    }

    /// The synchronized-folder warnings of one target.
    public func synchronizedFolderWarnings(_ p: LoadedProject, _ target: PBXObject) -> [String] {
        ProjectPIF(pif: self, project: p).synchronizedWarnings(target)
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
    /// The project's synchronized folders read from disk, by root group id.
    let synchronizedFolders: [String: SynchronizedFolder]

    init(pif: XcodePIF, project: LoadedProject) {
        self.pif = pif
        self.project = project
        parents = project.proj.parentMap()
        var owners: [String: String] = [:]
        for t in project.proj.targets { if let r = t.string("productReference") { owners[r] = t.id } }
        productOwners = owners
        var folders: [String: SynchronizedFolder] = [:]
        for g in project.proj.objects(isa: "PBXFileSystemSynchronizedRootGroup") {
            if let f = project.proj.synchronizedFolder(g.id, projectDirectory: project.directory, parents: parents) { folders[g.id] = f }
        }
        synchronizedFolders = folders
    }

    func guid(_ id: String) -> String { pif.guid(project, id) }

    // MARK: Project

    func projectContents() -> [String: Any] {
        let root = proj.project
        let list = root?.string("buildConfigurationList")
        var c: [String: Any] = [
            "guid": pif.projectGUID(project),
            "path": project.url.path,
            "projectDirectory": project.directory.path,
            // Filled in with the targets' signatures by `XcodePIF.objects()`.
            "targets": [String](),
            "buildConfigurations": configurations(list),
            "defaultConfigurationName": project.defaultConfigurationName,
            "developmentRegion": root?.string("developmentRegion") ?? "en",
            "classPrefix": (root?["attributes"]?.dictionary?["CLASSPREFIX"]?.string) ?? "",
            "appPreferencesBuildSettings": [String: Any](),
        ]
        if let regions = root?["knownRegions"]?.array?.compactMap(\.string) { c["knownRegions"] = regions }
        if let main = root?.string("mainGroup"), var tree = reference(main, isRoot: true) {
            if let generated = pluginOutputGroup() { tree["children"] = (tree["children"] as? [[String: Any]] ?? []) + [generated] }
            c["groupTree"] = tree
        }
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

    func reference(_ id: String, isRoot: Bool = false) -> [String: Any]? {
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
            out["children"] = (synchronizedFolders[id]?.entries ?? []).map { synchronizedReference(root: id, $0) }
        default:
            return nil // reference proxies and others live elsewhere
        }
        return out
    }

    /// GUID of a synchronized item (file, folder, variant group) by its
    /// membership key.
    func synchronizedItemGUID(_ root: String, _ e: SynchronizedFolder.Entry) -> String { synchronizedGUID(root, e.membershipKey) }

    /// A synchronized folder's row in the group tree: sub-folders become
    /// groups, `.lproj` files variant groups, everything else files.
    func synchronizedReference(root: String, _ e: SynchronizedFolder.Entry) -> [String: Any] {
        switch e.kind {
        case .group:
            return ["guid": synchronizedGUID(root, e.path), "type": "group", "name": e.name, "path": e.name, "sourceTree": "<group>",
                    "children": e.children.map { synchronizedReference(root: root, $0) }]
        case .variantGroup:
            // The region files sit in `<region>.lproj` folders next to the
            // localized item, so the variant group adds no path of its own.
            return ["guid": synchronizedItemGUID(root, e), "type": "variantGroup", "name": e.name, "path": "", "sourceTree": "<group>",
                    "children": e.children.map { r -> [String: Any] in
                        var f: [String: Any] = ["guid": synchronizedGUID(root, r.path), "type": "file",
                                                "path": (r.region ?? "") + ".lproj/" + e.name, "sourceTree": "<group>",
                                                "fileType": r.fileType, "regionVariantName": r.region ?? ""]
                        if r.fileType.hasPrefix("text") { f["fileTextEncoding"] = "utf-8" }
                        return f
                    }]
        case .file:
            var out: [String: Any] = ["guid": synchronizedGUID(root, e.path), "type": "file", "path": e.name, "sourceTree": "<group>",
                                      "fileType": e.fileType]
            if e.fileType.hasPrefix("sourcecode") || e.fileType.hasPrefix("text") { out["fileTextEncoding"] = "utf-8" }
            return out
        }
    }

    /// The synchronized members of a target, folder by folder.
    func synchronizedMembers(_ t: PBXObject) -> [SynchronizedMember] {
        guard t.isa == "PBXNativeTarget" else { return [] }
        return proj.synchronizedFolderIDs(ofTarget: t.id).compactMap { synchronizedFolders[$0] }
            .flatMap { proj.synchronizedMembers(ofTarget: t.id, folder: $0) }
    }

    /// PIF platform filters for pbxproj platform names (`ios`,
    /// `maccatalyst`, `macos`, …).
    static func platformFilters(_ names: [String]) -> [[String: Any]] {
        names.map { n in n == "maccatalyst" ? ["platform": "ios", "environment": "macabi"] : ["platform": n] }
    }

    /// The build file of a synchronized member in phase `pid`.
    func synchronizedBuildFile(_ m: SynchronizedMember, phase pid: String) -> [String: Any] {
        let attributes = Set(m.attributes)
        var out: [String: Any] = ["guid": guid(pid + "/" + m.folder + "/" + m.entry.membershipKey),
                                  "fileReference": synchronizedItemGUID(m.folder, m.entry),
                                  "codeSignOnCopy": attributes.contains("CodeSignOnCopy") ? "true" : "false",
                                  "removeHeadersOnCopy": attributes.contains("RemoveHeadersOnCopy") ? "true" : "false",
                                  "platformFilters": Self.platformFilters(m.platformFilters)]
        if attributes.contains("Weak") { out["shouldLinkWeakly"] = "true" }
        if let v = m.headerVisibility { out["headerVisibility"] = v.rawValue }
        if let f = m.compilerFlags, !f.isEmpty { out["additionalCompilerOptions"] = f }
        return out
    }

    /// Warnings about a target's synchronized folders: a folder that is
    /// not on disk, and a target that compiles no source file although it
    /// takes its files from synchronized folders (Ycode decision,
    /// `build-pif.md` §Synchronized folders).
    func synchronizedWarnings(_ t: PBXObject) -> [String] {
        guard t.isa == "PBXNativeTarget" else { return [] }
        let ids = proj.synchronizedFolderIDs(ofTarget: t.id)
        guard !ids.isEmpty else { return [] }
        let name = t.string("name") ?? t.id
        func folderName(_ id: String) -> String { proj[id]?.string("name") ?? proj[id]?.string("path") ?? id }
        var out: [String] = []
        for id in ids where synchronizedFolders[id]?.exists != true {
            let path = synchronizedFolders[id]?.directory
                ?? proj.resolvedPath(of: id, projectDirectory: project.directory, parents: parents) ?? folderName(id)
            out.append("The synchronized folder \u{201C}\(folderName(id))\u{201D} of target \u{201C}\(name)\u{201D} is missing (\(path)); the target gets no files from it.")
        }
        // Resource bundles need no code.
        guard t.string("productType") != "com.apple.product-type.bundle" else { return out }
        let ownSources = t.references("buildPhases").filter { proj[$0]?.isa == "PBXSourcesBuildPhase" }
            .contains { !(proj[$0]?.references("files").isEmpty ?? true) }
        let synchronizedSources = synchronizedMembers(t).contains { $0.phase == .sources }
        let generated = !(pluginOutputs(t)?.generatedSources.isEmpty ?? true)
        if !ownSources && !synchronizedSources && !generated {
            let folders = ids.map { "\u{201C}\(folderName($0))\u{201D}" }.joined(separator: ", ")
            out.append("Target \u{201C}\(name)\u{201D} compiles no source files: its synchronized folders (\(folders)) hold none that it builds.")
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

    func targetContents(_ t: PBXObject) -> [String: Any]? {
        guard let kind = Self.targetKind(t) else { return nil }
        let name = t.string("name") ?? ""
        var c: [String: Any] = [
            "guid": guid(t.id), "name": name, "type": kind,
            "buildConfigurations": configurations(t.string("buildConfigurationList")),
            "dependencies": dependencies(t),
            "customTasks": pluginCustomTasks(t),
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
        // Package products the target uses are explicit dependencies: swift-build
        // builds them for the target's platform (package targets take part in no
        // implicit dependencies).
        for p in t.references("packageProductDependencies") {
            guard let product = packageProduct(p), !out.contains(where: { $0["guid"] as? String == product.guid }) else { continue }
            out.append(["guid": product.guid, "platformFilters": [Any]()])
        }
        // Build-tool plug-ins: their PIF targets build the tools for the host.
        for g in pluginOutputs(t)?.pluginTargetGUIDs ?? [] where !out.contains(where: { $0["guid"] as? String == g }) {
            out.append(["guid": g, "platformFilters": [Any]()])
        }
        return out
    }

    // MARK: Build-tool plug-ins

    func pluginOutputs(_ t: PBXObject) -> ProjectPlugins.TargetOutputs? {
        pif.packages?.pluginOutputs[ProjectPlugins.key(project, t.id)]
    }

    /// The plug-ins' build commands as custom tasks (host tools at the
    /// client build's products folder).
    func pluginCustomTasks(_ t: PBXObject) -> [[String: Any]] {
        guard let outputs = pluginOutputs(t), let graph = pif.packages else { return [] }
        return outputs.commands.map { c in
            var task: [String: Any] = [
                "commandLine": ([c.executable] + c.arguments).map(graph.relocated),
                "environment": c.environment.sorted { $0.key < $1.key }.map { [$0.key, graph.relocated($0.value)] },
                "executionDescription": c.displayName ?? "Performing build tool plug-in command",
                "inputFilePaths": ([c.executable] + c.inputFiles).map(graph.relocated),
                "outputFilePaths": c.outputFiles,
                "enableSandboxing": "false",
                "preparesForIndexing": "true",
            ]
            if let w = c.workingDirectory { task["workingDirectory"] = w }
            return task
        }
    }

    /// GUID of the file reference of a plug-in's generated file.
    func generatedFileGUID(_ path: String) -> String { guid("ycode-plugin-output:" + path) }

    /// A group holding the files plug-ins generate for this project's
    /// targets (absolute paths); nil when there are none.
    func pluginOutputGroup() -> [String: Any]? {
        var files: [String] = []
        for t in proj.targets {
            guard let o = pluginOutputs(t) else { continue }
            for f in o.generatedSources + o.generatedResources where !files.contains(f) { files.append(f) }
        }
        guard !files.isEmpty else { return nil }
        return ["guid": guid("ycode-plugin-outputs"), "type": "group", "name": "Plug-in Outputs", "path": "", "sourceTree": "<absolute>",
                "children": files.map { f -> [String: Any] in
                    ["guid": generatedFileGUID(f), "type": "file", "path": f, "sourceTree": "<absolute>",
                     "fileType": FileTypes.type(forPath: f)]
                }]
    }

    // MARK: Package products

    /// The package product an `XCSwiftPackageProductDependency` names: its
    /// `package` reference gives the package identity (a local folder's
    /// name, or the repository's last URL component), else any package with
    /// a product of that name. Nil for build-tool plug-ins (`plugin:`
    /// names) and when the product is not in the package graph.
    func packageProduct(_ id: String) -> PackageGraphPIF.Product? {
        guard let graph = pif.packages, let dep = proj[id], dep.isa == "XCSwiftPackageProductDependency",
              let name = dep.string("productName"), !name.hasPrefix("plugin:") else { return nil }
        var identity: String?
        if let ref = dep.string("package").flatMap({ proj[$0] }) {
            if ref.isa == "XCLocalSwiftPackageReference", let rel = ref.string("relativePath") {
                identity = URL(fileURLWithPath: rel).lastPathComponent.lowercased()
            } else if let url = ref.string("repositoryURL") {
                identity = PackageResolver.identity(of: url)
            }
        }
        if let identity, let p = graph.product(name, identity: identity) { return p }
        return graph.product(name, identity: nil)
    }

    /// Whether a target is an application, whose bundle gets the dynamic
    /// package products it links.
    static func embedsPackageProducts(_ t: PBXObject) -> Bool {
        (t.string("productType") ?? "").hasPrefix("com.apple.product-type.application")
    }

    /// A copy-files phase that embeds the dynamic package products an
    /// application links but no copy-files phase of its own copies (Ycode
    /// decision, `build-pif.md` §Package products); nil when there are none.
    func packageEmbedPhase(_ t: PBXObject, phases: [[String: Any]]) -> [String: Any]? {
        guard Self.embedsPackageProducts(t), let dynamic = pif.packages?.dynamicProductGUIDs, !dynamic.isEmpty else { return nil }
        func references(_ type: String) -> [String] {
            phases.filter { $0["type"] as? String == type }
                .flatMap { ($0["buildFiles"] as? [[String: Any]] ?? []).compactMap { $0["targetReference"] as? String } }
        }
        let copied = Set(references("com.apple.buildphase.copy-files"))
        var embed: [String] = []
        for g in references("com.apple.buildphase.frameworks") where dynamic.contains(g) && !copied.contains(g) && !embed.contains(g) {
            embed.append(g)
        }
        guard !embed.isEmpty else { return nil }
        let phase = t.id + "-ycode-embed-package-products"
        return ["guid": guid(phase), "type": "com.apple.buildphase.copy-files",
                "destinationSubfolder": "$(FRAMEWORKS_FOLDER_PATH)", "destinationSubpath": "",
                "runOnlyForDeploymentPostprocessing": "false",
                "buildFiles": embed.map { g -> [String: Any] in
                    ["guid": guid(phase + "/" + g), "targetReference": g, "codeSignOnCopy": "true",
                     "removeHeadersOnCopy": "true", "platformFilters": [Any]()]
                }]
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
        let phaseIDs = t.references("buildPhases")
        let members = synchronizedMembers(t)
        // Default phases a synchronized member needs but the target lacks
        // are added after its own (Ycode decision, `build-pif.md`).
        var placed = Set<Int>()
        func membersFor(_ pid: String, isa: String) -> [[String: Any]] {
            let firstOfKind = phaseIDs.first { proj[$0]?.isa == isa } == pid
            var out: [[String: Any]] = []
            for (i, m) in members.enumerated() {
                let matches = m.phase == .buildPhase(pid) || (firstOfKind && m.phase.isa == isa)
                if matches { out.append(synchronizedBuildFile(m, phase: pid)); placed.insert(i) }
            }
            return out
        }
        for pid in phaseIDs {
            guard let phase = proj[pid], let type = Self.phaseTypes[phase.isa] else { continue }
            var files = phase.references("files").compactMap { buildFile($0, phaseISA: phase.isa) }
            // Members of synchronized folders join the phase their type
            // belongs to, or the phase an exception set names.
            files += membersFor(pid, isa: phase.isa)
            // Files build-tool plug-ins generate.
            if let o = pluginOutputs(t), phase.isa == "PBXSourcesBuildPhase" || phase.isa == "PBXResourcesBuildPhase" {
                for f in phase.isa == "PBXSourcesBuildPhase" ? o.generatedSources : o.generatedResources {
                    files.append(["guid": guid(pid + "/ycode-plugin-output:" + f), "fileReference": generatedFileGUID(f),
                                  "codeSignOnCopy": "false", "removeHeadersOnCopy": "false", "platformFilters": [Any]()])
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
        // Products that are no bundle take no resources.
        let unbundled = ["com.apple.product-type.tool", "com.apple.product-type.library.static", "com.apple.product-type.library.dynamic",
                         "com.apple.product-type.tool.host-build"].contains(t.string("productType") ?? "")
        for kind in [SynchronizedMember.Phase.headers, .sources, .frameworks, .resources] where !(kind == .resources && unbundled) {
            guard let isa = kind.isa, let type = Self.phaseTypes[isa] else { continue }
            let files = members.enumerated().filter { !placed.contains($0.offset) && $0.element.phase == kind }
            guard !files.isEmpty else { continue }
            let pid = t.id + "-ycode-synchronized-" + type
            phases.append(["guid": guid(pid), "type": type, "buildFiles": files.map { synchronizedBuildFile($0.element, phase: pid) }])
        }
        if let embed = packageEmbedPhase(t, phases: phases) { phases.append(embed) }
        return phases
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
        } else if let ref = bf.string("productRef"), let product = packageProduct(ref) {
            out["targetReference"] = product.guid
        } else {
            return nil // a package product outside the package graph (or none loaded)
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
        for m in synchronizedMembers(t) where m.phase == .sources { count(m.entry.fileType) }
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
typealias FileTypes = BuildFileTypes
