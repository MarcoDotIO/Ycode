import AppKit

/// The root view of sheets and popovers: paints the window background color
/// itself, so the content is opaque wherever it is shown (a sheet, a
/// popover whose material may not draw, or an offscreen capture) and the
/// semantic label colors stay readable.
@MainActor
public final class PanelBackgroundView: NSView {

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // Only inside our bounds: offscreen captures can pass a dirty rect
        // that reaches past this view and would paint over its neighbors.
        bounds.intersection(dirtyRect).fill()
    }
}
