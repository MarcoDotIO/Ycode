import Foundation
import YcodePlist
import YcodeProject

/// A file's target membership in a project (the File inspector's Target
/// Membership section, `specs/ide/reference-ui-5.md` §7.3). A file belongs
/// to a target when one of the target's build phases holds a build file
/// for its reference, or when it lies in one of the target's synchronized
/// folders and no exception set of that folder for the target excludes it
/// (`specs/formats/pbxproj.md`).
public struct TargetMembership: Equatable, Sendable {
    public var targetID: String
    public var name: String
    public var isMember: Bool
    /// Membership can be changed here (a file reference, or a synchronized
    /// folder the target already has).
    public var isEditable: Bool
    /// The membership kind shown under the target's name.
    public var kind: String { "Default" }
}

extension PBXProj {
    /// Where a file sits in the project: its file reference, or the
    /// synchronized folder holding it with its path inside that folder.
    enum FilePlace { case reference(String), synchronized(group: String, relative: String) }

    func place(ofFile path: String, projectDirectory: URL) -> FilePlace? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let parents = parentMap()
        for ref in objects.values where ref.isa == "PBXFileReference" {
            if let p = resolvedPath(of: ref.id, projectDirectory: projectDirectory, parents: parents),
               URL(fileURLWithPath: p).standardizedFileURL.path == target { return .reference(ref.id) }
        }
        for g in objects.values where g.isa == "PBXFileSystemSynchronizedRootGroup" {
            guard let p = resolvedPath(of: g.id, projectDirectory: projectDirectory, parents: parents) else { continue }
            let root = URL(fileURLWithPath: p).standardizedFileURL.path + "/"
            if target.hasPrefix(root) { return .synchronized(group: g.id, relative: String(target.dropFirst(root.count))) }
        }
        return nil
    }

    /// The exception set of a synchronized folder for one target.
    func exceptionSet(group: String, target: String) -> PBXObject? {
        self[group]?.references("exceptions").compactMap { self[$0] }
            .first { $0.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet" && $0.string("target") == target }
    }

    /// Every target of the project with whether `path` belongs to it.
    public func targetMemberships(ofFile path: String, projectDirectory: URL) -> [TargetMembership] {
        let place = place(ofFile: path, projectDirectory: projectDirectory)
        return targets.map { t in
            let name = t.string("name") ?? t.id
            switch place {
            case .reference(let ref)?:
                let member = buildPhases(ofTarget: t.id).contains { phase in
                    phase.references("files").contains { fileReference(ofBuildFile: $0)?.id == ref }
                }
                return TargetMembership(targetID: t.id, name: name, isMember: member, isEditable: true)
            case .synchronized(let group, let rel)?:
                let owns = t.references("fileSystemSynchronizedGroups").contains(group)
                let excluded = exceptionSet(group: group, target: t.id)?.references("membershipExceptions").contains(rel) ?? false
                return TargetMembership(targetID: t.id, name: name, isMember: owns && !excluded, isEditable: owns)
            case nil:
                return TargetMembership(targetID: t.id, name: name, isMember: false, isEditable: false)
            }
        }
    }

    /// Adds `path` to a target, or removes it. File references get or lose
    /// a build file in the target's Sources phase (source files) or
    /// Resources phase (others); files in a synchronized folder are taken
    /// out of, or put into, the folder's exception set for the target.
    /// Returns whether the project changed.
    @discardableResult
    public mutating func setMembership(ofFile path: String, target: String, member: Bool, projectDirectory: URL) -> Bool {
        guard self[target] != nil, let place = place(ofFile: path, projectDirectory: projectDirectory) else { return false }
        switch place {
        case .reference(let ref):
            let phases = buildPhases(ofTarget: target)
            if member {
                guard !phases.contains(where: { $0.references("files").contains { fileReference(ofBuildFile: $0)?.id == ref } }) else { return false }
                let isa = Self.isSource(path) ? "PBXSourcesBuildPhase" : "PBXResourcesBuildPhase"
                let phase = phases.first { $0.isa == isa }?.id ?? addBuildPhase(isa, to: target)
                addBuildFile(fileReference: ref, to: phase)
            } else {
                var changed = false
                for phase in phases {
                    for bf in phase.references("files") where fileReference(ofBuildFile: bf)?.id == ref { removeBuildFile(bf); changed = true }
                }
                return changed
            }
        case .synchronized(let group, let rel):
            guard self[target]?.references("fileSystemSynchronizedGroups").contains(group) == true else { return false }
            if var set = exceptionSet(group: group, target: target) {
                var list = set.references("membershipExceptions")
                if member {
                    guard list.contains(rel) else { return false }
                    list.removeAll { $0 == rel }
                } else {
                    guard !list.contains(rel) else { return false }
                    list.append(rel)
                    list.sort()
                }
                if list.isEmpty && set.attributes.keys.allSatisfy({ ["isa", "membershipExceptions", "target"].contains($0) }) {
                    // An empty set says nothing: drop it from the folder.
                    if var g = self[group] {
                        let rest = g.references("exceptions").filter { $0 != set.id }
                        g["exceptions"] = rest.isEmpty ? nil : .array(rest.map(PlistValue.string))
                        self[group] = g
                    }
                    self[set.id] = nil
                } else {
                    set["membershipExceptions"] = .array(list.map(PlistValue.string))
                    self[set.id] = set
                }
            } else {
                guard !member else { return false }
                let id = makeObjectID()
                self[id] = PBXObject(id: id, attributes: PlistDictionary([
                    ("isa", .string("PBXFileSystemSynchronizedBuildFileExceptionSet")),
                    ("membershipExceptions", .array([.string(rel)])),
                    ("target", .string(target)),
                ]))
                if var g = self[group] {
                    g["exceptions"] = .array((g.references("exceptions") + [id]).map(PlistValue.string))
                    self[group] = g
                }
            }
        }
        return true
    }

    /// Adds an empty build phase of class `isa` at the end of a target's phases.
    mutating func addBuildPhase(_ isa: String, to target: String) -> String {
        let id = makeObjectID()
        self[id] = PBXObject(id: id, attributes: PlistDictionary([
            ("isa", .string(isa)), ("buildActionMask", .string("2147483647")), ("files", .array([])),
            ("runOnlyForDeploymentPostprocessing", .string("0")),
        ]))
        if var t = self[target] {
            t["buildPhases"] = .array((t.references("buildPhases") + [id]).map(PlistValue.string))
            self[target] = t
        }
        return id
    }

    static func isSource(_ path: String) -> Bool {
        ["swift", "m", "mm", "c", "cc", "cpp", "cxx", "metal", "s", "intentdefinition"].contains((path as NSString).pathExtension.lowercased())
    }
}
