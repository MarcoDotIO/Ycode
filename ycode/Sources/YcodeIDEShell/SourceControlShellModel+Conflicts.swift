import Foundation
import YcodeIDECore

/// The merge sheet over the veiled window (`specs/ide/merge-sheet.md`
/// §2–§10; `source-control.md`, "Source Control navigator menus" and
/// "Integrate menu additions"): a conflicting merge, rebase, cherry-pick,
/// pull or stash apply opens it on the first conflicted file and one that
/// completes closes it; selecting a conflicted change, its Resolve
/// Conflicts… and Integrate ▸ Resolve Conflicts… open it too. The sheet's
/// Merge writes and stages every file, then continues the operation; its
/// Cancel asks, then aborts. The window behind keeps what it showed.
extension SourceControlShellModel {
    /// Whether the merge sheet is up (the view's overlay shows it).
    public var isMergeSheetShown: Bool { conflictEditor != nil }

    /// Shows the merge sheet on `path` (else the first conflicted file).
    /// `fresh`: an operation stopped (again), so the sheet reads everything
    /// anew instead of keeping the choices it had.
    @discardableResult
    public func showConflictEditor(path: String? = nil, fresh: Bool = false) -> ConflictEditorShellModel? {
        guard let repo = repository else { return nil }
        mergeAlert = nil
        isMerging = false
        if let e = conflictEditor, !fresh {
            if let path { e.showFile(path) } else { e.reload() }
            return e
        }
        saveEditors?()
        let editor = ConflictEditorShellModel(repository: repo, focus: path)
        editor.onResolved = { [weak self] in self?.refresh() }
        conflictEditor = editor
        editor.reload()
        return editor
    }

    /// Closes the sheet (the view reverses its appearance, Ycode's choice).
    public func closeConflictEditor() {
        conflictEditor = nil
        isMerging = false
    }

    /// Integrate ▸ Resolve Conflicts…: the selected conflicted file, else
    /// the first one.
    public func resolveConflicts() {
        let selected = selectedFile.flatMap { f in snapshot.changes.contains { $0.path == f && $0.status == .conflicted } ? f : nil }
        showConflictEditor(path: selected)
    }

    /// Abort <operation> (Integrate, the navigator's banner): asks first.
    public func askAbort() {
        let verb = snapshot.integration.verb.lowercased()
        let name = verb.isEmpty ? "operation" : verb
        confirmation = SourceControlConfirmation(
            title: "Abort the \(name)?", message: "Returns the branch to where it was before the \(name).",
            choices: [.init(title: "Abort", isDestructive: true, action: .abortIntegration)])
    }

    /// The sheet's Merge (§9; what follows is Ycode's choice, open question
    /// 3): writes and stages every file, then completes the operation (the
    /// merge commit, or the next step of a rebase, which may stop again and
    /// the sheet reads it anew); the sheet closes once nothing is left.
    public func completeMerge() async {
        guard let e = conflictEditor, e.state.canMerge else { return }
        if !e.state.files.isEmpty {
            guard await e.writeResolutions() == nil else { return }
        }
        if snapshot.integration.isInProgress || e.state.integration.isInProgress {
            perform(.continueIntegration)
        } else {
            closeConflictEditor()
            refresh()
        }
    }

    /// The sheet's Cancel: while an operation is stopped it asks "Abort the
    /// <operation>?" and Abort aborts it (Ycode's choice, open question 3);
    /// otherwise it only closes the sheet.
    public func cancelMerge() {
        let integration = conflictEditor?.state.integration ?? snapshot.integration
        guard snapshot.integration.isInProgress || integration.isInProgress else {
            closeConflictEditor()
            return
        }
        let verb = integration.isInProgress ? integration.verb : snapshot.integration.verb
        confirmation = SourceControlConfirmation(title: MergeSheetText.cancelTitle(verb: verb), message: MergeSheetText.cancelMessage(verb: verb),
                                                 choices: [.init(title: "Abort", isDestructive: true, action: .abortIntegration)])
    }

    /// After an operation: conflicts open the merge sheet (read anew); an
    /// integration that completed, or an abort, closes it.
    func integrated(_ op: Operation, _ result: GitRepository.IntegrationResult?, succeeded: Bool) {
        isMerging = false
        if case .conflicts(let files)? = result {
            showConflictEditor(path: files.first, fresh: true)
        } else if result != nil || (op == .abortIntegration && succeeded) {
            closeConflictEditor()
        }
    }
}

/// The result of an integrating command, read back on the main actor.
final class IntegrationOutcome: @unchecked Sendable {
    var value: GitRepository.IntegrationResult?
}
