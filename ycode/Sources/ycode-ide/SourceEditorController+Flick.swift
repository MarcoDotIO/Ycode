import Foundation
import YcodeIDECore
#if os(Linux)
import OVPlatform
import SwiftUI
#endif

// The Linux editor's scrolling with the touchpad's phases (B6-OPENVIEWS;
// `editor-area.md` §D.3 and H.1, council rows 25 and 157), as the macOS
// editor's `EditorScrollView`:
//
// - precise (touchpad) deltas move the text 1:1, a wheel notch three times
//   the toolkit's step (about two lines);
// - the gesture's first event moves the text (no hold); every event queued
//   before a frame is applied before that frame (the toolkit drains its
//   queue first), so a burst lands in one frame;
// - momentum that would carry the text past the top or the bottom starts
//   `EditorFlick`'s bounce (TopBounce's constants, shared with macOS): a new
//   position every display frame until it is at rest.
extension SourceEditorController {
    #if os(Linux)
    /// One scroll event over the editor; true when used.
    func scrollEvent(_ e: ScrollEvent) -> Bool {
        let precise = e.isPrecise || e.hasPhase
        let k: CGFloat = precise ? 1 : 3
        let maxY = max(0, contentHeight - viewport.height)
        var usedX = false
        if e.delta.width != 0 {
            let mx = max(0, contentWidth - viewport.width)
            let nx = min(max(left - e.delta.width * k, 0), mx)
            if nx != left {
                scroll(x: nx, y: flick.isBouncing ? max(0, min(top, maxY)) : top)
                usedX = true
            }
        }
        let step = EditorFlick.Step(dy: Double(e.delta.height * k), phase: Self.flickPhase(e.phase),
                                    momentumPhase: Self.flickPhase(e.momentumPhase), time: e.timestamp)
        switch flick.handle(step, offset: Double(top), maxOffset: Double(maxY), visibleHeight: Double(viewport.height)) {
        case .scroll(let y):
            connection?.requestFrame(flickFrames, fire: nil)
            scroll(x: left, y: CGFloat(y))
            return true
        case .bounce(let edge):
            scroll(x: left, y: edge == .top ? 0 : maxY)
            connection?.requestFrame(flickFrames) { [weak self] t in self?.flickFrame(at: t) }
            return true
        case .held:
            return true
        case .ignored:
            return usedX
        }
    }

    /// One frame of the bounce: the text past its edge by the spring's
    /// overscroll, or back at the edge once it rests.
    private func flickFrame(at t: TimeInterval) {
        let maxY = max(0, contentHeight - viewport.height)
        let edge = flick.bounce?.edge ?? .top
        let period = 1.0 / 60
        guard let x = flick.overscroll(at: t, frame: period) else {
            top = edge == .top ? 0 : maxY
            lastScroll = now
            invalidate()
            return
        }
        top = edge == .top ? -CGFloat(x) : maxY + CGFloat(x)
        lastScroll = now
        invalidate()
        connection?.requestFrame(flickFrames) { [weak self] t in self?.flickFrame(at: t) }
    }

    private static func flickPhase(_ p: ScrollPhase) -> EditorFlick.Phase {
        switch p {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        }
    }
    #endif
}
