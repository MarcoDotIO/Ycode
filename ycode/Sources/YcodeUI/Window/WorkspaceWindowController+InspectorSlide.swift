import AppKit
import QuartzCore
import YcodeIDECore

/// Showing and hiding the inspector (`specs/ide/editor-area.md` §C.7,
/// H.2, J.3; `fidelity-council.md` rows 9, 158, 204, 248): the inspector
/// slides rigidly by its width while the editor resizes live, every frame: a
/// hide ease-out over 200 ms from 75 ms after the press, a show ease-in-out
/// over 230 ms from 170 ms (`EditorMetrics.inspectorSlideProgress`); the editor's scrollers are
/// not flashed by it. The divider moves one display frame at a
/// time from the press; the inspector's contents keep their width pinned to
/// the divider, so nothing in them reflows.
extension WorkspaceWindowController {
    /// View ▸ Inspectors ▸ Show / Hide Inspector, and the toolbar button.
    @objc public func toggleInspector(_ sender: Any?) {
        slideInspector(show: inspectorItem.isCollapsed)
    }

    /// Whether a slide is running (tests).
    public var isInspectorSliding: Bool { inspectorSlide.running }

    func slideInspector(show: Bool) {
        let split = mainSplit.splitView
        guard let window, window.isVisible, !inspectorSlide.running, split.subviews.count >= 3 else {
            if !inspectorSlide.running { inspectorItem.isCollapsed = !show }
            return
        }
        guard show == inspectorItem.isCollapsed else { return }
        let state = inspectorSlide
        // The curve's clock starts at the press, not at the first frame:
        // the work below would otherwise delay the first motion past the
        // measured 43 / 118 ms (editor-area.md F.5: 48 and about 120 ms).
        // A first frame later than the motion's start begins the motion
        // there instead (InspectorSlideClock, W7.3, row 190).
        let press = CACurrentMediaTime()
        // From here to the last frame (the collapse change and the first
        // layout below would otherwise fit the toolbar mid-slide).
        state.running = true
        state.ending = false
        state.minimum = inspectorItem.minimumThickness
        let total = split.bounds.width
        let divider = split.dividerThickness
        let width: CGFloat
        // The split view collapses a pane dragged narrower than about half
        // its usual width, and opens it again only past that: a divider set
        // there frame by frame would leave the pane collapsed for the first
        // 40 % of a show (the edge still, then a jump: round 8, row 204) and
        // collapse it before the end of a hide. The pane cannot collapse
        // while it slides; the hide collapses it once, at the end.
        state.canCollapse = inspectorItem.canCollapse
        if show {
            // The pane stays collapsed until the motion's first frame (rows
            // 224, 248: the reference's edge first moves 136–225 ms after the
            // click; opening the 1-point pane at the press moved it at +57).
            width = max(inspectorItem.minimumThickness, state.lastWidth ?? Self.inspectorWidth)
            inspectorItem.minimumThickness = 1
            inspectorItem.canCollapse = false
            state.paneOpened = false
        } else {
            width = inspector.view.frame.width
            state.lastWidth = width
            inspectorItem.minimumThickness = 1
            inspectorItem.canCollapse = false
        }
        // Every editor's top line stays through the slide (row 223).
        for e in editorArea.allEditors { e.textView.beginMotionAnchor() }
        inspector.beginRigidSlide(width: width)
        // The contents are laid out and drawn at their width before the
        // first frame, so the inspector never slides in blank.
        inspector.view.layoutSubtreeIfNeeded()
        inspector.view.displayIfNeeded()
        // The shown pane's edge is where the split view lays it out at rest,
        // its width from the window's right edge (the thin divider lies over
        // it). Row 248: one divider's width less moved the edge a point with
        // the hide's first frame, before the slide's start, and left the
        // shown pane a point wider than at rest.
        state.from = show ? total - divider - 1 : total - width
        state.to = show ? total - width : total - divider - 1
        state.show = show
        state.clock = InspectorSlideClock(show: show, press: press)
        // Nothing but the slide's own layout runs per frame: the bars keep
        // their blurred image, and the toolbar is fitted and updated once
        // at the end (row 106).
        EditorBlurMotion.begin()
        EditorScrollView.quietScrollersUntil = .infinity
        let link = split.displayLink(target: state, selector: #selector(InspectorSlideState.step(_:)))
        state.onFrame = { [weak self] progress in self?.inspectorSlideFrame(progress) }
        link.add(to: .main, forMode: .common)
        state.link = link
    }

    private func inspectorSlideFrame(_ progress: CGFloat) {
        let state = inspectorSlide
        // Only the running slide's frames, up to its last one.
        guard state.running, !state.ending else { return }
        let split = mainSplit.splitView
        // A show opens the pane with its first moving frame, in the same
        // pass as that frame's position.
        if state.show, !state.paneOpened {
            guard progress > 0 else { return }
            state.paneOpened = true
            inspectorItem.isCollapsed = false
        }
        let x = (state.from + (state.to - state.from) * progress).rounded()
        split.setPosition(x, ofDividerAt: 1)
        guard progress >= 1 else { return }
        state.link?.invalidate()
        state.link = nil
        // The last frame shows the slide's end: the pane at its width, or
        // the hidden pane collapsed (not a sliver of its minimum width).
        inspector.endRigidSlide()
        inspectorItem.canCollapse = state.canCollapse
        if !state.show { inspectorItem.isCollapsed = true }
        inspectorItem.minimumThickness = state.minimum
        // The rest of the end (the bars' render, the toolbar's update and
        // fit) follows that frame's commit instead of holding it back (row
        // 204: the last frame came 70–130 ms after the one before it). A
        // run-loop timer: the run loop commits the frame before it waits
        // for it. Off every display it follows at once (tests), unless asked.
        let onScreen = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard onScreen || InspectorSlideState.defersEndOffscreen else { return finishInspectorSlide() }
        state.ending = true
        let timer = Timer(timeInterval: 0.008, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishInspectorSlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The slide's end, after its last frame.
    private func finishInspectorSlide() {
        let state = inspectorSlide
        guard state.running else { return }
        state.ending = false
        state.running = false
        EditorBlurMotion.end()
        EditorScrollView.quietScrollersUntil = CACurrentMediaTime() + EditorScrollView.quietAfterSlide
        updateToolbarState()
        scheduleToolbarFit()
    }

    var inspectorSlide: InspectorSlideState { inspectorSlideBox }
}

/// A running slide: the divider's travel, the curve's clock, the display
/// link that steps it.
@MainActor
final class InspectorSlideState: NSObject {
    var link: CADisplayLink?
    /// From the press to the last frame.
    var running = false
    /// The curve's time from the press (W7.3: a late start still plays it).
    var clock: InspectorSlideClock?
    var from: CGFloat = 0
    var to: CGFloat = 0
    var show = false
    var minimum: CGFloat = 0
    /// The pane's `canCollapse` before the slide.
    var canCollapse = true
    /// A show's pane is open (it opens with the motion's first frame).
    var paneOpened = true
    /// The last position is drawn; the slide's end follows.
    var ending = false
    /// Defers the slide's end past its last frame off every display too
    /// (tests that step the frames as a display does).
    static var defersEndOffscreen = false
    var lastWidth: CGFloat?
    var onFrame: ((CGFloat) -> Void)?

    /// The measured duration (`EditorMetrics.inspectorSlideDuration`).
    static let duration = EditorMetrics.inspectorSlideDuration

    @objc func step(_ link: CADisplayLink) {
        // Times are those of the frames being drawn, from the press; motion
        // starts after the measured delay (editor-area.md §D.5), or with
        // the first frame when that comes later (W7.3), on H.2's curves.
        let now = link.targetTimestamp
        var c = clock ?? InspectorSlideClock(show: show, press: now)
        let progress = c.progress(at: now)
        clock = c
        onFrame?(CGFloat(progress))
    }
}
