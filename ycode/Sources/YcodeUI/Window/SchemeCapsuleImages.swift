import AppKit
import YcodeIDECore

/// The scheme capsule's pictures on macOS (`SchemeCapsuleIcons`, council
/// round 8, row 199): the scheme's app icon (or Ycode's plain app tile) and
/// this computer's destination glyph, a laptop tinted the system blue on a
/// laptop. Drawn as images of their own (not templates), so the toolbar
/// does not tint them grey.
@MainActor
enum SchemeCapsuleImages {
    /// The glyph slot's side in the capsule.
    static let side: CGFloat = 16

    /// The scheme's icon: its target's app icon, rounded, else the tile.
    static func schemeImage(appIcon url: URL?) -> NSImage {
        let picture = url.flatMap { NSImage(contentsOf: $0) }
        let s = side
        let image = NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
            let inset = (s - CGFloat(SchemeAppTile.side)) / 2
            let r = NSRect(x: inset, y: inset, width: CGFloat(SchemeAppTile.side), height: CGFloat(SchemeAppTile.side))
            let shape = NSBezierPath(roundedRect: r, xRadius: CGFloat(SchemeAppTile.corner), yRadius: CGFloat(SchemeAppTile.corner))
            if let picture {
                NSGraphicsContext.current?.imageInterpolation = .high
                shape.addClip()
                picture.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                return true
            }
            drawTile(in: r, shape: shape)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = picture == nil ? "App" : "App Icon"
        return image
    }

    /// Ycode's plain app tile (`SchemeAppTile`), in the drawing appearance.
    static func drawTile(in r: NSRect, shape: NSBezierPath) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let g = SchemeAppTile.gradient(dark: dark)
        NSGradient(starting: rgb(g.top), ending: rgb(g.bottom))?.draw(in: shape, angle: 90)
        rgb(g.rim).setStroke()
        let rim = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: CGFloat(SchemeAppTile.corner), yRadius: CGFloat(SchemeAppTile.corner))
        rim.lineWidth = 0.5
        rim.stroke()
        NSColor.white.withAlphaComponent(0.85).setFill()
        for b in SchemeAppTile.bars {
            NSBezierPath(roundedRect: NSRect(x: r.minX + CGFloat(b.x), y: r.minY + CGFloat(b.y), width: CGFloat(b.w), height: CGFloat(b.h)),
                         xRadius: CGFloat(b.h / 2), yRadius: CGFloat(b.h / 2)).fill()
        }
    }

    /// This computer's destination glyph: the system's laptop or desktop
    /// symbol, blue on a laptop, the label colour otherwise.
    static func hostImage(_ form: SchemeCapsuleIcons.HostForm = SchemeCapsuleIcons.currentHostForm) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: form.symbol, accessibilityDescription: "My Mac")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return nil }
        guard form == .laptop else { return symbol }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            symbol.draw(in: rect)
            rgb(SchemeCapsuleIcons.hostGlyphTint(form, dark: dark) ?? 0).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "My Mac"
        return image
    }

    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// A pop-up cell that leaves a non-template image to the button's
/// `ColourGlyphView` (it keeps the image's room): drawn in the cell, the
/// toolbar's glass rendered it as a grey glyph (council round 8, row 199:
/// an empty square for the app icon, a dark monitor for the blue laptop).
/// Template images draw as before.
final class ColourImagePopUpCell: NSPopUpButtonCell {
    override func drawImage(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let image = menuItem?.image, !image.isTemplate { return }
        super.drawImage(withFrame: cellFrame, in: controlView)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        guard image.isTemplate else { return }
        super.drawImage(image, withFrame: frame, in: controlView)
    }
}

/// A picture in its own colours over a pop-up's image slot: a plain view
/// without vibrancy (as the issue capsule's symbols), which the toolbar
/// neither tints nor dims.
final class ColourGlyphView: NSView {
    var image: NSImage? { didSet { needsDisplay = true; isHidden = image == nil } }
    var dimmed = false { didSet { if oldValue != dimmed { needsDisplay = true } } }
    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let s = image.size
        let r = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.5 : 1, respectFlipped: true, hints: nil)
    }

    /// Places the view over `button`'s image slot with the selected item's
    /// picture when it is not a template (hidden otherwise).
    static func update(_ glyph: ColourGlyphView, in button: NSPopUpButton) {
        if glyph.superview !== button { button.addSubview(glyph) }
        guard let cell = button.cell as? NSPopUpButtonCell, let image = button.selectedItem?.image, !image.isTemplate,
              button.imagePosition != .noImage else {
            glyph.image = nil
            return
        }
        glyph.frame = cell.imageRect(forBounds: button.bounds).integral
        glyph.image = image
        glyph.dimmed = !button.isEnabled
    }
}

/// The scheme pop-up of the capsule (its app icon in colour).
final class SchemePopUpButton: NSPopUpButton {
    let glyph = ColourGlyphView()

    override class var cellClass: AnyClass? {
        get { ColourImagePopUpCell.self }
        set {}
    }

    override func layout() {
        super.layout()
        ColourGlyphView.update(glyph, in: self)
    }

    override func select(_ item: NSMenuItem?) {
        super.select(item)
        needsLayout = true
    }

    override func selectItem(at index: Int) {
        super.selectItem(at: index)
        needsLayout = true
    }
}
