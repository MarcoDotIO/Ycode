import Foundation

/// A `.xcworkspace` (or the workspace embedded in an `.xcodeproj`).
/// See `specs/formats/xcworkspace.md`.
public struct Workspace: Sendable {
    /// Where a workspace item lives, as written in its `location` attribute.
    public enum Location: Equatable, Sendable {
        /// Relative to the enclosing group, or to the container at top level.
        case group(String)
        /// Relative to the directory that contains the workspace.
        case container(String)
        case absolute(String)
        /// The project that embeds this workspace (`self:`), or a legacy
        /// path relative to that project's directory.
        case selfReference(String)
        /// Relative to the active developer directory.
        case developer(String)
        case unknown(String)

        public init(_ raw: String) {
            let (scheme, path) = raw.firstIndex(of: ":").map { (String(raw[..<$0]), String(raw[raw.index(after: $0)...])) } ?? ("", raw)
            switch scheme {
            case "group": self = .group(path)
            case "container": self = .container(path)
            case "absolute": self = .absolute(path)
            case "self": self = .selfReference(path)
            case "developer": self = .developer(path)
            default: self = .unknown(raw)
            }
        }

        public var rawValue: String {
            switch self {
            case .group(let p): "group:" + p
            case .container(let p): "container:" + p
            case .absolute(let p): "absolute:" + p
            case .selfReference(let p): "self:" + p
            case .developer(let p): "developer:" + p
            case .unknown(let r): r
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public enum Kind: Sendable { case file, group }
        public var kind: Kind
        public var location: Location
        public var name: String?
        public var children: [Item]
        /// Absolute path, resolved when the workspace was loaded from disk.
        public var resolvedPath: String?
    }

    /// The `.xcworkspace` bundle, if loaded from disk.
    public var url: URL?
    public var document: XMLNode
    public private(set) var items: [Item] = []

    public init(parsing text: String, url: URL? = nil, developerDirectory: String? = nil) throws {
        document = try XcodeXML.parse(text)
        guard document.name == "Workspace" else { throw XMLReadError(message: "root element is not <Workspace>", offset: 0) }
        self.url = url
        let container = url?.deletingLastPathComponent().path
        // An embedded workspace (`App.xcodeproj/project.xcworkspace`) uses
        // `self:` for its project.
        let selfProject = url.flatMap { $0.deletingLastPathComponent().pathExtension == "xcodeproj" ? $0.deletingLastPathComponent() : nil }
        items = document.children.compactMap {
            Self.item($0, base: container, container: container, selfProject: selfProject?.path, developer: developerDirectory)
        }
    }

    /// Loads `path`, which may be an `.xcworkspace`, an `.xcodeproj` (its
    /// embedded workspace), or a `contents.xcworkspacedata` file.
    public init(contentsOf path: String) throws {
        var url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "contents.xcworkspacedata" { url.deleteLastPathComponent() }
        if url.pathExtension == "xcodeproj" { url.appendPathComponent("project.xcworkspace") }
        let data = url.appendingPathComponent("contents.xcworkspacedata")
        let text: String
        if FileManager.default.fileExists(atPath: data.path) {
            text = try String(contentsOf: data, encoding: .utf8)
        } else if url.lastPathComponent == "project.xcworkspace" {
            // Projects without an embedded workspace behave as if it said `self:`.
            text = XcodeXML.write(XMLNode("Workspace", attributes: [("version", "1.0")],
                                          children: [XMLNode("FileRef", attributes: [("location", "self:")])]))
        } else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: data.path])
        }
        try self.init(parsing: text, url: url, developerDirectory: Self.activeDeveloperDirectory())
    }

    public func serialized() -> String { XcodeXML.write(document) }

    /// Every file item, depth-first.
    public var allFiles: [Item] {
        func walk(_ items: [Item]) -> [Item] {
            items.flatMap { $0.kind == .file ? [$0] : walk($0.children) }
        }
        return walk(items)
    }

    /// Absolute paths of the projects in the workspace, in order.
    public var projectPaths: [String] {
        allFiles.compactMap(\.resolvedPath).filter { $0.hasSuffix(".xcodeproj") }
    }

    private static func item(_ node: XMLNode, base: String?, container: String?, selfProject: String?, developer: String?) -> Item? {
        let kind: Item.Kind
        switch node.name {
        case "FileRef": kind = .file
        case "Group": kind = .group
        default: return nil
        }
        let location = Location(node["location"] ?? "")
        let resolved = resolve(location, base: base, container: container, selfProject: selfProject, developer: developer)
        let children = node.children.compactMap {
            item($0, base: resolved ?? base, container: container, selfProject: selfProject, developer: developer)
        }
        return Item(kind: kind, location: location, name: node["name"], children: children, resolvedPath: resolved)
    }

    static func resolve(_ location: Location, base: String?, container: String?, selfProject: String?, developer: String?) -> String? {
        func join(_ dir: String?, _ rel: String) -> String? {
            guard let dir else { return nil }
            if rel.isEmpty { return dir }
            return URL(fileURLWithPath: dir).appendingPathComponent(rel).standardizedFileURL.path
        }
        switch location {
        case .group(let p): return p.hasPrefix("/") ? p : join(base, p)
        case .container(let p): return join(container, p)
        case .absolute(let p): return p
        case .developer(let p): return join(developer, p)
        case .selfReference(let p):
            guard let selfProject else { return nil }
            return p.isEmpty ? selfProject : join(URL(fileURLWithPath: selfProject).deletingLastPathComponent().path, p)
        case .unknown: return nil
        }
    }

    /// `DEVELOPER_DIR`, else the `xcode-select` link, else nil.
    public static func activeDeveloperDirectory() -> String? {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return env }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
    }
}
