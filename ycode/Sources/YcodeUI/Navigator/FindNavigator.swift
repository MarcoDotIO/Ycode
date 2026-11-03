import AppKit
import YcodeIDECore

/// The Find navigator's state and the controls `NavigatorAreaController`
/// does not own: the Replace row, the count line, the running search and
/// the hooks the window sets. See `specs/ide/navigators.md` §Find
/// navigator, "Ycode implementation".
@MainActor
final class FindNavigatorUI {
    var model = FindNavigatorModel()
    let replaceRow = NSStackView()
    let replaceField = NSTextField()
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    var replaceHeight: NSLayoutConstraint?
    var replaceTop: NSLayoutConstraint?
    var running: Task<Void, Never>?
    let history = ReplaceHistory()
    let fieldDelegate = ReplaceFieldDelegate()
    /// File texts read for regular-expression previews, per search.
    var previewTexts: [String: String] = [:]
    /// The last semantic result shown (tests, the count line).
    var semanticResult: SemanticFind.Result?
    /// The Custom Scopes editor last opened.
    var scopeEditor: FindScopeEditorController?
    /// Set while the results' selection is changed from code.
    var selectingFromCode = false

    // Hooks the window sets.
    var buffers: (() -> [String: String])?
    var openFiles: (() -> [String])?
    var semantic: (@MainActor (FindQuery) async -> SemanticFind.Result)?
    var io: ReplaceIO?
    var performReplace: ((ReplacePlan) -> ReplaceTransaction)?
    var onOpenMatch: ((String, WorkspaceSearch.Match) -> Void)?

    var customScopes: [CustomFindScope] { Preferences.shared.findCustomScopes }
}

/// Reports edits of the replacement field.
final class ReplaceFieldDelegate: NSObject, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    func controlTextDidChange(_ obj: Notification) { onChange?() }
}

/// A Replace-mode checkbox in a result row.
final class FindCheckbox: NSButton {
    var file = 0
    var match: Int?
}

extension NavigatorAreaController {
    // MARK: Hooks and state (the window, tests)

    /// Unsaved editor text by path (searched instead of the file).
    public var findBuffers: (() -> [String: String])? {
        get { findUI.buffers }
        set { findUI.buffers = newValue }
    }
    /// The files open in this window (the Open Files scope).
    public var findOpenFiles: (() -> [String])? {
        get { findUI.openFiles }
        set { findUI.openFiles = newValue }
    }
    /// Runs a semantic kind (the window asks its language server).
    public var findSemantic: (@MainActor (FindQuery) async -> SemanticFind.Result)? {
        get { findUI.semantic }
        set { findUI.semantic = newValue }
    }
    /// How Replace reads and writes files (default: the disk).
    public var findReplaceIO: ReplaceIO? {
        get { findUI.io }
        set { findUI.io = newValue }
    }
    /// Performs a Replace (the window groups it for undo); default: the
    /// plan applied through `findReplaceIO`, recorded in `findReplaceHistory`.
    public var findPerformReplace: ((ReplacePlan) -> ReplaceTransaction)? {
        get { findUI.performReplace }
        set { findUI.performReplace = newValue }
    }
    /// Opens a match and selects it (default: `onOpen` at its line).
    public var onOpenFindMatch: ((String, WorkspaceSearch.Match) -> Void)? {
        get { findUI.onOpenMatch }
        set { findUI.onOpenMatch = newValue }
    }
    public var findModel: FindNavigatorModel { findUI.model }
    public var findReplaceHistory: ReplaceHistory { findUI.history }
    public var findCountText: String { findUI.countLabel.stringValue }
    public var findReplaceField: NSTextField { findUI.replaceField }
    public var findReplaceAllButton: NSButton { findUI.replaceAllButton }
    public var findReplaceButton: NSButton { findUI.replaceButton }
    public var isShowingFindReplaceRow: Bool { !findUI.replaceRow.isHidden }
    public var lastSemanticFindResult: SemanticFind.Result? { findUI.semanticResult }

    // MARK: Controls

    func installFindControls(in root: NSView) {
        let ui = findUI
        ui.replaceField.placeholderString = "With"
        ui.replaceField.controlSize = .small
        ui.replaceField.font = .systemFont(ofSize: 11)
        ui.replaceField.delegate = ui.fieldDelegate
        ui.fieldDelegate.onChange = { [weak self] in self?.replacementChanged() }
        for (b, sel) in [(ui.replaceButton, #selector(replaceClicked)), (ui.replaceAllButton, #selector(replaceAllClicked))] {
            b.controlSize = .small
            b.bezelStyle = .push
            b.font = .systemFont(ofSize: 11)
            b.target = self
            b.action = sel
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        ui.replaceButton.toolTip = "Replace the selected results"
        ui.replaceAllButton.toolTip = "Replace every checked result"
        ui.replaceRow.orientation = .horizontal
        ui.replaceRow.spacing = 4
        for v in [ui.replaceField, ui.replaceButton, ui.replaceAllButton] as [NSView] { ui.replaceRow.addArrangedSubview(v) }
        ui.replaceRow.isHidden = true
        ui.countLabel.font = .systemFont(ofSize: 10)
        ui.countLabel.textColor = .secondaryLabelColor
        ui.countLabel.alignment = .right
        ui.countLabel.lineBreakMode = .byTruncatingHead
        ui.countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ui.countLabel.isHidden = true
        for v in [ui.replaceRow, ui.countLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let height = ui.replaceRow.heightAnchor.constraint(equalToConstant: 0)
        let top = ui.replaceRow.topAnchor.constraint(equalTo: findField.bottomAnchor, constant: 0)
        ui.replaceHeight = height
        ui.replaceTop = top
        NSLayoutConstraint.activate([
            height, top,
            ui.replaceRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            ui.replaceRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            ui.countLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            ui.countLabel.centerYAnchor.constraint(equalTo: findScope.centerYAnchor),
            ui.countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: findScope.trailingAnchor, constant: 4),
        ])
    }

    /// Shows the Replace row in Replace mode and the count line while the
    /// Find navigator is selected.
    func applyFindVisibility(_ shown: Bool) {
        let replace = shown && findUI.model.mode == .replace
        findUI.replaceRow.isHidden = !replace
        findUI.replaceHeight?.constant = replace ? 22 : 0
        findUI.replaceTop?.constant = replace ? 2 : 0
        findUI.countLabel.isHidden = !shown
        updateReplaceButtons()
    }

    func updateReplaceButtons() {
        let plan = findUI.model.plan
        let textual = findUI.model.query.kind.supportsReplace
        findUI.replaceAllButton.isEnabled = (plan?.includedCount ?? 0) > 0
        findUI.replaceButton.isEnabled = plan != nil && !selectedFindRows.isEmpty
        findUI.replaceField.isEnabled = textual
        findUI.replaceField.toolTip = textual ? nil : "Replace works with Text, Multiple Words and Regular Expression"
    }

    /// The query the header describes for `text`. Symbols ▸ Definitions
    /// matches names containing the text; ▸ References the exact name.
    public func findQuery(_ text: String) -> FindQuery {
        let kind = FindQuery.Kind(rawValue: findStyle.indexOfSelectedItem) ?? .text
        let ignoreCase = findCaseToggle.state != .on
        if kind == .symbols {
            let role = FindQuery.SymbolRole(rawValue: findMatch.indexOfSelectedItem) ?? .definitions
            return FindQuery(text, kind: kind, match: role == .references ? .matchingWord : .containing, ignoreCase: ignoreCase, symbolRole: role)
        }
        return FindQuery(text, kind: kind, match: FindQuery.Match(rawValue: findMatch.indexOfSelectedItem) ?? .containing, ignoreCase: ignoreCase)
    }

    /// Mode, kind, match and case as the pop-ups would set them.
    public func setFindOptions(mode: FindNavigatorModel.Mode? = nil, kind: FindQuery.Kind? = nil, match: Int? = nil, ignoreCase: Bool? = nil) {
        _ = view
        if let mode { findMode.selectItem(at: mode.rawValue) }
        if let kind { findStyle.selectItem(at: kind.rawValue) }
        syncFindMatchItems()
        if let match { findMatch.selectItem(at: match) }
        if let ignoreCase { findCaseToggle.state = ignoreCase ? .off : .on }
        findOptionsDidChange()
    }

    /// The Match pop-up lists Definitions and References for Symbols, the
    /// match styles otherwise.
    func syncFindMatchItems() {
        let symbols = findStyle.indexOfSelectedItem == FindQuery.Kind.symbols.rawValue
        let titles = symbols ? FindQuery.SymbolRole.allCases.map(\.title) : Self.findMatches
        guard findMatch.itemTitles != titles else { return }
        findMatch.removeAllItems()
        findMatch.addItems(withTitles: titles)
        findMatch.selectItem(at: 0)
    }

    func findOptionsDidChange() {
        syncFindMatchItems()
        updateFindPlaceholder()
        let mode = FindNavigatorModel.Mode(rawValue: findMode.indexOfSelectedItem) ?? .find
        if mode != findUI.model.mode {
            findUI.model.setMode(mode)
            applyFindVisibility(selectedIndex == 3)
            view.needsLayout = true
            showFindRows(findRows())
        }
        if !lastQuery.isEmpty { runFind(lastQuery) }
    }

    func replacementChanged() {
        findUI.model.setReplacement(findUI.replaceField.stringValue)
        if selectedIndex == 3 { outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outlineView.numberOfRows), columnIndexes: [0]) }
    }

    /// Return in the query field: a streamed search, noted in the history.
    func submitFind() {
        let q = findField.stringValue
        if !q.isEmpty {
            noteRecentSearch(q)
            findUI.model.noteRecent(q)
        }
        beginFind(q)
    }

    // MARK: Searching

    /// The engine request for a textual query in the selected scope, with
    /// the window's unsaved buffers; nil without a workspace.
    func findRequest(_ q: FindQuery) -> FindEngine.Request? {
        guard let root = workspaceRoot else { return nil }
        let resolver = FindScopeResolver(root: root, openFiles: findUI.openFiles?() ?? [], currentResults: lastResultFiles,
                                         customScopes: findUI.customScopes)
        return FindEngine.Request(query: q, files: resolver.candidates(for: findScopeValue), buffers: findUI.buffers?() ?? [:])
    }

    func prepareFind(_ text: String) -> FindQuery {
        _ = view
        findField.stringValue = text
        lastQuery = text
        findUI.running?.cancel()
        findUI.running = nil
        findUI.previewTexts = [:]
        findUI.semanticResult = nil
        let q = findQuery(text)
        findUI.model.query = q
        findUI.model.setReplacement(findUI.replaceField.stringValue)
        findUI.model.begin()
        return q
    }

    /// Searches at once (textual kinds); semantic kinds start in the
    /// background (`beginFind` returns their task).
    func runFind(_ text: String) {
        let q = prepareFind(text)
        if q.kind.isSemantic {
            findUI.running = semanticTask(q)
            return
        }
        guard let req = findRequest(q) else { finishFind(FindEngine.Summary()); return }
        finishFind(FindEngine.search(req))
    }

    /// Searches in the background, showing files as they are found; a new
    /// search cancels this one.
    @discardableResult
    public func beginFind(_ text: String) -> Task<Void, Never> {
        let q = prepareFind(text)
        if q.kind.isSemantic {
            let t = semanticTask(q)
            findUI.running = t
            return t
        }
        guard let req = findRequest(q) else {
            finishFind(FindEngine.Summary())
            return Task {}
        }
        showFindRows([])
        findUI.countLabel.stringValue = text.isEmpty ? "" : "Searching…"
        let stream = FindEngine.stream(req)
        let task = Task { @MainActor [weak self] in
            var shown = Date()
            var summary: FindEngine.Summary?
            for await e in stream {
                guard let self, !Task.isCancelled else { return }
                switch e {
                case .file(let f):
                    self.findUI.model.append(f)
                    if Date().timeIntervalSince(shown) > 0.1 {
                        shown = Date()
                        self.showFindRows(self.findRows())
                        self.findUI.countLabel.stringValue = "Searching… " + self.findUI.model.countText
                    }
                case .finished(let s): summary = s
                }
            }
            guard let self, !Task.isCancelled, let summary else { return }
            self.finishFind(summary)
        }
        findUI.running = task
        return task
    }

    func finishFind(_ s: FindEngine.Summary) {
        findUI.model.finish(s)
        if findScopeValue != .currentResults { lastResultFiles = s.files.map(\.path) }
        showFindRows(findRows())
        findUI.countLabel.stringValue = findUI.model.countText
        updateReplaceButtons()
    }

    func semanticTask(_ q: FindQuery) -> Task<Void, Never> {
        findUI.countLabel.stringValue = q.text.isEmpty ? "" : "Searching…"
        showFindRows([])
        let run = findUI.semantic
        return Task { @MainActor [weak self] in
            let r = await run?(q) ?? SemanticFind.Result(heading: q.text, message: "No language server")
            guard let self, !Task.isCancelled else { return }
            self.showSemanticResult(r, selectNavigator: false)
        }
    }

    /// Shows a semantic result: a heading row with the tree under it.
    public func showSemanticResult(_ r: SemanticFind.Result, selectNavigator: Bool = true) {
        _ = view
        findUI.semanticResult = r
        @MainActor func item(_ n: FindResultNode) -> OutlineItem {
            let glyph: String
            switch n.kind {
            case .file: glyph = "doc.text"
            case .match: glyph = "text.magnifyingglass"
            case .heading: glyph = "magnifyingglass"
            case .symbol: glyph = Self.symbolGlyph(n.symbolKind)
            }
            let o = OutlineItem(title: n.title, symbol: glyph, tint: n.kind == .match ? .secondaryLabelColor : nil,
                                children: n.children.map(item), path: n.path, line: n.line)
            if n.kind == .file { o.detail = n.detail }
            if n.kind == .match { o.maxLines = Preferences.shared.findNavigatorDetail }
            return o
        }
        let rows = [OutlineItem(title: r.heading, symbol: "magnifyingglass", children: r.nodes.map(item))]
        findUI.countLabel.stringValue = r.message ?? ""
        if selectNavigator {
            showSymbolResults(title: r.heading, symbol: "magnifyingglass", children: r.nodes.map(item))
        } else {
            showFindRows(rows)
        }
        updateReplaceButtons()
    }

    /// Letter badges for LSP symbol kinds (as the jump bar's).
    static func symbolGlyph(_ kind: Int?) -> String {
        switch kind {
        case 5: "c.square.fill"
        case 10: "e.square.fill"
        case 11: "p.square.fill"
        case 23: "s.square.fill"
        case 6, 9, 12: "f.square.fill"
        case 7, 8, 13, 14: "v.square.fill"
        case 22: "e.square"
        case 26: "t.square.fill"
        default: "number.square"
        }
    }

    // MARK: Rows

    /// Replaces the rows without opening what the selection lands on.
    func showFindRows(_ rows: [OutlineItem]) {
        findUI.selectingFromCode = true
        setFindRows(rows)
        findUI.selectingFromCode = false
    }

    /// One row per file, "name  (N)", then one per match with its line.
    func findRows() -> [OutlineItem] {
        findUI.model.results.enumerated().map { fi, f in
            let name = (f.path as NSString).lastPathComponent
            let file = OutlineItem(title: "\(name)  (\(f.matches.count))", symbol: "doc.text", children: f.matches.enumerated().map { mi, m in
                let row = OutlineItem(title: m.text, symbol: "text.magnifyingglass", tint: .secondaryLabelColor, path: f.path, line: m.line)
                row.maxLines = Preferences.shared.findNavigatorDetail
                row.findIndex = (fi, mi)
                return row
            })
            file.findIndex = (fi, nil)
            return file
        }
    }

    /// The match highlighted in its row; in Replace mode a checkbox and
    /// the replacement shown after the struck-out match.
    func decorateFindRow(_ item: OutlineItem, cell: NSTableCellView, image: NSImageView, label: NSTextField) {
        guard let idx = item.findIndex, findUI.model.results.indices.contains(idx.file) else { return }
        let plan = findUI.model.plan
        if let plan {
            let box = FindCheckbox(checkboxWithTitle: "", target: self, action: #selector(findCheckboxToggled(_:)))
            box.file = idx.file
            box.match = idx.match
            box.allowsMixedState = idx.match == nil
            let included = plan.files[idx.file].included
            if let m = idx.match {
                box.state = included[m] ? .on : .off
            } else {
                box.state = included.allSatisfy { $0 } ? .on : (included.contains(true) ? .mixed : .off)
            }
            box.controlSize = .small
            box.translatesAutoresizingMaskIntoConstraints = false
            box.setAccessibilityLabel(idx.match == nil ? "Include file" : "Include match")
            cell.addSubview(box)
            image.isHidden = true
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                box.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            ])
        }
        guard let mi = idx.match else { return }
        let f = findUI.model.results[idx.file], m = f.matches[mi]
        label.attributedStringValue = Self.matchTitle(m, replacement: plan.map { replacementPreview($0, file: idx.file, match: mi) },
                                                      included: plan?.files[idx.file].included[mi] ?? true, size: Self.rowFontSize)
    }

    func replacementPreview(_ plan: ReplacePlan, file: Int, match: Int) -> String {
        guard plan.query.kind == .regularExpression else { return plan.replacement }
        let path = plan.files[file].path
        if findUI.previewTexts[path] == nil {
            findUI.previewTexts[path] = (findUI.io ?? .disk).read(path) ?? ""
        }
        return plan.replacementText(for: plan.files[file].matches[match], in: findUI.previewTexts[path] ?? "")
    }

    /// The row text with the match emphasized; with a replacement, the
    /// match struck out and the replacement after it.
    static func matchTitle(_ m: WorkspaceSearch.Match, replacement: String?, included: Bool, size: CGFloat) -> NSAttributedString {
        let text = m.text as NSString
        let h = NSIntersectionRange(m.highlight, NSRange(location: 0, length: text.length))
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString(string: text.substring(to: h.location), attributes: base)
        var hit = base
        hit[.font] = NSFont.boldSystemFont(ofSize: size)
        hit[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35)
        if let r = replacement, included {
            hit[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            hit[.foregroundColor] = NSColor.secondaryLabelColor
            hit[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.18)
            out.append(NSAttributedString(string: text.substring(with: h), attributes: hit))
            var add = base
            add[.font] = NSFont.boldSystemFont(ofSize: size)
            add[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.25)
            out.append(NSAttributedString(string: r, attributes: add))
        } else {
            out.append(NSAttributedString(string: text.substring(with: h), attributes: hit))
        }
        out.append(NSAttributedString(string: text.substring(from: NSMaxRange(h)), attributes: base))
        if replacement != nil && !included { out.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: out.length)) }
        return out
    }

    @objc func findCheckboxToggled(_ sender: FindCheckbox) {
        setFindInclusion(sender.state != .off, file: sender.file, match: sender.match)
    }

    /// Includes or leaves out a match (or a file's matches) in Replace.
    public func setFindInclusion(_ on: Bool, file: Int, match: Int?) {
        findUI.model.plan?.setIncluded(on, file: file, match: match)
        if isViewLoaded, selectedIndex == 3 { outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outlineView.numberOfRows), columnIndexes: [0]) }
        updateReplaceButtons()
    }

    // MARK: Opening and stepping

    /// The rows selected in the outline that are results.
    var selectedFindRows: [OutlineItem] {
        guard isViewLoaded, selectedIndex == 3 else { return [] }
        return outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? OutlineItem }.filter { $0.findIndex != nil }
    }

    func openFindRow(_ item: OutlineItem) {
        guard let idx = item.findIndex, let mi = idx.match, findUI.model.results.indices.contains(idx.file) else { return }
        findUI.model.select(file: idx.file, match: mi)
        let f = findUI.model.results[idx.file]
        openFindMatch(f.path, f.matches[mi])
    }

    func openFindMatch(_ path: String, _ m: WorkspaceSearch.Match) {
        if let open = findUI.onOpenMatch { open(path, m) } else { onOpen?(path, m.line) }
    }

    /// Moving the selection with the keyboard opens the selected match (a
    /// click opens it through `rowClicked`).
    func findSelectionChanged() {
        defer { updateReplaceButtons() }
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown]
        guard !findUI.selectingFromCode, !mouse.contains(NSApp.currentEvent?.type ?? .applicationDefined),
              outlineView.selectedRowIndexes.count == 1, let item = selectedFindRows.first, item.findIndex?.match != nil else { return }
        openFindRow(item)
    }

    /// The search in progress, if any (tests await it).
    public var runningFind: Task<Void, Never>? { findUI.running }

    /// Find ▸ Find Next / Previous in Workspace: the next match across
    /// files (wrapping), selected in the results and opened.
    @discardableResult
    public func stepFindResult(forward: Bool) -> (path: String, match: WorkspaceSearch.Match)? {
        guard let hit = findUI.model.step(forward: forward), let c = findUI.model.cursor else { NSSound.beep(); return nil }
        if isViewLoaded, selectedIndex == 3,
           let row = rows(3).flatMap(\.children).first(where: { $0.findIndex?.file == c.file && $0.findIndex?.match == c.match }) {
            let r = outlineView.row(forItem: row)
            if r >= 0 {
                findUI.selectingFromCode = true
                outlineView.selectRowIndexes([r], byExtendingSelection: false)
                findUI.selectingFromCode = false
                outlineView.scrollRowToVisible(r)
            }
        }
        openFindMatch(hit.path, hit.match)
        return hit
    }

    // MARK: Replace

    @objc func replaceAllClicked() { replaceAllFindMatches() }
    @objc func replaceClicked() { replaceSelectedFindMatches() }

    /// Replace All: every checked match. Returns the transaction.
    @discardableResult
    public func replaceAllFindMatches() -> ReplaceTransaction? {
        guard var plan = findUI.model.plan, plan.includedCount > 0 else { NSSound.beep(); return nil }
        plan.replacement = findUI.replaceField.stringValue
        return performFindReplace(plan)
    }

    /// Replace: the checked matches of the selected rows (a file row
    /// stands for its matches).
    @discardableResult
    public func replaceSelectedFindMatches() -> ReplaceTransaction? {
        guard var plan = findUI.model.plan else { NSSound.beep(); return nil }
        let picked = selectedFindRows.compactMap(\.findIndex)
        guard !picked.isEmpty else { NSSound.beep(); return nil }
        for f in plan.files.indices {
            for m in plan.files[f].matches.indices {
                let chosen = picked.contains { $0.file == f && ($0.match == nil || $0.match == m) }
                if !chosen { plan.setIncluded(false, file: f, match: m) }
            }
        }
        guard plan.includedCount > 0 else { NSSound.beep(); return nil }
        plan.replacement = findUI.replaceField.stringValue
        return performFindReplace(plan)
    }

    func performFindReplace(_ plan: ReplacePlan) -> ReplaceTransaction {
        let t: ReplaceTransaction
        if let perform = findUI.performReplace {
            t = perform(plan)
        } else {
            t = plan.apply(findUI.io ?? .disk)
            findUI.history.record(t)
        }
        rerunAfterReplace()
        let files = t.changes.count
        findUI.countLabel.stringValue = "Replaced \(t.replacedCount) occurrence\(t.replacedCount == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
            + (t.stale.isEmpty ? "" : "; \(t.stale.count) changed since the search")
        return t
    }

    /// Undo of the last Replace without a window (the window uses its undo
    /// manager): every file restored at once.
    @discardableResult
    public func undoFindReplace() -> ReplaceHistory.Outcome {
        let o = findUI.history.undo(findUI.io ?? .disk)
        rerunAfterReplace()
        return o
    }

    @discardableResult
    public func redoFindReplace() -> ReplaceHistory.Outcome {
        let o = findUI.history.redo(findUI.io ?? .disk)
        rerunAfterReplace()
        return o
    }

    /// The results follow the files after a replace or its undo.
    public func rerunAfterReplace() {
        guard !lastQuery.isEmpty, findUI.model.query.kind.isTextual else { return }
        runFind(lastQuery)
    }

    // MARK: Custom scopes

    /// Custom Scopes…: the editor sheet (FindScopeEditor.swift).
    func editCustomScopes() {
        rebuildScopeMenu()
        let editor = FindScopeEditorController(scopes: findUI.customScopes)
        editor.onSave = { [weak self] scopes in
            Preferences.shared.findCustomScopes = scopes
            guard let self else { return }
            if case .custom(let n) = self.findScopeValue, !scopes.contains(where: { $0.name == n }) { self.setFindScope(.workspace) } else { self.rebuildScopeMenu() }
        }
        if view.window?.isVisible == true { presentAsSheet(editor) }
        findUI.scopeEditor = editor
    }

    /// The Custom Scopes editor last opened (tests drive it without a sheet).
    public var lastScopeEditor: FindScopeEditorController? { findUI.scopeEditor }
}
