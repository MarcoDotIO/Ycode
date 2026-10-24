import AppKit

extension SourceTextView {
    /// Draws the stop annotation as a green label at the line's right end.
    func drawStopAnnotation(_ text: String, in r: NSRect) {
        let s = NSAttributedString(string: "  \(text)  ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
        let size = s.size()
        let box = NSRect(x: max(r.maxX - size.width - 8, r.minX + 200), y: r.minY, width: size.width, height: r.height)
        NSColor.systemGreen.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        s.draw(at: NSPoint(x: box.minX, y: box.minY + (box.height - size.height) / 2))
    }
}
