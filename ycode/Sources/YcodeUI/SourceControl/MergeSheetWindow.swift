import AppKit
import YcodeIDECore

/// The merge sheet's own window (`specs/ide/merge-sheet.md` §14.1): a
/// borderless child of the workspace window, attached below its toolbar.
/// The sheet's height comes from its content, so in an 880-point window it
/// ends at y 908, 28 below the parent's bottom edge, drawn over whatever
/// lies below; the parent is neither moved nor resized.
///
/// The window is `slideRoom` taller than the sheet, transparent above it, so
/// the appear animation (§10: the top edge from about y 20 to 52.5) is not
/// cut at the toolbar's bottom. It never constrains its frame to a screen.
@MainActor
public final class MergeSheetWindow: NSWindow {
    /// Room above the sheet for the slide (§10: 32 points).
    public static let slideRoom = CGFloat(MergeSheetMotion.slideDistance)

    /// The flipped, transparent content view holding the sheet.
    public let container = MergeSheetContainerView()

    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        contentView = container
    }

    // The sheet takes the keyboard (Return, Escape, the panes); the
    // workspace window stays the main window.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// It hangs below its parent, past the screen's bottom if it must.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The sheet's place in the parent: `frame` in the parent's coordinates
    /// (points from its top-left corner), converted to the screen.
    public func place(sheet frame: MergeSheetMetrics.Rect, in parent: NSWindow) {
        let p = parent.frame
        let top = p.maxY - CGFloat(frame.y)
        let r = NSRect(x: p.minX + CGFloat(frame.x), y: top - CGFloat(frame.height), width: CGFloat(frame.width),
                       height: CGFloat(frame.height) + Self.slideRoom)
        if r != self.frame { setFrame(r, display: isVisible) }
        container.sheetHeight = CGFloat(frame.height)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        invalidateShadow()
    }

    /// The sheet's frame in the parent window's coordinates (points from its
    /// top-left corner), as placed.
    public func sheetFrame(in parent: NSWindow) -> NSRect {
        let p = parent.frame, f = frame
        return NSRect(x: f.minX - p.minX, y: p.maxY - (f.maxY - Self.slideRoom), width: f.width, height: f.height - Self.slideRoom)
    }
}

/// The sheet window's content: transparent, flipped, the sheet's view
/// `slideRoom` below its top, filling the rest.
@MainActor
public final class MergeSheetContainerView: NSView {
    var sheetHeight: CGFloat = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public override func layout() {
        super.layout()
        for v in subviews {
            v.frame = NSRect(x: 0, y: MergeSheetWindow.slideRoom, width: bounds.width, height: max(0, bounds.height - MergeSheetWindow.slideRoom))
        }
    }

    // Clicks on the transparent room above the sheet do nothing.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
