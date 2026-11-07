import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax

/// The merge sheet's two panes and the gutter between them in one scroll
/// view, so corresponding lines share a y (`merge-sheet.md` §4–§6), as the
/// AppKit `MergeCanvasView` draws them: line numbers ending at +27, code
/// from +41 in the editor's font and syntax colours (8.0 per cell, 18 per
/// line, wrapping as the editor wraps), the current-line highlight,
/// full-width shading per row through the gutter, changed-word fills, the
/// selected change's red rules, and one capsule token per change opening
/// the Choose menu (§7); the 17-point overview ruler at the right pane's
/// end. x 0 is the left pane's edge. Double-clicking a change's left lines
/// writes it by hand (Ycode's choice).
struct MergeComparisonView: View {
    var editor: ConflictEditorShellModel
    var palette: MergeSheetPalette
    var leftWidth: CGFloat
    var rightWidth: CGFloat
    var height: CGFloat
    @State private var currentLeft = 1
    @State private var currentRight = 1
    /// The last click on a row (a reference, so every click's handler sees
    /// the one before it).
    @State private var clicks = MergeClickTracker()
    /// The last layout, kept while the document is unchanged (a click on a
    /// row only moves the selection).
    @State private var layouts = MergeLayoutCache()
    /// The panes' scroll offset and content height (the ruler's knob).
    @State private var scrolled = MergeScrollState()

    typealias M = MergeSheetMetrics

    var body: some View {
        let state = editor.state
        let name = state.currentFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let layout = layouts.layout(state: state, fileName: name, leftWidth: leftWidth, rightWidth: rightWidth, palette: palette)
        let p = palette
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: CGFloat(M.firstLineTop))
                            ForEach(layout.rows.indices, id: \.self) { i in
                                rowView(i, layout)
                                    .id(i)
                            }
                            Color.clear.frame(height: CGFloat(M.firstLineTop))
                        }
                        if state.isEditing, let h = state.currentHunk, let range = layout.rows(ofHunk: h) {
                            let top = CGFloat(M.firstLineTop) + layout.tops[range.lowerBound]
                            let bottom = CGFloat(M.firstLineTop) + layout.tops[range.upperBound - 1] + layout.heights[range.upperBound - 1]
                            // As tall as the change, and a line more than its text.
                            let lines = CGFloat(editor.editedText.split(separator: "\n", omittingEmptySubsequences: false).count + 1)
                            handEditor(p)
                                .frame(width: leftWidth - CGFloat(M.codeX) - 4, height: max(bottom - top, lines * CGFloat(M.lineHeight) + 12))
                                .offset(x: CGFloat(M.codeX) - 4, y: top)
                        }
                    }
                    .frame(width: layout.totalWidth, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        // The gutter and its rules run the whole height.
                        HStack(spacing: 0) {
                            Color(mergeHex: p.pane).frame(width: leftWidth)
                            Rectangle().fill(Color(mergeHex: p.gutterRule)).frame(width: 1)
                            Color(mergeHex: p.gutter).frame(width: CGFloat(M.gutterWidth))
                            Rectangle().fill(Color(mergeHex: p.gutterRule)).frame(width: 1)
                            Color(mergeHex: p.pane).frame(width: rightWidth)
                        }
                        .frame(minHeight: height)
                    }
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: MergeScrollState.self, of: { MergeScrollState(top: $0.contentOffset.y, content: $0.contentSize.height) }) { _, s in
                    scrolled = s
                }
                .frame(width: layout.totalWidth, height: height)
                .shellTarget("merge panes")
                MergeRuler(marks: state.rulerMarks(rows: layout.rows), palette: p, scroll: scrolled, visibleHeight: height) { share in
                    let i = Int((share * Double(layout.rows.count)).rounded(.down))
                    if layout.rows.indices.contains(i) { proxy.scrollTo(i, anchor: .center) }
                }
                .frame(width: CGFloat(M.rulerWidth), height: height)
                .shellTarget("merge ruler")
            }
            .onChange(of: editor.revealCount) { _, _ in
                if let h = editor.state.currentHunk, let r = layout.rows(ofHunk: h) { proxy.scrollTo(r.lowerBound, anchor: .center) }
            }
            .onChange(of: state.currentFile) { _, _ in
                currentLeft = 1
                currentRight = 1
                if let h = editor.state.currentHunk, let r = layout.rows(ofHunk: h) { proxy.scrollTo(r.lowerBound, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    func rowView(_ i: Int, _ layout: MergePaneLayout) -> some View {
        let row = layout.rows[i]
        let state = editor.state
        let selected = row.hunk != nil && row.hunk == state.currentHunk
        let decided = selected && (row.hunk.flatMap { state.token(forHunk: $0)?.isDecided } ?? false)
        let input = MergeRowPainter(row: row, layout: layout, currentLeft: currentLeft, currentRight: currentRight,
                                    isSelected: selected, isDecided: decided)
        Canvas { ctx, _ in input.draw(&ctx) }
            .frame(width: layout.totalWidth, height: layout.heights[i])
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.left.map { "Line \($0.number): \($0.text)" } ?? row.right.map { "Line \($0.number): \($0.text)" } ?? "")
            .shellTarget("merge row \(i)")
            .contentShape(Rectangle())
            .onTapGesture(count: 1, coordinateSpace: .local) { pt in click(i, at: pt, layout) }
            // A double-click by the events' own times (a busy frame between
            // the two clicks' handlers must not split them).
            .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick(i, layout) })
            .overlay(alignment: .topLeading) {
                if row.isFirstOfHunk, let h = row.hunk, let t = state.token(forHunk: h) {
                    token(h, t)
                        .offset(x: layout.gutterX + CGFloat(M.tokenLeft), y: (CGFloat(M.lineHeight) - CGFloat(M.tokenHeight)) / 2)
                }
            }
    }

    /// A row's click: the current line of the side clicked, the row's change
    /// selected; a second click on a change's left lines within 0.4 s
    /// writes it by hand.
    func click(_ i: Int, at pt: CGPoint, _ layout: MergePaneLayout) {
        // A click in the panes or the gutter moves the focus there (§14.3).
        if !editor.panesFocused { editor.panesFocused = true }
        let row = layout.rows[i]
        // Only what changes is set: a frame drawn between a double-click's
        // two clicks must not be needed.
        if pt.x < leftWidth, let l = row.left, currentLeft != l.number { currentLeft = l.number }
        if pt.x >= layout.rightX, let r = row.right, currentRight != r.number { currentRight = r.number }
        let isDouble = clicks.isDouble(row: i, left: pt.x < leftWidth)
        guard let h = row.hunk else { return }
        if editor.state.currentHunk != h { editor.selectHunk(h) }
        if isDouble, pt.x < leftWidth, !editor.state.isEditing { editor.beginEditing() }
    }

    /// A double-click on a change's left lines writes it by hand (Ycode's
    /// choice).
    func doubleClick(_ i: Int, _ layout: MergePaneLayout) {
        guard clicks.lastWasLeft(row: i), let h = layout.rows[i].hunk, !editor.state.isEditing else { return }
        editor.selectHunk(h)
        editor.beginEditing()
    }

    /// A change's token: selects the change and opens the Choose menu
    /// (§7): Choose Left, Choose Right — Choose Left Then Right, Choose
    /// Right Then Left. The choice rewrites the left pane; the change stays
    /// selected.
    func token(_ h: Int, _ t: ConflictEditorState.Token) -> some View {
        Menu {
            ForEach(Array(MergeSheetText.chooseTitles.enumerated()), id: \.offset) { pair in
                Button(pair.element) { editor.choose(MergeSheetText.chooseChoices[pair.offset], forHunk: h) }
                    .onAppear { if pair.offset == 0, editor.state.currentHunk != h { editor.selectHunk(h) } }
                if pair.offset == MergeSheetText.chooseSeparatorAfter { Divider() }
            }
        } label: {
            MergeTokenView(token: t, palette: palette)
        }
        .menuStyle(.borderlessButton)
        #if !os(Linux)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .simultaneousGesture(TapGesture().onEnded {
            // The token's click moves the focus into the panes (§14.3).
            if !editor.panesFocused { editor.panesFocused = true }
            if editor.state.currentHunk != h { editor.selectHunk(h) }
        })
        .shellTarget("merge token \(h)")
    }

    func handEditor(_ p: MergeSheetPalette) -> some View {
        TextEditor(text: Binding(get: { editor.editedText }, set: { editor.editedText = $0 }))
            .font(ShellFonts.editor(MergeCodeFont.size))
            .scrollContentBackground(.hidden)
            .background(Color(mergeHex: p.pane))
            .overlay { Rectangle().stroke(Color(mergeHex: p.selectedRule), lineWidth: 1) }
            .shellTarget("merge hand editor")
    }
}

/// Tells a double-click from two clicks: the same row again within 0.4 s.
final class MergeClickTracker {
    private var last: (row: Int, time: Date, left: Bool)?

    func isDouble(row: Int, left: Bool) -> Bool {
        let now = Date()
        defer { last = (row, now, left) }
        guard let l = last, l.row == row else { return false }
        return now.timeIntervalSince(l.time) < 0.4
    }

    /// The last click was on row `row`'s left pane.
    func lastWasLeft(row: Int) -> Bool { last.map { $0.row == row && $0.left } ?? false }
}

/// Keeps the last `MergePaneLayout` (highlighting and wrapping a file
/// costs more than a frame) while the document, the widths and the
/// appearance are unchanged.
final class MergeLayoutCache {
    private var key: (doc: MergeDocument?, file: String, left: CGFloat, right: CGFloat, palette: MergeSheetPalette)?
    private var cached: MergePaneLayout?

    @MainActor
    func layout(state: ConflictEditorState, fileName: String, leftWidth: CGFloat, rightWidth: CGFloat, palette: MergeSheetPalette) -> MergePaneLayout {
        if let k = key, let c = cached, k.doc == state.document, k.file == fileName, k.left == leftWidth, k.right == rightWidth, k.palette == palette {
            return c
        }
        let l = MergePaneLayout(state: state, fileName: fileName, leftWidth: leftWidth, rightWidth: rightWidth, palette: palette,
                                theme: SourcePalette.forAppearance(dark: palette == .dark, theme: Preferences.shared.theme))
        key = (state.document, fileName, leftWidth, rightWidth, palette)
        cached = l
        return l
    }
}

/// The rows, their heights and tops, and both panes' syntax runs, for one
/// shown document.
struct MergePaneLayout {
    let rows: [MergeSheetRow]
    let heights: [CGFloat]
    let tops: [CGFloat]
    let leftRuns: [[(text: String, role: SyntaxTokenKind.Role?)]]
    let rightRuns: [[(text: String, role: SyntaxTokenKind.Role?)]]
    let leftWidth: CGFloat
    let rightWidth: CGFloat
    let columns: Int
    let palette: MergeSheetPalette
    let theme: SourcePalette

    typealias M = MergeSheetMetrics

    init(state: ConflictEditorState, fileName: String, leftWidth: CGFloat, rightWidth: CGFloat, palette: MergeSheetPalette, theme: SourcePalette) {
        rows = state.sheetRows
        leftRuns = MergeSheetLayout.highlight(state.leftLines, fileName: fileName)
        rightRuns = MergeSheetLayout.highlight(state.rightLines, fileName: fileName)
        self.leftWidth = leftWidth
        self.rightWidth = rightWidth
        self.palette = palette
        self.theme = theme
        let cols = M.columnsOfText(paneWidth: Double(leftWidth))
        columns = cols
        heights = rows.map { CGFloat(MergeSheetLayout.height($0, columns: cols)) }
        var y: CGFloat = 0
        tops = heights.map { h in
            defer { y += h }
            return y
        }
    }

    var gutterX: CGFloat { leftWidth + 1 }
    var rightX: CGFloat { leftWidth + 1 + CGFloat(M.gutterWidth) + 1 }
    var totalWidth: CGFloat { rightX + rightWidth }

    /// The rows of change `h`.
    func rows(ofHunk h: Int) -> Range<Int>? {
        guard let a = rows.firstIndex(where: { $0.hunk == h }), let b = rows.lastIndex(where: { $0.hunk == h }) else { return nil }
        return a..<(b + 1)
    }
}

/// The code's font size: the editor's monospaced face at the size whose
/// cells are 8.0 wide (`editor-area.md` C.1), measured once.
enum MergeCodeFont {
    nonisolated(unsafe) static var measured: CGFloat?

    static var size: CGFloat { measured ?? 13 }

    static func font(_ ctx: GraphicsContext) -> Font {
        if measured == nil {
            let probe = String(repeating: "M", count: 40)
            let w = ctx.resolve(Text(verbatim: probe).font(ShellFonts.editor(13))).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width / 40
            measured = w > 1 ? min(16, max(10, 13 * CGFloat(MergeSheetMetrics.cellWidth) / w)) : 13
        }
        return ShellFonts.editor(size)
    }
}

/// One row's drawing (all three columns): shading, the current-line
/// highlight, changed words, line numbers, text, and the selected change's
/// rules.
struct MergeRowPainter {
    let row: MergeSheetRow
    let layout: MergePaneLayout
    let currentLeft: Int
    let currentRight: Int
    let isSelected: Bool
    let isDecided: Bool

    typealias M = MergeSheetMetrics

    func draw(_ ctx: inout GraphicsContext) {
        let p = layout.palette
        let lw = layout.leftWidth, rw = layout.rightWidth, rx = layout.rightX, gx = layout.gutterX
        let h = CGFloat(MergeSheetLayout.height(row, columns: layout.columns))
        let lh = CGFloat(M.lineHeight)
        func fill(_ r: CGRect, _ hex: UInt32) { ctx.fill(Path(r), with: .color(Color(mergeHex: hex))) }
        fill(CGRect(x: 0, y: 0, width: lw, height: h), p.pane)
        fill(CGRect(x: rx, y: 0, width: rw, height: h), p.pane)
        fill(CGRect(x: gx, y: 0, width: CGFloat(M.gutterWidth), height: h), p.gutter)
        // Shading: full width, through the gutter (§6).
        if row.kind != .same {
            let shade = row.kind == .conflict ? p.conflictRow : p.cleanRow
            fill(CGRect(x: 0, y: 0, width: lw, height: h), shade)
            fill(CGRect(x: rx, y: 0, width: rw, height: h), shade)
            fill(CGRect(x: gx, y: 0, width: CGFloat(M.gutterWidth), height: h), row.kind == .conflict ? p.gutterConflict : p.gutterClean)
        } else {
            // The current-line highlight on every visual line of the line.
            let inset = CGFloat(M.currentLineInset)
            if let l = row.left, l.number == currentLeft {
                let n = CGFloat(MergeSheetLayout.wrap(l.text, columns: layout.columns).count)
                ctx.fill(Path(roundedRect: CGRect(x: inset, y: 0, width: lw - 2 * inset, height: n * lh), cornerRadius: 4), with: .color(Color(mergeHex: p.currentLine)))
            }
            if let r = row.right, r.number == currentRight {
                let n = CGFloat(MergeSheetLayout.wrap(r.text, columns: layout.columns).count)
                ctx.fill(Path(roundedRect: CGRect(x: rx + inset, y: 0, width: rw - 2 * inset, height: n * lh), cornerRadius: 4),
                         with: .color(Color(mergeHex: p.currentLine)))
            }
        }
        fill(CGRect(x: lw, y: 0, width: 1, height: h), p.gutterRule)
        fill(CGRect(x: rx - 1, y: 0, width: 1, height: h), p.gutterRule)
        let font = MergeCodeFont.font(ctx)
        if let l = row.left { side(&ctx, l, runs: layout.leftRuns, x: 0, current: currentLeft, font: font) }
        if let r = row.right { side(&ctx, r, runs: layout.rightRuns, x: rx, current: currentRight, font: font) }
        // The selected change's rules, across both panes and the gutter.
        if isSelected {
            let rule = isDecided ? p.decidedRule : p.selectedRule
            if row.isFirstOfHunk { fill(CGRect(x: 0, y: 0, width: layout.totalWidth, height: 1), rule) }
            if row.isLastOfHunk { fill(CGRect(x: 0, y: h - 1, width: layout.totalWidth, height: 1), rule) }
        }
    }

    func side(_ ctx: inout GraphicsContext, _ s: MergeSheetRow.Side, runs: [[(text: String, role: SyntaxTokenKind.Role?)]], x: CGFloat,
              current: Int, font: Font) {
        let p = layout.palette
        let lh = CGFloat(M.lineHeight), cw = CGFloat(M.cellWidth)
        let segs = MergeSheetLayout.wrap(s.text, columns: layout.columns)
        // Changed words: 16 tall, whole cells, never the spaces (§6).
        for (k, seg) in segs.enumerated() {
            for w in s.words {
                let a = max(w.lowerBound, seg.cells.lowerBound), b = min(w.upperBound, seg.cells.upperBound)
                guard a < b else { continue }
                ctx.fill(Path(CGRect(x: x + CGFloat(M.codeX) + CGFloat(seg.column + a - seg.cells.lowerBound) * cw,
                                     y: CGFloat(k) * lh + CGFloat(M.wordInset), width: CGFloat(b - a) * cw, height: lh - 2 * CGFloat(M.wordInset))),
                         with: .color(Color(mergeHex: p.conflictWord)))
            }
        }
        // The line number, right-aligned at +27.
        let numberColor = Color(mergeHex: s.number == current ? p.currentLineNumber : p.lineNumber)
        ctx.draw(Text(verbatim: String(s.number)).font(Font.system(size: 10).monospacedDigit()).foregroundStyle(numberColor),
                 at: CGPoint(x: x + CGFloat(M.lineNumberRight), y: lh / 2), anchor: .trailing)
        // The text in the editor's colours, one visual line at a time.
        let line = runs.indices.contains(s.number - 1) ? runs[s.number - 1] : [(s.text, nil)]
        for (k, seg) in segs.enumerated() {
            var pieces: [Text] = []
            var at = 0
            for run in line {
                let chars = Array(run.text)
                let a = max(seg.cells.lowerBound, at), b = min(seg.cells.upperBound, at + chars.count)
                if a < b {
                    let piece = Text(verbatim: String(chars[(a - at)..<(b - at)])).foregroundStyle(layout.theme.color(run.role).color)
                    pieces.append(run.role == .keyword ? piece.bold() : piece)
                }
                at += chars.count
            }
            let t = pieces.reduce(Text(verbatim: ""), +)
            ctx.draw(t.font(font), at: CGPoint(x: x + CGFloat(M.codeX) + CGFloat(seg.column) * cw, y: CGFloat(k) * lh + lh / 2), anchor: .leading)
        }
    }
}

/// A change's token (§5, §13.5): a 38.5 × 14 capsule, #575757 with a
/// 0.5-point lighter rim (the selected change #6D2A2D with a 1-point red
/// rim), the glyph ("?" undecided, a digit once decided) left of centre,
/// then a light, thin down-chevron, in a circle once a choice is in effect.
struct MergeTokenView: View {
    var token: ConflictEditorState.Token
    var palette: MergeSheetPalette

    typealias M = MergeSheetMetrics

    var body: some View {
        let p = palette
        let w = CGFloat(M.tokenWidth), h = CGFloat(M.tokenHeight)
        ZStack(alignment: .topLeading) {
            Capsule(style: .continuous).fill(Color(mergeHex: token.isSelected ? p.selectedToken : p.token))
            Capsule(style: .continuous).strokeBorder(Color(mergeHex: token.isSelected ? p.selectedTokenRim : p.tokenRim),
                                                     lineWidth: CGFloat(token.isSelected ? MergeSheetToken.selectedRimWidth : MergeSheetToken.rimWidth))
            Text(verbatim: token.glyph).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(mergeHex: p.tokenInk))
                .frame(width: 14, height: h)
                .offset(x: 21.5 - 7)
            if token.isDecided {
                Circle().fill(Color(mergeHex: token.isSelected ? p.selectedChevronCircle : p.chevronCircle))
                    .frame(width: CGFloat(M.chevronCircle), height: CGFloat(M.chevronCircle))
                    .offset(x: 33.5 - CGFloat(M.chevronCircle) / 2, y: (h - CGFloat(M.chevronCircle)) / 2)
            }
            Path { path in
                let hw = CGFloat(MergeSheetToken.chevronHalfWidth), ch = CGFloat(MergeSheetToken.chevronHeight)
                path.move(to: CGPoint(x: 33.5 - hw, y: h / 2 - ch / 2))
                path.addLine(to: CGPoint(x: 33.5, y: h / 2 + ch / 2))
                path.addLine(to: CGPoint(x: 33.5 + hw, y: h / 2 - ch / 2))
            }
            .stroke(Color(mergeHex: p.tokenInk),
                    style: StrokeStyle(lineWidth: CGFloat(MergeSheetToken.chevronLineWidth), lineCap: .round, lineJoin: .round))
        }
        .frame(width: w, height: h)
        .contentShape(Capsule())
    }
}

/// The panes' scroll offset and content height.
struct MergeScrollState: Equatable {
    var top: CGFloat = 0
    var content: CGFloat = 0
}

/// The 17-point overview ruler (§4.4, §14.4): the track 3 inside the
/// pane's top and bottom; in dark an 11-wide knob (#A2A2A2) over its
/// visible part (the whole track when the file fits); a 10-wide mark per
/// change at its first line's centre (conflicts #FDB9B5, clean #D4D4D4); a
/// click scrolls there.
struct MergeRuler: View {
    var marks: [(position: Double, isConflict: Bool)]
    var palette: MergeSheetPalette
    var scroll = MergeScrollState()
    var visibleHeight: CGFloat = 0
    var onClick: (Double) -> Void

    typealias M = MergeSheetMetrics

    var body: some View {
        let p = palette
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(mergeHex: p.pane)))
                if let knob = p.rulerKnob {
                    let k = M.rulerKnob(visibleTop: Double(scroll.top), visibleHeight: Double(visibleHeight),
                                        contentHeight: Double(max(scroll.content, visibleHeight)), height: Double(size.height))
                    let r = CGRect(x: CGFloat(M.rulerKnobX), y: CGFloat(k.y), width: CGFloat(M.rulerKnobWidth), height: CGFloat(k.height))
                    ctx.fill(Path(roundedRect: r, cornerRadius: r.width / 2), with: .color(Color(mergeHex: knob)))
                }
                for m in marks {
                    ctx.fill(Path(CGRect(x: CGFloat(M.rulerMarkX), y: CGFloat(M.rulerMarkY(share: m.position, height: Double(size.height))),
                                         width: CGFloat(M.rulerMarkWidth), height: 1)),
                             with: .color(Color(mergeHex: m.isConflict ? p.rulerConflict : p.rulerClean)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 1, coordinateSpace: .local) { pt in
                let inset = M.rulerTrackInset
                onClick(max(0, min(1, (Double(pt.y) - inset) / max(1, Double(geo.size.height) - 2 * inset))))
            }
        }
    }
}
