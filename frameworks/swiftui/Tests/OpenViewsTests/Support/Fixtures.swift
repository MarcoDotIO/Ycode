import Foundation
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

/// Measurement inputs, all taken from the spec.
///
/// Text: the reference font of `ReferenceFont` — vertical metrics from
/// 07 §1.2 and the measured single-line widths of the strings the golden
/// cases use, read from golden-layout.md (the probe frame of each text in
/// its own case, or the `text.*`, `font.*` and `dyn.*` rows). These are
/// *inputs*: the golden tests then check the layout arithmetic around them
/// (line heights and baselines on the pixel grid, stacking, spacing,
/// alignment, frames, distribution). Values printed as .33/.67 are thirds
/// of a point (scale 3), so they are entered as exact thirds.
enum Fixture {
    /// Stand-in for the probe's 43-character `longText`. Its content is not
    /// part of the spec; the stand-in keeps what the spec gives or implies:
    /// 43 characters, single-line width 339 (`text.long`), and 35 lines when
    /// broken after every character (`fixedSize.vertical` fit[0×0] = 768.33
    /// = 20.33 + 34 × 22), i.e. 35 non-space characters and 8 spaces (which
    /// hang at line ends). Its glyph widths are unknown, so answers that
    /// depend on where it wraps are skipped (and checked as relations with a
    /// real font in TextRelationTests).
    static let longText = "xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxx"

    static func th(_ v: Double) -> CGFloat { (v * 3).rounded() / 3 }

    static let bodyWidths: [String: CGFloat] = [
        "Hello": 39,                       // text.hello
        "World": 45,                       // text.twoLines: max(39, World) = 45
        longText: 339,                     // text.long
        "A": th(11.33), "B": 11,           // hstack.texts
        "Left": th(29.67), "Right": 40,    // hstack.spacer
        "Hi": 16,                          // zstack
        "Short": th(41.67), "Longer text": th(86.33),  // vstack.leading
        "Top": th(28.33), "Bottom": 56,    // vstack.spacer
        "One": th(31.67), "Two": th(31.33),            // alignmentGuide
        "Longer": th(53.33), "Wide cell": th(69.67),   // grid
        "X": th(11.33), "Fixed": th(40.67),            // grid.flex
        "short": th(39.67),                // viewThatFits
        "short words here": th(128.67),    // hstack.equalTexts
        // Round R8 (T-CTL): label widths implied by the control rows with
        // the control rules of README "Controls design (R8)" — inputs, like
        // the rows above; the other proposals of each row are the checks.
        "Tap": th(27.67),                  // button.default (borderless: the label)
        "Ycode": th(47.33),                // link
        "Title": 33,                       // label: 63 = 22 (star) + 8 + title
        "On": th(22.33),                   // toggle: 91.33 = title + 8 + 61
        "S": th(10.67),                    // stepper: 112.67 = title + 8 + 94
        "D": 12,                           // datePicker.compact: 142.67 − 130.67
        "G": th(12.33),                    // gauge: the label's width
        "Placeholder": 90,                 // textfield.plain
        "Password": th(73.33),             // secureField
        "Jan 1, 1970": th(98.67),          // datePicker.compact: 130.67 = 8 + 98.67 + 12 + 12
    ]

    /// Typesets with the reference font tables (ReferenceFont.swift).
    static let measurer = TypesetTextMeasurer(fonts: ReferenceFontProvider())

    /// Symbols: Ycode's own provider (round R5) in reference-parity mode
    /// (unknown names lay out 0 × 0). Its boxes are the spec's: `star` /
    /// `star.fill` at body size 22 × 20.67, baseline 3.67 above the bottom,
    /// natural (resizable) size 18.67 × 18 (07 §3, 04 §2).
    static let symbols = OpenSymbolProvider(missingSymbolsLayOutEmpty: true)

    static var engine: LayoutEngine { LayoutEngine(textMeasurer: measurer, symbols: symbols) }
}
