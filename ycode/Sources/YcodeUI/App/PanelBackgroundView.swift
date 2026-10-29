import AppKit

/// The root view of sheets and popovers: paints the window background color
/// itself, so the content is opaque wherever it is shown (a sheet, a
/// popover whose material may not draw, or an offscreen capture) and the
/// semantic label colors stay readable.
///
/// On macOS 26 and later a popover's background is the system's glass
/// material, which this view leaves alone: it paints only in a titled
/// window (a sheet, a panel, an editor) or with no window at all (an
/// offscreen capture). A popover's window is borderless
/// (`specs/ide/liquid-glass-ycode.md` §6).
@MainActor
public final class PanelBackgroundView: NSView {

    /// Whether the view paints its background in `window`.
    public static func paints(in window: NSWindow?) -> Bool {
        guard #available(macOS 26, *), let window else { return true }
        return window.styleMask.contains(.titled)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard Self.paints(in: window) else { return }
        NSColor.windowBackgroundColor.setFill()
        // Only inside our bounds: offscreen captures can pass a dirty rect
        // that reaches past this view and would paint over its neighbors.
        bounds.intersection(dirtyRect).fill()
    }
}
