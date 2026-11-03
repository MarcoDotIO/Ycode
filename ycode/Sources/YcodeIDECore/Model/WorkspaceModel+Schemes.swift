import Foundation
import YcodeProject
import YcodeWorkspace

// The scheme editor's model helpers (YcodeUI: SchemeEditorController.swift).

extension WorkspaceModel {
    /// Containers whose schemes the workspace shows.
    public var schemeContainers: [URL] {
        switch kind {
        case .project: [url]
        case .workspace: [url] + projects.keys.sorted().map { URL(fileURLWithPath: $0) }
        case .package: []
        }
    }

    /// Scheme files of all containers (shared and the current user's).
    public func loadSchemes() -> [Scheme] {
        schemeContainers.flatMap { Scheme.discover(in: $0) }
    }

    /// Build configuration names of the projects, in list order, unique.
    public var configurationNames: [String] {
        var seen = Set<String>()
        let names = projects.keys.sorted().flatMap { path -> [String] in
            let p = projects[path]!
            return p.buildConfigurations(listID: p.project?.string("buildConfigurationList")).compactMap { $0.string("name") }
        }
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? ["Debug", "Release"] : unique
    }
}
