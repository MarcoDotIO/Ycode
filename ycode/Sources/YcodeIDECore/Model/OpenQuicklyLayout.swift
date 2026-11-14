import Foundation

/// Open Quickly's panel, field, separator and result rows
/// (`fidelity-council.md` round 9, row 215; `open-quickly.md`), shared by
/// the AppKit panel (`OpenQuicklyController`) and the Linux IDE's
/// (`OpenQuicklyPanel`), so both lay out and colour it the same.
/// Positions are in points from the panel's top left.
public enum OpenQuicklyLayout {
    // MARK: Panel

    /// 640 wide, centred on the window, its top 200 below the window's top.
    public static let width = 640.0
    public static let top = 200.0
    /// The panel's corners: the rows' radius plus their inset, so the
    /// corners are concentric (Liquid Glass; the reference's panel radius
    /// was not measured).
    public static var cornerRadius: Double { rowCornerRadius + rowInset }

    // MARK: Field

    /// The field's band above the separator.
    public static let headerHeight = 54.0
    /// The magnifier: 21 × 21, 21.5 from the panel's left, centred in the band.
    public static let magnifierSize = 21.0
    public static let magnifierX = 21.5
    /// The query's first ink, aligned with the results' names.
    public static let queryX = 66.5
    /// The query's type (cap height about 16.5).
    public static let queryFontSize = 22.0
    public static let placeholder = "Open Quickly"

    // MARK: Separator

    /// A 1-point line at the band's bottom, inset 20 at each side.
    public static let separatorInset = 20.0
    public static let separatorHeight = 1.0

    // MARK: Rows

    /// 620 × 56 (the panel's width less 10 at each side), 10 below the
    /// separator, corner radius 22.
    public static let rowInset = 10.0
    public static let rowHeight = 56.0
    public static let rowCornerRadius = 22.0
    public static var rowWidth: Double { width - 2 * rowInset }
    /// The rows start this far below the panel's top.
    public static var rowsTop: Double { headerHeight + rowInset }
    /// The most rows shown before the list scrolls (Ycode's choice: the
    /// reference was captured with one result).
    public static let maximumVisibleRows = 8

    /// The result glyph's box, 13 from the row's left (x 403 in a panel at 380).
    public static let glyphX = 13.0
    public static let glyphSize = (width: 24.5, height: 20.5)
    /// The name, 56 from the row's left (66 from the panel's), level with the query.
    public static var nameX: Double { queryX - 0.5 - rowInset }
    /// The name (round 10, row 242): 17 points, bold, its baseline 23
    /// below the row's top (its capitals' top about 10.5 below it).
    public static let nameFontSize = 17.0
    public static let nameBaseline = 23.0
    /// The second line: a 12 × 12 project glyph, 4 before the group path in
    /// 15-point regular type whose baseline is 44.5 below the row's top.
    public static let breadcrumbGlyphSize = 12.0
    public static let breadcrumbGap = 4.0
    public static let breadcrumbFontSize = 15.0
    public static let breadcrumbBaseline = 44.5
    /// The glyph's centre below the row's top (the middle of the line's
    /// ascenders, 11 above the baseline).
    public static let breadcrumbGlyphCenter = 39.0
    /// Between two groups of the path: a thin tall chevron 3 × 14 (a
    /// 1-point stroke), its centre 38 below the row's top, 7 of space at
    /// each side.
    public static let breadcrumbChevronWidth = 3.0
    public static let breadcrumbChevronHeight = 14.0
    public static let breadcrumbChevronStroke = 1.0
    public static let breadcrumbChevronCenter = 38.0
    public static let breadcrumbChevronGap = 7.0

    /// The panel's height for `results` rows: the field's band alone with
    /// none, else the band, the rows (at most `maximumVisibleRows`) and 10
    /// below them (130 for one, as the reference's).
    public static func height(results: Int) -> Double {
        guard results > 0 else { return headerHeight }
        return rowsTop + Double(min(results, maximumVisibleRows)) * rowHeight + rowInset
    }

    /// The breadcrumb under a file's name: its groups, outermost first, joined by "›"
    /// (its text; each IDE draws the separator as the thin chevron).
    public static func breadcrumb(_ groupPath: [String]) -> String { groupPath.joined(separator: " \u{203A} ") }

    /// The breadcrumb's pieces from the text's start: each group's x, and
    /// each chevron's x (its ink's left), for the groups' widths.
    public static func breadcrumbLayout(widths: [Double]) -> (groups: [Double], chevrons: [Double]) {
        var x = 0.0, groups: [Double] = [], chevrons: [Double] = []
        for (i, w) in widths.enumerated() {
            if i > 0 {
                x += breadcrumbChevronGap
                chevrons.append(x)
                x += breadcrumbChevronWidth + breadcrumbChevronGap
            }
            groups.append(x)
            x += w
        }
        return (groups, chevrons)
    }

    /// A file name split for drawing: the name, and its extension with the dot (dimmed).
    public static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    // MARK: Colours (0xRRGGBB, light / dark)

    /// The selected row: #0064E1 / #0059D1.
    public static func selection(dark: Bool) -> UInt32 { dark ? 0x0059D1 : 0x0064E1 }
    /// The separator: #E4E4E4 / #525252.
    public static func separator(dark: Bool) -> UInt32 { dark ? 0x525252 : 0xE4E4E4 }
    /// The magnifier: #7D7D7D in light (dark: Ycode's, the secondary grey).
    public static func magnifier(dark: Bool) -> UInt32 { dark ? 0x9A9A9A : 0x7D7D7D }
    /// The query: #262626 in light (dark: the label colour).
    public static func query(dark: Bool) -> UInt32 { dark ? 0xDFDFDF : 0x262626 }
    /// The selected row's extension: white at this opacity (#BFD8F8 on #0064E1).
    public static let selectedExtensionOpacity = 0.75

    // MARK: File glyphs (row 211)

    /// A file result's glyph: the navigator's glyph (`FileGlyphs`) fitted
    /// to the 24.5 × 20.5 box (nil: a file Ycode shows with a symbol).
    public static func fileGlyph(_ fileName: String) -> GlyphDrawing? {
        let icon = NavigatorRowIcon.ofFile(fileName)
        return icon.isGlyph ? FileGlyphs.drawing(icon, in: FileGlyphs.openQuicklyBox) : nil
    }

    /// A file result's glyph colour: white on the selected row (#FFFFFF on
    /// #0064E1 / #0059D1), else its type's tint (nil: the accent colour).
    public static func fileGlyphColor(_ fileName: String, selected: Bool) -> GlyphColor? {
        if selected { return GlyphColor(FileGlyphs.selectedWhite, FileGlyphs.selectedWhite) }
        return FileGlyphs.tint(WorkspaceChrome.iconTint(kind: .file, name: fileName))
    }
}
