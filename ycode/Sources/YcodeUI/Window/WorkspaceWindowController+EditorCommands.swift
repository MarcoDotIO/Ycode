import AppKit
import YcodeBuild
import YcodeLanguage

/// The Editor menu of each editor kind (`specs/ide/reference-ui-5.md`
/// §2.7, §2.8), the change gutter's navigation (§6.3) and the editing
/// commands behind them (§6.4). The source commands act on the focused
/// editor; the text work is in `SourceEditorController+Commands.swift`.
extension WorkspaceWindowController {
    /// Which Editor menu the focused editor gets.
    public var focusedEditorKind: EditorKind {
        guard let aux = editor.auxiliary else { return .source }
        if let p = plistEditor, p.isViewLoaded, aux === p.view { return .propertyList }
        if let ib = interfaceEditor, ib.isViewLoaded, aux === ib.view { return .interfaceBuilder }
        if let a = assetEditor, a.isViewLoaded, aux === a.view { return .assetCatalog }
        return .other
    }

    /// A source file is shown in the focused editor.
    var hasSourceFile: Bool { editor.fileURL != nil && editor.auxiliary == nil }
    var hasEditableSource: Bool { hasSourceFile && editor.textView.isEditable }

    /// Wires the change gutter of an editor (`wire(_:)` calls this).
    func wireChangeGutter(_ e: SourceEditorController) {
        e.changeBaselines = { [weak self] url in
            guard let self, Preferences.shared.sourceControlEnabled, let repo = self.repository, repo.relative(url.path) != nil else { return nil }
            // git show, twice: off the main thread.
            return await Task.detached { () -> (index: String?, head: String?)? in
                let index = repo.contents(of: url.path, at: nil), head = repo.headContents(of: url.path)
                return index == nil && head == nil ? nil : (index, head)
            }.value
        }
        e.gutter.onChangeClick = { [weak self, weak e] line in
            guard let self, let e else { return }
            self.showChangeInCodeReview(line: line, in: e)
        }
    }

    /// A change bar's click: Code Review, inline, on that region (§6.3.6).
    func showChangeInCodeReview(line: Int, in e: SourceEditorController) {
        if let i = editorArea.tab.editors.firstIndex(where: { $0 === e }) { editorArea.tab.focused = i }
        if editor.comparisonStyle != .inline || !editor.isShowingInlineComparison {
            if editor.isShowingComparison || editor.isShowingInlineComparison { endCodeReview() }
            editor.comparisonStyle = .inline
            guard startCodeReview() else { return }
        }
        editor.selectReviewChange(containing: line)
    }

    // MARK: Layout ▸ (§2.7 item 4)

    /// Editor ▸ Layout ▸ Automatic / Editor on Left / Editor on Top.
    @objc public func setCanvasLayout(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? 0
        editorArea.canvasLayout = tag == 1 ? .beside : (tag == 2 ? .below : nil)
    }

    // MARK: Issues

    /// Editor ▸ Show / Hide All Issues (⌃⌘L).
    @objc public func toggleInlineIssues(_ sender: Any?) {
        let show = !editor.showsInlineIssues
        for e in editorArea.allEditors { e.showsInlineIssues = show }
    }

    // MARK: Structure

    @objc public func reindent(_ sender: Any?) { editor.reindentLines() }
    @objc public func shiftLeft(_ sender: Any?) { editor.shiftLines(right: false) }
    @objc public func shiftRight(_ sender: Any?) { editor.shiftLines(right: true) }
    @objc public func reformatToWidth(_ sender: Any?) { if !editor.reformatToWidth() { NSSound.beep() } }
    @objc public func formatToMultipleLines(_ sender: Any?) { if !editor.formatToMultipleLines() { NSSound.beep() } }
    @objc public func moveLineUp(_ sender: Any?) { editor.moveLines(up: true) }
    @objc public func moveLineDown(_ sender: Any?) { editor.moveLines(up: false) }
    @objc public func addDocumentation(_ sender: Any?) { if !editor.addDocumentation() { NSSound.beep() } }

    /// Format Selection / Format File (⌃⌥⇧I / ⌃⇧I) with `swift-format`.
    @objc public func formatSelection(_ sender: Any?) { runSwiftFormat(selectionOnly: true) }
    @objc public func formatFile(_ sender: Any?) { runSwiftFormat(selectionOnly: false) }

    @discardableResult
    func runSwiftFormat(selectionOnly: Bool) -> Task<Void, Never> {
        let e = editor
        return Task { [weak self] in
            let r = await e.formatWithSwiftFormat(selectionOnly: selectionOnly)
            if case .failure(let f) = r {
                NSSound.beep()
                self?.session.packageIssues = [Diagnostic(severity: .warning, message: "Format: \(f.description)")]
            }
        }
    }

    // MARK: Code Folding

    @objc public func foldMethodsAndFunctions(_ sender: Any?) { editor.foldMethodsAndFunctions(true) }
    @objc public func unfoldMethodsAndFunctions(_ sender: Any?) { editor.foldMethodsAndFunctions(false) }
    @objc public func foldCommentBlocks(_ sender: Any?) { editor.foldCommentBlocks(true) }
    @objc public func unfoldCommentBlocks(_ sender: Any?) { editor.foldCommentBlocks(false) }

    // MARK: Selection

    @objc public func splitSelectionByLines(_ sender: Any?) { if !editor.splitSelectionByLines() { NSSound.beep() } }
    @objc public func balanceDelimiters(_ sender: Any?) { if !editor.balanceDelimiters() { NSSound.beep() } }
    @objc public func selectColumnUp(_ sender: Any?) { if !editor.addColumnSelection(up: true) { NSSound.beep() } }
    @objc public func selectColumnDown(_ sender: Any?) { if !editor.addColumnSelection(up: false) { NSSound.beep() } }

    /// Editor ▸ Selection ▸ Select All Symbols and Editor ▸ Edit All in
    /// Scope (⌃⌘E): the occurrences as selections, from the language
    /// server's document highlights when it has them.
    @objc public func selectAllSymbols(_ sender: Any?) { selectAllOccurrences() }
    @objc public func editAllInScope(_ sender: Any?) { selectAllOccurrences() }

    @discardableResult
    func selectAllOccurrences() -> Task<Void, Never>? {
        let e = editor
        guard let url = e.fileURL else { NSSound.beep(); return nil }
        guard session.language != nil else {
            if !e.selectAllOccurrences() { NSSound.beep() }
            return nil
        }
        let text = e.text
        let caret = e.textView.selectedRange()
        let pos = e.caretPosition
        return Task { [weak self] in
            let hs = await self?.session.documentHighlights(url, at: pos) ?? []
            guard e.text == text, e.textView.selectedRange() == caret else { return }
            let index = e.textView.lineIndex
            let ranges = hs.map { h -> NSRange in
                let a = index.offset(of: h.start), b = index.offset(of: h.end)
                return NSRange(location: a, length: max(0, b - a))
            }
            if !e.selectAllOccurrences(highlights: ranges) { NSSound.beep() }
        }
    }

    // MARK: Syntax Coloring

    /// Editor ▸ Syntax Coloring ▸ <item> (tag: `EditorMenu.defaultSyntaxTag`
    /// or a language's index).
    @objc public func setSyntaxColoring(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? EditorMenu.defaultSyntaxTag
        let all = SourceTokenizer.Language.allCases
        editor.setSyntaxColoring(all.indices.contains(tag) ? all[tag] : nil)
    }

    // MARK: Font Size (§6.4)

    /// The source editor's font size now (the setting, else the theme's).
    public var sourceFontSize: Double { Preferences.shared.sourceFontSize ?? Preferences.shared.theme.fontSize }

    @objc public func increaseFontSize(_ sender: Any?) { stepFontSize(+1) }
    @objc public func decreaseFontSize(_ sender: Any?) { stepFontSize(-1) }
    @objc public func resetFontSize(_ sender: Any?) { Preferences.shared.sourceFontSize = nil }

    func stepFontSize(_ delta: Double) {
        let r = Preferences.fontSizeRange
        let new = min(r.upperBound, max(r.lowerBound, sourceFontSize.rounded() + delta))
        Preferences.shared.sourceFontSize = new == Preferences.shared.theme.fontSize ? nil : new
    }

    // MARK: Changes (§2.6, §6.3)

    @objc public func jumpToNextChange(_ sender: Any?) { if !editor.jumpToChange(forward: true) { NSSound.beep() } }
    @objc public func jumpToPreviousChange(_ sender: Any?) { if !editor.jumpToChange(forward: false) { NSSound.beep() } }
    /// "Local or Upstream": no upstream comparison is known, so the same
    /// as the local command (§2.6).
    @objc public func jumpToNextLocalOrUpstreamChange(_ sender: Any?) { jumpToNextChange(sender) }
    @objc public func jumpToPreviousLocalOrUpstreamChange(_ sender: Any?) { jumpToPreviousChange(sender) }

    // MARK: Edit menu (§6.4)

    @objc public func copyFileAndLine(_ sender: Any?) { copyToPasteboard(editor.fileAndLine) }
    @objc public func copySymbolName(_ sender: Any?) { copyToPasteboard(editor.symbolName(qualified: false)) }
    @objc public func copyQualifiedSymbolName(_ sender: Any?) { copyToPasteboard(editor.symbolName(qualified: true)) }
    @objc public func duplicateSelection(_ sender: Any?) { if !editor.duplicateSelection() { NSSound.beep() } }

    func copyToPasteboard(_ s: String?) {
        guard let s else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Property list (§2.8)

    @objc public func addPlistItem(_ sender: Any?) { plistEditor?.addItem() }
    @objc public func setPlistValueType(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? -1
        guard PlistTree.types.indices.contains(tag), plistEditor?.setTypeOfSelection(PlistTree.types[tag]) == true else { NSSound.beep(); return }
    }
    @objc public func toggleRawKeysAndValues(_ sender: Any?) { plistEditor?.showsRawKeys.toggle() }

    // MARK: Interface Builder (§2.8)

    @objc public func updateCanvasFrames(_ sender: Any?) { interfaceEditor?.updateFramesClicked(sender) }
    @objc public func toggleDocumentOutline(_ sender: Any?) { interfaceEditor?.toggleOutline(sender) }
    @objc public func zoomCanvasToPercent(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? 10_000
        interfaceEditor?.setZoom(CGFloat(tag) / 10_000)
    }
    @objc public func zoomCanvasToFit(_ sender: Any?) { interfaceEditor?.zoomToFit(sender) }
    @objc public func zoomCanvasIn(_ sender: Any?) { interfaceEditor?.zoomIn(sender) }
    @objc public func zoomCanvasOut(_ sender: Any?) { interfaceEditor?.zoomOut(sender) }

    // MARK: Asset catalog (§2.8)

    /// Editor ▸ Add New Asset ▸ <item> (tag: `AssetCatalogEditorController.creatable`).
    @objc public func addNewAsset(_ sender: Any?) {
        guard let a = assetEditor else { return }
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? 0
        a.addAsset(tag: tag)
    }

    @objc public func deleteSelectedAssets(_ sender: Any?) { assetEditor?.removeSelected() }

    @objc public func showAssetInFinder(_ sender: Any?) {
        guard window?.isVisible == true, let a = assetEditor else { return }
        NSWorkspace.shared.activateFileViewerSelecting([a.selected?.url ?? a.catalog.url])
    }

    @objc public func openAssetInExternalEditor(_ sender: Any?) {
        guard window?.isVisible == true, let set = assetEditor?.selected else { return }
        NSWorkspace.shared.open(set.url)
    }

    // MARK: Validation

    /// Enablement and marks of the commands in this file; nil = not ours.
    func validateEditorCommandItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action else { return nil }
        switch action {
        case #selector(setCanvasLayout(_:)):
            let current = editorArea.canvasLayout
            item.state = (item.tag == 0 && current == nil) || (item.tag == 1 && current == .beside) || (item.tag == 2 && current == .below) ? .on : .off
            return canvas != nil
        case #selector(toggleInlineIssues(_:)): return hasSourceFile
        case #selector(reindent(_:)), #selector(shiftLeft(_:)), #selector(shiftRight(_:)), #selector(reformatToWidth(_:)),
             #selector(formatToMultipleLines(_:)), #selector(addDocumentation(_:)), #selector(duplicateSelection(_:)):
            return hasEditableSource
        case #selector(moveLineUp(_:)): return hasEditableSource && editor.canMoveLineUp
        case #selector(moveLineDown(_:)): return hasEditableSource && editor.canMoveLineDown
        case #selector(formatSelection(_:)), #selector(formatFile(_:)): return hasSourceFile && editor.canFormatWithSwiftFormat
        case #selector(foldMethodsAndFunctions(_:)), #selector(unfoldMethodsAndFunctions(_:)),
             #selector(foldCommentBlocks(_:)), #selector(unfoldCommentBlocks(_:)):
            return hasSourceFile
        case #selector(splitSelectionByLines(_:)): return hasSourceFile && editor.textView.selectedRange().length > 0
        case #selector(balanceDelimiters(_:)), #selector(selectColumnUp(_:)), #selector(selectColumnDown(_:)),
             #selector(selectAllSymbols(_:)), #selector(editAllInScope(_:)):
            return hasSourceFile
        case #selector(setSyntaxColoring(_:)):
            let all = SourceTokenizer.Language.allCases
            let override = editor.syntaxOverride
            if item.tag == EditorMenu.defaultSyntaxTag { item.state = override == nil ? .on : .off }
            else if all.indices.contains(item.tag) {
                let l = all[item.tag]
                item.state = override == l ? .on : (override == nil && editor.fileLanguage == l ? .mixed : .off)
            }
            return hasSourceFile
        case #selector(increaseFontSize(_:)): return sourceFontSize < Preferences.fontSizeRange.upperBound
        case #selector(decreaseFontSize(_:)): return sourceFontSize > Preferences.fontSizeRange.lowerBound
        case #selector(resetFontSize(_:)): return Preferences.shared.sourceFontSize != nil
        case #selector(jumpToNextChange(_:)), #selector(jumpToPreviousChange(_:)),
             #selector(jumpToNextLocalOrUpstreamChange(_:)), #selector(jumpToPreviousLocalOrUpstreamChange(_:)):
            return hasSourceFile && !editor.sourceChanges.isEmpty
        case #selector(copyFileAndLine(_:)): return hasSourceFile
        case #selector(copySymbolName(_:)), #selector(copyQualifiedSymbolName(_:)): return hasSourceFile && editor.symbolName(qualified: false) != nil
        case #selector(addPlistItem(_:)): return plistEditor != nil
        case #selector(setPlistValueType(_:)):
            let t = plistEditor?.selectedTypeName
            item.state = PlistTree.types.indices.contains(item.tag) && PlistTree.types[item.tag] == t ? .on : .off
            return t != nil
        case #selector(toggleRawKeysAndValues(_:)):
            item.state = plistEditor?.showsRawKeys == true ? .on : .off
            return plistEditor != nil
        case #selector(updateCanvasFrames(_:)), #selector(zoomCanvasToFit(_:)), #selector(zoomCanvasIn(_:)), #selector(zoomCanvasOut(_:)):
            return interfaceEditor != nil
        case #selector(zoomCanvasToPercent(_:)):
            item.state = interfaceEditor.map { abs($0.zoom * 10_000 - CGFloat(item.tag)) < 1 ? .on : .off } ?? .off
            return interfaceEditor != nil
        case #selector(toggleDocumentOutline(_:)):
            item.state = interfaceEditor?.isOutlineVisible == true ? .on : .off
            return interfaceEditor != nil
        case #selector(addNewAsset(_:)), #selector(deleteSelectedAssets(_:)), #selector(showAssetInFinder(_:)), #selector(openAssetInExternalEditor(_:)):
            guard let a = assetEditor else { return false }
            return action == #selector(addNewAsset(_:)) || a.selected != nil
        default: return nil
        }
    }
}
