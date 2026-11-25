import Foundation
import Observation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Showing and hiding a pane as the macOS IDE does
/// (`WorkspaceWindowController+InspectorSlide.swift`, `+PaneSlide.swift`;
/// `editor-area.md` G.1, H.2; checklist rows 133, 158; P-190–P-192): the
/// pane slides by its size while the editor resizes live, on beta 5's
/// curves (`Motion`): the inspector hides ease-out over 275 ms from 72 ms
/// after the press and shows ease-in-out over 242 ms from 21 ms (⌥⌘1/2/3
/// on the shown inspector: 300 and 266 ms); the navigator slides 290
/// points over 240 ms, ease-in-out (`window-layout.md` §6.1); the debug
/// area moves linearly over ≈ 250 ms (§6.2). The
/// inspector toggle stays at the window's right edge throughout, as the
/// macOS toolbar keeps it. The toolkit draws the frames (B5-OPENVIEWS,
/// P-200: until it draws every display frame a slide shows 2–3 positions).
@MainActor
@Observable
final class PaneSlideState {
    /// Which pane slides (its curves).
    enum Pane { case navigator, inspector, debugArea }
    let pane: Pane
    /// The share of the pane's size shown: 1 shown, 0 hidden.
    private(set) var progress: Double = 1
    /// From the press to the end of the motion.
    private(set) var isRunning = false
    /// Where the last slide went (nil until the window first shows).
    private(set) var shown: Bool?
    @ObservationIgnored private var generation = 0

    init(_ pane: Pane) { self.pane = pane }

    /// The curve for a slide (`bySelector`: ⌥⌘1/2/3 on the inspector).
    func curve(show: Bool, bySelector: Bool = false, trigger: Motion.NavigatorTrigger = .key) -> Motion.Curve {
        switch pane {
        case .navigator: Motion.navigator(show: show, trigger: trigger)
        case .inspector: Motion.inspector(show: show, bySelector: bySelector)
        case .debugArea: Motion.debugArea(show: show)
        }
    }

    /// The pane's state when the window first shows: no slide.
    func sync(_ isShown: Bool) {
        guard shown == nil else { return }
        shown = isShown
        progress = isShown ? 1 : 0
    }

    /// Whether the pane is sliding: also in the update where the model has
    /// changed and `run` has not been called yet, so the pane never leaves
    /// for a frame.
    func isSliding(modelShows: Bool) -> Bool { isRunning || (shown.map { $0 != modelShows } ?? false) }

    func run(show: Bool, bySelector: Bool = false, trigger: Motion.NavigatorTrigger = .key) {
        generation += 1
        let g = generation
        // A show starts from nothing; the pane is in place before it moves.
        if show, !isRunning, progress > 0.999 { progress = 0 }
        shown = show
        isRunning = true
        let c = curve(show: show, bySelector: bySelector, trigger: trigger)
        let b = c.bezier, motion = c.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + c.delay) { [weak self] in
            guard let self, self.generation == g else { return }
            withAnimation(.timingCurve(b.x1, b.y1, b.x2, b.y2, duration: motion)) { self.progress = show ? 1 : 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + motion + 0.02) { [weak self] in
                guard let self, self.generation == g else { return }
                self.isRunning = false
                if show { self.progress = 1 }
            }
        }
    }
}

/// The inspector pane: its usual limits at rest; while sliding, the
/// contents keep their width pinned to the divider and the pane shows the
/// sliding share of it.
struct InspectorSlidePane<Content: View>: View, Animatable {
    var progress: Double
    var isRunning: Bool
    @ViewBuilder var content: () -> Content

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let width = CGFloat(WorkspaceChrome.inspectorWidth)
        let shown = max(0, (width * CGFloat(progress)).rounded())
        // One chain at rest and while sliding, so the column keeps its state.
        content()
            .frame(width: isRunning ? width : nil)
            .frame(minWidth: isRunning ? shown : CGFloat(NarrowWindowLayout.inspectorMinimum), idealWidth: isRunning ? shown : width,
                   maxWidth: isRunning ? shown : 400, alignment: .leading)
            .clipped()
    }
}

/// The navigator column: its usual limits at rest; while sliding, the
/// contents keep their width and leave by the window's leading edge (P-190).
/// A narrowing window never shrinks it (P-024: it collapses instead).
struct NavigatorSlidePane<Content: View>: View, Animatable {
    var progress: Double
    var isRunning: Bool
    @ViewBuilder var content: () -> Content

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The narrowest a divider drag makes the navigator.
    static var dragMinimum: CGFloat { 135 }

    var body: some View {
        let width = CGFloat(WorkspaceChrome.navigatorWidth)
        let shown = max(0, (width * CGFloat(progress)).rounded())
        content()
            .frame(width: isRunning ? width : nil)
            .frame(minWidth: isRunning ? shown : Self.dragMinimum, idealWidth: isRunning ? shown : width,
                   maxWidth: isRunning ? shown : 500, alignment: .trailing)
            .clipped()
    }
}

/// The debug area under the editor: its height asked for at rest; while
/// sliding, the contents keep their height and the pane shows the sliding
/// share of it from its top (P-191).
struct DebugSlidePane<Content: View>: View, Animatable {
    var progress: Double
    var isRunning: Bool
    @ViewBuilder var content: () -> Content

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let height = CGFloat(WorkspaceChrome.debugAreaHeight)
        let shown = max(0, (height * CGFloat(progress)).rounded())
        content()
            .frame(height: isRunning ? height : nil)
            .frame(minHeight: isRunning ? shown : 80, idealHeight: isRunning ? shown : height, maxHeight: isRunning ? shown : 600, alignment: .top)
            .clipped()
    }
}
