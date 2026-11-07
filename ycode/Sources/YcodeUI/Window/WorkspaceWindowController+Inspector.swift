import AppKit
import YcodeIDECore
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
    /// that holds the file; in a package, the target folder the file is in
    /// (`FileInspectorInfo.make`, shared with the Linux IDE).
    public func fileInspectorInfo(_ url: URL) -> FileInspectorInfo {
        let root = Preferences.shared.sourceControlEnabled ? repository?.root : nil
        return FileInspectorInfo.make(for: url, in: session.model, repositoryRoot: root)
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
