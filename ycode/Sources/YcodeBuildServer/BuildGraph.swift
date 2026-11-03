import Foundation
import YcodeProject
import YcodeXcodebuild

/// A source language as sourcekit-lsp names it (LSP language identifiers).
public enum SourceLanguage: String, Sendable, CaseIterable {
    case swift
    case c
    case objectiveC = "objective-c"
    case cpp
    case objectiveCpp = "objective-cpp"

    /// The language of a compiled source file, by extension (nil for
    /// headers and files that are not compiled).
    public init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": self = .swift
        case "c": self = .c
        case "m": self = .objectiveC
        case "mm": self = .objectiveCpp
        case "cpp", "cc", "cxx", "c++", "cp": self = .cpp
        default: return nil
        }
    }

    public var isClangFamily: Bool { self != .swift }

    /// clang's `-x` value.
    public var clangInputType: String {
        switch self {
        case .swift: "swift"
        case .c: "c"
        case .objectiveC: "objective-c"
        case .cpp: "c++"
        case .objectiveCpp: "objective-c++"
        }
    }

    static func isHeader(_ path: String) -> Bool {
        ["h", "hh", "hpp", "hxx", "h++", "ipp", "pch"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// The targets of a project or workspace as the build server reports them:
/// each native target with its compiled sources, headers and target
/// dependencies. See `specs/ide/language.md` §Build server.
public struct BuildGraph: @unchecked Sendable {
    public struct SourceFile: Hashable, Sendable {
        public var path: String
        public var language: SourceLanguage
        /// Per-file compiler flags (`COMPILER_FLAGS` of the build file).
        public var flags: String?
    }

    public struct Header: Hashable, Sendable {
        public enum Visibility: String, Sendable { case `public`, `private`, project }
        public var path: String
        public var visibility: Visibility
    }

    public struct Target: @unchecked Sendable {
        /// The build target identifier (a URI).
        public var id: String
        public var name: String
        /// The `PBXNativeTarget` object identifier.
        public var objectID: String
        /// Index of the target's project in `BuildGraph.container.projects`.
        public var projectIndex: Int
        /// The target's `productType`.
        public var productType: String
        public var sources: [SourceFile]
        public var headers: [Header]
        /// Identifiers of the targets this one depends on, explicit and
        /// implicit (a linked or embedded product of another target).
        public var dependencies: [String]
        /// Swift package products the target uses (`packageProductDependencies`).
        public var packageProducts: [String]

        public var isTest: Bool { productType.hasPrefix("com.apple.product-type.bundle.") && productType.contains("test") }
        public var isApplication: Bool { productType.hasPrefix("com.apple.product-type.application") || productType == "com.apple.product-type.tool" }
        public var isFramework: Bool { productType.hasPrefix("com.apple.product-type.framework") }
        public var isLibrary: Bool { productType.hasPrefix("com.apple.product-type.library") || isFramework }
        public var hasSwift: Bool { sources.contains { $0.language == .swift } }
        public var hasClangSources: Bool { sources.contains { $0.language.isClangFamily } }
        /// Languages of the target's sources (headers count as the C family
        /// of its sources, or Objective-C).
        public var languages: [SourceLanguage] {
            var set = Set(sources.map(\.language))
            if !headers.isEmpty && !set.contains(where: \.isClangFamily) { set.insert(.objectiveC) }
            return SourceLanguage.allCases.filter(set.contains)
        }
    }

    public var container: Container
    public var targets: [Target]

    public func target(id: String) -> Target? { targets.first { $0.id == id } }

    /// The targets whose sources (or headers) include `path`.
    public func targets(containing path: String) -> [Target] {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return targets.filter { t in t.sources.contains { $0.path == p } || t.headers.contains { $0.path == p } }
    }

    public func project(of t: Target) -> LoadedProject { container.projects[t.projectIndex] }

    /// The target's dependencies, transitively, dependencies first (the
    /// target itself is not included).
    public func transitiveDependencies(of t: Target) -> [Target] {
        var out: [Target] = []
        var seen: Set<String> = [t.id]
        func visit(_ id: String) {
            guard seen.insert(id).inserted, let d = target(id: id) else { return }
            for dep in d.dependencies { visit(dep) }
            out.append(d)
        }
        for dep in t.dependencies { visit(dep) }
        return out
    }

    /// The identifier of a target: `ycode-target:<project path>/<object id>?name=<target name>`.
    public static func targetID(projectPath: String, objectID: String, name: String) -> String {
        var c = URLComponents()
        c.scheme = "ycode-target"
        c.path = projectPath + "/" + objectID
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url?.absoluteString ?? "ycode-target:\(objectID)"
    }

    // MARK: Loading

    public static func load(_ container: Container) -> BuildGraph {
        var targets: [Target] = []
        // Product file names of every native target, for implicit
        // dependencies through linked or embedded products.
        var byProductName: [String: String] = [:]
        var byObject: [String: String] = [:]
        for p in container.projects {
            for t in p.targets where t.isa == "PBXNativeTarget" {
                let id = targetID(projectPath: p.url.path, objectID: t.id, name: t.string("name") ?? "")
                byObject[p.url.standardizedFileURL.path + "#" + t.id] = id
                if let ref = t.string("productReference"), let name = p.proj[ref]?.string("path") {
                    byProductName[(name as NSString).lastPathComponent] = id
                }
            }
        }
        for (pi, p) in container.projects.enumerated() {
            let loader = TargetLoader(project: p, container: container, byObject: byObject, byProductName: byProductName)
            for t in p.targets where t.isa == "PBXNativeTarget" {
                targets.append(loader.load(t, projectIndex: pi))
            }
        }
        return BuildGraph(container: container, targets: targets)
    }

    /// Files whose change can change the graph or the settings: project
    /// files, workspace contents, xcconfig files and the folders of
    /// synchronized groups.
    public func watchedPaths() -> [String] {
        var out: [String] = []
        if container.kind == .workspace { out.append(container.url.appendingPathComponent("contents.xcworkspacedata").path) }
        for p in container.projects {
            out.append(p.url.appendingPathComponent("project.pbxproj").path)
            let parents = p.proj.parentMap()
            for o in p.proj.objects.values {
                if o.isa == "PBXFileReference", (o.string("path") ?? "").hasSuffix(".xcconfig"),
                   let path = p.proj.resolvedPath(of: o.id, projectDirectory: p.directory, parents: parents), path.hasPrefix("/") {
                    out.append(path)
                }
                if o.isa == "PBXFileSystemSynchronizedRootGroup",
                   let folder = p.proj.synchronizedFolder(o.id, projectDirectory: p.directory, parents: parents) {
                    out += TargetLoader.directories(of: folder)
                }
            }
        }
        return out
    }
}

/// Reads one project's native targets.
struct TargetLoader {
    var project: LoadedProject
    var container: Container
    var byObject: [String: String]
    var byProductName: [String: String]
    var parents: [String: String]
    var projectDirectory: URL

    init(project: LoadedProject, container: Container, byObject: [String: String], byProductName: [String: String]) {
        self.project = project
        self.container = container
        self.byObject = byObject
        self.byProductName = byProductName
        parents = project.proj.parentMap()
        projectDirectory = project.directory
    }

    var proj: PBXProj { project.proj }

    func path(of ref: String) -> String? {
        guard let p = proj.resolvedPath(of: ref, projectDirectory: projectDirectory, parents: parents), p.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: p).standardizedFileURL.path
    }

    func load(_ t: PBXObject, projectIndex: Int) -> BuildGraph.Target {
        var sources: [BuildGraph.SourceFile] = []
        var headers: [BuildGraph.Header] = []
        var deps: [String] = []
        func addDependency(_ id: String?) {
            if let id, !deps.contains(id), id != byObject[project.url.standardizedFileURL.path + "#" + t.id] { deps.append(id) }
        }

        for pid in t.references("buildPhases") {
            guard let phase = proj[pid] else { continue }
            for bf in phase.references("files") {
                guard let buildFile = proj[bf], let ref = buildFile.string("fileRef"), let fileRef = proj[ref] else { continue }
                switch phase.isa {
                case "PBXSourcesBuildPhase":
                    guard fileRef.isa == "PBXFileReference", let p = path(of: ref), let lang = SourceLanguage(path: p) else { continue }
                    let flags = buildFile["settings"]?.dictionary?["COMPILER_FLAGS"]?.string
                    sources.append(.init(path: p, language: lang, flags: flags?.isEmpty == false ? flags : nil))
                case "PBXHeadersBuildPhase":
                    guard let p = path(of: ref) else { continue }
                    let attrs = Set(buildFile["settings"]?.dictionary?["ATTRIBUTES"]?.array?.compactMap(\.string) ?? [])
                    headers.append(.init(path: p, visibility: attrs.contains("Public") ? .public : attrs.contains("Private") ? .private : .project))
                case "PBXFrameworksBuildPhase", "PBXCopyFilesBuildPhase":
                    addDependency(productTarget(ref, fileRef))
                default: break
                }
            }
        }

        // Synchronized folders: the members the build gets
        // (`PBXProj.synchronizedMembers`, shared with the PIF generator).
        for (folder, members) in proj.synchronizedMembers(ofTarget: t.id, projectDirectory: projectDirectory, parents: parents) {
            for m in members where m.entry.kind == .file {
                let full = folder.directory + "/" + m.entry.path
                switch m.phase {
                case .sources:
                    guard let lang = SourceLanguage(path: m.entry.path) else { continue }
                    sources.append(.init(path: full, language: lang, flags: m.compilerFlags?.isEmpty == false ? m.compilerFlags : nil))
                case .headers:
                    headers.append(.init(path: full, visibility: m.headerVisibility == .public ? .public : m.headerVisibility == .private ? .private : .project))
                default: break
                }
            }
            // Headers of a target without a Headers phase are in no phase,
            // but the index still needs their folders (project headers).
            for item in folder.items where item.kind == .file && SourceLanguage.isHeader(item.path)
                && !members.contains(where: { $0.entry.path == item.path && $0.phase == .headers })
                && proj.isSynchronizedMember(key: item.membershipKey, folder: folder.groupID, target: t.id) {
                headers.append(.init(path: folder.directory + "/" + item.path, visibility: .project))
            }
        }

        for did in t.references("dependencies") {
            guard let d = proj[did] else { continue }
            if let target = d.string("target") {
                addDependency(byObject[project.url.standardizedFileURL.path + "#" + target])
            } else if let proxy = d.string("targetProxy") {
                addDependency(proxyTarget(proxy))
            }
        }

        let name = t.string("name") ?? ""
        return BuildGraph.Target(
            id: BuildGraph.targetID(projectPath: project.url.path, objectID: t.id, name: name), name: name, objectID: t.id,
            projectIndex: projectIndex, productType: t.string("productType") ?? "", sources: sources, headers: headers,
            dependencies: deps, packageProducts: proj.packageProducts(ofTarget: t.id).map(\.name))
    }

    /// The target that produces a linked or embedded file: its product
    /// reference, a reference proxy to another project's target, or a
    /// product of the same file name.
    func productTarget(_ ref: String, _ fileRef: PBXObject) -> String? {
        if fileRef.isa == "PBXReferenceProxy", let remote = fileRef.string("remoteRef") { return proxyTarget(remote) }
        let selfPath = project.url.standardizedFileURL.path
        if let owner = proj.targets.first(where: { $0.string("productReference") == ref }) { return byObject[selfPath + "#" + owner.id] }
        guard let name = fileRef.string("path") else { return nil }
        return byProductName[(name as NSString).lastPathComponent]
    }

    /// The target a `PBXContainerItemProxy` names, in this project or in the
    /// project its container portal references.
    func proxyTarget(_ proxyID: String) -> String? {
        guard let proxy = proj[proxyID], let remote = proxy.string("remoteGlobalIDString") else { return nil }
        let portal = proxy.string("containerPortal") ?? ""
        if portal == proj.rootObject || proj[portal]?.isa == "PBXProject" {
            return byObject[project.url.standardizedFileURL.path + "#" + remote]
        }
        guard let other = path(of: portal) else { return nil }
        return byObject[URL(fileURLWithPath: other).standardizedFileURL.path + "#" + remote]
    }

    /// A synchronized folder and its sub-folders, `.lproj` folders
    /// included (their listings change when files are added or removed).
    static func directories(of folder: SynchronizedFolder) -> [String] {
        guard folder.exists else { return [folder.directory] }
        var out = [folder.directory]
        func walk(_ entries: [SynchronizedFolder.Entry]) {
            for e in entries {
                switch e.kind {
                case .group:
                    out.append(folder.directory + "/" + e.path)
                    walk(e.children)
                case .variantGroup:
                    for r in e.children {
                        let dir = folder.directory + "/" + (r.path as NSString).deletingLastPathComponent
                        if !out.contains(dir) { out.append(dir) }
                    }
                case .file: break
                }
            }
        }
        walk(folder.entries)
        return out
    }

    /// Walks a folder for recursive search paths (`dir/**`): hidden names
    /// and the contents of package-like folders left out.
    static func walk(_ dir: String, relative: String, depth: Int = 0, _ visit: (String, Bool) -> Void) {
        guard depth < 32 else { return }
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !SynchronizedFolder.isHidden(name) {
            let full = dir + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue && !SynchronizedFolder.isPackageLike(name) {
                visit(rel, true)
                walk(full, relative: rel, depth: depth + 1, visit)
            } else {
                visit(rel, false)
            }
        }
    }
}
