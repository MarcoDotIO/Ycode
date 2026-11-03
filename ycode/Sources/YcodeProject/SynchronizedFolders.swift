import Foundation
import YcodePlist

/// The contents of one file-system-synchronized folder
/// (`PBXFileSystemSynchronizedRootGroup`), read from disk, and the build
/// membership its targets get from it. The PIF generator, the build server,
/// the project navigator and the File inspector all read folders through
/// this type, so they see the same files. See `specs/formats/pbxproj.md`
/// §Synchronized folders.
public struct SynchronizedFolder: Sendable, Equatable {
    /// One row of the folder's tree.
    public struct Entry: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A sub-folder, expanded.
            case group
            /// A file, a package-like folder (`.xcassets`, `.docc`, …) or a
            /// folder listed in `explicitFolders`: one item.
            case file
            /// The files of one name in the folder's `<region>.lproj`
            /// sub-folders, as one localized item; its children are the
            /// regions' files.
            case variantGroup
        }

        public var name: String
        /// Path relative to the folder. A variant group's path is the
        /// localized file's path without the `.lproj` component
        /// (`Base.lproj/Main.storyboard` → `Main.storyboard`).
        public var path: String
        public var kind: Kind
        /// File type (`lastKnownFileType` vocabulary); `explicitFileTypes`
        /// wins over the extension. Empty for groups.
        public var fileType: String
        /// A region file's region (the `.lproj` folder's name without the
        /// extension).
        public var region: String?
        public var children: [Entry]

        public init(name: String, path: String, kind: Kind, fileType: String = "", region: String? = nil, children: [Entry] = []) {
            self.name = name
            self.path = path
            self.kind = kind
            self.fileType = fileType
            self.region = region
            self.children = children
        }

        /// The key exception sets use for this item: its path, or
        /// `/Localized: <path>` for a localized item.
        public var membershipKey: String { kind == .variantGroup ? SynchronizedFolder.localizedPrefix + path : path }
    }

    /// The root group's object ID.
    public var groupID: String
    /// The folder's absolute path.
    public var directory: String
    /// Whether the folder exists on disk.
    public var exists: Bool
    /// The tree, in Finder-like name order (folders and files mixed).
    public var entries: [Entry]

    public static let localizedPrefix = "/Localized: "

    /// Names never listed: hidden names and build or user-state folders.
    public static let hiddenNames: Set<String> = [".DS_Store", ".git", ".build", ".swiftpm", "xcuserdata", "DerivedData"]

    /// Folders that are one item rather than a group (bundles and other
    /// package-like folders).
    public static let packageExtensions: Set<String> = [
        "xcassets", "icon", "xcdatamodeld", "xcdatamodel", "xcmappingmodel", "bundle", "framework", "xcframework", "docc",
        "rcproject", "realitycomposerpro", "app", "appex", "scnassets", "spriteatlas", "xcodeproj", "xcworkspace", "playground",
        "mlpackage", "xcstickers", "storekit",
    ]

    public static func isPackageLike(_ name: String) -> Bool {
        packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isHidden(_ name: String) -> Bool { name.hasPrefix(".") || hiddenNames.contains(name) }

    /// Reads a folder. `explicitFileTypes` (relative path → type) and
    /// `explicitFolders` (relative paths kept as one item) come from the
    /// root group.
    public init(groupID: String, directory: String, explicitFileTypes: [String: String] = [:], explicitFolders: Set<String> = []) {
        self.groupID = groupID
        self.directory = directory
        var isDir: ObjCBool = false
        exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDir) && isDir.boolValue
        entries = exists ? Self.list(directory, relative: "", types: explicitFileTypes, folders: explicitFolders, depth: 0) : []
    }

    static func sortedNames(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !isHidden($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func list(_ dir: String, relative: String, types: [String: String], folders: Set<String>, depth: Int) -> [Entry] {
        guard depth < 32 else { return [] }
        let fm = FileManager.default
        var out: [Entry] = []
        var variants: [String: Int] = [:]
        func join(_ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }
        for name in sortedNames(dir) {
            let full = dir + "/" + name
            let rel = join(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue && (name as NSString).pathExtension.lowercased() == "lproj" && !folders.contains(rel) {
                // `<region>.lproj/<file>` → the variant group `<file>`.
                let region = (name as NSString).deletingPathExtension
                for file in sortedNames(full) {
                    let fileRel = rel + "/" + file
                    let child = Entry(name: region, path: fileRel, kind: .file,
                                      fileType: types[fileRel] ?? BuildFileTypes.type(forPath: file), region: region)
                    if let i = variants[file] {
                        out[i].children.append(child)
                    } else {
                        variants[file] = out.count
                        out.append(Entry(name: file, path: join(file), kind: .variantGroup,
                                         fileType: BuildFileTypes.type(forPath: file), children: [child]))
                    }
                }
            } else if isDir.boolValue && !isPackageLike(name) && !folders.contains(rel) {
                out.append(Entry(name: name, path: rel, kind: .group,
                                 children: list(full, relative: rel, types: types, folders: folders, depth: depth + 1)))
            } else {
                let type = types[rel] ?? (folders.contains(rel) ? "folder" : BuildFileTypes.type(forPath: name))
                out.append(Entry(name: name, path: rel, kind: .file, fileType: type))
            }
        }
        // A variant group sorts by its file's name among the other rows.
        return out.enumerated().sorted { a, b in
            let c = a.element.name.localizedStandardCompare(b.element.name)
            return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
        }.map(\.element)
    }

    /// Every buildable item, depth-first: files, package-like folders,
    /// explicit folders and variant groups (not groups, not a variant
    /// group's region files).
    public var items: [Entry] {
        func walk(_ e: [Entry]) -> [Entry] { e.flatMap { $0.kind == .group ? walk($0.children) : [$0] } }
        return walk(entries)
    }

    /// Absolute paths of every file the folder lists (a package-like
    /// folder is one path; a variant group lists its region files).
    public var filePaths: [String] {
        items.flatMap { $0.kind == .variantGroup ? $0.children.map { directory + "/" + $0.path } : [directory + "/" + $0.path] }
    }

    /// The exception-set key of a path relative to the folder:
    /// `de.lproj/Extra.strings` → `/Localized: Extra.strings`.
    public static func membershipKey(forRelativePath rel: String) -> String {
        var parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 2, (parts[parts.count - 2] as NSString).pathExtension.lowercased() == "lproj" else { return rel }
        parts.remove(at: parts.count - 2)
        return localizedPrefix + parts.joined(separator: "/")
    }

    /// Whether an exception list names an item or a folder above it.
    static func listed(_ key: String, in list: Set<String>) -> Bool {
        if list.contains(key) { return true }
        let plain = key.hasPrefix(localizedPrefix) ? String(key.dropFirst(localizedPrefix.count)) : key
        var parts = plain.split(separator: "/").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if list.contains(parts.joined(separator: "/")) { return true }
        }
        return false
    }
}

/// One item of a synchronized folder in one target's build.
public struct SynchronizedMember: Sendable, Equatable {
    public enum Phase: Sendable, Equatable, Hashable {
        case sources, resources, headers, frameworks
        /// The phase a `PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet` names.
        case buildPhase(String)

        /// The `PBX*BuildPhase` class of a default phase.
        public var isa: String? {
            switch self {
            case .sources: "PBXSourcesBuildPhase"
            case .resources: "PBXResourcesBuildPhase"
            case .headers: "PBXHeadersBuildPhase"
            case .frameworks: "PBXFrameworksBuildPhase"
            case .buildPhase: nil
            }
        }
    }

    public enum HeaderVisibility: String, Sendable, Equatable { case `public`, `private` }

    public var folder: String
    public var entry: SynchronizedFolder.Entry
    public var phase: Phase
    public var headerVisibility: HeaderVisibility?
    /// `additionalCompilerFlagsByRelativePath`.
    public var compilerFlags: String?
    /// `attributesByRelativePath` (`CodeSignOnCopy`, `RemoveHeadersOnCopy`, `Weak`, …).
    public var attributes: [String]
    /// `platformFiltersByRelativePath` (`ios`, `macos`, `maccatalyst`, …).
    public var platformFilters: [String]

    public init(folder: String, entry: SynchronizedFolder.Entry, phase: Phase, headerVisibility: HeaderVisibility? = nil,
                compilerFlags: String? = nil, attributes: [String] = [], platformFilters: [String] = []) {
        self.folder = folder
        self.entry = entry
        self.phase = phase
        self.headerVisibility = headerVisibility
        self.compilerFlags = compilerFlags
        self.attributes = attributes
        self.platformFilters = platformFilters
    }
}

extension PBXProj {
    /// A root group's folder read from disk; nil when `id` is not a
    /// synchronized root group or its path does not resolve to a local one.
    public func synchronizedFolder(_ id: String, projectDirectory: URL, parents: [String: String]? = nil) -> SynchronizedFolder? {
        guard let g = self[id], g.isa == "PBXFileSystemSynchronizedRootGroup",
              let dir = resolvedPath(of: id, projectDirectory: projectDirectory, parents: parents), dir.hasPrefix("/") else { return nil }
        var types: [String: String] = [:]
        for (k, v) in g["explicitFileTypes"]?.dictionary ?? PlistDictionary() { if let s = v.string { types[k] = s } }
        return SynchronizedFolder(groupID: id, directory: URL(fileURLWithPath: dir).standardizedFileURL.path,
                                  explicitFileTypes: types, explicitFolders: Set(g.references("explicitFolders")))
    }

    /// The exception sets of a root group.
    func synchronizedExceptions(_ group: String) -> [PBXObject] {
        self[group]?.references("exceptions").compactMap { self[$0] } ?? []
    }

    /// The synchronized folders a target takes files from: its
    /// `fileSystemSynchronizedGroups`, then folders it does not list whose
    /// exception set for the target adds files to it, then folders with a
    /// build-phase exception set for one of its phases.
    public func synchronizedFolderIDs(ofTarget target: String) -> [String] {
        guard let t = self[target] else { return [] }
        var out = t.references("fileSystemSynchronizedGroups")
        let phases = Set(t.references("buildPhases"))
        for g in objects(isa: "PBXFileSystemSynchronizedRootGroup") where !out.contains(g.id) {
            let uses = synchronizedExceptions(g.id).contains { e in
                (e.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet" && e.string("target") == target)
                    || (e.isa == "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet" && phases.contains(e.string("buildPhase") ?? ""))
            }
            if uses { out.append(g.id) }
        }
        return out
    }

    /// The phase a synchronized item of `type` joins by default, or nil
    /// when it is not built (`hasHeadersPhase`: the target has a Headers
    /// phase, so project headers join it).
    static func defaultPhase(type: String, path: String, header visibility: SynchronizedMember.HeaderVisibility?,
                             hasHeadersPhase: Bool) -> SynchronizedMember.Phase? {
        switch BuildFileTypes.phase(forType: type, path: path) {
        case "sources": return .sources
        case "resources": return .resources
        case "frameworks": return .frameworks
        case "headers": return visibility != nil || hasHeadersPhase ? .headers : nil
        default: return nil
        }
    }

    /// Whether a target is a member of a synchronized item: in a folder the
    /// target lists, unless its exception set names the item (or a folder
    /// above it); in a folder it does not list, only when its exception set
    /// names it.
    public func isSynchronizedMember(key: String, folder: String, target: String) -> Bool {
        let owns = self[target]?.references("fileSystemSynchronizedGroups").contains(folder) ?? false
        let set = synchronizedExceptions(folder).first { $0.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet" && $0.string("target") == target }
        let listed = SynchronizedFolder.listed(key, in: Set(set?.references("membershipExceptions") ?? []))
        return owns != listed
    }

    /// The items of `folder` in `target`'s build and the phase each joins.
    /// Membership: `isSynchronizedMember`. Phase: by file type (sources;
    /// resources; libraries and frameworks link; headers when the target
    /// has a Headers phase or the header is public or private); a
    /// build-phase exception set for one of the target's phases moves the
    /// items it names into that phase (a linked library also stays linked).
    public func synchronizedMembers(ofTarget target: String, folder: SynchronizedFolder) -> [SynchronizedMember] {
        guard let t = self[target] else { return [] }
        let phases = t.references("buildPhases")
        let hasHeaders = phases.contains { self[$0]?.isa == "PBXHeadersBuildPhase" }
        let exceptions = synchronizedExceptions(folder.groupID)
        let set = exceptions.first { $0.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet" && $0.string("target") == target }
        let publicHeaders = Set(set?.references("publicHeaders") ?? [])
        let privateHeaders = Set(set?.references("privateHeaders") ?? [])
        func dictionary(_ key: String, _ obj: PBXObject?) -> PlistDictionary { obj?[key]?.dictionary ?? PlistDictionary() }
        let flags = dictionary("additionalCompilerFlagsByRelativePath", set)
        let attributes = dictionary("attributesByRelativePath", set)
        let filters = dictionary("platformFiltersByRelativePath", set)
        let phaseSets = exceptions.filter {
            $0.isa == "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet" && phases.contains($0.string("buildPhase") ?? "")
        }
        var out: [SynchronizedMember] = []
        for item in folder.items {
            let key = item.membershipKey
            let moved = phaseSets.filter { SynchronizedFolder.listed(key, in: Set($0.references("membershipExceptions"))) }
            let member = isSynchronizedMember(key: key, folder: folder.groupID, target: target)
            guard member || !moved.isEmpty else { continue }
            let visibility: SynchronizedMember.HeaderVisibility? =
                publicHeaders.contains(key) ? .public : privateHeaders.contains(key) ? .private : nil
            var base = SynchronizedMember(folder: folder.groupID, entry: item, phase: .resources, headerVisibility: visibility,
                                          compilerFlags: flags[key]?.string,
                                          attributes: attributes[key]?.array?.compactMap(\.string) ?? [],
                                          platformFilters: filters[key]?.array?.compactMap(\.string) ?? [])
            let defaultPhase = Self.defaultPhase(type: item.fileType, path: item.path, header: visibility, hasHeadersPhase: hasHeaders)
            if member, let p = defaultPhase, moved.isEmpty || p == .frameworks {
                base.phase = p
                out.append(base)
            }
            for m in moved {
                var copy = base
                copy.phase = .buildPhase(m.string("buildPhase") ?? "")
                copy.headerVisibility = nil
                copy.compilerFlags = nil
                let a = dictionary("attributesByRelativePath", m)[key]?.array?.compactMap(\.string)
                if let a { copy.attributes = a }
                let f = dictionary("platformFiltersByRelativePath", m)[key]?.array?.compactMap(\.string)
                if let f { copy.platformFilters = f }
                out.append(copy)
            }
        }
        return out
    }

    /// Every synchronized member of a target, folder by folder, with the
    /// folders it reads (nil entries: folders that do not resolve).
    public func synchronizedMembers(ofTarget target: String, projectDirectory: URL, parents: [String: String]? = nil)
        -> [(folder: SynchronizedFolder, members: [SynchronizedMember])] {
        let parents = parents ?? parentMap()
        return synchronizedFolderIDs(ofTarget: target).compactMap { id in
            synchronizedFolder(id, projectDirectory: projectDirectory, parents: parents).map { ($0, synchronizedMembers(ofTarget: target, folder: $0)) }
        }
    }
}

/// File types by extension for files found on disk (synchronized folders,
/// untyped references), in the `lastKnownFileType` vocabulary, and the
/// build phase each type joins in a synchronized folder.
public enum BuildFileTypes {
    public static let byExtension: [String: String] = [
        "swift": "sourcecode.swift", "c": "sourcecode.c.c", "m": "sourcecode.c.objc", "mm": "sourcecode.cpp.objcpp",
        "cpp": "sourcecode.cpp.cpp", "cc": "sourcecode.cpp.cpp", "cxx": "sourcecode.cpp.cpp", "h": "sourcecode.c.h",
        "hpp": "sourcecode.cpp.h", "hh": "sourcecode.cpp.h", "metal": "sourcecode.metal", "s": "sourcecode.asm",
        "xcassets": "folder.assetcatalog", "icon": "folder.iconcomposer.icon",
        "storyboard": "file.storyboard", "xib": "file.xib", "strings": "text.plist.strings", "stringsdict": "text.plist.stringsdict",
        "xcstrings": "text.json.xcstrings", "plist": "text.plist.xml", "json": "text.json", "xcconfig": "text.xcconfig",
        "entitlements": "text.plist.entitlements", "png": "image.png", "jpg": "image.jpeg", "jpeg": "image.jpeg", "gif": "image.gif",
        "pdf": "image.pdf", "md": "net.daringfireball.markdown", "txt": "text", "xcdatamodeld": "wrapper.xcdatamodeld",
        "xcdatamodel": "wrapper.xcdatamodel", "mlmodel": "file.mlmodel", "mlpackage": "folder.mlpackage",
        "intentdefinition": "file.intentdefinition", "docc": "folder.documentationcatalog", "xctestplan": "text",
        "rcproject": "file.rcproject", "usdz": "file.usdz", "lproj": "folder", "bundle": "wrapper.plug-in",
        "framework": "wrapper.framework", "xcframework": "wrapper.xcframework", "a": "archive.ar", "dylib": "compiled.mach-o.dylib",
        "tbd": "sourcecode.text-based-dylib-definition", "app": "wrapper.application", "appex": "wrapper.app-extension",
        "modulemap": "sourcecode.module-map", "y": "sourcecode.yacc", "l": "sourcecode.lex", "mig": "sourcecode.mig",
        "defs": "sourcecode.mig", "iig": "sourcecode.iig",
    ]

    public static func type(forPath path: String) -> String {
        byExtension[(path as NSString).pathExtension.lowercased()] ?? "file"
    }

    /// The phase a synchronized-folder item of `type` joins: "sources",
    /// "resources", "frameworks", "headers" or nil (not built).
    public static func phase(forType type: String, path: String) -> String? {
        switch type {
        case "wrapper.framework", "wrapper.xcframework", "archive.ar", "compiled.mach-o.dylib",
             "sourcecode.text-based-dylib-definition":
            return "frameworks"
        case "sourcecode.c.h", "sourcecode.cpp.h":
            return "headers"
        case "text.xcconfig", "text.plist.entitlements", "sourcecode.module-map":
            return nil
        case "wrapper.xcdatamodeld", "wrapper.xcdatamodel", "file.mlmodel", "folder.mlpackage", "file.intentdefinition",
             "folder.documentationcatalog":
            return "sources"
        case "text.plist.xml" where (path as NSString).lastPathComponent == "Info.plist":
            return nil
        default:
            if path.hasSuffix(".xctestplan") { return nil }
            return type.hasPrefix("sourcecode.") ? "sources" : "resources"
        }
    }
}
