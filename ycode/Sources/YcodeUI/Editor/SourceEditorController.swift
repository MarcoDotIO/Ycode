import AppKit
import YcodeBuild
import YcodeLanguage

/// A text view that paints issue annotations and the current-line tint
/// behind the text.
@MainActor
final class SourceTextView: NSTextView {
    var issues: [Int: [Diagnostic]] = [:] { didSet { needsDisplay = true } }
    /// The text changed since the issues were set: annotations draw grey.
    var issuesStale = false { didSet { if oldValue != issuesStale { needsDisplay = true } } }
    /// Editor ▸ Hide All Issues turns the inline annotations off.
    var showsIssues = true { didSet { needsDisplay = true } }
    /// Inline Code Review marks by line (reference-ui-4.md §15).
    var reviewMarks: [Int: LineDiff.Row.Kind] = [:] { didSet { needsDisplay = true } }
    /// Find matches to tint, and the current one (drawn stronger).
    var findMatches: [NSRange] = [] { didSet { needsDisplay = true } }
    /// Lines whose region is folded: they get a "⋯" token at their end.
    var foldedStartLines: Set<Int> = [] { didSet { needsDisplay = true } }
    var currentFindMatch: NSRange? { didSet { needsDisplay = true } }
    /// Editing ▸ Display extras and issue presentation (SourceEditorDisplayExtras.swift).
    let displayState = EditorDisplayState()

    /// Editor overscroll: blank space after the last line.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: heightWithOverscroll(newSize.height)))
    }

    override func performFindPanelAction(_ sender: Any?) {
        if owner?.performFind(tag: (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 1) != true {
            super.performFindPanelAction(sender)
        }
    }

    /// Edit ▸ Delete (⌘⌫, reference-ui-5.md §2.3) deletes the selection;
    /// with none, it deletes to the start of the line, as ⌘⌫ does in text
    /// (the menu item would otherwise take the keystroke).
    override func delete(_ sender: Any?) {
        if selectedRange().length == 0 { deleteToBeginningOfLine(sender) } else { super.delete(sender) }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(delete(_:)) ? isEditable : super.validateMenuItem(item)
    }

    /// Rectangles covering a character range (one per line fragment), in
    /// view coordinates, from TextKit 2 text segments.
    func segmentRects(_ range: NSRange) -> [NSRect] {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        tlm.ensureLayout(for: textRange)
        var rects: [NSRect] = []
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            return true
        }
        return rects
    }
    var highlightedLine: Int? { didSet { needsDisplay = true } }
    /// The debugger's stop annotation on the highlighted line.
    var stopAnnotation: String? { didSet { needsDisplay = true } }
    /// The insertion point's line: a subtle full-width background
    /// (reference-ui.md §3).
    var caretLine: Int? {
        didSet {
            guard oldValue != caretLine else { return }
            for l in [oldValue, caretLine].compactMap({ $0 }) {
                if let r = lineRect(l) { setNeedsDisplay(r.insetBy(dx: 0, dy: -1)) } else { needsDisplay = true }
            }
        }
    }
    var lineIndex = LineIndex("")
    weak var owner: SourceEditorController?

    /// Settings ▸ Navigation ▸ Click on Code: ⌥-click shows Quick Help;
    /// ⌘-click and ⌃⌘-click jump to the definition (by default).
    override func mouseDown(with event: NSEvent) {
        if let action = Preferences.shared.codeClick(for: event.modifierFlags) {
            let p = convert(event.locationInWindow, from: nil)
            let offset = characterIndexForInsertion(at: p)
            if action == .quickHelp { owner?.quickHelp(atOffset: offset) } else { owner?.jumpToDefinition(atOffset: offset) }
            return
        }
        // A click on an issue annotation that has a fix-it offers it
        // (reference-ui-6.md §4.3.2; the gutter has no lightbulb).
        let p = convert(event.locationInWindow, from: nil)
        if let line = owner?.annotationLine(at: p), let menu = owner?.fixItMenu(line: line) {
            menu.popUp(positioning: nil, at: p, in: self)
            return
        }
        super.mouseDown(with: event)
        // A click inside a placeholder selects the whole token.
        let s = selectedRange()
        if s.length == 0, let t = Placeholders.token(containing: s.location, in: string) { setSelectedRange(t) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Any other selection change returns to one selection.
        if !keepsMultipleRanges && !multipleRanges.isEmpty { multipleRanges = [] }
        needsDisplay = true // the selected token is drawn stronger
    }

    /// Several selections or insertion points at once (Select Column Up /
    /// Down, Split Selection By Lines, Select All Symbols, Edit All in
    /// Scope; reference-ui-5.md §6.4), in text order. Empty = the ordinary
    /// single selection. Typing and deleting edit at each; Escape, a click
    /// or moving the caret returns to one.
    var multipleRanges: [NSRange] = [] { didSet { needsDisplay = true } }
    private var keepsMultipleRanges = false

    /// Sets several ranges; the native selection is `primary` (else the last).
    func setMultipleRanges(_ ranges: [NSRange], primary: NSRange? = nil) {
        var sorted: [NSRange] = []
        for r in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) where sorted.last.map({ NSMaxRange($0) <= r.location && $0 != r }) ?? true {
            sorted.append(r)
        }
        guard let last = sorted.last else { return }
        keepsMultipleRanges = true
        setSelectedRange(primary ?? last)
        keepsMultipleRanges = false
        multipleRanges = sorted.count > 1 ? sorted : []
    }

    /// Replaces each of the ranges `edit` returns (one per selection, in
    /// order) as one undo step; the selections become insertion points
    /// after the inserted text.
    func editEachSelection(_ edit: (NSRange) -> (NSRange, String)?) {
        let edits = multipleRanges.compactMap(edit)
        guard !edits.isEmpty else { return }
        keepsMultipleRanges = true
        undoManager?.beginUndoGrouping()
        for (r, s) in edits.reversed() where shouldChangeText(in: r, replacementString: s) {
            replaceCharacters(in: r, with: s)
            didChangeText()
        }
        undoManager?.endUndoGrouping()
        var carets: [NSRange] = []
        var delta = 0
        for (r, s) in edits {
            let n = (s as NSString).length
            carets.append(NSRange(location: r.location + delta + n, length: 0))
            delta += n - r.length
        }
        setSelectedRange(carets[carets.count - 1])
        keepsMultipleRanges = false
        multipleRanges = carets.count > 1 ? carets : []
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard multipleRanges.count > 1, replacementRange.location == NSNotFound else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        editEachSelection { ($0, s) }
    }

    override func deleteBackward(_ sender: Any?) {
        guard multipleRanges.count > 1 else { super.deleteBackward(sender); return }
        editEachSelection { r in r.length > 0 ? (r, "") : (r.location > 0 ? (NSRange(location: r.location - 1, length: 1), "") : nil) }
    }

    /// Escape returns to one selection.
    override func cancelOperation(_ sender: Any?) {
        if !multipleRanges.isEmpty { multipleRanges = []; return }
        super.cancelOperation(sender)
    }

    /// The other selections: tinted ranges and thin insertion points.
    func drawMultipleRanges(in rect: NSRect) {
        let primary = selectedRange()
        for r in multipleRanges where r != primary {
            if r.length > 0 {
                Theme.selectionColor.setFill()
                for seg in segmentRects(r) where seg.intersects(rect) { seg.fill() }
            } else if let c = caretRect(at: r.location), c.intersects(rect) {
                insertionPointColor.setFill()
                NSRect(x: c.minX, y: c.minY, width: 1.5, height: c.height).fill()
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { owner?.onActivate?() }
        return ok
    }

    /// Records each edit (range and old text) for incremental highlighting.
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: range, replacementString: replacementString)
        if ok { owner?.noteEdit(range: range, replacement: replacementString ?? "") }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if owner?.handleCompletionKey(event) == true { return }
        if owner?.handlePlaceholderKey(event) == true { return }
        super.keyDown(with: event)
    }

    /// Show Completions (Control-Space) asks the language server.
    override func complete(_ sender: Any?) { owner?.requestCompletion() }

    /// The insertion-point rectangle for a UTF-16 offset, in view
    /// coordinates, from TextKit 2 line-fragment geometry.
    func caretRect(at offset: Int) -> NSRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return nil }
        // After an edit, fragments past it hold estimated frames until laid out.
        tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: loc) ?? tlm.documentRange)
        guard let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        let fragStart = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
        let inFrag = offset - fragStart
        let origin = frag.layoutFragmentFrame.origin
        for line in frag.textLineFragments {
            let r = line.characterRange
            if inFrag >= r.location && inFrag <= NSMaxRange(r) {
                let p = line.locationForCharacter(at: inFrag)
                let b = line.typographicBounds
                return NSRect(x: origin.x + b.minX + p.x + textContainerOrigin.x,
                              y: origin.y + b.minY + textContainerOrigin.y, width: 1, height: b.height)
            }
        }
        return nil
    }

    func lineRect(_ line: Int) -> NSRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let r = lineIndex.range(ofLine: line),
              let loc = tcm.location(tcm.documentRange.location, offsetBy: r.location),
              let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        var f = frag.layoutFragmentFrame
        f.origin.y += textContainerOrigin.y
        f.origin.x = 0
        f.size.width = bounds.width
        return f
    }

    /// Settings ▸ Text Editing ▸ Page guide at column (nil = off).
    var pageGuideColumn: Int? { didSet { needsDisplay = true } }

    /// Tab inserts one indentation step (spaces or a tab, per settings).
    override func insertTab(_ sender: Any?) {
        insertText(Preferences.shared.indentUnit, replacementRange: selectedRange())
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let col = pageGuideColumn {
            let w = ("0" as NSString).size(withAttributes: [.font: Theme.font]).width
            let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + w * CGFloat(col)
            NSColor.separatorColor.withAlphaComponent(0.08).setFill()
            NSRect(x: x, y: rect.minY, width: bounds.width - x, height: rect.height).fill()
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
        }
        for line in foldedStartLines {
            guard let r = lineIndex.range(ofLine: line), let end = segmentRects(NSRange(location: NSMaxRange(r), length: 0)).first
                ?? segmentRects(NSRange(location: max(r.location, NSMaxRange(r) - 1), length: 1)).first else { continue }
            let token = NSRect(x: end.maxX + 6, y: end.minY + 1, width: 26, height: max(end.height - 2, 12))
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: token, xRadius: 4, yRadius: 4).fill()
            let dots = NSAttributedString(string: "⋯", attributes: [.font: Theme.font, .foregroundColor: NSColor.secondaryLabelColor])
            dots.draw(at: NSPoint(x: token.midX - dots.size().width / 2, y: token.midY - dots.size().height / 2))
        }
        let sel = selectedRange()
        for p in Placeholders.ranges(in: string) {
            let inner = NSRange(location: p.location + 2, length: p.length - 4)
            (p == sel ? Theme.placeholderSelectedFill : Theme.placeholderFill).setFill()
            for r in segmentRects(inner) where r.intersects(rect) {
                NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: 0.5), xRadius: 5, yRadius: 5).fill()
            }
        }
        for m in findMatches {
            let isCurrent = m == currentFindMatch
            (isCurrent ? NSColor.systemYellow : NSColor.systemYellow.withAlphaComponent(0.3)).setFill()
            for r in segmentRects(m) where r.intersects(rect) {
                NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
            }
        }
        if let l = caretLine, l != highlightedLine, let r = lineRect(l), r.intersects(rect) {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            r.fill()
        }
        if let l = highlightedLine, let r = lineRect(l) {
            Theme.currentLineColor.setFill()
            r.fill()
            if let a = stopAnnotation { drawStopAnnotation(a, in: r) }
        }
        drawDisplayExtras(in: rect)
        drawReviewMarks(in: rect)
        drawMultipleRanges(in: rect)
        drawIssueAnnotations(in: rect)
    }
}

/// A thumbnail of the whole file at the editor's right edge (⌃⇧⌘M).
@MainActor
final class MinimapView: NSView {
    var lines: [Int] = [] { didSet { needsDisplay = true } }
    /// Declaration labels at their lines ("landmarks", reference-ui-5.md §6.5).
    var landmarks: [(line: Int, name: String)] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    /// §6.5: about 13–14 % of the editor's width, at least 60 pt.
    static func width(forEditorWidth w: CGFloat) -> CGFloat { max(60, (w * 0.133).rounded()) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSColor.tertiaryLabelColor.setFill()
        for (i, len) in lines.enumerated() where len > 0 {
            let y = CGFloat(i) * 2
            if y > bounds.height { break }
            NSRect(x: 6, y: y, width: min(CGFloat(len), bounds.width - 10), height: 1).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        for l in landmarks {
            let y = CGFloat(l.line - 1) * 2
            if y > bounds.height { break }
            NSAttributedString(string: l.name, attributes: attrs).draw(at: NSPoint(x: 6, y: max(0, y - 5)))
        }
    }
}

/// The path above the editor: Related Items, then workspace › groups ›
/// file › symbol, and the issue controls at the right end. The assistant's
/// bar starts with a close button and the mode pop-up. No history buttons:
/// history is in the toolbar (`specs/ide/reference-ui-5.md` §6.1).
@MainActor
final class JumpBar: NSView {
    let stack = NSStackView()
    /// The right end: Show Previous Issue, the Issues pull-down, Show Next Issue.
    let issueStack = NSStackView()
    var onToggleMinimap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for s in [stack, issueStack] {
            s.orientation = .horizontal
            s.spacing = 2
            s.translatesAutoresizingMaskIntoConstraints = false
            addSubview(s)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            {
                let c = stack.trailingAnchor.constraint(lessThanOrEqualTo: issueStack.leadingAnchor, constant: -6)
                c.priority = .defaultLow
                return c
            }(),
            issueStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            issueStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        issueStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// The Related Items button was clicked (the window opens the ⌃1 menu).
    var onRelatedItems: (() -> Void)?
    /// The assistant pane's close button ("Close this Editor Pane").
    var onClose: (() -> Void)?
    var showsCloseButton = false { didSet { if oldValue != showsCloseButton { setPath(lastComponents) } } }
    private(set) var closeButton: NSButton?
    private(set) var relatedItemsButton: NSButton?
    /// The Counterparts menu: (title, path) pairs, and what picking one does.
    var counterparts: [(String, String)] = []
    var onPickCounterpart: ((String) -> Void)?
    private(set) var counterpartsMenu: NSPopUpButton?
    /// The assistant's mode pop-up: titles, the selected one, and the action.
    var modes: [String] = []
    /// Modes listed but disabled (no data for the file).
    var disabledModes: Set<String> = []
    var selectedMode = ""
    var onPickMode: ((String) -> Void)?
    private(set) var modeMenu: NSPopUpButton?
    /// The title of the related-files pull-down (the mode's name).
    var relatedTitle = "Counterparts"
    private var lastComponents: [(String, String)] = []
    /// The symbol component after the path ("No Selection" outside a declaration).
    var symbolTitle: String? { didSet { if oldValue != symbolTitle { setPath(lastComponents) } } }

    func setCounterparts(_ list: [(String, String)]) {
        counterparts = list
        setPath(lastComponents)
    }

    func setPath(_ components: [(String, String)]) {
        lastComponents = components
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        closeButton = nil
        relatedItemsButton = nil
        if showsCloseButton {
            let b = iconButton("xmark", "Close this Editor Pane")
            b.target = self
            b.action = #selector(closeClicked)
            closeButton = b
            stack.addArrangedSubview(b)
        } else {
            let b = iconButton("square.grid.2x2", "Navigate to Related Items")
            b.setAccessibilityLabel("Related Items")
            b.target = self
            b.action = #selector(relatedItemsClicked)
            relatedItemsButton = b
            stack.addArrangedSubview(b)
        }
        counterpartsMenu = nil
        modeMenu = nil
        if !modes.isEmpty {
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            pop.addItems(withTitles: modes)
            pop.autoenablesItems = false
            for item in pop.itemArray where disabledModes.contains(item.title) { item.isEnabled = false }
            pop.selectItem(withTitle: selectedMode)
            pop.isBordered = false
            pop.font = .systemFont(ofSize: 11)
            pop.controlSize = .small
            pop.target = self
            pop.action = #selector(modeChosen(_:))
            modeMenu = pop
            stack.addArrangedSubview(pop)
        }
        // The primary editor lists its counterparts under Related Items;
        // the assistant shows them in a pull-down named after its mode.
        if !counterparts.isEmpty && !modes.isEmpty {
            let pop = NSPopUpButton(frame: .zero, pullsDown: true)
            pop.addItem(withTitle: relatedTitle)
            for (title, path) in counterparts {
                pop.addItem(withTitle: title)
                pop.lastItem?.representedObject = path
            }
            pop.isBordered = false
            pop.font = .systemFont(ofSize: 11)
            pop.controlSize = .small
            pop.target = self
            pop.action = #selector(counterpartChosen(_:))
            counterpartsMenu = pop
            stack.addArrangedSubview(pop)
        }
        if components.isEmpty { stack.addArrangedSubview(label("No Selection", secondary: true)) }
        for (i, (title, symbol)) in components.enumerated() {
            if i > 0 { stack.addArrangedSubview(label("›", secondary: true)) }
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let iv = NSImageView(image: img)
                iv.contentTintColor = .secondaryLabelColor
                stack.addArrangedSubview(iv)
            }
            stack.addArrangedSubview(label(title, secondary: false))
        }
        if let symbolTitle, !components.isEmpty {
            stack.addArrangedSubview(label("›", secondary: true))
            stack.addArrangedSubview(label(symbolTitle, secondary: symbolTitle == "No Selection"))
        }
    }

    private func label(_ s: String, secondary: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = secondary ? .tertiaryLabelColor : .labelColor
        return l
    }

    @objc private func modeChosen(_ p: NSPopUpButton) { if let t = p.titleOfSelectedItem { onPickMode?(t) } }
    @objc private func relatedItemsClicked() { onRelatedItems?() }
    @objc private func closeClicked() { onClose?() }

    /// The titles of the controls in order, left to right (tests): tooltips
    /// of buttons, titles of pop-ups and labels.
    var componentTitles: [String] {
        (stack.arrangedSubviews + issueStack.arrangedSubviews).compactMap { v -> String? in
            switch v {
            case let p as NSPopUpButton:
                p.pullsDown ? (p.itemArray.first?.title.isEmpty == false ? p.itemArray.first!.title : (p.accessibilityLabel() ?? ""))
                    : (p.titleOfSelectedItem ?? "")
            case let b as NSButton: b.toolTip ?? b.title
            case let t as NSTextField: t.stringValue
            default: nil
            }
        }
    }

    // MARK: Issues (§6.1.2)

    /// One issue of the file: its message, line and whether it is an error.
    struct IssueEntry: Equatable { var message: String; var line: Int; var isError: Bool }
    /// The file's issues; nil hides the three controls (the workspace has
    /// no issues).
    private(set) var issues: [IssueEntry]?
    var onPreviousIssue: (() -> Void)?
    var onNextIssue: (() -> Void)?
    var onPickIssue: ((Int) -> Void)?
    private(set) var issuesMenu: NSPopUpButton?
    /// The severity glyph the Issues menu shows (error if any, else warning).
    private(set) var issueGlyph: String?

    func setIssues(_ list: [IssueEntry]?) {
        guard list != issues || (list != nil && issueStack.arrangedSubviews.isEmpty) else { return }
        issues = list
        issueStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        issuesMenu = nil
        guard let list else { return }
        // Three glyph-only controls: ‹, the severity glyph menu, ›
        // (reference-ui-6.md §4.1.2, E2).
        let prev = iconButton("chevron.left", "Show Previous Issue")
        prev.target = self
        prev.action = #selector(previousIssueClicked)
        let next = iconButton("chevron.right", "Show Next Issue")
        next.target = self
        next.action = #selector(nextIssueClicked)
        let pop = NSPopUpButton(frame: .zero, pullsDown: true)
        pop.isBordered = false
        pop.controlSize = .small
        pop.font = .systemFont(ofSize: 11)
        pop.addItem(withTitle: "")
        let hasError = list.contains { $0.isError }
        issueGlyph = hasError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        pop.item(at: 0)?.image = NSImage(systemSymbolName: issueGlyph!, accessibilityDescription: "Issues")
        pop.imagePosition = .imageOnly
        (pop.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        pop.widthAnchor.constraint(equalToConstant: 20).isActive = true
        pop.toolTip = "Issues"
        pop.setAccessibilityLabel("Issues")
        pop.setAccessibilityTitle("Issues")
        if list.isEmpty {
            pop.addItem(withTitle: "No Issues")
            pop.lastItem?.isEnabled = false
        }
        for e in list {
            let item = NSMenuItem(title: e.message, action: #selector(issuePicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = e.line
            item.image = NSImage(systemSymbolName: e.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
            pop.menu?.addItem(item)
        }
        issuesMenu = pop
        for v in [prev, pop, next] as [NSView] { issueStack.addArrangedSubview(v) }
    }

    @objc private func previousIssueClicked() { onPreviousIssue?() }
    @objc private func nextIssueClicked() { onNextIssue?() }
    @objc private func issuePicked(_ item: NSMenuItem) { onPickIssue?(item.tag) }
    @objc private func counterpartChosen(_ p: NSPopUpButton) {
        if let path = p.selectedItem?.representedObject as? String { onPickCounterpart?(path) }
    }

    private func iconButton(_ symbol: String, _ name: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(), target: nil, action: nil)
        b.identifier = NSUserInterfaceItemIdentifier(symbol)
        b.isBordered = false
        b.toolTip = name
        return b
    }
}

/// The source editor: jump bar, gutter, text and minimap. See
/// `specs/ide/source-editor.md`.
@MainActor
public final class SourceEditorController: NSViewController, NSTextViewDelegate, NSTextContentManagerDelegate {
    public private(set) var fileURL: URL?
    public var pathComponents: [(String, String)] = [] { didSet { jumpBar.setPath(pathComponents) } }
    public var onBreakpointClick: ((String, Int) -> Void)?
    private var prefsObserver: NSObjectProtocol?
    private var showsMinimapCache = false
    /// The files this editor showed (Go Back / Go Forward).
    public var history = NavigationHistory()
    /// Called when the editor's text view becomes first responder.
    public var onActivate: (() -> Void)?
    /// Jump bar: the Related Items button (⌃1's menu), the assistant's
    /// close button, and the issue controls at the right end
    /// (reference-ui-5.md §6.1).
    public var onRelatedItems: (() -> Void)? { didSet { jumpBar.onRelatedItems = onRelatedItems } }
    public var onClosePane: (() -> Void)? { didSet { jumpBar.onClose = onClosePane } }
    /// The assistant's bar: a close button in place of Related Items.
    public var showsCloseButton: Bool {
        get { jumpBar.showsCloseButton }
        set { jumpBar.showsCloseButton = newValue }
    }
    public var onPreviousIssue: (() -> Void)? { didSet { jumpBar.onPreviousIssue = onPreviousIssue } }
    public var onNextIssue: (() -> Void)? { didSet { jumpBar.onNextIssue = onNextIssue } }
    public var onPickIssue: ((Int) -> Void)? { didSet { jumpBar.onPickIssue = onPickIssue } }
    /// The jump bar's items left to right (tests).
    public var jumpBarTitles: [String] { jumpBar.componentTitles }
    /// The Issues pull-down's entries ("message" per issue; tests).
    public var jumpBarIssueTitles: [String]? { jumpBar.issuesMenu.map { $0.itemArray.dropFirst().map(\.title) } }
    /// The Issues menu's glyph and its visible title ("" — glyph only; tests).
    public var jumpBarIssueGlyph: (symbol: String, title: String)? {
        jumpBar.issuesMenu.map { (jumpBar.issueGlyph ?? "", $0.itemArray.first?.title ?? "") }
    }
    /// The issue arrows' glyphs (tests).
    public var jumpBarIssueArrowSymbols: [String] {
        jumpBar.issueStack.arrangedSubviews.compactMap { v in
            guard let b = v as? NSButton, !(b is NSPopUpButton) else { return nil }
            return b.identifier?.rawValue
        }
    }
    /// Shows the file's issues at the jump bar's right end; nil hides them.
    public func setJumpBarIssues(_ list: [(message: String, line: Int, isError: Bool)]?) {
        jumpBar.setIssues(list?.map { JumpBar.IssueEntry(message: $0.message, line: $0.line, isError: $0.isError) })
    }
    /// The jump bar's Counterparts menu (title, path); empty hides it.
    public func setCounterparts(_ list: [(String, String)], onPick: @escaping (String) -> Void) {
        jumpBar.onPickCounterpart = onPick
        jumpBar.setCounterparts(list)
    }
    public var counterpartTitles: [String] { jumpBar.counterparts.map(\.0) }

    /// Shows the assistant mode pop-up in this editor's jump bar (empty
    /// titles remove it); the related-files pull-down takes the mode's name.
    public func setAssistantModes(_ titles: [String], selected: String, disabled: Set<String> = [], onPick: @escaping (String) -> Void) {
        jumpBar.disabledModes = disabled
        jumpBar.modes = titles
        jumpBar.selectedMode = selected
        jumpBar.relatedTitle = titles.isEmpty ? "Counterparts" : selected
        jumpBar.onPickMode = onPick
        jumpBar.setCounterparts(jumpBar.counterparts)
    }
    public var assistantModeTitles: [String] { jumpBar.modes }
    public var disabledAssistantModes: Set<String> { jumpBar.disabledModes }
    public var onBreakpointMove: ((String, Int, Int) -> Void)?
    public var onBreakpointRemove: ((String, Int) -> Void)?
    public var onBreakpointEdit: ((String, Int) -> Void)?
    public var onRunTest: ((String, Int) -> Void)?
    /// ⌥-click: (file, position, anchor rect in the text view).
    public var onQuickHelp: ((URL, Position, NSRect) -> Void)?
    /// ⌘-click: (file, position).
    public var onJumpToDefinition: ((URL, Position) -> Void)?
    /// The insertion point moved (Quick Help inspector follows it).
    public var onSelectionChange: ((URL, Position) -> Void)?
    public private(set) var isDirty = false
    /// Language-service hooks (set by the window).
    public var onDocumentOpened: ((URL, String) -> Void)?
    /// The editor stopped showing a file (it opened another one).
    public var onDocumentClosed: ((URL) -> Void)?
    public var onDocumentChanged: ((URL, String) -> Void)?
    public var completionProvider: ((URL, Position) async -> [CompletionItem])?
    let completionPopup = CompletionPopupView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
    public var isShowingCompletions: Bool { completionPopup.superview != nil }
    public var completions: CompletionModel { completionPopup.model }

    let jumpBar = JumpBar()
    /// Code Review mode state (CodeReviewViews.swift).
    let review = CodeReviewState()
    /// The empty-editor view, when shown (EmptyEditorView.swift).
    let emptyHolder = EmptyStateHolder()
    /// The editor stopped showing a document (the window shows Recent Files).
    public var onBecameEmpty: (() -> Void)?
    final class SymbolCache {
        var symbols: [SymbolScanner.Symbol]?
        var highlightTimer: Timer?
        /// The identifier whose instances are highlighted (selected-symbol highlighting).
        var highlighted: String?
    }
    let symbolCache = SymbolCache()
    let findBar = FindBarView()
    /// The comparison (code review) view, over the text when shown.
    public let comparison = ComparisonView()
    public var isShowingComparison: Bool { !comparison.isHidden }
    private var findBarHeight: NSLayoutConstraint!
    public private(set) var find = EditorFind()
    /// Brace regions of the current text, and the folded ones (by start line).
    public private(set) var foldRegions: [FoldRegion] = []
    public internal(set) var foldedStarts: Set<Int> = []
    /// Lines currently hidden by folds.
    public private(set) var hiddenLines: Set<Int> = []
    public var isShowingFindBar: Bool { findBarHeight.constant > 0 }
    let scrollView = NSScrollView()
    let textView: SourceTextView
    let gutter: GutterView
    let minimap = MinimapView()
    private var minimapWidth: NSLayoutConstraint!
    /// The coloring language: the file's, or Editor ▸ Syntax Coloring's choice.
    var language = SourceTokenizer.Language.plain
    /// The language the text is colored as (Display extras).
    var displayLanguage: SourceTokenizer.Language { language }
    /// Editor ▸ Syntax Coloring: nil = Default for File Type (per file).
    public internal(set) var syntaxOverride: SourceTokenizer.Language?
    /// Multi-line comments and `//` runs (Fold Comment Blocks).
    public internal(set) var commentRegions: [FoldRegion] = []
    /// The file's staged (index) and committed (HEAD) contents for the
    /// change gutter; nil when the file is not in a git working copy
    /// (`reference-ui-5.md` §6.3).
    /// Reads the file's index and HEAD versions (nil: not in git). Called
    /// off the main thread's critical path: the editor awaits it and keeps
    /// the result until the next explicit refresh (open, save, a
    /// source-control change), so typing never waits for git.
    public var changeBaselines: ((URL) async -> (index: String?, head: String?)?)?
    var changeRefresh: Timer?
    /// The baselines of `fileURL` last read (`.some(nil)`: not in git).
    var changeBaselineCache: (url: URL, base: (index: String?, head: String?)?)?
    /// The baseline read in progress, if any.
    public internal(set) var changeBaselineLoading: Task<Void, Never>?
    var changeBaselineGeneration = 0
    /// The change gutter refreshes this long after the last edit (§6.3.4).
    public static var changeRefreshDelay: TimeInterval = 0.5

    public override init(nibName: NSNib.Name?, bundle: Bundle?) {
        textView = SourceTextView(usingTextLayoutManager: true)
        gutter = GutterView(textView: textView, scrollView: scrollView)
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init() { self.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = NSView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Theme.font
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.delegate = self
        textView.owner = self
        completionPopup.onAccept = { [weak self] in self?.acceptCompletion() }
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        // The gutter (a ruler) draws past its frame unless clipped: a
        // gutter-wide cell showed above it, in the jump bar's row
        // (reference-ui-6.md §1.3.3).
        scrollView.clipsToBounds = true
        gutter.clipsToBounds = true
        gutter.onClick = { [weak self] l in self?.fileURL.map { self?.onBreakpointClick?($0.path, l) } }
        gutter.onMove = { [weak self] a, b in self?.fileURL.map { self?.onBreakpointMove?($0.path, a, b) } }
        gutter.onRemove = { [weak self] l in self?.fileURL.map { self?.onBreakpointRemove?($0.path, l) } }
        gutter.onRibbonClick = { [weak self] l in self?.toggleFold(at: l) }
        gutter.onEdit = { [weak self] l in self?.fileURL.map { self?.onBreakpointEdit?($0.path, l) } }
        gutter.onRunTest = { [weak self] l in self?.fileURL.map { self?.onRunTest?($0.path, l) } }
        textView.textLayoutManager?.textContentManager?.delegate = self

        findBar.onChange = { [weak self] in self?.findChanged() }
        findBar.onStep = { [weak self] f in self?.findStep(forward: f) }
        findBar.onReplace = { [weak self] all in all ? self?.replaceAll() : self?.replaceCurrent() }
        findBar.onDone = { [weak self] in self?.hideFindBar() }
        findBar.clipsToBounds = true
        comparison.isHidden = true
        for v in [jumpBar, findBar, scrollView, minimap, comparison] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        minimapWidth = minimap.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            jumpBar.topAnchor.constraint(equalTo: root.topAnchor),
            jumpBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            jumpBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            jumpBar.heightAnchor.constraint(equalToConstant: 26),
            findBar.topAnchor.constraint(equalTo: jumpBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            minimap.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            comparison.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            comparison.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            comparison.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            comparison.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            minimap.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            minimapWidth,
        ])
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBarHeight.isActive = true
        view = root
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        applyPreferences()
        // No document yet: Related Items and "No Selection" over an empty
        // editor (reference-ui-6.md §1.3.1, W4).
        jumpBar.setPath(pathComponents)
        if fileURL == nil && auxiliary == nil && textView.string.isEmpty { showsNoDocument = true }
    }

    /// The editor shows no document: no gutter and no editable text, only
    /// the editor's background under the jump bar (reference-ui-6.md §1.3).
    public internal(set) var showsNoDocument: Bool {
        get { noDocument.value }
        set {
            noDocument.value = newValue
            scrollView.rulersVisible = !newValue
            if newValue { textView.isEditable = false }
        }
    }
    let noDocument = NoDocumentFlag()

    /// The minimap keeps its share of the editor's width (§6.5).
    public override func viewDidLayout() {
        super.viewDidLayout()
        if minimapWidth.constant > 0 {
            let w = MinimapView.width(forEditorWidth: view.bounds.width)
            if minimapWidth.constant != w { minimapWidth.constant = w }
        }
    }

    /// The minimap's width (tests).
    public var minimapWidthValue: CGFloat { minimapWidth.constant }

    // MARK: Other editors in this area

    /// A view shown instead of the text (project editor, property-list
    /// editor). The jump bar stays.
    public private(set) var auxiliary: NSView?
    /// The file the auxiliary editor shows, when it shows one (the window
    /// title names it, reference-ui-6.md §1.1).
    public private(set) var auxiliaryFile: URL?

    public func showAuxiliary(_ v: NSView, path: [(String, String)], file: URL? = nil) {
        _ = view
        try? save()
        hideComparison()
        hideEmptyState()
        auxiliary?.removeFromSuperview()
        auxiliary = v
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: jumpBar.bottomAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        fileURL = nil
        auxiliaryFile = file
        pathComponents = path
        scrollView.isHidden = true
        minimap.isHidden = true
    }

    public func hideAuxiliary() {
        auxiliary?.removeFromSuperview()
        auxiliary = nil
        auxiliaryFile = nil
        scrollView.isHidden = false
        minimap.isHidden = false
    }

    // MARK: Comparison

    /// Shows HEAD (`old`) beside the editor's current text.
    public func showComparison(old: String, oldTitle: String) {
        _ = view
        comparison.show(old: old, new: textView.string, oldTitle: oldTitle,
                        newTitle: (fileURL?.lastPathComponent ?? "") + " (Local)")
        comparison.isHidden = false
        scrollView.isHidden = true
        minimap.isHidden = true
    }

    public func hideComparison() {
        if !review.inlineShown { removeReviewBar() }
        comparison.onWorkingCopyEdit = nil
        comparison.isHidden = true
        scrollView.isHidden = false
        minimap.isHidden = false
    }

    // MARK: Find bar

    /// performFindPanelAction tags: 1 Find, 2 Next, 3 Previous, 7 Use
    /// Selection for Find, 12 Find and Replace; the Find menu's Replace (5),
    /// Replace All (4), Replace and Find Next (6), Select All Find Matches
    /// (9) and Select Find Matches in Selection (10).
    @discardableResult
    public func performFind(tag: Int) -> Bool {
        switch tag {
        case 1: showFindBar(replace: false)
        case 12: showFindBar(replace: true)
        case 2: findStep(forward: true)
        case 3: findStep(forward: false)
        case 7: useSelectionForFind()
        case 4: replaceAll()
        case 5, 6: replaceCurrent()
        case 9, 10: selectFindMatches(inSelectionOnly: tag == 10)
        default: return false
        }
        return true
    }

    /// Selects every find match (or those inside the selection), one
    /// selection range each.
    public func selectFindMatches(inSelectionOnly: Bool) {
        if find.matches.isEmpty { findChanged() }
        let sel = textView.selectedRange()
        let ms = inSelectionOnly ? find.matches.filter { NSIntersectionRange($0, sel).length == $0.length && $0.length > 0 } : find.matches
        guard !ms.isEmpty else { NSSound.beep(); return }
        textView.setSelectedRanges(ms.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
    }

    public func showFindBar(replace: Bool) {
        _ = view
        findBar.replaceRow.isHidden = !replace
        findBarHeight.constant = replace ? 60 : 32
        view.window?.makeFirstResponder(findBar.queryField)
        findChanged()
    }

    public func hideFindBar() {
        findBarHeight.constant = 0
        textView.findMatches = []
        textView.currentFindMatch = nil
        view.window?.makeFirstResponder(textView)
    }

    /// Sets the query and options as typing in the bar would.
    public func setFind(_ query: String, replacement: String = "", options: WorkspaceSearch.Options = .init()) {
        _ = view
        findBar.queryField.stringValue = query
        findBar.replaceField.stringValue = replacement
        findBar.style.selectItem(at: options.regularExpression ? 1 : 0)
        findBar.match.selectItem(at: options.wholeWord ? 1 : 0)
        findBar.caseMode.selectItem(at: options.ignoreCase ? 0 : 1)
        findChanged()
    }

    func findChanged() {
        find.query = findBar.queryField.stringValue
        find.replacement = findBar.replaceField.stringValue
        find.options = findBar.options
        find.update(text: textView.string, from: textView.selectedRange().location)
        showFindState(select: false)
    }

    public func findStep(forward: Bool) {
        if find.matches.isEmpty { findChanged() }
        find.step(forward)
        showFindState(select: true)
    }

    private func showFindState(select: Bool) {
        textView.findMatches = find.matches
        textView.currentFindMatch = find.currentRange
        findBar.countLabel.stringValue = find.query.isEmpty ? "" : (find.matches.isEmpty ? "No matches" : "\((find.current ?? 0) + 1) of \(find.matches.count)")
        if select, let r = find.currentRange {
            textView.setSelectedRange(r)
            textView.scrollRangeToVisible(r)
        }
    }

    /// ⌘E: the selection becomes the query.
    public func useSelectionForFind() {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return }
        setFind((textView.string as NSString).substring(with: sel), options: findBar.options)
    }

    public func replaceCurrent() {
        find.replacement = findBar.replaceField.stringValue
        guard let r = find.currentRange else { return }
        let text = find.replacementText(in: textView.string, range: r)
        if textView.shouldChangeText(in: r, replacementString: text) {
            textView.replaceCharacters(in: r, with: text)
            textView.didChangeText()
        }
        find.update(text: textView.string, from: r.location + (text as NSString).length)
        showFindState(select: true)
    }

    public func replaceAll() {
        find.replacement = findBar.replaceField.stringValue
        let (newText, count) = find.replacingAll(in: textView.string)
        guard count > 0 else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: all, replacementString: newText) {
            textView.replaceCharacters(in: all, with: newText)
            textView.didChangeText()
        }
        find.update(text: textView.string)
        showFindState(select: false)
        findBar.countLabel.stringValue = "Replaced \(count)"
    }

    // MARK: Settings

    /// Applies the current settings and theme (called on every change).
    public func applyPreferences() {
        _ = view
        let p = Preferences.shared
        showsLineNumbers = p.showLineNumbers
        gutter.showsRibbon = p.showFoldingRibbon
        showsMinimap = p.showMinimap
        textView.pageGuideColumn = p.showPageGuide ? p.pageGuideColumn : nil
        textView.backgroundColor = Theme.backgroundColor
        textView.insertionPointColor = Theme.textColor
        textView.selectedTextAttributes = [.backgroundColor: Theme.selectionColor]
        textView.typingAttributes = [.font: Theme.font, .foregroundColor: Theme.textColor]
        let tab = ("0" as NSString).size(withAttributes: [.font: Theme.font]).width * CGFloat(p.tabWidth)
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = tab
        para.tabStops = []
        // Wrapped lines are indented (Editing ▸ Display ▸ Indent wrapped lines).
        if p.wrapLines {
            para.headIndent = ("0" as NSString).size(withAttributes: [.font: Theme.font]).width * CGFloat(p.wrappedLineIndent)
        }
        if let ts = textView.textStorage, ts.length > 0 {
            ts.addAttribute(.paragraphStyle, value: para.copy(), range: NSRange(location: 0, length: ts.length))
        }
        textView.defaultParagraphStyle = para
        // Wrapping: the container follows the view width, or grows freely.
        textView.isHorizontallyResizable = !p.wrapLines
        textView.textContainer?.widthTracksTextView = p.wrapLines
        if !p.wrapLines {
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        } else {
            scrollView.hasHorizontalScroller = false
            textView.frame.size.width = scrollView.contentSize.width
        }
        multilineTokens = Theme.highlightReturningMultiline(textView.textStorage!, language: language)
        textView.textStorage?.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: textView.textStorage!.length))
        applyDisplayPreferences()
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    /// Removes spaces and tabs at line ends (not on the caret's line while
    /// typing there would lose them: the whole text is trimmed on save).
    public func trimTrailingWhitespace() {
        let ns = textView.string as NSString
        guard let re = try? NSRegularExpression(pattern: "[ \\t]+$", options: .anchorsMatchLines) else { return }
        // Whitespace-only lines are trimmed only with Settings ▸ Editing ▸
        // "Trim whitespace-only lines" (default off).
        let trimBlank = Preferences.shared.trimWhitespaceOnlyLines
        let matches = re.matches(in: textView.string, range: NSRange(location: 0, length: ns.length)).filter { m in
            trimBlank || ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location != m.range.location
        }
        guard !matches.isEmpty else { return }
        textView.undoManager?.beginUndoGrouping()
        for m in matches.reversed() where textView.shouldChangeText(in: m.range, replacementString: "") {
            textView.replaceCharacters(in: m.range, with: "")
            textView.didChangeText()
        }
        textView.undoManager?.endUndoGrouping()
    }

    /// The page-guide column shown, if any (tests).
    public var pageGuideColumn: Int? { textView.pageGuideColumn }
    public var wrapsLines: Bool { textView.textContainer?.widthTracksTextView ?? true }

    // MARK: Refactoring support

    /// Applies LSP text edits to the open text as one undoable change
    /// (last edit first, so earlier positions stay valid).
    public func applyTextEdits(_ edits: [TextEdit]) {
        _ = view
        let index = textView.lineIndex
        let sorted = edits.sorted { ($0.start.line, $0.start.character) > ($1.start.line, $1.start.character) }
        textView.undoManager?.beginUndoGrouping()
        for e in sorted {
            let a = index.offset(of: e.start), b = index.offset(of: e.end)
            let r = NSRange(location: a, length: max(0, b - a))
            if textView.shouldChangeText(in: r, replacementString: e.newText) {
                textView.replaceCharacters(in: r, with: e.newText)
                textView.didChangeText()
            }
        }
        textView.undoManager?.endUndoGrouping()
        textView.undoManager?.setActionName("Refactor")
    }

    /// Highlights whole-word occurrences of `name` (nil clears), as the
    /// rename field's live feedback.
    public func highlightOccurrences(of name: String?) {
        _ = view
        guard let name, !name.isEmpty else { textView.findMatches = []; textView.currentFindMatch = nil; return }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        let re = try? NSRegularExpression(pattern: pattern)
        textView.findMatches = re?.matches(in: textView.string, range: NSRange(location: 0, length: (textView.string as NSString).length)).map(\.range) ?? []
        textView.currentFindMatch = nil
    }

    /// The occurrences highlighted for a rename.
    public var highlightedOccurrences: [NSRange] { textView.findMatches }

    /// The rename field: a small text field over the symbol; Return
    /// commits, Escape cancels.
    func showRenameField(name: String, at range: NSRange, onCommit: @escaping (String) -> Void) {
        let rect = textView.segmentRects(range).first ?? .zero
        let field = RenameField(string: name)
        field.frame = NSRect(x: rect.minX - 2, y: rect.minY - 2, width: max(120, rect.width + 40), height: rect.height + 4)
        field.font = Theme.font
        field.onCommit = { [weak field, weak self] text in
            field?.removeFromSuperview()
            self?.view.window?.makeFirstResponder(self?.textView)
            if let text { onCommit(text) } else { self?.highlightOccurrences(of: nil) }
        }
        field.onChange = { [weak self] text in self?.highlightOccurrences(of: name); _ = text }
        textView.addSubview(field)
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: Content

    /// Inserts text at the selection (a Library item), as one undoable
    /// edit, then selects its first `<#placeholder#>` if it has one.
    /// Returns false when no editable file is shown.
    @discardableResult
    public func insertLibraryText(_ text: String) -> Bool {
        _ = view
        guard fileURL != nil, textView.isEditable else { return false }
        let at = textView.selectedRange()
        textView.insertText(text, replacementRange: at)
        selectFirstPlaceholder(inInserted: NSRange(location: at.location, length: (text as NSString).length))
        return true
    }

    public func open(_ url: URL) throws {
        _ = view
        hideComparison()
        hideInlineComparison()
        hideAuxiliary()
        hideEmptyState()
        let text = try String(contentsOf: url, encoding: .utf8)
        let old = fileURL
        fileURL = url
        if let old, old != url { onDocumentClosed?(old) }
        textView.isEditable = true
        syntaxOverride = nil
        language = .init(fileName: url.lastPathComponent)
        symbolCache.symbols = nil
        clearMultipleSelection()
        showsNoDocument = false
        textView.string = text
        isDirty = false
        reindex()
        multilineTokens = Theme.highlightReturningMultiline(textView.textStorage!, language: language)
        updateDisplayExtras()
        refreshSourceChanges()
        onDocumentOpened?(url, text)
        // A newly opened file starts at line 1, column 1 (reference-ui-6.md
        // §4.2.2); an open that names a line moves the caret afterwards.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
    }

    /// Shows read-only text that is not a file (a build log).
    /// Stops showing the file: an empty editor, "No Selection".
    public func closeFile() {
        _ = view
        let old = fileURL
        showText("", title: "")
        pathComponents = []
        jumpBar.symbolTitle = nil
        textView.caretLine = nil
        gutter.caretLine = nil
        showsNoDocument = true
        if let old { onDocumentClosed?(old) }
        onBecameEmpty?()
    }

    public func showText(_ text: String, title: String) {
        _ = view
        try? save()
        fileURL = nil
        language = .plain
        syntaxOverride = nil
        symbolCache.symbols = nil
        clearMultipleSelection()
        showsNoDocument = false
        textView.string = text
        textView.isEditable = false
        refreshSourceChanges()
        isDirty = false
        reindex()
        Theme.highlight(textView.textStorage!, language: .plain)
        pathComponents = [(title, "doc.plaintext")]
        setIssues([])
        setBreakpoints([:], active: true)
        setCurrentLine(nil)
    }

    public func save() throws {
        guard let url = fileURL, isDirty else { return }
        if Preferences.shared.convertExistingFilesOnSave { convertLineEndings() }
        if Preferences.shared.trimTrailingWhitespace { trimTrailingWhitespace() }
        try textView.string.write(to: url, atomically: true, encoding: .utf8)
        isDirty = false
        refreshSourceChanges()
        onSave?(url)
    }

    /// Called after the file is written (the preview canvas refreshes).
    public var onSave: ((URL) -> Void)?

    public var text: String { textView.string }

    // MARK: Incremental editing

    /// Re-color only the edited lines (and recompute folds/minimap lazily
    /// on large files) instead of the whole file per keystroke.
    public static var incrementalEditing = true
    /// Files with more lines than this get folds and the minimap updated
    /// after a short pause instead of on every keystroke.
    public static var lazyThreshold = 3_000
    private var pendingEdit: (range: NSRange, newLength: Int, oldText: String)?
    private var multilineTokens: [NSRange] = []
    private var deferredIndex: DispatchWorkItem?
    /// How the last change was colored (tests): true = only the edited lines.
    public private(set) var lastHighlightWasIncremental = false

    func noteEdit(range: NSRange, replacement: String) {
        if !textView.issues.isEmpty { textView.issuesStale = true; gutter.marks.issuesStale = true }
        let ns = textView.string as NSString
        let old = NSMaxRange(range) <= ns.length ? ns.substring(with: range) : ""
        // Several edits before one change notification: fall back to a full pass.
        pendingEdit = pendingEdit == nil ? (range, (replacement as NSString).length, old) : (NSRange(location: 0, length: 0), -1, "")
    }

    /// Re-colors after an edit: the edited lines only when no multi-line
    /// token can be affected, else the whole text.
    func rehighlight() {
        let storage = textView.textStorage!
        defer { pendingEdit = nil }
        guard Self.incrementalEditing, let e = pendingEdit, e.newLength >= 0 else {
            multilineTokens = Theme.highlightReturningMultiline(storage, language: language)
            lastHighlightWasIncremental = false
            return
        }
        let ns = textView.string as NSString
        let delta = e.newLength - e.range.length
        let changed = NSRange(location: e.range.location, length: e.newLength)
        let region = ns.lineRange(for: NSRange(location: min(changed.location, ns.length), length: min(changed.length, ns.length - min(changed.location, ns.length))))
        let inserted = ns.substring(with: NSRange(location: changed.location, length: min(changed.length, ns.length - changed.location)))
        let markers = ["/*", "*/", "\"\"\"", "#\""]
        let touchesMarkers = markers.contains { inserted.contains($0) || e.oldText.contains($0) || ns.substring(with: region).contains($0) }
        // Shift multi-line token ranges after the edit; any token touching
        // the edited lines forces a full pass.
        let oldRegionEnd = NSMaxRange(region) - delta
        let hits = multilineTokens.contains { t in t.location <= oldRegionEnd && NSMaxRange(t) >= region.location }
        if touchesMarkers || hits || region.length == 0 {
            multilineTokens = Theme.highlightReturningMultiline(storage, language: language)
            lastHighlightWasIncremental = false
            return
        }
        multilineTokens = multilineTokens.map { $0.location >= e.range.location ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
        Theme.highlight(storage, language: language, region: region)
        lastHighlightWasIncremental = true
    }

    public func textDidChange(_ notification: Notification) {
        symbolCache.symbols = nil
        isDirty = true
        reindex()
        rehighlight()
        updateDisplayExtras()
        refreshInlineComparison()
        scheduleSourceChangesRefresh()
        if let url = fileURL { onDocumentChanged?(url, textView.string) }
        let caret = textView.selectedRange().location
        let ns = textView.string as NSString
        if isShowingCompletions {
            let start = completionPopup.model.wordStart
            if caret < start { hideCompletions() } else {
                var m = completionPopup.model
                m.filter(ns.substring(with: NSRange(location: start, length: caret - start)))
                showCompletions(m)
            }
        } else if caret > 0, ns.character(at: caret - 1) == 46 /* . */, language == .swift {
            requestCompletion()
        }
    }

    // MARK: Completion

    /// The LSP position of the insertion point.
    public var caretPosition: Position { textView.lineIndex.position(at: textView.selectedRange().location) }

    /// Asks the provider for completions at the insertion point and shows them.
    public func requestCompletion() {
        guard let url = fileURL, let provider = completionProvider else { return }
        let caret = textView.selectedRange().location
        let ns = textView.string as NSString
        let start = CompletionModel.wordStart(in: ns, before: caret)
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        let pos = textView.lineIndex.position(at: caret)
        Task {
            let items = await provider(url, pos)
            guard self.textView.selectedRange().location == caret, !items.isEmpty else { return }
            var m = CompletionModel()
            m.reset(items: items, wordStart: start, prefix: prefix)
            self.showCompletions(m)
        }
    }

    public func showCompletions(_ m: CompletionModel) {
        completionPopup.model = m
        guard !m.visible.isEmpty else { return hideCompletions() }
        // Below the start of the word; the label column lines up with it.
        let anchor = textView.caretRect(at: m.wordStart) ?? NSRect(x: 40, y: 20, width: 0, height: 16)
        let labelInset: CGFloat = 8 + ("M  " as NSString).size(withAttributes: [.font: Theme.boldFont]).width
        let height = CompletionPopupView.height(rows: m.visible.count, hasDoc: completionPopup.hasDoc)
        let inText = NSRect(x: max(0, anchor.minX - labelInset), y: anchor.maxY + 2, width: 380, height: height)
        // Hosted above the scroll view (not inside the text view) so it is
        // never clipped by, or drawn into, the text layout.
        completionPopup.frame = view.convert(inText, from: textView)
        if completionPopup.superview == nil { view.addSubview(completionPopup, positioned: .above, relativeTo: nil) }
    }

    public func hideCompletions() { completionPopup.removeFromSuperview() }

    /// The popup's frame in text-view coordinates.
    public var completionFrameInText: NSRect { textView.convert(completionPopup.frame, from: view) }

    /// Replaces the partial word with the selected completion.
    public func acceptCompletion() {
        guard let item = completionPopup.model.current else { return hideCompletions() }
        let caret = textView.selectedRange().location
        var start = completionPopup.model.wordStart
        if let r = item.replaceStart { start = min(caret, textView.lineIndex.offset(of: r)) }
        let range = NSRange(location: start, length: caret - start)
        hideCompletions()
        let text = item.isSnippet ? Placeholders.fromLSPSnippet(item.insertText) : item.insertText
        if textView.shouldChangeText(in: range, replacementString: text) {
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: start + (text as NSString).length, length: 0))
            selectFirstPlaceholder(inInserted: NSRange(location: start, length: (text as NSString).length))
        }
    }

    // MARK: Placeholders

    /// Tab / Shift-Tab select the next / previous placeholder; Return on a
    /// selected placeholder replaces it with its text.
    func handlePlaceholderKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.shift, .command, .option, .control])
        switch e.keyCode {
        case 48 where flags.isEmpty || flags == .shift: return selectPlaceholder(backward: flags == .shift)
        case 36, 76 where flags.isEmpty: return acceptSelectedPlaceholder()
        default: return false
        }
    }

    /// Selects the next (or previous) placeholder; false when there is none.
    @discardableResult
    public func selectPlaceholder(backward: Bool = false) -> Bool {
        guard let r = Placeholders.next(from: textView.selectedRange(), in: textView.string, backward: backward) else { return false }
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        return true
    }

    /// Replaces the selected placeholder with its own text.
    @discardableResult
    public func acceptSelectedPlaceholder() -> Bool {
        let sel = textView.selectedRange()
        guard Placeholders.ranges(in: textView.string).contains(sel) else { return false }
        let text = Placeholders.text(of: sel, in: textView.string)
        guard textView.shouldChangeText(in: sel, replacementString: text) else { return false }
        textView.replaceCharacters(in: sel, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: sel.location + (text as NSString).length, length: 0))
        return true
    }

    /// After inserting `length` characters at `location`, selects the first
    /// placeholder among them.
    func selectFirstPlaceholder(inInserted inserted: NSRange) {
        if let p = Placeholders.ranges(in: textView.string).first(where: { NSIntersectionRange($0, inserted).length == $0.length }) {
            textView.setSelectedRange(p)
        }
    }

    /// Up, Down, Return, Tab and Escape drive the popup while it shows.
    func handleCompletionKey(_ e: NSEvent) -> Bool {
        guard isShowingCompletions else { return false }
        switch e.keyCode {
        case 125, 126:
            var m = completionPopup.model
            m.move(e.keyCode == 125 ? 1 : -1)
            showCompletions(m) // the documentation line may appear or go
        case 36, 76, 48: acceptCompletion()
        case 53: hideCompletions()
        default: return false
        }
        return true
    }

    public func quickHelp(atOffset offset: Int) {
        guard let url = fileURL else { return }
        let rect = textView.segmentRects(NSRange(location: offset, length: 0)).first ?? .zero
        onQuickHelp?(url, textView.lineIndex.position(at: offset), rect)
    }

    public func jumpToDefinition(atOffset offset: Int) {
        guard let url = fileURL else { return }
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        onJumpToDefinition?(url, textView.lineIndex.position(at: offset))
    }

    /// The jump bar's symbol component (tests).
    public var jumpBarSymbol: String? { jumpBar.symbolTitle }

    /// The document's declarations, for View ▸ Editor ▸ Show Document Items (⌃6).
    var documentSymbols: [SymbolScanner.Symbol] {
        guard fileURL != nil, language != .plain else { return [] }
        if symbolCache.symbols == nil { symbolCache.symbols = SymbolScanner.symbols(in: textView.string, language: language) }
        return symbolCache.symbols ?? []
    }

    /// The innermost declaration at or before the caret's line.
    func updateSymbolComponent() {
        guard fileURL != nil, language != .plain else { jumpBar.symbolTitle = nil; return }
        if symbolCache.symbols == nil { symbolCache.symbols = SymbolScanner.symbols(in: textView.string, language: language) }
        let line = currentLine
        var best: SymbolScanner.Symbol?
        var level = symbolCache.symbols ?? []
        while let s = level.last(where: { $0.line <= line }), line <= endLine(of: s) {
            best = s
            level = s.children
        }
        jumpBar.symbolTitle = best?.name ?? "No Selection"
    }

    /// The line of a declaration's closing brace (its own line when it has
    /// no body). Braces in strings and comments are not skipped
    /// (an approximation for the jump bar).
    func endLine(of s: SymbolScanner.Symbol) -> Int {
        guard let start = textView.lineIndex.range(ofLine: s.line) else { return s.line }
        let ns = textView.string as NSString
        var depth = 0, opened = false, i = start.location
        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}")), nl = UInt16(UInt8(ascii: "\n"))
        while i < ns.length {
            let c = ns.character(at: i)
            if c == open { depth += 1; opened = true }
            else if c == close { depth -= 1; if opened && depth == 0 { return textView.lineIndex.line(at: i) } }
            else if c == nl && !opened && i > start.location + start.length { return s.line }
            i += 1
        }
        return opened ? textView.lineIndex.line(at: max(0, ns.length - 1)) : s.line
    }

    /// The identifier at the caret (nil inside whitespace or punctuation).
    public var identifierAtCaret: String? {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, ns.length > 0 else { return nil }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ i: Int) -> Bool { i >= 0 && i < ns.length && UnicodeScalar(ns.character(at: i)).map(word.contains) == true }
        var a = sel.location, b = sel.location
        while isWord(a - 1) { a -= 1 }
        while isWord(b) { b += 1 }
        guard b > a else { return nil }
        let w = ns.substring(with: NSRange(location: a, length: b - a))
        return w.first?.isNumber == true ? nil : w
    }

    /// The identifier whose instances are highlighted (tests).
    public var highlightedSymbol: String? { symbolCache.highlighted }

    /// Editing ▸ Display ▸ Highlight instances of selected symbol, after
    /// the highlighting delay; skipped while the find bar shows matches.
    func scheduleSymbolHighlight() {
        symbolCache.highlightTimer?.invalidate()
        let p = Preferences.shared
        guard p.highlightSelectedSymbol, !isShowingFindBar else { return }
        if symbolCache.highlighted != nil { symbolCache.highlighted = nil; highlightOccurrences(of: nil) }
        guard let name = identifierAtCaret, language != .plain else { return }
        symbolCache.highlightTimer = Timer.scheduledTimer(withTimeInterval: p.highlightDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySymbolHighlight(name) }
        }
    }

    public func applySymbolHighlight(_ name: String) {
        guard identifierAtCaret == name else { return }
        symbolCache.highlighted = name
        highlightOccurrences(of: name)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        // Setting the text posts this before the line index is rebuilt; a
        // stale index turns the offset into the column (reference-ui-6.md
        // §4.2.1, E3).
        // (Typing keeps its incremental index: `pendingEdit` is set then.)
        if pendingEdit == nil, textView.lineIndex.length != (textView.string as NSString).length {
            let idx = LineIndex(textView.string)
            textView.lineIndex = idx
            gutter.lineIndex = idx
        }
        let caret = fileURL == nil && textView.string.isEmpty ? nil : currentLine
        textView.caretLine = caret
        gutter.caretLine = caret
        updateSymbolComponent()
        scheduleSymbolHighlight()
        guard let url = fileURL else { return }
        onSelectionChange?(url, caretPosition)
    }

    /// Places the insertion point at an LSP position.
    public func reveal(position p: Position) {
        let offset = textView.lineIndex.offset(of: p)
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    // MARK: Code folding

    /// Hides folded lines: TextKit 2 skips paragraphs this returns false for.
    public nonisolated func textContentManager(_ textContentManager: NSTextContentManager,
                                               shouldEnumerate textElement: NSTextElement,
                                               options: NSTextContentManager.EnumerationOptions) -> Bool {
        let snap = foldSnapshot
        guard !snap.hidden.isEmpty, let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return !snap.hidden.contains(snap.index.line(at: offset))
    }

    /// What the (nonisolated) TextKit delegate reads: hidden lines and the
    /// line index they refer to. Written only on the main actor.
    nonisolated(unsafe) private var foldSnapshot = (hidden: Set<Int>(), index: LineIndex(""))

    /// Brace and comment regions together.
    public var allFoldRegions: [FoldRegion] { foldRegions + commentRegions }

    func applyFolds() {
        let all = allFoldRegions
        hiddenLines = Set(all.filter { foldedStarts.contains($0.startLine) }.flatMap { Array($0.hiddenLines) })
        foldSnapshot = (hiddenLines, textView.lineIndex)
        gutter.foldStarts = Dictionary(all.map { ($0.startLine, foldedStarts.contains($0.startLine)) }, uniquingKeysWith: { a, _ in a })
        textView.foldedStartLines = foldedStarts
        if let tlm = textView.textLayoutManager {
            tlm.invalidateLayout(for: tlm.documentRange)
            tlm.ensureLayout(for: tlm.documentRange)
        }
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    /// The ribbon click: folds or unfolds the region starting at (else
    /// containing) `line`.
    public func toggleFold(at line: Int) {
        guard let r = allFoldRegions.first(where: { $0.startLine == line }) ?? FoldRegions.innermost(foldRegions, containing: line) else { return }
        if foldedStarts.contains(r.startLine) { foldedStarts.remove(r.startLine) } else { foldedStarts.insert(r.startLine) }
        applyFolds()
    }

    /// ⌥⌘←: folds the innermost open region (or comment block) around the insertion point.
    @objc public func fold(_ sender: Any?) {
        let line = currentLine
        // A comment block around the caret first, else the innermost brace region.
        let comment = commentRegions.first { $0.contains(line: line) && !foldedStarts.contains($0.startLine) }
        guard let r = comment ?? foldRegions.filter({ $0.contains(line: line) && !foldedStarts.contains($0.startLine) }).max(by: { $0.depth < $1.depth }) else { return }
        foldedStarts.insert(r.startLine)
        applyFolds()
    }

    /// ⌥⌘→: unfolds the folds that start on, or contain, the insertion line.
    @objc public func unfold(_ sender: Any?) {
        let line = currentLine
        foldedStarts = foldedStarts.filter { s in !(allFoldRegions.first { $0.startLine == s }?.contains(line: line) ?? false) }
        applyFolds()
    }

    /// ⌥⇧⌘←: folds every region.
    @objc public func foldAll(_ sender: Any?) {
        foldedStarts = Set(foldRegions.map(\.startLine))
        applyFolds()
    }

    /// ⌥⇧⌘→: unfolds everything.
    @objc public func unfoldAll(_ sender: Any?) {
        foldedStarts = []
        applyFolds()
    }

    private func reindex() {
        let idx: LineIndex
        let newLength = (textView.string as NSString).length
        if Self.incrementalEditing, let e = pendingEdit, e.newLength >= 0, textView.lineIndex.length + e.newLength - e.range.length == newLength {
            var i = textView.lineIndex
            let ns = textView.string as NSString
            i.applyEdit(range: e.range, replacement: ns.substring(with: NSRange(location: e.range.location, length: e.newLength)))
            idx = i
        } else {
            idx = LineIndex(textView.string)
        }
        textView.lineIndex = idx
        gutter.lineIndex = idx
        // Large files: folds and the minimap catch up after a short pause.
        if Self.incrementalEditing && idx.starts.count > Self.lazyThreshold && pendingEdit != nil {
            deferredIndex?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reindexDeferred() }
            deferredIndex = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }
        reindexDeferred()
    }

    /// Folds and minimap (the expensive part of re-indexing).
    func reindexDeferred() {
        deferredIndex = nil
        // The minimap is computed only while it is shown.
        minimap.lines = showsMinimapCache ? textView.string.components(separatedBy: "\n").map { $0.utf16.count } : []
        // Keep folds whose regions still exist (matched by start line).
        foldRegions = FoldRegions.regions(in: textView.string, language: language)
        commentRegions = FoldRegions.commentRegions(in: textView.string, language: language)
        foldedStarts = foldedStarts.filter { s in allFoldRegions.contains { $0.startLine == s } }
        minimap.landmarks = showsMinimapCache ? minimapLandmarks() : []
        applyFolds()
    }

    // MARK: Marks

    public func setBreakpoints(_ lines: [Int: Bool], active: Bool, customized: Set<Int> = []) {
        gutter.marks.breakpoints = lines
        gutter.marks.customized = customized
        gutter.marks.breakpointsActive = active
    }

    /// The annotations are grey: the file was edited after they were set.
    public var issuesAreStale: Bool { textView.issuesStale }
    /// Editor ▸ Show Issues / Hide All Issues.
    public var showsInlineIssues: Bool {
        get { textView.showsIssues }
        set { textView.showsIssues = newValue }
    }

    public func setIssues(_ issues: [Diagnostic]) {
        let path = fileURL?.standardizedFileURL.path
        let mine = issues.filter { $0.location.map { URL(fileURLWithPath: $0.file).standardizedFileURL.path } == path }
        let grouped = Dictionary(grouping: mine, by: { $0.location!.line })
        // The same issues again (a breakpoint refresh) keep their stale state;
        // new ones from a build or the language server replace it.
        if grouped != textView.issues {
            textView.issues = grouped
            textView.issuesStale = false
            gutter.marks.issuesStale = false
        }
        gutter.marks.issues = textView.issues.mapValues { list in list.contains { $0.severity == .error } ? .error : .warning }
        gutter.marks.fixable = Set(textView.issues.filter { $0.value.contains { !$0.fixIts.isEmpty } }.keys)
    }

    /// The line whose issue annotation is at `p` (text-view coordinates):
    /// right of the line's code, where the annotation is drawn.
    public func annotationLine(at p: NSPoint) -> Int? {
        guard textView.showsIssues else { return nil }
        let line = textView.lineIndex.line(at: textView.characterIndexForInsertion(at: p))
        guard textView.issues[line]?.isEmpty == false, let r = textView.lineRect(line), r.contains(p),
              let lr = textView.lineIndex.range(ofLine: line) else { return nil }
        let end = NSMaxRange(lr)
        let textEnd = textView.segmentRects(NSRange(location: max(lr.location, end - 1), length: end > lr.location ? 1 : 0)).first?.maxX ?? r.minX
        return p.x >= textEnd + 16 ? line : nil
    }

    /// The menu a click on a line's annotation opens when its issues carry
    /// fix-its: the message, then "Fix" (applies them); nil otherwise.
    public func fixItMenu(line: Int) -> NSMenu? {
        guard let list = textView.issues[line], list.contains(where: { !$0.fixIts.isEmpty }),
              let first = InlineIssueLayout.primary(list.filter { !$0.fixIts.isEmpty }) else { return nil }
        let m = NSMenu()
        m.autoenablesItems = false
        let title = NSMenuItem(title: first.message, action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        let fix = NSMenuItem(title: "Fix", action: #selector(fixItChosen(_:)), keyEquivalent: "")
        fix.target = self
        fix.tag = line
        m.addItem(fix)
        return m
    }

    @objc func fixItChosen(_ item: NSMenuItem) { gutter.onFixIt?(item.tag) }

    /// Test diamonds for the open file.
    public func setTests(_ marks: [Int: GutterView.TestStatusMark]) { gutter.marks.tests = marks }

    /// "Thread 1: breakpoint 1.1 (1)" at the right of the current line.
    public func setStopAnnotation(_ text: String?) { textView.stopAnnotation = text }
    public var stopAnnotationText: String? { textView.stopAnnotation }

    /// Marks the program counter's line. The editor scrolls to a new line;
    /// the caret stays (Debug ▸ Debug Workflow ▸ Synchronize Insertion
    /// Point to Program Counter moves it, reference-ui-5.md §2.10).
    public func setCurrentLine(_ line: Int?) {
        let changed = textView.highlightedLine != line
        textView.highlightedLine = line
        gutter.marks.currentLine = line
        if let line, changed, let r = textView.lineIndex.range(ofLine: line) { textView.scrollRangeToVisible(r) }
    }

    /// The 1-based line of the insertion point.
    public var currentLine: Int { textView.lineIndex.line(at: textView.selectedRange().location) }

    public func reveal(line: Int) {
        guard let r = textView.lineIndex.range(ofLine: line) else { return }
        textView.setSelectedRange(NSRange(location: r.location, length: 0))
        textView.scrollRangeToVisible(r)
    }

    // MARK: Editor options

    public var showsMinimap: Bool {
        get { minimapWidth.constant > 0 }
        set {
            _ = view
            minimapWidth.constant = newValue ? MinimapView.width(forEditorWidth: view.bounds.width) : 0  // reference-ui-5.md §6.5
            if newValue != showsMinimapCache {
                showsMinimapCache = newValue
                if newValue { minimap.lines = textView.string.components(separatedBy: "\n").map { $0.utf16.count }; minimap.landmarks = minimapLandmarks() }
            }
        }
    }

    public var showsLineNumbers: Bool {
        get { gutter.showsLineNumbers }
        set { gutter.showsLineNumbers = newValue }
    }

    /// Editor ▸ Minimap (⌃⇧⌘M): a user setting for every editor (reference-ui-5.md §9.3).
    @objc public func toggleMinimap(_ sender: Any?) { Preferences.shared.showMinimap.toggle() }
    @objc public func toggleLineNumbers(_ sender: Any?) { showsLineNumbers.toggle() }

    /// ⌘/: adds or removes `// ` at the start of each selected line.
    @objc public func commentSelection(_ sender: Any?) {
        let ns = textView.string as NSString
        let lines = ns.lineRange(for: textView.selectedRange())
        let block = ns.substring(with: lines)
        let parts = block.components(separatedBy: "\n")
        let body = parts.last?.isEmpty == true ? Array(parts.dropLast()) : parts
        let allCommented = body.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") || $0.isEmpty }
        let changed = body.map { line -> String in
            if allCommented, let r = line.range(of: "// ") ?? line.range(of: "//") { return line.replacingCharacters(in: r, with: "") }
            return allCommented ? line : "// " + line
        }.joined(separator: "\n") + (parts.last?.isEmpty == true ? "\n" : "")
        if textView.shouldChangeText(in: lines, replacementString: changed) {
            textView.replaceCharacters(in: lines, with: changed)
            textView.didChangeText()
            // Keep the same lines selected so ⌘/ toggles back.
            textView.setSelectedRange(NSRange(location: lines.location, length: max(0, changed.utf16.count - 1)))
        }
    }
}

/// The in-editor rename field.
final class RenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String?) -> Void)?
    var onChange: ((String) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); delegate = self }
    convenience init(string: String) { self.init(frame: .zero); stringValue = string }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ obj: Notification) { onChange?(stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { onCommit?(stringValue); onCommit = nil; return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { onCommit?(nil); onCommit = nil; return true }
        return false
    }
}

extension SourceEditorController {
    /// The source editor's context menu starts with Show Code Actions
    /// (reference-ui-5.md §2.0: the command keeps no shortcut and moves
    /// here; Editor ▸ Show Coding Tools ▸ Show Coding Tools… ⌥⌘0 also
    /// shows the actions at the caret).
    public func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard fileURL != nil, !menu.items.contains(where: { $0.action == Self.showCodeActionsAction }) else { return menu }
        menu.insertItem(NSMenuItem(title: "Show Code Actions", action: Self.showCodeActionsAction, keyEquivalent: ""), at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    static let showCodeActionsAction = NSSelectorFromString("showCodeActions:")
}

/// Whether the editor shows no document (an extension-friendly box).
@MainActor final class NoDocumentFlag { var value = false }
