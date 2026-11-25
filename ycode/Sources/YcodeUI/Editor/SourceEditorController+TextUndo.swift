import AppKit

/// Text undo belongs to the file (`specs/ide/source-editor.md`, "Text undo
/// belongs to the file"; TextUndoHistories.swift). The editor reuses one
/// text view for every file it shows; its undo manager is the shown file's,
/// so Edit ▸ Undo (⌘Z) and Redo (⇧⌘Z) act only on that file, and Undo is
/// disabled in a file with no edits of its own. Two editors on one file
/// show one text and share its history.
extension SourceEditorController {
    /// The text view's undo manager: the shown file's history (an editor
    /// with no file, or read-only text, has nothing to undo).
    public func undoManager(for view: NSTextView) -> UndoManager? {
        fileURL.map { textUndo.manager(for: $0) } ?? textUndo.noFile
    }

    /// The file's undo history (tests; nil with no file).
    public var fileUndoManager: UndoManager? { fileURL.map { textUndo.manager(for: $0) } }

    /// The editor stops showing `url` (its text view still holds its text).
    func leftFile(_ url: URL) {
        textView.breakUndoCoalescing()   // typing in the next file starts its own entry
        textUndo.editor(self, left: url, text: textView.string)
    }

    /// The editor shows `url` with `text`; `reloaded` when it showed the
    /// file already and the text on disk changed under it.
    func enteredFile(_ url: URL, text: String, reloaded: Bool) {
        if reloaded { textUndo.clear(url) }
        textUndo.editor(self, entered: url, text: text)
    }

    /// Undo and Redo change the text view's text without a change
    /// notification: the editor notes the storage's change, and the file's
    /// history, after its undo or redo, has the editors that changed run
    /// the editor's change path (`textChangedByUndo`). Without it the
    /// editor kept its unedited state after ⌘Z, and the disk follower put
    /// the saved text back a second later.
    func observeTextStorageForUndo() {
        guard undoStorageObserver == nil, let storage = textView.textStorage else { return }
        undoStorageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage,
                                                                     queue: nil) { [weak self] n in
            guard let mask = (n.object as? NSTextStorage)?.editedMask, mask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.storageChangedOutsideEdit = true }
        }
    }

    /// The file's undo or redo changed this editor's text.
    func textChangedByUndo() {
        guard storageChangedOutsideEdit else { return }
        storageChangedOutsideEdit = false
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// The text view changed the text (typing, a command, Undo or Redo):
    /// the history notes who made its entries, and the other editors on the
    /// file show the change.
    func textChangedForUndo() {
        textUndo.noteEdit(by: self)
        textUndo.mirror(from: self)
    }

    /// Shows the text another editor on the same file changed to, without
    /// an entry of its own (the change is that editor's entry, in the
    /// shared history) and without moving this editor's scroll position.
    func mirror(_ new: String, isDirty dirty: Bool) {
        let old = textView.string as NSString
        let n = new as NSString
        guard old as String != new else { isDirty = dirty; return }
        var start = 0
        while start < old.length, start < n.length, old.character(at: start) == n.character(at: start) { start += 1 }
        var oEnd = old.length, nEnd = n.length
        while oEnd > start, nEnd > start, old.character(at: oEnd - 1) == n.character(at: nEnd - 1) { oEnd -= 1; nEnd -= 1 }
        let range = NSRange(location: start, length: oEnd - start)
        let replacement = n.substring(with: NSRange(location: start, length: nEnd - start))
        let delta = nEnd - oEnd
        func map(_ o: Int) -> Int { o >= oEnd ? o + delta : min(o, nEnd) }
        let sel = textView.selectedRange()
        let a = map(sel.location), b = map(NSMaxRange(sel))
        isMirroringEdit = true
        let allows = textView.allowsUndo
        textView.allowsUndo = false
        defer {
            textView.allowsUndo = allows
            isMirroringEdit = false
        }
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: a, length: max(0, b - a)))
        isDirty = dirty
    }
}
