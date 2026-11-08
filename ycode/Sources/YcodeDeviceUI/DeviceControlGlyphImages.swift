// The second capsule's glyphs on macOS (device-hub.md §13.1, rows 131–132)
// and the toolbar's Zoom to Fit (§14.1, row 156): Rotate, the three postures
// and the magnifier with four arrowheads drawn by Ycode from the shapes the Linux
// device window draws too (`DeviceControlGlyphs`, YcodeDeviceModel).

#if os(macOS)
import AppKit
import YcodeDeviceModel

public enum DeviceControlGlyphImage {
    public typealias G = DeviceControlGlyphs

    /// One shape as a path around (cx, cy) in a flipped space.
    static func path(_ s: G.Shape, cx: CGFloat, cy: CGFloat) -> NSBezierPath {
        switch s {
        case .roundedRect(let x, let y, let w, let h, let r):
            return NSBezierPath(roundedRect: NSRect(x: cx + x, y: cy + y, width: w, height: h), xRadius: r, yRadius: r)
        case .arc(let c, let r, let from, let to):
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: cx + c.x, y: cy + c.y), radius: r, startAngle: from * 180 / .pi, endAngle: to * 180 / .pi,
                        clockwise: false)
            return p
        case .polygon(let pts), .polyline(let pts):
            let p = NSBezierPath()
            for (i, q) in pts.enumerated() {
                let pt = NSPoint(x: cx + q.x, y: cy + q.y)
                if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
            }
            if case .polygon = s { p.close() }
            return p
        case .disc(let c, let r):
            return NSBezierPath(ovalIn: NSRect(x: cx + c.x - r, y: cy + c.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// Draws `g` centred in `rect` (flipped), lines and solids in `line`,
    /// fills in `fill`.
    static func draw(_ g: G.Glyph, in rect: NSRect, line: NSColor, fill: NSColor?) {
        let cx = rect.midX, cy = rect.midY
        if let fill {
            fill.setFill()
            for s in g.fills { path(s, cx: cx, cy: cy).fill() }
        }
        line.setStroke()
        for s in g.strokes {
            let p = path(s, cx: cx, cy: cy)
            p.lineWidth = g.lineWidth
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
        line.setFill()
        for s in g.solids { path(s, cx: cx, cy: cy).fill() }
    }

    static func size(_ g: G.Glyph) -> NSSize { NSSize(width: ceil(g.size.width) + 2, height: ceil(g.size.height) + 2) }

    /// Rotate: a template image (the button tints it).
    @MainActor
    public static func rotate() -> NSImage {
        let g = G.rotate
        let img = NSImage(size: size(g), flipped: true) { r in
            draw(g, in: r, line: .black, fill: nil)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Rotate"
        return img
    }

    /// Zoom to Fit (§14.1, row 156): a template image the size of the
    /// toolbar's other magnifiers (16 × 15), so the segment tints it.
    @MainActor
    public static func zoomToFit() -> NSImage {
        let g = G.zoomToFit
        let img = NSImage(size: NSSize(width: g.size.width, height: g.size.height), flipped: true) { r in
            draw(g, in: r, line: .black, fill: nil)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Zoom to Fit"
        return img
    }

    /// A posture in its colours for the appearance it is drawn in: the
    /// current one in the accent colour (§13.1).
    @MainActor
    public static func posture(_ p: G.Posture, current: Bool) -> NSImage {
        let g = G.posture(p)
        let img = NSImage(size: size(g), flipped: true) { r in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = G.postureColours(current: current, dark: dark)
            draw(g, in: r, line: color(c.line), fill: color(c.fill))
            return true
        }
        img.accessibilityDescription = "\(p)"
        return img
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
