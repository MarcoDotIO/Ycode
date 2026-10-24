import AppKit

/// Code Review mode (`specs/ide/reference-ui-4.md` §15): inline or side by
/// side, the change stepper, swapping, and the source picker.
extension WorkspaceWindowController {
    /// Starts Code Review on the focused file in its comparison style.
    @discardableResult
    func startCodeReview() -> Bool {
        guard let url = editor.fileURL, let repo = repository else { NSSound.beep(); return false }
        let source = editor.review.rightSource
        // After a swap the right side may be the working copy itself.
        let baseline = source == .uncommittedChanges ? editor.textView.string : (source.baseline(of: url.path, in: repo) ?? "")
        // §15.1: the controls live in the debug bar.
        editor.review.host = { [weak self] bar in self?.debugArea.setReviewControls(bar) }
        // A left source other than the working copy compares two stored
        // versions, side by side and read-only.
        let left = editor.review.leftSource
        editor.review.leftText = left == .uncommittedChanges ? nil : (left.leftContents(of: url.path, in: repo) ?? "")
        if editor.comparisonStyle == .inline && editor.review.leftText == nil {
            editor.showInlineComparison(baseline: baseline, source: source)
        } else {
            editor.showSideBySideComparison(baseline: baseline, source: source)
        }
        let bar = editor.reviewBar
        bar.onSwap = { [weak self] in
            guard let self else { return }
            self.editor.swapReviewSources()
            self.endCodeReview(); self.startCodeReview()
        }
        bar.onPick = { [weak self] left, anchor in self?.showReviewSourcePicker(left: left, anchor: anchor) }
        return true
    }

    func endCodeReview() { endCodeReview(in: editor) }

    func endCodeReview(in e: SourceEditorController) {
        e.hideInlineComparison()
        e.hideComparison()
    }

    /// Editor ▸ Inline Comparison / Side By Side Comparison.
    @objc public func showInlineComparison(_ sender: Any?) { setComparisonStyle(.inline) }
    @objc public func showSideBySideComparison(_ sender: Any?) { setComparisonStyle(.sideBySide) }

    func setComparisonStyle(_ s: ComparisonStyle) {
        let active = editor.isShowingComparison || editor.isShowingInlineComparison
        editor.comparisonStyle = s
        if active { endCodeReview(); startCodeReview() }
    }

    /// The source picker for one side of the comparison.
    @discardableResult
    public func reviewSourcePicker(left: Bool) -> ReviewSourcePicker? {
        guard let repo = repository else { return nil }
        let branches = (try? repo.branches()) ?? []
        let tags = (try? repo.tags()) ?? []
        let commits = repo.recentCommits(limit: 50, path: editor.fileURL?.path)
        let recents = [editor.review.leftSource, editor.review.rightSource].compactMap { s -> String? in
            if case .branch(let b) = s { return b } else { return nil }
        }
        let columns = CodeReviewModel.pickerColumns(branches: branches + tags, recents: recents, commits: commits)
        var branchSources: [String: ReviewSource] = [:]
        for b in branches + tags { branchSources[b.name] = .branch(b.name) }
        let commitSources: [ReviewSource] = [.uncommittedChanges, .unstagedChanges, .stagedChanges]
            + commits.map { .commit(hash: $0.hash, title: "\($0.shortHash) \($0.subject)") }
        let picker = ReviewSourcePicker(columns: columns, commitSources: commitSources, branchSources: branchSources)
        picker.onChoose = { [weak self] s in
            guard let self else { return }
            self.editor.setReviewSource(s, left: left)
            // Either side re-runs the comparison.
            self.endCodeReview(); self.startCodeReview()
        }
        return picker
    }

    func showReviewSourcePicker(left: Bool, anchor: NSView) {
        guard let picker = reviewSourcePicker(left: left), window?.isVisible == true else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = picker
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}
