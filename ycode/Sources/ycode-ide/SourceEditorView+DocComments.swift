import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore

/// Documentation comments in the proportional face (P-054,
/// `EditorDocCommentStyle`), as the macOS editor draws them: the text after
/// `///` (and inside `/** … */`) in the system face at the source size, its
/// delimiters on the grid. `EditorLineLayout` gives those characters their
/// proportional widths (carets, selection, hit testing); here they are
/// drawn at the same places, on the source font's baseline.
extension ShellFonts {
    static func docComment(_ size: CGFloat) -> Font {
        .system(size: CGFloat(EditorDocCommentStyle.pointSize(sourceSize: Double(size))))
    }
}

extension SourceEditorPainter {
    /// A documentation comment character's width in the proportional face,
    /// measured with the context of the frame.
    func docCommentMeasure(_ measuring: GraphicsContext, _ c: SourceEditorController) -> (Character) -> CGFloat {
        let font = ShellFonts.docComment(c.fontSize)
        return { ch in measuring.resolve(Text(verbatim: String(ch)).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width }
    }

    /// A line with documentation comment text: the grid's runs as before,
    /// each proportional run in the system face at its layout position.
    func drawDocCommentRuns(_ ctx: inout GraphicsContext, _ runs: [EditorRun], at x: CGFloat, y: CGFloat, font f: Font) {
        let c = controller
        let docFont = ShellFonts.docComment(c.fontSize)
        let shift = docCommentShift(&ctx, font: f, docFont: docFont)
        var cx = x
        var grid: [EditorRun] = []
        var gridX = x
        func flush(_ ctx: inout GraphicsContext) {
            guard !grid.isEmpty else { return }
            drawRuns(&ctx, grid, at: gridX, y: y, font: f)
            grid = []
        }
        for r in runs {
            if r.proportional {
                flush(&ctx)
                let t = Text(verbatim: r.text).font(docFont).foregroundStyle(palette.color(r.role).color)
                ctx.draw(t, at: CGPoint(x: cx, y: y + shift), anchor: .topLeading)
                cx += r.text.reduce(0) { $0 + c.layout.proportionalWidth(of: $1) }
            } else {
                if grid.isEmpty { gridX = cx }
                grid.append(r)
                cx += r.text.reduce(0) { $0 + c.layout.width(of: $1) }
            }
        }
        flush(&ctx)
    }

    /// The proportional face's top below the source font's top, so both
    /// sit on one baseline (measured once per size).
    func docCommentShift(_ ctx: inout GraphicsContext, font f: Font, docFont: Font) -> CGFloat {
        if let s = controller.docCommentBaselineShift { return s }
        let unbounded = CGSize(width: CGFloat.infinity, height: .infinity)
        let mono = ctx.resolve(styled(Text(verbatim: "Hg"))).firstBaseline(in: unbounded)
        let prop = ctx.resolve(Text(verbatim: "Hg").font(docFont)).firstBaseline(in: unbounded)
        let s = (mono - prop).rounded()
        controller.docCommentBaselineShift = s
        return s
    }
}
