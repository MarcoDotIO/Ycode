// Shaping: text runs → grapheme clusters with advances.
//
// Our shaper covers simple scripts: each cluster takes the glyph of its
// first scalar (from the run's face, else a fallback face that has it, else
// the face's missing glyph), combining marks and variation selectors in the
// cluster add no advance, adjacent clusters of one run are kerned with the
// face's pair kerning (GPOS `kern` / `kern` table), and the run's tracking
// and kerning attributes add to every cluster. Ligatures, contextual forms
// and mark positioning (GSUB, GPOS mark attachment) — needed for Arabic,
// Indic and other complex scripts — are not implemented; a HarfBuzz-based
// shaper can replace this one behind the same `ShapedCluster` output.

/// Style of one run of text.
public struct RunStyle: @unchecked Sendable {
    public var face: any FontFace
    public var size: Double
    /// Extra space after every cluster (points).
    public var tracking: Double
    /// Extra kerning between adjacent clusters (points).
    public var kerning: Double
    /// Vertical shift of the run (points, up).
    public var baselineOffset: Double
    /// Where to look for glyphs the face lacks (nil: none).
    public var fallback: FontCatalog?

    public init(face: any FontFace, size: Double, tracking: Double = 0, kerning: Double = 0,
                baselineOffset: Double = 0, fallback: FontCatalog? = nil) {
        self.face = face
        self.size = size
        self.tracking = tracking
        self.kerning = kerning
        self.baselineOffset = baselineOffset
        self.fallback = fallback
    }

    func scaled(_ s: Double) -> RunStyle {
        var r = self
        r.size *= s
        r.tracking *= s
        r.kerning *= s
        r.baselineOffset *= s
        return r
    }
}

/// A run of text with its style.
public struct AttributedRun: Sendable {
    public var text: String
    public var style: RunStyle

    public init(_ text: String, style: RunStyle) {
        self.text = text
        self.style = style
    }
}

/// One shaped grapheme cluster.
public struct ShapedCluster: @unchecked Sendable {
    public var character: Character
    public var run: Int
    /// Advance including tracking, without the kerning to the next cluster.
    public var advance: Double
    /// Kerning to the following cluster of the same run (dropped at line ends).
    public var kernAfter: Double
    public var glyph: GlyphID
    public var face: any FontFace
    /// Whitespace that hangs at the end of a line (not counted in its width).
    public var hangs: Bool
    public var breakClass: LineBreakClass
}

public enum Shaper {
    /// Shapes `runs` into clusters (in logical order).
    public static func shape(_ runs: [AttributedRun]) -> [ShapedCluster] {
        var out: [ShapedCluster] = []
        for (ri, run) in runs.enumerated() {
            let st = run.style
            let tracking = st.tracking + st.face.tracking(size: st.size)
            var previous: (index: Int, glyph: GlyphID, face: ObjectIdentifier)?
            for ch in run.text {
                let cls = LineBreaker.lineBreakClass(of: ch)
                let isBreak = cls == .BK || cls == .CR || cls == .LF || cls == .NL
                var face = st.face
                var glyph: GlyphID = 0
                var advance = 0.0
                if !isBreak, let first = ch.unicodeScalars.first {
                    if let g = face.glyph(for: first) {
                        glyph = g
                    } else if let fb = st.fallback?.fallback(for: first, near: st.face.traits),
                              let g = fb.glyph(for: first) {
                        face = fb
                        glyph = g
                    }
                    advance = face.advance(of: glyph, size: st.size) + tracking
                    if first == "\t" { advance = st.size * 2 }
                }
                let hangs = !isBreak && ch.isWhitespace
                if let p = previous, p.face == ObjectIdentifier(face), !isBreak {
                    out[p.index].kernAfter = face.kerning(p.glyph, glyph, size: st.size) + st.kerning
                } else if let p = previous, !isBreak {
                    out[p.index].kernAfter = st.kerning
                }
                out.append(ShapedCluster(character: ch, run: ri, advance: advance, kernAfter: 0, glyph: glyph,
                                         face: face, hangs: hangs, breakClass: cls))
                previous = isBreak ? nil : (out.count - 1, glyph, ObjectIdentifier(face))
            }
        }
        return out
    }
}
