import Foundation
import Synchronization
import OVText

// The text measurer the layout engine calls (04-layout.md §3), round R4.
//
// `Text` lowers to a `ResolvedText` (runs with resolved fonts, paragraph
// settings from the environment); the engine's text leaf asks a
// `TextMeasurer` for its size and baselines for each proposal. The default
// measurer typesets with OVText: a `TextFontProvider` maps resolved fonts to
// faces (by default the font catalog with the bundled Noto Sans), OVText
// breaks lines, and this file applies SwiftUI's observable rules and the
// pixel grid:
//
// - a 0 × 0 proposal → 0 × 0; an empty text → width 0 and the empty-line
//   height (14 at 17 pt with baseline 11, golden `text.empty`; scaled with
//   the size for other sizes);
// - width: the widest line, rounded up to the pixel grid; at most the
//   proposed width; the proposed width itself when a word had to be broken
//   between characters (golden `hstack.priority`: the squeezed text answers
//   the 17 pt it was offered, and 0 for a zero width);
// - height: lines rounded up to the pixel grid; the proposed height limits
//   the number of lines (at least one), the last shown line truncated with
//   an ellipsis (golden `hstack.equalTexts` fit[100×100], `frame.tooSmall`);
// - baselines: the first and last lines' baselines rounded to the nearest
//   pixel (07 §1.2: body ascender 16.19 → 16.33, large title 32.37 → 32.33).

/// A font resolved against the environment: what the measurer needs.
package struct TextFont: Hashable, Sendable {
    package var size: CGFloat
    package var weight: Font.Weight
    package var width: Font.Width
    package var design: Font.Design
    package var isItalic: Bool
    /// A custom family name, or nil for the system font of `design`.
    package var family: String?
    package var leading: Font.Leading
    package var isMonospacedDigit: Bool
    package var smallCaps: Font.SmallCaps
    /// The text style the size came from (nil for fixed sizes).
    package var textStyle: Font.TextStyle?

    package init(size: CGFloat, weight: Font.Weight = .regular, width: Font.Width = .standard,
                 design: Font.Design = .default, isItalic: Bool = false, family: String? = nil,
                 leading: Font.Leading = .standard, isMonospacedDigit: Bool = false,
                 smallCaps: Font.SmallCaps = [], textStyle: Font.TextStyle? = nil) {
        self.size = size
        self.weight = weight
        self.width = width
        self.design = design
        self.isItalic = isItalic
        self.family = family
        self.leading = leading
        self.isMonospacedDigit = isMonospacedDigit
        self.smallCaps = smallCaps
        self.textStyle = textStyle
    }

    /// A text style at a Dynamic Type size.
    package static func style(_ s: Font.TextStyle, _ size: DynamicTypeSize = .large) -> TextFont {
        Font(base: .style(s)).resolvedTextFont(Font.Context(dynamicTypeSize: size))
    }

    package static let body = TextFont.style(.body)

    package var isBold: Bool { weight.value >= Font.Weight.bold.value }

    /// This font with a heavier weight (`Text.bold()` on a test node).
    package func bolded() -> TextFont { var f = self; f.weight = .bold; return f }
}

/// A text as the layout engine measures it.
package struct ResolvedText: Hashable, Sendable {
    package struct Run: Hashable, Sendable {
        package var string: String
        package var font: TextFont
        package var tracking: CGFloat
        package var kerning: CGFloat
        package var baselineOffset: CGFloat

        package init(string: String, font: TextFont, tracking: CGFloat = 0, kerning: CGFloat = 0,
                     baselineOffset: CGFloat = 0) {
            self.string = string
            self.font = font
            self.tracking = tracking
            self.kerning = kerning
            self.baselineOffset = baselineOffset
        }
    }

    package struct Paragraph: Hashable, Sendable {
        package var lineLimit: Int?
        /// Lines reserved even when fewer are needed.
        package var minimumLines: Int?
        package var lineSpacing: CGFloat = 0
        package var alignment: TextAlignment = .leading
        package var truncation: Text.TruncationMode = .tail
        package var minimumScaleFactor: CGFloat = 1
        package var allowsTightening = false
        package var layoutDirection: LayoutDirection = .leftToRight
        package var displayScale: CGFloat = 3

        package init(lineLimit: Int? = nil) { self.lineLimit = lineLimit }

        package init(environment e: EnvironmentValues) {
            lineLimit = e.lineLimit
            minimumLines = e.lineLimitMinimum
            lineSpacing = e.lineSpacing
            alignment = e.multilineTextAlignment
            truncation = e.truncationMode
            minimumScaleFactor = e.minimumScaleFactor
            allowsTightening = e.allowsTightening
            layoutDirection = e.layoutDirection
            displayScale = e.displayScale
        }
    }

    package var runs: [Run]
    package var paragraph: Paragraph

    package init(runs: [Run], paragraph: Paragraph) {
        self.runs = runs
        self.paragraph = paragraph
    }

    /// One run of `string` in `font`.
    package init(_ string: String, font: TextFont = .body, lineLimit: Int? = nil) {
        self.init(runs: [Run(string: string, font: font)], paragraph: Paragraph(lineLimit: lineLimit))
    }

    package var string: String { runs.map(\.string).joined() }
    package var firstFont: TextFont { runs.first?.font ?? .body }
    package var lastFont: TextFont { runs.last?.font ?? .body }
}

/// A text's answer to a proposal.
package struct TextMeasurement: Sendable {
    package var size: CGSize
    /// Baselines from the top; nil when unknown (the engine then falls back to
    /// the guide's default and marks the pass uncertain).
    package var firstBaseline: CGFloat?
    package var lastBaseline: CGFloat?
    /// Dimensions of `size` the measurer could only approximate (a reference
    /// table font without a measured width for some line).
    package var unknown: Axis.Set

    package init(size: CGSize, firstBaseline: CGFloat?, lastBaseline: CGFloat?, unknown: Axis.Set = []) {
        self.size = size
        self.firstBaseline = firstBaseline
        self.lastBaseline = lastBaseline
        self.unknown = unknown
    }
}

/// Vertical spacing preferences of a text's top and bottom edges (04 §4.1).
package struct TextSpacing: Sendable {
    package var above: SpacingPreference
    package var below: SpacingPreference

    package init(above: SpacingPreference, below: SpacingPreference) {
        self.above = above
        self.below = below
    }
}

/// Measures texts for layout.
package protocol TextMeasurer: Sendable {
    func measure(_ text: ResolvedText, proposal: ProposedViewSize) -> TextMeasurement
    func spacing(for font: TextFont) -> TextSpacing
}

/// Maps resolved fonts to faces.
package protocol TextFontProvider: Sendable {
    func face(for font: TextFont) -> any FontFace
    /// Where glyphs missing from a face are looked up.
    var fallbackCatalog: FontCatalog? { get }
    func spacing(for font: TextFont) -> TextSpacing
}

extension TextFontProvider {
    package var fallbackCatalog: FontCatalog? { nil }

    /// Spacing from the face's metrics, with the reference body values (04
    /// §4.1: 10.643 below a text toward a standard view, 6.433 above, 2
    /// between texts) expressed as baseline distances: below = 0.86726 ×
    /// size − descent, above = 1.33056 × size − ascent (0.86726 and 1.33056
    /// are (10.643 + 4.1006) / 17 and (6.433 + 16.1865) / 17 with the
    /// reference body metrics of 07 §1.2).
    package func spacing(for font: TextFont) -> TextSpacing {
        let size = Double(font.size)
        let m = face(for: font).lineMetrics(size: size)
        return TextSpacing(
            above: SpacingPreference(kind: .text, towardStandard: CGFloat(max(1.33056 * size - m.ascent, 0)), towardText: 2),
            below: SpacingPreference(kind: .text, towardStandard: CGFloat(max(0.86726 * size - m.descent, 0)), towardText: 2))
    }
}

/// Faces from a font catalog (the default: the bundled Noto Sans, plus the
/// system font directories on Linux).
package struct CatalogFontProvider: TextFontProvider {
    package let catalog: FontCatalog

    package init(catalog: FontCatalog = .shared) { self.catalog = catalog }

    package var fallbackCatalog: FontCatalog? { catalog }

    package func face(for font: TextFont) -> any FontFace {
        let design: FontDesignClass
        switch font.design {
        case .default: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .monospaced: design = .monospaced
        }
        let traits = FontTraits(weight: font.weight.weightClass, width: font.width.widthClass,
                                isItalic: font.isItalic, isMonospaced: font.design == .monospaced)
        if let f = catalog.face(for: FontRequest(family: font.family, design: design, traits: traits)) { return f }
        return EmptyFace.shared
    }
}

/// A face with no glyphs (no fonts available at all).
final class EmptyFace: FontFace, @unchecked Sendable {
    static let shared = EmptyFace()
    let familyName = "Empty"
    let styleName = "Regular"
    let traits = FontTraits()
    func lineMetrics(size: Double) -> LineMetrics { LineMetrics(ascent: size * 0.8, descent: size * 0.2, leading: 0) }
    func glyph(for scalar: Unicode.Scalar) -> GlyphID? { nil }
    func advance(of glyph: GlyphID, size: Double) -> Double { size * 0.5 }
    func kerning(_ left: GlyphID, _ right: GlyphID, size: Double) -> Double { 0 }
}

/// The OVText-based measurer.
package final class TypesetTextMeasurer: TextMeasurer, @unchecked Sendable {
    package let fonts: any TextFontProvider
    /// Empty-text line height and baseline as fractions of the size (golden
    /// `text.empty`: 14 and 11 at 17 pt).
    package var emptyLineHeightRatio: CGFloat = 14.0 / 17.0
    package var emptyBaselineRatio: CGFloat = 11.0 / 17.0

    private struct Key: Hashable {
        let text: ResolvedText
        let w: CGFloat?
        let h: CGFloat?
    }
    private let cache = Mutex<[Key: TextMeasurement]>([:])

    package init(fonts: any TextFontProvider) { self.fonts = fonts }

    /// The default measurer: bundled fonts (plus system fonts on Linux).
    package static let shared = TypesetTextMeasurer(fonts: CatalogFontProvider())

    package func spacing(for font: TextFont) -> TextSpacing { fonts.spacing(for: font) }

    // MARK: Pixel grid

    private static func ceilPx(_ v: Double, _ scale: CGFloat) -> CGFloat {
        let s = Double(scale)
        return CGFloat((v * s - 1e-4).rounded(.up) / s)
    }

    private static func roundPx(_ v: Double, _ scale: CGFloat) -> CGFloat {
        let s = Double(scale)
        return CGFloat((v * s).rounded() / s)
    }

    // MARK: Layout

    /// Leading adjustment of `Font.Leading` (ours: ±0.07 × size; the spec
    /// does not measure it).
    private static func leadingAdjustment(_ f: TextFont) -> Double {
        switch f.leading {
        case .standard: return 0
        case .tight: return -0.07 * Double(f.size)
        case .loose: return 0.07 * Double(f.size)
        }
    }

    /// The typeset lines of `text` for a width and height (nil: unlimited).
    package func layout(_ text: ResolvedText, width: CGFloat?, height: CGFloat?) -> TextLayout {
        let runs = text.runs.map { r in
            AttributedRun(r.string, style: RunStyle(face: fonts.face(for: r.font), size: Double(r.font.size),
                                                    tracking: Double(r.tracking), kerning: Double(r.kerning),
                                                    baselineOffset: Double(r.baselineOffset),
                                                    fallback: fonts.fallbackCatalog))
        }
        let p = text.paragraph
        let truncation: ParagraphStyle.Truncation
        switch p.truncation {
        case .head: truncation = .head
        case .middle: truncation = .middle
        case .tail: truncation = .tail
        }
        let style = ParagraphStyle(
            maxLines: p.lineLimit, truncation: truncation,
            lineSpacing: Double(p.lineSpacing) + TypesetTextMeasurer.leadingAdjustment(text.firstFont),
            minimumScaleFactor: Double(p.minimumScaleFactor), allowsTightening: p.allowsTightening,
            fallbackDirection: p.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        let scale = p.displayScale
        return Typesetter.layout(runs, width: width.map(Double.init), maxHeight: height.map(Double.init),
                                 style: style, rounding: { Double(TypesetTextMeasurer.ceilPx($0, scale)) })
    }

    /// A line placed in a text view of a given size: where its baseline
    /// starts (the text's own coordinates, x growing rightwards), by
    /// `multilineTextAlignment` in the layout direction.
    package struct PlacedLine: Sendable {
        package var line: TextLayout.Line
        package var origin: CGPoint
    }

    /// The lines of `text` as drawn in a view of `size` (the size it was
    /// given by layout).
    package func placedLines(_ text: ResolvedText, size: CGSize) -> [PlacedLine] {
        let l = layout(text, width: size.width, height: size.height)
        let scale = text.paragraph.displayScale
        let rtl = text.paragraph.layoutDirection == .rightToLeft
        return l.lines.map { line in
            let slack = Double(size.width) - line.width
            let x: Double
            switch text.paragraph.alignment {
            case .leading: x = rtl ? slack : 0
            case .center: x = slack / 2
            case .trailing: x = rtl ? 0 : slack
            }
            return PlacedLine(line: line, origin: CGPoint(x: CGFloat(x),
                                                          y: TypesetTextMeasurer.roundPx(line.baseline, scale)))
        }
    }

    package func measure(_ text: ResolvedText, proposal p: ProposedViewSize) -> TextMeasurement {
        let key = Key(text: text, w: p.width, h: p.height)
        if let m = cache.withLock({ $0[key] }) { return m }
        let m = compute(text, p)
        cache.withLock {
            if $0.count > 8192 { $0.removeAll(keepingCapacity: true) }
            $0[key] = m
        }
        return m
    }

    private func compute(_ text: ResolvedText, _ p: ProposedViewSize) -> TextMeasurement {
        let scale = text.paragraph.displayScale
        let width = p.width.flatMap { $0.isFinite ? max($0, 0) : nil }
        let height = p.height.flatMap { $0.isFinite ? max($0, 0) : nil }
        if text.string.isEmpty {
            if p.width == 0 && p.height == 0 {
                return TextMeasurement(size: .zero, firstBaseline: 0, lastBaseline: 0)
            }
            let size = text.firstFont.size
            let b = TypesetTextMeasurer.roundPx(Double(emptyBaselineRatio * size), scale)
            return TextMeasurement(size: CGSize(width: 0, height: TypesetTextMeasurer.ceilPx(Double(emptyLineHeightRatio * size), scale)),
                                   firstBaseline: b, lastBaseline: b)
        }
        if p.width == 0 && p.height == 0 {
            // The minimum size of a text is 0 × 0 (04 §1, §3). Its baselines
            // stay those of its first line.
            let l = layout(text, width: nil, height: nil)
            let b = TypesetTextMeasurer.roundPx(l.firstBaseline, scale)
            return TextMeasurement(size: .zero, firstBaseline: b, lastBaseline: b)
        }
        let l = layout(text, width: width, height: height)
        var w = TypesetTextMeasurer.ceilPx(l.width, scale)
        if let pw = width {
            if l.brokeInsideWord { w = pw }
            w = min(w, pw)
        }
        var h = l.height
        if let minLines = text.paragraph.minimumLines, l.lines.count < minLines, let last = l.lines.last {
            let pitch = last.ascent + last.descent + last.leading + Double(text.paragraph.lineSpacing)
            h += Double(minLines - l.lines.count) * pitch
        }
        var unknown: Axis.Set = []
        if l.breaksUseEstimates {
            unknown = [.horizontal, .vertical]
        } else if l.widthUsesEstimates && !(l.brokeInsideWord && width != nil) {
            unknown = [.horizontal]
        }
        return TextMeasurement(size: CGSize(width: w, height: TypesetTextMeasurer.ceilPx(h, scale)),
                               firstBaseline: TypesetTextMeasurer.roundPx(l.firstBaseline, scale),
                               lastBaseline: TypesetTextMeasurer.roundPx(l.lastBaseline, scale),
                               unknown: unknown)
    }
}
