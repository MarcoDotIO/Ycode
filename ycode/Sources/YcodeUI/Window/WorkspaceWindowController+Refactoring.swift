import AppKit
import YcodeBuild
import YcodeLanguage

/// Rename, references, call hierarchy, code actions and fix-its through
/// the language server. See `specs/ide/refactoring.md`.
extension WorkspaceWindowController {
    /// Every editor of every tab.
    var allEditors: [SourceEditorController] { editorArea.tabs.flatMap(\.editors) }

    /// The focused editor's file and the LSP position of its caret.
    var caretLocation: (url: URL, position: Position)? {
        guard let url = editor.fileURL else { return nil }
        let tv = editor.textView
        return (url, tv.lineIndex.position(at: tv.selectedRange().location))
    }

    // MARK: Applying edits

    /// Applies a workspace edit. Files open in an editor change there, as
    /// one undoable step per file; other files are rewritten on disk (their
    /// previous text is kept in `refactoringBackups`). Returns the files changed.
    @discardableResult
    public func applyWorkspaceEdit(_ edit: WorkspaceEdit) -> [URL] {
        var changed: [URL] = []
        for url in edit.files {
            let edits = edit.changes[url] ?? []
            guard !edits.isEmpty else { continue }
            let path = url.standardizedFileURL.path
            if let e = allEditors.first(where: { $0.fileURL?.standardizedFileURL.path == path }) {
                e.applyTextEdits(edits)
            } else {
                guard let old = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let new = Self.apply(edits, to: old)
                refactoringBackups[path] = old
                try? new.write(to: url, atomically: true, encoding: .utf8)
                session.language?.fileChangedOnDisk(url)
            }
            changed.append(url)
        }
        return changed
    }

    /// Applies text edits to a string (last edit first).
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let index = LineIndex(text)
        let ns = NSMutableString(string: text)
        for e in edits.sorted(by: { ($0.start.line, $0.start.character) > ($1.start.line, $1.start.character) }) {
            let a = index.offset(of: e.start), b = index.offset(of: e.end)
            ns.replaceCharacters(in: NSRange(location: a, length: max(0, b - a)), with: e.newText)
        }
        return ns as String
    }

    /// Restores files changed on disk by the last refactorings.
    public func revertDiskRefactorings() {
        for (path, old) in refactoringBackups {
            try? old.write(toFile: path, atomically: true, encoding: .utf8)
            // The server only learns of disk changes through watched files.
            session.language?.fileChangedOnDisk(URL(fileURLWithPath: path))
        }
        refactoringBackups = [:]
    }

    // MARK: Rename

    /// Refactor ▸ Rename…: asks the server whether the symbol at the caret
    /// can be renamed and highlights its occurrences in the file. Returns
    /// the current name.
    @discardableResult
    public func beginRename() async -> String? {
        guard let (url, p) = caretLocation, let language = session.language else { NSSound.beep(); return nil }
        try? editor.save()
        guard let r = try? await language.client.prepareRename(url, at: p) else { NSSound.beep(); return nil }
        let index = editor.textView.lineIndex
        let a = index.offset(of: r.start), b = index.offset(of: r.end)
        let name = r.placeholder ?? (editor.text as NSString).substring(with: NSRange(location: a, length: b - a))
        renameState = (url, p, name)
        editor.highlightOccurrences(of: name)
        if window?.isVisible == true { editor.showRenameField(name: name, at: NSRange(location: a, length: b - a)) { [weak self] newName in
            Task { await self?.rename(to: newName) }
        } }
        return name
    }

    /// Renames to `newName`. One file: applied at once. Several files: kept
    /// as `renamePreview` (and shown in a sheet) until `applyRenamePreview()`.
    @discardableResult
    public func rename(to newName: String) async -> WorkspaceEdit? {
        guard let (url, p, _) = renameState, let language = session.language else { return nil }
        editor.highlightOccurrences(of: nil)
        renameState = nil
        guard let edit = try? await language.client.rename(url, at: p, to: newName), !edit.isEmpty else { NSSound.beep(); return nil }
        if edit.files.count > 1 {
            renamePreview = edit
            if window?.isVisible == true { presentRenamePreview(edit, newName: newName) }
        } else {
            applyWorkspaceEdit(edit)
        }
        return edit
    }

    /// Applies the multi-file rename shown in the preview.
    @discardableResult
    public func applyRenamePreview() -> [URL] {
        guard let edit = renamePreview else { return [] }
        renamePreview = nil
        return applyWorkspaceEdit(edit)
    }

    public func cancelRename() {
        renameState = nil
        renamePreview = nil
        editor.highlightOccurrences(of: nil)
    }

    private func presentRenamePreview(_ edit: WorkspaceEdit, newName: String) {
        let sheet = RenamePreviewController(edit: edit, newName: newName)
        sheet.onApply = { [weak self] in self?.applyRenamePreview() }
        sheet.onCancel = { [weak self] in self?.renamePreview = nil }
        contentViewController?.presentAsSheet(sheet)
    }

    @objc public func renameSymbol(_ sender: Any?) { Task { await beginRename() } }

    // MARK: References, call hierarchy, original source

    /// Find ▸ Find Selected Symbol in Workspace: references in the Find
    /// navigator, grouped by file.
    @discardableResult
    public func findSelectedSymbolInWorkspace() async -> [Location] {
        guard let (url, p) = caretLocation, let language = session.language else { return [] }
        let refs = (try? await language.client.references(url, at: p)) ?? []
        let name = symbolName(at: editor.textView.selectedRange().location)
        let byFile = Dictionary(grouping: refs, by: { $0.url.standardizedFileURL.path })
        let children = byFile.keys.sorted().map { path in
            let lines = (try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n") ?? []
            return OutlineItem(title: "\(URL(fileURLWithPath: path).lastPathComponent)  (\(byFile[path]!.count))", symbol: "doc.text",
                               children: byFile[path]!.sorted { $0.start.line < $1.start.line }.map { l in
                                   let text = l.start.line < lines.count ? lines[l.start.line].trimmingCharacters(in: .whitespaces) : ""
                                   return OutlineItem(title: "\(l.start.line + 1): \(text)", symbol: "text.magnifyingglass", tint: .secondaryLabelColor,
                                                      path: path, line: l.start.line + 1)
                               })
        }
        navigator.showSymbolResults(title: "\(name) — \(refs.count) reference\(refs.count == 1 ? "" : "s")", symbol: "magnifyingglass", children: children)
        return refs
    }

    /// Find ▸ Find Call Hierarchy: callers of the symbol at the caret, two
    /// levels deep, in the Find navigator.
    @discardableResult
    public func findCallHierarchy() async -> [String] {
        guard let (url, p) = caretLocation, let language = session.language,
              let item = (try? await language.client.prepareCallHierarchy(url, at: p))?.first else { NSSound.beep(); return [] }
        func node(_ i: CallHierarchyItem, depth: Int) async -> OutlineItem {
            var kids: [OutlineItem] = []
            if depth < 2 {
                for (caller, _) in (try? await language.client.incomingCalls(i)) ?? [] { kids.append(await node(caller, depth: depth + 1)) }
            }
            return OutlineItem(title: i.name, symbol: "f.cursive", children: kids, path: i.url.path, line: i.selection.line + 1)
        }
        let root = await node(item, depth: 0)
        navigator.showSymbolResults(title: "Callers of \(item.name)", symbol: "arrow.down.right.and.arrow.up.left", children: [root])
        var names: [String] = []
        func walk(_ o: OutlineItem, _ d: Int) { names.append(String(repeating: "  ", count: d) + o.title); o.children.forEach { walk($0, d + 1) } }
        walk(root, 0)
        return names
    }

    /// Navigate ▸ Jump to Original Source: the declaration (falls back to
    /// the definition).
    @objc public func jumpToOriginalSource(_ sender: Any?) {
        guard let (url, p) = caretLocation, let language = session.language else { return }
        Task {
            var loc = (try? await language.client.declaration(url, at: p))?.first
            if loc == nil { loc = (try? await language.client.definition(url, at: p))?.first }
            if let loc { open(path: loc.url.path, line: loc.start.line + 1) }
        }
    }

    @objc public func findSelectedSymbol(_ sender: Any?) { Task { await findSelectedSymbolInWorkspace() } }
    @objc public func showCallHierarchy(_ sender: Any?) { Task { await findCallHierarchy() } }

    /// The identifier around an offset in the focused editor.
    func symbolName(at offset: Int) -> String {
        let ns = editor.text as NSString
        var a = min(offset, ns.length), b = a
        func isIdent(_ c: unichar) -> Bool { Character(Unicode.Scalar(c) ?? " ").isLetter || Character(Unicode.Scalar(c) ?? " ").isNumber || c == 95 }
        while a > 0, isIdent(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length, isIdent(ns.character(at: b)) { b += 1 }
        return ns.substring(with: NSRange(location: a, length: b - a))
    }

    // MARK: Code actions and fix-its

    /// Code actions at the caret (or selection), with the diagnostics on
    /// its line. Also cached for the Refactor menu.
    @discardableResult
    public func codeActionsAtCaret() async -> [CodeAction] {
        guard let url = editor.fileURL, let language = session.language else { return [] }
        let tv = editor.textView
        let sel = tv.selectedRange()
        let start = tv.lineIndex.position(at: sel.location), end = tv.lineIndex.position(at: NSMaxRange(sel))
        let diags = (language.liveDiagnostics[url.standardizedFileURL.path] ?? []).filter { $0.start.line <= end.line && $0.end.line >= start.line }
        let actions = (try? await language.client.codeActions(url, start: start, end: end, diagnostics: diags.map(\.raw))) ?? []
        cachedCodeActions = actions
        return actions
    }

    /// Performs a code action: its edit, then its command (the server's
    /// edits arrive as `workspace/applyEdit`).
    public func perform(_ action: CodeAction) async {
        try? editor.save()
        if let e = action.edit { applyWorkspaceEdit(e) }
        if let c = action.command, let language = session.language { try? await language.client.executeCommand(c) }
    }

    /// Editor ▸ Show Code Actions (⇧⌘A): a menu of the actions at the caret.
    @objc public func showCodeActions(_ sender: Any?) {
        Task {
            let actions = await codeActionsAtCaret()
            guard window?.isVisible == true else { return }
            let menu = NSMenu(title: "Code Actions")
            if actions.isEmpty { menu.addItem(withTitle: "No Actions Available", action: nil, keyEquivalent: "") }
            for (i, a) in actions.enumerated() {
                let item = NSMenuItem(title: a.title, action: #selector(performCachedCodeAction(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                menu.addItem(item)
            }
            let tv = editor.textView
            let rect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            let p = window.map { $0.convertPoint(fromScreen: rect.origin) } ?? .zero
            menu.popUp(positioning: nil, at: tv.convert(p, from: nil), in: tv)
        }
    }

    @objc public func performCachedCodeAction(_ sender: Any?) {
        let item = sender as? NSMenuItem
        let i = (item?.representedObject as? Int) ?? item?.tag ?? -1
        guard cachedCodeActions.indices.contains(i) else { return }
        let a = cachedCodeActions[i]
        Task { await perform(a) }
    }

    /// Applies the fix-its of the issues on a line of the focused editor.
    @discardableResult
    public func applyFixIt(line: Int) -> Bool {
        guard let path = editor.fileURL?.standardizedFileURL.path else { return false }
        let fixes = session.displayedIssues.filter { $0.location?.line == line && $0.location.map { URL(fileURLWithPath: $0.file).standardizedFileURL.path } == path }
            .flatMap(\.fixIts)
        guard !fixes.isEmpty else { return false }
        editor.applyTextEdits(fixes.map(Self.textEdit))
        return true
    }

    /// Editor ▸ Fix All Issues: every fix-it in the focused file.
    @discardableResult
    @objc public func fixAllIssues(_ sender: Any?) -> Int {
        guard let path = editor.fileURL?.standardizedFileURL.path else { return 0 }
        let fixes = session.displayedIssues.filter { $0.location.map { URL(fileURLWithPath: $0.file).standardizedFileURL.path } == path }
            .flatMap(\.fixIts)
        // Identical fix-its from several diagnostics apply once.
        var seen = Set<Diagnostic.FixIt>()
        let unique = fixes.filter { seen.insert($0).inserted }
        if !unique.isEmpty { editor.applyTextEdits(unique.map(Self.textEdit)) }
        return unique.count
    }

    static func textEdit(_ f: Diagnostic.FixIt) -> TextEdit {
        TextEdit(start: Position(line: f.start.line - 1, character: f.start.column - 1),
                 end: Position(line: f.end.line - 1, character: f.end.column - 1), newText: f.replacement)
    }
}

/// The rename preview: affected files and edit counts.
@MainActor
public final class RenamePreviewController: NSViewController {
    let edit: WorkspaceEdit
    let newName: String
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?

    init(edit: WorkspaceEdit, newName: String) {
        self.edit = edit
        self.newName = newName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// One row per file: name and number of edits.
    public var rows: [String] { edit.files.map { "\($0.lastPathComponent) (\(edit.changes[$0]?.count ?? 0))" } }

    public override func loadView() {
        let title = NSTextField(labelWithString: "Rename to “\(newName)” changes \(edit.files.count) files")
        title.font = .boldSystemFont(ofSize: 13)
        let list = NSStackView(views: rows.map { NSTextField(labelWithString: $0) })
        list.orientation = .vertical
        list.alignment = .leading
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Rename", target: self, action: #selector(applyClicked))
        apply.keyEquivalent = "\r"
        let stack = NSStackView(views: [title, list, NSStackView(views: [cancel, apply])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        view = stack
    }

    @objc private func applyClicked() { onApply?(); dismiss(nil) }
    @objc private func cancelClicked() { onCancel?(); dismiss(nil) }
}
