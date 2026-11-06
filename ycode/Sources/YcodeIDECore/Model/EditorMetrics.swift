import Foundation

/// The source editor's measured geometry (`specs/ide/editor-area.md`
/// §C.1–§C.5, §C.7; `fidelity-council.md` rows 4, 7, 8, 9, 21, 27). Every
/// position is relative to the editor's left edge or its content top, so
/// it holds at any window size.
public enum EditorMetrics {
    // MARK: Text (§C.1)

    /// The font size the measurements were taken at.
    public static let referenceFontSize = 13.0
    /// Line pitch at the reference size: 18 for 13 points, the same for
    /// wrapped continuation lines.
    public static func lineHeight(fontSize: Double) -> Double { (fontSize * 18 / referenceFontSize).rounded() }
    /// A character's advance: the font's own, rounded to whole points
    /// (8.0 at 13 points; 58 columns span 464 with no drift).
    public static func advance(fontAdvance: Double) -> Double { max(1, fontAdvance.rounded()) }
    /// The code column: the editor's left edge plus 51.
    public static let codeColumn = 51.0
    /// The first line's top below the content top (under the jump bar).
    public static let firstLineInset = 7.0
    /// The text container ends this far before the minimap's separator.
    public static let textToMinimap = 10.0
    /// Wrapped lines continue this many columns past the line's own
    /// indentation.
    public static let wrappedIndentColumns = 4

    /// The indentation, in columns, of a wrapped line's continuation:
    /// the line's leading whitespace (tabs to the next tab stop) plus
    /// `extra` columns.
    public static func wrappedIndent(of line: Substring, tabWidth: Int, extra: Int = wrappedIndentColumns) -> Int {
        var col = 0
        for ch in line {
            if ch == " " { col += 1 } else if ch == "\t" { col += tabWidth - col % max(1, tabWidth) } else { break }
        }
        return col + extra
    }

    // MARK: Gutter (§C.2)

    /// Line numbers end here (right-aligned), 12 before the code column.
    public static let lineNumberEnd = 38.0
    /// The current-line band starts here and ends at the text container's
    /// end; it is one line pitch tall with corners of about 4.
    public static let currentLineBandStart = 14.0
    public static let currentLineBandRadius = 4.0
    /// The line-number face relative to the source font: digits about 9
    /// points of ink against the code's 10, stepping about 6 points.
    public static func lineNumberFontSize(sourceSize: Double) -> Double { (sourceSize * 11 / referenceFontSize).rounded() }

    // MARK: Sticky scope header (§C.3)

    /// Room above the header's first row, and its separator below.
    public static let stickyHeaderTopPad = 2.0
    public static let stickyHeaderSeparator = 2.0
    /// The header's height for `rows` rows.
    public static func stickyHeaderHeight(rows: Int, lineHeight: Double) -> Double {
        rows > 0 ? stickyHeaderTopPad + lineHeight * Double(rows) : 0
    }

    // MARK: Bars

    /// The jump bar band (y 52–83 under a 52-point toolbar) and its
    /// separator (y 84–85).
    public static let jumpBarBand = 32.0
    public static let jumpBarSeparator = 2.0
    /// How much of the content beneath shows through the toolbar band,
    /// jump bar, sticky header and bottom bar (`liquid-glass.md` §7.3): a
    /// faint veil with no fade below any bar. The reference's veil changes
    /// no pixel by more than 7–8 levels of 255; a black glyph pixel under
    /// this fill changes by about 8.
    public static let barVeil = 0.035
    /// Active window (`liquid-glass.md` §8.3): the jump bar's band lays this
    /// much of the editor's background over the blurred material, so it
    /// passes about 8.5 % of the content where the toolbar band passes the
    /// material's own (the bottom bar's 12 %).
    public static let jumpBarOverBlur = 0.3
    /// The bottom bar's 1-point separator: black at this strength over the
    /// editor's background (#D7D7D7 on white, `liquid-glass.md` §7.4).
    public static let bottomBarSeparatorInk = 0.157

    // MARK: Minimap (§C.5)

    /// The minimap's width (its separator not included): 15 % of the
    /// editor (127 in an 850-point editor, 63 in a 424-point split), never
    /// under 59 nor over 135 (`editor-area.md` E.6, checklist row 77: from
    /// the separator to the scroll lane, which starts 3 points into the
    /// scroll bar, that is 63 to 139, the reference's floor and ceiling).
    public static let minimapWidthRange = 59.0...135.0
    public static func minimapWidth(editorWidth: Double) -> Double {
        guard editorWidth > 0 else { return 0 }
        return min(minimapWidthRange.upperBound, max(minimapWidthRange.lowerBound, (editorWidth * 0.15).rounded(.down)))
    }
    public static let minimapSeparator = 1.0
    /// Text at 1/6 scale: a 2-point bar on a 3-point pitch per visual line.
    public static let minimapScale = 1.0 / 6
    public static let minimapBarHeight = 2.0
    public static let minimapLinePitch = 3.0
    /// Column 0 sits this far inside the minimap's left edge.
    public static let minimapTextInset = 14.0
    /// Bars take their token's colour at about this strength.
    public static let minimapInk = 0.35

    /// The minimap's vertical offset when its content (`contentHeight`)
    /// is taller than the view (`viewHeight`): it scrolls in proportion
    /// to the editor (`fraction` 0 at the top, 1 at the end).
    public static func minimapOffset(contentHeight: Double, viewHeight: Double, fraction: Double) -> Double {
        guard contentHeight > viewHeight else { return 0 }
        return (contentHeight - viewHeight) * min(1, max(0, fraction))
    }

    // MARK: Inspector show and hide (§C.7)

    /// About 215 ms of motion (205–225 from the last still frame to the
    /// first final one): the table's end.
    public static let inspectorSlideDuration = 0.225
    /// The best cubic fit of the measured progress table.
    public static let inspectorSlideCurve = (x1: 0.8, y1: 0.4, x2: 0.65, y2: 1.0)
    /// The measured progress (ms from the last still frame, fraction of the
    /// travel). The recorder's last point (237 ms) is a frame after the
    /// motion ended; the slide ends at 225.
    public static let inspectorSlideTable: [(ms: Double, progress: Double)] = [
        (0, 0), (21, 0.01), (41, 0.05), (63, 0.17), (86, 0.25), (108, 0.31), (127, 0.47),
        (147, 0.58), (165, 0.74), (183, 0.92), (202, 0.97), (221, 0.98), (225, 1),
    ]

    // Round 2 (`editor-area.md` §D.5, key window, Long.swift open): this
    // supersedes the duration and curve above.

    /// From the press to the first motion: hide 43 ms, show 118 ms.
    public static func inspectorSlideDelay(show: Bool) -> Double { show ? 0.118 : 0.043 }
    /// The motion with fitted ends: hide 248 ms, show 240 ms.
    public static func inspectorSlideMotion(show: Bool) -> Double { show ? 0.240 : 0.248 }
    /// Ease-in-out, the working curve for both.
    public static let inspectorSlideEaseInOut = (x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)

    /// The slide's progress `elapsed` seconds after the press.
    public static func inspectorSlideProgress(elapsed: Double, show: Bool) -> Double {
        let t = (elapsed - inspectorSlideDelay(show: show)) / inspectorSlideMotion(show: show)
        let c = inspectorSlideEaseInOut
        return cubicBezier(t, x1: c.x1, y1: c.y1, x2: c.x2, y2: c.y2)
    }
    /// The whole slide from the press.
    public static func inspectorSlideTotal(show: Bool) -> Double { inspectorSlideDelay(show: show) + inspectorSlideMotion(show: show) }

    /// The slide's progress at `t` (0–1 of the duration): the measured
    /// table, interpolated (`editor-area.md` §C.7: "implement the table").
    public static func inspectorSlideProgress(_ t: Double) -> Double {
        let ms = min(1, max(0, t)) * inspectorSlideDuration * 1000
        let table = inspectorSlideTable
        guard let i = table.firstIndex(where: { $0.ms >= ms }) else { return 1 }
        if i == 0 { return table[0].progress }
        let a = table[i - 1], b = table[i]
        return a.progress + (b.progress - a.progress) * (ms - a.ms) / max(1e-9, b.ms - a.ms)
    }

    /// The same curve as a cubic Bézier, the table's best fit.
    public static func inspectorSlideBezierProgress(_ t: Double) -> Double {
        let c = inspectorSlideCurve
        return cubicBezier(t, x1: c.x1, y1: c.y1, x2: c.x2, y2: c.y2)
    }

    /// y for x on a CSS-style cubic Bézier through (0,0) and (1,1).
    public static func cubicBezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if bez(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return bez(t, y1, y2)
    }
}
