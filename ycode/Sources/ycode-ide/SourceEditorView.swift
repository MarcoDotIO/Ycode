import Foundation
import SwiftUI
import YcodeBuild
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax
#if os(Linux)
import OVPlatform
#else
import AppKit
#endif

/// The source editor (`docs/PARITY.md` §5.9 item 2): a viewport-sized `Canvas`
/// that draws only the visible lines, with the gutter over the text.
///
/// On OpenViews the editor scrolls itself (`textSurfaceScroll`) and redraws
/// without a layout (`SourceEditorController.invalidate()`): the canvas reads
/// the controller when it draws, and the body reads nothing that typing or
/// scrolling changes. On Apple's SwiftUI it sits in a `ScrollView` as
/// `ov-editor-bench` measures the pattern.
struct SourceEditorView: View {
    let controller: SourceEditorController
    var model: WorkspaceShellModel
    let palette: SourcePalette
    /// `ShellPreferences.revision`: new settings measure the font again.
    let preferences: Int
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = controller
        let bar = model.findBar
        // Read here so a change of the find matches or of the issues draws
        // again (they change rarely; typing does not change them).
        let matches = bar.isShown ? bar.matches : []
        let currentMatch = bar.current
        let issues = model.editorIssues
        let debugMarks = model.debug.marks(for: c.document.path)
        let scm = model.sourceControl
        let changes = scm.changeRegionsPath != nil && scm.changeRegionsPath == model.editor?.path ? scm.changeRegions : []
        let diamonds = model.testDiamonds
        // The rename's occurrences (they change rarely, as the matches).
        let highlights = model.languageFeatures.highlights
        let colors = ShellColors(scheme)
        let palette = palette
        let preferences = preferences
        let canvas = Canvas { ctx, size in
            c.applyPreferences(revision: preferences)
            c.viewportChanged(size)
            var painter = SourceEditorPainter(controller: c, palette: palette, colors: colors,
                                              matches: matches, currentMatch: currentMatch, issues: issues, debug: debugMarks,
                                              changes: changes, diamonds: diamonds, highlights: highlights)
            painter.draw(&ctx, size: size)
        }
        content(canvas)
            .contentShape(Rectangle())
            .background { WindowOriginReader(controller: c) }
            #if os(Linux)
            .textSurfacePointer { e in
                switch e {
                case .down(let p, let t):
                    focused = true
                    // ⌥-click: Quick Help; ⌘- or Ctrl-click: Jump to Definition.
                    if let m = c.connection?.pointerModifiers, SymbolClick.handle(p, modifiers: m, controller: c, model: model) { return }
                    c.pointerChanged(start: p, location: p, time: t, shift: c.connection?.pointerModifiers.contains(.shift) ?? false)
                case .moved(let p, _): c.pointerChanged(start: p, location: p, time: 0, shift: false)
                case .up, .cancelled: c.pointerEnded()
                }
            }
            .textSurfaceScroll { d, _ in
                model.dismissQuickHelp()
                return c.wheel(d)
            }
            .textSurface(c)
            .focused($focused)
            #else
            .highPriorityGesture(pointerGesture(c))
            .focusable()
            .focused($focused)
            .onKeyPress(phases: [.down, .repeat]) { c.handle($0) }
            #endif
            .onChange(of: model.revealCount) { _, _ in
                if model.markedLine != nil { c.centerCaret() }
            }
            .onChange(of: model.editorFocusCount) { _, _ in focused = true }
            .onAppear {
                if !ShellFocus.outlineHasKeyboard { focused = true }
                c.onGutterDiamondClick = { [weak model] line in
                    guard let model, model.testDiamonds[line] != nil else { return false }
                    model.runTests(atLine: line)
                    return true
                }
                c.onActivity = { [weak model] in model?.caretMoved() }
                model.updateCaretSymbol()
                c.onEscape = { [weak bar, weak model] in
                    if let model, model.languageFeatures.popover != nil {
                        model.dismissQuickHelp()
                        return true
                    }
                    guard let bar, bar.isShown else { return false }
                    bar.isShown = false
                    return true
                }
                c.scheduleRefine(after: 0.05)
                c.requestCompletions = { [weak model] in await model?.completions() ?? [] }
                DebugGutter.connect(c, model: model)
            }
            .task(id: c.document.path) {
                // The file on disk, about once a second.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    model.checkOpenFilesOnDisk()
                }
            }
            .contextMenu {
                Button("Cut") { _ = c.perform(.cut, clipboard: Self.clipboard(c)) }.disabled(c.buffer.selection.isEmpty || c.buffer.isReadOnly)
                Button("Copy") { _ = c.perform(.copy, clipboard: Self.clipboard(c)) }.disabled(c.buffer.selection.isEmpty)
                Button("Paste") { _ = c.perform(.paste, clipboard: Self.clipboard(c)) }.disabled(c.buffer.isReadOnly)
                Divider()
                Button("Select All") { _ = c.perform(.selectAll, clipboard: Self.clipboard(c)) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Source Editor")
            .accessibilityValue(c.document.name)
            .shellTarget("source")
    }

    #if os(Linux)
    func content<C: View>(_ canvas: C) -> some View { canvas }
    #else
    func content<C: View>(_ canvas: C) -> some View {
        let c = controller
        let tick = c.redraw.tick
        return ScrollView([.vertical, .horizontal]) {
            Color.clear
                .frame(width: c.contentWidth, height: c.contentHeight)
                .overlay(alignment: .topLeading) {
                    canvas
                        .id(tick)
                        .frame(width: c.viewport.width, height: c.viewport.height)
                        .offset(x: c.left, y: c.top)
                }
        }
        .scrollPosition(Binding(get: { c.position }, set: { c.position = $0 }))
        .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, r in c.scrolled(to: r) }
    }
    #endif

    static func clipboard(_ c: SourceEditorController) -> (get: () -> String?, set: (String) -> Void) {
        #if os(Linux)
        return (get: { c.connection?.clipboardText }, set: { c.connection?.clipboardText = $0 })
        #else
        return (get: { NSPasteboard.general.string(forType: .string) },
                set: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) })
        #endif
    }

    #if !os(Linux)
    func pointerGesture(_ c: SourceEditorController) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                focused = true
                let shift = NSEvent.modifierFlags.contains(.shift)
                c.pointerChanged(start: v.startLocation, location: v.location, time: v.time.timeIntervalSinceReferenceDate, shift: shift)
            }
            .onEnded { _ in c.pointerEnded() }
    }
    #endif
}

/// Keeps the editor's window origin for the input method's caret rectangle.
struct WindowOriginReader: View {
    let controller: SourceEditorController

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            Color.clear.onChange(of: origin, initial: true) { _, o in controller.windowOrigin = o }
        }
    }
}

/// Draws one frame of the editor.
@MainActor
struct SourceEditorPainter {
    let controller: SourceEditorController
    let palette: SourcePalette
    let colors: ShellColors
    var caretOn: Bool { controller.caretOn }
    let matches: [NSRange]
    let currentMatch: Int?
    let issues: [Int: EditorLineIssue]
    var debug = EditorDebugMarks()
    /// The change bars (source control): unstaged in the accent color,
    /// staged in grey, a deletion as a short mark between lines.
    var changes: [SourceChangeRegion] = []
    /// Test diamonds by 1-based line, in place of the line number
    /// (`specs/ide/testing.md` §Gutter): outlined, green, red.
    var diamonds: [Int: TestOutcome.Status?] = [:]
    var highlights: [NSRange] = []

    func font(_ c: SourceEditorController) -> Font { ShellFonts.editor(c.fontSize) }

    mutating func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let c = controller
        let b = c.buffer
        let f = font(c)
        c.prepareMetrics { s in ctx.resolve(Text(verbatim: s).font(f)).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)) }
        #if os(Linux)
        // Hit testing and carets between frames measure other characters
        // with the context of the last frame.
        let measuring = ctx
        c.characterMeasure = { ch in measuring.resolve(Text(verbatim: String(ch)).font(f)).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width }
        #endif
        let lines = c.visibleLines(height: size.height)
        let lh = c.lineHeight
        let textX = c.textOrigin - c.left
        func top(_ n: Int) -> CGFloat { c.lineTop(n) - c.top }
        let doc = b.document
        guard !lines.isEmpty else { return }

        // Whole-line bands.
        let currentLine = b.caretLine
        if b.selection.isEmpty, c.isFocused || true {
            ctx.fill(Path(CGRect(x: 0, y: top(currentLine), width: size.width, height: lh)), with: .color(palette.currentLine.color))
        }
        for n in lines {
            if let i = issues[n + 1] {
                let tint = (i.isError ? Color.red : Color.yellow).opacity(0.13)
                ctx.fill(Path(CGRect(x: 0, y: top(n), width: size.width, height: lh)), with: .color(tint))
            }
        }
        DebugGutter.drawStoppedLine(&ctx, debug, lines: lines, top: top, lineHeight: lh, width: size.width)

        // Find matches.
        if !matches.isEmpty {
            let first = doc.lineStart(lines.lowerBound)
            let end = lines.upperBound < doc.lineCount ? doc.lineStart(lines.upperBound) : b.length
            var lo = 0, hi = matches.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if matches[mid].location + matches[mid].length < first { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < matches.count, matches[i].location <= end {
                let isCurrent = i == currentMatch
                fillRange(&ctx, matches[i].location..<(matches[i].location + matches[i].length), lines: lines,
                          color: Color.yellow.opacity(isCurrent ? 0.75 : 0.32), textX: textX)
                i += 1
            }
        }

        // The occurrences of a symbol being renamed.
        for h in highlights where h.length > 0 {
            fillRange(&ctx, h.location..<(h.location + h.length), lines: lines, color: colors.accent.opacity(0.22), textX: textX)
        }

        // The selection.
        if !b.selection.isEmpty {
            fillRange(&ctx, b.selection.range, lines: lines, color: palette.selection.color, textX: textX)
        }

        // The text.
        let columnWidth = max(c.layout.advance, 1)
        let columns = max(0, Int(c.left / columnWidth) - 8)..<(Int((c.left + size.width) / columnWidth) + 8)
        for n in lines {
            let line = c.layout.displayLine(n, in: b, columns: columns)
            let y = top(n) + c.textDrop
            let x = textX + CGFloat(line.firstColumn) * c.layout.advance
            if b.hasMarkedText, n == currentLine {
                drawComposing(&ctx, line, y: y, x: x)
            } else if !line.runs.isEmpty {
                ctx.draw(text(line.runs).font(f), at: CGPoint(x: x, y: y), anchor: .topLeading)
            }
        }

        // Issue labels at the lines' right ends.
        for n in lines {
            guard let i = issues[n + 1] else { continue }
            let message = Text(verbatim: i.message).font(.system(size: 11)).foregroundStyle(palette.foreground.color)
            let r = ctx.resolve(message)
            let m = r.measure(in: CGSize(width: size.width * 0.6, height: lh))
            let w = min(m.width, size.width * 0.6)
            let box = CGRect(x: size.width - w - 14, y: top(n) + 0.5, width: w + 10, height: lh - 1)
            ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(palette.background.color))
            ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color((i.isError ? Color.red : Color.yellow).opacity(0.28)))
            ctx.draw(r, in: CGRect(x: box.minX + 5, y: box.minY, width: w, height: box.height))
        }

        DebugGutter.drawAnnotation(&ctx, debug, lines: lines, top: top, lineHeight: lh, width: size.width)

        // The caret.
        if b.selection.isEmpty || b.hasMarkedText, caretOn, c.isFocused {
            var x = textX + c.layout.x(ofOffset: b.caret, line: currentLine, in: b)
            if b.hasMarkedText {
                x += markedPrefixWidth(c)
            }
            ctx.fill(Path(CGRect(x: x - 0.5, y: top(currentLine), width: 1.5, height: lh)), with: .color(palette.foreground.color))
        }

        // The scroll indicator, for a second after scrolling (Linux; the
        // scroll view draws its own elsewhere).
        #if os(Linux)
        if c.now - c.lastScroll < 1, c.contentHeight > size.height {
            let track = size.height - 6
            let len = max(36, track * size.height / c.contentHeight)
            let frac = c.top / max(1, c.contentHeight - size.height)
            ctx.fill(Path(roundedRect: CGRect(x: size.width - 6, y: 3 + (track - len) * frac, width: 3, height: len), cornerRadius: 1.5),
                     with: .color(palette.foreground.color.opacity(0.35)))
        }
        #endif

        // The gutter stays put while the text scrolls under it.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: c.gutterWidth, height: size.height)), with: .color(palette.background.color))
        if b.selection.isEmpty {
            ctx.fill(Path(CGRect(x: 0, y: top(currentLine), width: c.gutterWidth, height: lh)), with: .color(palette.currentLine.color))
        }
        let numberFont = Font.system(size: 10).monospacedDigit()
        for n in lines {
            let isCurrent = n == currentLine
            let hasBreakpoint = DebugGutter.drawBreakpoint(&ctx, debug, line: n + 1, top: top(n), lineHeight: lh, numberRight: c.numberRight)
            DebugGutter.drawPCMark(&ctx, debug, line: n + 1, top: top(n), lineHeight: lh)
            if !hasBreakpoint, let d = diamonds[n + 1] {
                drawDiamond(&ctx, status: d, center: CGPoint(x: c.numberRight - 6, y: top(n) + lh / 2))
            } else {
                let numberColor = hasBreakpoint ? Color.white : (isCurrent ? palette.foreground.color : palette.lineNumber.color)
                let t = Text(verbatim: "\(n + 1)").font(numberFont).foregroundStyle(numberColor)
                ctx.draw(t, at: CGPoint(x: c.numberRight, y: top(n) + lh / 2), anchor: .trailing)
            }
            if let i = issues[n + 1] {
                let dot = CGRect(x: c.gutterWidth - 14, y: top(n) + lh / 2 - 3.5, width: 7, height: 7)
                ctx.fill(Path(ellipseIn: dot), with: .color(i.isError ? Color.red : Color.yellow))
            }
        }
        drawChangeBars(&ctx, lines: lines)

        drawCompletion(&ctx, size: size)
    }

    /// A test's diamond: outlined before a run, green with a check when it
    /// passed, red with a cross when it failed.
    private func drawDiamond(_ ctx: inout GraphicsContext, status: TestOutcome.Status?, center p: CGPoint) {
        let r: CGFloat = 6.5
        var shape = Path()
        shape.move(to: CGPoint(x: p.x, y: p.y - r))
        shape.addLine(to: CGPoint(x: p.x + r, y: p.y))
        shape.addLine(to: CGPoint(x: p.x, y: p.y + r))
        shape.addLine(to: CGPoint(x: p.x - r, y: p.y))
        shape.closeSubpath()
        switch status {
        case .passed?, .failed?:
            ctx.fill(shape, with: .color(status == .passed ? colors.success : colors.error))
            var mark = Path()
            if status == .passed {
                mark.move(to: CGPoint(x: p.x - 2.6, y: p.y))
                mark.addLine(to: CGPoint(x: p.x - 0.6, y: p.y + 2))
                mark.addLine(to: CGPoint(x: p.x + 2.8, y: p.y - 2))
            } else {
                mark.move(to: CGPoint(x: p.x - 2.2, y: p.y - 2.2)); mark.addLine(to: CGPoint(x: p.x + 2.2, y: p.y + 2.2))
                mark.move(to: CGPoint(x: p.x + 2.2, y: p.y - 2.2)); mark.addLine(to: CGPoint(x: p.x - 2.2, y: p.y + 2.2))
            }
            ctx.stroke(mark, with: .color(.white), lineWidth: 1.5)
        default:
            ctx.stroke(shape, with: .color(palette.lineNumber.color), lineWidth: 1.2)
        }
    }

    /// The change column at the gutter's right edge (`reference-ui-5.md`
    /// §6.3), as the AppKit gutter draws it.
    private func drawChangeBars(_ ctx: inout GraphicsContext, lines: Range<Int>) {
        guard let first = lines.first, let last = lines.last, !changes.isEmpty else { return }
        let c = controller
        let lh = c.lineHeight
        let x = c.gutterWidth - 5
        func top(_ n: Int) -> CGFloat { c.lineTop(n) - c.top }
        for r in changes {
            let tint = r.staged ? colors.secondaryLabel : colors.accent
            let a = r.firstLine - 1
            if r.kind == .deleted {
                guard a >= first, a <= last + 1 else { continue }
                ctx.fill(Path(roundedRect: CGRect(x: x - 1, y: top(a) - 2, width: 5, height: 4), cornerRadius: 1.5), with: .color(tint))
                continue
            }
            let z = a + max(r.lineCount, 1) - 1
            guard z >= first, a <= last else { continue }
            let y0 = top(max(a, first)), y1 = top(min(z, last)) + lh
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y0, width: 3, height: y1 - y0), cornerRadius: 1.5), with: .color(tint))
        }
    }

    /// The completion list under the word being completed.
    private func drawCompletion(_ ctx: inout GraphicsContext, size: CGSize) {
        let c = controller
        guard let list = c.completion, let f = c.completionFrame(in: size) else { return }
        let box = Path(roundedRect: f.rect, cornerRadius: 6)
        ctx.fill(box, with: .color(palette.background.color))
        ctx.fill(box, with: .color(palette.foreground.color.opacity(0.05)))
        ctx.stroke(box, with: .color(palette.foreground.color.opacity(0.25)), lineWidth: 1)
        let rows = min(SourceEditorController.completionRows, list.shown.count)
        let labelFont = font(c), detailFont = Font.system(size: 11)
        for r in 0..<rows {
            let i = f.first + r
            let y = f.rect.minY + 3 + CGFloat(r) * f.rowHeight
            if i == list.selected {
                ctx.fill(Path(roundedRect: CGRect(x: f.rect.minX + 3, y: y, width: f.rect.width - 6, height: f.rowHeight), cornerRadius: 4),
                         with: .color(colors.accent.opacity(0.85)))
            }
            let fg = i == list.selected ? Color.white : palette.foreground.color
            let item = list.shown[i]
            ctx.draw(Text(verbatim: item.label).font(labelFont).foregroundStyle(fg),
                     at: CGPoint(x: f.rect.minX + 10, y: y + f.rowHeight / 2), anchor: .leading)
            if let d = item.detail, !d.isEmpty {
                ctx.draw(Text(verbatim: d).font(detailFont).foregroundStyle(fg.opacity(0.7)),
                         at: CGPoint(x: f.rect.maxX - 10, y: y + f.rowHeight / 2), anchor: .trailing)
            }
        }
    }

    private func text(_ runs: [EditorRun]) -> Text {
        runs.reduce(Text(verbatim: "")) { t, r in
            let piece = Text(verbatim: r.text).foregroundStyle(palette.color(r.role).color)
            return t + (r.role == .keyword ? piece.bold() : piece)
        }
    }

    /// Fills `range` on the visible lines (a line it runs past gets a little
    /// more, showing the newline is included).
    private func fillRange(_ ctx: inout GraphicsContext, _ range: Range<Int>, lines: Range<Int>, color: Color, textX: CGFloat) {
        let c = controller
        let b = c.buffer
        let doc = b.document
        let a = max(lines.lowerBound, doc.line(containing: range.lowerBound))
        let z = min(lines.upperBound - 1, doc.line(containing: range.upperBound))
        guard a <= z else { return }
        for n in a...z {
            let r = doc.lineRange(n)
            let lo = max(range.lowerBound, r.lowerBound), hi = min(range.upperBound, r.upperBound)
            guard lo <= hi else { continue }
            let x0 = c.layout.x(ofOffset: lo, line: n, in: b)
            var x1 = c.layout.x(ofOffset: hi, line: n, in: b)
            if range.upperBound > r.upperBound { x1 += c.layout.advance }
            guard x1 > x0 else { continue }
            ctx.fill(Path(CGRect(x: textX + x0, y: c.lineTop(n) - c.top, width: x1 - x0, height: c.lineHeight)), with: .color(color))
        }
    }

    /// The caret's line during an input-method composition: the text, the
    /// marked text underlined, the rest of the line after it.
    private func drawComposing(_ ctx: inout GraphicsContext, _ line: EditorDisplayLine, y: CGFloat, x: CGFloat) {
        let c = controller
        let b = c.buffer
        let f = font(c)
        let caretX = c.layout.x(ofOffset: b.caret, line: b.caretLine, in: b)
        let split = c.layout.displayColumn(ofOffset: b.caret, line: b.caretLine, in: b)
        let (before, after) = line.split(atColumn: split - line.firstColumn)
        if !before.isEmpty { ctx.draw(text(before).font(f), at: CGPoint(x: x, y: y), anchor: .topLeading) }
        let marked = Text(verbatim: b.markedText).font(f).foregroundStyle(palette.foreground.color)
        let r = ctx.resolve(marked)
        let w = r.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
        let mx = c.textOrigin - c.left + caretX
        ctx.draw(r, at: CGPoint(x: mx, y: y), anchor: .topLeading)
        ctx.fill(Path(CGRect(x: mx, y: y + c.lineHeight - 2, width: w, height: 1)), with: .color(palette.foreground.color))
        if !after.isEmpty { ctx.draw(text(after).font(f), at: CGPoint(x: mx + w, y: y), anchor: .topLeading) }
    }

    /// The width of the marked text before its cursor.
    private func markedPrefixWidth(_ c: SourceEditorController) -> CGFloat {
        c.layout.width(ofText: String(c.buffer.markedText.prefix(c.buffer.markedCursor)))
    }
}
