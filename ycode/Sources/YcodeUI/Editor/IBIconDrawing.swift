import AppKit
import YcodeIDECore

/// Draws an `IBIcon` (shapes in a 16 × 16 box, IBLibraryObjects.swift) with
/// AppKit: the Library's 34-point object icons and the Document Outline's
/// 16-point ones. The Linux IDE draws the same shapes on a canvas.
enum IBIconDrawing {
    static func color(_ p: IBIcon.Paint) -> NSColor { NSColor(srgbRed: p.r, green: p.g, blue: p.b, alpha: p.a) }

    static func image(_ icon: IBIcon, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: size / 16, y: size / 16)
            for s in icon.shapes { draw(s) }
            return true
        }
    }

    static func draw(_ s: IBIcon.Shape) {
        switch s {
        case .rect(let r, let radius, let fill, let stroke, let width, let dashed):
            let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            if let f = fill { color(f).setFill(); p.fill() }
            if let st = stroke {
                color(st).setStroke()
                p.lineWidth = width
                if dashed { p.setLineDash([2, 1.5], count: 2, phase: 0) }
                p.stroke()
            }
        case .oval(let r, let fill, let stroke, let width):
            let p = NSBezierPath(ovalIn: r)
            if let f = fill { color(f).setFill(); p.fill() }
            if let st = stroke { color(st).setStroke(); p.lineWidth = width; p.stroke() }
        case .lines(let pts, let stroke, let width, let closed):
            let p = NSBezierPath()
            for (i, q) in pts.enumerated() { if i == 0 { p.move(to: q) } else { p.line(to: q) } }
            if closed { p.close() }
            p.lineWidth = width
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            color(stroke).setStroke()
            p.stroke()
        case .polygon(let pts, let fill):
            let p = NSBezierPath()
            for (i, q) in pts.enumerated() { if i == 0 { p.move(to: q) } else { p.line(to: q) } }
            p.close()
            color(fill).setFill()
            p.fill()
        case .arc(let center, let radius, let from, let to, let stroke, let width):
            // Flipped drawing: angles run clockwise on screen as given.
            let p = NSBezierPath()
            p.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
            p.lineWidth = width
            color(stroke).setStroke()
            p.stroke()
        case .text(let t, let center, let size, let bold, let c):
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            let a = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color(c)])
            let sz = a.size()
            a.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
        }
    }
}
