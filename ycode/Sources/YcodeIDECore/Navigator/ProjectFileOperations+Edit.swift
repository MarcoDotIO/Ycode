import Foundation
import YcodePlist
import YcodeProject

/// Edit ▸ Sort ▸ By Name / By Type.
public enum NavigatorSortOrder: Sendable {
    /// Display names in Finder order, groups and files mixed.
    case name
    /// Groups and folders first, then files by extension, each by name.
    case type
}

extension ProjectFileOperations {
    // MARK: Delete

    /// Edit ▸ Delete: removes the items' references (and, for groups,
    /// everything under them), and with `moveToTrash` moves their files
    /// to the trash. Items with no reference of their own (in a
    /// synchronized folder, in a package) can only go to the trash.
    public mutating func delete(_ items: [ProjectItem], moveToTrash: Bool) throws -> ProjectEdit {
        for item in items {
            switch item {
            case .disk(let p) where !moveToTrash: throw NavigatorEditError.notAllowed("“\((p as NSString).lastPathComponent)” has no reference to remove")
            case .object(let id) where project.map({ $0.groupID(id) == $0.groupID($0.rootObject) }) ?? true:
                throw NavigatorEditError.notAllowed("The project cannot be deleted")
            default: break
            }
        }
        return try edit(moveToTrash ? "Move to Trash" : "Remove References") { ops in
            var trash: [String] = []
            var emptyFolders: [String] = []
            for item in items {
                switch item {
                case .disk(let p): trash.append(p)
                case .object(let id):
                    guard moveToTrash else { continue }
                    let paths = ops.trashPaths(id)
                    trash += paths.files
                    emptyFolders += paths.folders
                }
            }
            // Outer items first; skip anything inside an item already trashed.
            var done: [String] = []
            for p in trash.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted() where !done.contains(where: { RelativePath.isInside(p, $0) }) {
                guard FileManager.default.fileExists(atPath: p) else { continue }
                if let s = ops.synchronizedFolder(containing: p), !s.relative.isEmpty { ops.proj.rewriteExceptionPaths(in: s.folder, from: s.relative, to: nil) }
                try ops.journal.perform(.trash(URL(fileURLWithPath: p)))
                done.append(p)
            }
            for item in items { if case .object(let id) = item { ops.proj.removeTree(id) } }
            // A group's folder goes too once nothing is left in it (inner first).
            for f in emptyFolders.reversed() where FileManager.default.fileExists(atPath: f) && !done.contains(where: { RelativePath.isInside(f, $0) }) {
                let left = ((try? FileManager.default.contentsOfDirectory(atPath: f)) ?? []).filter { $0 != ".DS_Store" }
                if left.isEmpty { try ops.journal.perform(.trash(URL(fileURLWithPath: f))) }
            }
            return []
        }
    }

    /// What trashing an object moves to the trash: a reference's file, a
    /// synchronized folder or model bundle as a whole; for a group, its
    /// members' files, and its own folder (when it has one) if that ends
    /// up empty.
    func trashPaths(_ id: String) -> (files: [String], folders: [String]) {
        guard let obj = project?[id], let path = resolved(id), !path.hasPrefix("$(") else { return ([], []) }
        switch obj.isa {
        case "PBXFileReference", "PBXFileSystemSynchronizedRootGroup", "XCVersionGroup": return ([path], [])
        case "PBXGroup", "PBXVariantGroup":
            let kids = obj.references("children").map(trashPaths)
            // Outer folders first; the caller tries them inner first.
            return (kids.flatMap(\.files), (obj.string("path") != nil ? [path] : []) + kids.flatMap(\.folders))
        default: return ([], [])
        }
    }

    // MARK: Rename

    /// Renames a file, group or folder: on disk when it has a location
    /// there, and in the project (`path`'s last component, or `name` for a
    /// group without a folder). Exception sets follow renamed items in a
    /// synchronized folder.
    public mutating func rename(_ item: ProjectItem, to newName: String) throws -> ProjectEdit {
        let newName = try Self.validate(newName)
        return try edit("Rename") { ops in [try ops.renameItem(item, to: newName)] }
    }

    mutating func renameItem(_ item: ProjectItem, to newName: String) throws -> ProjectItem {
        switch item {
        case .disk(let p):
            let old = URL(fileURLWithPath: p), new = old.deletingLastPathComponent().appendingPathComponent(newName)
            guard old.lastPathComponent != newName else { return item }
            let folder = synchronizedFolder(containing: p)
            try journal.perform(.move(old, new))
            moved[old.path] = new.path
            if let folder, !folder.relative.isEmpty {
                let parent = (folder.relative as NSString).deletingLastPathComponent
                proj.rewriteExceptionPaths(in: folder.folder, from: folder.relative, to: parent.isEmpty ? newName : parent + "/" + newName)
            }
            return .disk(new.path)
        case .object(let id):
            guard var obj = project?[id], proj.groupID(id) != proj.groupID(proj.rootObject) else {
                throw NavigatorEditError.notAllowed("The project is renamed in the File inspector")
            }
            guard displayName(id) != newName else { return item }
            if let path = obj.string("path") {
                if let abs = resolved(id), !abs.hasPrefix("$("), FileManager.default.fileExists(atPath: abs) {
                    let old = URL(fileURLWithPath: abs), new = old.deletingLastPathComponent().appendingPathComponent(newName)
                    try journal.perform(.move(old, new))
                    moved[old.path] = new.path
                }
                let parent = (path as NSString).deletingLastPathComponent
                obj["path"] = .string(parent.isEmpty ? newName : parent + "/" + newName)
                obj["name"] = parent.isEmpty ? nil : .string(newName)
                if obj.isa == "PBXFileReference", obj.string("lastKnownFileType") != nil,
                   (path as NSString).pathExtension.lowercased() != (newName as NSString).pathExtension.lowercased() {
                    obj["lastKnownFileType"] = .string(PBXProj.fileType(forPath: newName))
                }
            } else {
                obj["name"] = .string(newName)
            }
            proj[id] = obj
            return item
        }
    }

    // MARK: Move

    /// Drag and drop in the navigator (and Edit ▸ Paste ▸ Move Item Here):
    /// moves items into a group or folder at `index`. Files move on disk
    /// when the destination has a folder of its own; otherwise their paths
    /// are rewritten so they keep pointing at the same files.
    public mutating func move(_ items: [ProjectItem], to container: ProjectItem, at index: Int? = nil) throws -> ProjectEdit {
        try edit("Move") { ops in
            var out: [ProjectItem] = []
            var i = index
            for item in items {
                out.append(try ops.moveItem(item, to: container, at: i))
                i = i.map { $0 + 1 }
            }
            return out
        }
    }

    mutating func moveItem(_ item: ProjectItem, to container: ProjectItem, at index: Int?) throws -> ProjectItem {
        guard let destDir = directory(of: container) else { throw NavigatorEditError.missing("destination") }
        if let group = classicGroup(container) {
            switch item {
            case .object(let x): return try moveObject(x, into: group, at: index)
            case .disk(let p):
                // Out of a synchronized folder into a group: the item gets a
                // reference, in the targets that had it.
                let members = membershipTargets(ofDiskItem: p)
                let new = destDir.appendingPathComponent((p as NSString).lastPathComponent)
                if let s = synchronizedFolder(containing: p), !s.relative.isEmpty { proj.rewriteExceptionPaths(in: s.folder, from: s.relative, to: nil) }
                try journal.perform(.move(URL(fileURLWithPath: p), new))
                moved[p] = new.path
                let rel = RelativePath.from(resolved(group) ?? destDir.path, to: new.path)
                return .object(try addItem(at: new, path: rel, to: group, at: index,
                                           options: AddFilesOptions(action: .reference, grouping: .folders, targets: members ?? [])))
            }
        }
        // Into a folder on disk (a synchronized folder, a package folder).
        switch item {
        case .disk(let p):
            guard !RelativePath.isInside(destDir.path, p) else { throw NavigatorEditError.notAllowed("A folder cannot move into itself") }
            let new = destDir.appendingPathComponent((p as NSString).lastPathComponent)
            guard new.standardizedFileURL.path != URL(fileURLWithPath: p).standardizedFileURL.path else { return item }
            let members = membershipTargets(ofDiskItem: p)
            let from = synchronizedFolder(containing: p)
            try journal.perform(.move(URL(fileURLWithPath: p), new))
            moved[p] = new.path
            if isProject {
                let to = synchronizedFolder(containing: new.path)
                if let from, !from.relative.isEmpty {
                    proj.rewriteExceptionPaths(in: from.folder, from: from.relative, to: from.folder == to?.folder ? to?.relative : nil)
                }
                if from?.folder != to?.folder, let members { exclude(new.path, exceptFor: members) }
            }
            return .disk(new.path)
        case .object(let x):
            guard ["PBXFileReference", "XCVersionGroup"].contains(isa(x)), let abs = resolved(x), FileManager.default.fileExists(atPath: abs) else {
                throw NavigatorEditError.notAllowed("Only files can move into a folder")
            }
            let members = proj.targetsContaining(x)
            let new = destDir.appendingPathComponent((abs as NSString).lastPathComponent)
            try journal.perform(.move(URL(fileURLWithPath: abs), new))
            moved[abs] = new.path
            proj.removeTree(x)
            exclude(new.path, exceptFor: members)
            return .disk(new.path)
        }
    }

    /// The targets a disk item belongs to through its synchronized folder
    /// (nil outside one).
    func membershipTargets(ofDiskItem p: String) -> [String]? {
        guard isProject, synchronizedFolder(containing: p) != nil else { return nil }
        return proj.targetMemberships(ofFile: p, projectDirectory: rootDirectory).filter(\.isMember).map(\.targetID)
    }

    /// Moves an object into a classic group.
    mutating func moveObject(_ x: String, into group: String, at index: Int?) throws -> ProjectItem {
        let main = proj.groupID(proj.rootObject)
        guard x != main, proj[x] != nil else { throw NavigatorEditError.notAllowed("The project cannot move") }
        var parents = proj.parentMap()
        var a: String? = group
        while let g = a {
            if g == x { throw NavigatorEditError.notAllowed("A group cannot move into itself") }
            a = parents[g]
        }
        // Where everything under `x` is now, to keep pointing at it.
        var oldPaths: [String: String] = [:]
        func record(_ id: String) {
            if let p = proj.resolvedPath(of: id, projectDirectory: rootDirectory, parents: parents), !p.hasPrefix("$(") { oldPaths[id] = p }
            for c in proj[id]?.references("children") ?? [] { record(c) }
        }
        record(x)
        let oldParent = parents[x]
        var index = index
        if let d = proj.detachChild(x), d.group == group, let j = index, d.index < j { index = j - 1 }
        proj.insertChild(x, into: group, at: index)
        parents = proj.parentMap()
        // On disk: into the destination group's own folder, when the item
        // sits directly in its old group's folder.
        let destDir = proj.resolvedPath(of: group, projectDirectory: rootDirectory, parents: parents) ?? rootDirectory.path
        let folderBacked = group == main || proj[group]?.string("path") != nil
        var diskMove: (String, String)?
        if folderBacked, let obj = proj[x], obj.string("path") != nil, (obj.string("sourceTree") ?? "<group>") == "<group>",
           let old = oldPaths[x], FileManager.default.fileExists(atPath: old),
           let oldParent, let oldParentDir = oldPaths[oldParent] ?? resolved(oldParent),
           (old as NSString).deletingLastPathComponent == URL(fileURLWithPath: oldParentDir).standardizedFileURL.path,
           URL(fileURLWithPath: destDir).standardizedFileURL.path != URL(fileURLWithPath: oldParentDir).standardizedFileURL.path {
            let new = URL(fileURLWithPath: destDir).appendingPathComponent((old as NSString).lastPathComponent).path
            try journal.perform(.move(URL(fileURLWithPath: old), URL(fileURLWithPath: new)))
            moved[old] = new
            diskMove = (old, new)
        }
        // Rewrite `<group>` paths, top down, so each item resolves to where
        // its file now is.
        func expected(_ p: String) -> String {
            guard let d = diskMove, RelativePath.isInside(p, d.0) else { return p }
            return d.1 + p.dropFirst(d.0.count)
        }
        func fix(_ id: String) {
            if let obj = proj[id], obj.string("path") != nil, (obj.string("sourceTree") ?? "<group>") == "<group>", let old = oldPaths[id] {
                let want = expected(old)
                let now = proj.resolvedPath(of: id, projectDirectory: rootDirectory, parents: parents)
                if now != want, let parent = parents[id],
                   let base = proj.resolvedPath(of: parent, projectDirectory: rootDirectory, parents: parents) {
                    proj.setPath(RelativePath.from(base, to: want), of: id)
                }
            }
            for c in proj[id]?.references("children") ?? [] { fix(c) }
        }
        fix(x)
        return .object(x)
    }

    // MARK: Group and Folder from Selection

    /// File ▸ New ▸ Group from Selection (with or without a folder): a new
    /// group in the items' group, at the first item's place, holding them.
    public mutating func groupFromSelection(_ items: [ProjectItem], named name: String, withFolder: Bool) throws -> ProjectEdit {
        let name = try Self.validate(name)
        let (parent, first, ids) = try sharedGroup(items)
        return try edit(withFolder ? "New Group from Selection" : "New Group from Selection without Folder") { ops in
            if withFolder, let dir = ops.resolved(parent) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) { try ops.journal.perform(.createDirectory(url)) }
            }
            let g = ops.proj.addGroup(named: name, withFolder: withFolder, to: parent, at: first)
            for id in ids { _ = try ops.moveObject(id, into: g, at: nil) }
            return [.object(g)]
        }
    }

    /// Group from Selection applies: the items share a classic group.
    public func canGroup(_ items: [ProjectItem]) -> Bool { (try? sharedGroup(items)) != nil }

    /// Folder from Selection applies: items in one folder, or files in one group.
    public func canMakeFolder(from items: [ProjectItem]) -> Bool {
        let disks = items.compactMap { if case .disk(let p) = $0 { p } else { nil } }
        if !disks.isEmpty {
            let parent = (disks[0] as NSString).deletingLastPathComponent
            return disks.count == items.count && disks.allSatisfy { ($0 as NSString).deletingLastPathComponent == parent }
        }
        guard let ids = try? sharedGroup(items).2 else { return false }
        return ids.allSatisfy { isa($0) == "PBXFileReference" }
    }

    /// The classic group all items are in, the first one's index, and the
    /// items in group order.
    func sharedGroup(_ items: [ProjectItem]) throws -> (String, Int, [String]) {
        let ids = items.compactMap { if case .object(let id) = $0 { id } else { nil } }
        guard isProject, !ids.isEmpty, ids.count == items.count else { throw NavigatorEditError.notAllowed("Select items in one group") }
        let parents = proj.parentMap()
        guard let parent = parents[ids[0]], ids.allSatisfy({ parents[$0] == parent }), classicGroup(.object(parent)) != nil,
              let kids = proj[parent]?.references("children") else { throw NavigatorEditError.notAllowed("Select items in one group") }
        let ordered = kids.filter(ids.contains)
        return (parent, kids.firstIndex(of: ordered[0]) ?? 0, ordered)
    }

    /// File ▸ New ▸ Folder from Selection: a new folder holding the items.
    /// Items in a folder move into a new subfolder. File references in a
    /// group move into a new synchronized folder there, which joins every
    /// target any of them was in; a file not in one of those targets gets
    /// an exception for it.
    public mutating func folderFromSelection(_ items: [ProjectItem], named name: String) throws -> ProjectEdit {
        let name = try Self.validate(name)
        let disks = items.compactMap { if case .disk(let p) = $0 { p } else { nil } }
        if !disks.isEmpty {
            let parent = (disks[0] as NSString).deletingLastPathComponent
            guard disks.count == items.count, disks.allSatisfy({ ($0 as NSString).deletingLastPathComponent == parent }) else {
                throw NavigatorEditError.notAllowed("Select items in one folder")
            }
            return try edit("New Folder from Selection") { ops in
                let dir = URL(fileURLWithPath: parent).appendingPathComponent(name)
                try ops.journal.perform(.createDirectory(dir))
                for p in disks { _ = try ops.moveItem(.disk(p), to: .disk(dir.path), at: nil) }
                return [.disk(dir.path)]
            }
        }
        let (parent, first, ids) = try sharedGroup(items)
        guard ids.allSatisfy({ isa($0) == "PBXFileReference" }), let parentDir = resolved(parent) else {
            throw NavigatorEditError.notAllowed("Only files can go into a new folder")
        }
        return try edit("New Folder from Selection") { ops in
            let dir = URL(fileURLWithPath: parentDir).appendingPathComponent(name)
            try ops.journal.perform(.createDirectory(dir))
            let members = ids.map { ops.proj.targetsContaining($0) }
            let union = ops.proj.targets.map(\.id).filter { t in members.contains { $0.contains(t) } }
            let folder = ops.proj.addSynchronizedFolder(path: name, to: parent, at: first, targets: union)
            for (id, targets) in zip(ids, members) {
                guard let abs = ops.resolved(id), FileManager.default.fileExists(atPath: abs) else { ops.proj.removeTree(id); continue }
                let new = dir.appendingPathComponent((abs as NSString).lastPathComponent)
                try ops.journal.perform(.move(URL(fileURLWithPath: abs), new))
                ops.moved[abs] = new.path
                ops.proj.removeTree(id)
                ops.exclude(new.path, exceptFor: targets)
            }
            return [.object(folder)]
        }
    }

    // MARK: Sort

    /// Edit ▸ Sort ▸ By Name / By Type: reorders a group's children (one
    /// level). Folders on disk are always shown sorted.
    public mutating func sort(_ container: ProjectItem, by order: NavigatorSortOrder) throws -> ProjectEdit {
        guard let group = classicGroup(container) else { throw NavigatorEditError.notAllowed("Only groups can be sorted") }
        return try edit(order == .name ? "Sort by Name" : "Sort by Type") { ops in
            let kids = ops.proj[group]?.references("children") ?? []
            let products = ops.proj.project?.string("productRefGroup")
            func key(_ id: String) -> (Int, String, String) {
                let n = ops.displayName(id) ?? ""
                guard order == .type else { return (0, "", n) }
                let folder = ["PBXGroup", "PBXFileSystemSynchronizedRootGroup"].contains(ops.isa(id))
                return (folder ? 0 : 1, folder ? "" : (n as NSString).pathExtension.lowercased(), n)
            }
            // The Products group keeps its place at the end of the main group.
            let sortable = kids.filter { $0 != products }
            let sorted = sortable.sorted { a, b in
                let ka = key(a), kb = key(b)
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.1 != kb.1 { return ka.1.localizedStandardCompare(kb.1) == .orderedAscending }
                return ka.2.localizedStandardCompare(kb.2) == .orderedAscending
            }
            let result = sorted + kids.filter { $0 == products }
            if result != kids, var g = ops.proj[group] {
                g["children"] = .array(result.map(PlistValue.string))
                ops.proj[group] = g
            }
            return [.object(group)]
        }
    }
}
