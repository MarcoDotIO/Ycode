import Foundation
import YcodeIDECore

/// The merge confirmation (`specs/ide/merge-sheet.md` §1.2): "Are you sure
/// you want to merge from “b”?" with Cancel and **Merge**, centred on the
/// window over the veil. Integrate ▸ Merge… adds a pop-up of the branches
/// to merge from (Ycode's choice: the reference's path was not captured).
public struct MergeAlertState: Equatable, Sendable {
    /// The branch merged from.
    public var branch: String
    /// The current branch, merged into.
    public var current: String
    /// The pop-up's branches (Integrate ▸ Merge…); nil without one.
    public var choices: [String]?

    public init(branch: String, current: String, choices: [String]? = nil) {
        self.branch = branch
        self.current = current
        self.choices = choices
    }

    public var title: String { MergeSheetText.alertTitle(branch: branch) }
    public var message: String { MergeSheetText.alertMessage(branch: branch, current: current) }
    public var hasChooser: Bool { !(choices?.isEmpty ?? true) }

    /// The alert's frame, centred in a window of `size` (30 taller with the
    /// pop-up).
    public func frame(window size: (width: Double, height: Double)) -> MergeSheetMetrics.Rect {
        MergeSheetMetrics.alertFrame(window: size, chooser: hasChooser)
    }
}

/// Starting a merge (§1): the branch row's "Merge “b” into “c”…" and
/// Integrate ▸ Merge… show the alert; its Merge runs git's merge (the sheet
/// opens on conflicts); the reference's other branch-menu items.
extension SourceControlShellModel {
    /// The local branches Integrate ▸ Merge… offers (all but the current).
    public var mergeableBranches: [String] { snapshot.branches.map(\.name).filter { $0 != snapshot.currentBranch } }

    /// The merge confirmation for `branch`; with `choices`, a pop-up to pick
    /// the branch.
    public func presentMergeAlert(branch: String, choices: [String]? = nil) {
        mergeAlert = MergeAlertState(branch: branch, current: snapshot.currentBranch ?? "HEAD", choices: choices)
    }

    /// Integrate ▸ Merge…: the alert for the branch selected in the
    /// navigator (else the first other branch), with the pop-up.
    public func showMergeFromMenu() {
        let branches = mergeableBranches
        guard !branches.isEmpty else { return }
        let selected = selection.flatMap { s -> String? in
            if s.hasPrefix("branch:") { return String(s.dropFirst(7)) }
            if s.hasPrefix("recent:") { return String(s.dropFirst(7)) }
            return nil
        }
        presentMergeAlert(branch: selected.flatMap { branches.contains($0) ? $0 : nil } ?? branches[0], choices: branches)
    }

    /// The pop-up's choice.
    public func chooseMergeBranch(_ branch: String) {
        guard var a = mergeAlert, a.choices?.contains(branch) ?? false else { return }
        a.branch = branch
        mergeAlert = a
    }

    /// The alert's Merge (Return): the alert fades out and git merges; the
    /// veil stays while it runs, then the sheet comes in on conflicts.
    public func confirmMergeAlert() {
        guard let a = mergeAlert else { return }
        mergeAlert = nil
        isMerging = true
        perform(.merge(a.branch))
    }

    /// The alert's Cancel (Escape).
    public func cancelMergeAlert() {
        mergeAlert = nil
    }

    /// The branch menu's items that only the reference's menu has.
    func chooseMore(_ action: SourceControlRowMenu.Action) {
        switch action {
        case .viewOnHost(let branch):
            if let url = SourceControlRowMenu.hostURL(branch: branch, remoteURLs: snapshot.remotes.map(\.url)) { openExternally(url) }
        case .exportStash(let ref):
            let name = repository?.root.lastPathComponent ?? "Repository"
            let folder = repository?.root.deletingLastPathComponent().path ?? folder.path
            prompt = SourceControlPrompt(purpose: .exportStash(ref), title: "Export Stashed Changes as Patch File",
                                         message: "Write the changes of \u{201C}\(ref)\u{201D} as a patch file.",
                                         fields: [.init(label: "File", placeholder: "Path of the patch file",
                                                        text: (folder as NSString).appendingPathComponent("\(name) stash.patch"))],
                                         button: "Export")
        // Merge “c” into “b”…, New “repo” Remote… and Add Existing Remote…
        // are disabled in the branch menu (§1.1).
        default: break
        }
    }

    /// Writes a stash's patch (Export Stashed Changes as Patch File…'s
    /// prompt); a failure is shown like any other.
    func exportStash(_ ref: String, to path: String) {
        guard let repo = repository else { return }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : (folder.path as NSString).appendingPathComponent(expanded))
        Task { [weak self] in
            let error = await Task.detached { () -> String? in
                do { try repo.exportStash(ref, to: url); return nil } catch let e as GitRepository.GitError {
                    return e.errorDescription ?? e.description
                } catch { return error.localizedDescription }
            }.value
            if let error { self?.errorMessage = error }
        }
    }
}
