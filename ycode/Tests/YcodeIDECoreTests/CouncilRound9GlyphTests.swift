import Foundation
import Testing
@testable import YcodeIDECore

/// Council round 9, group A1 (`specs/ide/fidelity-council.md` rows 208–213,
/// the owner's rules 1–4 of 2026-11-13): the file glyphs both IDEs draw,
/// their boxes, strokes and tints, the jump bar's and Open Quickly's sizes,
/// and the title area's mark and build ring. Platform-free: runs on the Mac
/// and on Linux.
@Suite struct CouncilRound9GlyphTests {
    func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.15) -> Bool { abs(a - b) <= tolerance }

    // MARK: Row 208: the line-art logos in the reference's box

    /// Every logo fits the navigator's 14.5 × 12.5 box, centred, filling
    /// it in one direction (its aspect kept).
    @Test func logosFitTheNavigatorsBox() throws {
        for name in LanguageLogos.names {
            let d = try #require(FileGlyphs.navigatorDrawing(.logo(name)))
            #expect(d.width == 14.5 && d.height == 12.5)
            let ink = d.inkBox
            #expect(ink.minX >= -0.05 && ink.minY >= -0.05 && ink.maxX <= 14.55 && ink.maxY <= 12.55, "\(name) \(ink)")
            let w = ink.maxX - ink.minX, h = ink.maxY - ink.minY
            #expect(close(w, 14.5, 0.3) || close(h, 12.5, 0.3), "\(name) \(w) × \(h)")
            #expect(close((ink.minX + ink.maxX) / 2, 7.25, 0.2) && close((ink.minY + ink.maxY) / 2, 6.25, 0.2), "\(name) centred")
        }
    }

    /// The thin "line" variants (C, Rust) are thickened to the reference's
    /// 1.5-point strokes; plain variants are solid shapes, not stroked.
    @Test func lineVariantsGetTheReferencesStroke() throws {
        for name in LanguageLogos.names {
            let d = try #require(FileGlyphs.navigatorDrawing(.logo(name)))
            let stroke = d.paths.map(\.strokeWidth).max() ?? 0
            #expect(d.paths.allSatisfy { $0.fills } == (name != "python"))
            switch name {
            case "c": #expect(close(stroke, 1.25, 0.01))
            case "rust": #expect(close(stroke, 1.35, 0.01))
            case "python": #expect(close(stroke, 1.5, 0.01))
            default: #expect(stroke == 0, "\(name)")
            }
        }
        // C's band, about 2.25 units of 128 (0.22 points at 12.5) plus the
        // boost: about 1.5 points.
        let c = try #require(LanguageLogos.outline("c"))
        let band = 2.25 * min(14.5 - 1.25, 12.5 - 1.25) / max(c.width, c.height) + 1.25
        #expect(close(band, FileGlyphs.lineWidth, 0.1))
    }

    /// The owner's decision of 2026-11-13: the Swift glyph is devicon's
    /// plain variant inverted, the bird alone (the reference's filled bird),
    /// no rounded square: its outline is the bird's bounds (about 94 × 81
    /// of the SVG's 128), filled even-odd so it comes out solid, and fitted
    /// to the glyph box by the bird's own bounds.
    @Test func swiftIsTheBirdAloneWithNoTile() throws {
        let o = try #require(LanguageLogos.outline("swift"))
        #expect(close(o.width, 94.3, 0.5) && close(o.height, 80.64, 0.5), "\(o.width) × \(o.height)")
        #expect(o.paths.allSatisfy { $0.evenOdd })
        // The tile's outline (a 120-unit square) is gone: no subpath spans the viewBox.
        for p in o.paths {
            let d = GlyphDrawing(width: o.width, height: o.height, paths: [GlyphPath(p.elements)])
            #expect(d.inkBox.maxX - d.inkBox.minX < 100)
        }
        let d = try #require(FileGlyphs.navigatorDrawing(.logo("swift")))
        let ink = d.inkBox
        // The bird fills the 14.5 × 12.5 box by its own bounds (aspect 1.17).
        #expect(close(ink.maxX - ink.minX, 14.5, 0.1) && close(ink.maxY - ink.minY, 14.5 * 80.64 / 94.3, 0.15), "\(ink)")
        // The box's corners are empty: the top left lies outside every subpath.
        #expect(!Self.contains(d, x: 0.4, y: 0.4) && Self.contains(d, x: 7.25, y: 9.5))
    }

    /// Whether a point is inside a drawing's filled paths (even-odd, curves flattened).
    static func contains(_ d: GlyphDrawing, x: Double, y: Double) -> Bool {
        var crossings = 0
        for p in d.paths {
            var pts: [(Double, Double)] = [], cur = (0.0, 0.0), start = (0.0, 0.0)
            func edge(_ a: (Double, Double), _ b: (Double, Double)) {
                if (a.1 > y) != (b.1 > y), x < a.0 + (y - a.1) * (b.0 - a.0) / (b.1 - a.1) { crossings += 1 }
            }
            for e in p.elements {
                switch e {
                case let .move(px, py):
                    if cur != start { edge(cur, start) }
                    cur = (px, py); start = cur
                case let .line(px, py): edge(cur, (px, py)); cur = (px, py)
                case let .curve(a, b, c, e, px, py):
                    var prev = cur
                    for k in 1...16 {
                        let t = Double(k) / 16, u = 1 - t
                        let q = (u * u * u * cur.0 + 3 * u * u * t * a + 3 * u * t * t * c + t * t * t * px,
                                 u * u * u * cur.1 + 3 * u * u * t * b + 3 * u * t * t * e + t * t * t * py)
                        edge(prev, q); prev = q
                    }
                    cur = (px, py)
                case .close: edge(cur, start); cur = start
                }
            }
            if cur != start { edge(cur, start) }
            _ = pts.isEmpty
            pts = []
        }
        return crossings % 2 == 1
    }

    @Test func swiftPythonAndMarkdownUseTheirSingleColourVariants() {
        #expect(LanguageLogos.source("swift") == "swift-plain.svg")
        #expect(LanguageLogos.source("python") == "python-plain.svg")
        #expect(LanguageLogos.source("markdown") == nil)
        #expect(LanguageLogos.source("ruby") == "ruby-plain.svg")
        #expect(LanguageLogos.source("json") == nil)
    }

    // MARK: Rows 208, 209, 213: the tint table

    @Test func tintsAreTheReferencesMeasuredInk() {
        func t(_ kind: NavigatorNode.Kind, _ name: String) -> GlyphColor? { FileGlyphs.tint(WorkspaceChrome.iconTint(kind: kind, name: name)) }
        #expect(t(.file, "Bands.swift") == GlyphColor(0xF77640, 0xFFA54D))
        #expect(t(.file, "convert.py") == GlyphColor(0xEFBD00, 0xFFF62A))
        #expect(t(.file, "NOTES.md") == GlyphColor(0x52788D, 0xCCEAFF))
        #expect(t(.file, "palette.json") == GlyphColor(0xEE2C22, 0xFF695E))
        #expect(t(.file, "Stripes.png") == GlyphColor(0x006BEF, 0x2DA7FF))
        #expect(t(.folder, "Models") == GlyphColor(0x3FA1F6, 0x5BC6FF))
        #expect(t(.group, "Plain") == GlyphColor(0x7B7B80, 0xB6B7BC))
        #expect(t(.container, "GlassScroll") == GlyphColor(0x006BEF, 0x2DA7FF))
        // Every language has a tint of its own.
        for name in LanguageLogos.names { #expect(FileGlyphs.tint(.logo(name)) != nil || name == "swift", "\(name)") }
        // Files with neither a logo nor a measured tint keep the accent.
        #expect(t(.file, "Info.plist") == nil)
    }

    /// A selected row without focus: the type's tint, Swift's slightly
    /// shifted (#EC6D38 / #FFB75F).
    @Test func unfocusedSelectionTints() {
        #expect(FileGlyphs.unfocusedSelectedTint(.orange) == GlyphColor(0xEC6D38, 0xFFB75F))
        #expect(FileGlyphs.unfocusedSelectedTint(.markdown) == FileGlyphs.tint(.markdown))
        #expect(FileGlyphs.unfocusedSelectedTint(.json) == FileGlyphs.tint(.json))
        #expect(FileGlyphs.selectedWhite == 0xFFFFFF)
    }

    /// The owner's decision of 2026-11-13: Python is its plain shapes'
    /// outline only, 1.5-point strokes, nothing filled inside.
    @Test func pythonIsAnOutlineWithNoFill() throws {
        let d = try #require(FileGlyphs.navigatorDrawing(.logo("python")))
        #expect(d.paths.allSatisfy { !$0.fills && $0.strokeWidth == FileGlyphs.lineWidth })
        let ink = d.inkBox
        #expect(ink.minX >= -0.01 && ink.maxX <= 14.51 && ink.minY >= -0.01 && ink.maxY <= 12.51, "\(ink)")
        #expect(close(ink.maxY - ink.minY, 12.5, 0.2) || close(ink.maxX - ink.minX, 14.5, 0.2))
        #expect(WorkspaceChrome.iconTint(kind: .file, name: "convert.py") == .logo("python"))
    }

    /// The owner's decision of 2026-11-13: Markdown is Ycode's own open
    /// book (two facing pages and a spine), line art at 1.5 points, 14.5 × 12,
    /// in the reference's Markdown tint; no devicon file.
    @Test func markdownIsYcodesOpenBook() throws {
        #expect(NavigatorRowIcon.ofFile("NOTES.md") == .markdown && LanguageLogos.logo(forFileName: "NOTES.md") == nil)
        #expect(WorkspaceChrome.iconTint(kind: .file, name: "NOTES.md") == .markdown)
        #expect(FileGlyphs.tint(.markdown) == GlyphColor(0x52788D, 0xCCEAFF))
        let d = try #require(FileGlyphs.navigatorDrawing(.markdown))
        #expect(d == FileGlyphs.fitted(FileGlyphs.book, in: (14.5, 12)) && d.width == 14.5 && d.height == 12)
        #expect(d.paths.count == 2 && d.paths.allSatisfy { !$0.fills && $0.strokeWidth == 1.5 })
        let ink = d.inkBox
        #expect(close(ink.minX, 0, 0.05) && close(ink.maxX, 14.5, 0.05) && ink.minY >= 0 && close(ink.maxY, 12, 0.05), "\(ink)")
        // Two pages mirrored about the spine at x 7.25, both touching it.
        let left = GlyphDrawing(width: 14.5, height: 12, paths: [d.paths[0]]).inkBox
        let right = GlyphDrawing(width: 14.5, height: 12, paths: [d.paths[1]]).inkBox
        #expect(close(left.maxX, 8.0, 0.05) && close(right.minX, 6.5, 0.05) && close(left.minX, 14.5 - right.maxX, 0.01))
    }

    // MARK: Row 210: Ycode's JSON glyph

    /// Braces (1.5-point strokes) round a filled opening quote, 16.5 × 12;
    /// the quote's two "6"s about 2.6 × 3.2 each, side by side.
    @Test func jsonGlyph() throws {
        let d = try #require(FileGlyphs.navigatorDrawing(.json))
        #expect(d.width == 16.5 && d.height == 12)
        let ink = d.inkBox
        #expect(close(ink.minX, 0, 0.05) && close(ink.maxX, 16.5, 0.05) && close(ink.minY, 0, 0.05) && close(ink.maxY, 12, 0.05), "\(ink)")
        let braces = d.paths.filter { $0.strokeWidth > 0 }, filled = d.paths.filter { $0.fills }
        #expect(braces.count == 2 && braces.allSatisfy { $0.strokeWidth == 1.5 && !$0.fills })
        #expect(filled.count == 4)   // two dots and two tails
        // Each "6" (dot and tail).
        for i in [0, 2] {
            let six = GlyphDrawing(width: 16.5, height: 12, paths: [filled[i], filled[i + 1]]).inkBox
            #expect(close(six.maxX - six.minX, 2.6, 0.1) && close(six.maxY - six.minY, 3.2, 0.1), "\(six)")
        }
        // The quote sits between the braces, the two "6"s side by side.
        let left = GlyphDrawing(width: 16.5, height: 12, paths: [filled[0], filled[1]]).inkBox
        let right = GlyphDrawing(width: 16.5, height: 12, paths: [filled[2], filled[3]]).inkBox
        #expect(left.maxX < right.minX && left.minX > 4.4 && right.maxX < 12.1 && close(left.minY, right.minY, 0.01))
        // In the jump bar its own drawing, 14 × 10 (round 10, row 246).
        let j = try #require(FileGlyphs.jumpBarDrawing(.json))
        let jink = j.inkBox
        #expect(close(jink.maxX - jink.minX, 14, 0.1) && close(jink.maxY - jink.minY, 10, 0.1))
        #expect(NavigatorRowIcon.ofFile("palette.json") == .json && WorkspaceChrome.iconTint(kind: .file, name: "palette.json") == .json)
    }

    // MARK: Row 213: folders and the project row

    @Test func folderAndProjectBoxes() throws {
        let d = try #require(FileGlyphs.navigatorDrawing(.folder))
        let ink = d.inkBox
        #expect(close(ink.maxX - ink.minX, 14.5, 0.01) && close(ink.maxY - ink.minY, 12, 0.01))
        #expect(d.paths.count == 2 && d.paths.allSatisfy { $0.fills && $0.strokeWidth == 0 })
        #expect(FileGlyphs.navigatorBox(.ycodeMark) == (15, 15))
        #expect(NavigatorRowIcon.of(kind: .group, name: "Plain", path: nil) == .folder)
        #expect(NavigatorRowIcon.of(kind: .folder, name: "Models", path: nil) == .folder)
        #expect(NavigatorRowIcon.of(kind: .container, name: "GlassScroll", path: "/a/GlassScroll.xcodeproj") == .ycodeMark)
    }

    // MARK: Row 211: outside the navigator

    @Test func jumpBarAndOpenQuicklyBoxes() throws {
        let md = try #require(FileGlyphs.jumpBarDrawing(.markdown))
        #expect(md.width == 13 && md.height == 10.5)
        let ink = md.inkBox
        #expect(close(ink.maxX - ink.minX, 13, 0.2))
        #expect(FileGlyphs.jumpBarTint(.markdown) == GlyphColor(0x5A8095, 0xB7D5EB))
        #expect(FileGlyphs.jumpBarTint(.orange) == FileGlyphs.tint(.orange))
        #expect(FileGlyphs.openQuicklyBox == (24.5, 20.5))
        let oq = try #require(FileGlyphs.drawing(.logo("swift"), in: FileGlyphs.openQuicklyBox))
        #expect(close(oq.inkBox.maxY - oq.inkBox.minY, 20.5, 0.3))
        // Which components get a glyph.
        #expect(FileGlyphs.jumpBarGlyph(symbol: "folder.badge.gearshape", role: .project, fileName: "NOTES.md") == .ycodeMark)
        #expect(FileGlyphs.jumpBarGlyph(symbol: "folder.fill", role: .group, fileName: "NOTES.md") == .folder)
        #expect(FileGlyphs.jumpBarGlyph(symbol: "doc.text", role: .file, fileName: "NOTES.md") == .markdown)
        #expect(FileGlyphs.jumpBarGlyph(symbol: "list.bullet.rectangle", role: .file, fileName: "palette.json") == .json)
        #expect(FileGlyphs.jumpBarGlyph(symbol: "doc.text", role: .file, fileName: "Info.plist") == nil)
        #expect(FileGlyphs.jumpBarGlyphTint(.markdown, fileName: "NOTES.md") == GlyphColor(0x5A8095, 0xB7D5EB))
    }

    // MARK: Row 212: the title area

    @Test func titleMarkAndBuildRing() {
        #expect(FileGlyphs.titleMarkSide == 19.5)
        #expect(FileGlyphs.buildRingDiameter == 19 && FileGlyphs.buildRingStroke == 2.5)
        #expect(FileGlyphs.buildRingTrack.light == 0xE6E6E6 && FileGlyphs.buildRingArc.light == 0x007AFF)
    }

    // MARK: The generated outline data

    @Test func outlineTextParses() {
        let e = LanguageLogos.parse("M1 2L3-4.5C1 2 3 4 5 6Z")
        #expect(e == [.move(1, 2), .line(3, -4.5), .curve(1, 2, 3, 4, 5, 6), .close])
        for name in LanguageLogos.names {
            guard let o = LanguageLogos.outline(name) else { Issue.record("\(name)"); continue }
            for p in o.paths {
                guard case .move = p.elements.first else { Issue.record("\(name) starts without a move"); continue }
            }
        }
    }
}
