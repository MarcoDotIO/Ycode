import AppKit
import YcodeIDECore

/// Branch workflows in the window: the Source Control navigator's context
/// menus (`SourceControlRowMenu`), merge and rebase with the conflict
/// editor, stashes, tags and remotes (`specs/ide/source-control.md`,
/// "Ycode implementation"). Each operation runs git in the background
/// after the previous one; the parameterized methods are what the menus
/// call once their prompt is answered (tests call them directly).
extension SourceControlCoordinator {
    // MARK: Row menus

    /// The context menu of a navigator row.
    public func rowMenuItems(forKey key: String) -> [NSMenuItem] {
        SourceControlRowMenu.items(forKey: key, in: .init(snapshot)).map { spec in
            guard let action = spec.action else { return .separator() }
            let item = SourceControlMenuItem(title: spec.title, action: #selector(SourceControlMenuItem.choose(_:)), keyEquivalent: "")
            item.target = item
            item.rowAction = action
            item.handler = { [weak self] a in self?.run(a) }
            item.rowEnabled = spec.isEnabled
            item.isEnabled = spec.isEnabled
            return item
        }
    }

    /// Performs a row action, asking for names and confirmations first
    /// (nothing is asked while the window is off screen: tests).
    public func run(_ action: SourceControlRowMenu.Action) {
        let current = snapshot.currentBranch ?? "HEAD"
        func q(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }
        switch action {
        case .checkout(let b): checkoutAsking(b)
        case .newBranch(let from):
            guard let name = prompt("New Branch", "Creates a branch from \(q(from ?? current)) and checks it out.", placeholder: "Branch name"),
                  !name.isEmpty else { return }
            createBranch(name, from: from, checkout: true)
        case .newTag(let at):
            guard let name = prompt("New Tag", "Tags \(q(at ?? current)). A message makes an annotated tag.", placeholder: "Tag name"),
                  !name.isEmpty else { return }
            createTag(name, at: at)
        case .renameBranch(let b):
            guard let name = prompt("Rename \(q(b))", "Enter a new name for the branch.", placeholder: b), !name.isEmpty else { return }
            renameBranch(b, to: name)
        case .deleteBranch(let b):
            guard confirm("Delete the branch \(q(b))?", "A branch with commits that are not merged is deleted only after a second confirmation.", "Delete") else { return }
            deleteBranch(b, force: false)
        case .merge(let ref):
            guard confirm("Merge \(q(ref)) into \(q(current))?", "Conflicts open the conflict editor.", "Merge") else { return }
            merge(ref)
        case .rebaseOnto(let ref):
            guard confirm("Rebase \(q(current)) onto \(q(ref))?", "Replays the commits of \(q(current)) on top of \(q(ref)).", "Rebase") else { return }
            rebase(onto: ref)
        case .push(let b):
            let remote = snapshot.repository.flatMap { $0.remote(of: b) } ?? snapshot.remotes.first?.name ?? "origin"
            guard confirm("Push \(q(b)) to \(q(remote))?", "Sets the remote branch as its upstream.", "Push") else { return }
            push(branch: b, remote: remote)
        case .pull(let b):
            let remote = snapshot.repository.flatMap { $0.remote(of: b) } ?? snapshot.remotes.first?.name ?? "origin"
            pull(branch: b, remote: remote, style: .merge)
        case .deleteRemoteBranch(let r, let b):
            guard confirm("Delete \(q(b)) from \(q(r))?", "The branch is deleted on the remote.", "Delete") else { return }
            perform { try $0.deleteRemoteBranch(remote: r, branch: b) }
        case .pushTag(let t):
            guard let remote = snapshot.remotes.first?.name else { return }
            perform { try $0.push(remote: remote, tag: t) }
        case .deleteTag(let t):
            guard confirm("Delete the tag \(q(t))?", "", "Delete") else { return }
            perform { try $0.deleteTag(t) }
        case .applyStash(let ref): applyStash(ref, pop: false)
        case .popStash(let ref): applyStash(ref, pop: true)
        case .dropStash(let ref):
            guard confirm("Delete \(ref)?", "The stashed changes are lost.", "Delete") else { return }
            perform { try $0.dropStash(ref) }
        case .fetch(let r): perform { try $0.fetch(remote: r) }
        case .addRemote:
            guard let name = prompt("Add Remote", "Enter the remote's name.", placeholder: "origin"), !name.isEmpty,
                  let url = prompt("Add Remote", "Enter the URL of \(q(name)).", placeholder: "https://…"), !url.isEmpty else { return }
            perform { try $0.addRemote(name, url: url) }
        case .removeRemote(let r):
            guard confirm("Remove the remote \(q(r))?", "Its remote branches are removed from this repository.", "Remove") else { return }
            perform { try $0.removeRemote(r) }
        case .resolveConflicts(let p): showConflictEditor(path: p)
        case .markResolved(let p): perform { try $0.markResolved([p]) }
        }
    }

    // MARK: Operations

    public func createBranch(_ name: String, from start: String? = nil, checkout: Bool = false) {
        perform { try $0.createBranch(name, from: start, checkout: checkout) }
    }

    public func renameBranch(_ name: String, to newName: String) { perform { try $0.renameBranch(name, to: newName) } }

    /// Deletes a branch; an unmerged one asks again, then is forced.
    public func deleteBranch(_ name: String, force: Bool) {
        guard let repo = repository else { NSSound.beep(); return }
        runInBackground(body: {
            do { try repo.deleteBranch(name, force: force) } catch where !force {
                throw UnmergedBranch(name: name, underlying: error)
            }
        }, failure: { [weak self] error in
            guard let self, let u = error as? UnmergedBranch else { return false }
            if self.confirm("\u{201C}\(u.name)\u{201D} is not fully merged.", "Deleting it loses its unmerged commits.", "Delete Anyway") {
                self.deleteBranch(u.name, force: true)
            }
            return true
        })
    }

    struct UnmergedBranch: Error { let name: String; let underlying: any Error }

    /// Asks what to do with uncommitted changes, then switches.
    func checkoutAsking(_ branch: String) {
        let dirty = snapshot.changes.contains { $0.status != .untracked }
        guard dirty, owner.window?.isVisible == true else { checkout(branch, changes: .carry); return }
        let a = NSAlert()
        a.messageText = "Check out \u{201C}\(branch)\u{201D}?"
        a.informativeText = "The working copy has uncommitted changes. Stash them, or take them along to the other branch."
        a.addButton(withTitle: "Stash and Check Out")
        a.addButton(withTitle: "Keep Changes")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: checkout(branch, changes: .stash)
        case .alertSecondButtonReturn: checkout(branch, changes: .carry)
        default: return
        }
    }

    public func checkout(_ branch: String, changes: GitRepository.ChangeHandling) {
        perform { _ = try $0.checkout(branch, changes: changes) }
    }

    public func createTag(_ name: String, at revision: String? = nil, message: String? = nil) {
        perform { try $0.createTag(name, at: revision, message: message) }
    }

    public func merge(_ revision: String, style: GitRepository.MergeStyle = .fastForwardIfPossible) {
        integrate { try $0.merge(revision, style: style) }
    }

    public func rebase(onto revision: String) { integrate { try $0.rebase(onto: revision) } }

    public func cherryPick(_ revision: String) { integrate { try $0.cherryPickCommit(revision) } }

    public func applyStash(_ ref: String, pop: Bool) { integrate { try $0.applyStash(ref, pop: pop) } }

    public func push(branch: String, remote: String, setUpstream: Bool = true) {
        perform { try $0.push(remote: remote, branch: branch, setUpstream: setUpstream) }
    }

    public func pull(branch: String, remote: String, style: GitRepository.PullStyle) {
        integrate { try $0.pull(remote: remote, branch: branch, style: style) }
    }

    /// Integrate ▸ Continue <operation>: once every conflict is resolved.
    public func continueIntegration() { integrate { try $0.continueIntegration() } }

    /// Integrate ▸ Abort <operation>.
    public func abortIntegration() {
        perform { try $0.abortIntegration() }
        enqueue { [weak self] in self?.closeConflictEditor() }
    }

    /// The last integrating command's result (tests).
    public var lastIntegrationResult: GitRepository.IntegrationResult? {
        get { integrationResult } set { integrationResult = newValue }
    }

    /// Runs a merge, rebase, pick or stash apply; conflicts open the
    /// conflict editor on the first conflicted file, success closes it.
    func integrate(_ body: @escaping @Sendable (GitRepository) throws -> GitRepository.IntegrationResult) {
        guard let repo = repository else { NSSound.beep(); return }
        let box = ResultBox()
        runInBackground(body: { box.value = try body(repo) }, then: { [weak self] in
            guard let self else { return }
            self.integrationResult = box.value
            switch box.value {
            case .conflicts(let files)?: self.showConflictEditor(path: files.first)
            case .some: if self.conflictEditor != nil { self.closeConflictEditor() }
            case nil: break
            }
        })
    }

    final class ResultBox: @unchecked Sendable { var value: GitRepository.IntegrationResult? }

    // MARK: Conflict editor

    public var conflictEditor: ConflictEditorController? { editorOverlay as? ConflictEditorController }

    /// Shows the conflict editor over the editor area, on `path` or the
    /// first conflicted file.
    @discardableResult
    public func showConflictEditor(path: String? = nil) -> ConflictEditorController? {
        guard let repo = repository else { return nil }
        try? owner.editor.save()
        let c = ConflictEditorController(repository: repo, focus: path)
        c.onResolved = { [weak self] in self?.owner.refreshFileStatus(nil) }
        c.onContinue = { [weak self] in self?.continueIntegration() }
        c.onAbort = { [weak self] in
            guard let self else { return }
            let verb = self.snapshot.integration.verb
            guard self.confirm("Abort the \(verb.lowercased())?", "Returns the branch to where it was before the \(verb.lowercased()).", "Abort") else { return }
            self.abortIntegration()
        }
        install(c)
        setInspector(nil)
        return c
    }

    func closeConflictEditor() {
        guard conflictEditor != nil else { return }
        hideEditor()
    }

    // MARK: Show Last Change for Line

    /// History of the commit that last changed `line` of `path`, with that
    /// commit selected; false when the line is not committed or the file
    /// is not in the repository.
    @discardableResult
    public func showLastChange(path: String, line: Int, contents: String?) async -> Bool {
        guard let repo = repository else { return false }
        let commits = await Task.detached { repo.blame(of: path, contents: contents) }.value
        guard let commits, commits.indices.contains(line - 1), !commits[line - 1].isUncommitted else { return false }
        let hash = commits[line - 1].hash
        guard let h = showHistory(ref: hash, branch: nil) else { return false }
        await h.idle()
        h.select(h.shown.first { $0.hash == hash })
        return true
    }
}

/// A row-menu item carrying its action; it is its own target.
final class SourceControlMenuItem: NSMenuItem {
    var rowAction: SourceControlRowMenu.Action?
    var handler: ((SourceControlRowMenu.Action) -> Void)?

    @objc func choose(_ sender: Any?) {
        guard let rowAction else { return }
        handler?(rowAction)
    }

    /// Enablement from the row's state (menus that enable their items
    /// ask the target, which is the item itself).
    var rowEnabled = true
}

extension SourceControlMenuItem: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { rowEnabled }
}

extension WorkspaceWindowController {
    /// Integrate ▸ Resolve Conflicts…: the conflict editor on the selected
    /// conflicted file, else the first one.
    @objc public func scmResolveConflicts(_ sender: Any?) {
        let selected = sourceControl.selectedFile.flatMap { f in sourceControl.snapshot.changes.contains { $0.path == f && $0.status == .conflicted } ? f : nil }
        sourceControl.showConflictEditor(path: selected)
    }
    /// Integrate ▸ Continue <operation>.
    @objc public func scmContinueIntegration(_ sender: Any?) { sourceControl.continueIntegration() }
    /// Integrate ▸ Abort <operation>.
    @objc public func scmAbortIntegration(_ sender: Any?) {
        let verb = sourceControl.snapshot.integration.verb.lowercased()
        guard sourceControl.confirm("Abort the \(verb)?", "Returns the branch to where it was before the \(verb).", "Abort") else { return }
        sourceControl.abortIntegration()
    }
}
