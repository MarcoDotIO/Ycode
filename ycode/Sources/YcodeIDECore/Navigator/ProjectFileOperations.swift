import Foundation
import YcodePlist
import YcodeProject

public enum NavigatorEditError: LocalizedError, CustomStringConvertible, Equatable {
    /// An item with that name is already there.
    case exists(String)
    case invalidName(String)
    /// The operation does not apply to the items (for example a group in a
    /// synchronized folder).
    case notAllowed(String)
    case missing(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .exists(let n): "“\(n)” already exists"
        case .invalidName(let n): "“\(n)” is not a valid name"
        case .notAllowed(let why): why
        case .missing(let n): "“\(n)” was not found"
        }
    }
}

/// A project navigator row an operation acts on.
public enum ProjectItem: Hashable, Sendable {
    /// A pbxproj object: a group, a file reference or a synchronized folder.
    /// The `PBXProject` object stands for the main group.
    case object(String)
    /// A file or folder with no object of its own: inside a synchronized
    /// folder, or in a package.
    case disk(String)
}

/// Add Files… options (`specs/ide/navigators.md` §Ycode implementation).
public struct AddFilesOptions: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        /// Copies the items that are not already in the destination's folder.
        case copy = "Copy files to destination"
        /// Moves the items that are not already in the destination's folder.
        case move = "Move files to destination"
        case reference = "Reference files in place"
    }

    public enum Grouping: String, CaseIterable, Sendable {
        /// A synchronized folder per added folder.
        case folders = "Create folders"
        /// A group per added folder, with a reference per file.
        case groups = "Create groups"
        /// A folder reference per added folder (copied as a unit).
        case folderReferences = "Create folder references"
    }

    public var action: Action
    public var grouping: Grouping
    /// The targets (object IDs) the added items join.
    public var targets: [String]

    public init(action: Action = .copy, grouping: Grouping = .groups, targets: [String] = []) {
        self.action = action
        self.grouping = grouping
        self.targets = targets
    }
}

/// One finished operation, with what undo and redo need: the project
/// before and after (untouched objects keep their bytes either way) and
/// the file steps that were performed.
public struct ProjectEdit: Sendable {
    /// "New Group", "Delete", … (the Edit menu's "Undo <name>").
    public let actionName: String
    public let before: PBXProj?
    public let after: PBXProj?
    public private(set) var entries: [FileSystemJournal.Entry]
    /// The items to select afterwards.
    public let result: [ProjectItem]
    /// Paths that moved or were renamed (old → new), so open editors follow.
    public let moved: [String: String]
    /// Every path created, moved (both ends) or trashed: what source
    /// control stages.
    public var touchedPaths: [String] {
        var out: [String] = []
        for e in entries {
            switch e.step {
            case .createFile(let u, _), .createDirectory(let u), .copy(_, let u), .trash(let u): out.append(u.path)
            case .move(let a, let b): out += [a.path, b.path]
            }
        }
        return out
    }

    /// Reverses the file steps; returns the project as it was before.
    public func undo(bin: TrashBin) throws -> PBXProj? {
        try FileSystemJournal.undo(entries, bin: bin)
        return before
    }

    /// Performs the file steps again; returns the project as it was after.
    public mutating func redo(bin: TrashBin) throws -> PBXProj? {
        entries = try FileSystemJournal.redo(entries, bin: bin)
        return after
    }
}

/// The project navigator's file operations on one project (or a package
/// folder): each keeps the project and the file system consistent and
/// returns a `ProjectEdit` to undo it. See `specs/ide/navigators.md`
/// §Ycode implementation.
public struct ProjectFileOperations: Sendable {
    public var project: PBXProj?
    public let xcodeprojURL: URL?
    /// The project's directory (`projectDirPath` applied), or the package folder.
    public let rootDirectory: URL
    public internal(set) var journal: FileSystemJournal
    var moved: [String: String] = [:]

    public init(project: PBXProj, xcodeprojURL: URL, bin: TrashBin = .user) {
        self.project = project
        self.xcodeprojURL = xcodeprojURL
        rootDirectory = project.projectDirectory(xcodeprojURL: xcodeprojURL)
        journal = FileSystemJournal(bin: bin)
    }

    /// A package (or plain folder): operations work on disk only.
    public init(packageDirectory: URL, bin: TrashBin = .user) {
        project = nil
        xcodeprojURL = nil
        rootDirectory = packageDirectory.standardizedFileURL
        journal = FileSystemJournal(bin: bin)
    }

    // MARK: Running an edit

    mutating func edit(_ name: String, _ body: (inout ProjectFileOperations) throws -> [ProjectItem]) throws -> ProjectEdit {
        let before = project
        moved = [:]
        _ = journal.takeEntries()
        do {
            let result = try body(&self)
            return ProjectEdit(actionName: name, before: before, after: project, entries: journal.takeEntries(), result: result, moved: moved)
        } catch {
            // Leave nothing half done.
            try? FileSystemJournal.undo(journal.takeEntries(), bin: journal.bin)
            project = before
            throw error
        }
    }

    // MARK: Looking things up

    var proj: PBXProj {
        get { project! }
        set { project = newValue }
    }

    var isProject: Bool { project != nil }

    func resolved(_ id: String) -> String? {
        project?.resolvedPath(of: id, projectDirectory: rootDirectory)
    }

    func isa(_ id: String) -> String { project?[id]?.isa ?? "" }

    /// The synchronized folder holding `path`, and the path inside it.
    func synchronizedFolder(containing path: String) -> (folder: String, relative: String)? {
        guard let project else { return nil }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        var best: (String, String)?
        for g in project.objects.values where g.isa == "PBXFileSystemSynchronizedRootGroup" {
            guard let root = resolved(g.id) else { continue }
            if p == root { return (g.id, "") }
            if RelativePath.isInside(p, root), best.map({ root.count > $0.1.count }) ?? true { best = (g.id, root) }
        }
        return best.map { ($0.0, RelativePath.from($0.1, to: p)) }
    }

    /// The folder an item's new children go to.
    public func directory(of item: ProjectItem) -> URL? {
        switch item {
        case .disk(let p):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            return isDir.boolValue ? URL(fileURLWithPath: p) : URL(fileURLWithPath: p).deletingLastPathComponent()
        case .object(let id):
            guard let project else { return nil }
            let gid = project.groupID(id)
            if PBXProj.editableGroupClasses.contains(isa(gid)) || isa(gid) == "PBXFileSystemSynchronizedRootGroup" {
                return resolved(gid).map { URL(fileURLWithPath: $0) }
            }
            return resolved(gid).map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        }
    }

    /// Where a new item goes for a navigator selection: into a selected
    /// group or folder (at the end), or after a selected file in its group.
    public func insertionPoint(for selection: ProjectItem?) -> (container: ProjectItem, index: Int?) {
        guard let selection else {
            return (project.map { .object($0.groupID($0.rootObject)) } ?? .disk(rootDirectory.path), nil)
        }
        switch selection {
        case .disk(let p):
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            let dir = isDir.boolValue && !Self.isBundle(p) ? p : (p as NSString).deletingLastPathComponent
            if let s = synchronizedFolder(containing: dir), s.relative.isEmpty { return (.object(s.folder), nil) }
            return (.disk(dir), nil)
        case .object(let id):
            guard let project else { return (.disk(rootDirectory.path), nil) }
            let gid = project.groupID(id)
            if PBXProj.editableGroupClasses.contains(isa(gid)) || isa(gid) == "PBXFileSystemSynchronizedRootGroup" { return (.object(gid), nil) }
            if let parent = project.parentMap()[gid], let i = project[parent]?.references("children").firstIndex(of: gid) {
                return (.object(parent), i + 1)
            }
            return (.object(project.groupID(project.rootObject)), nil)
        }
    }

    /// The container is a classic group (groups and references go there),
    /// not a folder on disk.
    func classicGroup(_ c: ProjectItem) -> String? {
        guard case .object(let id) = c, let project else { return nil }
        let gid = project.groupID(id)
        return PBXProj.editableGroupClasses.contains(isa(gid)) ? gid : nil
    }

    static func isBundle(_ path: String) -> Bool {
        ["xcassets", "xcodeproj", "xcworkspace", "playground", "xcdatamodeld", "xcdatamodel", "bundle", "framework", "xcframework",
         "app", "docc", "scnassets", "xcstickers", "icon", "rcproject", "mlpackage", "xctemplate"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    static func validate(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != ".", n != "..", !n.contains("/"), !n.contains("\0") else { throw NavigatorEditError.invalidName(name) }
        return n
    }

    /// `base`, else "base 2", "base 3", … : free on disk in `dir` and
    /// among the group's children names.
    func uniqueName(_ base: String, in dir: URL?, group: String?) -> String {
        let taken = Set((group.flatMap { project?[$0]?.references("children") } ?? []).compactMap(displayName))
        var name = base, n = 1
        while taken.contains(name) || dir.map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }) == true {
            n += 1
            name = "\(base) \(n)"
        }
        return name
    }

    func displayName(_ id: String) -> String? {
        guard let o = project?[id] else { return nil }
        return o.string("name") ?? o.string("path").map { ($0 as NSString).lastPathComponent }
    }

    /// A free default name for a new item in the container ("New Group",
    /// "New Group 2", …).
    public func defaultName(_ base: String, in container: ProjectItem) -> String {
        uniqueName(base, in: directory(of: container), group: classicGroup(container))
    }

    // MARK: New groups and folders

    /// File ▸ New ▸ Group (with a folder of the same name) or Group
    /// without Folder. Groups go into classic groups only.
    public mutating func newGroup(named name: String, in container: ProjectItem, at index: Int? = nil, withFolder: Bool) throws -> ProjectEdit {
        let name = try Self.validate(name)
        guard let group = classicGroup(container) else { throw NavigatorEditError.notAllowed("Groups cannot be added to a folder") }
        return try edit(withFolder ? "New Group" : "New Group without Folder") { ops in
            if withFolder, let dir = ops.directory(of: container) {
                let url = dir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) { try ops.journal.perform(.createDirectory(url)) }
            }
            return [.object(ops.proj.addGroup(named: name, withFolder: withFolder, to: group, at: index))]
        }
    }

    /// File ▸ New ▸ Folder: a directory on disk. In a classic group it is a
    /// new synchronized folder, included in the targets the group's files
    /// belong to; inside a folder (or a package) only the directory is made.
    public mutating func newFolder(named name: String, in container: ProjectItem, at index: Int? = nil) throws -> ProjectEdit {
        let name = try Self.validate(name)
        guard let dir = directory(of: container) else { throw NavigatorEditError.missing(name) }
        let url = dir.appendingPathComponent(name)
        return try edit("New Folder") { ops in
            try ops.journal.perform(.createDirectory(url))
            guard let group = ops.classicGroup(container) else { return [.disk(url.path)] }
            let targets = ops.targetsOfMembers(group)
            return [.object(ops.proj.addSynchronizedFolder(path: name, to: group, at: index, targets: targets))]
        }
    }

    /// The targets any file directly in `group` belongs to, in project order.
    func targetsOfMembers(_ group: String) -> [String] {
        let kids = Set(proj[group]?.references("children") ?? [])
        var found = Set<String>()
        for k in kids { found.formUnion(proj.targetsContaining(k)) }
        for k in kids where isa(k) == "PBXFileSystemSynchronizedRootGroup" {
            for t in proj.targets where t.references("fileSystemSynchronizedGroups").contains(k) { found.insert(t.id) }
        }
        return proj.targets.map(\.id).filter(found.contains)
    }

    // MARK: New files

    /// Writes template files (paths relative to the container's folder; a
    /// path ending in "/" is an empty folder) and adds the top-level items:
    /// a reference each in a classic group, joined to `targets` (nil: the
    /// first target with Compile Sources, for compiled files); in a
    /// synchronized folder, the owning targets not in `targets` get an
    /// exception for each item.
    public mutating func newFiles(_ files: [(String, String)], in container: ProjectItem, at index: Int? = nil,
                                  targets: [String]? = nil) throws -> ProjectEdit {
        guard let dir = directory(of: container) else { throw NavigatorEditError.missing("destination") }
        var top: [String] = []
        for (f, _) in files {
            let first = String(f.split(separator: "/", omittingEmptySubsequences: true).first ?? Substring(f))
            if !top.contains(first) { top.append(first) }
        }
        for t in top where FileManager.default.fileExists(atPath: dir.appendingPathComponent(t).path) { throw NavigatorEditError.exists(t) }
        return try edit("New File") { ops in
            // Each new folder is its own step, outer first, so undo takes
            // every one of them back.
            func makeFolders(_ rel: String) throws {
                var u = dir
                for part in rel.split(separator: "/") {
                    u.appendPathComponent(String(part))
                    if !FileManager.default.fileExists(atPath: u.path) { try ops.journal.perform(.createDirectory(u)) }
                }
            }
            for (f, text) in files {
                if f.hasSuffix("/") {
                    try makeFolders(f)
                } else {
                    try makeFolders((f as NSString).deletingLastPathComponent)
                    try ops.journal.perform(.createFile(dir.appendingPathComponent(f), Data(text.utf8)))
                }
            }
            let urls = top.map { dir.appendingPathComponent($0) }
            guard ops.isProject else { return urls.map { .disk($0.path) } }
            if let group = ops.classicGroup(container) {
                var out: [ProjectItem] = []
                let fallback = ops.proj.targets.first { t in ops.proj.buildPhases(ofTarget: t.id).contains { $0.isa == "PBXSourcesBuildPhase" } }
                for (n, u) in urls.enumerated() {
                    let ref = ops.proj.addReference(path: u.lastPathComponent, fileType: PBXProj.fileType(forPath: u.path), to: group,
                                                    at: index.map { $0 + n })
                    if let targets {
                        ops.proj.addToTargets(ref, fileName: u.lastPathComponent, targets: targets)
                    } else if let fallback, FileTemplate.compiledExtensions.contains(u.pathExtension.lowercased()) {
                        ops.proj.addToTargets(ref, fileName: u.lastPathComponent, targets: [fallback.id])
                    }
                    out.append(.object(ref))
                }
                return out
            }
            if let targets {
                for u in urls { ops.exclude(u.path, exceptFor: targets) }
            }
            return urls.map { .disk($0.path) }
        }
    }

    /// For a path in a synchronized folder: every target owning the folder
    /// that is not in `targets` gets an exception for it.
    mutating func exclude(_ path: String, exceptFor targets: [String]) {
        guard let s = synchronizedFolder(containing: path), !s.relative.isEmpty else { return }
        for t in proj.targets where t.references("fileSystemSynchronizedGroups").contains(s.folder) && !targets.contains(t.id) {
            proj.setMembership(ofFile: path, target: t.id, member: false, projectDirectory: rootDirectory)
        }
    }

    // MARK: Add Files

    /// File ▸ Add Files to “<project>”…: adds existing files and folders to
    /// the container, copying or moving them first when asked (items
    /// already in the container's folder stay where they are).
    public mutating func addFiles(_ urls: [URL], to container: ProjectItem, at index: Int? = nil, options: AddFilesOptions) throws -> ProjectEdit {
        guard let dir = directory(of: container) else { throw NavigatorEditError.missing("destination") }
        let group = classicGroup(container)
        return try edit("Add Files") { ops in
            var out: [ProjectItem] = []
            for (n, src) in urls.map(\.standardizedFileURL).enumerated() {
                var location = src
                let inPlace = src.deletingLastPathComponent().path == dir.standardizedFileURL.path
                // Items reach a synchronized folder (or a package) only on disk.
                let action = group == nil && options.action == .reference && !inPlace ? .copy : options.action
                if !inPlace && action != .reference {
                    location = dir.appendingPathComponent(src.lastPathComponent)
                    try ops.journal.perform(action == .copy ? .copy(src, location) : .move(src, location))
                    if action == .move { ops.moved[src.path] = location.path }
                }
                guard ops.isProject else { out.append(.disk(location.path)); continue }
                guard let group else {
                    ops.exclude(location.path, exceptFor: options.targets)
                    out.append(.disk(location.path))
                    continue
                }
                let rel = RelativePath.from(ops.resolved(group) ?? dir.path, to: location.path)
                out.append(.object(try ops.addItem(at: location, path: rel, to: group, at: index.map { $0 + n }, options: options)))
            }
            return out
        }
    }

    /// Adds one existing item to a group: a reference for a file or
    /// bundle, else a group tree, folder reference or synchronized folder.
    mutating func addItem(at url: URL, path: String, to group: String, at index: Int?, options: AddFilesOptions) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw NavigatorEditError.missing(url.lastPathComponent) }
        let name = url.lastPathComponent
        if isDir.boolValue && url.pathExtension.lowercased() == "xcdatamodeld" {
            return addVersionGroup(at: url, path: path, to: group, at: index, targets: options.targets)
        }
        if !isDir.boolValue || Self.isBundle(url.path) {
            let ref = proj.addReference(path: path, fileType: PBXProj.fileType(forPath: name), to: group, at: index)
            proj.addToTargets(ref, fileName: name, targets: options.targets)
            return ref
        }
        switch options.grouping {
        case .folderReferences:
            let ref = proj.addReference(path: path, fileType: "folder", to: group, at: index)
            proj.addToTargets(ref, fileName: name, targets: options.targets, isFolderReference: true)
            return ref
        case .folders:
            let f = proj.addSynchronizedFolder(path: path, to: group, at: index, targets: options.targets)
            proj.setPath(path, of: f)
            return f
        case .groups:
            let g = proj.addGroup(named: path, withFolder: true, to: group, at: index)
            proj.setPath(path, of: g)
            for child in NavigatorTree.directory(url.path) {
                guard let p = child.path else { continue }
                _ = try addItem(at: URL(fileURLWithPath: p), path: (p as NSString).lastPathComponent, to: g, at: nil, options: options)
            }
            return g
        }
    }

    /// A Core Data model bundle: an `XCVersionGroup` holding its versions,
    /// the current one from `.xccurrentversion` (else the last).
    mutating func addVersionGroup(at url: URL, path: String, to group: String, at index: Int?, targets: [String]) -> String {
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".xcdatamodel") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let currentName = (NSDictionary(contentsOf: url.appendingPathComponent(".xccurrentversion"))?["_XCCurrentVersionName"] as? String)
            ?? versions.last
        let id = proj.addObject([("isa", .string("XCVersionGroup")), ("children", .array([])), ("path", .string(path)),
                                 ("sourceTree", .string("<group>")), ("versionGroupType", .string("wrapper.xcdatamodel"))], to: group, at: index)
        var current: String?
        for v in versions {
            let ref = proj.addReference(path: v, fileType: "wrapper.xcdatamodel", to: id, at: nil)
            if v == currentName { current = ref }
        }
        if let current, var g = proj[id] {
            g["currentVersion"] = .string(current)
            proj[id] = g
        }
        proj.addToTargets(id, fileName: url.lastPathComponent, targets: targets)
        return id
    }
}
