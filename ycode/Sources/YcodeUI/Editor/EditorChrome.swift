import AppKit
import YcodeIDECore

/// The editor's bars over its text (`specs/ide/liquid-glass.md` §7.3,
/// `fidelity-council.md` row 5): the text scrolls under the toolbar band,
/// the jump bar and the sticky header, which let about 6 % of it show as a
/// shapeless veil. The fill is the editor's background, nearly opaque,
/// with no fade at the edges.
@MainActor
enum EditorVeil {
    static var fill: NSColor { Theme.backgroundColor.withAlphaComponent(1 - CGFloat(EditorMetrics.barVeil)) }
    /// The 2-point separator under the jump bar and the sticky header.
    static var separator: NSColor { NSColor.separatorColor }

    /// The separator, opaque: the system colour is translucent, so it is
    /// drawn over the editor's background, or the text beneath would show
    /// through it at full strength.
    static func drawSeparator(_ r: NSRect) {
        Theme.backgroundColor.setFill()
        r.fill(using: .copy)
        separator.setFill()
        r.fill(using: .sourceOver)
    }
}

/// The veil behind the toolbar band and the jump bar: from the editor's
/// top (under the toolbar) to the jump bar's separator.
final class EditorBandBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        EditorVeil.fill.setFill()
        dirtyRect.intersection(bounds).fill(using: .copy)
    }
}

/// The sticky scope header (`editor-area.md` §C.3): the lines that open
/// the declarations enclosing the first visible line, each with its line
/// number in the gutter, in their syntax colours, on an 18-point pitch
/// below a 2-point pad; a 2-point separator below. It spans the gutter and
/// the text, not the minimap. No outline, no shadow.
final class ScopeHeaderView: NSView {
    struct Row {
        var line: Int
        var text: NSAttributedString
    }
    private(set) var rows: [Row] = []
    var lineHeight: CGFloat = 18
    var codeColumn: CGFloat = CGFloat(EditorMetrics.codeColumn)
    var numberEnd: CGFloat = CGFloat(EditorMetrics.lineNumberEnd)
    var showsLineNumbers = true
    /// The code baseline below a line's top.
    var baseline: CGFloat = 14

    override var isFlipped: Bool { true }

    func show(_ rows: [Row]) {
        self.rows = rows
        isHidden = rows.isEmpty
        needsDisplay = true
    }

    /// The header's height: the rows and the pad, then the separator.
    var bandHeight: CGFloat { CGFloat(EditorMetrics.stickyHeaderHeight(rows: rows.count, lineHeight: Double(lineHeight))) }
    var totalHeight: CGFloat { rows.isEmpty ? 0 : bandHeight + CGFloat(EditorMetrics.stickyHeaderSeparator) }

    override func draw(_ dirtyRect: NSRect) {
        EditorVeil.fill.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bandHeight).fill(using: .copy)
        EditorVeil.drawSeparator(NSRect(x: 0, y: bandHeight, width: bounds.width, height: CGFloat(EditorMetrics.stickyHeaderSeparator)))
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: Theme.lineNumberColor]
        for (i, r) in rows.enumerated() {
            let top = CGFloat(EditorMetrics.stickyHeaderTopPad) + CGFloat(i) * lineHeight
            let base = top + baseline
            if showsLineNumbers {
                let n = NSAttributedString(string: "\(r.line)", attributes: numberAttrs)
                n.draw(at: NSPoint(x: numberEnd - n.size().width, y: base - Theme.gutterFont.ascender))
            }
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: codeColumn, y: top, width: max(0, bounds.width - codeColumn), height: lineHeight).clip()
            r.text.draw(at: NSPoint(x: codeColumn, y: base - Theme.font.ascender))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The minimap (`editor-area.md` §C.5): the text at 1/6 scale, each
/// visual line a 2-point bar on a 3-point pitch in its tokens' colours at
/// about 35 %, with a full-width shade over the visible area. No labels.
/// A 1-point separator at its left edge. It runs under the bars like the
/// text and scrolls in proportion to the editor when the file is taller
/// than it.
@MainActor
final class MinimapView: NSView {
    /// One visual line: runs of (first column, length, colour).
    struct Run: Equatable {
        var column: Int
        var length: Int
        var color: NSColor
    }
    var rows: [[Run]] = [] { didSet { cache = nil; needsDisplay = true } }
    /// The content inset at the top (under the bars) and the visible
    /// area, as fractions of the document.
    var contentTop: CGFloat = 0 { didSet { if oldValue != contentTop { needsDisplay = true } } }
    var visibleTop: CGFloat = 0 { didSet { if oldValue != visibleTop { needsDisplay = true } } }
    var visibleHeight: CGFloat = 0 { didSet { if oldValue != visibleHeight { needsDisplay = true } } }
    /// The editor's scroll position, 0 at the top and 1 at the end.
    var scrollFraction: CGFloat = 0 { didSet { if oldValue != scrollFraction { needsDisplay = true } } }
    /// A character's width at full size (the minimap draws it at 1/6).
    var advance: CGFloat = 8
    /// The first line's inset below the content top, in text points.
    var textTopInset: CGFloat = CGFloat(EditorMetrics.firstLineInset)
    /// A click or drag: scroll the editor so this document y (text
    /// points) is centred.
    var onScrollTo: ((CGFloat) -> Void)?
    private var cache: NSImage?

    override var isFlipped: Bool { true }

    /// The width for an editor of `w` points, its separator included.
    static func width(forEditorWidth w: CGFloat) -> CGFloat {
        CGFloat(EditorMetrics.minimapWidth(editorWidth: Double(w)) + EditorMetrics.minimapSeparator)
    }

    var pitch: CGFloat { CGFloat(EditorMetrics.minimapLinePitch) }
    var scale: CGFloat { CGFloat(EditorMetrics.minimapScale) }
    var contentHeight: CGFloat { CGFloat(rows.count) * pitch + textTopInset * scale }
    /// The minimap's own scroll offset (it scrolls only when the file is
    /// taller than the minimap).
    var offset: CGFloat {
        CGFloat(EditorMetrics.minimapOffset(contentHeight: Double(contentHeight), viewHeight: Double(max(0, bounds.height - contentTop)),
                                            fraction: Double(scrollFraction)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width { cache = nil }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views do not clip to their bounds: fill only this view's own area.
        Theme.backgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        let sep = CGFloat(EditorMetrics.minimapSeparator)
        let top = contentTop - offset
        // The visible area: a full-width shade.
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSRect(x: sep, y: top + visibleTop * scale, width: bounds.width - sep, height: visibleHeight * scale).fill()
        if let image = renderedRows() {
            image.draw(in: NSRect(x: 0, y: top + textTopInset * scale, width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: sep, height: bounds.height).fill()
    }

    /// The bars, drawn once per change of text or width.
    private func renderedRows() -> NSImage? {
        if let cache { return cache }
        guard !rows.isEmpty, bounds.width > 0 else { return nil }
        let inset = CGFloat(EditorMetrics.minimapSeparator + EditorMetrics.minimapTextInset)
        let charWidth = advance * scale
        let height = min(CGFloat(rows.count) * pitch, 16_000)
        let width = bounds.width
        let image = NSImage(size: NSSize(width: width, height: max(1, height)), flipped: true) { [rows, pitch] _ in
            let bar = CGFloat(EditorMetrics.minimapBarHeight)
            let ink = CGFloat(EditorMetrics.minimapInk)
            for (i, runs) in rows.enumerated() {
                let y = CGFloat(i) * pitch
                if y > height { break }
                for r in runs {
                    let x = inset + CGFloat(r.column) * charWidth
                    guard x < width else { continue }
                    r.color.withAlphaComponent(r.color.alphaComponent * ink).setFill()
                    NSRect(x: x, y: y, width: min(CGFloat(r.length) * charWidth, width - x), height: bar).fill()
                }
            }
            return true
        }
        cache = image
        return image
    }

    override func mouseDown(with event: NSEvent) { scrollTo(event) }
    override func mouseDragged(with event: NSEvent) { scrollTo(event) }

    private func scrollTo(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let docY = (p.y - contentTop + offset) / scale - textTopInset
        onScrollTo?(max(0, docY))
    }
}

extension MinimapView {
    /// The visual lines of `text` at `columns` per line, with the colours
    /// of `storage` (wrapped lines continue at their indentation plus 4).
    static func rows(of storage: NSAttributedString, columns: Int, tabWidth: Int, wraps: Bool) -> [[Run]] {
        let ns = storage.string as NSString
        var out: [[Run]] = []
        var lineStart = 0
        let length = ns.length
        let cols = max(8, columns)
        while lineStart <= length {
            var end = lineStart
            while end < length, ns.character(at: end) != 10 { end += 1 }
            let line = ns.substring(with: NSRange(location: lineStart, length: end - lineStart))
            let indent = EditorMetrics.wrappedIndent(of: Substring(line), tabWidth: tabWidth)
            var row: [Run] = []
            var col = 0
            var i = lineStart
            func flush() { out.append(row); row = [] }
            while i < end {
                var range = NSRange()
                let color = (storage.attribute(.foregroundColor, at: i, effectiveRange: &range) as? NSColor) ?? Theme.textColor
                let runEnd = min(end, NSMaxRange(range))
                var runStart: Int?
                var runCol = 0
                func closeRun() {
                    if runStart != nil, col > runCol { row.append(Run(column: runCol, length: col - runCol, color: color)) }
                    runStart = nil
                }
                while i < runEnd {
                    let c = ns.character(at: i)
                    if wraps, col >= cols {
                        closeRun()
                        flush()
                        col = min(indent, cols / 2)
                    }
                    if c == 32 || c == 9 {
                        closeRun()
                        col += c == 9 ? tabWidth - col % max(1, tabWidth) : 1
                    } else {
                        if runStart == nil { runStart = i; runCol = col }
                        col += 1
                    }
                    i += 1
                }
                closeRun()
            }
            flush()
            lineStart = end + 1
        }
        return out
    }
}
