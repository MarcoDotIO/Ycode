import AppKit
import YcodeIDECore

/// Draws Ycode's glyphs on the destination's pixel grid (council round 10,
/// rows 243, 244 and 246): the drawing is moved by less than a pixel and
/// its strokes set to whole pixels (`FileGlyphs.pixelAligned`) for where
/// it lands in the current context, a window's backing store or a bitmap,
/// so straight runs draw at full colour at 1x. The Linux IDE does the same
/// from the glyph's place in its window (`ycode-ide/NavigatorRowIcons.swift`).
@MainActor
enum GlyphPixelGrid {
    /// Fills and strokes `d` in `color` with its box's top left at `rect`'s
    /// top left in the current context, whose user space is the view's
    /// (`flipped`: y down).
    static func draw(_ d: GlyphDrawing, in rect: NSRect, color: NSColor, flipped: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if flipped {
            ctx.translateBy(x: rect.minX, y: rect.minY)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
        }
        let aligned = alignedForContext(d, ctx: ctx)
        // `NavigatorRowImages.fill` expects y down, which the transform gives.
        let flippedContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flippedContext
        NavigatorRowImages.fill(aligned, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `d` aligned for a context whose user space has the glyph's box at
    /// its origin, y down.
    static func alignedForContext(_ d: GlyphDrawing, ctx: CGContext) -> GlyphDrawing {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = Double(hypot(t.a, t.b))
        guard scale > 0 else { return d }
        let o = CGPoint.zero.applying(t), right = CGPoint(x: 1, y: 0).applying(t), down = CGPoint(x: 0, y: 1).applying(t)
        // Each glyph axis against the device axis it runs along (a negative
        // direction mirrors the pixel phase, which aligns the same way).
        let ox = Double(right.x >= o.x ? o.x : -o.x) / scale
        let oy = Double(down.y >= o.y ? o.y : -o.y) / scale
        return FileGlyphs.pixelAligned(d, origin: (ox, oy), scale: (scale * 4).rounded() / 4)
    }
}
