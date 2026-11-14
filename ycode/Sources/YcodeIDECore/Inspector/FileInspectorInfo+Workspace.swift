import Foundation
import YcodeProject

/// The File inspector's facts about a file, from the workspace, read the
/// same way by both IDEs (`cross-platform-parity.md` §5: the Linux IDE had
/// no Working Copy and no Relative Path rows).
extension FileInspectorInfo {
    /// Working copy (outside git, or with source control off: none) and the
    /// targets of the project that holds the file; in a package, the target
    /// folder the file is in.
    public static func make(for url: URL, in model: WorkspaceModel, repositoryRoot: URL?) -> FileInspectorInfo {
        var info = FileInspectorInfo()
        let path = url.standardizedFileURL.path
        if let repositoryRoot {
            let root = repositoryRoot.standardizedFileURL.path
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            for p in [path, resolved] where p.hasPrefix(root + "/") {
                info.workingCopy = root
                info.relativePath = String(p.dropFirst(root.count + 1))
                break
            }
        }
        switch model.kind {
        case .package:
            let base = model.url.standardizedFileURL.path
            // reference-ui-6.md §6 (I1): a package's files show only
            // Identity and Type and Text Settings.
            info.isPackageFile = path.hasPrefix(base + "/")
            for dir in ["Sources", "Tests"] where path.hasPrefix(base + "/\(dir)/") {
                // Sources/<Target>/…: the folder names the target.
                let parts = path.dropFirst(base.count + dir.count + 2).split(separator: "/")
                if parts.count >= 2 {
                    info.memberships = [TargetMembership(targetID: String(parts[0]), name: String(parts[0]), isMember: true, isEditable: false)]
                }
            }
        default:
            if let (projPath, proj) = project(holding: path, in: model) {
                let dir = proj.projectDirectory(xcodeprojURL: URL(fileURLWithPath: projPath))
                info.memberships = proj.targetMemberships(ofFile: path, projectDirectory: dir)
                switch proj.place(ofFile: path, projectDirectory: dir) {
                case .synchronized?: info.inSynchronizedFolder = true
                case .reference(let id)?:
                    info.recordedType = proj[id].flatMap { $0.string("explicitFileType") ?? $0.string("lastKnownFileType") }
                case nil: break
                }
            }
        }
        return info
    }

    /// The project (its path and file) whose tree holds `path`.
    public static func project(holding path: String, in model: WorkspaceModel) -> (String, PBXProj)? {
        for (projPath, proj) in model.projects.sorted(by: { $0.key < $1.key }) {
            let dir = proj.projectDirectory(xcodeprojURL: URL(fileURLWithPath: projPath))
            if proj.place(ofFile: path, projectDirectory: dir) != nil { return (projPath, proj) }
        }
        return nil
    }
}
