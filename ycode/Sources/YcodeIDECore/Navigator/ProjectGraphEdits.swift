import Foundation
import YcodePlist
import YcodeProject

/// Object-graph edits behind the project navigator's file operations
/// (`specs/ide/navigators.md` §Ycode implementation). They touch only the
/// objects they change, so the writer keeps every other object's bytes.
extension PBXProj {
    /// The group a navigator row stands for: the project object means the
    /// main group.
    public func groupID(_ id: String) -> String {
        id == rootObject ? (project?.string("mainGroup") ?? id) : id
    }

    /// Classes whose `children` the navigator edits.
    static let editableGroupClasses: Set<String> = ["PBXGroup"]
    static let groupClasses: Set<String> = ["PBXGroup", "PBXVariantGroup", "XCVersionGroup"]

    /// Inserts `child` into a group's `children` at `index` (nil or past
    /// the end: at the end, except that in the main group the Products
    /// group stays last).
    mutating func insertChild(_ child: String, into group: String, at index: Int?) {
        guard var g = self[group] else { return }
        var kids = g.references("children")
        var end = kids.count
        if group == project?.string("mainGroup"), let products = project?.string("productRefGroup"), kids.last == products { end -= 1 }
        let i = min(max(0, index ?? end), kids.count)
        kids.insert(child, at: i)
        g["children"] = .array(kids.map(PlistValue.string))
        self[group] = g
    }

    /// Takes `child` out of its group; returns the group and the index it had.
    @discardableResult
    mutating func detachChild(_ child: String) -> (group: String, index: Int)? {
        for (gid, var g) in objects {
            let kids = g.references("children")
            guard let i = kids.firstIndex(of: child) else { continue }
            g["children"] = .array(kids.filter { $0 != child }.map(PlistValue.string))
            self[gid] = g
            return (gid, i)
        }
        return nil
    }

    /// Removes an object and everything under it: a group's children, the
    /// build files that point at any of them, a synchronized folder's
    /// exception sets and its place in targets, and their entries in
    /// groups.
    mutating func removeTree(_ id: String) {
        guard let obj = self[id] else { return }
        for child in obj.references("children") { removeTree(child) }
        if obj.isa == "PBXFileSystemSynchronizedRootGroup" {
            for e in obj.references("exceptions") { self[e] = nil }
            for t in targets where t.references("fileSystemSynchronizedGroups").contains(id) {
                var t = t
                let rest = t.references("fileSystemSynchronizedGroups").filter { $0 != id }
                t["fileSystemSynchronizedGroups"] = rest.isEmpty ? nil : .array(rest.map(PlistValue.string))
                self[t.id] = t
            }
        }
        for bf in objects.values where bf.isa == "PBXBuildFile" && bf.string("fileRef") == id { removeBuildFile(bf.id) }
        detachChild(id)
        self[id] = nil
    }

    /// Adds a new object at `index` in a group; returns its ID.
    mutating func addObject(_ attributes: [(String, PlistValue)], to group: String, at index: Int?) -> String {
        let id = makeObjectID()
        self[id] = PBXObject(id: id, attributes: PlistDictionary(attributes))
        insertChild(id, into: group, at: index)
        return id
    }

    /// A new group: with a folder (`path`) or without one (`name`).
    mutating func addGroup(named name: String, withFolder: Bool, to group: String, at index: Int?) -> String {
        addObject([("isa", .string("PBXGroup")), ("children", .array([])),
                   (withFolder ? "path" : "name", .string(name)), ("sourceTree", .string("<group>"))], to: group, at: index)
    }

    /// A new synchronized folder at `path` (relative to the group).
    mutating func addSynchronizedFolder(path: String, to group: String, at index: Int?, targets: [String]) -> String {
        let id = addObject([("isa", .string("PBXFileSystemSynchronizedRootGroup")), ("path", .string(path)),
                            ("sourceTree", .string("<group>"))], to: group, at: index)
        for t in targets { addSynchronizedFolder(id, toTarget: t) }
        return id
    }

    mutating func addSynchronizedFolder(_ folder: String, toTarget t: String) {
        guard var target = self[t], !target.references("fileSystemSynchronizedGroups").contains(folder) else { return }
        target["fileSystemSynchronizedGroups"] = .array((target.references("fileSystemSynchronizedGroups") + [folder]).map(PlistValue.string))
        self[t] = target
    }

    /// A file reference at `index` (`path` relative to the group). A
    /// folder reference has the type `folder`.
    mutating func addReference(path: String, fileType: String, to group: String, at index: Int?) -> String {
        let id = addObject([("isa", .string("PBXFileReference")), ("lastKnownFileType", .string(fileType)),
                            ("path", .string(path)), ("sourceTree", .string("<group>"))], to: group, at: index)
        setPath(path, of: id)
        return id
    }

    /// Sets an item's `path`. A path through other folders keeps the
    /// item's name in `name`; a plain one needs no `name` equal to it.
    mutating func setPath(_ path: String, of id: String) {
        guard var obj = self[id] else { return }
        let display = obj.string("name") ?? obj.string("path").map { ($0 as NSString).lastPathComponent }
        obj["path"] = .string(path)
        if path.contains("/") {
            if obj["name"] == nil { obj["name"] = .string(display ?? (path as NSString).lastPathComponent) }
        } else if obj.string("name") == path {
            obj["name"] = nil
        }
        self[id] = obj
    }

    /// The build phase class a file joins in a target, by type (nil: none,
    /// as for headers, xcconfig files, entitlements and Info.plist).
    static func buildPhaseClass(forFile name: String, isFolderReference: Bool = false) -> String? {
        if isFolderReference { return "PBXResourcesBuildPhase" }
        let ext = (name as NSString).pathExtension.lowercased()
        if FileCreator.sourceExtensions.contains(ext) || ext == "xcdatamodel" { return "PBXSourcesBuildPhase" }
        if ["framework", "a", "dylib", "tbd", "xcframework"].contains(ext) { return "PBXFrameworksBuildPhase" }
        if ["h", "hpp", "hh", "xcconfig", "entitlements", "xctestplan", "pch", "modulemap"].contains(ext) || name == "Info.plist" { return nil }
        return "PBXResourcesBuildPhase"
    }

    /// Adds a reference's build file to each target's matching phase
    /// (creating the phase when the target has none).
    mutating func addToTargets(_ ref: String, fileName: String, targets: [String], isFolderReference: Bool = false) {
        guard let isa = Self.buildPhaseClass(forFile: fileName, isFolderReference: isFolderReference) else { return }
        for t in targets where self[t] != nil {
            let phase = buildPhases(ofTarget: t).first { $0.isa == isa }?.id ?? addBuildPhase(isa, to: t)
            guard !(self[phase]?.references("files") ?? []).contains(where: { self[$0]?.string("fileRef") == ref }) else { continue }
            addBuildFile(fileReference: ref, to: phase)
        }
    }

    /// The targets whose build phases hold a build file for `ref`.
    func targetsContaining(_ ref: String) -> [String] {
        targets.filter { t in buildPhases(ofTarget: t.id).contains { $0.references("files").contains { self[$0]?.string("fileRef") == ref } } }
            .map(\.id)
    }

    // MARK: Synchronized folders' exception sets

    /// Rewrites the paths a folder's exception sets name: `old` (and any
    /// path under it) becomes `new`; nil drops them. Empty sets that say
    /// nothing else are removed (as `setMembership` does).
    mutating func rewriteExceptionPaths(in folder: String, from old: String, to new: String?) {
        guard var root = self[folder] else { return }
        func map(_ p: String) -> String?? {
            if p == old { return .some(new) }
            if p.hasPrefix(old + "/") { return .some(new.map { $0 + p.dropFirst(old.count) }) }
            return .none
        }
        var kept: [String] = []
        for sid in root.references("exceptions") {
            guard var set = self[sid] else { continue }
            var changed = false
            for (key, value) in set.attributes {
                if case .array(let list) = value, list.allSatisfy({ $0.string != nil }) {
                    var out: [String] = []
                    for p in list.compactMap(\.string) {
                        if case .some(let m) = map(p) { changed = true; if let m { out.append(m) } } else { out.append(p) }
                    }
                    let wasSorted = list.compactMap(\.string) == list.compactMap(\.string).sorted()
                    set[key] = .array((wasSorted ? out.sorted() : out).map(PlistValue.string))
                } else if case .dictionary(let d) = value {
                    var out = PlistDictionary()
                    var touched = false
                    for (k, v) in d {
                        if case .some(let m) = map(k) { touched = true; if let m { out[m] = v } } else { out[k] = v }
                    }
                    if touched { changed = true; set[key] = .dictionary(out) }
                }
            }
            guard changed else { kept.append(sid); continue }
            let empty = set.attributes.allSatisfy { key, value in
                key == "isa" || key == "target" || key == "buildPhase" || (value.array?.isEmpty ?? false) || (value.dictionary?.isEmpty ?? false)
            }
            if empty {
                self[sid] = nil
            } else {
                self[sid] = set
                kept.append(sid)
            }
        }
        if kept != root.references("exceptions") {
            root["exceptions"] = kept.isEmpty ? nil : .array(kept.map(PlistValue.string))
            self[folder] = root
        }
    }
}

/// Paths relative to a directory, with ".." where needed.
enum RelativePath {
    static func from(_ dir: String, to path: String) -> String {
        let a = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents
        let b = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        let parts = Array(repeating: "..", count: a.count - i) + b[i...]
        return parts.isEmpty ? "" : parts.joined(separator: "/")
    }

    /// Whether `path` is `dir` or inside it.
    static func isInside(_ path: String, _ dir: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path, d = URL(fileURLWithPath: dir).standardizedFileURL.path
        return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }
}
