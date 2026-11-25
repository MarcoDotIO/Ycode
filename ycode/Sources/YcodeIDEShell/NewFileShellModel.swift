import Foundation
import Observation
import YcodeIDECore
import YcodeProject

/// File ▸ New ▸ File from Template… (⌘N) on Linux (P-187, L-151): the
/// macOS New File sheet's two steps in one sheet. The template step is
/// the chooser (platform tabs, filter, the outlined grid); the save step
/// holds the macOS save panel's fields: Save As, the Group pop-up (the
/// project's groups, indented by depth; the folder new files go to) and
/// the Targets checkboxes (the selected file's targets checked). Create
/// writes through the navigator's operations (`ProjectFileOperations`),
/// as the macOS IDE's `createNavigatorFiles` does, saves the project,
/// refreshes the navigator and opens the first file.
@MainActor
@Observable
public final class NewFileShellModel {
    public enum Step: Equatable, Sendable { case template, save }

    /// A Group pop-up entry.
    public struct Group: Equatable, Sendable {
        public var title: String
        public var depth: Int
        public var directory: URL
    }

    public private(set) var step = Step.template
    public private(set) var platform: String
    public private(set) var filter = ""
    public private(set) var sections: [TemplateSection] = []
    public private(set) var selected: TemplateEntry?
    /// Save As: the new file's name.
    public var saveAs = ""
    public private(set) var groups: [Group] = []
    public var groupIndex = 0
    public private(set) var targets: [String] = []
    public private(set) var checkedTargets: [String] = []
    /// Why the last Create failed.
    public private(set) var error: String?

    @ObservationIgnored let workspace: WorkspaceShellModel
    /// The project new files join (nil: a package or folder).
    @ObservationIgnored let projectPath: String?

    public init(workspace: WorkspaceShellModel, platform: String? = nil) {
        self.workspace = workspace
        let model = workspace.session.model
        let project = model.kind == .package ? nil : model.projects.keys.sorted().first
        projectPath = project
        self.platform = platform ?? Self.preferredPlatform(model)
        let selectedPath = workspace.selection.flatMap { workspace.root.find(id: $0)?.path } ?? workspace.document?.path
        let selectedFile = selectedPath.map { URL(fileURLWithPath: $0) }
        if let project, let proj = model.projects[project] {
            let xcodeproj = URL(fileURLWithPath: project)
            groups = Self.groups(proj, xcodeprojURL: xcodeproj)
            targets = proj.targets.compactMap { $0.string("name") }
            let owning = Self.targets(of: selectedFile, proj: proj, xcodeprojURL: xcodeproj)
            checkedTargets = owning.isEmpty ? Array(targets.prefix(1)) : owning
        } else {
            let dir = model.kind == .package ? model.url : model.url.deletingLastPathComponent()
            groups = [Group(title: dir.lastPathComponent, depth: 0, directory: dir)]
        }
        // The group of the selection's folder (else the first).
        if let selectedFile {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: selectedFile.path, isDirectory: &isDir)
            let dir = (exists && isDir.boolValue ? selectedFile : selectedFile.deletingLastPathComponent()).standardizedFileURL.path
            groupIndex = groups.lastIndex { $0.directory.standardizedFileURL.path == dir } ?? 0
        }
        reload()
    }

    public var heading: String { FileTemplateCatalog.heading }
    public var tabs: [String] { FileTemplateCatalog.platforms }

    /// The platform tab the sheet opens on: the product's platform.
    static func preferredPlatform(_ model: WorkspaceModel) -> String {
        let proj = model.projects.keys.sorted().first.flatMap { model.projects[$0] }
        let p = proj.map { DestinationMenuModel.platforms(of: $0).platforms } ?? []
        return ["iOS", "macOS", "watchOS", "tvOS", "visionOS"].first { p.contains($0) } ?? (model.kind == .package ? "macOS" : "iOS")
    }

    // MARK: Template step

    public func setPlatform(_ p: String) {
        guard tabs.contains(p) else { return }
        platform = p
        reload()
    }

    public func setFilter(_ f: String) {
        filter = f
        reload()
    }

    public func select(_ title: String) {
        guard let e = sections.lazy.flatMap(\.entries).first(where: { $0.title == title }) else { return }
        selected = e
    }

    func reload() {
        sections = FileTemplateCatalog.sections(platform: platform, filter: filter)
        let all = sections.flatMap(\.entries)
        if let s = selected, all.contains(s) { return }
        selected = all.first
    }

    // MARK: Steps

    public var isPreviousEnabled: Bool { step == .save }
    public var isNextEnabled: Bool {
        switch step {
        case .template: selected != nil
        case .save: !saveAs.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    public var nextTitle: String { step == .save ? "Create" : "Next" }

    public func next() {
        guard step == .template, let e = selected else { return }
        // The template's default name, as the macOS save panel shows it
        // ("File"); the template adds its extension.
        saveAs = e.defaultName
        error = nil
        step = .save
    }

    public func previous() {
        if step == .save { step = .template }
    }

    public func setTarget(_ name: String, checked: Bool) {
        if checked { if !checkedTargets.contains(name) { checkedTargets.append(name) } } else { checkedTargets.removeAll { $0 == name } }
        checkedTargets.sort { (targets.firstIndex(of: $0) ?? 0) < (targets.firstIndex(of: $1) ?? 0) }
    }

    /// The folder of the chosen group.
    public var directory: URL { groups.indices.contains(groupIndex) ? groups[groupIndex].directory : workspace.session.model.url }

    // MARK: Create

    /// Writes the files and adds them to the project; returns the files
    /// made (nil on failure, with `error` set).
    @discardableResult
    public func create() -> [URL]? {
        guard step == .save, let e = selected else { return nil }
        let name = saveAs.trimmingCharacters(in: .whitespaces)
        do {
            let files = try FileTemplateCatalog.files(e, name: name, platform: platform)
            let urls = try write(files, in: directory)
            error = nil
            if let first = urls.first { workspace.open(first.path) }
            return urls
        } catch {
            self.error = "\(error)"
            return nil
        }
    }

    func write(_ files: [(String, String)], in directory: URL) throws -> [URL] {
        let dir = directory.standardizedFileURL
        var top: [String] = []
        for (f, _) in files {
            let first = String(f.split(separator: "/", omittingEmptySubsequences: true).first ?? Substring(f))
            if !top.contains(first) { top.append(first) }
        }
        for t in top where FileManager.default.fileExists(atPath: dir.appendingPathComponent(t).path) {
            throw NavigatorEditError.exists(t)
        }
        let session = workspace.session
        var ops: ProjectFileOperations
        if let projectPath, let proj = session.model.projects[projectPath] {
            ops = ProjectFileOperations(project: proj, xcodeprojURL: URL(fileURLWithPath: projectPath))
        } else {
            ops = ProjectFileOperations(packageDirectory: session.model.kind == .package ? session.model.url : dir)
        }
        if !FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let container = Self.container(for: dir, ops: ops)
        let ids = ops.project.map { p in p.targets.filter { checkedTargets.contains($0.string("name") ?? "") }.map(\.id) }
        _ = try ops.newFiles(files, in: container, targets: targets.isEmpty ? nil : ids)
        if let projectPath, let proj = ops.project {
            session.model.projects[projectPath] = proj
            try session.model.saveProjects()
        }
        workspace.reloadProjectTree()
        return top.map { dir.appendingPathComponent($0) }
    }

    /// The group whose folder is `dir` (first by ID), a synchronized folder
    /// holding it, else the main group; on disk for a package.
    static func container(for dir: URL, ops: ProjectFileOperations) -> ProjectItem {
        let path = dir.standardizedFileURL.path
        guard let proj = ops.project else { return .disk(path) }
        let groups = proj.objects.values.filter { $0.isa == "PBXGroup" }.sorted { $0.id < $1.id }
        if let g = groups.first(where: { ops.directory(of: .object($0.id))?.standardizedFileURL.path == path }) { return .object(g.id) }
        let folders = proj.objects.values.filter { $0.isa == "PBXFileSystemSynchronizedRootGroup" }
        if let f = folders.first(where: { ops.directory(of: .object($0.id)).map { path == $0.path || path.hasPrefix($0.path + "/") } ?? false }) {
            return ops.directory(of: .object(f.id))?.standardizedFileURL.path == path ? .object(f.id) : .disk(path)
        }
        return .object(proj.rootObject)
    }

    /// The project's groups and synchronized folders, depth first, the
    /// project itself first (the macOS save step's Group pop-up).
    static func groups(_ proj: PBXProj, xcodeprojURL: URL) -> [Group] {
        var out: [Group] = []
        let projectDir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = proj.parentMap()
        let products = proj.project?.string("productRefGroup")
        func walk(_ id: String, _ depth: Int) {
            guard let g = proj[id], let path = proj.resolvedPath(of: id, projectDirectory: projectDir, parents: parents) else { return }
            let title = depth == 0 ? xcodeprojURL.deletingPathExtension().lastPathComponent
                : g.string("name") ?? g.string("path").map { ($0 as NSString).lastPathComponent } ?? "Group"
            out.append(Group(title: title, depth: depth, directory: URL(fileURLWithPath: path)))
            for c in g.references("children") where c != products {
                if let child = proj[c], child.isa == "PBXGroup" || child.isa == "PBXFileSystemSynchronizedRootGroup" { walk(c, depth + 1) }
            }
        }
        if let main = proj.project?.string("mainGroup") { walk(main, 0) }
        return out
    }

    /// Targets whose build phases hold the file, or whose synchronized
    /// folders contain it.
    static func targets(of file: URL?, proj: PBXProj, xcodeprojURL: URL) -> [String] {
        guard let file else { return [] }
        let path = file.standardizedFileURL.path
        let projectDir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = proj.parentMap()
        return proj.targets.filter { t in
            let inPhase = proj.buildPhases(ofTarget: t.id).contains { phase in
                phase.references("files").contains { bf in
                    guard let ref = proj[bf]?.string("fileRef") else { return false }
                    return proj.resolvedPath(of: ref, projectDirectory: projectDir, parents: parents) == path
                }
            }
            let inFolder = t.references("fileSystemSynchronizedGroups").contains { g in
                guard let dir = proj.resolvedPath(of: g, projectDirectory: projectDir, parents: parents) else { return false }
                return path.hasPrefix(dir + "/")
            }
            return inPhase || inFolder
        }.compactMap { $0.string("name") }
    }
}
