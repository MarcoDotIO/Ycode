// Ycode's own device glyphs (AGENTS.md rule 5: no trademark-shaped
// symbols, so no product symbols such as the phone or tablet SF Symbols):
// simple outlines drawn as template images, so a view tints them. Used by
// the hub's sidebar rows (§5.2: coloured with a lit screen while running,
// grey otherwise) and the iPhone Duo's pose buttons (§4.4: Closed is a
// closed phone, Open a flat tablet).

#if os(macOS)
import AppKit
import YcodeDeviceModel

public enum DeviceGlyph: String, Sendable, CaseIterable {
    /// A phone, upright.
    case phone
    /// A tablet, upright.
    case tablet
    /// A headset: a wide visor.
    case headset
    /// The iPhone Duo open flat: a wide panel with its hinge.
    case openFlat

    public static func of(_ family: DeviceFamily) -> DeviceGlyph {
        switch family {
        case .phone: .phone
        case .pad: .tablet
        case .vision: .headset
        }
    }

    /// A template image `size` points tall; `lit` fills the screen.
    @MainActor
    public func image(height: CGFloat = 16, lit: Bool = false) -> NSImage {
        let (aspect, radius): (CGFloat, CGFloat) = switch self {
        case .phone: (0.52, 0.16)
        case .tablet: (0.74, 0.10)
        case .headset: (1.7, 0.42)
        case .openFlat: (1.42, 0.10)
        }
        let w = (height * aspect).rounded(), h = height
        let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
            let line: CGFloat = 1.3
            let body = rect.insetBy(dx: line / 2, dy: line / 2)
            let r = min(body.width, body.height) * radius
            let outline = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
            outline.lineWidth = line
            NSColor.black.setStroke()
            outline.stroke()
            let inset: CGFloat = self == .headset ? 2.6 : 2.4
            let screen = body.insetBy(dx: inset, dy: inset)
            if lit, screen.width > 0, screen.height > 0 {
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: screen, xRadius: max(0, r - inset / 2), yRadius: max(0, r - inset / 2)).fill()
            }
            if self == .openFlat {
                let hinge = NSBezierPath()
                hinge.move(to: NSPoint(x: body.midX, y: body.minY + 1))
                hinge.line(to: NSPoint(x: body.midX, y: body.maxY - 1))
                hinge.lineWidth = 0.9
                hinge.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = rawValue
        return img
    }
}
#endif
