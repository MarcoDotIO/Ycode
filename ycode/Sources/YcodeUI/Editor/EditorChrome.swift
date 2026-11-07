import AppKit
import YcodeIDECore
import YcodeSyntax

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

/// The blurred veil of the editor's bars (`liquid-glass.md` §8.3, §9.1;
/// `fidelity-council.md` rows 5 and 68): the content beneath shows
/// blurred (σ about 6) and faint, **keeping its shape** (`StructureBlur`),
/// at each bar's share of the content's darkness (`BarBlur`): toolbar band
/// 18 %, jump bar 8.5 %, bottom bar 12 %. No gradient, no fade. A theme
/// with its own background colour keeps the round-1 fill instead.
@MainActor
enum EditorBlurVeil {
    static var applies: Bool { EditorTheme.color(Theme.current.background) == nil }
}

/// A backdrop view: the content under it blurred with its shape, or the
/// theme's veil fill.
public class EditorBlurBackdrop: NSView {
    /// The views whose content shows through (the editor's text and minimap).
    var sources: () -> [NSView] = { [] }
    /// The bands of this view and their shares, top to bottom.
    var regions: () -> [(rect: NSRect, share: CGFloat)] = { [] }
    /// Whether the content's shape is drawn (tests; false: the theme's fill).
    public var showsStructure: Bool { EditorBlurVeil.applies }
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Follows the theme.
    public func themeChanged() {
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard EditorBlurVeil.applies else {
            EditorVeil.fill.setFill()
            dirtyRect.intersection(bounds).fill(using: .copy)
            return
        }
        Theme.backgroundColor.setFill()
        dirtyRect.intersection(bounds).fill(using: .copy)
        let shown = regions().filter { $0.share > 0 && $0.rect.intersects(dirtyRect) }
        guard let union = shown.map(\.rect).reduce(nil, { r, x in r.map { $0.union(x) } ?? x }), let image = blurredImage(of: union) else { return }
        // One render of the content serves every band; each band shows it
        // at its own share (council round 4, row 106: the bands were each
        // rendered on their own, every frame).
        for (rect, share) in shown { StructureBlur.draw(image, for: union, in: self, share: share, clip: rect) }
    }

    /// The last render: the image, the rect it was made for, and the
    /// content's scroll position then.
    private var cached: (image: CGImage, rect: NSRect)?
    /// Renders made (tests).
    public private(set) var renderCount = 0

    /// The blurred content under `rect`: rendered now, or, while the
    /// window's layout is in motion (`EditorBlurMotion`: the inspector's
    /// slide, a live resize), the last render stretched to the new rect.
    /// A held image is replaced by one render when the motion ends.
    private func blurredImage(of rect: NSRect) -> CGImage? {
        if EditorBlurMotion.isHolding || inLiveResize, let cached, cached.rect.height == rect.height { return cached.image }
        guard let image = StructureBlur.image(of: rect, in: self, sources: sources(), background: Theme.backgroundColor) else { return nil }
        renderCount += 1
        cached = (image, rect)
        return image
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { EditorBlurMotion.register(self) }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }
}

/// Motion of the window's layout during which the bars keep their last
/// blurred image instead of rendering the content again every frame
/// (`editor-area.md` F.5, checklist row 106: a render of the text under
/// the bars cost several milliseconds per bar, so the inspector's slide
/// drew 5–6 frames instead of a new one on every display refresh). The
/// blur is σ 6 at 8.5–18 % of the content's darkness, so a held image is
/// not told apart while the text re-wraps under it; one render follows
/// when the motion ends.
@MainActor
public enum EditorBlurMotion {
    private static var holds = 0
    private static let backdrops = NSHashTable<EditorBlurBackdrop>.weakObjects()

    /// Whether the bars hold their image (an inspector slide runs; a live
    /// resize holds its own window's bars).
    public static var isHolding: Bool { holds > 0 }

    static func register(_ b: EditorBlurBackdrop) { backdrops.add(b) }

    /// Starts a motion.
    public static func begin() { holds += 1 }

    /// Ends a motion: the bars render the content beneath them again.
    public static func end() {
        holds = max(0, holds - 1)
        guard holds == 0 else { return }
        for b in backdrops.allObjects { b.needsDisplay = true }
    }
}

/// The editor's bottom bar (the debug bar) over the text
/// (`liquid-glass.md` §7.4, §8.3; `fidelity-council.md` rows 5, 13): the
/// blurred veil, under a 1-point opaque separator.
public final class EditorBottomBarBackdrop: EditorBlurBackdrop {
    /// The separator's colour: #D7D7D7 on white (black at about 15.7 %),
    /// the system separator in dark.
    public static var separatorColor: NSColor {
        NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .separatorColor
                : NSColor.black.withAlphaComponent(CGFloat(EditorMetrics.bottomBarSeparatorInk))
        }
    }
    private let line = SeparatorLine()

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.autoresizingMask = [.width, .maxYMargin]
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        addSubview(line)
        // Below the separator, the bar's 12 % (liquid-glass.md §9.1).
        regions = { [weak self] in
            guard let self else { return [] }
            return [(NSRect(x: 0, y: 1, width: self.bounds.width, height: max(0, self.bounds.height - 1)), CGFloat(BarBlur.bottomBarShare))]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func themeChanged() {
        super.themeChanged()
        line.needsDisplay = true
    }

    /// The opaque 1-point line at the bar's top.
    final class SeparatorLine: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            Theme.backgroundColor.setFill()
            bounds.fill(using: .copy)
            EditorBottomBarBackdrop.separatorColor.setFill()
            bounds.fill(using: .sourceOver)
        }
    }
}

/// The veil behind the toolbar band and the jump bar: from the editor's
/// top (under the toolbar) to the jump bar's separator. The toolbar band
/// and the jump bar are two smears, each with its own share (§9.1: two
/// distinct blurred smears at the top).
final class EditorBandBackdrop: EditorBlurBackdrop {
    /// Where the jump bar's band starts (the toolbar's bottom).
    var jumpBarTop: CGFloat = 0 { didSet { if oldValue != jumpBarTop { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        regions = { [weak self] in
            guard let self else { return [] }
            let top = min(self.jumpBarTop, self.bounds.height), sep = CGFloat(EditorMetrics.jumpBarSeparator)
            return [(NSRect(x: 0, y: 0, width: self.bounds.width, height: top), CGFloat(BarBlur.toolbarBandShare)),
                    (NSRect(x: 0, y: top, width: self.bounds.width, height: max(0, self.bounds.height - top - sep)), CGFloat(BarBlur.jumpBarShare))]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The sticky scope header (`editor-area.md` §C.3): the lines that open
/// the declarations enclosing the first visible line, each with its line
/// number in the gutter, in their syntax colours, on an 18-point pitch
/// below a 2-point pad; a 2-point separator below. It spans the gutter and
/// the text, not the minimap. No outline, no shadow.
final class ScopeHeaderView: NSView {
    /// The editor's scroll view: wheel events over this view scroll it.
    weak var scrollTarget: NSScrollView?
    override func scrollWheel(with event: NSEvent) {
        if let t = scrollTarget { t.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
    struct Row {
        var line: Int
        var text: NSAttributedString
    }
    private(set) var rows: [Row] = []
    var lineHeight: CGFloat = 18
    var codeColumn = CGFloat(EditorMetrics.codeColumn)
    var numberEnd = CGFloat(EditorMetrics.lineNumberEnd)
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
    /// The editor's scroll view: wheel events over this view scroll it.
    weak var scrollTarget: NSScrollView?
    override func scrollWheel(with event: NSEvent) {
        if let t = scrollTarget { t.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
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
    var textTopInset = CGFloat(EditorMetrics.firstLineInset)
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
    ///
    /// One bar per token (`editor-area.md` §D.6): a space or tab inside
    /// one of `tokens` (a comment, a string) does not break its bar, so a
    /// whole comment is one bar; anywhere else whitespace separates bars.
    /// Indentation and whitespace at a bar's end are never drawn.
    static func rows(of storage: NSAttributedString, columns: Int, tabWidth: Int, wraps: Bool, tokens: IndexSet = IndexSet()) -> [[Run]] {
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
            var leading = true
            func flush() { out.append(row); row = [] }
            while i < end {
                var range = NSRange()
                let color = (storage.attribute(.foregroundColor, at: i, effectiveRange: &range) as? NSColor) ?? Theme.textColor
                let runEnd = min(end, NSMaxRange(range))
                var open = false
                var runCol = 0
                var inkEnd = 0
                func closeRun() {
                    if open, inkEnd > runCol { row.append(Run(column: runCol, length: inkEnd - runCol, color: color)) }
                    open = false
                }
                while i < runEnd {
                    let c = ns.character(at: i)
                    if wraps, col >= cols {
                        closeRun()
                        flush()
                        col = min(indent, cols / 2)
                    }
                    if c == 32 || c == 9 {
                        if leading || !tokens.contains(i) { closeRun() }
                        col += c == 9 ? tabWidth - col % max(1, tabWidth) : 1
                    } else {
                        leading = false
                        if !open { open = true; runCol = col }
                        col += 1
                        inkEnd = col
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

    /// The characters inside tokens that may hold whitespace (comments,
    /// strings and the like), for `rows(of:…tokens:)`.
    static func tokenInteriors(_ tokens: [SyntaxToken]) -> IndexSet {
        var set = IndexSet()
        for t in tokens where t.length > 1 && t.kind != .identifier { set.insert(integersIn: t.location..<t.end) }
        return set
    }
}
