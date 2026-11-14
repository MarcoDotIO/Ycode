import Foundation

/// A colour in light and dark, as 0xRRGGBB.
public struct GlyphColor: Equatable, Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32
    public init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
    public func hex(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
    /// The red, green and blue components (0…1) in an appearance.
    public func rgb(dark isDark: Bool) -> (red: Double, green: Double, blue: Double) {
        let v = hex(dark: isDark)
        return (Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
    }
}

/// One step of a glyph's outline (points, y down).
public enum GlyphElement: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
    case close
}

/// One path of a glyph: filled (by the non-zero or the even-odd rule),
/// stroked with round caps and joins, or both.
public struct GlyphPath: Equatable, Sendable {
    public var elements: [GlyphElement]
    public var evenOdd = false
    public var fills = true
    /// The stroke's width in points (0: no stroke).
    public var strokeWidth = 0.0

    public init(_ elements: [GlyphElement], evenOdd: Bool = false, fills: Bool = true, strokeWidth: Double = 0) {
        self.elements = elements
        self.evenOdd = evenOdd
        self.fills = fills
        self.strokeWidth = strokeWidth
    }

    /// The path scaled by `k` and moved by `dx`, `dy` (the stroke scaled too).
    public func transformed(scale k: Double, dx: Double, dy: Double) -> GlyphPath {
        var p = self
        p.elements = elements.map { e in
            switch e {
            case let .move(x, y): .move(x * k + dx, y * k + dy)
            case let .line(x, y): .line(x * k + dx, y * k + dy)
            case let .curve(a, b, c, d, x, y): .curve(a * k + dx, b * k + dy, c * k + dx, d * k + dy, x * k + dx, y * k + dy)
            case .close: .close
            }
        }
        p.strokeWidth *= k
        return p
    }
}

/// A glyph laid out in its box: paths in points from the box's top left,
/// y down. Both IDEs fill and stroke these paths in one colour (the
/// type's tint, white on a focused selection).
public struct GlyphDrawing: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var paths: [GlyphPath]

    /// The ink's extent (curves sampled; strokes counted at half their
    /// width outside the path).
    public var inkBox: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var b = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for p in paths {
            let h = p.strokeWidth / 2
            func add(_ x: Double, _ y: Double) {
                b.minX = min(b.minX, x - h); b.minY = min(b.minY, y - h); b.maxX = max(b.maxX, x + h); b.maxY = max(b.maxY, y + h)
            }
            var cur = (0.0, 0.0)
            for e in p.elements {
                switch e {
                case let .move(x, y), let .line(x, y): add(x, y); cur = (x, y)
                case let .curve(x1, y1, x2, y2, x, y):
                    for k in 0...16 {
                        let t = Double(k) / 16, u = 1 - t
                        add(u * u * u * cur.0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x,
                            u * u * u * cur.1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y)
                    }
                    cur = (x, y)
                case .close: break
                }
            }
        }
        return b
    }
}

/// The file glyphs wherever a file is listed (council round 9, rows 208–213;
/// the owner's rules 1–3 of 2026-11-13): the project navigator, the jump
/// bar's components, the merge sheet's file list and path, and Open
/// Quickly's results.
///
/// - A language file: its official logo as single-colour line art
///   (devicon v2.18.0's "plain" or "line" variant, `LanguageLogos`),
///   fitted to the reference's glyph box (14.5 × 12.5 in the navigator),
///   its thin "line" outlines thickened to the reference's 1.5-point stroke.
/// - JSON: Ycode's own glyph, an opening brace, a filled opening double
///   quote and a closing brace, 16.5 × 12, the braces 1.5-point strokes.
/// - Markdown: Ycode's own open book, 14.5 × 12, 1.5-point strokes.
/// - Swift: the bird alone (devicon's plain variant inverted); Python: the
///   outline of its plain shapes, 1.5-point strokes, no fill.
/// - A group or folder: Ycode's own filled folder, 14.5 × 12.
/// - The project: the small Ycode mark, 15 × 15 (the owner's decision of
///   2026-11-08); drawn by each IDE from `ProductIconSmallGeometry`.
///
/// Every glyph is drawn in one colour: its type's tint (`tint(_:)`), white
/// on a focused selected row, the unfocused tint on a selected row without
/// focus.
public enum FileGlyphs {
    public typealias Size = (width: Double, height: Double)

    /// The reference's stroke for line-art glyphs (a 3-pixel core at 2x).
    public static let lineWidth = 1.5

    // MARK: Boxes

    /// A glyph's box in the project navigator (and the merge sheet's list).
    public static func navigatorBox(_ icon: NavigatorRowIcon) -> Size {
        switch icon {
        case .json: (16.5, 12)
        case .markdown, .folder: (14.5, 12)
        case .ycodeMark: (15, 15)
        case .image: (14, 12)
        case .logo, .symbol: (14.5, 12.5)
        }
    }

    /// A glyph's box in the jump bar (the same glyph, smaller): Markdown
    /// 13 × 10.5 and JSON 14 × 10, each its own drawing (round 10, row 246,
    /// `jumpBarDrawing`), other files the path's 11.5 of ink, a folder
    /// 12.5 wide, the project 13.
    public static func jumpBarBox(_ icon: NavigatorRowIcon) -> Size {
        switch icon {
        case .json: (14, 10)
        case .markdown: (13, 10.5)
        case .logo, .symbol, .image: (11.5, 11.5)
        case .folder: (12.5, 12.5 * 12 / 14.5)
        case .ycodeMark: (13, 13)
        }
    }

    /// Open Quickly's result glyph (reference: 24.5 × 20.5).
    public static let openQuicklyBox: Size = (24.5, 20.5)

    /// The title area's icon: the Ycode mark in a 19.5-point box; the
    /// build ring 19 across (its ink) with a 2.5-point stroke and round
    /// caps (rows 212, 236), filled to the build's n/m
    /// (`BuildRingProgress`).
    public static let titleMarkSide = 19.5
    public static let buildRingDiameter = 19.0
    public static let buildRingStroke = 2.5
    /// The ring's track and arc in light (#E6E6E6, #007AFF); dark: the
    /// system's track (white at 15 %) and accent (#0A84FF).
    public static let buildRingTrack = GlyphColor(0xE6E6E6, 0x3A3A3C)
    public static let buildRingArc = GlyphColor(0x007AFF, 0x0A84FF)

    // MARK: Drawings

    /// The glyph of an icon laid out in `box` (nil: a symbol or the Ycode
    /// mark, which each IDE draws itself).
    public static func drawing(_ icon: NavigatorRowIcon, in box: Size) -> GlyphDrawing? {
        switch icon {
        case .logo(let name): logo(name, in: box)
        case .json: fitted(json, in: box)
        case .markdown: fitted(book, in: box)
        case .image: fitted(picture, in: box)
        case .folder: fitted(folder, in: box)
        case .ycodeMark, .symbol: nil
        }
    }

    /// The glyph in the navigator's box.
    public static func navigatorDrawing(_ icon: NavigatorRowIcon) -> GlyphDrawing? { drawing(icon, in: navigatorBox(icon)) }

    /// A drawing scaled uniformly to fit `box`, centred in it.
    public static func fitted(_ d: GlyphDrawing, in box: Size) -> GlyphDrawing {
        let k = min(box.width / d.width, box.height / d.height)
        let dx = (box.width - d.width * k) / 2, dy = (box.height - d.height * k) / 2
        return GlyphDrawing(width: box.width, height: box.height, paths: d.paths.map { $0.transformed(scale: k, dx: dx, dy: dy) })
    }

    /// A logo's outline fitted to `box`: filled, and its "line" outlines
    /// also stroked so their bands are about 1.5 points at the navigator's
    /// size (the stroke's half-width kept inside the box); an outline-only
    /// logo (Python) stroked 1.5 and not filled.
    public static func logo(_ name: String, in box: Size) -> GlyphDrawing? {
        guard let o = LanguageLogos.outline(name) else { return nil }
        let outlineOnly = LanguageLogos.outlineOnly.contains(name)
        let boost = outlineOnly ? lineWidth : LanguageLogos.strokeBoost[name] ?? 0
        // The boost scales with the glyph (it is set for the navigator's box).
        let scale = min(box.width, box.height) / min(navigatorBox(.logo(name)).width, navigatorBox(.logo(name)).height)
        let s = boost * scale
        let inner = (width: max(1, box.width - s), height: max(1, box.height - s))
        let k = min(inner.width / o.width, inner.height / o.height)
        let dx = (box.width - o.width * k) / 2, dy = (box.height - o.height * k) / 2
        let paths = o.paths.map { p -> GlyphPath in
            var q = GlyphPath(p.elements, evenOdd: p.evenOdd, fills: !outlineOnly).transformed(scale: k, dx: dx, dy: dy)
            q.strokeWidth = s
            return q
        }
        return GlyphDrawing(width: box.width, height: box.height, paths: paths)
    }

    /// Ycode's JSON glyph in its own 16.5 × 12 box: two braces (1.5-point
    /// strokes) round a filled opening double quote, two "6"-shaped
    /// commas side by side, each about 2.6 × 3.2.
    public static let json: GlyphDrawing = {
        let w = 16.5, h = 12.0, t = lineWidth, half = t / 2
        // The left brace, its ink from x 0 to 4.4: arms out to x 4.4, the
        // point at x 0 on the middle line.
        func brace(_ m: (Double) -> Double) -> GlyphPath {
            let top = half, bottom = h - half, mid = h / 2
            let tip = m(half), stem = m(2.35), arm = m(4.4 - half)
            return GlyphPath([
                .move(arm, top),
                .curve(m(3.0), top, stem, top + 0.35, stem, top + 1.6),
                .line(stem, mid - 1.6),
                .curve(stem, mid - 0.55, m(1.6), mid, tip, mid),
                .curve(m(1.6), mid, stem, mid + 0.55, stem, mid + 1.6),
                .line(stem, bottom - 1.6),
                .curve(stem, bottom - 0.35, m(3.0), bottom, arm, bottom),
            ], fills: false, strokeWidth: t)
        }
        // A "6": a round dot with a tail rising to the upper right.
        func comma(_ x: Double, _ y: Double) -> [GlyphPath] {
            let r = 1.22, cx = x + 1.3, cy = y + 3.2 - r, c = 0.5523 * r
            let dot = GlyphPath([
                .move(cx + r, cy),
                .curve(cx + r, cy + c, cx + c, cy + r, cx, cy + r),
                .curve(cx - c, cy + r, cx - r, cy + c, cx - r, cy),
                .curve(cx - r, cy - c, cx - c, cy - r, cx, cy - r),
                .curve(cx + c, cy - r, cx + r, cy - c, cx + r, cy),
                .close,
            ])
            let tail = GlyphPath([
                .move(cx - r, cy),
                .curve(cx - r, y + 1.0, x + 1.1, y, x + 2.6, y),
                .line(x + 2.6, y + 0.62),
                .curve(x + 1.75, y + 0.72, cx - 0.2, y + 1.25, cx - 0.1, cy - r + 0.1),
                .close,
            ])
            return [dot, tail]
        }
        let quoteTop = h / 2 - 2.0
        let paths = [brace { $0 }, brace { w - $0 }] + comma(w / 2 - 2.95, quoteTop) + comma(w / 2 + 0.35, quoteTop)
        return GlyphDrawing(width: w, height: h, paths: paths)
    }()

    /// Ycode's Markdown glyph in its own 14.5 × 12 box (the owner's
    /// decision of 2026-11-13; the reference's Markdown glyph is an open
    /// book in line art): two facing pages meeting at a spine, 1.5-point
    /// strokes, round joins. Each page rises from its outer edge to the
    /// spine along a slight curve, top and bottom; the spine is the line
    /// both pages share.
    public static let book: GlyphDrawing = {
        let w = 14.5, h = 12.0, t = lineWidth, half = t / 2
        let mid = w / 2
        func page(_ m: (Double) -> Double) -> GlyphPath {
            let outer = m(half), spineTop = 2.3, spineBottom = h - half, cornerTop = half + 0.15, cornerBottom = h - 1.85
            return GlyphPath([
                .move(m(mid), spineTop),
                .curve(m(mid - 1.7), spineTop - 1.25, m(mid - 4.2), cornerTop - 0.05, outer, cornerTop),
                .line(outer, cornerBottom),
                .curve(m(mid - 4.2), cornerBottom - 0.05, m(mid - 1.7), spineBottom - 1.0, m(mid), spineBottom),
                .close,
            ], fills: false, strokeWidth: t)
        }
        return GlyphDrawing(width: w, height: h, paths: [page { $0 }, page { w - $0 }])
    }()

    /// Ycode's filled folder in its own 14.5 × 12 box: the back with its
    /// tab, then the front panel 0.6 below it.
    public static let folder: GlyphDrawing = {
        let w = 14.5, h = 12.0, r = 1.4, c = 0.5523 * r
        let back = GlyphPath([
            .move(0, 1.2),
            .curve(0, 0.5, 0.5, 0, 1.2, 0),
            .line(4.9, 0),
            .curve(5.4, 0, 5.7, 0.15, 6.0, 0.5),
            .line(6.8, 1.4),
            .line(w - 1.2, 1.4),
            .curve(w - 0.5, 1.4, w, 1.9, w, 2.6),
            .line(0, 2.6),
            .close,
        ])
        let top = 3.2
        let front = GlyphPath([
            .move(r, top),
            .line(w - r, top),
            .curve(w - r + c, top, w, top + r - c, w, top + r),
            .line(w, h - r),
            .curve(w, h - r + c, w - r + c, h, w - r, h),
            .line(r, h),
            .curve(r - c, h, 0, h - r + c, 0, h - r),
            .line(0, top + r),
            .curve(0, top + r - c, r - c, top, r, top),
            .close,
        ])
        return GlyphDrawing(width: w, height: h, paths: [back, front])
    }()

    // MARK: Tints

    /// A row icon's tint (nil: the accent colour), the reference's
    /// measured flat ink per type (council round 9, the tint table): Swift
    /// #F77640 / #FFA54D, Python #EFBD00 / #FFF62A, Markdown #52788D /
    /// #CCEAFF, JSON #EE2C22 / #FF695E, images and the project #006BEF /
    /// #2DA7FF, synchronized folders #3FA1F6 / #5BC6FF, plain groups
    /// #7B7B80 / #B6B7BC. The other languages were not measured; each gets
    /// its logo's own colour family, light enough for the dark navigator.
    public static func tint(_ t: WorkspaceChrome.IconTint) -> GlyphColor? {
        switch t {
        case .orange: GlyphColor(0xF77640, 0xFFA54D)
        case .blue: GlyphColor(0x006BEF, 0x2DA7FF)
        case .lightBlue: GlyphColor(0x3FA1F6, 0x5BC6FF)
        case .grey: GlyphColor(0x7B7B80, 0xB6B7BC)
        case .json: GlyphColor(0xEE2C22, 0xFF695E)
        case .markdown: GlyphColor(0x52788D, 0xCCEAFF)
        case .logo(let name): logoTints[name]
        case .accent: nil
        }
    }

    /// The tint on a selected row without focus: the type's tint, slightly
    /// shifted for Swift (#EC6D38 / #FFB75F, measured on Long.swift);
    /// other types keep their tint (unmeasured).
    public static func unfocusedSelectedTint(_ t: WorkspaceChrome.IconTint) -> GlyphColor? {
        if t == .orange { return GlyphColor(0xEC6D38, 0xFFB75F) }
        return tint(t)
    }

    /// The jump bar's tint: the navigator's, but Markdown #5A8095 / #B7D5EB
    /// and JSON the system red #FF383C / #FF4245 (round 10, row 246).
    public static func jumpBarTint(_ t: WorkspaceChrome.IconTint) -> GlyphColor? {
        if t == .markdown { return GlyphColor(0x5A8095, 0xB7D5EB) }
        if t == .json { return jumpBarJSONTint }
        return tint(t)
    }

    /// The languages' tints (Python measured; the rest Ycode's
    /// choice from each logo's colour).
    public static let logoTints: [String: GlyphColor] = [
        "python": GlyphColor(0xEFBD00, 0xFFF62A),
        "c": GlyphColor(0x5C6E9E, 0xA9BACD),
        "cplusplus": GlyphColor(0x00599C, 0x6FA8DC),
        "javascript": GlyphColor(0xC9A400, 0xF0DB4F),
        "typescript": GlyphColor(0x007ACC, 0x4FB3FF),
        "rust": GlyphColor(0xB7410E, 0xF08A5D),
        "go": GlyphColor(0x0094BA, 0x5DD4F0),
        "ruby": GlyphColor(0xD91404, 0xFF6B5E),
        "java": GlyphColor(0xE2231A, 0xFF7070),
        "kotlin": GlyphColor(0xA811C9, 0xE07CF0),
        "html5": GlyphColor(0xE44D26, 0xFF7A55),
        "css3": GlyphColor(0x1572B6, 0x4FA8E8),
        "bash": GlyphColor(0x4D5A64, 0xA9B4BC),
    ]

    // MARK: Jump bar

    /// The glyph Ycode draws for a jump-bar path component (nil: its
    /// symbol): the file's (`NavigatorRowIcon.ofFile`) when it is one of
    /// Ycode's outlines, the folder for a group, the Ycode mark for the
    /// project (both IDEs, row 211).
    public static func jumpBarGlyph(symbol: String, role: JumpBarPathLayout.IconRole, fileName: String?) -> NavigatorRowIcon? {
        switch role {
        case .file:
            let g = fileName.map(NavigatorRowIcon.ofFile)
            return g?.isGlyph == true ? g : nil
        case .project: return ["folder.badge.gearshape", "shippingbox", "square.stack.3d.up"].contains(symbol) ? .ycodeMark : nil
        case .group: return symbol == "folder.fill" || symbol == "folder" ? .folder : nil
        }
    }

    /// A jump-bar glyph's tint in the focused pane (`jumpBarTint`; folders
    /// the synchronized folder's blue, the project its blue).
    public static func jumpBarGlyphTint(_ g: NavigatorRowIcon, fileName: String?) -> GlyphColor? {
        switch g {
        case .folder: jumpBarTint(.lightBlue)
        case .ycodeMark: jumpBarTint(.blue)
        default: jumpBarTint(WorkspaceChrome.iconTint(kind: .file, name: fileName ?? ""))
        }
    }

    /// White, a glyph's colour on a focused selected row.
    public static let selectedWhite: UInt32 = 0xFFFFFF
}
