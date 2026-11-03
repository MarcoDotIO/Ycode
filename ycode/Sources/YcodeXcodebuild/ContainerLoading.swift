import Foundation
import YcodeProject

extension Container {
    /// Opens an `.xcodeproj` (with the projects it references) or an
    /// `.xcworkspace` (with its projects), for other modules: the build
    /// server (`specs/ide/language.md` §Build server) loads containers the
    /// way ycodebuild does.
    public static func open(_ url: URL) throws -> Container {
        let url = url.standardizedFileURL
        do {
            switch url.pathExtension {
            case "xcworkspace": return try ContainerLocator.loadWorkspace(url)
            case "xcodeproj": return try ContainerLocator.loadProjectContainer(url)
            default: throw XcodebuildFailure("'\(url.path)' is not a project or workspace.", exitCode: ExitCode.noInput)
            }
        } catch let e as XcodebuildFailure {
            throw ContainerOpenError(description: e.messages.joined(separator: "\n"))
        }
    }
}

/// Why `Container.open` failed.
public struct ContainerOpenError: Error, CustomStringConvertible {
    public var description: String
}

extension SettingsTarget {
    public init(_ project: LoadedProject, _ target: PBXObject) {
        self.project = project
        self.target = target
    }
}
