import AppKit
import CoreText
import YcodeIDECore

/// Characters the editor font lacks still take one column (council round
/// 2): block elements, box drawing and geometric shapes come from a
/// fallback face whose own advance can be half the editor's (a run of 34
/// full blocks measured 136 points instead of 272). They get that
/// fallback face with the editor's advance fixed, as the font itself has
/// (`editor-area.md` §C.1: 8.0 at 13 points).
extension Theme {
    /// Box Drawing, Block Elements, Geometric Shapes; Braille Patterns.
    static func isCellCharacter(_ u: UInt16) -> Bool {
        (0x2500...0x25FF).contains(u) || (0x2800...0x28FF).contains(u)
    }

    /// Gives every cell character in `range` a face that draws it at the
    /// editor's advance.
    static func fixCellWidths(_ storage: NSTextStorage, in range: NSRange) {
        let text = storage.string as NSString
        let end = min(NSMaxRange(range), text.length)
        var i = max(0, range.location)
        let advance = CGFloat(EditorMetrics.advance(fontAdvance: Double(Theme.advance)))
        var cache: [String: NSFont] = [:]
        while i < end {
            let u = text.character(at: i)
            guard isCellCharacter(u) else { i += 1; continue }
            // One run of cell characters sharing a font.
            var j = i + 1
            while j < end, isCellCharacter(text.character(at: j)) { j += 1 }
            let run = NSRange(location: i, length: j - i)
            let base = (storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont) ?? font
            let s = text.substring(with: run)
            if let fixed = cellFont(for: s, base: base, advance: advance, cache: &cache) {
                storage.addAttribute(.font, value: fixed, range: run)
            }
            i = j
        }
    }

    /// The face that draws `s` (the base font when it has the glyphs, else
    /// the system's fallback) with its advance fixed at `advance`; nil when
    /// the base font already draws them at that advance.
    static func cellFont(for s: String, base: NSFont, advance: CGFloat, cache: inout [String: NSFont]) -> NSFont? {
        let ct = base as CTFont
        let chars = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        let has = CTFontGetGlyphsForCharacters(ct, chars, &glyphs, chars.count)
        let face: CTFont = has ? ct : CTFontCreateForString(ct, s as CFString, CFRange(location: 0, length: (s as NSString).length))
        let key = "\(CTFontCopyPostScriptName(face)) \(CTFontGetSize(face)) \(advance)"
        if let f = cache[key] { return f === base ? nil : f }
        // The face's own advance for the first character.
        var g: CGGlyph = 0
        var c = chars[0]
        CTFontGetGlyphsForCharacters(face, &c, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(face, .horizontal, &g, &adv, 1)
        if has, abs(adv.width - advance) < 0.01 { cache[key] = base; return nil }
        let desc = (face as NSFont).fontDescriptor.addingAttributes([.fixedAdvance: advance])
        let fixed = NSFont(descriptor: desc, size: base.pointSize) ?? (face as NSFont)
        cache[key] = fixed
        return fixed
    }
}
