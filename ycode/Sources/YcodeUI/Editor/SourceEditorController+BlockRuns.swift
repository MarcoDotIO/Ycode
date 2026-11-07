import AppKit
import YcodeIDECore

/// Block elements join without seams (`editor-area.md` F.4, checklist row
/// 87): a full block drawn as a glyph comes out slightly wider than its
/// cell, and the antialiased edges of neighbours add up to a lighter line
/// at every cell edge. Paragraphs with solid block elements get a layout
/// fragment that draws each run of them on a visual row as filled shapes
/// in the run's colour (one rectangle per run of full blocks), with the
/// ink where F.1 measured it (13.5 of the 18-point row, its top 3.5 below
/// the row's top), and clips the glyphs away.
extension SourceEditorController {
    public nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                              in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let p = textElement as? NSTextParagraph, BlockRunLayoutFragment.hasSolidBlocks(p.attributedString.string) {
            return BlockRunLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A paragraph's layout with its block elements drawn as shapes.
final class BlockRunLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    static func hasSolidBlocks(_ s: String) -> Bool {
        s.unicodeScalars.contains { EditorTextGeometry.isSolidBlock($0.value) }
    }

    /// One run of block elements on a visual row: the cells it covers (the
    /// whole row's height, clipped from the glyph drawing) and the shapes
    /// to fill, in the fragment's coordinates.
    struct Run {
        var cells: CGRect
        var shapes: [(rect: CGRect, color: NSColor)]
    }

    /// The runs, from the laid-out rows.
    func blockRuns() -> [Run] {
        var out: [Run] = []
        for line in textLineFragments {
            let text = line.attributedString
            let ns = text.string as NSString
            let range = line.characterRange
            let row = line.typographicBounds
            let ink = EditorTextGeometry.blockInk(rowHeight: Double(row.height))
            var i = range.location
            while i < NSMaxRange(range) {
                guard EditorTextGeometry.isSolidBlock(UInt32(ns.character(at: i))) else { i += 1; continue }
                var j = i
                var shapes: [(rect: CGRect, color: NSColor)] = []
                var x = row.minX + line.locationForCharacter(at: i).x
                while j < NSMaxRange(range), EditorTextGeometry.isSolidBlock(UInt32(ns.character(at: j))) {
                    let next = row.minX + line.locationForCharacter(at: j + 1).x
                    let color = (text.attribute(.foregroundColor, at: j, effectiveRange: nil) as? NSColor) ?? .textColor
                    if let s = EditorTextGeometry.blockShape(UInt32(ns.character(at: j)), x: Double(x), width: Double(next - x),
                                                             top: Double(row.minY) + ink.top, height: ink.height) {
                        let r = CGRect(x: s.x, y: s.y, width: s.width, height: s.height)
                        // Neighbours of one shape and colour make one rectangle.
                        if let last = shapes.last, last.color == color, abs(last.rect.maxX - r.minX) < 0.01,
                           last.rect.minY == r.minY, last.rect.height == r.height {
                            shapes[shapes.count - 1].rect = last.rect.union(r)
                        } else {
                            shapes.append((r, color))
                        }
                    }
                    x = next
                    j += 1
                }
                let start = row.minX + line.locationForCharacter(at: i).x
                out.append(Run(cells: CGRect(x: start, y: row.minY, width: x - start, height: row.height), shapes: shapes))
                i = j
            }
        }
        return out
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let runs = blockRuns()
        guard !runs.isEmpty else { return super.draw(at: point, in: context) }
        context.saveGState()
        let all = renderingSurfaceBounds.offsetBy(dx: point.x, dy: point.y).insetBy(dx: -64, dy: -64)
        context.addRect(all)
        for r in runs { context.addRect(r.cells.offsetBy(dx: point.x, dy: point.y)) }
        context.clip(using: .evenOdd)
        super.draw(at: point, in: context)
        context.restoreGState()
        for r in runs {
            for s in r.shapes {
                context.setFillColor(s.color.cgColor)
                context.fill(s.rect.offsetBy(dx: point.x, dy: point.y))
            }
        }
    }
}
