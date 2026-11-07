import AppKit

/// The debug bar's Activate / Deactivate Breakpoints glyph, Ycode's own
/// drawing (`specs/ide/editor-area.md` F.9, checklist row 110): a label
/// tag 17.5 × 11.5 points, a rounded rectangle whose right end is drawn to
/// a point. Filled in the accent colour (#007AFF) while breakpoints are
/// active; outlined while they are not. A template, tinted by the button.
enum BreakpointsToggleGlyph {
    /// The tag's size, points.
    static let size = NSSize(width: 17.5, height: 11.5)
    /// The pointed end's length, and the body's corner radius.
    static let pointLength: CGFloat = 4.5
    static let cornerRadius: CGFloat = 2.5

    /// The outline of the tag in `rect`.
    static func path(in rect: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let r = min(cornerRadius, rect.height / 2)
        let bodyEnd = rect.maxX - pointLength
        p.move(to: NSPoint(x: rect.minX + r, y: rect.minY))
        p.line(to: NSPoint(x: bodyEnd, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        p.line(to: NSPoint(x: bodyEnd, y: rect.maxY))
        p.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
        p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            if active {
                path(in: rect).fill()
            } else {
                let p = path(in: rect.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1.2
                p.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Deactivate breakpoints" : "Activate breakpoints"
        return image
    }
}
