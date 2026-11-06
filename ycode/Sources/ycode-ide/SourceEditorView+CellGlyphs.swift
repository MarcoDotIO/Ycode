import Foundation
import SwiftUI
import YcodeEditorKit

/// Cell characters on the editor's grid (`editor-area.md` E.7, checklist
/// row 75): a box-drawing, block, shape or braille character takes one
/// cell whatever its face's advance; a narrower glyph is centred in the
/// cell and a wider one clipped to it. Other text draws as before.
extension SourceEditorPainter {
    /// The rectangle (and ink strength) a Block Elements character fills in
    /// its cell `c` (the glyph's box): eighths, halves, the full block and
    /// the three shades; nil for the others.
    static func blockShape(_ v: UInt32, in c: CGRect) -> (CGRect, Double)? {
        let r = c.insetBy(dx: -0.25, dy: 0)
        func lower(_ n: CGFloat) -> CGRect { CGRect(x: r.minX, y: r.maxY - r.height * n / 8, width: r.width, height: r.height * n / 8) }
        func left(_ n: CGFloat) -> CGRect { CGRect(x: r.minX, y: r.minY, width: r.width * n / 8, height: r.height) }
        switch v {
        case 0x2580: return (CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2), 1)
        case 0x2581...0x2588: return (lower(CGFloat(v - 0x2580)), 1)
        case 0x2589...0x258F: return (left(CGFloat(0x2590 - v)), 1)
        case 0x2590: return (CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height), 1)
        case 0x2591: return (r, 0.25)
        case 0x2592: return (r, 0.5)
        case 0x2593: return (r, 0.75)
        case 0x2594: return (CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 8), 1)
        case 0x2595: return (CGRect(x: r.maxX - r.width / 8, y: r.minY, width: r.width / 8, height: r.height), 1)
        default: return nil
        }
    }

    /// Box Drawing and Block Elements.
    static func joinsNeighbours(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x2500...0x259F).contains(v)
    }

    func drawRuns(_ ctx: inout GraphicsContext, _ runs: [EditorRun], at x: CGFloat, y: CGFloat, font f: Font) {
        guard runs.contains(where: { EditorCellCharacters.contains($0.text) }) else {
            ctx.draw(text(runs).font(f), at: CGPoint(x: x, y: y), anchor: .topLeading)
            return
        }
        let layout = controller.layout
        let cell = max(layout.advance, 1)
        let height = controller.lineHeight
        var cx = x
        var pending: [EditorRun] = []
        var pendingX = x
        func flush(_ ctx: inout GraphicsContext) {
            guard !pending.isEmpty else { return }
            ctx.draw(text(pending).font(f), at: CGPoint(x: pendingX, y: y), anchor: .topLeading)
            pending = []
        }
        for r in runs {
            var chunk = ""
            for ch in r.text {
                guard EditorCellCharacters.isCell(ch) else {
                    if pending.isEmpty, chunk.isEmpty { pendingX = cx }
                    chunk.append(ch)
                    cx += layout.width(of: ch)
                    continue
                }
                if !chunk.isEmpty { pending.append(EditorRun(chunk, role: r.role)); chunk = "" }
                flush(&ctx)
                let glyph = ctx.resolve(text([EditorRun(String(ch), role: r.role)]).font(f))
                let measured = glyph.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                let w = measured.width
                // Block elements are drawn as the shapes they name, a hair
                // over their cell, so a row of them is one solid band.
                if let v = ch.unicodeScalars.first?.value,
                   let (rect, alpha) = Self.blockShape(v, in: CGRect(x: cx, y: y, width: cell, height: measured.height)) {
                    ctx.fill(Path(rect), with: .color(palette.color(r.role).color.opacity(alpha)))
                    cx += cell
                    continue
                }
                let box = CGRect(x: cx, y: y - height, width: cell, height: height * 3)
                // Block elements and box lines join their neighbours, so a
                // narrower face's glyph is widened to the cell (no seams);
                // other cell glyphs are centred.
                let stretch = Self.joinsNeighbours(ch) && w > 0 && w < cell ? cell / w : 1
                let left = stretch > 1 ? cx : cx + (cell - w) / 2
                ctx.drawLayer { layer in
                    layer.clip(to: Path(box))
                    if stretch > 1 {
                        layer.translateBy(x: left, y: y)
                        layer.scaleBy(x: stretch, y: 1)
                        layer.draw(glyph, at: .zero, anchor: .topLeading)
                    } else {
                        layer.draw(glyph, at: CGPoint(x: left, y: y), anchor: .topLeading)
                    }
                }
                cx += cell
            }
            if !chunk.isEmpty { pending.append(EditorRun(chunk, role: r.role)) }
        }
        flush(&ctx)
    }
}
