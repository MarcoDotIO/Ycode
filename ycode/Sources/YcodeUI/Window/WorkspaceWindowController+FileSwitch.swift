import AppKit
import YcodeIDECore

/// Switching files (`editor-area.md` H.7, council rows 163 and 206). Round
/// 6 saw the reference draw the File inspector a frame after the new text,
/// and Ycode followed it (the inspector rebuilt just after the editor's
/// frame). Round 8 (row 206, at a light load) saw the reference change the
/// editor and the inspector **in one frame**, and Ycode's deferred rebuild
/// made the switch two frames 110 ms apart: the inspector is now rebuilt in
/// the same pass as the editor. The deferral stays available for
/// measurement (`InspectorFollow.isEnabled`).
extension WorkspaceWindowController {
    /// Shows `url` in the File inspector after the editor's frame.
    func showInspectorAfterEditor(file url: URL?) {
        let follow = inspectorFollowBox
        follow.generation += 1
        let onScreen = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard follow.isEnabled, onScreen || follow.defersOffscreen else {
            inspector.show(file: url)
            return
        }
        let g = follow.generation
        follow.pending = true
        // A run-loop timer, not the next turn of the main queue: the run
        // loop then waits, so the frame with the new content is committed
        // first.
        let timer = Timer(timeInterval: InspectorFollow.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.inspectorFollowBox.generation == g else { return }
                self.inspectorFollowBox.pending = false
                // Only if the editor still shows it (another editor may
                // have set the inspector since).
                guard self.isShowingInEditor(url) else { return }
                self.inspector.show(file: url)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Whether the editor area shows `url`: the image viewer's image, or
    /// the source editor's file.
    func isShowingInEditor(_ url: URL?) -> Bool {
        guard let url else { return false }
        if let v = imageViewer { return OpenRequestKey.path(v.url) == OpenRequestKey.path(url) }
        return editor.fileURL.map(OpenRequestKey.path) == OpenRequestKey.path(url)
    }

    /// Whether a deferred inspector rebuild is waiting (tests).
    public var isInspectorFollowPending: Bool { inspectorFollowBox.pending }
}

/// The deferred inspector rebuild's state.
@MainActor
final class InspectorFollow {
    /// After the editor's frame: about one frame at 120 Hz.
    static let delay: TimeInterval = 0.008
    var generation = 0
    var pending = false
    /// On: the inspector is rebuilt after the editor's frame (round 6's
    /// order); off (round 8, row 206): with the editor, in its frame.
    var isEnabled = false
    /// Defers off every display too (tests).
    var defersOffscreen = false
}
