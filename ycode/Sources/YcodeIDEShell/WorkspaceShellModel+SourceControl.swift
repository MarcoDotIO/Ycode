import Foundation
import YcodeIDECore

/// What the source-control model asks of its window: the open files'
/// text (change bars), saving before a commit, opening a file.
extension WorkspaceShellModel {
    func connectSourceControl() {
        let scm = sourceControl
        scm.currentText = { [weak self] path in self?.openDocuments[path]?.buffer.text }
        scm.saveEditors = { [weak self] in _ = self?.saveAll() }
        scm.openFile = { [weak self] path in self?.open(path) }
        scm.onSnapshot = { [weak self] read in self?.session.noteConflicts(read) }   // row 188
        scm.refresh()
    }

    /// The current branch for the debug bar (nil outside git).
    public var currentBranch: String? { sourceControl.snapshot.currentBranch }
}
