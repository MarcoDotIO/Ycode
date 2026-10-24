import Foundation
import YcodeProject

/// One row of the project navigator. See `specs/ide/navigators.md`.
public final class NavigatorNode: @unchecked Sendable {
    public enum Kind: Equatable, Sendable {
        /// The top row for a project, workspace or package.
        case container
        /// A group (`PBXGroup`, variant/version group) with no folder of its own.
        case group
        /// A folder: a synchronized root group, or a directory on disk.
        case folder
        case file
    }

    public let name: String
    public let kind: Kind
    /// Absolute path, when the item is on disk.
    public let path: String?
    /// The pbxproj object, if the row comes from a project.
    public let objectID: String?
    public internal(set) var children: [NavigatorNode]

    public init(name: String, kind: Kind, path: String?, objectID: String? = nil, children: [NavigatorNode] = []) {
        self.name = name
        self.kind = kind
        self.path = path
        self.objectID = objectID
        self.children = children
    }

    public var isExpandable: Bool { kind != .file }

    /// Identifies the row across launches for the saved expansion: the
    /// project object, else the path, else the name.
    public var expansionKey: String { objectID ?? path ?? name }

    /// Every file row, depth-first.
    public var allFiles: [NavigatorNode] {
        kind == .file ? [self] : children.flatMap(\.allFiles)
    }

    /// The first row whose path equals `path`.
    public func find(path: String) -> NavigatorNode? {
        if self.path == path { return self }
        for c in children { if let f = c.find(path: path) { return f } }
        return nil
    }
}

public enum NavigatorTree {
    /// Names the navigator never shows when listing a directory.
    static let hidden: Set<String> = [".DS_Store", ".git", ".build", ".swiftpm", "xcuserdata", "DerivedData"]

    /// The tree of a project: the project row, then the main group's
    /// children in file order, without the product-reference group
    /// ("Products", `reference-ui-5.md` §5.1, N1). Synchronized folders
    /// list their directory.
    public static func project(_ proj: PBXProj, xcodeprojURL: URL) -> NavigatorNode {
        let dir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = proj.parentMap()
        func node(_ id: String) -> NavigatorNode? {
            guard let obj = proj[id] else { return nil }
            let path = proj.resolvedPath(of: id, projectDirectory: dir, parents: parents)
            let display = obj.string("name") ?? obj.string("path").map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            switch obj.isa {
            case "PBXGroup", "PBXVariantGroup", "XCVersionGroup":
                let kids = obj.references("children").compactMap(node)
                return NavigatorNode(name: display, kind: .group, path: path, objectID: id, children: kids)
            case "PBXFileSystemSynchronizedRootGroup":
                let kids = path.map { directory($0) } ?? []
                return NavigatorNode(name: display, kind: .folder, path: path, objectID: id, children: kids)
            case "PBXFileReference":
                return NavigatorNode(name: display, kind: .file, path: path, objectID: id)
            default:
                return nil
            }
        }
        let main = proj.project?.string("mainGroup").flatMap { proj[$0] }
        let products = proj.project?.string("productRefGroup")
        let kids = main?.references("children").filter { $0 != products }.compactMap(node) ?? []
        let name = xcodeprojURL.deletingPathExtension().lastPathComponent
        return NavigatorNode(name: name, kind: .container, path: xcodeprojURL.path, objectID: proj.rootObject, children: kids)
    }

    /// A directory's contents in Finder-style name order, folders and files
    /// mixed (an open question in the spec).
    public static func directory(_ path: String) -> [NavigatorNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.filter { !hidden.contains($0) && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let full = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                // Bundles such as `.xcassets` are leaves.
                let isBundle = ["xcassets", "xcodeproj", "xcworkspace", "playground", "xcdatamodeld", "bundle"]
                    .contains((name as NSString).pathExtension)
                if isDir.boolValue && !isBundle {
                    return NavigatorNode(name: name, kind: .folder, path: full, children: directory(full))
                }
                return NavigatorNode(name: name, kind: .file, path: full)
            }
    }

    /// The rows expanded at first open, when no expansion was saved
    /// (`reference-ui-5.md` §5.1, N4): the root and its first child that
    /// can expand (the first group). Expansion keys, see `expansionKey`.
    public static func initiallyExpanded(_ root: NavigatorNode) -> [String] {
        [root.expansionKey] + (root.children.first(where: \.isExpandable).map { [$0.expansionKey] } ?? [])
    }

    /// A package folder: the folder row with its contents. The root's
    /// children are the manifest ("Package"), then "Sources", then
    /// "Tests", then the other items by name (`reference-ui-5.md` §5.1, N5).
    public static func package(at dir: URL) -> NavigatorNode {
        NavigatorNode(name: dir.lastPathComponent, kind: .container, path: dir.path, children: packageOrder(directory(dir.path)))
    }

    static func packageOrder(_ rows: [NavigatorNode]) -> [NavigatorNode] {
        func rank(_ n: NavigatorNode) -> Int {
            switch (n.name, n.kind) {
            case ("Package.swift", .file): 0
            case ("Sources", .folder): 1
            case ("Tests", .folder): 2
            default: 3
            }
        }
        // A stable sort keeps the name order within the last rank.
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}
