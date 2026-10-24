import AppKit
import YcodeBuild

/// The editor's left gutter: the source-control change column at its far
/// left (`reference-ui-5.md` §6.3), line numbers, breakpoints, issue marks,
/// the current-instruction marker, and a code-folding ribbon on its right
/// edge. See `specs/ide/source-editor.md` §Gutter.
@MainActor
public final class GutterView: NSRulerView, NSViewToolTipOwner {
    public struct Marks {
        public var breakpoints: [Int: Bool] = [:]   // line → enabled
        public var breakpointsActive = true
        /// Breakpoints with a condition, ignore count or actions.
        public var customized: Set<Int> = []
        public var issues: [Int: Diagnostic.Severity] = [:]
        public var currentLine: Int?
        /// Test lines: nil = not run yet.
        public var tests: [Int: TestStatusMark] = [:]
        /// Issue lines with a fix-it: a lightbulb replaces the issue dot.
        public var fixable: Set<Int> = []
        /// Issues from before the last edit: drawn grey (reference-ui-4.md §4).
        public var issuesStale = false
        /// Code Review change bars by line (reference-ui-4.md §15).
        public var changes: [Int: LineDiff.Row.Kind] = [:]
    }

    public enum TestStatusMark: Equatable { case notRun, passed, failed }

    public var marks = Marks() { didSet { needsDisplay = true } }
    public var showsLineNumbers = true { didSet { needsDisplay = true } }
    /// The insertion point's line: its number is drawn brighter.
    public var caretLine: Int? { didSet { if oldValue != caretLine { needsDisplay = true } } }
    public var lineIndex = LineIndex("") { didSet { needsDisplay = true } }
    public var onClick: ((Int) -> Void)?
    public var onMove: ((Int, Int) -> Void)?
    public var onRemove: ((Int) -> Void)?
    /// Double-click or ⌘-click on a breakpoint: edit it.
    public var onEdit: ((Int) -> Void)?
    /// A click on a test diamond (runs that test or class).
    public var onRunTest: ((Int) -> Void)?
    /// A click in the folding ribbon on a line.
    public var onRibbonClick: ((Int) -> Void)?
    /// A click on a fix-it lightbulb (applies the line's fix-it).
    public var onFixIt: ((Int) -> Void)?
    /// Fold starts: line → folded?
    public var foldStarts: [Int: Bool] = [:] { didSet { needsDisplay = true } }

    static let ribbonWidth: CGFloat = 12
    /// The change column (§6.3.1): 11 pt, left of the line numbers.
    public static let changeColumnWidth: CGFloat = 11
    static let baseThickness: CGFloat = 48

    /// Shown while the file is in a git working copy (§6.3.1).
    public var showsChangeColumn = false {
        didSet {
            guard oldValue != showsChangeColumn else { return }
            ruleThickness = Self.baseThickness + leftInset
            updateChangeToolTips()
            needsDisplay = true
        }
    }
    /// The change regions against the index and HEAD (§6.3.2).
    public var changeRegions: [SourceChangeRegion] = [] {
        didSet {
            guard oldValue != changeRegions else { return }
            updateChangeToolTips()
            needsDisplay = true
        }
    }
    /// A click on a change bar (the line clicked).
    public var onChangeClick: ((Int) -> Void)?
    /// Everything right of the change column starts here.
    var leftInset: CGFloat { showsChangeColumn ? Self.changeColumnWidth : 0 }
    /// Settings ▸ Text Editing ▸ Code folding ribbon.
    public var showsRibbon = true { didSet { needsDisplay = true } }
    private var textView: NSTextView? { clientView as? NSTextView }

    public init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.baseThickness
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// (line, y-range in gutter coordinates) for each laid-out line in view.
    func visibleLines() -> [(line: Int, rect: NSRect)] {
        guard let tv = textView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return [] }
        var out: [(Int, NSRect)] = []
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            if frame.maxY >= visible.minY {
                let offset = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
                let first = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
                let r = NSRect(x: 0, y: frame.minY + origin.y, width: 0, height: first)
                let inGutter = self.convert(r, from: tv)
                out.append((self.lineIndex.line(at: offset), inGutter))
            }
            return true
        }
        // An empty last line has no fragment of its own; draw its number too.
        return out
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let numberWidth = ruleThickness - Self.ribbonWidth
        // Folding ribbon (not drawn when the ribbon is off, reference-ui.md §3).
        if showsRibbon {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
            NSRect(x: numberWidth, y: bounds.minY, width: Self.ribbonWidth, height: bounds.height).fill()
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor]
        let inset = leftInset
        let rows = visibleLines()
        if showsChangeColumn { drawChangeBars(rows) }
        for (line, r) in rows {
            let row = NSRect(x: 2 + inset, y: r.minY, width: numberWidth - 3 - inset, height: max(r.height, 14))
            if let enabled = marks.breakpoints[line] {
                drawBreakpoint(in: row, enabled: enabled && marks.breakpointsActive, customized: marks.customized.contains(line))
            }
            if line == marks.currentLine {
                Theme.currentLineColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(rect: NSRect(x: inset, y: row.minY, width: 3, height: row.height)).fill()
            }
            if showsLineNumbers {
                let isBP = marks.breakpoints[line] != nil
                var a = attrs
                if isBP { a[.foregroundColor] = NSColor.white } else if line == caretLine { a[.foregroundColor] = NSColor.labelColor }
                let s = NSAttributedString(string: "\(line)", attributes: a)
                let size = s.size()
                s.draw(at: NSPoint(x: numberWidth - 8 - size.width, y: row.minY + (row.height - size.height) / 2))
            }
            if let t = marks.tests[line] {
                drawTestDiamond(t, at: NSPoint(x: 14 + inset, y: row.midY))
            }
            if showsRibbon, let folded = foldStarts[line] {
                drawFoldMark(folded: folded, at: NSPoint(x: numberWidth + Self.ribbonWidth / 2, y: row.midY))
            }
            if let k = marks.changes[line] {
                (k == .added ? NSColor.systemGreen : (k == .removed ? NSColor.systemRed : NSColor.systemBlue)).setFill()
                NSRect(x: bounds.width - 3, y: k == .removed ? row.minY - 1 : row.minY, width: 3, height: k == .removed ? 3 : row.height).fill()
            }
            if let sev = marks.issues[line] {
                let color = InlineIssueLayout.color(sev, stale: marks.issuesStale)
                if marks.fixable.contains(line), let bulb = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Fix-it") {
                    let tinted = bulb.withSymbolConfiguration(.init(paletteColors: [color])) ?? bulb
                    tinted.draw(in: NSRect(x: 1 + inset, y: row.midY - 6, width: 12, height: 12))
                } else {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 4 + inset, y: row.midY - 3, width: 6, height: 6)).fill()
                }
            }
        }
    }

    /// The breakpoint shape: a tag pointing right, filled when enabled and
    /// pale when disabled or when breakpoints are deactivated.
    private func drawBreakpoint(in row: NSRect, enabled: Bool, customized: Bool = false) {
        let r = row.insetBy(dx: 0, dy: 1)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - 6, y: r.minY))
        p.line(to: NSPoint(x: r.maxX, y: r.midY))
        p.line(to: NSPoint(x: r.maxX - 6, y: r.maxY))
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        let base = customized ? (Theme.breakpointColor.blended(withFraction: 0.35, of: .black) ?? Theme.breakpointColor) : Theme.breakpointColor
        base.withAlphaComponent(enabled ? 1 : 0.35).setFill()
        p.fill()
    }

    /// A disclosure triangle in the ribbon: pointing right when folded,
    /// down when open.
    private func drawFoldMark(folded: Bool, at c: NSPoint) {
        let p = NSBezierPath()
        if folded {
            p.move(to: NSPoint(x: c.x - 2.5, y: c.y - 4)); p.line(to: NSPoint(x: c.x + 3, y: c.y)); p.line(to: NSPoint(x: c.x - 2.5, y: c.y + 4))
        } else {
            p.move(to: NSPoint(x: c.x - 4, y: c.y - 2.5)); p.line(to: NSPoint(x: c.x + 4, y: c.y - 2.5)); p.line(to: NSPoint(x: c.x, y: c.y + 3))
        }
        p.close()
        (folded ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
        p.fill()
    }

    /// A test diamond left of the line number: outlined when not run, green when
    /// passed, red when failed.
    private func drawTestDiamond(_ t: TestStatusMark, at c: NSPoint) {
        let r: CGFloat = 4.5
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y - r))
        p.line(to: NSPoint(x: c.x + r, y: c.y))
        p.line(to: NSPoint(x: c.x, y: c.y + r))
        p.line(to: NSPoint(x: c.x - r, y: c.y))
        p.close()
        switch t {
        case .notRun:
            NSColor.secondaryLabelColor.setStroke()
            p.stroke()
        case .passed:
            NSColor.systemGreen.setFill()
            p.fill()
        case .failed:
            NSColor.systemRed.setFill()
            p.fill()
        }
    }

    func line(atGutterY y: CGFloat) -> Int? {
        let lines = visibleLines()
        if let hit = lines.first(where: { y >= $0.rect.minY && y < $0.rect.minY + max($0.rect.height, 14) }) { return hit.line }
        // Below the last line: none.
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let line = line(atGutterY: start.y) else { return }
        if showsChangeColumn, start.x < leftInset {
            if changeRegion(atLine: line) != nil { onChangeClick?(line) }
            return
        }
        let x = start.x - leftInset
        if showsRibbon, x >= ruleThickness - leftInset - Self.ribbonWidth {
            onRibbonClick?(line)
            return
        }
        if marks.fixable.contains(line), x < 14 {
            onFixIt?(line)
            return
        }
        if marks.tests[line] != nil, x >= 7, x <= 21 {
            onRunTest?(line)
            return
        }
        let hadBreakpoint = marks.breakpoints[line] != nil
        if hadBreakpoint && (event.clickCount >= 2 || event.modifierFlags.contains(.command)) {
            onEdit?(line)
            return
        }
        var dragged = false
        var outside = false
        var target = line
        // Track until mouse up: drag along the gutter moves, drag out deletes.
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(e.locationInWindow, from: nil)
            if e.type == .leftMouseUp { break }
            dragged = dragged || hypot(p.x - start.x, p.y - start.y) > 3
            outside = !bounds.insetBy(dx: -20, dy: -20).contains(p) || p.x > bounds.maxX + 10
            if let l = self.line(atGutterY: p.y) { target = l }
        }
        if hadBreakpoint && dragged && outside { onRemove?(line) }
        else if hadBreakpoint && dragged && target != line { onMove?(line, target) }
        else if !dragged { onClick?(line) }
    }
}

// MARK: Change column (reference-ui-5.md §6.3)

extension GutterView {
    /// The region whose bar is on `line` (a deletion's bar sits at the top
    /// of the line it precedes).
    public func changeRegion(atLine line: Int) -> SourceChangeRegion? {
        changeRegions.first { $0.contains(line: line) }
    }

    /// The bar rectangles, in gutter coordinates, for the given rows.
    func changeBarRects(_ rows: [(line: Int, rect: NSRect)]) -> [(SourceChangeRegion, NSRect)] {
        var out: [(SourceChangeRegion, NSRect)] = []
        let x: CGFloat = 3, w: CGFloat = 5
        for region in changeRegions {
            let covered = rows.filter { region.contains(line: $0.line) }
            if region.kind == .deleted {
                // A short mark between the lines: at the top of the line it
                // precedes, or under the last line for a deletion at the end.
                if let r = rows.first(where: { $0.line == region.firstLine }) {
                    out.append((region, NSRect(x: x - 1, y: r.rect.minY - 2, width: w + 2, height: 4)))
                } else if let last = rows.last, region.firstLine == last.line + 1 {
                    out.append((region, NSRect(x: x - 1, y: last.rect.minY + max(last.rect.height, 14) - 2, width: w + 2, height: 4)))
                }
                continue
            }
            guard let top = covered.first, let bottom = covered.last else { continue }
            let maxY = bottom.rect.minY + max(bottom.rect.height, 14)
            out.append((region, NSRect(x: x, y: top.rect.minY, width: w, height: maxY - top.rect.minY)))
        }
        return out
    }

    func drawChangeBars(_ rows: [(line: Int, rect: NSRect)]) {
        for (region, rect) in changeBarRects(rows) {
            (region.staged ? NSColor.secondaryLabelColor : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// The change column's tooltip at a point: the kind of the bar there.
    public func changeToolTip(atGutterY y: CGFloat) -> String? {
        guard showsChangeColumn else { return nil }
        if let hit = changeBarRects(visibleLines()).first(where: { y >= $0.1.minY - 1 && y <= $0.1.maxY + 1 }) { return hit.0.toolTip }
        return line(atGutterY: y).flatMap(changeRegion(atLine:))?.toolTip
    }

    func updateChangeToolTips() {
        removeAllToolTips()
        guard showsChangeColumn else { return }
        addToolTip(NSRect(x: 0, y: -100_000, width: Self.changeColumnWidth, height: 200_000), owner: self, userData: nil)
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        changeToolTip(atGutterY: point.y) ?? ""
    }

    /// One accessibility element per bar, described as in §6.3.3.
    public var changeBarDescriptions: [String] { changeRegions.map(\.accessibilityDescription) }

    public override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard showsChangeColumn else { return children }
        let rows = visibleLines()
        for (region, rect) in changeBarRects(rows) {
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.image)
            e.setAccessibilityLabel(region.accessibilityDescription)
            e.setAccessibilityHelp(region.toolTip)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(rect)
            children.append(e)
        }
        return children
    }
}
