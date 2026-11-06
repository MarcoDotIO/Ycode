import AppKit
import YcodeIDECore

/// The rows that scroll under the navigator's selector capsule show as
/// blurred smudges, not legible text (`liquid-glass.md` §9.2, checklist
/// row 69): an opaque backdrop in the capsule's shape, under the glass,
/// draws the outline beneath it blurred (σ about 6) at the capsule's share
/// and darkens it a little, so the capsule reads about #E8E8E9 over white
/// rows.
extension NavigatorAreaController {
    func installSelectorBackdrop(in root: NSView) {
        let backdrop = selectorBackdrop
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop, positioned: .below, relativeTo: selectorGlass)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: selectorGlass.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: selectorGlass.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: selectorGlass.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: selectorGlass.trailingAnchor),
        ])
        backdrop.sources = { [weak self] in self.map { [$0.scrollView] } ?? [] }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        selectorBackdropObserver.value = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                               queue: .main) { [weak backdrop] _ in
            MainActor.assumeIsolated { backdrop?.needsDisplay = true }
        }
    }
}

/// The observer token (a class so the extension can hold it).
final class ObserverBox {
    var value: NSObjectProtocol?
    deinit { if let value { NotificationCenter.default.removeObserver(value) } }
}

/// The capsule-shaped backdrop under the selector's glass.
final class SelectorBackdropView: NSView {
    var sources: () -> [NSView] = { [] }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The capsule's shape.
    var shape: NSBezierPath {
        let r = bounds.height / 2
        return NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let background = NSColor.textBackgroundColor
        background.setFill()
        bounds.fill()
        if let image = StructureBlur.image(of: bounds, in: self, sources: sources(), background: background) {
            StructureBlur.draw(image, for: bounds, in: self, share: CGFloat(BarBlur.selectorShare))
        }
        NSColor.labelColor.withAlphaComponent(CGFloat(BarBlur.selectorFill)).setFill()
        bounds.fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
    }
}
