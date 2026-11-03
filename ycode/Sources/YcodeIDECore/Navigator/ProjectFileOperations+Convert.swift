import Foundation
import YcodePlist
import YcodeProject

/// Edit ▸ Convert ▸ To Group, To Folder and Preflight Conversion to Folder
/// (`specs/ide/navigators.md` §Ycode implementation). A conversion keeps
/// every file's target membership.
extension ProjectFileOperations {
    /// To Group: a synchronized folder becomes a group with a folder,
    /// holding a reference for each item on disk (sub-folders become
    /// groups), each in the targets it was in through the folder.
    public mutating func convertToGroup(_ item: ProjectItem) throws -> ProjectEdit {
        guard case .object(let folder) = item, isa(folder) == "PBXFileSystemSynchronizedRootGroup", let dir = resolved(folder),
              let obj = proj[folder], let place = proj.detachChildPreview(folder) else {
            throw NavigatorEditError.notAllowed("Only a folder can be converted to a group")
        }
        return try edit("Convert to Group") { ops in
            // Memberships before the folder goes.
            var members: [String: [String]] = [:]
            func collect(_ path: String) {
                for child in NavigatorTree.directory(path) {
                    guard let p = child.path else { continue }
                    if child.kind == .folder { collect(p); continue }
                    members[p] = ops.proj.targetMemberships(ofFile: p, projectDirectory: ops.rootDirectory).filter(\.isMember).map(\.targetID)
                }
            }
            collect(dir)
            ops.proj.removeTree(folder)
            let g = ops.proj.addGroup(named: obj.string("path") ?? "", withFolder: true, to: place.group, at: place.index)
            if let name = obj.string("name"), var group = ops.proj[g] {
                group["name"] = .string(name)
                ops.proj[g] = group
            }
            func add(_ path: String, to group: String) {
                for child in NavigatorTree.directory(path) {
                    guard let p = child.path else { continue }
                    let name = (p as NSString).lastPathComponent
                    if child.kind == .folder {
                        add(p, to: ops.proj.addGroup(named: name, withFolder: true, to: group, at: nil))
                    } else {
                        let ref = ops.proj.addReference(path: name, fileType: PBXProj.fileType(forPath: name), to: group, at: nil)
                        ops.proj.addToTargets(ref, fileName: name, targets: members[p] ?? [])
                    }
                }
            }
            add(dir, to: g)
            return [.object(g)]
        }
    }

    /// Why a group cannot become a synchronized folder (empty: it can).
    /// The group must have its own folder, and everything under it must be
    /// plain groups with folders and references named like their files,
    /// with no build settings of their own.
    public func folderConversionProblems(_ item: ProjectItem) -> [String] {
        guard case .object(let id) = item, let project, let group = project[project.groupID(id)] else { return ["Select a group."] }
        guard group.isa == "PBXGroup", group.id != project.groupID(project.rootObject) else { return ["Only a group can be converted to a folder."] }
        var problems: [String] = []
        func name(_ o: PBXObject) -> String { o.string("name") ?? o.string("path") ?? o.id }
        func check(_ o: PBXObject) {
            let path = o.string("path") ?? ""
            if (o.string("sourceTree") ?? "<group>") != "<group>" || path.isEmpty || path.contains("/") {
                problems.append("“\(name(o))” is not in its group's folder.")
            } else if let abs = resolved(o.id), !FileManager.default.fileExists(atPath: abs) {
                problems.append("“\(name(o))” is missing on disk.")
            }
            switch o.isa {
            case "PBXGroup": for c in o.references("children") { if let child = project[c] { check(child) } }
            case "PBXFileReference", "XCVersionGroup":
                for bf in project.objects.values where bf.isa == "PBXBuildFile" && bf.string("fileRef") == o.id && bf["settings"] != nil {
                    problems.append("“\(name(o))” has build settings of its own.")
                }
            default: problems.append("“\(name(o))” cannot be in a folder (\(o.isa)).")
            }
        }
        check(group)
        return problems
    }

    /// To Folder: a group (see `folderConversionProblems`) becomes a
    /// synchronized folder, in every target any of its files was in; a
    /// file on disk not in one of those targets gets an exception there.
    public mutating func convertToFolder(_ item: ProjectItem) throws -> ProjectEdit {
        let problems = folderConversionProblems(item)
        guard problems.isEmpty, case .object(let id) = item, let gid = project.map({ $0.groupID(id) }), let group = proj[gid],
              let dir = resolved(gid), let place = proj.detachChildPreview(gid) else {
            throw NavigatorEditError.notAllowed(problems.joined(separator: " "))
        }
        return try edit("Convert to Folder") { ops in
            var refs: [String] = []
            func walk(_ id: String) {
                guard let o = ops.proj[id] else { return }
                if o.isa == "PBXGroup" { o.references("children").forEach(walk) } else { refs.append(id) }
            }
            walk(gid)
            let byRef = refs.map { ($0, ops.resolved($0) ?? "", ops.proj.targetsContaining($0)) }
            let union = ops.proj.targets.map(\.id).filter { t in byRef.contains { $0.2.contains(t) } }
            ops.proj.removeTree(gid)
            let folder = ops.proj.addSynchronizedFolder(path: group.string("path") ?? "", to: place.group, at: place.index, targets: union)
            if let name = group.string("name"), var f = ops.proj[folder] {
                f["name"] = .string(name)
                ops.proj[folder] = f
            }
            // Every file on disk now belongs to all of `union`: exclude
            // it where it was not a member.
            let member = Dictionary(byRef.map { ($0.1, $0.2) }, uniquingKeysWith: { $0 + $1 })
            func files(_ path: String) -> [String] {
                NavigatorTree.directory(path).flatMap { c -> [String] in
                    guard let p = c.path else { return [] }
                    return c.kind == .folder ? files(p) : [p]
                }
            }
            for f in files(dir) { ops.exclude(f, exceptFor: member[f] ?? []) }
            return [.object(folder)]
        }
    }
}

extension PBXProj {
    /// The group holding `child` and its index there, without changing anything.
    func detachChildPreview(_ child: String) -> (group: String, index: Int)? {
        for g in objects.values {
            if let i = g.references("children").firstIndex(of: child) { return (g.id, i) }
        }
        return nil
    }
}
