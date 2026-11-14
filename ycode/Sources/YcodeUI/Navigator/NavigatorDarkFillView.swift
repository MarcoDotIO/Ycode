import AppKit
import YcodeIDECore

/// The navigator's background in dark (council round 10, row 245): a flat
/// #28282A (`WorkspaceChrome.navigatorDarkBackground`, the reference's mean
/// over a flat area of its navigator) over the sidebar material; in light
/// nothing, so the material shows as before. A sheet's dimming over the
/// window darkens it as it does the rest. The Linux IDE fills its navigator
/// with the same colour (`ShellColors.navigatorBackground`).
final class NavigatorDarkFillView: NSView {
    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The colour drawn (nil in light).
    var fillColor: NSColor? {
        guard isDark else { return nil }
        let v = WorkspaceChrome.navigatorDarkBackground
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = fillColor else { return }
        c.setFill()
        dirtyRect.fill()
    }
}
