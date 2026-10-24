import AppKit

/// A bookmark: a file, or a line in it, with a label. See
/// `specs/ide/navigators.md` §Bookmarks.
public struct Bookmark: Codable, Equatable, Sendable {
    public var file: String
    /// 1-based; nil for a file bookmark.
    public var line: Int?
    public var label: String
    /// Marked done from the bookmark's context menu; saved as `done: true`
    /// and left out otherwise (reference-ui-5.md §5.2, Incomplete Items).
    public var done: Bool?
    public init(file: String, line: Int?, label: String, done: Bool? = nil) {
        self.file = file
        self.line = line
        self.label = label
        self.done = done
    }
}

/// The workspace's bookmarks, saved per user next to the workspace:
/// `<container>/xcuserdata/<user>.xcuserdatad/ycode-bookmarks.json`
/// (packages: `.swiftpm/xcode/xcuserdata/…`).
@MainActor
public final class BookmarkStore {
    public private(set) var all: [Bookmark] = []
    let fileURL: URL?
    var onChange: (() -> Void)?

    init(containerURL: URL, isPackage: Bool) {
        let user = NSUserName()
        let base = isPackage ? containerURL.appendingPathComponent(".swiftpm/xcode") : containerURL
        fileURL = base.appendingPathComponent("xcuserdata/\(user).xcuserdatad/ycode-bookmarks.json")
        if let f = fileURL, let d = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([Bookmark].self, from: d) { all = list }
    }

    func save() {
        guard let f = fileURL else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(all).write(to: f, options: .atomic)
        onChange?()
    }

    /// Adds a bookmark (a second bookmark on the same line or file replaces the first).
    public func add(_ b: Bookmark) {
        all.removeAll { $0.file == b.file && $0.line == b.line }
        all.append(b)
        all.sort { ($0.file, $0.line ?? 0) < ($1.file, $1.line ?? 0) }
        save()
    }

    /// Marks a bookmark done (or not done).
    public func setDone(_ b: Bookmark, _ done: Bool) {
        guard let i = all.firstIndex(where: { $0.file == b.file && $0.line == b.line }) else { return }
        all[i].done = done ? true : nil
        save()
    }

    public func remove(_ b: Bookmark) {
        all.removeAll { $0 == b }
        save()
    }

    /// The next (or previous) line bookmark after `line` in `file`, wrapping
    /// within the file; with `workspace`, continuing into the other files
    /// in path order.
    public func next(from file: String, line: Int, backward: Bool, workspace: Bool) -> Bookmark? {
        let lines = all.filter { $0.line != nil }
        let ordered = workspace ? lines : lines.filter { $0.file == file }
        guard !ordered.isEmpty else { return nil }
        func key(_ b: Bookmark) -> (String, Int) { (b.file, b.line!) }
        let here = (file, line)
        if backward { return ordered.last { key($0) < here } ?? ordered.last }
        return ordered.first { key($0) > here } ?? ordered.first
    }
}

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
