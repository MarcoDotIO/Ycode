import AppKit
import YcodeIDECore
import YcodeSyntax

/// The merge sheet's two panes and the gutter between them, in one
/// scrolling view so corresponding lines share a y (`merge-sheet.md`
/// §4–§6): line numbers ending at +27, code from +41 in the editor's font
/// and syntax colours, full-width shading per row (through the gutter),
/// changed-word fills, the selected change's red rules, and one capsule
/// token per change in the 46-point gutter. x 0 is the left pane's edge.
@MainActor
public final class MergeCanvasView: NSView {
    weak var controller: MergeSheetController?
    /// The rows and where each starts (y, from the top).
    public private(set) var rows: [MergeSheetRow] = []
    public private(set) var rowTops: [CGFloat] = []
    /// Each pane's lines in the editor's theme (`Theme.apply`: the same
    /// colours, fonts and declaration colours as the source editor).
    var leftLines: [NSAttributedString] = []
    var rightLines: [NSAttributedString] = []
    /// The pane widths (the right one without the ruler).
    var leftWidth: CGFloat = 523
    var rightWidth: CGFloat = 523
    /// The current line of each pane (1-based): its number is darker and
    /// the line has the current-line highlight.
    public var currentLine = (left: 1, right: 1)
    let handEditor = NSTextView()
    let handEditorScroll = NSScrollView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        handEditor.isRichText = false
        handEditor.font = Theme.font
        handEditor.isAutomaticQuoteSubstitutionEnabled = false
        handEditor.isAutomaticDashSubstitutionEnabled = false
        handEditor.isAutomaticTextReplacementEnabled = false
        handEditor.textContainerInset = NSSize(width: 2, height: 0)
        handEditor.autoresizingMask = [.width]
        handEditor.isVerticallyResizable = true
        handEditor.setAccessibilityLabel("Edited change")
        handEditorScroll.documentView = handEditor
        handEditorScroll.hasVerticalScroller = true
        handEditorScroll.borderType = .lineBorder
        handEditorScroll.isHidden = true
        addSubview(handEditorScroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Merge comparison")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    var palette: MergeSheetPalette { MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge) }

    typealias M = MergeSheetMetrics
    var gutterX: CGFloat { leftWidth + 1 }
    var rightX: CGFloat { leftWidth + 1 + CGFloat(M.gutterWidth) + 1 }
    var totalWidth: CGFloat { rightX + rightWidth }
    var columns: Int { M.columnsOfText(paneWidth: Double(leftWidth)) }

    /// Takes the controller's state: rows, highlighting, sizes.
    func reload(state: ConflictEditorState, fileName: String) {
        rows = state.sheetRows
        leftLines = Self.themed(state.leftLines, fileName: fileName)
        rightLines = Self.themed(state.rightLines, fileName: fileName)
        relayoutRows()
    }

    func relayoutRows() {
        var y = CGFloat(M.firstLineTop)
        rowTops = rows.map { r in
            defer { y += CGFloat(MergeSheetLayout.height(r, columns: columns)) }
            return y
        }
        let content = y + CGFloat(M.firstLineTop)
        let visible = enclosingScrollView?.contentView.bounds.height ?? 0
        setFrameSize(NSSize(width: totalWidth, height: max(content, visible)))
        layoutHandEditor()
        needsDisplay = true
    }

    /// A row's frame (all three columns).
    public func rowRect(_ i: Int) -> NSRect {
        guard rows.indices.contains(i) else { return .zero }
        return NSRect(x: 0, y: rowTops[i], width: totalWidth, height: CGFloat(MergeSheetLayout.height(rows[i], columns: columns)))
    }

    /// The rows of change `h`.
    func rows(ofHunk h: Int) -> Range<Int>? {
        guard let a = rows.firstIndex(where: { $0.hunk == h }), let b = rows.lastIndex(where: { $0.hunk == h }) else { return nil }
        return a..<(b + 1)
    }

    /// The token of change `h` (canvas coordinates).
    public func tokenRect(forHunk h: Int) -> NSRect? {
        guard let r = rows(ofHunk: h) else { return nil }
        let top = rowTops[r.lowerBound]
        return NSRect(x: gutterX + CGFloat(M.tokenLeft), y: top + (CGFloat(M.lineHeight) - CGFloat(M.tokenHeight)) / 2,
                      width: CGFloat(M.tokenWidth), height: CGFloat(M.tokenHeight))
    }

    // MARK: Accessibility (§13.2)

    /// One button per change's token: pressing it opens the Choose menu.
    private var tokenElements: [Int: DrawnControlElement] = [:]

    public override func accessibilityChildren() -> [Any]? {
        guard let state = controller?.state, let doc = state.document else { return [] }
        var out: [Any] = []
        for h in doc.hunks.indices {
            let e = tokenElements[h] ?? DrawnControlElement(
                in: self,
                label: { [unowned self] in
                    let t = controller?.state.token(forHunk: h)
                    let n = (controller?.state.document?.hunks.count).map { "Change \(h + 1) of \($0)" } ?? "Change \(h + 1)"
                    return n + (t?.isDecided == true ? ", choice \(t?.glyph ?? "")" : ", undecided") + ": Choose…"
                },
                rect: { [unowned self] in tokenRect(forHunk: h) ?? .zero },
                press: { [unowned self] in controller?.showChooseMenu(forHunk: h) })
            tokenElements[h] = e
            out.append(e)
        }
        if !handEditorScroll.isHidden { out.append(handEditorScroll) }
        return out
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let p = palette
        let state = controller?.state
        let selected = state?.currentHunk
        NSColor(mergeHex: p.pane).setFill()
        dirtyRect.fill()
        NSColor(mergeHex: p.gutter).setFill()
        NSRect(x: gutterX, y: dirtyRect.minY, width: CGFloat(M.gutterWidth), height: dirtyRect.height).fill()
        NSColor(mergeHex: p.gutterRule).setFill()
        NSRect(x: leftWidth, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        NSRect(x: rightX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        let cols = columns
        let lh = CGFloat(M.lineHeight)
        for (i, row) in rows.enumerated() {
            let r = rowRect(i)
            guard r.intersects(dirtyRect) else { continue }
            // Shading: full width, through the gutter (§6).
            if row.kind != .same {
                let fill = NSColor(mergeHex: row.kind == .conflict ? p.conflictRow : p.cleanRow)
                fill.setFill()
                NSRect(x: 0, y: r.minY, width: leftWidth, height: r.height).fill()
                NSRect(x: rightX, y: r.minY, width: rightWidth, height: r.height).fill()
                NSColor(mergeHex: row.kind == .conflict ? p.gutterConflict : p.gutterClean).setFill()
                NSRect(x: gutterX, y: r.minY, width: CGFloat(M.gutterWidth), height: r.height).fill()
            } else {
                // The current-line highlight on every visual line of the line.
                NSColor(mergeHex: p.currentLine).setFill()
                if let l = row.left, l.number == currentLine.left {
                    let h = CGFloat(MergeSheetLayout.wrap(l.text, columns: cols).count) * lh
                    NSBezierPath(roundedRect: NSRect(x: CGFloat(M.currentLineInset), y: r.minY, width: leftWidth - 2 * CGFloat(M.currentLineInset), height: h),
                                 xRadius: 4, yRadius: 4).fill()
                }
                if let rr = row.right, rr.number == currentLine.right {
                    let h = CGFloat(MergeSheetLayout.wrap(rr.text, columns: cols).count) * lh
                    NSBezierPath(roundedRect: NSRect(x: rightX + CGFloat(M.currentLineInset), y: r.minY,
                                                     width: rightWidth - 2 * CGFloat(M.currentLineInset), height: h), xRadius: 4, yRadius: 4).fill()
                }
            }
            if let l = row.left { drawSide(l, lines: leftLines, x: 0, top: r.minY, current: currentLine.left, cols: cols, p) }
            if let rr = row.right { drawSide(rr, lines: rightLines, x: rightX, top: r.minY, current: currentLine.right, cols: cols, p) }
        }
        // The selected change's rules, across both panes and the gutter.
        if let h = selected, let range = rows(ofHunk: h) {
            let decided = state?.token(forHunk: h)?.isDecided ?? false
            NSColor(mergeHex: decided ? p.decidedRule : p.selectedRule).setFill()
            let top = rowTops[range.lowerBound], bottom = rowRect(range.upperBound - 1).maxY
            NSRect(x: 0, y: top, width: totalWidth, height: 1).fill()
            NSRect(x: 0, y: bottom - 1, width: totalWidth, height: 1).fill()
        }
        // Tokens.
        if let state, let doc = state.document {
            for h in doc.hunks.indices {
                guard let t = state.token(forHunk: h), let rect = tokenRect(forHunk: h), rect.intersects(dirtyRect) else { continue }
                drawToken(t, in: rect, p)
            }
        }
    }

    func drawSide(_ side: MergeSheetRow.Side, lines: [NSAttributedString], x: CGFloat, top: CGFloat, current: Int,
                  cols: Int, _ p: MergeSheetPalette) {
        let lh = CGFloat(M.lineHeight), cw = CGFloat(M.cellWidth)
        let segs = MergeSheetLayout.wrap(side.text, columns: cols)
        // Changed words: 16 tall, whole cells, never the spaces (§6).
        if !side.words.isEmpty {
            NSColor(mergeHex: p.conflictWord).setFill()
            for (k, seg) in segs.enumerated() {
                for w in side.words {
                    let a = max(w.lowerBound, seg.cells.lowerBound), b = min(w.upperBound, seg.cells.upperBound)
                    guard a < b else { continue }
                    NSRect(x: x + CGFloat(M.codeX) + CGFloat(seg.column + a - seg.cells.lowerBound) * cw,
                           y: top + CGFloat(k) * lh + CGFloat(M.wordInset), width: CGFloat(b - a) * cw, height: lh - 2 * CGFloat(M.wordInset)).fill()
                }
            }
        }
        // The line number, right-aligned at +27, in the editor's colours.
        let numberColor = side.number == current ? Theme.textColor : Theme.lineNumberColor
        let n = NSAttributedString(string: String(side.number), attributes: [.font: Theme.gutterFont, .foregroundColor: numberColor])
        let ns = n.size()
        n.draw(at: NSPoint(x: x + CGFloat(M.lineNumberRight) - ns.width, y: top + ((lh - ns.height) / 2).rounded()))
        // The text in the editor's theme.
        let font = Theme.font
        let full = lines.indices.contains(side.number - 1) && lines[side.number - 1].string == side.text ? lines[side.number - 1]
            : NSAttributedString(string: side.text, attributes: [.font: font, .foregroundColor: Theme.textColor])
        let textHeight = ceil(font.ascender - font.descender)
        let total = (full.string as NSString).length
        let characters = Array(full.string)
        for (k, seg) in segs.enumerated() {
            // Cells are characters; convert to UTF-16 offsets.
            let start = String(characters[0..<min(seg.cells.lowerBound, characters.count)]).utf16.count
            let end = String(characters[0..<min(seg.cells.upperBound, characters.count)]).utf16.count
            guard start < end, end <= total else { continue }
            let piece = full.attributedSubstring(from: NSRange(location: start, length: end - start))
            piece.draw(at: NSPoint(x: x + CGFloat(M.codeX) + CGFloat(seg.column) * cw, y: top + CGFloat(k) * lh + ((lh - textHeight) / 2).rounded()))
        }
    }

    func drawToken(_ t: ConflictEditorState.Token, in rect: NSRect, _ p: MergeSheetPalette) {
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(mergeHex: t.isSelected ? p.selectedToken : p.token).setFill()
        capsule.fill()
        // The rim (§13.5): 1 point of red on the selected token, a 0.5-point
        // lighter hairline on the others (it reads as an outlined pill on
        // the dark gutter).
        let rimWidth = CGFloat(t.isSelected ? MergeSheetToken.selectedRimWidth : MergeSheetToken.rimWidth)
        NSColor(mergeHex: t.isSelected ? p.selectedTokenRim : p.tokenRim).setStroke()
        let ri = rect.insetBy(dx: rimWidth / 2, dy: rimWidth / 2)
        let rim = NSBezierPath(roundedRect: ri, xRadius: ri.height / 2, yRadius: ri.height / 2)
        rim.lineWidth = rimWidth
        rim.stroke()
        let ink = NSColor(mergeHex: p.tokenInk)
        // The glyph left of centre (ink about +14.5 to +28.5).
        let g = NSAttributedString(string: t.glyph, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: ink])
        let gs = g.size()
        g.draw(at: NSPoint(x: rect.minX + 21.5 - gs.width / 2, y: rect.midY - gs.height / 2))
        // The chevron, in a circle once a choice is in effect.
        let cx = rect.minX + 33.5, cy = rect.midY
        if t.isDecided {
            NSColor(mergeHex: t.isSelected ? p.selectedChevronCircle : p.chevronCircle).setFill()
            let d = CGFloat(M.chevronCircle)
            NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)).fill()
        }
        // A light, thin down-chevron, about 6 × 3.5 (§5, §13.5).
        let hw = CGFloat(MergeSheetToken.chevronHalfWidth), ch = CGFloat(MergeSheetToken.chevronHeight)
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: cx - hw, y: cy - ch / 2))
        chevron.line(to: NSPoint(x: cx, y: cy + ch / 2))
        chevron.line(to: NSPoint(x: cx + hw, y: cy - ch / 2))
        chevron.lineWidth = CGFloat(MergeSheetToken.chevronLineWidth)
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        ink.setStroke()
        chevron.stroke()
    }

    /// `lines` (tabs expanded) styled by the editor's theme, one attributed
    /// string per line.
    static func themed(_ lines: [String], fileName: String) -> [NSAttributedString] {
        let expanded = lines.map(MergeSheetLayout.expandTabs)
        let text = expanded.joined(separator: "\n")
        let language = SyntaxLanguage(fileName: fileName)
        let doc = expanded.count <= 20_000 && language != .plain ? SyntaxDocument(text: text, language: language) : nil
        let storage = NSTextStorage(string: text)
        Theme.apply(doc, to: storage)
        var out: [NSAttributedString] = []
        out.reserveCapacity(expanded.count)
        var at = 0
        for line in expanded {
            let n = line.utf16.count
            out.append(storage.attributedSubstring(from: NSRange(location: at, length: n)))
            at += n + 1
        }
        return out
    }

    // MARK: Hand editing (Ycode's choice: double-click a change's left lines)

    func layoutHandEditor() {
        guard let state = controller?.state, state.isEditing, let h = state.currentHunk, let r = rows(ofHunk: h) else {
            handEditorScroll.isHidden = true
            return
        }
        let top = rowTops[r.lowerBound], bottom = rowRect(r.upperBound - 1).maxY
        let height = max(bottom - top, CGFloat(M.lineHeight) * 3)
        handEditorScroll.frame = NSRect(x: CGFloat(M.codeX) - 4, y: top, width: leftWidth - CGFloat(M.codeX) - 4, height: height)
        handEditorScroll.isHidden = false
    }

    // MARK: Events

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let state = controller?.state, let doc = state.document {
            for h in doc.hunks.indices where tokenRect(forHunk: h)?.insetBy(dx: -2, dy: -2).contains(pt) == true {
                controller?.showChooseMenu(forHunk: h)
                return
            }
        }
        guard let i = rowTops.lastIndex(where: { $0 <= pt.y }), rows.indices.contains(i), rowRect(i).contains(pt) else { return }
        let row = rows[i]
        if pt.x < leftWidth, let l = row.left { currentLine.left = l.number }
        if pt.x >= rightX, let r = row.right { currentLine.right = r.number }
        if let h = row.hunk {
            controller?.selectHunk(h)
            if event.clickCount == 2, pt.x < leftWidth { controller?.beginEditing() }
        }
        needsDisplay = true
    }
}

/// The 17-point overview ruler at the right pane's end (§4.4): the whole
/// file on the pane's height, a 10-wide mark per change.
@MainActor
public final class MergeRulerView: NSView {
    public var marks: [(position: Double, isConflict: Bool)] = [] { didSet { needsDisplay = true } }
    var onClick: ((Double) -> Void)?

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        let p = MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge)
        NSColor(mergeHex: p.pane).setFill()
        bounds.fill()
        for m in marks {
            NSColor(mergeHex: m.isConflict ? p.rulerConflict : p.rulerClean).setFill()
            NSRect(x: CGFloat(MergeSheetMetrics.rulerMarkX), y: (CGFloat(m.position) * bounds.height).rounded(.down),
                   width: CGFloat(MergeSheetMetrics.rulerMarkWidth), height: 1).fill()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        onClick?(Double(max(0, min(1, y / max(1, bounds.height)))))
    }
}
