import AppKit
import YcodeIDECore

// Bookmark commands of the workspace window; the bookmark model is in
// YcodeIDECore (Session/Bookmarks.swift).
extension WorkspaceWindowController {
    var bookmarks: BookmarkStore {
        if let b = bookmarkStoreHolder.store { return b }
        let b = BookmarkStore(containerURL: session.model.url, isPackage: session.model.kind == .package)
        b.onChange = { [weak self, weak b] in if let b { self?.navigator.setBookmarks(b.all) } }
        navigator.onSetBookmarkDone = { [weak b] bookmark, done in b?.setDone(bookmark, done) }
        bookmarkStoreHolder.store = b
        navigator.setBookmarks(b.all)
        return b
    }

    /// The trimmed text of a line of the focused editor.
    func lineText(_ line: Int) -> String {
        guard let r = editor.textView.lineIndex.range(ofLine: line) else { return "" }
        return (editor.text as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
    }

    /// Edit ▸ Bookmark Line: the caret's line, labelled with its text.
    @objc public func bookmarkLine(_ sender: Any?) { addLineBookmark() }

    @discardableResult
    public func addLineBookmark() -> Bookmark? {
        guard let path = editor.fileURL?.path else { NSSound.beep(); return nil }
        let line = editor.currentLine
        let b = Bookmark(file: path, line: line, label: lineText(line).isEmpty ? "Line \(line)" : lineText(line))
        bookmarks.add(b)
        return b
    }

    /// Edit ▸ Bookmark File: the focused file, labelled with its name.
    @objc public func bookmarkFile(_ sender: Any?) { addFileBookmark() }

    @discardableResult
    public func addFileBookmark() -> Bookmark? {
        guard let url = editor.fileURL else { NSSound.beep(); return nil }
        let b = Bookmark(file: url.path, line: nil, label: url.lastPathComponent)
        bookmarks.add(b)
        return b
    }

    /// "With Dialog": asks for the label first (only for a window on screen).
    @objc public func bookmarkLineWithDialog(_ sender: Any?) { askLabel(default: lineText(editor.currentLine)) { [weak self] l in
        guard let self, let b = self.addLineBookmark() else { return }
        self.bookmarks.add(Bookmark(file: b.file, line: b.line, label: l))
    } }

    @objc public func bookmarkFileWithDialog(_ sender: Any?) { askLabel(default: editor.fileURL?.lastPathComponent ?? "") { [weak self] l in
        guard let self, let b = self.addFileBookmark() else { return }
        self.bookmarks.add(Bookmark(file: b.file, line: nil, label: l))
    } }

    func askLabel(default value: String, _ done: @escaping (String) -> Void) {
        guard let window, window.isVisible else { return }
        let a = NSAlert()
        a.messageText = "Bookmark"
        let f = NSTextField(string: value)
        f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { done(f.stringValue) } }
    }

    func jumpBookmark(backward: Bool, workspace: Bool) {
        guard let path = editor.fileURL?.path ?? bookmarks.all.first?.file,
              let b = bookmarks.next(from: path, line: editor.fileURL == nil ? 0 : editor.currentLine, backward: backward, workspace: workspace) else {
            NSSound.beep()
            return
        }
        open(path: b.file, line: b.line)
    }

    @objc public func jumpToNextBookmark(_ sender: Any?) { jumpBookmark(backward: false, workspace: false) }
    @objc public func jumpToPreviousBookmark(_ sender: Any?) { jumpBookmark(backward: true, workspace: false) }
    @objc public func jumpToNextBookmarkInWorkspace(_ sender: Any?) { jumpBookmark(backward: false, workspace: true) }
    @objc public func jumpToPreviousBookmarkInWorkspace(_ sender: Any?) { jumpBookmark(backward: true, workspace: true) }
}
