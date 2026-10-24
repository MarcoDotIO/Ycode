import AppKit

/// Connects the Source Control navigator, the commit editor and branch
/// history (shown over the editor area), the inspector's Source Control
/// tab, and the Integrate menu to a window's repository.
@MainActor
public final class SourceControlCoordinator {
    unowned let owner: WorkspaceWindowController
    public private(set) var mode: SourceControlNavigatorModel.Mode = .changes
    /// The view controller shown over the editor area, if any.
    public private(set) var editorOverlay: NSViewController?
    public var commitEditor: CommitEditorController? { editorOverlay as? CommitEditorController }
    public var history: BranchHistoryController? { editorOverlay as? BranchHistoryController }
    /// A path selected in the Changes list (Integrate's "Selected Files").
    public private(set) var selectedChange: String?
    private var installedInspector = false
    /// From the last Refresh File Status, for the menu bar (no git call
    /// per menu update): whether the repository has a remote, and the
    /// files' status.
    public internal(set) var hasRemote = false
    public internal(set) var lastStatus: [String: GitRepository.FileStatus] = [:]
    /// The last source-control read (`SourceControlSnapshot`). Menus,
    /// navigators and the debug bar read only this; it is re-read off the
    /// main thread by `scheduleRefresh()`.
    public private(set) var snapshot = SourceControlSnapshot()
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    /// The git command running in the background (Integrate menu), if any;
    /// later commands wait for it.
    private var operation: Task<Void, Never>?
    private var operationID = 0

    /// Outside changes (FSEvents on the repository) and the app becoming
    /// active refresh the snapshot. Off in test runs.
    private var watcher: FileSystemWatcher?
    private var observers: [NSObjectProtocol] = []
    let watchesForChanges: Bool

    init(owner: WorkspaceWindowController) {
        self.owner = owner
        watchesForChanges = !WorkspaceWindowController.isTestProcess
        owner.navigator.onSourceControlRow = { [weak self] key in self?.handleRow(key) }
        owner.navigator.onSourceControlMode = { [weak self] m in self?.setMode(m) }
        guard watchesForChanges else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: owner.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watcher?.stop()
                self?.watcher = nil
            }
        })
    }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Watches the repository once it is known.
    private func watch(_ repo: GitRepository) {
        guard watchesForChanges, watcher == nil else { return }
        let w = FileSystemWatcher { [weak self] paths in
            guard paths.contains(where: FileSystemWatcher.affectsSourceControl) else { return }
            self?.scheduleRefresh()
        }
        w.start(path: repo.root.path)
        watcher = w
    }

    var repository: GitRepository? { Preferences.shared.sourceControlEnabled ? owner.repository : nil }

    public func setMode(_ m: SourceControlNavigatorModel.Mode) {
        mode = m
        owner.navigator.sourceControlMode.selectedSegment = m.rawValue
        refresh()
    }

    /// Rebuilds the navigator tree for the current mode from the last
    /// snapshot (no git call).
    public func refresh() {
        guard Preferences.shared.sourceControlEnabled, let repo = snapshot.repository else { owner.navigator.setSourceControlRoots([]); return }
        let name = repo.root.lastPathComponent, branch = snapshot.currentBranch
        switch mode {
        case .changes:
            owner.navigator.setSourceControlRoots(SourceControlNavigatorModel.changesTree(
                repository: name, branch: branch, changes: snapshot.changes, root: repo.root))
        case .repositories:
            owner.navigator.setSourceControlRoots(SourceControlNavigatorModel.repositoriesTree(
                repository: name, branch: branch, branches: snapshot.branches, recents: snapshot.recentBranches,
                tags: snapshot.tags, stashes: snapshot.stashes, remotes: snapshot.remotes,
                remoteBranches: snapshot.remoteBranches))
        }
        if let c = commitEditor, c.isViewLoaded { c.reload() }
    }

    /// Re-reads git in the background, then updates the status letters,
    /// both navigators, the Integrate menu's state and the debug bar's
    /// branch. Calls while a read runs are folded into one more read.
    public func scheduleRefresh() {
        guard refreshTask == nil else { refreshAgain = true; return }
        refreshTask = Task { [weak self] in
            while true {
                // Nothing holds the window while git runs.
                guard let (enabled, known, url, folder) = self?.refreshInputs() else { return }
                let read = await Task.detached { SourceControlSnapshot.read(workspace: url, known: known, branchFolder: folder) }.value
                guard let self else { return }
                self.apply(read, enabled: enabled)
                if !self.refreshAgain { self.refreshTask = nil; return }
            }
        }
    }

    private func refreshInputs() -> (Bool, GitRepository??, URL, String) {
        refreshAgain = false
        let enabled = Preferences.shared.sourceControlEnabled
        return (enabled, enabled ? owner.knownRepository : .some(nil), owner.session.model.url, owner.sourceControlRoot)
    }

    /// Shows a snapshot (Refresh File Status as it was when it read git on
    /// the main thread).
    func apply(_ read: SourceControlSnapshot, enabled: Bool) {
        owner.debugArea.setBranch(read.debugBarBranch)
        // Settings ▸ Source Control ▸ Enable source control: off clears
        // the badges and reads nothing from git.
        guard enabled else {
            owner.navigator.setFileStatus([:])
            refresh()
            return
        }
        owner.knownRepository = .some(read.repository)
        let previous = snapshot
        snapshot = read
        if read.baselinesMayDiffer(from: previous) {
            for e in owner.editorArea.allEditors where e.fileURL != nil && e.changeBaselines != nil { e.refreshSourceChanges() }
        }
        guard let repo = read.repository else { return }
        watch(repo)
        lastStatus = read.status
        hasRemote = !read.remotes.isEmpty
        owner.navigator.setFileStatus(read.status)
        owner.navigator.setRepository(name: repo.root.lastPathComponent, branches: read.branches,
                                      tags: read.tags, remotes: read.remotes, remoteBranches: read.remoteBranches)
        refresh()
    }

    /// Waits until no source-control read or command is running, and the
    /// commit editor and history have loaded (tests; the user interface
    /// never waits).
    public func idle() async {
        while true {
            if let t = operation { await t.value; continue }
            if let t = refreshTask { await t.value; continue }
            if let c = commitEditor, c.loading != nil || c.working != nil { await c.idle(); continue }
            if let h = history, h.loading != nil || h.inspectorLoading != nil { await h.idle(); continue }
            return
        }
    }

    /// A navigator row: a change opens the commit editor; a branch, tag or
    /// remote branch opens its history.
    public func handleRow(_ key: String) {
        guard repository != nil else { return }
        if key.hasPrefix("change:") {
            selectedChange = String(key.dropFirst(7))
            showCommitEditor(focus: selectedChange)
        } else if key == "repository" {
            selectedChange = nil
            if mode == .changes { showCommitEditor(focus: nil) } else if let b = snapshot.currentBranch { showHistory(ref: b, branch: b) }
        } else if key.hasPrefix("branch:") {
            let b = String(key.dropFirst(7))
            showHistory(ref: "refs/heads/" + b, branch: b)
        } else if key.hasPrefix("tag:") {
            showHistory(ref: "refs/tags/" + key.dropFirst(4), branch: nil)
        } else if key.hasPrefix("remoteBranch:") {
            showHistory(ref: "refs/remotes/" + key.dropFirst(13), branch: nil)
        } else if key.hasPrefix("stash:") {
            showHistory(ref: String(key.dropFirst(6)), branch: nil)
        }
    }

    @discardableResult
    public func showCommitEditor(focus: String?) -> CommitEditorController? {
        guard let repo = repository else { return nil }
        try? owner.editor.save()
        let c = CommitEditorController(repository: repo)
        c.focusPath = focus
        c.onChanged = { [weak self] in self?.owner.refreshFileStatus(nil) }
        install(c)
        setInspector(nil)
        return c
    }

    @discardableResult
    public func showHistory(ref: String, branch: String?) -> BranchHistoryController? {
        guard let repo = repository else { return nil }
        let h = BranchHistoryController(repository: repo, ref: ref)
        var selection = 0
        h.onSelectCommit = { [weak self] commit in
            // The inspector's rows come from git: read off the main thread;
            // a later selection replaces an earlier one still reading.
            selection += 1
            let mine = selection
            let task = Task { [weak self] in
                let sections = await Task.detached { () -> [(String, [(String, String)])] in
                    var sections: [(String, [(String, String)])] = []
                    if let branch { sections.append(("Branch", SourceControlInspector.branchRows(repository: repo, branch: branch))) }
                    if let commit { sections.append(("Commit", SourceControlInspector.commitRows(repository: repo, commit: commit))) }
                    return sections
                }.value
                guard mine == selection else { return }
                self?.setInspector(sections)
            }
            h.inspectorLoading = task
        }
        install(h)
        h.onSelectCommit?(nil)
        return h
    }

    /// The inspector's fourth tab with the given sections (nil removes it).
    public private(set) var inspectorSections: [(String, [(String, String)])]?

    func setInspector(_ sections: [(String, [(String, String)])]?) {
        inspectorSections = sections
        if let sections, !sections.isEmpty {
            installedInspector = true
            owner.inspector.setExtraInspectors([("Source Control", "arrow.triangle.branch")],
                                               provider: { _ in SourceControlInspector.view(sections: sections) },
                                               select: CommandTable.inspectors.count)
        } else if installedInspector {
            installedInspector = false
            owner.inspector.setExtraInspectors([], provider: nil)
        }
    }

    func install(_ vc: NSViewController) {
        hideEditor()
        editorOverlay = vc
        let host = owner.editorArea
        host.addChild(vc)
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: host.view.topAnchor), v.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: host.view.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
    }

    /// Removes the commit editor or history (a file was opened).
    public func hideEditor() {
        guard let vc = editorOverlay else { return }
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        editorOverlay = nil
        setInspector(nil)
    }

    // MARK: Integrate menu

    /// The selected file: the Changes row, else the project navigator's.
    var selectedFile: String? {
        if owner.navigator.selectedIndex == 1 { return selectedChange }
        return owner.navigator.selectedPath ?? owner.editor.fileURL?.path
    }

    /// The Integrate menu's state from the last snapshot: menu validation
    /// never runs git.
    public func menuState() -> IntegrateMenuState {
        var s = IntegrateMenuState()
        guard Preferences.shared.sourceControlEnabled, snapshot.repository != nil else {
            s.selectedFileExists = selectedFile.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return s
        }
        s.hasRepository = true
        s.hasRemote = !snapshot.remotes.isEmpty
        let changes = snapshot.changes
        s.hasStaged = changes.contains(where: \.isStaged)
        s.hasUnstaged = changes.contains(where: \.isUnstaged)
        if let f = selectedFile {
            s.selectedFileExists = FileManager.default.fileExists(atPath: f)
            if let c = changes.first(where: { $0.path == f }) { s.selectedStatus = c.status; s.selectedIsStaged = c.isStaged }
        }
        s.selectedCommit = history?.selectedCommit?.hash
        return s
    }

    /// Runs a git command in the background (after any earlier one),
    /// then reports a failure and refreshes.
    func perform(_ body: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let repo = repository else { NSSound.beep(); return }
        runInBackground(body: { try body(repo) })
    }

    /// Runs `body` off the main thread after the previous command; then
    /// presents its error, refreshes, and reloads the history.
    func runInBackground(body: @escaping @Sendable () throws -> Void, then: (@MainActor () -> Void)? = nil) {
        let previous = operation
        operationID += 1
        let id = operationID
        operation = Task { [weak self] in
            await previous?.value
            let failure = await Task.detached { () -> GitFailure? in
                do { try body(); return nil } catch { return GitFailure(error: error) }
            }.value
            guard let self else { return }
            if let failure, self.owner.window?.isVisible == true { self.owner.presentError(failure.error) }
            then?()
            self.owner.refreshFileStatus(nil)
            if let h = self.history { h.reload() }
            if self.operationID == id { self.operation = nil }
        }
    }

    struct GitFailure: @unchecked Sendable { let error: any Error }

    /// Runs `work` on the main actor after the previous command (it awaits
    /// its own background work); `idle()` waits for it.
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operationID += 1
        let id = operationID
        operation = Task { [weak self] in
            await previous?.value
            await work()
            if let self, self.operationID == id { self.operation = nil }
        }
    }

    /// A one-field prompt; nil when cancelled or not on screen.
    func prompt(_ title: String, _ info: String, placeholder: String) -> String? {
        guard owner.window?.isVisible == true else { return nil }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        f.placeholderString = placeholder
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    func confirm(_ title: String, _ info: String, _ button: String) -> Bool {
        guard owner.window?.isVisible == true else { return true }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

extension WorkspaceWindowController {
    @objc public func scmPush(_ sender: Any?) { sourceControl.perform { try $0.push() } }
    @objc public func scmPull(_ sender: Any?) { sourceControl.perform { try $0.pull() } }
    @objc public func scmFetch(_ sender: Any?) { sourceControl.perform { try $0.fetch() } }
    @objc public func scmStageAll(_ sender: Any?) { sourceControl.perform { try $0.stageAll() } }
    @objc public func scmUnstageAll(_ sender: Any?) { sourceControl.perform { try $0.unstageAll() } }
    @objc public func scmStageSelected(_ sender: Any?) {
        guard let f = sourceControl.selectedFile else { return }
        sourceControl.perform { try $0.stage([f]) }
    }
    @objc public func scmUnstageSelected(_ sender: Any?) {
        guard let f = sourceControl.selectedFile else { return }
        sourceControl.perform { try $0.unstage([f]) }
    }
    @objc public func scmMarkResolved(_ sender: Any?) {
        guard let f = sourceControl.selectedFile else { return }
        sourceControl.perform { try $0.markResolved([f]) }
    }
    @objc public func scmAddSelected(_ sender: Any?) {
        guard let f = sourceControl.selectedFile else { return }
        sourceControl.perform { try $0.stage([f]) }
    }
    @objc public func scmCherryPick(_ sender: Any?) {
        guard let c = sourceControl.history?.selectedCommit else { return }
        guard sourceControl.confirm("Cherry-pick \"\(c.subject)\"?", "Applies commit \(c.shortHash) on top of the current branch.", "Cherry-Pick") else { return }
        sourceControl.perform { try $0.cherryPick(c.hash) }
    }
    @objc public func scmStash(_ sender: Any?) {
        let message = window?.isVisible == true ? sourceControl.prompt("Stash Changes", "Saves uncommitted changes and untracked files to a stash.", placeholder: "Description") : ""
        guard let message else { return }
        sourceControl.perform { try $0.stash(message: message) }
    }
    @objc public func scmDiscardAll(_ sender: Any?) {
        guard sourceControl.confirm("Discard all changes?", "Tracked files return to their last commit; new files move to the Trash.", "Discard All") else { return }
        sourceControl.perform { repo in for c in try repo.changes() { try repo.discard(c.path) } }
    }
    @objc public func scmTrashSelected(_ sender: Any?) {
        guard let f = sourceControl.selectedFile else { return }
        guard sourceControl.confirm("Move \"\(URL(fileURLWithPath: f).lastPathComponent)\" to the Trash?", "", "Move to Trash") else { return }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil) } catch { presentError(error) }
        refreshFileStatus(nil)
    }
    @objc public func scmClone(_ sender: Any?) {
        guard let url = sourceControl.prompt("Clone", "Enter a repository URL.", placeholder: "https://…"), !url.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Clone"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let name = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "Repository"
        let target = dir.appendingPathComponent(name)
        sourceControl.runInBackground(body: { try GitRepository.clone(url, into: target) })
    }
    @objc public func scmNewRepository(_ sender: Any?) {
        let u = session.model.url
        let dir = ["xcodeproj", "xcworkspace", "swift"].contains(u.pathExtension) || !u.hasDirectoryPath ? u.deletingLastPathComponent() : u
        // The next refresh finds the new repository.
        sourceControl.runInBackground(body: { _ = try GitRepository.initialize(at: dir) }, then: { [weak self] in self?.resetRepository() })
    }
}
