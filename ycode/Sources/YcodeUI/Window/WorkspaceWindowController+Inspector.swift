import AppKit
import YcodeProject

/// The inspectors' data from the workspace (`specs/ide/reference-ui-5.md`
/// §7): the File inspector's working copy and target membership, the
/// History inspector's commits, Quick Help's documentation search.
extension WorkspaceWindowController {
    func wireInspector() {
        inspector.fileInfo = { [weak self] url in self?.fileInspectorInfo(url) ?? FileInspectorInfo() }
        inspector.onSetMembership = { [weak self] url, target, member in self?.setTargetMembership(of: url, target: target, member: member) }
        inspector.historyProvider = { [weak self] url in
            guard let self, Preferences.shared.sourceControlEnabled, let repo = self.repository else { return [] }
            return await Task.detached { repo.history(ofFile: url.path) }.value
        }
        inspector.onSelectHistoryCommit = { [weak self] url, commit in self?.showHistoryCommit(commit, of: url) }
        inspector.onSearchDocumentation = { [weak self] in self?.searchDocumentationForSelection(nil) }
    }

    /// Working copy (outside git: none) and the targets of the project
    /// that holds the file; in a package, the target folder the file is in.
    public func fileInspectorInfo(_ url: URL) -> FileInspectorInfo {
        var info = FileInspectorInfo()
        let path = url.standardizedFileURL.path
        if Preferences.shared.sourceControlEnabled, let repo = repository {
            let root = repo.root.standardizedFileURL.path
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            for p in [path, resolved] where p.hasPrefix(root + "/") {
                info.workingCopy = root
                info.relativePath = String(p.dropFirst(root.count + 1))
                break
            }
        }
        switch session.model.kind {
        case .package:
            let base = session.model.url.standardizedFileURL.path
            for dir in ["Sources", "Tests"] where path.hasPrefix(base + "/\(dir)/") {
                // Sources/<Target>/…: the folder names the target.
                let parts = path.dropFirst(base.count + dir.count + 2).split(separator: "/")
                if parts.count >= 2 {
                    info.memberships = [TargetMembership(targetID: String(parts[0]), name: String(parts[0]), isMember: true, isEditable: false)]
                }
            }
        default:
            if let (_, proj) = project(holding: path) {
                info.memberships = proj.memberships
            }
        }
        return info
    }

    /// The project whose tree holds `path`, with the file's memberships.
    func project(holding path: String) -> (String, (project: PBXProj, memberships: [TargetMembership]))? {
        for (projPath, proj) in session.model.projects.sorted(by: { $0.key < $1.key }) {
            let dir = proj.projectDirectory(xcodeprojURL: URL(fileURLWithPath: projPath))
            guard proj.place(ofFile: path, projectDirectory: dir) != nil else { continue }
            return (projPath, (proj, proj.targetMemberships(ofFile: path, projectDirectory: dir)))
        }
        return nil
    }

    /// Target Membership "+" / "−": edits the project and saves it.
    @discardableResult
    public func setTargetMembership(of url: URL, target: String, member: Bool) -> Bool {
        let path = url.standardizedFileURL.path
        guard let (projPath, found) = project(holding: path) else { NSSound.beep(); return false }
        var proj = found.project
        let dir = proj.projectDirectory(xcodeprojURL: URL(fileURLWithPath: projPath))
        guard proj.setMembership(ofFile: path, target: target, member: member, projectDirectory: dir) else { NSSound.beep(); return false }
        projectChanged(path: projPath, proj)
        inspector.refresh()
        return true
    }

    /// A History inspector row: the commit in Code Review against the
    /// working copy (§7.4).
    public func showHistoryCommit(_ commit: GitRepository.Commit, of url: URL) {
        if editor.fileURL?.standardizedFileURL != url.standardizedFileURL { open(path: url.path, line: nil) }
        endEditorModes(except: .codeReview)
        editor.setReviewSource(.commit(hash: commit.hash, title: "\(commit.shortHash) \(commit.subject)"), left: false)
        endCodeReview()
        startCodeReview()
        updateToolbarState()
    }
}
