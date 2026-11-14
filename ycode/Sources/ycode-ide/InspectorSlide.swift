import Foundation
import Observation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Showing and hiding the inspector as the macOS IDE does
/// (`WorkspaceWindowController+InspectorSlide.swift`; `editor-area.md`
/// G.1, H.2; checklist rows 133, 158): the inspector slides rigidly by its
/// width while the editor resizes live: a hide ease-out (0, 0, 0.58, 1)
/// over 200 ms from 75 ms after the press, a show ease-in-out (0.42, 0,
/// 0.58, 1) over 230 ms from 170 ms (rows 204, 224, 248;
/// `EditorMetrics.inspectorSlideDelay`, `inspectorSlideMotion`,
/// `inspectorSlideCurve`). The
/// inspector toggle stays at the window's right edge throughout, as the
/// macOS toolbar keeps it.
@MainActor
@Observable
final class InspectorSlideState {
    /// The share of the inspector's width shown: 1 shown, 0 hidden.
    private(set) var progress: Double = 1
    /// From the press to the end of the motion.
    private(set) var isRunning = false
    /// Where the last slide went (nil until the window first shows).
    private(set) var shown: Bool?
    @ObservationIgnored private var generation = 0

    /// The inspector's state when the window first shows: no slide.
    func sync(_ isShown: Bool) {
        guard shown == nil else { return }
        shown = isShown
        progress = isShown ? 1 : 0
    }

    /// Whether the pane is sliding: also in the update where the model has
    /// changed and `run` has not been called yet, so the pane never leaves
    /// for a frame.
    func isSliding(modelShows: Bool) -> Bool { isRunning || (shown.map { $0 != modelShows } ?? false) }

    func run(show: Bool) {
        generation += 1
        let g = generation
        // A show starts from nothing; the pane is in place before it moves.
        if show, !isRunning, progress > 0.999 { progress = 0 }
        shown = show
        isRunning = true
        let delay = EditorMetrics.inspectorSlideDelay(show: show), motion = EditorMetrics.inspectorSlideMotion(show: show)
        let c = EditorMetrics.inspectorSlideCurve(show: show)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == g else { return }
            withAnimation(.timingCurve(c.x1, c.y1, c.x2, c.y2, duration: motion)) { self.progress = show ? 1 : 0 }
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
            .frame(minWidth: isRunning ? shown : 220, idealWidth: isRunning ? shown : width, maxWidth: isRunning ? shown : 400, alignment: .leading)
            .clipped()
    }
}
