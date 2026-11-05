import Foundation
import Observation
import YcodeEditorKit
import YcodeIDECore
import YcodeLanguage

/// The Quick Help popover over the editor (`language.md` §Features): the
/// hover of the symbol at `offset` of `path`.
public struct QuickHelpPopover: Equatable, Identifiable, Sendable {
    public var id: Int
    public var path: String
    /// UTF-16 offset of the symbol's start (the popover hangs under it).
    public var offset: Int
    public var document: QuickHelpDocument
    /// The hover as plain text (`QuickHelpFormatter.plain`).
    public var text: String
}

/// Editor ▸ Refactor ▸ Rename… in progress: the symbol the server accepted.
public struct RenameRequest: Equatable, Sendable {
    public var path: String
    public var position: Position
    /// The symbol's UTF-16 range in the file.
    public var range: NSRange
    public var oldName: String
}

/// The state of the language features of one workspace window (Quick
/// Help, Jump to Definition, rename, references), over the session's
/// language server. See `specs/ide/language.md` and `specs/ide/refactoring.md`.
@MainActor
@Observable
public final class ShellLanguageFeatures {
    /// The inspector's tabs, in capsule order (⌥⌘1 File, ⌥⌘3 Quick Help).
    public enum InspectorTab: Int, CaseIterable, Sendable { case file = 0, history = 1, quickHelp = 2 }

    public var inspectorTab: InspectorTab = .file
    /// The popover shown over the editor.
    public internal(set) var popover: QuickHelpPopover?
    /// The Quick Help inspector's content (the symbol at the insertion point).
    public internal(set) var inspectorHelp: QuickHelpDocument?
    /// The rename sheet is up for this symbol.
    public internal(set) var rename: RenameRequest?
    /// A rename across several files, waiting for the user (the sheet's preview).
    public internal(set) var renamePreview: RenamePreview?
    /// The rename sheet asked the server and is waiting.
    public internal(set) var isRenaming = false
    /// The occurrences of the symbol being renamed in the open file.
    public internal(set) var highlights: [NSRange] = []
    /// What the last request found nothing for ("No definition found"),
    /// shown briefly in the editor.
    public internal(set) var notice: String?
    @ObservationIgnored var popoverCount = 0
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var inspectorTask: Task<Void, Never>?
    /// The text of files a refactoring rewrote on disk (not open), by path.
    @ObservationIgnored public internal(set) var diskBackups: [String: String] = [:]
    /// The declaration the insertion point is in (the jump bar's symbol
    /// component), and the open file's declarations (its document items menu).
    public internal(set) var caretSymbol: SymbolScanner.Symbol?
    public internal(set) var documentSymbols: [SymbolScanner.Symbol] = []
    @ObservationIgnored var symbolsRevision: (path: String, revision: Int)?
    @ObservationIgnored var symbolTask: Task<Void, Never>?
    /// Opens a web address (the app sets it).
    @ObservationIgnored public var openExternally: (URL) -> Void = { _ in }

    public init() {}
}

extension WorkspaceShellModel {
    // MARK: Positions

    /// The LSP position (0-based line, UTF-16 column) of an offset of `d`.
    func lspPosition(_ offset: Int, in d: EditorDocument) -> Position {
        let doc = d.buffer.document
        let o = min(max(0, offset), d.buffer.length)
        let line = doc.line(containing: o)
        return Position(line: line, character: o - doc.lineStart(line))
    }

    /// The offset of an LSP position in `d`, clamped to its line.
    func offset(of p: Position, in d: EditorDocument) -> Int {
        let doc = d.buffer.document
        guard p.line < doc.lineCount else { return d.buffer.length }
        let r = doc.lineRange(max(0, p.line))
        return min(r.lowerBound + max(0, p.character), r.upperBound)
    }

    /// The open file and the position of `offset` (the caret by default),
    /// after the server has its current text; nil without a server.
    func languageTarget(at offset: Int? = nil) -> (url: URL, position: Position, document: EditorDocument)? {
        guard let d = editor, let language = session.language, d.readOnlyReason == nil else { return nil }
        let url = URL(fileURLWithPath: d.path)
        languageUpdates.removeValue(forKey: d.path)?.cancel()
        language.change(url, text: d.buffer.text)
        // A selection asks about its start (a selected name, as a jump leaves it).
        return (url, lspPosition(offset ?? d.buffer.selection.range.lowerBound, in: d), d)
    }

    /// The language commands need an editable file and a running server.
    func isLanguageCommandEnabled(_ c: ShellCommand) -> Bool {
        guard let d = editor, d.readOnlyReason == nil, session.language != nil else { return false }
        return c != .renameSymbol || !d.buffer.isReadOnly
    }

    func performLanguage(_ c: ShellCommand) {
        switch c {
        case .jumpToDefinition: Task { await jumpToDefinition() }
        case .jumpToOriginalSource: Task { await jumpToOriginalSource() }
        case .showQuickHelp: Task { await showQuickHelp() }
        case .renameSymbol: Task { await beginRename() }
        case .findSelectedSymbol: Task { await findSelectedSymbolInWorkspace() }
        case .showCallHierarchy: Task { await findCallHierarchy() }
        case .showFileInspector: showInspector(.file)
        case .showQuickHelpInspector: showInspector(.quickHelp)
        default: break
        }
    }

    /// View ▸ Inspectors: shows the inspector at that tab.
    public func showInspector(_ tab: ShellLanguageFeatures.InspectorTab) {
        isInspectorShown = true
        languageFeatures.inspectorTab = tab
        if tab == .quickHelp { refreshQuickHelpInspector() }
    }

    /// A message for a request that found nothing; it goes after a moment.
    func noteLanguage(_ message: String) {
        let f = languageFeatures
        f.notice = message
        f.noticeTask?.cancel()
        f.noticeTask = Task { [weak f] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            f?.notice = nil
        }
    }

    // MARK: Jump to Definition

    /// Navigate ▸ Jump to Definition (⌃⌘J), and ⌘- or Ctrl-click: asks the
    /// server where the symbol at `offset` (the caret) is defined, opens that
    /// file and selects the symbol there. False when there is none.
    @discardableResult
    public func jumpToDefinition(at offset: Int? = nil) async -> Bool {
        guard let t = languageTarget(at: offset) else { return false }
        dismissQuickHelp()
        let session = session
        guard let loc = await withLanguageTimeout(nil, { await session.definition(t.url, at: t.position) }) else {
            noteLanguage("No definition found")
            return false
        }
        reveal(loc)
        return true
    }

    /// Navigate ▸ Jump to Original Source: the declaration, else the definition.
    @discardableResult
    public func jumpToOriginalSource() async -> Bool {
        guard let t = languageTarget() else { return false }
        let session = session
        guard let loc = await withLanguageTimeout(nil, { await session.declarationOrDefinition(t.url, at: t.position) }) else {
            noteLanguage("No declaration found")
            return false
        }
        reveal(loc)
        return true
    }

    /// Opens a location: the file (a new history entry), the symbol selected
    /// and scrolled to.
    public func reveal(_ loc: Location) {
        let path = loc.url.standardizedFileURL.path
        open(path, line: loc.start.line + 1)
        guard let d = editor, d.path == path else { return }
        let a = offset(of: loc.start, in: d)
        var b = offset(of: loc.end, in: d)
        // A location without a range (sourcekit-lsp's definitions): the name there.
        if b <= a { b = identifierEnd(d.buffer, from: a) }
        d.buffer.setSelection(b > a ? EditorSelection(anchor: a, head: b) : EditorSelection(caret: a))
        refreshQuickHelpInspector()
    }

    // MARK: Quick Help

    /// ⌥-click, or Help ▸ Show Quick Help for Selected Item (⌃⌘?): the hover
    /// of the symbol at `offset` (the caret) in a popover under it, and in
    /// the Quick Help inspector. Nil (no popover) when the server has none.
    @discardableResult
    public func showQuickHelp(at offset: Int? = nil) async -> QuickHelpDocument? {
        guard let t = languageTarget(at: offset) else { return nil }
        let session = session
        guard let hover = await withLanguageTimeout(nil, { await session.hover(t.url, at: t.position) }) else {
            dismissQuickHelp()
            noteLanguage("No Quick Help")
            return nil
        }
        let file = await withLanguageTimeout(nil, { await session.definition(t.url, at: t.position) })?.url.standardizedFileURL.path
        let doc = QuickHelpDocument(hover: hover, file: file)
        let f = languageFeatures
        f.popoverCount += 1
        let start = t.document.buffer.identifierStart(before: offset ?? t.document.buffer.caret)
        f.popover = QuickHelpPopover(id: f.popoverCount, path: t.document.path, offset: start, document: doc, text: QuickHelpFormatter.plain(hover))
        f.inspectorHelp = doc
        return doc
    }

    /// Quick Help's "Open in Developer Documentation": a documentation
    /// search for the symbol's name.
    public func openDocumentation(for name: String) {
        var c = URLComponents(string: "https://developer.apple.com/search/")
        c?.queryItems = [URLQueryItem(name: "q", value: name)]
        if let u = c?.url { languageFeatures.openExternally(u) }
    }

    /// Quick Help's file link: opens the defining file at the symbol.
    public func openQuickHelpFile(_ path: String) {
        dismissQuickHelp()
        open(path)
    }

    /// The popover goes (Escape, a click, typing).
    public func dismissQuickHelp() {
        if languageFeatures.popover != nil { languageFeatures.popover = nil }
    }

    /// The insertion point moved (the editor calls it): the popover goes, and
    /// the Quick Help inspector, when shown, follows the symbol at the caret.
    public func caretMoved() {
        dismissQuickHelp()
        scheduleCaretSymbolUpdate()
        guard isInspectorShown, languageFeatures.inspectorTab == .quickHelp else { return }
        refreshQuickHelpInspector(after: 0.35)
    }

    // MARK: Document symbols

    /// The jump bar follows the insertion point after a moment (a scan per
    /// keystroke would cost typing on a large file).
    func scheduleCaretSymbolUpdate() {
        let f = languageFeatures
        f.symbolTask?.cancel()
        f.symbolTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.updateCaretSymbol()
        }
    }

    /// Scans the open file's declarations when its text changed, and finds
    /// the one at the caret (`DocumentSymbols`, as the macOS jump bar).
    public func updateCaretSymbol() {
        let f = languageFeatures
        guard let d = editor else {
            if f.caretSymbol != nil { f.caretSymbol = nil }
            if !f.documentSymbols.isEmpty { f.documentSymbols = [] }
            f.symbolsRevision = nil
            return
        }
        let b = d.buffer
        if f.symbolsRevision?.path != d.path || f.symbolsRevision?.revision != b.textRevision {
            let lang = SourceTokenizer.Language(fileName: (d.path as NSString).lastPathComponent)
            let symbols = SymbolScanner.symbols(in: b.text, language: lang)
            if symbols != f.documentSymbols { f.documentSymbols = symbols }
            f.symbolsRevision = (d.path, b.textRevision)
        }
        let at = DocumentSymbols.enclosing(f.documentSymbols, line: b.caretLine + 1, text: b.text as NSString, index: LineIndex(b.text))
        if at != f.caretSymbol { f.caretSymbol = at }
    }

    /// The document items menu's choice: the declaration's line.
    public func openSymbol(_ s: SymbolScanner.Symbol) {
        guard let path = document?.path else { return }
        open(path, line: s.line)
        updateCaretSymbol()
    }

    /// Reads the Quick Help of the symbol at the caret into the inspector.
    public func refreshQuickHelpInspector(after delay: Double = 0) {
        let f = languageFeatures
        f.inspectorTask?.cancel()
        f.inspectorTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard !Task.isCancelled, let self, let t = self.languageTarget() else { return }
            let session = self.session
            let hover = await withLanguageTimeout(nil, { await session.hover(t.url, at: t.position) })
            guard !Task.isCancelled else { return }
            guard let hover else { f.inspectorHelp = nil; return }
            let file = await withLanguageTimeout(nil, { await session.definition(t.url, at: t.position) })?.url.standardizedFileURL.path
            guard !Task.isCancelled else { return }
            f.inspectorHelp = QuickHelpDocument(hover: hover, file: file)
        }
    }

    /// Waits for the inspector's read (tests, drivers).
    public func quickHelpInspectorSettled() async { await languageFeatures.inspectorTask?.value }

    // MARK: Rename

    /// Editor ▸ Refactor ▸ Rename…: asks the server whether the symbol at the
    /// caret can be renamed; if so marks its occurrences in the file and
    /// opens the rename sheet. False (nothing shown) when it cannot.
    @discardableResult
    public func beginRename() async -> Bool {
        guard let t = languageTarget(), !t.document.buffer.isReadOnly else { return false }
        dismissQuickHelp()
        let session = session
        guard let r = await withLanguageTimeout(nil, { await session.prepareRename(t.url, at: t.position) }) else {
            noteLanguage("Can't rename this symbol")
            return false
        }
        let d = t.document
        let a = offset(of: r.start, in: d), b = offset(of: r.end, in: d)
        let name = r.placeholder ?? d.buffer.string(a..<max(a, b))
        let highlights = await withLanguageTimeout([], { await session.documentHighlights(t.url, at: t.position) })
        let f = languageFeatures
        f.highlights = highlights.map { h in
            let s = offset(of: h.start, in: d), e = offset(of: h.end, in: d)
            return NSRange(location: s, length: max(0, e - s))
        }
        if f.highlights.isEmpty { f.highlights = [NSRange(location: a, length: max(0, b - a))] }
        f.renamePreview = nil
        f.rename = RenameRequest(path: d.path, position: t.position, range: NSRange(location: a, length: max(0, b - a)), oldName: name)
        return true
    }

    /// The rename sheet's Rename: asks the server for the edits. One file:
    /// applied at once (one undo step) and the sheet closes. Several files:
    /// kept as `renamePreview` for the sheet to show until
    /// `applyRenamePreview()`. Returns the edit (nil: nothing to rename).
    @discardableResult
    public func commitRename(to newName: String) async -> WorkspaceEdit? {
        let f = languageFeatures
        guard let r = f.rename else { return nil }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != r.oldName else {
            cancelRename()
            return nil
        }
        f.isRenaming = true
        defer { f.isRenaming = false }
        if let d = openDocuments[r.path], let language = session.language {
            languageUpdates.removeValue(forKey: r.path)?.cancel()
            language.change(URL(fileURLWithPath: r.path), text: d.buffer.text)
        }
        let session = session
        guard let edit = await withLanguageTimeout(nil, { await session.rename(URL(fileURLWithPath: r.path), at: r.position, to: name) }) else {
            noteLanguage("Rename failed")
            cancelRename()
            return nil
        }
        if edit.files.count > 1 {
            f.renamePreview = RenamePreview(edit: edit, oldName: r.oldName, newName: name) { [weak self] url in self?.currentText(of: url.standardizedFileURL.path) }
        } else {
            applyWorkspaceEdit(edit)
            cancelRename()
        }
        return edit
    }

    /// The preview's Rename: applies the edits and closes the sheet.
    @discardableResult
    public func applyRenamePreview() -> [String] {
        guard let p = languageFeatures.renamePreview else { return [] }
        let changed = applyWorkspaceEdit(p.edit)
        cancelRename()
        return changed
    }

    /// The sheet's Cancel (and its end after a rename).
    public func cancelRename() {
        let f = languageFeatures
        f.rename = nil
        f.renamePreview = nil
        f.highlights = []
        focusEditor()
    }

    /// A file's text as the user sees it: its editor buffer, else the disk.
    public func currentText(of path: String) -> String? {
        openDocuments[path]?.buffer.text ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    // MARK: Applying edits

    /// Applies a workspace edit (`refactoring.md` §Applying edits): a file
    /// open here changes in its buffer as one undo step; another file is
    /// rewritten on disk (its old text kept in `diskBackups`) and the server
    /// is told. Returns the paths changed.
    @discardableResult
    public func applyWorkspaceEdit(_ edit: WorkspaceEdit) -> [String] {
        var changed: [String] = []
        for url in edit.files {
            let edits = edit.changes[url] ?? []
            guard !edits.isEmpty else { continue }
            let path = url.standardizedFileURL.path
            if let d = openDocuments[path] {
                guard !d.buffer.isReadOnly else { continue }
                let ranges = TextEditApplication.ranges(edits, in: d.buffer.text)
                d.buffer.replaceAll(ranges.map { ($0.range, $0.newText) })
                syncEdited(d)
            } else {
                guard let old = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                languageFeatures.diskBackups[path] = old
                do {
                    try TextEditApplication.apply(edits, to: old).write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    continue
                }
                session.language?.fileChangedOnDisk(URL(fileURLWithPath: path))
            }
            changed.append(path)
        }
        return changed
    }

    // MARK: References and callers

    /// Find ▸ Find Selected Symbol in Workspace (⌃⇧⌘F): the references in the
    /// Find navigator ("greet — 3 references", then files and lines).
    /// Returns how many.
    @discardableResult
    public func findSelectedSymbolInWorkspace() async -> Int {
        guard let t = languageTarget() else { return 0 }
        let session = session
        // References and callers read the index, which a server may be updating: longer.
        let refs = await withLanguageTimeout([], timeout: 15, { await session.references(t.url, at: t.position) })
        let b = t.document.buffer
        let caret = b.caret
        let name = b.string(b.identifierStart(before: caret)..<identifierEnd(b, from: caret))
        guard !refs.isEmpty else {
            noteLanguage("No references found")
            return 0
        }
        let results = SymbolResults.fileResults(refs) { [weak self] in self?.currentText(of: $0) }
        let count = results.reduce(0) { $0 + $1.matches.count }
        showFindResults(query: name, title: SymbolResults.referencesTitle(name, count: count), results)
        return count
    }

    /// Find ▸ Find Call Hierarchy (⌃⇧⌘H): the function at the caret, its
    /// callers and their callers (two levels, `CallerTree`), as a tree in
    /// the Find navigator under "Callers of greet". Returns how many callers
    /// the tree holds.
    @discardableResult
    public func findCallHierarchy() async -> Int {
        guard let t = languageTarget() else { return 0 }
        let session = session
        guard let tree = await withLanguageTimeout(nil, timeout: 15, { await session.callerTree(t.url, at: t.position) }) else {
            noteLanguage("Not a callable symbol")
            return 0
        }
        // The name as written ("greet"), not the server's qualified one.
        let b = t.document.buffer
        var name = b.string(b.identifierStart(before: b.caret)..<identifierEnd(b, from: b.caret))
        if name.isEmpty { name = tree.name }
        showFindResults(query: name, title: SymbolResults.callersTitle(name), [])
        callHierarchy.onOpen = { [weak self] path, line in self?.open(path, line: line) }
        callHierarchy.show(tree)
        return tree.callerCount
    }

    private func identifierEnd(_ b: EditorBuffer, from offset: Int) -> Int {
        let u = b.document.units
        var e = offset
        while e < u.count, let s = Unicode.Scalar(u[e]), CharacterSet.alphanumerics.contains(s) || s == "_" { e += 1 }
        return e
    }
}

/// Runs a language request; `fallback` after `timeout` seconds (a server
/// that is busy indexing, or gone, never holds the window).
@MainActor
func withLanguageTimeout<T: Sendable>(_ fallback: T, timeout: Double = 5, _ work: @escaping @MainActor () async -> T) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let once = LanguageResumeOnce(cont)
        Task { @MainActor in once.resume(await work()) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            once.resume(fallback)
        }
    }
}

@MainActor
private final class LanguageResumeOnce<T: Sendable> {
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ v: T) {
        cont?.resume(returning: v)
        cont = nil
    }
}
