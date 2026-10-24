import Foundation
import YcodeProject
import YcodeWorkspace

/// A loaded project, with its file location.
public struct LoadedProject: @unchecked Sendable {
    public var url: URL
    public var proj: PBXProj
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var directory: URL { proj.projectDirectory(xcodeprojURL: url) }

    public var targets: [PBXObject] { proj.targets }
    public var targetNames: [String] { proj.targets.compactMap { $0.string("name") } }
    public var configurationNames: [String] {
        proj.buildConfigurations(listID: proj.project?.string("buildConfigurationList")).compactMap { $0.string("name") }
    }
    public var defaultConfigurationName: String {
        proj[proj.project?.string("buildConfigurationList") ?? ""]?.string("defaultConfigurationName")
            ?? configurationNames.last ?? "Release"
    }

    public func target(named n: String) -> PBXObject? { proj.targets.first { $0.string("name") == n } }

    /// True if the project's `TargetAttributes` give the target a
    /// `TestTargetID` (the target its tests run in).
    public func hasTestHost(_ t: PBXObject) -> Bool {
        proj.project?["attributes"]?.dictionary?["TargetAttributes"]?.dictionary?[t.id]?.dictionary?["TestTargetID"] != nil
    }

    /// Projects referenced from this one (`projectReferences`), absolute.
    public var subprojectURLs: [URL] {
        let dir = directory
        let parents = proj.parentMap()
        return (proj.project?["projectReferences"]?.array ?? []).compactMap { ref in
            guard let id = ref.dictionary?["ProjectRef"]?.string,
                  let p = proj.resolvedPath(of: id, projectDirectory: dir, parents: parents), p.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: p)
        }
    }
}

/// The project or workspace a command works on.
public struct Container: @unchecked Sendable {
    public enum Kind: Sendable { case project, workspace }
    public var kind: Kind
    /// Absolute path of the `.xcodeproj` or `.xcworkspace`.
    public var url: URL
    public var name: String { displayName ?? url.deletingPathExtension().lastPathComponent }
    /// The projects, in workspace order (for a project: itself first, then
    /// the projects it references, recursively).
    public var projects: [LoadedProject]
    /// A name other than the bundle's (a Swift package's own name).
    public var displayName: String? = nil

    /// The workspace PIF path: `X.xcworkspace`, or the implicit
    /// `X.xcodeproj/project.xcworkspace`.
    public var workspacePath: URL { kind == .workspace ? url : url.appendingPathComponent("project.xcworkspace") }
    /// The directory project paths are relative to (for PIF GUIDs).
    public var baseDirectory: URL { url.deletingLastPathComponent() }

    public var mainProject: LoadedProject? { kind == .project ? projects.first : nil }

    /// Schemes visible in this container (see info-commands.md §2).
    public func schemes(user: String = NSUserName()) -> [Scheme] {
        var bundles: [URL] = []
        if kind == .workspace { bundles.append(url) }
        bundles += projects.map(\.url)
        var seen = Set<String>()
        var out: [Scheme] = []
        for (i, b) in bundles.enumerated() {
            var found = Scheme.discover(in: b, user: user)
            // A project without any scheme files gets one generated scheme
            // per target, test bundles excepted.
            if found.isEmpty, let p = projects.first(where: { $0.url == b }), kind == .workspace || i == 0 {
                found = p.targets.compactMap { t -> Scheme? in
                    // A test bundle hosted by another target belongs to
                    // that target's scheme.
                    guard t.string("name") != nil, !(Self.isTestBundle(t) && p.hasTestHost(t)) else { return nil }
                    return AutocreatedScheme.make(for: t, in: p, containerName: b.lastPathComponent)
                }
            }
            for s in found where seen.insert(s.name).inserted { out.append(s) }
        }
        // Local Swift packages referenced by the projects add their schemes.
        for p in projects {
            for pkg in LocalPackages.find(in: p) {
                for name in pkg.schemeNames where seen.insert(name).inserted {
                    let ref = Scheme.BuildableReference(blueprintIdentifier: name, buildableName: name, blueprintName: name,
                                                        referencedContainer: "container:\(pkg.directory)")
                    var scheme = Scheme.autocreated(for: ref, isTestBundle: false, isRunnable: false)
                    scheme.name = name
                    out.append(scheme)
                }
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isTestBundle(_ t: PBXObject) -> Bool {
        ["com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing"].contains(t.string("productType") ?? "")
    }

    /// Finds the project that contains a scheme's buildable reference.
    public func project(for ref: Scheme.BuildableReference, schemeBundle: URL?) -> LoadedProject? {
        let c = ref.referencedContainer
        if c.hasPrefix("container:") {
            let rel = String(c.dropFirst("container:".count))
            let base = schemeBundle.map { b -> URL in
                // Container paths are relative to the directory holding the
                // project or workspace bundle the scheme lives in.
                let bundle = b.path.components(separatedBy: "/xcshareddata/").first.map { URL(fileURLWithPath: $0) }
                    ?? b.path.components(separatedBy: "/xcuserdata/").first.map { URL(fileURLWithPath: $0) } ?? b
                return bundle.deletingLastPathComponent()
            } ?? baseDirectory
            let target = base.appendingPathComponent(rel).standardizedFileURL.path
            if let p = projects.first(where: { $0.url.standardizedFileURL.path == target }) { return p }
            if let p = projects.first(where: { $0.url.lastPathComponent == URL(fileURLWithPath: rel).lastPathComponent }) { return p }
        }
        return projects.first { $0.proj.objects[ref.blueprintIdentifier] != nil }
    }
}

enum ContainerLocator {
    /// Opens the container named by `-project`/`-workspace`, or found in `cwd`.
    static func open(_ inv: Invocation, cwd: String) throws(XcodebuildFailure) -> Container {
        func absolute(_ p: String) -> URL {
            URL(fileURLWithPath: p.hasPrefix("/") ? p : cwd + "/" + p).standardizedFileURL
        }
        let fm = FileManager.default
        if let p = inv.project {
            let url = absolute(p)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw XcodebuildFailure("'\(p)' does not exist.", exitCode: ExitCode.noInput)
            }
            guard isDir.boolValue, url.pathExtension == "xcodeproj",
                  fm.fileExists(atPath: url.appendingPathComponent("project.pbxproj").path) else {
                throw XcodebuildFailure("'\(url.path)' is not a project file.", exitCode: ExitCode.noInput)
            }
            return try loadProjectContainer(url)
        }
        if let w = inv.workspace {
            let url = absolute(w)
            guard fm.fileExists(atPath: url.path) else {
                throw XcodebuildFailure("'\(w)' does not exist.", exitCode: ExitCode.noInput)
            }
            return try loadWorkspace(url)
        }
        let entries = ((try? fm.contentsOfDirectory(atPath: cwd)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }
        let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }
        if workspaces.count == 1, inv.scheme != nil || (projects.isEmpty && inv.has("-list")) {
            return try loadWorkspace(URL(fileURLWithPath: cwd + "/" + workspaces[0]).standardizedFileURL)
        }
        if projects.count == 1 {
            return try loadProjectContainer(URL(fileURLWithPath: cwd + "/" + projects[0]).standardizedFileURL)
        }
        if projects.count > 1 {
            throw XcodebuildFailure("The directory \(cwd) contains \(projects.count) projects, including multiple projects with the current extension (.xcodeproj). Specify the project to use with the -project option.",
                                    exitCode: ExitCode.config, trailingBlank: true)
        }
        if inv.scheme != nil || inv.has("-list") {
            if fm.fileExists(atPath: cwd + "/Package.swift") {
                throw XcodebuildFailure("ycodebuild does not support Swift packages without a project or workspace yet.", exitCode: ExitCode.software)
            }
            throw XcodebuildFailure("The directory \(cwd) does not contain an Xcode project, workspace or package.", exitCode: ExitCode.noInput, trailingBlank: true)
        }
        throw XcodebuildFailure("The directory \(cwd) does not contain an Xcode project.", exitCode: ExitCode.noInput, trailingBlank: true)
    }

    static func loadProject(_ url: URL) throws(XcodebuildFailure) -> LoadedProject {
        do {
            return LoadedProject(url: url, proj: try PBXProj(contentsOf: url))
        } catch {
            throw XcodebuildFailure("Unable to read project '\(url.lastPathComponent)': \(error)", exitCode: ExitCode.dataError)
        }
    }

    /// A project plus the projects it references (depth first, each once).
    static func loadProjectContainer(_ url: URL) throws(XcodebuildFailure) -> Container {
        let main = try loadProject(url)
        var projects = [main]
        collectSubprojects(of: main, into: &projects)
        return Container(kind: .project, url: url, projects: projects)
    }

    static func collectSubprojects(of p: LoadedProject, into projects: inout [LoadedProject]) {
        for sub in p.subprojectURLs where !projects.contains(where: { $0.url.standardizedFileURL == sub.standardizedFileURL }) {
            guard let loaded = try? loadProject(sub.standardizedFileURL) else { continue }
            projects.append(loaded)
            collectSubprojects(of: loaded, into: &projects)
        }
    }

    static func loadWorkspace(_ url: URL) throws(XcodebuildFailure) -> Container {
        let ws: Workspace
        do { ws = try Workspace(contentsOf: url.path) } catch {
            throw XcodebuildFailure("Unable to read workspace '\(url.lastPathComponent)': \(error)", exitCode: ExitCode.dataError)
        }
        var projects: [LoadedProject] = []
        for p in ws.projectPaths {
            let u = URL(fileURLWithPath: p).standardizedFileURL
            guard !projects.contains(where: { $0.url == u }), let loaded = try? loadProject(u) else { continue }
            projects.append(loaded)
            collectSubprojects(of: loaded, into: &projects)
        }
        return Container(kind: .workspace, url: url, projects: projects)
    }
}

/// Swift packages stored next to a project and referenced from it: an
/// `XCLocalSwiftPackageReference`, or a folder reference whose directory
/// holds a `Package.swift`. See info-commands.md §2.
struct LocalPackage {
    var directory: String
    var products: [String]
    var name: String
    /// Referenced by an `XCLocalSwiftPackageReference` (reported `@ local`)
    /// rather than by a folder reference.
    var isPackageReference: Bool
    /// Also (or only) added to the project as a folder.
    var addedAsFolder = false
    var testTargets: [String] = []
    /// One scheme per library or executable product; a package added as a
    /// folder also has one per test target not named `<product>Tests`.
    var schemeNames: [String] {
        guard addedAsFolder else { return products }
        return products + testTargets.filter { t in !products.contains { $0 + "Tests" == t } && !products.contains(t) }
    }
}

enum LocalPackages {
    /// A project's package references in `packageReferences` order: local
    /// directories, or remote repository URLs.
    static func references(in p: LoadedProject) -> [(local: String?, remote: String?)] {
        let projectDir = p.url.deletingLastPathComponent()
        return (p.proj.project?.references("packageReferences") ?? []).compactMap { id in
            guard let o = p.proj[id] else { return nil }
            if o.isa == "XCLocalSwiftPackageReference", let rel = o.string("relativePath") {
                return (rel.hasPrefix("/") ? rel : projectDir.appendingPathComponent(rel).standardizedFileURL.path, nil)
            }
            if o.isa == "XCRemoteSwiftPackageReference", let url = o.string("repositoryURL") { return (nil, url) }
            return nil
        }
    }

    static func find(in p: LoadedProject) -> [LocalPackage] {
        var dirs: [(String, Bool)] = references(in: p).compactMap { $0.local.map { ($0, true) } }
        let parents = p.proj.parentMap()
        for o in p.proj.objects(isa: "PBXFileReference") where ["wrapper", "folder"].contains(o.string("lastKnownFileType") ?? "") {
            if let path = p.proj.resolvedPath(of: o.id, projectDirectory: p.directory, parents: parents), path.hasPrefix("/") {
                dirs.append((path, false))
            }
        }
        var out: [LocalPackage] = []
        for (d, isRef) in dirs where !out.contains(where: { $0.directory == d }) {
            guard let manifest = try? String(contentsOfFile: d + "/Package.swift", encoding: .utf8) else { continue }
            out.append(LocalPackage(directory: d, products: productNames(manifest),
                                    name: packageName(manifest) ?? URL(fileURLWithPath: d).lastPathComponent, isPackageReference: isRef,
                                    addedAsFolder: dirs.contains { $0.0 == d && !$0.1 }, testTargets: testTargetNames(manifest)))
        }
        return out
    }

    /// Test target names written literally in the manifest.
    static func testTargetNames(_ manifest: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\.testTarget\s*\(\s*name\s*:\s*"([^"]+)""#) else { return [] }
        let ns = manifest as NSString
        var out: [String] = []
        for m in re.matches(in: manifest, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// Product names written literally in the manifest.
    static func productNames(_ manifest: String) -> [String] {
        var out: [String] = []
        let pattern = #"\.(library|executable)\s*\(\s*name\s*:\s*"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = manifest as NSString
        for m in re.matches(in: manifest, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 2))
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    static func packageName(_ manifest: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"Package\s*\(\s*name\s*:\s*"([^"]+)""#),
              let m = re.firstMatch(in: manifest, range: NSRange(location: 0, length: (manifest as NSString).length)) else { return nil }
        return (manifest as NSString).substring(with: m.range(at: 1))
    }
}
