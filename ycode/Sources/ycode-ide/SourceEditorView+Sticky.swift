import Foundation
import SwiftUI
import YcodeIDECore

// The sticky first line of the enclosing declaration (#58,
// `specs/ui/glass-materials.md` §3.2; the macOS editor's `ScopeHeaderView`):
// when the first visible line lies inside a declaration whose own first
// line has scrolled above the editor's top, that line is pinned under the
// jump bar in an opaque band of the editor's background, with its number
// in the gutter, then a 2-point separator across the gutter and the text.
// The lines below scroll under it and are clipped at its separator. No
// fade, no blur (§3.1).

/// The fold regions of a document, kept per text revision (they are found
/// again only when the text changes).
@MainActor
enum StickyLineRegions {
    private static var cache: [ObjectIdentifier: (revision: Int, regions: [FoldRegion])] = [:]

    static func regions(_ c: SourceEditorController) -> [FoldRegion] {
        let b = c.buffer
        let key = ObjectIdentifier(c)
        if let hit = cache[key], hit.revision == b.textRevision { return hit.regions }
        let language = SourceTokenizer.Language(fileName: (c.document.path as NSString).lastPathComponent)
        let regions = FoldRegions.regions(in: b.text, language: language)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = (b.textRevision, regions)
        return regions
    }
}

extension SourceEditorPainter {
    /// The sticky lines (1-based) for the controller's scroll position.
    static func stickyLines(_ c: SourceEditorController) -> [Int] {
        guard Preferences.shared.showCodeStructureHeaders, c.top > SourceEditorController.topInset, c.visualRowCount > 0 else { return [] }
        let doc = c.buffer.document
        let lineHeight = c.lineHeight
        return GlassMaterials.stickyLines(regions: StickyLineRegions.regions(c), firstVisibleLine: { below in
            let row = Int((c.top + CGFloat(below) - SourceEditorController.topInset) / lineHeight)
            return c.line(atRow: min(max(0, row), c.visualRowCount - 1)) + 1
        }, lineHeight: Double(lineHeight)) { l in
            guard l >= 1, l <= doc.lineCount else { return "" }
            return doc.lineText(l - 1)
        }
    }

    /// Draws the sticky band at the canvas's top (after the text and the
    /// gutter, so the lines beneath are clipped at its separator).
    func drawStickyLines(_ ctx: inout GraphicsContext, size: CGSize) {
        let c = controller
        let lines = Self.stickyLines(c)
        guard !lines.isEmpty else { return }
        let lh = c.lineHeight
        let pad = CGFloat(EditorMetrics.stickyHeaderTopPad)
        // The reference's band (y 85–104) starts on the divider's second
        // row; here the canvas starts below the 2-point rule, so the band is
        // one point shorter and its separator lands on the same rows.
        let band = CGFloat(EditorMetrics.stickyHeaderHeight(rows: lines.count, lineHeight: Double(lh))) - CGFloat(GlassMaterials.stickyOverlapsDivider)
        let sep = CGFloat(GlassMaterials.stickySeparatorHeight)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: band)), with: .color(palette.background.color))
        let rule = GlassMaterials.stickySeparator(dark: colors.dark)
        ctx.fill(Path(CGRect(x: 0, y: band, width: size.width, height: sep / 2)), with: .color(rule.top.color))
        ctx.fill(Path(CGRect(x: 0, y: band + sep / 2, width: size.width, height: sep / 2)), with: .color(rule.bottom.color))
        let f = font(c)
        let numberFont = Font.system(size: CGFloat(EditorMetrics.lineNumberFontSize(sourceSize: Double(c.fontSize)))).monospacedDigit()
        let textX = c.textOrigin - c.left
        for (i, l) in lines.enumerated() {
            let top = pad - CGFloat(GlassMaterials.stickyOverlapsDivider) + CGFloat(i) * lh
            let line = c.layout.displayLine(l - 1, in: c.buffer)
            ctx.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: c.gutterWidth, y: top, width: max(0, size.width - c.gutterWidth), height: lh)))
                if !line.runs.isEmpty {
                    drawRuns(&layer, line.runs, at: textX + CGFloat(line.firstColumn) * c.layout.advance, y: top + c.textDrop, font: f)
                }
            }
            let t = ctx.resolve(Text(verbatim: "\(l)").font(numberFont).foregroundStyle(palette.lineNumber.color))
            let base = t.firstBaseline(in: CGSize(width: 200, height: 100))
            ctx.draw(t, at: CGPoint(x: c.numberRight, y: top + EditorCell.numberBaseline(lineHeight: lh) - base), anchor: .topTrailing)
        }
    }
}
