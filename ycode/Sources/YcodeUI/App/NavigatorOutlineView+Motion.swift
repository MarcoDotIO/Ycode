import AppKit
import YcodeIDECore

/// The navigator outline's collapse by keyboard (`parity-inventory.md`
/// P-194, `Motion.outlineCollapse`): Left arrow on an expanded group slides
/// the rows below up over ≈ 75 ms (5 frames), where the outline collapsed
/// in one frame; the disclosure triangle's and the Right arrow's motion is
/// the system's (≈ 150–200 ms in both).
extension NavigatorOutlineView {
    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        guard OutlineCollapseMotion.isKeyCollapse(NSApp.currentEvent), !OutlineCollapseMotion.inAnimation, window?.isVisible == true else {
            super.collapseItem(item, collapseChildren: collapseChildren)
            return
        }
        OutlineCollapseMotion.inAnimation = true
        defer { OutlineCollapseMotion.inAnimation = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.outlineDuration(expand: false, byKey: true)
            context.allowsImplicitAnimation = true
            animator().collapseItem(item, collapseChildren: collapseChildren)
        }
        OutlineCollapseMotion.animatedCollapses += 1
    }
}

/// The state of a keyboard collapse.
@MainActor
enum OutlineCollapseMotion {
    /// Inside the animated collapse (the animator calls back into the outline).
    static var inAnimation = false
    /// The collapses animated so far (tests).
    static var animatedCollapses = 0

    /// Whether `event` is a Left arrow (with no modifier but Option, which
    /// collapses the children too).
    static func isKeyCollapse(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode == 123 else { return false }
        return event.modifierFlags.isDisjoint(with: [.command, .control, .shift])
    }
}
