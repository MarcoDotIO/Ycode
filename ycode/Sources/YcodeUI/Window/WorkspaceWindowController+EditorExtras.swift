import AppKit

/// Editor wiring added with reference-ui-4.md §7/§9: the Quick Help links
/// and the empty editor's Open Quickly field and Recent Files.
extension WorkspaceWindowController {
    func wireEditorExtras(_ e: SourceEditorController) {
        QuickHelpView.onOpenFile = { [weak self] f in self?.open(path: f, line: nil) }
        QuickHelpView.onOpenDocumentation = { name in
            var c = URLComponents(string: "https://developer.apple.com/search/")!
            c.queryItems = [URLQueryItem(name: "q", value: name)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        }
        e.onBecameEmpty = { [weak self, weak e] in
            guard let self, let e else { return }
            self.showEmptyEditor(e)
            self.updateWindowTitle()
        }
        if e.fileURL == nil && e.auxiliary == nil { showEmptyEditor(e) }
        wireChangeGutter(e)  // reference-ui-5.md §6.3
    }

    /// The empty editor: Recent Files (most recent first) and Open Quickly.
    /// The candidates come from the workspace index (read in the
    /// background); the view updates when a fresh read arrives.
    func showEmptyEditor(_ e: SourceEditorController) {
        let recent = Array(navigator.recentFiles.reversed()), root = Self.breadcrumbRoot(session.model.url)
        withWorkspaceCandidates { [weak self, weak e] candidates in
            guard let self, let e, e.fileURL == nil, e.auxiliary == nil else { return }
            e.showEmptyState(recent: recent, candidates: candidates, root: root) { [weak self, weak e] path, line in
                guard let self else { return }
                if let e, let i = self.editorArea.tab.editors.firstIndex(where: { $0 === e }) { self.editorArea.tab.focused = i }
                self.open(path: path, line: line)
            }
        }
    }

    /// Calls `apply` with the last workspace index at once (empty before
    /// the first read), then again with a fresh one read off the main
    /// thread (every source file is read and scanned for symbols).
    func withWorkspaceCandidates(_ apply: @escaping @MainActor ([FuzzyMatch.Candidate]) -> Void) {
        let index = candidateIndex
        apply(index.value ?? [])
        index.waiting.append(apply)
        guard index.task == nil else { return }
        let root = session.model.root
        index.task = Task {
            let fresh = await Task.detached { FuzzyMatch.candidates(in: root) }.value
            index.value = fresh
            let waiting = index.waiting
            index.waiting = []
            index.task = nil
            for w in waiting { w(fresh) }
        }
    }

    /// Waits for the workspace index read (tests).
    public func workspaceCandidatesIdle() async {
        while let t = candidateIndex.task { await t.value }
    }

    /// The folder above the workspace's folder, so breadcrumbs start with it.
    static func breadcrumbRoot(_ url: URL) -> String {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let folder = isDir && !["xcodeproj", "xcworkspace"].contains(url.pathExtension) ? url : url.deletingLastPathComponent()
        return folder.deletingLastPathComponent().path
    }
}

/// Open Quickly's candidates, kept between reads.
@MainActor final class WorkspaceCandidateIndex {
    var value: [FuzzyMatch.Candidate]?
    var task: Task<Void, Never>?
    var waiting: [@MainActor ([FuzzyMatch.Candidate]) -> Void] = []
}
