import AppKit
import YcodeIDECore
import YcodeLanguage

/// The window's side of the Find navigator (`specs/ide/navigators.md`
/// §Find navigator, "Ycode implementation"): unsaved editors searched,
/// Replace through open editors and the disk with one undo step for all
/// files, the semantic kinds through the language server, and the Find
/// menu's workspace items.
extension WorkspaceWindowController {
    func installFindHooks() {
        navigator.findBuffers = { [weak self] in self?.unsavedFindBuffers() ?? [:] }
        navigator.findOpenFiles = { [weak self] in self?.openFindFiles() ?? [] }
        navigator.findSemantic = { [weak self] q in await SemanticFind.run(q, service: self?.session.language?.client) }
        navigator.findReplaceIO = findReplaceIO
        navigator.findPerformReplace = { [weak self] plan in self?.performWorkspaceReplace(plan) ?? plan.apply(.disk) }
        navigator.onOpenFindMatch = { [weak self] path, m in self?.openFindMatch(path, m) }
    }

    /// The editor showing a file, if any.
    func findEditor(for path: String) -> SourceEditorController? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return allEditors.first { $0.fileURL?.standardizedFileURL.path == p }
    }

    /// Text of editors with unsaved changes, by path (as given and standardized).
    func unsavedFindBuffers() -> [String: String] {
        var out: [String: String] = [:]
        for e in allEditors where e.isDirty {
            guard let url = e.fileURL else { continue }
            out[url.path] = e.text
            out[url.standardizedFileURL.path] = e.text
        }
        return out
    }

    /// Files open in this window's editors, in tab order.
    func openFindFiles() -> [String] {
        var seen = Set<String>()
        return allEditors.compactMap { $0.fileURL?.path }.filter { seen.insert($0).inserted }
    }

    /// Reads an open file from its editor (unsaved changes included) and
    /// writes it there as one undoable edit; other files go to the disk
    /// (the language server is told).
    var findReplaceIO: ReplaceIO {
        ReplaceIO(read: { [weak self] path in
            MainActor.assumeIsolated {
                if let e = self?.findEditor(for: path) { return e.text }
                return try? String(contentsOfFile: path, encoding: .utf8)
            }
        }, write: { [weak self] path, text in
            MainActor.assumeIsolated {
                guard let self else { return false }
                if let e = self.findEditor(for: path) { return e.replaceText(with: text, actionName: "Replace") }
                guard (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
                self.session.language?.fileChangedOnDisk(URL(fileURLWithPath: path))
                return true
            }
        })
    }

    /// Replace (All) as one step of the window's undo manager: the open
    /// editors' edits, and an action that puts the files changed on disk
    /// back (or forward, on redo).
    func performWorkspaceReplace(_ plan: ReplacePlan) -> ReplaceTransaction {
        let um = window?.undoManager
        um?.beginUndoGrouping()
        let t = plan.apply(findReplaceIO)
        var disk = t
        disk.changes = t.changes.filter { findEditor(for: $0.path) == nil }
        if !disk.changes.isEmpty { registerDiskReplace(disk, toOriginal: true) }
        um?.setActionName(t.title)
        um?.endUndoGrouping()
        return t
    }

    private func registerDiskReplace(_ t: ReplaceTransaction, toOriginal: Bool) {
        window?.undoManager?.registerUndo(withTarget: self) { wc in
            MainActor.assumeIsolated {
                _ = ReplaceHistory.restore(t, wc.findReplaceIO, toOriginal: toOriginal)
                wc.registerDiskReplace(t, toOriginal: !toOriginal)
                wc.navigator.rerunAfterReplace()
            }
        }
    }

    /// Opens a match and selects it.
    func openFindMatch(_ path: String, _ m: WorkspaceSearch.Match) {
        openFromNavigator(path: path, line: m.line)
        if editor.fileURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path { editor.selectFindMatch(m.range) }
    }

    func showFindNavigator() {
        navigatorItem.isCollapsed = false
        navigator.select(3)
    }

    /// The focused editor's selected text, if any.
    var selectedSourceText: String? {
        guard editor.fileURL != nil else { return nil }
        let sel = editor.textView.selectedRange()
        return sel.length > 0 ? (editor.text as NSString).substring(with: sel) : nil
    }

    // MARK: Find menu

    /// Find ▸ Find and Replace in Workspace… (⌥⇧⌘F): the Find navigator in
    /// Replace mode, searching for the selection if any.
    @objc public func findAndReplaceInWorkspace(_ sender: Any?) {
        showFindNavigator()
        navigator.setFindOptions(mode: .replace)
        if let q = selectedSourceText { navigator.find(q) }
        window?.makeFirstResponder(navigator.findField)
    }

    /// Find ▸ Find Next / Previous in Workspace (⌃⌘G / ⌃⇧⌘G).
    @objc public func findNextInWorkspace(_ sender: Any?) { navigator.stepFindResult(forward: true) }
    @objc public func findPreviousInWorkspace(_ sender: Any?) { navigator.stepFindResult(forward: false) }

    /// Find ▸ Find Selected Text in Workspace: the selection as Text,
    /// Containing.
    @objc public func findSelectedTextInWorkspace(_ sender: Any?) { findSelection(match: .containing) }
    /// Find ▸ Find Selected Words in Workspace: the selection as Text,
    /// Matching Word.
    @objc public func findSelectedWordsInWorkspace(_ sender: Any?) { findSelection(match: .matchingWord) }

    func findSelection(match: FindQuery.Match) {
        guard let q = selectedSourceText else { NSSound.beep(); return }
        showFindNavigator()
        navigator.setFindOptions(kind: .text, match: match.rawValue)
        navigator.noteRecentSearch(q)
        navigator.find(q)
    }

    @objc public func findAncestorTypes(_ sender: Any?) { Task { await findTypes(.ancestorTypes) } }
    @objc public func findDescendentTypes(_ sender: Any?) { Task { await findTypes(.descendentTypes) } }
    @objc public func findConformingTypes(_ sender: Any?) { Task { await findTypes(.conformingTypes) } }

    /// Find ▸ Find Ancestor / Descendent / Conforming Types: the type
    /// hierarchy of the symbol at the caret in the Find navigator.
    @discardableResult
    public func findTypes(_ kind: FindQuery.Kind) async -> SemanticFind.Result? {
        guard let (url, p) = caretLocation else { NSSound.beep(); return nil }
        try? editor.save()
        let seed = SemanticFind.Seed(url: url, position: p, name: symbolName(at: editor.textView.selectedRange().location))
        let r = await SemanticFind.run(kind, at: seed, service: session.language?.client)
        showFindNavigator()
        navigator.showSemanticResult(r)
        return r
    }

    /// Enablement of the items above; nil = not one of them.
    func validateFindMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(findNextInWorkspace(_:)), #selector(findPreviousInWorkspace(_:)): return navigator.findModel.matchCount > 0
        case #selector(findSelectedTextInWorkspace(_:)), #selector(findSelectedWordsInWorkspace(_:)): return selectedSourceText != nil
        case #selector(findAncestorTypes(_:)), #selector(findDescendentTypes(_:)), #selector(findConformingTypes(_:)):
            return editor.fileURL != nil && editor.auxiliary == nil && session.language != nil
        default: return nil
        }
    }
}
