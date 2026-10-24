import Foundation
import OVText
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
#else
@testable import SwiftUICore
#endif

/// The reference device's system font as *tables of values the spec
/// records* (07-text-images-color.md §1.2, golden-layout.md), used as a
/// test font so that the layout arithmetic around text can be checked
/// exactly without that font (which OpenViews must not use):
///
/// - ascent and descent ratios 0.952148 and 0.241211 of the point size
///   (07 §1.2: body 16.19 / 4.10 at 17 pt, large title 32.37 / 8.20 at 34,
///   … — the same two ratios fit every row to 0.01 pt);
/// - leading per point size (07 §1.2 column "leading");
/// - measured widths of whole runs (golden frames and `text.*`/`font.*`/`dyn.*`
///   rows: `Fixture.bodyWidths` and the generated `GoldenTextRuns`);
/// - spacing preferences of body and caption text from the default-spacing
///   matrix (04 §4.1).
///
/// Glyph advances are estimates (`TableFace`): any answer that needs the
/// width of text the spec did not measure (a wrapped line, a truncated
/// line) is reported as approximate and the golden runner skips that check.
enum ReferenceFont {
    static let ascentRatio = 0.952148
    static let descentRatio = 0.241211

    /// 07 §1.2, leading by point size.
    static let leading: [Double: Double] = [34: 0.43, 28: 0.59, 22: 1.75, 20: 1.13, 17: 1.71, 16: 1.91,
                                            13: 2.49, 12: 1.68, 11: -0.13]

    static func runs(weight: Int) -> [TableFace.Run: Double] {
        var r: [TableFace.Run: Double] = [:]
        for (key, w) in GoldenTextRuns.widths where key.weight == weight {
            r[TableFace.Run(key.text, size: key.size, weight: weight)] = w
        }
        if weight == 400 {
            for (s, w) in Fixture.bodyWidths { r[TableFace.Run(s, size: 17)] = Double(w) }
            r[TableFace.Run("Big", size: 34)] = Double(Fixture.th(47.67))   // hstack.baseline
            r[TableFace.Run("small", size: 12)] = Double(Fixture.th(29.67)) // hstack.baseline
        }
        if weight == 700 {
            r[TableFace.Run("Hello", size: 17, weight: 700)] = 41           // text.bold
        }
        return r
    }

    static func face(weight: Int, name: String) -> TableFace {
        TableFace(familyName: "Reference", styleName: name, traits: FontTraits(weight: weight),
                  ascentRatio: ascentRatio, descentRatio: descentRatio, leadingBySize: leading,
                  runs: runs(weight: weight))
    }

    static let regular = face(weight: 400, name: "Regular")
    static let semibold = face(weight: 600, name: "Semibold")
    static let bold = face(weight: 700, name: "Bold")
}

/// Fonts for the reference measurer.
struct ReferenceFontProvider: TextFontProvider {
    func face(for font: TextFont) -> any FontFace {
        let faces: [TableFace] = [ReferenceFont.regular, ReferenceFont.semibold, ReferenceFont.bold]
        let i = FontCatalog.bestMatch(faces.map(\.traits), for: FontTraits(weight: font.weight.weightClass))
        return faces[i]
    }

    func spacing(for font: TextFont) -> TextSpacing {
        switch font.size {
        // Body: 6.43 below a standard view, 10.64 above one (04 §4.1;
        // values within the matrix and grid cases, see README "Rules").
        case 17: return TextSpacing(above: SpacingPreference(kind: .text, towardStandard: 6.433, towardText: 2),
                                    below: SpacingPreference(kind: .text, towardStandard: 10.643, towardText: 2))
        // Caption: 4.56 and 7.53 (spacing matrix, row/column textCaption).
        case 12: return TextSpacing(above: SpacingPreference(kind: .text, towardStandard: 4.56, towardText: 2),
                                    below: SpacingPreference(kind: .text, towardStandard: 7.53, towardText: 2))
        default:
            let s = Double(font.size)
            return TextSpacing(
                above: SpacingPreference(kind: .text, towardStandard: CGFloat(1.33056 * s - ReferenceFont.ascentRatio * s), towardText: 2),
                below: SpacingPreference(kind: .text, towardStandard: CGFloat(0.86726 * s - ReferenceFont.descentRatio * s), towardText: 2))
        }
    }
}
