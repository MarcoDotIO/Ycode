import Foundation
import YcodePlist
import YcodeProject
import YcodeStrings

/// A `.strings`/`.stringsdict` table of a project: Edit ▸ Convert ▸ To
/// String Catalogs… lists these. See `specs/ide/string-catalog.md`, "Ycode
/// implementation".
public struct LegacyStringTable: Equatable, Sendable, Identifiable {
    /// The table name (`Localizable`, `InfoPlist`).
    public var name: String
    /// The folder holding the table's `.lproj` folders; the catalog goes here.
    public var directory: String
    /// Every file of the table: (language, path), `.strings` and `.stringsdict`.
    public var files: [File]
    /// The variant groups that hold the files (none in a synchronized folder).
    public var groupIDs: [String]
    /// The targets the table is in, and their names.
    public var targetIDs: [String]
    public var targetNames: [String]

    public struct File: Equatable, Sendable {
        public var language: String
        public var path: String
    }

    public var id: String { (directory as NSString).appendingPathComponent(name) }
    public var catalogPath: String { (directory as NSString).appendingPathComponent(name + ".xcstrings") }
    public var languages: [String] { Array(Set(files.map(\.language))).sorted() }
}

extension ProjectFileOperations {
    /// The project's development region (`developmentRegion`), else `en`.
    public var developmentRegion: String {
        guard let project, let root = project[project.rootObject] else { return "en" }
        return root.string("developmentRegion") ?? "en"
    }

    /// The `.strings`/`.stringsdict` tables of the project: variant groups
    /// named `<table>.strings` or `<table>.stringsdict` (not the strings of
    /// Interface Builder files), and `.lproj` tables inside synchronized
    /// folders. Grouped by folder and name, sorted by path.
    public func legacyStringTables() -> [LegacyStringTable] {
        guard let project else { return [] }
        let parents = project.parentMap()
        var tables: [String: LegacyStringTable] = [:]
        func targets(of ids: [String]) -> [String] { project.targets.map(\.id).filter { t in ids.contains(t) } }
        func add(name: String, file: LegacyStringTable.File, group: String?, targetIDs: [String]) {
            let lproj = (file.path as NSString).deletingLastPathComponent
            guard lproj.hasSuffix(".lproj") else { return }
            let dir = (lproj as NSString).deletingLastPathComponent
            let key = (dir as NSString).appendingPathComponent(name)
            var t = tables[key] ?? LegacyStringTable(name: name, directory: dir, files: [], groupIDs: [], targetIDs: [], targetNames: [])
            if !t.files.contains(file) { t.files.append(file) }
            if let group, !t.groupIDs.contains(group) { t.groupIDs.append(group) }
            for id in targetIDs where !t.targetIDs.contains(id) { t.targetIDs.append(id) }
            tables[key] = t
        }
        for g in project.objects.values where g.isa == "PBXVariantGroup" {
            let groupName = g.string("name") ?? g.string("path") ?? ""
            let ext = (groupName as NSString).pathExtension
            guard ext == "strings" || ext == "stringsdict" else { continue }
            let name = (groupName as NSString).deletingPathExtension
            let inTargets = proj.targetsContaining(g.id)
            for c in g.references("children") {
                guard let child = project[c], let path = project.resolvedPath(of: c, projectDirectory: rootDirectory, parents: parents) else { continue }
                let lproj = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let language = child.string("name") ?? String(lproj.dropLast(".lproj".count))
                add(name: name, file: .init(language: language, path: path), group: g.id, targetIDs: inTargets)
            }
        }
        // Synchronized folders: the tables on disk.
        for f in project.objects.values where f.isa == "PBXFileSystemSynchronizedRootGroup" {
            guard let root = resolved(f.id) else { continue }
            let inTargets = targets(of: project.targets.filter { $0.references("fileSystemSynchronizedGroups").contains(f.id) }.map(\.id))
            let e = FileManager.default.enumerator(atPath: root)
            while let rel = e?.nextObject() as? String {
                let ext = (rel as NSString).pathExtension
                guard ext == "strings" || ext == "stringsdict" else { continue }
                let lproj = ((rel as NSString).deletingLastPathComponent as NSString).lastPathComponent
                guard lproj.hasSuffix(".lproj") else { continue }
                let path = (root as NSString).appendingPathComponent(rel)
                add(name: ((rel as NSString).lastPathComponent as NSString).deletingPathExtension,
                    file: .init(language: String(lproj.dropLast(".lproj".count)), path: path), group: nil, targetIDs: inTargets)
            }
        }
        let names = Dictionary(project.targets.map { ($0.id, $0.string("name") ?? $0.id) }, uniquingKeysWith: { a, _ in a })
        return tables.values.map { t in
            var t = t
            t.files.sort { ($0.language, $0.path) < ($1.language, $1.path) }
            t.targetNames = t.targetIDs.map { names[$0] ?? $0 }
            return t
        }.sorted { $0.id < $1.id }
    }

    /// The catalog a table converts to (and the converter's warnings).
    public func catalog(for table: LegacyStringTable, sourceLanguage: String? = nil) throws -> (StringCatalog, [StringCatalogConverter.Warning]) {
        let source = sourceLanguage ?? developmentRegion
        var byLanguage: [String: (strings: String?, stringsdict: String?)] = [:]
        for f in table.files {
            // `Base.lproj` strings belong to the development language.
            let lang = f.language == "Base" ? source : f.language
            var e = byLanguage[lang] ?? (nil, nil)
            if f.path.hasSuffix(".stringsdict") { e.stringsdict = f.path } else { e.strings = f.path }
            byLanguage[lang] = e
        }
        let tables = try byLanguage.keys.sorted().map { lang in
            try StringCatalogConverter.LanguageTable.read(language: lang, strings: byLanguage[lang]!.strings, stringsdict: byLanguage[lang]!.stringsdict)
        }
        return StringCatalogConverter.catalog(sourceLanguage: source, tables: tables)
    }

    /// To String Catalogs: each table becomes `<folder>/<table>.xcstrings`
    /// in the table's targets, where its first variant group was; the
    /// variant groups leave the project and their files (and `.lproj`
    /// folders left empty) go to the trash. Undoable.
    public mutating func convertToStringCatalogs(_ tables: [LegacyStringTable], sourceLanguage: String? = nil) throws -> ProjectEdit {
        guard isProject, !tables.isEmpty else { throw NavigatorEditError.notAllowed("Select the string tables to convert.") }
        for t in tables where FileManager.default.fileExists(atPath: t.catalogPath) {
            throw NavigatorEditError.notAllowed("“\((t.catalogPath as NSString).lastPathComponent)” already exists in “\(t.directory)”.")
        }
        let catalogs = try tables.map { try catalog(for: $0, sourceLanguage: sourceLanguage).0 }
        return try edit(tables.count == 1 ? "Convert to String Catalog" : "Convert to String Catalogs") { ops in
            var results: [ProjectItem] = []
            for (t, catalog) in zip(tables, catalogs) {
                try ops.journal.perform(.createFile(URL(fileURLWithPath: t.catalogPath), catalog.data()))
                if let first = t.groupIDs.first, let place = ops.proj.detachChildPreview(first) {
                    for g in t.groupIDs { ops.proj.removeTree(g) }
                    let folder = ops.resolved(place.group) ?? t.directory
                    let ref = ops.proj.addReference(path: RelativePath.from(folder, to: t.catalogPath), fileType: "text.json.xcstrings",
                                                    to: place.group, at: min(place.index, ops.proj[place.group]?.references("children").count ?? 0))
                    ops.proj.addToTargets(ref, fileName: t.name + ".xcstrings", targets: t.targetIDs)
                    results.append(.object(ref))
                } else {
                    results.append(.disk(t.catalogPath))
                }
                var folders: [String] = []
                for f in t.files {
                    try ops.journal.perform(.trash(URL(fileURLWithPath: f.path)))
                    let dir = (f.path as NSString).deletingLastPathComponent
                    if !folders.contains(dir) { folders.append(dir) }
                }
                for dir in folders where !((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? ["?"]).contains(where: { $0 != ".DS_Store" }) {
                    try ops.journal.perform(.trash(URL(fileURLWithPath: dir)))
                }
            }
            return results
        }
    }
}

extension PBXProj {
    /// The Swift, Objective-C and C sources of the targets that hold the
    /// file at `path` (a catalog): their Sources phases and their
    /// synchronized folders. "Refresh from source" extracts from these.
    public func localizableSourceFiles(forResourceAt path: String, projectDirectory: URL) -> [String] {
        let exts: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp"]
        let targetIDs = Set(targetMemberships(ofFile: path, projectDirectory: projectDirectory).filter(\.isMember).map(\.targetID))
        let parents = parentMap()
        var out: [String] = []
        for t in targets where targetIDs.contains(t.id) {
            for phase in buildPhases(ofTarget: t.id) where phase.isa == "PBXSourcesBuildPhase" {
                for bf in phase.references("files") {
                    guard let ref = self[bf]?.string("fileRef"), let p = resolvedPath(of: ref, projectDirectory: projectDirectory, parents: parents),
                          exts.contains((p as NSString).pathExtension.lowercased()) else { continue }
                    out.append(p)
                }
            }
            for folder in t.references("fileSystemSynchronizedGroups") {
                guard let root = resolvedPath(of: folder, projectDirectory: projectDirectory, parents: parents) else { continue }
                out += StringsCLI.sourceFiles([root]).filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
