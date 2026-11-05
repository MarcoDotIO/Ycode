import Foundation
import YcodeIDECore

/// The conflict editor over the editor area (`source-control.md`,
/// "Source Control navigator menus" and "Integrate menu additions"): a
/// conflicting merge, rebase, cherry-pick, pull or stash apply opens it on
/// the first conflicted file and one that completes closes it; selecting
/// a conflicted change, its Resolve Conflicts… and Integrate ▸ Resolve
/// Conflicts… open it too. Abort asks first.
extension SourceControlShellModel {
    /// Shows the conflict editor on `path` (else the first conflicted file).
    @discardableResult
    public func showConflictEditor(path: String? = nil) -> ConflictEditorShellModel? {
        guard let repo = repository else { return nil }
        saveEditors?()
        let editor = ConflictEditorShellModel(repository: repo, focus: path)
        editor.onResolved = { [weak self] in self?.refresh() }
        editor.onContinue = { [weak self] in self?.perform(.continueIntegration) }
        editor.onAbort = { [weak self] in self?.askAbort() }
        conflictEditor = editor
        pane = .conflicts
        editor.reload()
        return editor
    }

    /// Closes the conflict editor (the editor area shows the file again).
    public func closeConflictEditor() {
        guard case .conflicts? = pane else { return }
        hidePane()
    }

    /// Integrate ▸ Resolve Conflicts…: the selected conflicted file, else
    /// the first one.
    public func resolveConflicts() {
        let selected = selectedFile.flatMap { f in snapshot.changes.contains { $0.path == f && $0.status == .conflicted } ? f : nil }
        showConflictEditor(path: selected)
    }

    /// Abort <operation>: asks first.
    public func askAbort() {
        let verb = snapshot.integration.verb.lowercased()
        let name = verb.isEmpty ? "operation" : verb
        confirmation = SourceControlConfirmation(
            title: "Abort the \(name)?", message: "Returns the branch to where it was before the \(name).",
            choices: [.init(title: "Abort", isDestructive: true, action: .abortIntegration)])
    }

    /// After an operation: conflicts open the conflict editor; an
    /// integration that completed, or an abort, closes it.
    func integrated(_ op: Operation, _ result: GitRepository.IntegrationResult?, succeeded: Bool) {
        if case .conflicts(let files)? = result {
            showConflictEditor(path: files.first)
        } else if result != nil || (op == .abortIntegration && succeeded) {
            closeConflictEditor()
        }
    }
}

/// The result of an integrating command, read back on the main actor.
final class IntegrationOutcome: @unchecked Sendable {
    var value: GitRepository.IntegrationResult?
}
