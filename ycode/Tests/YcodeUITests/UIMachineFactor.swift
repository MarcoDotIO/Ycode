import AppKit
import QuartzCore

/// How much slower than the reference Mac this machine lays out and draws
/// a window, for UI timing limits (B5-FIX-CI). A limit measured on the
/// owner's Mac (a debug build) stays as it is there and grows on a slower
/// machine (the 3-core CI runner draws without a GPU): the test's own
/// window is laid out and drawn in full, every view dirtied, and the
/// fastest of a few passes is compared with that pass on the reference
/// Mac. The factor is never below 1, so a fast machine keeps the tight
/// limit.
@MainActor
enum UIMachineFactor {
    /// One full layout and display of `w`'s frame view, fastest of
    /// `tries`, in milliseconds.
    static func fullRedrawMilliseconds(_ w: NSWindow, tries: Int = 3) -> Double {
        guard let frame = w.contentView?.superview else { return 0 }
        func dirty(_ v: NSView) {
            v.needsLayout = true
            v.needsDisplay = true
            v.subviews.forEach(dirty)
        }
        var best = Double.infinity
        for _ in 0..<max(1, tries) {
            let t0 = CACurrentMediaTime()
            dirty(frame)
            frame.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            best = min(best, (CACurrentMediaTime() - t0) * 1000)
        }
        return best
    }

    /// The factor for `w` against `referenceMilliseconds` (the same
    /// window's full redraw on the reference Mac), with the redraw time
    /// measured here.
    static func factor(_ w: NSWindow, referenceMilliseconds: Double) -> (factor: Double, redraw: Double) {
        let redraw = fullRedrawMilliseconds(w)
        return (max(1, redraw / referenceMilliseconds), redraw)
    }
}
