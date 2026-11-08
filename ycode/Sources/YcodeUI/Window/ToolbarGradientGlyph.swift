import AppKit
import YcodeIDECore

/// Toolbar glyphs drawn with a fill of their own (`editor-area.md` H.9,
/// council row 166): New Conversation's speech bubble with a plus, filled
/// with a pink-to-purple gradient from its top leading corner
/// (`WorkspaceChrome.newConversationGradient`), not tinted by the toolbar.
@MainActor
enum ToolbarGradientGlyph {
    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// The glyph as a non-template image.
    static func newConversation(pointSize: CGFloat = 15) -> NSImage {
        let name = WorkspaceChrome.newConversation.symbols[0]
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "New Conversation")?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) else { return NSImage() }
        let g = WorkspaceChrome.newConversationGradient
        let gradient = NSGradient(starting: rgb(g.start), ending: rgb(g.end))
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            // The gradient over the symbol's ink only.
            NSGraphicsContext.current?.compositingOperation = .sourceAtop
            gradient?.draw(in: rect, angle: -45)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "New Conversation"
        return image
    }
}
