import Foundation

extension PBXProj {
    /// Maps each object to the group that lists it in `children`.
    public func parentMap() -> [String: String] {
        var parents: [String: String] = [:]
        for obj in objects.values {
            for child in obj.references("children") { parents[child] = obj.id }
        }
        return parents
    }

    /// The directory that `<group>`-relative paths of the main group start
    /// from: the project's directory plus `projectDirPath`.
    public func projectDirectory(xcodeprojURL: URL) -> URL {
        let dir = xcodeprojURL.deletingLastPathComponent()
        guard let p = project?.string("projectDirPath"), !p.isEmpty else { return dir }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p).standardizedFileURL
    }

    /// The location of a file or group object. It is absolute when the
    /// source tree is `<group>`, `SOURCE_ROOT`, or `<absolute>`. Otherwise it
    /// is `$(SOURCE_TREE)/path`, for the caller to expand with build settings.
    /// See `specs/formats/pbxproj.md` §Paths.
    public func resolvedPath(of id: String, projectDirectory: URL, parents: [String: String]? = nil) -> String? {
        let parents = parents ?? parentMap()
        var visited: Set<String> = []
        func resolve(_ id: String) -> String? {
            guard let obj = objects[id], visited.insert(id).inserted else { return nil }
            let path = obj.string("path") ?? ""
            switch obj.string("sourceTree") ?? "<group>" {
            case "<absolute>":
                return path
            case "SOURCE_ROOT":
                return join(projectDirectory.path, path)
            case "<group>":
                let base = parents[id].flatMap(resolve) ?? projectDirectory.path
                return join(base, path)
            case let tree:
                return path.isEmpty ? "$(\(tree))" : "$(\(tree))/\(path)"
            }
        }
        return resolve(id)
    }

    private func join(_ base: String, _ rel: String) -> String {
        if rel.isEmpty { return base }
        if rel.hasPrefix("/") { return rel }
        return URL(fileURLWithPath: base).appendingPathComponent(rel).standardizedFileURL.path
    }
}
