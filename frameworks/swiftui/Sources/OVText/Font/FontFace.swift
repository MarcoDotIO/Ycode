// OVText: font faces, shaping, line breaking and paragraph layout for
// OpenViews (09-open-design.md §2, §5.2). This module knows nothing about
// views; SwiftUICore resolves `Font` values to faces and sizes and calls the
// typesetter (Layout/Typesetter.swift) through its text measurer.
//
// Written from public specifications only: the OpenType specification
// (table layouts), Unicode Standard Annex #14 (line breaking) and #9 (bidi),
// and Unicode Standard Annex #29 through Swift's `Character` (grapheme
// clusters).

/// A glyph index in a face.
public typealias GlyphID = UInt32

/// Style traits used for font matching.
public struct FontTraits: Hashable, Sendable {
    /// OpenType weight class, 1…1000 (400 regular, 700 bold).
    public var weight: Int
    /// OpenType width class, 1…9 (5 normal).
    public var width: Int
    public var isItalic: Bool
    public var isMonospaced: Bool

    public init(weight: Int = 400, width: Int = 5, isItalic: Bool = false, isMonospaced: Bool = false) {
        self.weight = weight
        self.width = width
        self.isItalic = isItalic
        self.isMonospaced = isMonospaced
    }
}

/// Vertical metrics of a face at one point size, in points. `descent` is
/// positive (below the baseline).
public struct LineMetrics: Hashable, Sendable {
    public var ascent: Double
    public var descent: Double
    /// Extra space between lines (the font's line gap).
    public var leading: Double
    public var capHeight: Double
    public var xHeight: Double

    public init(ascent: Double, descent: Double, leading: Double, capHeight: Double = 0, xHeight: Double = 0) {
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.capHeight = capHeight
        self.xHeight = xHeight
    }

    /// Height of one line without leading.
    public var lineHeight: Double { ascent + descent }

    public func scaled(by s: Double) -> LineMetrics {
        LineMetrics(ascent: ascent * s, descent: descent * s, leading: leading * s,
                    capHeight: capHeight * s, xHeight: xHeight * s)
    }
}

/// A typeface: glyph mapping, advances, kerning and vertical metrics.
///
/// Faces may be size-dependent (optical sizes, tracking tables): every query
/// takes the point size.
public protocol FontFace: AnyObject, Sendable {
    var familyName: String { get }
    var styleName: String { get }
    var traits: FontTraits { get }

    func lineMetrics(size: Double) -> LineMetrics
    /// The glyph for a scalar, or nil when the face has none.
    func glyph(for scalar: Unicode.Scalar) -> GlyphID?
    /// Advance width in points.
    func advance(of glyph: GlyphID, size: Double) -> Double
    /// Kerning adjustment in points between two adjacent glyphs.
    func kerning(_ left: GlyphID, _ right: GlyphID, size: Double) -> Double
    /// Extra space the face adds after every character at `size` (optical
    /// tracking; 0 for plain OpenType faces).
    func tracking(size: Double) -> Double

    /// A measured width for a whole run of text set in this face, when the
    /// face carries one (a table of measured runs, see `TableFace`); nil
    /// otherwise. The typesetter prefers it to the sum of advances.
    func measuredWidth(of text: Substring, size: Double) -> Double?
    /// True when advances are estimates rather than font data (table faces);
    /// layouts that depend on them report it (`TextLayout.usesEstimates`).
    var advancesAreEstimates: Bool { get }
}

extension FontFace {
    public func tracking(size: Double) -> Double { 0 }
    public func measuredWidth(of text: Substring, size: Double) -> Double? { nil }
    public var advancesAreEstimates: Bool { false }
}
