import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// A project navigator row's icon in the Linux IDE (council round 9, rows
/// 208–213; `FileGlyphs`): Ycode's outlines of the languages' line-art
/// logos, its JSON glyph and its folder, filled in the row's tint (white
/// on a focused selection, the unfocused tint on a selected row without
/// focus), the Ycode mark's small master on the project's row, or the
/// row's symbol as before. The macOS IDE draws the same outlines
/// (`YcodeUI/Navigator/NavigatorRowIcons.swift`).
struct NavigatorRowIconView: View {
    var row: OutlineRow
    var tint: Color
    /// The row is selected without focus (the type's unfocused tint).
    var unfocusedSelection = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch row.icon {
        case let icon? where icon.isGlyph:
            if let d = FileGlyphs.navigatorDrawing(icon) {
                // Centred 1.5 right of the 16-point frame's centre (x 62.75), as macOS
                // (a file at depth 2: x 55.5–70, row 208).
                FileGlyphView(drawing: d, color: color)
                    .offset(x: Self.glyphShift + Self.extraShift(icon))
                    .accessibilityLabel(FileGlyphView.description(icon))
                    .shellTarget("row glyph \(row.title)")
            }
        case .ycodeMark?:
            YcodeSmallMark(size: CGFloat(FileGlyphs.navigatorBox(.ycodeMark).width))
                .offset(x: Self.glyphShift)
                .shellTarget("row glyph \(row.title)")
        default:
            Image(systemName: row.symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
        }
    }

    /// From the frame's centre to the glyph's (macOS `glyphLeadOut`).
    static let glyphShift: CGFloat = 1.5

    /// The picture's box (14 wide, round 10, row 243) starts on x 56 at
    /// depth 2, where the macOS row's whole-point frame puts it.
    static func extraShift(_ icon: NavigatorRowIcon) -> CGFloat { icon == .image ? 0.5 : 0 }

    /// The tint, or the unfocused selection's tint for the row's type.
    private var color: Color {
        guard unfocusedSelection, case .icon(let t) = row.tint, let g = FileGlyphs.unfocusedSelectedTint(t) else { return tint }
        return FileGlyphView.color(g, dark: scheme == .dark)
    }
}

/// One of Ycode's glyphs (`GlyphDrawing`) filled and stroked in one colour,
/// in its own box.
struct FileGlyphView: View {
    var drawing: GlyphDrawing
    var color: Color
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Round 10 (rows 243, 244, 246): drawn on the window's pixel grid
        // from where the box lands (`FileGlyphs.pixelAligned`), as the
        // macOS IDE's `GlyphPixelGrid`.
        GeometryReader { g in
            let o = g.frame(in: .global).origin
            let d = FileGlyphs.pixelAligned(drawing, origin: (Double(o.x), Double(o.y)), scale: Double(displayScale))
            ZStack(alignment: .topLeading) {
                ForEach(Array(d.paths.enumerated()), id: \.offset) { pair in
                    let p = pair.element, path = Self.path(p)
                    if p.fills { path.fill(color, style: FillStyle(eoFill: p.evenOdd)) }
                    if p.strokeWidth > 0 {
                        path.stroke(color, style: StrokeStyle(lineWidth: CGFloat(p.strokeWidth), lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: CGFloat(drawing.width), height: CGFloat(drawing.height), alignment: .topLeading)
        }
        .frame(width: CGFloat(drawing.width), height: CGFloat(drawing.height), alignment: .topLeading)
    }

    static func path(_ p: GlyphPath) -> Path {
        var path = Path()
        for e in p.elements {
            switch e {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .curve(a, b, c, d, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func color(_ g: GlyphColor, dark: Bool) -> Color {
        let c = g.rgb(dark: dark)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    static func description(_ icon: NavigatorRowIcon) -> String {
        switch icon {
        case .logo(let name): name
        case .json: "JSON"
        case .markdown: "Markdown"
        case .folder: "folder"
        case .ycodeMark: "Ycode project"
        case .image: "image"
        case .symbol(let s): s
        }
    }
}

/// A file's glyph wherever a file is listed (the jump bar, the merge
/// sheet, Open Quickly; council round 9, row 211): its line-art logo or
/// Ycode's JSON glyph in `box` points, in its type's tint (`tint` given:
/// that colour instead, white on a selection); a file without one its
/// symbol.
struct FileGlyphImage: View {
    var fileName: String
    var box: FileGlyphs.Size
    var tint: Color?
    /// The jump bar's tints (Markdown #5A8095 / #B7D5EB).
    var jumpBar = false
    var symbolSize: CGFloat = 11
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let icon = NavigatorRowIcon.ofFile(fileName)
        let t = WorkspaceChrome.iconTint(kind: .file, name: fileName)
        let g = jumpBar ? FileGlyphs.jumpBarTint(t) : FileGlyphs.tint(t)
        let c = tint ?? g.map { FileGlyphView.color($0, dark: scheme == .dark) } ?? ShellColors(scheme).accent
        let d = jumpBar && box == FileGlyphs.jumpBarBox(icon) ? FileGlyphs.jumpBarDrawing(icon) : FileGlyphs.drawing(icon, in: box)
        if icon.isGlyph, let d {
            FileGlyphView(drawing: d, color: c).accessibilityLabel(FileGlyphView.description(icon))
        } else {
            Image(systemName: WorkspaceChrome.fileSymbol(fileName)).font(.system(size: symbolSize)).foregroundStyle(c)
        }
    }
}

/// The app icon's small master (`ProductIconSmallGeometry`), as the macOS
/// navigator draws it.
struct YcodeSmallMark: View {
    var size: CGFloat

    var body: some View {
        typealias G = ProductIconSmallGeometry
        let k = size / CGFloat(G.side)
        func point(_ q: (Double, Double)) -> CGPoint { CGPoint(x: CGFloat(q.0) * k, y: CGFloat(q.1) * k) }
        func line(_ points: [(Double, Double)]) -> Path {
            var p = Path()
            p.move(to: point(points[0]))
            for q in points.dropFirst() { p.addLine(to: point(q)) }
            return p
        }
        let a = G.fieldMin, b = G.fieldMax, s = G.cornerStart, c = G.cornerControl
        var field = Path()
        field.move(to: point((a + s, a)))
        field.addLine(to: point((b - s, a)))
        field.addCurve(to: point((b, a + s)), control1: point((b - c, a)), control2: point((b, a + c)))
        field.addLine(to: point((b, b - s)))
        field.addCurve(to: point((b - s, b)), control1: point((b, b - c)), control2: point((b - c, b)))
        field.addLine(to: point((a + s, b)))
        field.addCurve(to: point((a, b - s)), control1: point((a + c, b)), control2: point((a, b - c)))
        field.addLine(to: point((a, a + s)))
        field.addCurve(to: point((a + s, a)), control1: point((a, a + c)), control2: point((a + c, a)))
        field.closeSubpath()
        let style = StrokeStyle(lineWidth: CGFloat(G.strokeWidth) * k, lineCap: .round, lineJoin: .round)
        return ZStack(alignment: .topLeading) {
            field.fill(LinearGradient(colors: [YcodeMark.color(G.fieldTop), YcodeMark.color(G.fieldBottom)], startPoint: .top, endPoint: .bottom))
            line(G.chevron).stroke(YcodeMark.color(G.chevronColor), style: style)
            line(G.caret).stroke(YcodeMark.color(G.caretColor), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Ycode project")
    }
}

/// A navigator selector glyph: Ycode's own drawing (`SelectorGlyphs`, row
/// 192) where it has one, else the symbol, as the macOS selector draws them.
struct SelectorGlyphView: View {
    var symbol: String
    var color: Color

    var body: some View {
        if let parts = SelectorGlyphs.parts(forSymbol: symbol) {
            let style = StrokeStyle(lineWidth: CGFloat(SelectorGlyphs.lineWidth), lineCap: .round, lineJoin: .round)
            ZStack(alignment: .topLeading) {
                ForEach(Array(parts.enumerated()), id: \.offset) { pair in
                    switch pair.element {
                    case let .roundedRect(x, y, w, h, r):
                        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: CGFloat(r)).stroke(color, style: style)
                    case let .lines(points, closed):
                        Path { p in
                            p.move(to: CGPoint(x: points[0].x, y: points[0].y))
                            for q in points.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
                            if closed { p.closeSubpath() }
                        }
                        .stroke(color, style: style)
                    case let .dot(x, y, r):
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill(color)
                    }
                }
            }
            .frame(width: CGFloat(SelectorGlyphs.width), height: CGFloat(SelectorGlyphs.height), alignment: .topLeading)
        } else {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(color)
        }
    }
}
