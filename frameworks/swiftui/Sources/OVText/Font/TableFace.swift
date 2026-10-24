// A face defined by tables instead of a font file: vertical metrics as
// fractions of the point size, a per-size leading table, and a table of
// measured run widths. Its glyph advances are estimates (a fixed fraction of
// the size per character), so layouts that need them report
// `usesEstimates`.
//
// Use: conformance tests set the measured values of a reference font in it
// (widths, ascent, descent and leading recorded in the spec) so that layout
// arithmetic around text can be checked exactly without that font; any
// answer that would need the font's real glyph widths is flagged.

public final class TableFace: FontFace, @unchecked Sendable {
    /// A measured run: text, point size and weight class.
    public struct Run: Hashable, Sendable {
        public var text: String
        public var size: Double
        public var weight: Int

        public init(_ text: String, size: Double, weight: Int = 400) {
            self.text = text
            self.size = size
            self.weight = weight
        }
    }

    public let familyName: String
    public let styleName: String
    public let traits: FontTraits
    /// Ascent and descent as fractions of the point size.
    public let ascentRatio: Double
    public let descentRatio: Double
    public let capHeightRatio: Double
    public let xHeightRatio: Double
    /// Leading by point size; sizes not listed use the nearest listed size
    /// (or `defaultLeadingRatio` × size when the table is empty).
    public let leadingBySize: [Double: Double]
    public let defaultLeadingRatio: Double
    /// Measured run widths (points) by text, size and weight.
    public let runs: [Run: Double]
    /// Estimated advance of one character, as a fraction of the size.
    public let estimatedAdvanceRatio: Double

    public init(familyName: String, styleName: String = "Regular", traits: FontTraits = FontTraits(),
                ascentRatio: Double, descentRatio: Double, capHeightRatio: Double = 0.7, xHeightRatio: Double = 0.5,
                leadingBySize: [Double: Double] = [:], defaultLeadingRatio: Double = 0,
                runs: [Run: Double] = [:], estimatedAdvanceRatio: Double = 0.55) {
        self.familyName = familyName
        self.styleName = styleName
        self.traits = traits
        self.ascentRatio = ascentRatio
        self.descentRatio = descentRatio
        self.capHeightRatio = capHeightRatio
        self.xHeightRatio = xHeightRatio
        self.leadingBySize = leadingBySize
        self.defaultLeadingRatio = defaultLeadingRatio
        self.runs = runs
        self.estimatedAdvanceRatio = estimatedAdvanceRatio
    }

    public func lineMetrics(size: Double) -> LineMetrics {
        let leading: Double
        if let l = leadingBySize[size] {
            leading = l
        } else if let nearest = leadingBySize.keys.min(by: { abs($0 - size) < abs($1 - size) }) {
            leading = leadingBySize[nearest]!
        } else {
            leading = defaultLeadingRatio * size
        }
        return LineMetrics(ascent: ascentRatio * size, descent: descentRatio * size, leading: leading,
                           capHeight: capHeightRatio * size, xHeight: xHeightRatio * size)
    }

    public func glyph(for scalar: Unicode.Scalar) -> GlyphID? { scalar.value }

    public func advance(of glyph: GlyphID, size: Double) -> Double {
        guard let s = Unicode.Scalar(glyph) else { return 0 }
        if s.properties.generalCategory == .nonspacingMark || s.properties.generalCategory == .enclosingMark { return 0 }
        if s == " " { return estimatedAdvanceRatio * size * 0.5 }
        return estimatedAdvanceRatio * size
    }

    public func kerning(_ left: GlyphID, _ right: GlyphID, size: Double) -> Double { 0 }

    public func measuredWidth(of text: Substring, size: Double) -> Double? {
        runs[Run(String(text), size: size, weight: traits.weight)]
    }

    public var advancesAreEstimates: Bool { true }
}
