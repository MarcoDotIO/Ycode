import Foundation

/// The merge sheet's view of the conflict state (`specs/ide/merge-sheet.md`
/// §3–§9): every conflicted file keeps its choices while another is shown,
/// the aligned rows of the two panes, the gutter's tokens, the change
/// stepper, the file list, and whether Merge applies. The AppKit sheet and
/// the Linux IDE's sheet draw this; git is read and written by them.
extension ConflictEditorState {
    // MARK: Files

    /// Shows `file` in the panes, keeping the choices made in the file
    /// shown before (and taking up the ones made earlier in `file`).
    /// Showing the shown file again keeps it as it is.
    public mutating func show(file: String?, document: MergeDocument?) {
        if let f = currentFile, f == file, self.document != nil { return }
        if let f = currentFile, f != file, let d = self.document { otherDocuments[f] = d }
        currentFile = file
        guard let file else { load(nil); return }
        load(otherDocuments.removeValue(forKey: file) ?? document)
    }

    /// A file read ahead (Merge needs every file's choices); a document
    /// already there keeps its choices.
    public mutating func prefetch(file: String, document: MergeDocument?) {
        guard file != currentFile, otherDocuments[file] == nil, let document else { return }
        otherDocuments[file] = document
    }

    /// The document of `file` as the sheet has it (choices included).
    public func sheetDocument(_ file: String) -> MergeDocument? { file == currentFile ? document : otherDocuments[file] }

    /// Every conflict of `file` has a choice.
    public func isDecided(file: String) -> Bool { sheetDocument(file)?.isResolved ?? false }

    /// Merge (§9): enabled once every conflict of every file has a choice;
    /// with no conflicted file left, it continues the operation.
    public var canMerge: Bool {
        guard source == .repository else { return false }
        if files.isEmpty { return integration.isInProgress }
        return files.allSatisfy(isDecided(file:))
    }

    /// The primary button: "Merge"; for a stopped rebase, cherry-pick or
    /// revert "Continue <operation>", for a stash apply "Resolve" (Ycode's
    /// choice).
    public var primaryTitle: String {
        switch integration {
        case .merging: MergeSheetText.merge
        case .none: "Resolve"
        default: continueTitle
        }
    }

    /// Each conflicted file's merged text, for Merge.
    public var resolutions: [(file: String, text: String)] {
        files.compactMap { f in sheetDocument(f).flatMap { $0.isResolved ? (f, $0.result) : nil } }
    }

    // MARK: Changes

    /// The Choose menu (§7): the choice replaces the left pane's lines of
    /// the selected change, which stays selected.
    public mutating func chooseKeepingSelection(_ choice: MergeDocument.Choice) {
        guard var doc = document, let h = currentHunk else { return }
        doc.choose(choice, hunk: h)
        replaceDocument(doc)
    }

    /// A token's Choose menu: selects that change, then chooses.
    public mutating func choose(_ choice: MergeDocument.Choice, forHunk h: Int) {
        selectHunk(h)
        chooseKeepingSelection(choice)
    }

    /// The aligned rows of the two panes.
    public var sheetRows: [MergeSheetRow] { document.map(MergeSheetLayout.rows) ?? [] }

    /// The left pane's lines (highlighting).
    public var leftLines: [String] { document.map(MergeSheetLayout.leftText) ?? [] }
    /// The right pane's lines.
    public var rightLines: [String] { document.map { $0.chunks.flatMap(\.theirs) } ?? [] }

    /// "‹ n/m ›": the selected change and the count of changes (§8).
    public var stepperText: String {
        guard let doc = document, !doc.hunks.isEmpty else { return "0/0" }
        return "\((currentHunk ?? 0) + 1)/\(doc.hunks.count)"
    }

    /// A change's token (§5).
    public struct Token: Equatable, Sendable {
        public var glyph: String
        /// A choice is in effect: the chevron sits in a circle.
        public var isDecided: Bool
        public var isSelected: Bool
        public var isConflict: Bool
    }

    public func token(forHunk h: Int) -> Token? {
        guard let doc = document, doc.hunks.indices.contains(h) else { return nil }
        let kind = doc.chunks[doc.hunks[h]].kind
        let choice = doc.choices[h]
        return Token(glyph: MergeSheetToken.glyph(choice: choice, kind: kind), isDecided: choice != .unresolved,
                     isSelected: h == currentHunk, isConflict: kind == .conflict)
    }

    /// The overview ruler's marks (§4.4): each change's share of the
    /// right pane's height (its first row's place among all rows).
    public func rulerMarks(rows: [MergeSheetRow]) -> [(position: Double, isConflict: Bool)] {
        guard !rows.isEmpty else { return [] }
        return rows.enumerated().compactMap { i, r in r.isFirstOfHunk ? (Double(i) / Double(rows.count), r.kind == .conflict) : nil }
    }

    // MARK: File list (§3)

    public struct FileRow: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case folder, file }
        public var kind: Kind
        public var title: String
        public var depth: Int
        /// The file's path (files only).
        public var path: String?
        public var isConflicted: Bool
    }

    /// Hierarchical: one folder row per directory (its name), its files
    /// one level in; Flat: the files only. `filter` keeps the files whose
    /// name contains it (any case).
    public func fileRows(root: String, flat: Bool, filter: String = "") -> [FileRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = files.filter { needle.isEmpty || URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains(needle) }
        func row(_ f: String, _ depth: Int) -> FileRow {
            FileRow(kind: .file, title: URL(fileURLWithPath: f).lastPathComponent, depth: depth, path: f, isConflicted: true)
        }
        if flat { return shown.map { row($0, 0) } }
        var out: [FileRow] = []
        var lastFolder: String?
        for f in shown.sorted() {
            let dir = (f as NSString).deletingLastPathComponent
            if dir != lastFolder {
                let name = dir == root ? URL(fileURLWithPath: root).lastPathComponent : (dir as NSString).lastPathComponent
                out.append(FileRow(kind: .folder, title: name, depth: 0, path: nil, isConflicted: false))
                lastFolder = dir
            }
            out.append(row(f, 1))
        }
        return out
    }

    /// The jump bar's path (§4.1, §13.7): the workspace's project (else the
    /// repository's folder), the shown file's folders below the project's
    /// folder (else the repository's), and the file's name without its
    /// extension — as the main window's jump bar starts at the project.
    public func jumpPath(root: String, project: MergeSheetProject? = nil) -> [String] {
        guard let f = currentFile else { return [] }
        var base = root, first = URL(fileURLWithPath: root).lastPathComponent
        if let project {
            first = project.name
            let folder = project.folder.hasSuffix("/") ? String(project.folder.dropLast()) : project.folder
            if f.hasPrefix(folder + "/") { base = folder }
        }
        var parts = [first]
        let rel = f.hasPrefix(base + "/") ? String(f.dropFirst(base.count + 1)) : URL(fileURLWithPath: f).lastPathComponent
        let comps = rel.split(separator: "/").map(String.init)
        parts += comps.dropLast()
        if let last = comps.last { parts.append((last as NSString).deletingPathExtension) }
        return parts
    }
}

extension ConflictEditorState {
    /// Replaces the document, keeping the selection (the sheet's choices).
    mutating func replaceDocument(_ doc: MergeDocument) {
        let h = currentHunk
        load(doc)
        if let h { selectHunk(h) }
    }
}
