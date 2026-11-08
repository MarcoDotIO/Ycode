import AppKit
import YcodeIDECore

/// Switching files (`editor-area.md` H.7, council row 163): the new file's
/// content within about 210 ms of the click. The reference draws the
/// navigator, the jump bar and the new text in one frame and the File
/// inspector a frame later (text) or about 80 ms later (an image). On
/// screen Ycode does the same: the inspector is rebuilt just after the
/// frame that shows the new content, so its work (about a third of the
/// switch) no longer delays that frame. Off every display (tests) it is
/// rebuilt at once.
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
    /// Off: the inspector is rebuilt with the editor (measurements).
    var isEnabled = true
    /// Defers off every display too (tests).
    var defersOffscreen = false
}
