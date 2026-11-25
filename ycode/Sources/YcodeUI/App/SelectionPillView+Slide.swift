import AppKit
import ObjectiveC
import QuartzCore
import YcodeIDECore

/// The navigator selector's disc moving between tabs (`parity-inventory.md`
/// P-193, `Motion.selectorDisc`): a click slides the disc from the old tab
/// to the new one, +147 → +430 ms on an ease-out, while the content swaps
/// at once; ⌘1 cross-fades it over 75 ms; ⌘2–⌘9 move it in one frame. Only
/// a pill with `slidesOnClick` set moves this way (the navigator's); the
/// others jump, as before.
extension SelectionPillView {
    private static var slidesKey = 0

    /// Whether a click slides this pill and ⌘1 cross-fades it.
    var slidesOnClick: Bool {
        get { (objc_getAssociatedObject(self, &Self.slidesKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.slidesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// How the disc moves for the event being handled.
    enum DiscMove: Equatable { case jump, slide, fade }

    /// The move for `event` to the tab tagged `index`.
    static func discMove(for event: NSEvent?, index: Int) -> DiscMove {
        switch event?.type {
        case .leftMouseDown?, .leftMouseUp?: .slide
        case .keyDown?: Motion.selectorKeyFade(index: index) > 0 ? .fade : .jump
        default: .jump
        }
    }

    /// Puts the pill at `rect` under `target`, sliding or fading there when
    /// the event asks for it.
    func move(to rect: NSRect, target: NSView, event: NSEvent? = NSApp.currentEvent) {
        let old = frame
        frame = rect
        guard slidesOnClick, !isHidden, old.width > 0, old.origin != rect.origin, let layer else { return }
        switch Self.discMove(for: event, index: (target as? NSControl)?.tag ?? -1) {
        case .jump:
            return
        case .fade:
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.selectorKeyFade(index: 0)
            layer.add(fade, forKey: "discFade")
        case .slide:
            let c = Motion.selectorDisc
            let slide = CABasicAnimation(keyPath: "position")
            let dx = old.midX - rect.midX, dy = old.midY - rect.midY
            slide.fromValue = NSValue(point: NSPoint(x: layer.position.x + dx, y: layer.position.y + (superview?.isFlipped == true ? -dy : dy)))
            slide.toValue = NSValue(point: layer.position)
            slide.duration = c.duration
            let b = c.bezier
            slide.timingFunction = CAMediaTimingFunction(controlPoints: Float(b.x1), Float(b.y1), Float(b.x2), Float(b.y2))
            slide.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + Self.discDelay
            slide.fillMode = .backwards
            layer.add(slide, forKey: "discSlide")
        }
    }

    /// From the click to the disc's first move: the reference's +147 less
    /// Ycode's own latency to its content swap (+78 in the parity run, where
    /// the reference swaps at +113).
    static var discDelay: Double { max(0, Motion.selectorDisc.start - 0.078) }
}
