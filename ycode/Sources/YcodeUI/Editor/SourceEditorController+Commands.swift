import AppKit

/// The source editor's text commands behind the Editor menu, the change
/// gutter and the Edit menu's symbol items (`specs/ide/reference-ui-5.md`
/// §2.7, §6.3, §6.4). The text work is in `TextCommands`; this applies it
/// to the text view as one undo step each.
extension SourceEditorController {
    // MARK: Applying edits

    /// Applies a change as one undoable edit and selects its selection.
    /// Returns false when there is nothing to change.
    @discardableResult
    public func apply(_ change: TextChange?, actionName: String) -> Bool {
        _ = view
        guard let change, fileURL != nil, textView.isEditable else { return false }
        clearMultipleSelection()
        textView.undoManager?.beginUndoGrouping()
        defer {
            textView.undoManager?.setActionName(actionName)
            textView.undoManager?.endUndoGrouping()
        }
        guard textView.shouldChangeText(in: change.range, replacementString: change.replacement) else { return false }
        textView.replaceCharacters(in: change.range, with: change.replacement)
        textView.didChangeText()
        let len = (textView.string as NSString).length
        let s = change.selection
        textView.setSelectedRange(NSRange(location: min(max(0, s.location), len), length: max(0, min(s.length, len - min(max(0, s.location), len)))))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// Replaces the whole text with `new`, editing only the part that
    /// differs (so the caret and undo stay local).
    @discardableResult
    func replaceText(with new: String, actionName: String) -> Bool {
        let old = textView.string as NSString
        let n = new as NSString
        guard old as String != new else { return false }
        var start = 0
        while start < old.length, start < n.length, old.character(at: start) == n.character(at: start) { start += 1 }
        var oEnd = old.length, nEnd = n.length
        while oEnd > start, nEnd > start, old.character(at: oEnd - 1) == n.character(at: nEnd - 1) { oEnd -= 1; nEnd -= 1 }
        let caret = textView.selectedRange().location
        let delta = nEnd - oEnd
        let newCaret = caret >= oEnd ? caret + delta : min(caret, nEnd)
        return apply(TextChange(range: NSRange(location: start, length: oEnd - start), replacement: n.substring(with: NSRange(location: start, length: nEnd - start)),
                                selection: NSRange(location: newCaret, length: 0)), actionName: actionName)
    }

    var selection: NSRange { textView.selectedRange() }

    // MARK: Structure (§6.4)

    public var canMoveLineUp: Bool { fileURL != nil && TextCommands.canMoveLines(in: textView.string, selection: selection, up: true) }
    public var canMoveLineDown: Bool { fileURL != nil && TextCommands.canMoveLines(in: textView.string, selection: selection, up: false) }

    /// Move Line Up / Down (⌥⌘[ / ⌥⌘]).
    @discardableResult
    public func moveLines(up: Bool) -> Bool {
        apply(TextCommands.moveLines(in: textView.string, selection: selection, up: up), actionName: up ? "Move Line Up" : "Move Line Down")
    }

    /// Shift Left / Right (⌘[ / ⌘]).
    @discardableResult
    public func shiftLines(right: Bool) -> Bool {
        let p = Preferences.shared
        return apply(TextCommands.shift(in: textView.string, selection: selection, right: right, unit: p.indentUnit, indentWidth: p.indentWidth),
                     actionName: right ? "Shift Right" : "Shift Left")
    }

    /// Re-Indent (⌃I).
    @discardableResult
    public func reindentLines() -> Bool {
        apply(TextCommands.reindent(in: textView.string, selection: selection, language: language, unit: Preferences.shared.indentUnit), actionName: "Re-Indent")
    }

    /// Add Documentation (⌥⌘/).
    @discardableResult
    public func addDocumentation() -> Bool {
        guard language == .swift || language == .objc || language == .c else { return false }
        return apply(TextCommands.addDocumentation(in: textView.string, caretLine: currentLine), actionName: "Add Documentation")
    }

    /// Format to Multiple Lines (⌃M).
    @discardableResult
    public func formatToMultipleLines() -> Bool {
        apply(TextCommands.formatToMultipleLines(in: textView.string, caret: selection.location, language: language, unit: Preferences.shared.indentUnit),
              actionName: "Format to Multiple Lines")
    }

    /// Reformat To Width (⌃⌥I), at the "Reformat code at column" setting.
    @discardableResult
    public func reformatToWidth() -> Bool {
        apply(TextCommands.reformatToWidth(in: textView.string, selection: selection, column: Preferences.shared.pageGuideColumn), actionName: "Reformat To Width")
    }

    /// Format Selection / Format File are for Swift files only (§6.4).
    public var canFormatWithSwiftFormat: Bool { fileURL?.pathExtension == "swift" && textView.isEditable }

    /// Format Selection / Format File (⌃⌥⇧I / ⌃⇧I): runs `swift-format` off
    /// the main thread and applies its output if the text has not changed
    /// meanwhile. Returns whether the text changed. `tool` nil (the
    /// default) looks the tool up, also off the main thread; `.some(nil)`
    /// means it is missing.
    @discardableResult
    public func formatWithSwiftFormat(selectionOnly: Bool, tool: URL?? = nil) async -> Result<Bool, SwiftFormatTool.Failure> {
        guard canFormatWithSwiftFormat, let url = fileURL else { return .success(false) }
        let text = textView.string
        var lines: ClosedRange<Int>?
        if selectionOnly {
            let index = textView.lineIndex
            let sel = selection
            let a = index.line(at: sel.location), b = index.line(at: max(sel.location, NSMaxRange(sel) - (sel.length > 0 ? 1 : 0)))
            lines = a...b
        }
        let path = url.path
        let result = await Task.detached { SwiftFormatTool.format(text, fileName: path, lines: lines, tool: tool ?? SwiftFormatTool.locate()) }.value
        switch result {
        case .failure(let f): return .failure(f)
        case .success(let formatted):
            guard textView.string == text else { return .success(false) }
            return .success(replaceText(with: formatted, actionName: selectionOnly ? "Format Selection" : "Format File"))
        }
    }

    // MARK: Code Folding (§6.4)

    /// Fold / Unfold Methods & Functions (⌥⇧⌘← / →).
    public func foldMethodsAndFunctions(_ fold: Bool) {
        let starts = Set(FoldRegions.functionRegions(in: textView.string, language: language).map(\.startLine))
        setFolded(starts, fold)
    }

    /// Fold / Unfold Comment Blocks (⌃⇧⌘← / →).
    public func foldCommentBlocks(_ fold: Bool) { setFolded(Set(commentRegions.map(\.startLine)), fold) }

    func setFolded(_ starts: Set<Int>, _ fold: Bool) {
        if fold { foldedStarts.formUnion(starts) } else { foldedStarts.subtract(starts) }
        applyFolds()
    }

    // MARK: Selection (§6.4)

    /// The selections: several while multiple selections are active.
    public var selectionRanges: [NSRange] { textView.multipleRanges.isEmpty ? [selection] : textView.multipleRanges }

    /// Sets one or more selections (several: typing edits at each).
    public func setSelections(_ ranges: [NSRange]) {
        _ = view
        if ranges.count <= 1 { clearMultipleSelection(); if let r = ranges.first { textView.setSelectedRange(r) }; return }
        textView.setMultipleRanges(ranges)
    }

    func clearMultipleSelection() { textView.multipleRanges = [] }

    /// Types at every selection (tests; the keyboard goes through insertText).
    public func insertAtSelections(_ s: String) { textView.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    /// Split Selection By Lines.
    @discardableResult
    public func splitSelectionByLines() -> Bool {
        let parts = TextCommands.splitByLines(in: textView.string, selection: selection)
        guard parts.count > 1 else { return false }
        setSelections(parts)
        return true
    }

    /// Balance Delimiters.
    @discardableResult
    public func balanceDelimiters() -> Bool {
        guard let r = TextCommands.balance(in: textView.string, selection: selection, language: language) else { return false }
        clearMultipleSelection()
        textView.setSelectedRange(r)
        return true
    }

    /// Select Column Up / Down (⌃⇧↑ / ⌃⇧↓): an insertion point on the line
    /// above the topmost (below the bottommost) one, at the same column.
    @discardableResult
    public func addColumnSelection(up: Bool) -> Bool {
        let current = selectionRanges
        guard let edge = up ? current.first : current.last,
              let o = TextCommands.columnOffset(in: textView.string, from: edge.location, up: up) else { return false }
        let carets = current.map { NSRange(location: $0.location, length: 0) } + [NSRange(location: o, length: 0)]
        textView.setMultipleRanges(carets, primary: NSRange(location: o, length: 0))
        return true
    }

    /// Select All Symbols / Edit All in Scope (⌃⌘E): every occurrence of
    /// the symbol at the caret as selections. `highlights` are the
    /// language server's document highlights when it gave any.
    @discardableResult
    public func selectAllOccurrences(highlights: [NSRange]? = nil) -> Bool {
        let found = highlights.flatMap { $0.isEmpty ? nil : $0 }
            ?? TextCommands.occurrences(in: textView.string, at: selection.location, language: language)
        guard !found.isEmpty else { return false }
        let caret = selection.location
        let primary = found.first { $0.location <= caret && caret <= NSMaxRange($0) }
        if found.count == 1 { clearMultipleSelection(); textView.setSelectedRange(found[0]); return true }
        textView.setMultipleRanges(found, primary: primary)
        return true
    }

    // MARK: Syntax Coloring

    /// The language the file's type gives.
    public var fileLanguage: SourceTokenizer.Language { fileURL.map { .init(fileName: $0.lastPathComponent) } ?? .plain }
    /// The language the text is colored as.
    public var coloringLanguage: SourceTokenizer.Language { language }

    /// Editor ▸ Syntax Coloring ▸ <item>: nil = Default for File Type.
    public func setSyntaxColoring(_ l: SourceTokenizer.Language?) {
        _ = view
        syntaxOverride = l
        language = l ?? fileLanguage
        symbolCache.symbols = nil
        applyPreferences()   // recolors the whole text
        reindexDeferred()
    }

    // MARK: Change gutter (§6.3)

    /// The change regions shown in the gutter.
    public var sourceChanges: [SourceChangeRegion] { gutter.changeRegions }
    public var showsChangeColumn: Bool { gutter.showsChangeColumn }

    /// Re-reads the index and HEAD versions (in the background), then
    /// recomputes the change bars. Open and save call it; the window calls
    /// it after a source-control change.
    public func refreshSourceChanges() {
        changeRefresh?.invalidate()
        changeRefresh = nil
        changeBaselineGeneration += 1
        guard let url = fileURL, let read = changeBaselines else {
            changeBaselineCache = nil
            changeBaselineLoading = nil
            gutter.showsChangeColumn = false
            gutter.changeRegions = []
            return
        }
        // Another file's bars go at once; this file's stay until the read.
        if changeBaselineCache?.url != url {
            changeBaselineCache = nil
            gutter.changeRegions = []
        }
        let generation = changeBaselineGeneration
        changeBaselineLoading = Task { [weak self] in
            let base = await read(url)
            guard let self, generation == self.changeBaselineGeneration else { return }
            self.changeBaselineLoading = nil
            guard self.fileURL == url else { return }
            self.changeBaselineCache = (url, base)
            self.recomputeSourceChanges()
        }
    }

    /// Recomputes the change bars against the baselines already read (no
    /// git call): after an edit.
    func recomputeSourceChanges() {
        changeRefresh?.invalidate()
        changeRefresh = nil
        guard let url = fileURL, let cached = changeBaselineCache, cached.url == url else { return }
        guard let base = cached.base else {
            gutter.showsChangeColumn = false
            gutter.changeRegions = []
            return
        }
        gutter.showsChangeColumn = true
        gutter.changeRegions = SourceChanges.regions(text: textView.string, index: base.index, head: base.head)
    }

    /// Waits for the baseline read (tests).
    public func sourceChangesIdle() async {
        while let t = changeBaselineLoading { await t.value }
    }

    /// After an edit: refresh after a pause (§6.3.4).
    func scheduleSourceChangesRefresh() {
        guard changeBaselines != nil, fileURL != nil else { return }
        changeRefresh?.invalidate()
        // A run-loop timer (common modes), so it also fires while a menu or
        // a drag is tracking.
        let t = Timer(timeInterval: Self.changeRefreshDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recomputeSourceChanges() }
        }
        RunLoop.main.add(t, forMode: .common)
        changeRefresh = t
    }

    /// Navigate ▸ Jump to Next / Previous Change (⌃\ / ⌃|): the start of
    /// the next or previous region, wrapping.
    @discardableResult
    public func jumpToChange(forward: Bool) -> Bool {
        if changeRefresh != nil { recomputeSourceChanges() }
        guard let r = SourceChanges.step(from: currentLine, in: gutter.changeRegions, forward: forward) else { return false }
        reveal(line: min(r.firstLine, textView.lineIndex.lineCount))
        return true
    }

    // MARK: Edit menu items (§6.4)

    /// Edit ▸ Copy File and Line (⌃⌥⌘C): "<file name>:<line>".
    public var fileAndLine: String? { fileURL.map { "\($0.lastPathComponent):\(currentLine)" } }

    /// Edit ▸ Copy Symbol Name / Copy Qualified Symbol Name.
    public func symbolName(qualified: Bool) -> String? {
        TextCommands.symbolName(in: textView.string, at: selection.location, language: language, qualified: qualified)
    }

    /// Edit ▸ Duplicate (⌘D): the selection, or the caret's line, again
    /// right after it; the copy is selected (the caret moves to it).
    @discardableResult
    public func duplicateSelection() -> Bool {
        let ns = textView.string as NSString
        let sel = selection
        if sel.length > 0 {
            let s = ns.substring(with: sel)
            return apply(TextChange(range: NSRange(location: NSMaxRange(sel), length: 0), replacement: s,
                                    selection: NSRange(location: NSMaxRange(sel), length: sel.length)), actionName: "Duplicate")
        }
        let line = ns.lineRange(for: sel)
        var copy = ns.substring(with: line)
        var at = NSMaxRange(line)
        if !copy.hasSuffix("\n") { copy = "\n" + copy; at = NSMaxRange(line) }
        let column = sel.location - line.location
        let newLineStart = copy.hasPrefix("\n") ? at + 1 : at
        return apply(TextChange(range: NSRange(location: at, length: 0), replacement: copy, selection: NSRange(location: newLineStart + column, length: 0)),
                     actionName: "Duplicate")
    }

    // MARK: Minimap landmarks (§6.5)

    func minimapLandmarks() -> [(line: Int, name: String)] {
        guard fileURL != nil, language != .plain else { return [] }
        func flat(_ s: [SymbolScanner.Symbol]) -> [(line: Int, name: String)] {
            s.flatMap { [($0.line, $0.name)] + flat($0.children.filter { $0.kind != .property && $0.kind != .enumCase }) }
        }
        return flat(documentSymbols)
    }
}
