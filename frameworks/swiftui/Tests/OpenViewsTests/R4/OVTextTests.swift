import Foundation
import Testing
import OVText

// OVText on its own: the OpenType reader on the bundled Noto Sans, font
// matching, UAX #14 line breaking, UAX #9 visual order, and the paragraph
// rules of Layout/Typesetter.swift with a table face of round numbers.

private let catalog = FontCatalog.bundled

private func noto(weight: Int = 400) -> any FontFace {
    catalog.face(for: FontRequest(traits: FontTraits(weight: weight)))!
}

/// A table face whose every character advances `size / 2` (spaces `size / 4`).
private let grid = TableFace(familyName: "Grid", ascentRatio: 0.8, descentRatio: 0.2, defaultLeadingRatio: 0.1,
                             estimatedAdvanceRatio: 0.5)

private func run(_ s: String, size: Double = 20, face: any FontFace = grid) -> [AttributedRun] {
    [AttributedRun(s, style: RunStyle(face: face, size: size))]
}

private func lines(_ l: TextLayout) -> [String] {
    l.lines.map { line in
        var s = String(l.clusters[line.range].map(\.character))
        switch line.ellipsis {
        case .after: s += "…"
        case .before: s = "…" + s
        case .inMiddle(let at):
            let head = String(l.clusters[line.range.lowerBound..<at].map(\.character))
            s = head + "…"
        case .none: break
        }
        return s
    }
}

@Suite("OVText: OpenType reader and font matching (bundled Noto Sans)")
struct OpenTypeTests {
    @Test("Names, metrics and traits come from the name, head, hhea and OS/2 tables")
    func metrics() throws {
        let f = try #require(noto() as? OpenTypeFace)
        #expect(f.familyName == "Noto Sans")
        #expect(f.styleName == "Regular")
        #expect(f.unitsPerEm == 1000)
        #expect(f.ascender == 1069 && f.descender == 293 && f.lineGap == 0)
        #expect(f.traits.weight == 400 && !f.traits.isItalic)
        let m = f.lineMetrics(size: 20)
        #expect(abs(m.ascent - 21.38) < 1e-9 && abs(m.descent - 5.86) < 1e-9)
        #expect(m.capHeight > 0 && m.xHeight > 0 && m.xHeight < m.capHeight)
    }

    @Test("cmap maps characters; unknown characters have no glyph")
    func characterMap() {
        let f = noto()
        #expect(f.glyph(for: "A") != nil)
        #expect(f.glyph(for: "é") != nil)
        #expect(f.glyph(for: "\u{2026}") != nil)
        #expect(f.glyph(for: "漢") == nil)
    }

    @Test("Advances scale with the size; GPOS pair kerning tightens AV and To")
    func advancesAndKerning() throws {
        let f = noto()
        let a = try #require(f.glyph(for: "A")), v = try #require(f.glyph(for: "V"))
        #expect(abs(f.advance(of: a, size: 34) - 2 * f.advance(of: a, size: 17)) < 1e-9)
        #expect(f.kerning(a, v, size: 17) < 0)
        let t = try #require(f.glyph(for: "T")), o = try #require(f.glyph(for: "o"))
        #expect(f.kerning(t, o, size: 17) < 0)
        let shaped = Shaper.shape(run("AV", size: 17, face: f))
        #expect(shaped[0].kernAfter < 0)
    }

    @Test("Bold is a separate face; CSS matching picks the nearest weight in the right direction")
    func matching() {
        #expect(noto(weight: 700).traits.weight == 700)
        #expect(noto(weight: 600).traits.weight == 700)   // > 500: heavier first
        #expect(noto(weight: 500).traits.weight == 400)   // 400–500: up to 500, then lighter
        #expect(noto(weight: 300).traits.weight == 400)   // < 400: lighter first, then heavier
        #expect(noto(weight: 900).traits.weight == 700)
        let traits = [FontTraits(weight: 300), FontTraits(weight: 500), FontTraits(weight: 800)]
        #expect(FontCatalog.bestMatch(traits, for: FontTraits(weight: 400)) == 1)
        #expect(FontCatalog.bestMatch(traits, for: FontTraits(weight: 450)) == 1)
        #expect(FontCatalog.bestMatch(traits, for: FontTraits(weight: 350)) == 0)
        #expect(FontCatalog.bestMatch(traits, for: FontTraits(weight: 600)) == 2)
    }

    @Test("Apple's system font families are refused")
    func refusedFamilies() {
        #expect(FontCatalog.isRefused(family: "SF Pro Text"))
        #expect(FontCatalog.isRefused(family: "SF Compact"))
        #expect(FontCatalog.isRefused(family: ".SFUI-Regular"))
        #expect(FontCatalog.isRefused(family: "New York"))
        #expect(!FontCatalog.isRefused(family: "Noto Sans"))
        let c = FontCatalog()
        c.add(TableFace(familyName: "SF Pro", ascentRatio: 1, descentRatio: 0))
        #expect(c.registeredFaces.isEmpty)
    }

    @Test("A damaged file is an error, not a crash")
    func damaged() {
        #expect(throws: FontFileError.notAFont) { try OpenTypeFace(data: Data([1, 2, 3])) }
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[1] = 1 // version 0x00010000, no tables
        #expect(throws: FontFileError.missingTable("head")) { try OpenTypeFace(data: Data(bytes)) }
    }
}

@Suite("OVText: UAX #14 line break opportunities")
struct LineBreakTests {
    /// Indices of clusters before which a break is allowed (or mandatory, `!`).
    private func breaks(_ s: String) -> [String] {
        let chars = Array(s)
        let o = LineBreaker.opportunities(chars)
        return (1..<chars.count).compactMap { i in
            switch o[i] {
            case .allowed: return "\(i)"
            case .mandatory: return "\(i)!"
            case .prohibited: return nil
            }
        }
    }

    @Test("Spaces: break after the spaces (LB7, LB18)")
    func spaces() {
        #expect(breaks("Hello world") == ["6"])
        #expect(breaks("a  b") == ["3"])
    }

    @Test("Hard breaks (LB4, LB5); CR LF is one cluster")
    func hard() {
        #expect(breaks("a\nb") == ["2!"])
        #expect(breaks("a\r\nb") == ["2!"])
        #expect(breaks("a\u{2028}b") == ["2!"])
    }

    @Test("Punctuation: no break before closing punctuation, after opening, inside numbers (LB13, LB14, LB25)")
    func punctuation() {
        #expect(breaks("(a)") == [])
        #expect(breaks("end. Next") == ["5"])
        #expect(breaks("1,000.5") == [])
        #expect(breaks("$5 5%") == ["3"])
        #expect(breaks("-5") == [])
        #expect(breaks("\"quoted\"") == [])
    }

    @Test("Hyphens allow a break after them (LB21)")
    func hyphen() {
        #expect(breaks("well-known") == ["5"])
        #expect(breaks("a\u{00AD}b") == ["2"])
    }

    @Test("Glue and zero width space (LB8, LB12)")
    func glue() {
        #expect(breaks("a\u{00A0}b") == [])
        #expect(breaks("a\u{200B}b") == ["2"])
        #expect(breaks("a\u{2060}b") == [])
    }

    @Test("Ideographs break between characters, but not before small kana or closing marks (LB31, LB21, LB13)")
    func ideographs() {
        #expect(breaks("漢字です") == ["1", "2", "3"] || breaks("漢字です") == ["1", "2"])
        #expect(breaks("漢字。") == ["1"])
        #expect(breaks("ちょっと") == ["3"])
    }

    @Test("Clusters stay whole: emoji with modifiers, flags, combining marks")
    func clusters() {
        #expect(breaks("a 👍🏽 b") == ["2", "4"])
        #expect(breaks("🇫🇷🇩🇪") == ["1"])
        #expect(breaks("e\u{0301}x y") == ["3"])
    }
}

@Suite("OVText: UAX #9 visual order")
struct BidiTests {
    @Test("Left-to-right text keeps its order")
    func ltr() {
        let p = BidiParagraph(Array("abc def"))
        #expect(p.direction == .leftToRight)
        #expect(p.visualOrder(0..<7) == Array(0..<7))
    }

    @Test("A Hebrew paragraph is right-to-left and reversed")
    func rtl() {
        let p = BidiParagraph(Array("אבג"))
        #expect(p.direction == .rightToLeft)
        #expect(p.visualOrder(0..<3) == [2, 1, 0])
    }

    @Test("Embedded right-to-left run in a left-to-right paragraph")
    func mixed() {
        let p = BidiParagraph(Array("ab אבג cd"))
        #expect(p.visualOrder(0..<9) == [0, 1, 2, 5, 4, 3, 6, 7, 8])
    }

    @Test("Arabic with European digits: digits stay left-to-right (W2, I2)")
    func arabicDigits() {
        let p = BidiParagraph(Array("سعر 123"))
        #expect(p.direction == .rightToLeft)
        #expect(p.visualOrder(0..<7) == [4, 5, 6, 3, 2, 1, 0])
    }

    @Test("Direction from the first strong character; neutral-only text uses the fallback")
    func direction() {
        #expect(BidiParagraph(Array("123 אב")).direction == .rightToLeft)
        #expect(BidiParagraph(Array("!?"), fallback: .rightToLeft).direction == .rightToLeft)
        #expect(BidiParagraph(Array("אב"), base: .leftToRight).direction == .leftToRight)
    }
}

@Suite("OVText: paragraph layout rules")
struct TypesetterTests {
    @Test("Greedy wrapping at break opportunities; trailing spaces hang")
    func wrapping() {
        let l = Typesetter.layout(run("aaa bbb ccc"), width: 70)
        #expect(lines(l) == ["aaa bbb ", "ccc"])
        #expect(l.lines.map(\.width) == [65, 30])
        #expect(l.width == 65 && !l.brokeInsideWord && !l.isTruncated)
    }

    @Test("Unlimited width: one line per paragraph; explicit newlines break")
    func unlimited() {
        let l = Typesetter.layout(run("aaa bbb\ncc"), width: nil)
        #expect(lines(l) == ["aaa bbb\n", "cc"])
        #expect(l.width == 65)
    }

    @Test("A word wider than the line breaks between clusters, at least one per line")
    func emergency() {
        let l = Typesetter.layout(run("aaaaaaaa"), width: 35)
        #expect(lines(l) == ["aaa", "aaa", "aa"])
        #expect(l.brokeInsideWord)
        let zero = Typesetter.layout(run("ab cd"), width: 0)
        #expect(lines(zero) == ["a", "b ", "c", "d"])
    }

    @Test("Line positions: pitch = ascent + descent + leading (+ line spacing); height without trailing leading")
    func vertical() {
        var style = ParagraphStyle()
        let l = Typesetter.layout(run("aaa bbb ccc"), width: 40, style: style)
        #expect(l.lines.count == 3)
        #expect(l.firstBaseline == 16 && l.lastBaseline == 16 + 2 * 22)
        #expect(abs(l.height - (20 + 2 * 22)) < 1e-9)
        style.lineSpacing = 5
        let spaced = Typesetter.layout(run("aaa bbb ccc"), width: 40, style: style)
        #expect(abs(spaced.height - (20 + 2 * 27)) < 1e-9)
    }

    @Test("maxLines and maxHeight cap the lines; the last line takes the rest and is truncated")
    func caps() {
        let a = Typesetter.layout(run("aaa bbb ccc"), width: 70, style: ParagraphStyle(maxLines: 1))
        #expect(lines(a) == ["aaa bb…"])
        #expect(a.width == 65 && a.isTruncated && a.naturalLineCount == 2)
        let b = Typesetter.layout(run("aaa bbb ccc"), width: 40, maxHeight: 45)
        #expect(lines(b) == ["aaa ", "bbb…"])
        let c = Typesetter.layout(run("aaa bbb ccc"), width: 40, maxHeight: 5)
        #expect(c.lines.count == 1)
    }

    @Test("Head and middle truncation")
    func headMiddle() {
        let head = Typesetter.layout(run("aaa bbb ccc"), width: 70, style: ParagraphStyle(maxLines: 1, truncation: .head))
        #expect(lines(head) == ["…bb ccc"])
        #expect(head.width == 65)
        let mid = Typesetter.layout(run("abcdefghij"), width: 60, style: ParagraphStyle(maxLines: 1, truncation: .middle))
        #expect(mid.lines[0].ellipsis == .inMiddle(at: 3))
        #expect(mid.width == 60)
    }

    @Test("Minimum scale factor shrinks the text to fit before truncating")
    func minimumScale() {
        let style = ParagraphStyle(maxLines: 1, minimumScaleFactor: 0.5)
        let l = Typesetter.layout(run("aaaaaaaaaa"), width: 60, style: style)
        #expect(!l.isTruncated)
        #expect(l.scale > 0.59 && l.scale <= 0.6)
        let tooSmall = Typesetter.layout(run("aaaaaaaaaa"), width: 20, style: style)
        #expect(tooSmall.isTruncated && tooSmall.scale == 0.5)
    }

    @Test("Measured run widths win over advances and keep layouts exact")
    func measuredRuns() {
        let face = TableFace(familyName: "M", ascentRatio: 0.8, descentRatio: 0.2,
                             runs: [TableFace.Run("Hello", size: 17): 39])
        let l = Typesetter.layout(run("Hello", size: 17, face: face), width: 100)
        #expect(l.width == 39 && !l.usesEstimates)
        let wrapped = Typesetter.layout(run("Hello", size: 17, face: face), width: 20)
        #expect(wrapped.breaksUseEstimates)
        let unknown = Typesetter.layout(run("Other", size: 17, face: face), width: nil)
        #expect(unknown.widthUsesEstimates && !unknown.breaksUseEstimates)
    }

    @Test("Tracking and kerning attributes add to every cluster")
    func tracking() {
        let style = RunStyle(face: grid, size: 20, tracking: 2, kerning: 1)
        let l = Typesetter.layout([AttributedRun("aaa", style: style)], width: nil)
        #expect(l.width == 3 * 12 + 2 * 1)
    }

    @Test("Lines carry their direction and visual order")
    func bidiLines() {
        let l = Typesetter.layout(run("ab אבג"), width: nil)
        #expect(l.lines[0].direction == .leftToRight)
        #expect(l.lines[0].visualOrder == [0, 1, 2, 5, 4, 3])
    }

    @Test("Missing glyphs come from a fallback face when the catalog has one")
    func fallback() {
        let c = FontCatalog()
        let main = TableFace(familyName: "Main", ascentRatio: 0.8, descentRatio: 0.2)
        c.add(main)
        let shaped = Shaper.shape([AttributedRun("a", style: RunStyle(face: noto(), size: 10, fallback: c))])
        #expect(shaped[0].face === noto())
        let cjk = Shaper.shape([AttributedRun("漢", style: RunStyle(face: noto(), size: 10, fallback: c))])
        #expect(cjk[0].face === main) // the table face claims every scalar
    }
}
