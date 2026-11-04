import AppKit
import QuartzCore
import YcodeIDECore

/// Showing and hiding the inspector (`specs/ide/editor-area.md` §C.7,
/// `fidelity-council.md` row 9): the inspector slides rigidly by its
/// width while the editor resizes live, every frame, over about 215 ms on
/// the measured progress curve. The divider moves one display frame at a
/// time from the press; the inspector's contents keep their width pinned to
/// the divider, so nothing in them reflows.
extension WorkspaceWindowController {
    /// View ▸ Inspectors ▸ Show / Hide Inspector, and the toolbar button.
    @objc public func toggleInspector(_ sender: Any?) {
        slideInspector(show: inspectorItem.isCollapsed)
    }

    /// Whether a slide is running (tests).
    public var isInspectorSliding: Bool { inspectorSlide.link != nil }

    func slideInspector(show: Bool) {
        let split = mainSplit.splitView
        guard let window, window.isVisible, inspectorSlide.link == nil, split.subviews.count >= 3 else {
            if inspectorSlide.link == nil { inspectorItem.isCollapsed = !show }
            return
        }
        guard show == inspectorItem.isCollapsed else { return }
        let state = inspectorSlide
        state.minimum = inspectorItem.minimumThickness
        let total = split.bounds.width
        let divider = split.dividerThickness
        let width: CGFloat
        if show {
            width = max(inspectorItem.minimumThickness, state.lastWidth ?? Self.inspectorWidth)
            inspectorItem.minimumThickness = 1
            inspectorItem.isCollapsed = false
            split.setPosition(total - divider - 1, ofDividerAt: 1)
        } else {
            width = inspector.view.frame.width
            state.lastWidth = width
            inspectorItem.minimumThickness = 1
        }
        inspector.beginRigidSlide(width: width)
        state.from = show ? total - divider - 1 : total - divider - width
        state.to = show ? total - divider - width : total - divider - 1
        state.show = show
        state.start = nil
        let link = split.displayLink(target: state, selector: #selector(InspectorSlideState.step(_:)))
        state.onFrame = { [weak self] progress in self?.inspectorSlideFrame(progress) }
        link.add(to: .main, forMode: .common)
        state.link = link
    }

    private func inspectorSlideFrame(_ progress: CGFloat) {
        let state = inspectorSlide
        let split = mainSplit.splitView
        let x = (state.from + (state.to - state.from) * progress).rounded()
        split.setPosition(x, ofDividerAt: 1)
        guard progress >= 1 else { return }
        state.link?.invalidate()
        state.link = nil
        inspector.endRigidSlide()
        if !state.show { inspectorItem.isCollapsed = true }
        inspectorItem.minimumThickness = state.minimum
        updateToolbarState()
    }

    var inspectorSlide: InspectorSlideState { inspectorSlideBox }
}

/// A running slide: the divider's travel, the curve's clock, the display
/// link that steps it.
@MainActor
final class InspectorSlideState: NSObject {
    var link: CADisplayLink?
    var start: CFTimeInterval?
    var from: CGFloat = 0
    var to: CGFloat = 0
    var show = false
    var minimum: CGFloat = 0
    var lastWidth: CGFloat?
    var onFrame: ((CGFloat) -> Void)?

    /// The measured duration (`EditorMetrics.inspectorSlideDuration`).
    static let duration = EditorMetrics.inspectorSlideDuration

    @objc func step(_ link: CADisplayLink) {
        // Times are those of the frames being drawn; the first sets the
        // clock (the last still frame), and motion follows on the next.
        let now = link.targetTimestamp
        guard let start else { start = now; onFrame?(0); return }
        let t = min(1, (now - start) / Self.duration)
        onFrame?(CGFloat(EditorMetrics.inspectorSlideProgress(t)))
    }
}
