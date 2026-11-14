import AppKit

/// A borderless floating panel on the system's glass material (macOS 26
/// and later), for transient pickers such as Open Quickly
/// (`specs/ide/liquid-glass-ycode.md` §7). It becomes key so its search
/// field takes typing, and it closes when it stops being key (a click
/// elsewhere, another window). Reduce Transparency and Increase Contrast
/// are the material's own.
@available(macOS 26, *)
@MainActor
final class GlassPanel: NSPanel {
    let controller: NSViewController
    /// Called once when the panel closes.
    var onClose: (() -> Void)?
    private var closing = false

    init(content controller: NSViewController, cornerRadius: CGFloat) {
        self.controller = controller
        let size = controller.view.frame.size
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = cornerRadius
        glass.contentView = controller.view
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        guard !closing else { return }
        closing = true
        parent?.removeChildWindow(self)
        super.close()
        onClose?()
    }

    /// Shows the panel centered over `window`'s upper part, above it: its
    /// top `top` points below the window's top (nil: 18 % of the window's height).
    func show(over window: NSWindow, top: CGFloat? = nil) {
        let f = window.frame
        setFrameOrigin(NSPoint(x: (f.midX - frame.width / 2).rounded(),
                               y: (f.maxY - (top ?? f.height * 0.18) - frame.height).rounded()))
        window.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }

    /// A new height with the top edge where it was (Open Quickly follows
    /// its results, council round 9, row 215).
    func setHeightKeepingTop(_ height: CGFloat) {
        var f = frame
        f.origin.y += f.height - height
        f.size.height = height
        setFrame(f, display: true)
    }
}
