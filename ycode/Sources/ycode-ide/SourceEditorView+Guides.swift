import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeSyntax

/// Editor Options' Scope Guides, Invisibles and Code Coverage on Linux
/// (P-065), drawn as the macOS editor draws them
/// (`SourceEditorController+Guides.swift`, `GutterView.drawCoverage`):
/// a thin line from below each block's first line to above its last at the
/// column where that line's text starts; `·` for spaces, `→` for tabs and
/// `¬` at line ends in the tertiary label colour; a 4-point coverage strip
/// 4 inside the gutter's end, red where a line never ran and a faint grey
/// where it did.
extension SourceEditorController {
    /// The blocks the scope guides draw (0-based lines), kept per text.
    func scopeGuideBlocks() -> [SyntaxBlock] {
        if let c = guideCache.value, c.revision == buffer.textRevision { return c.blocks }
        let blocks = buffer.document.blocks().filter { $0.endLine - $0.startLine >= 2 }
        guideCache.value = (buffer.textRevision, blocks)
        return blocks
    }
}

/// The scope guides' blocks for one text revision.
final class EditorGuideCache {
    var value: (revision: Int, blocks: [SyntaxBlock])?
}

/// The labels' shades the macOS guides use, in either appearance.
enum EditorGuideColors {
    /// `tertiaryLabelColor`: black at 26 % in light, white at 25 % in dark.
    static func tertiary(dark: Bool) -> Color { dark ? Color.white.opacity(0.25) : Color.black.opacity(0.26) }
    /// `secondaryLabelColor`: black at 50 %, white at 55 %.
    static func secondary(dark: Bool) -> Color { dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5) }
    /// The guides: the tertiary label at 35 %.
    static func guide(dark: Bool) -> Color { tertiary(dark: dark).opacity(0.35) }
    static func coverage(count: Int, dark: Bool) -> Color { count == 0 ? Color.red.opacity(0.6) : secondary(dark: dark).opacity(0.25) }
}

extension SourceEditorPainter {
    /// Scope guides and invisibles under the visible lines.
    func drawEditorGuides(_ ctx: inout GraphicsContext, lines: Range<Int>, textX: CGFloat) {
        let p = Preferences.shared
        if p.scopeGuides != .none { drawScopeGuides(&ctx, lines: lines, textX: textX) }
        if p.showInvisibles { drawInvisibles(&ctx, lines: lines, textX: textX) }
    }

    func drawScopeGuides(_ ctx: inout GraphicsContext, lines: Range<Int>, textX: CGFloat) {
        let c = controller
        let doc = c.buffer.document
        let color = EditorGuideColors.guide(dark: colors.dark)
        for b in c.scopeGuideBlocks() where b.endLine >= lines.lowerBound && b.startLine < lines.upperBound {
            guard b.startLine + 1 < doc.lineCount, b.endLine < doc.lineCount else { continue }
            let top = c.lineTop(b.startLine + 1) - c.top, bottom = c.lineTop(b.endLine) - c.top
            guard bottom > top else { continue }
            // The column where the block's first line's text starts.
            let r = doc.lineRange(b.startLine)
            var at = r.lowerBound
            while at < r.upperBound, doc.units[at] == 32 || doc.units[at] == 9 { at += 1 }
            let x = textX + c.layout.x(ofOffset: at, line: b.startLine, in: c.buffer) + c.layout.advance * 0.5
            ctx.fill(Path(CGRect(x: x.rounded(.down), y: top, width: 1, height: bottom - top)), with: .color(color))
        }
    }

    func drawInvisibles(_ ctx: inout GraphicsContext, lines: Range<Int>, textX: CGFloat) {
        let c = controller
        let doc = c.buffer.document
        let color = EditorGuideColors.tertiary(dark: colors.dark)
        let marks: [UInt16: GraphicsContext.ResolvedText] = [
            32: ctx.resolve(styled(Text(verbatim: "·")).foregroundStyle(color)),
            9: ctx.resolve(styled(Text(verbatim: "→")).foregroundStyle(color)),
            10: ctx.resolve(styled(Text(verbatim: "¬")).foregroundStyle(color)),
        ]
        let lh = c.lineHeight
        for n in lines where n < doc.lineCount {
            let r = doc.lineRange(n)
            let y0 = c.lineTop(n) - c.top + c.textDrop
            var o = r.lowerBound
            // Very long lines: their beginning only (as the text, EditorLineLayout.longLine).
            let end = min(r.upperBound, r.lowerBound + EditorLineLayout.longLine)
            while o < end {
                if let m = marks[doc.units[o]] {
                    let p = c.position(ofOffset: o, line: n)
                    ctx.draw(m, at: CGPoint(x: textX + p.x, y: y0 + CGFloat(p.row) * lh), anchor: .topLeading)
                }
                o += 1
            }
            // The line's end, when a newline follows.
            if r.upperBound < doc.units.count, doc.units[r.upperBound] == 10, let m = marks[10] {
                let p = c.position(ofOffset: r.upperBound, line: n)
                ctx.draw(m, at: CGPoint(x: textX + p.x, y: y0 + CGFloat(p.row) * lh), anchor: .topLeading)
            }
        }
    }

    /// Editor ▸ Code Coverage: the gutter's strip per executable line
    /// (1-based `coverage`, from the newest run that gathered coverage).
    func drawCoverage(_ ctx: inout GraphicsContext, lines: Range<Int>) {
        guard !coverage.isEmpty else { return }
        let c = controller
        let w: CGFloat = 4
        for n in lines {
            guard let count = coverage[n + 1] else { continue }
            let top = c.lineTop(n) - c.top
            let bottom = n + 1 < c.buffer.document.lineCount ? c.lineTop(n + 1) - c.top : top + c.lineHeight
            ctx.fill(Path(CGRect(x: c.gutterWidth - 4 - w, y: top, width: w, height: max(c.lineHeight, bottom - top))),
                     with: .color(EditorGuideColors.coverage(count: count, dark: colors.dark)))
        }
    }
}
