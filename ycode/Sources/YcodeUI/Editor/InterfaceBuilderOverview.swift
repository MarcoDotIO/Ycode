import AppKit
import YcodeIDECore

/// The canvas overview at the canvas's top right (reference-ui-4.md §13
/// item 6): every scene as a small box, and the visible part of the canvas
/// as an accent outline. Drawn from the shared layout (`IBCanvasLayout.overview`),
/// as the Linux IDE draws it.
@MainActor
final class IBCanvasOverviewView: NSView {
    static let size = CGSize(width: 150, height: 96)
    weak var canvas: IBCanvasView?
    weak var scroll: NSScrollView?
    override var isFlipped: Bool { true }

    init(canvas: IBCanvasView, scroll: NSScrollView) {
        self.canvas = canvas
        self.scroll = scroll
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() { needsDisplay = true }

    /// What the panel shows (tests): the scene boxes and the visible rectangle.
    var drawn: (boxes: [CGRect], visible: CGRect?) {
        guard let layout = canvas?.layout else { return ([], nil) }
        let (_, boxes) = layout.overview(in: Self.size)
        let visible = scroll.map { layout.overviewRect($0.documentVisibleRect, in: Self.size) }
        return (boxes, visible)
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        panel.addClip()
        let (boxes, visible) = drawn
        for b in boxes {
            let path = NSBezierPath(roundedRect: b, xRadius: 2, yRadius: 2)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        }
        if let v = visible {
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: v.intersection(bounds.insetBy(dx: 1, dy: 1))).stroke()
        }
    }
}
