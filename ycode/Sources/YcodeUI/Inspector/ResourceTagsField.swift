import AppKit

/// The On Demand Resource Tags field of a resource (an image) in the File
/// inspector (`editor-area.md` §D.8, H.7; council row 162): a filled
/// rounded box 24 tall, #E0E0E1 in light (black at 10 % in dark), its
/// "Tags" placeholder (#707071 in light) 6.5 inside the field and centred
/// vertically. The Linux IDE draws the same (`FileInspectorView`).
@MainActor
enum ResourceTagsStyle {
    /// The field's fill.
    static let fill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.labelColor.withAlphaComponent(0.10)
            : NSColor(srgbRed: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE1 / 255, alpha: 1)
    }
    /// The placeholder's colour.
    static let placeholder = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.placeholderTextColor
            : NSColor(srgbRed: 0x70 / 255, green: 0x70 / 255, blue: 0x71 / 255, alpha: 1)
    }
    /// The placeholder's ink from the field's left edge.
    static let inkInset: CGFloat = 6.5
}

/// The field: its fill follows its appearance.
final class ResourceTagsField: NSTokenField {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFill()
    }

    func updateFill() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ResourceTagsStyle.fill.cgColor
        }
    }
}

/// The field's cell: the text (and the placeholder) start so their ink is
/// `ResourceTagsStyle.inkInset` inside, centred on the field's height.
final class ResourceTagsFieldCell: NSTokenFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let font = self.font ?? .systemFont(ofSize: 11)
        let line = ceil(font.ascender - font.descender + font.leading)
        // A text cell draws its text 2 inside its drawing rect; the glyph's
        // own side bearing is about half a point at this size.
        let x = ResourceTagsStyle.inkInset - 2 - 0.5
        // Centred: the line box's ink (cap height and descender) sits a
        // point below its middle, so it starts a point higher.
        let y = ((rect.height - line) / 2).rounded(.down) - 1
        return NSRect(x: rect.minX + x, y: rect.minY + y, width: max(0, rect.width - x - 4), height: line)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
}
