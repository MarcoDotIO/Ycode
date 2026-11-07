import Foundation
import SwiftUI
import YcodeIDECore

/// The Linux source editor's grid, the macOS editor's one to one
/// (`specs/ide/cross-platform-parity.md` §4; `editor-area.md` §C.1, F.2):
/// an 18-point line at 13 points and the macOS editor's cell, 8.0 at 1x
/// and 8.04 at 2x. The bundled monospaced face (OpenViews' Noto Sans Mono,
/// 7.8 per character at 13 points) keeps its size; the app tracks it to the
/// macOS advance (`FontTracking.desktopMonospaced`, YcodeIDEApp.swift) and
/// the editor adds whatever is left (the 1x rounding to whole pixels, or
/// all of it without the font's tracking) per character, so columns, the
/// code column and the wrap edge land where the macOS editor puts them.
enum EditorCell {
    /// The macOS editor's own advance at 13 points, unrounded
    /// (`editor-area.md` F.2: 8.04 on a 2x display, 8.0 at 1x).
    static let referenceAdvance = 8.0361328125

    /// The cell at `fontSize` on a display of `scale`.
    static func advance(fontSize: CGFloat, scale: CGFloat) -> CGFloat {
        let own = referenceAdvance * Double(fontSize) / EditorMetrics.referenceFontSize
        return CGFloat(EditorTextGeometry.cellAdvance(fontAdvance: own, backingScale: Double(scale)))
    }

    /// The line pitch (`EditorMetrics.lineHeight`).
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        CGFloat(EditorMetrics.lineHeight(fontSize: Double(fontSize)))
    }

    /// How far a text box `textHeight` tall sits under its line's top.
    static func textDrop(lineHeight: CGFloat, textHeight: CGFloat) -> CGFloat {
        max(0, ((lineHeight - textHeight) / 2).rounded(.down))
    }

    /// Where a line number's baseline sits below its line's top, and how far
    /// its right edge is drawn inside the number column's end
    /// (`EditorMetrics.lineNumberEnd`): the macOS gutter's digits at 13
    /// points (ink tops 4 below the code's, ink ends 3 inside the column's
    /// end, measured on the paired parity shots; Inter's digits have a
    /// narrower right bearing than the macOS face's).
    static func numberBaseline(lineHeight: CGFloat) -> CGFloat { (lineHeight * 16 / 18).rounded() }
    static let numberInset: CGFloat = 2

    /// The source font, drawn on the cell.
    static func text(_ t: Text, font: Font, tracking: CGFloat) -> Text {
        tracking == 0 ? t.font(font) : t.font(font).tracking(tracking)
    }
}
