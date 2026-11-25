import AppKit

/// Text undo belongs to the file (`specs/ide/source-editor.md`, "Text undo
/// belongs to the file"). Each file shown in a window's editors has its own
/// undo manager: the editor's text view asks for the manager of the file it
/// shows (`SourceEditorController.undoManager(for:)`), so ⌘Z after a file
/// switch acts only on the file on screen and never on the text of the file
/// shown before. The window's own undo manager keeps the navigator's and
/// the Find navigator's entries.
///
/// An entry made by a text view applies to that text view's text. Two rules
/// keep every entry on the text it was made for:
/// - The file's history is used by the editors showing the file; an editor
///   that made entries and stops showing the file while another editor
///   still shows it takes the history with it (it is cleared), and an editor
///   that starts showing a file whose entries were made by an editor no
///   longer showing it starts with a cleared history. Two editors on one
///   file share its history and its text (`SourceEditorController.mirror`).
/// - The history is kept only while the file's text is the text it was left
///   with: a file changed on disk while no editor showed it, or reloaded
///   after a change on disk, starts again with an empty history.
///
/// Closing the file's last editor (File ▸ Close "file") ends its history.
@MainActor
public final class TextUndoHistories {
    @MainActor final class History {
        let manager = UndoManager()
        /// The editors whose text views made the entries.
        var contributors: [Weak] = []
        /// The text when the last editor showing the file left it.
        var leftText: String?
        var observers: [NSObjectProtocol] = []
        isolated deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }
    }

    struct Weak {
        weak var editor: SourceEditorController?
    }

    private var histories: [String: History] = [:]
    /// The editors of the window (the editor area's, or the lone editor).
    var liveEditors: () -> [SourceEditorController] = { [] }
    /// The manager of an editor that shows no file: never anything to undo.
    let noFile = UndoManager()

    public init() {}

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The files with a history (tests).
    public var paths: [String] { histories.keys.sorted() }

    /// The undo manager of `url`'s text (made on first use).
    public func manager(for url: URL) -> UndoManager {
        history(Self.key(url)).manager
    }

    private func history(_ key: String) -> History {
        if let h = histories[key] { return h }
        let h = History()
        histories[key] = h
        // After an undo or redo, the editors whose text it changed run
        // their change path (the text view sends no change notification).
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            h.observers.append(NotificationCenter.default.addObserver(forName: name, object: h.manager, queue: nil) { [weak self, weak h] _ in
                MainActor.assumeIsolated {
                    guard let self, let h, let key = self.histories.first(where: { $0.value === h })?.key else { return }
                    for e in self.liveEditors() where e.fileURL.map(Self.key) == key { e.textChangedByUndo() }
                }
            })
        }
        return h
    }

    /// The live editors other than `e` showing `key`.
    func others(showing key: String, besides e: SourceEditorController) -> [SourceEditorController] {
        liveEditors().filter { $0 !== e && $0.fileURL.map(Self.key) == key }
    }

    /// `e`'s text view changed the file's text (not a mirrored change).
    func noteEdit(by e: SourceEditorController) {
        guard let url = e.fileURL else { return }
        let h = history(Self.key(url))
        if !h.contributors.contains(where: { $0.editor === e }) { h.contributors.append(Weak(editor: e)) }
    }

    /// `e` stops showing `url` (it shows another file, a non-text view, or
    /// nothing). `text` is what it showed.
    func editor(_ e: SourceEditorController, left url: URL, text: String) {
        let key = Self.key(url)
        guard let h = histories[key] else { return }
        if others(showing: key, besides: e).isEmpty {
            h.leftText = text
        } else if h.contributors.contains(where: { $0.editor === e }) {
            clear(key)
        }
    }

    /// `e` starts showing `url` with `text`. The history stays only when its
    /// text is still `text` and every entry was made by an editor showing
    /// the file (or by `e`).
    func editor(_ e: SourceEditorController, entered url: URL, text: String) {
        prune()
        let key = Self.key(url)
        guard let h = histories[key] else { return }
        let showing = others(showing: key, besides: e)
        if showing.isEmpty, let left = h.leftText, left != text { return clear(key) }
        let foreign = h.contributors.contains { c in
            guard let c = c.editor else { return true }
            return c !== e && !showing.contains { $0 === c }
        }
        if foreign { clear(key) }
        h.leftText = nil
    }

    /// The file's history is cleared (a reload after a change on disk).
    func clear(_ url: URL) { clear(Self.key(url)) }

    private func clear(_ key: String) {
        guard let h = histories[key] else { return }
        h.manager.removeAllActions()
        h.contributors = []
        h.leftText = nil
    }

    /// File ▸ Close "file": with no other editor showing it, its history ends.
    func close(_ url: URL, by e: SourceEditorController) {
        let key = Self.key(url)
        guard others(showing: key, besides: e).isEmpty, let h = histories.removeValue(forKey: key) else { return }
        h.manager.removeAllActions()
    }

    /// Files moved in the navigator keep their histories (by old path → new
    /// path; a moved folder moves the files in it). The editors still on
    /// the old path open the new one next: the history keeps the text they
    /// show, so it stays only if the moved file still has it.
    func move(_ moved: [String: String]) {
        let live = liveEditors()
        for (old, new) in moved {
            let o = URL(fileURLWithPath: old).standardizedFileURL.path
            let n = URL(fileURLWithPath: new).standardizedFileURL.path
            for key in histories.keys where key == o || key.hasPrefix(o + "/") {
                guard let h = histories.removeValue(forKey: key) else { continue }
                if let shown = live.first(where: { $0.fileURL.map(Self.key) == key }) { h.leftText = shown.text }
                histories[n + key.dropFirst(o.count)] = h
            }
        }
    }

    /// Histories no live editor can use again go: every entry was made by
    /// an editor that closed.
    private func prune() {
        let live = liveEditors()
        for (key, h) in histories {
            let anyLive = h.contributors.contains { c in live.contains { $0 === c.editor } }
            let shown = live.contains { $0.fileURL.map(Self.key) == key }
            if !anyLive, !shown {
                histories[key] = nil
                h.manager.removeAllActions()
            }
        }
    }

    /// The text of a live editor other than `e` showing `url`, and whether
    /// it is unsaved (a new editor on an open file shows that editor's text).
    func shownText(of url: URL, besides e: SourceEditorController) -> (text: String, isDirty: Bool)? {
        others(showing: Self.key(url), besides: e).first.map { ($0.text, $0.isDirty) }
    }

    /// `e` changed its file's text: the other editors on the file show it too.
    func mirror(from e: SourceEditorController) {
        guard let url = e.fileURL else { return }
        for o in others(showing: Self.key(url), besides: e) { o.mirror(e.text, isDirty: e.isDirty) }
    }

    /// `e` saved its file: the other editors on the file are saved too.
    func noteSaved(by e: SourceEditorController) {
        guard let url = e.fileURL else { return }
        for o in others(showing: Self.key(url), besides: e) where o.text == e.text { o.isDirty = false }
    }
}
