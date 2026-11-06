import AppKit
import YcodeIDECore

/// Image files in the editor (`specs/ide/editor-area.md` §C.6, E.3): the
/// image viewer replaces the text, the jump bar names the file, and the
/// File inspector switches to the image's sections, all in one pass. The
/// old content stays until the image is ready (checklist row 72): an
/// ordinary file decodes before the swap; a large one swaps in when it is
/// ready, or after `ImageViewerLayout.loadingDelay` with "Loading…".
extension WorkspaceWindowController {
    /// The image viewer, while an image is shown.
    public var imageViewer: ImageViewerController? {
        get { imageViewerBox.controller }
        set {
            imageViewerBox.controller = newValue
            imageViewerBox.pending = nil
        }
    }

    /// An image still decoding, not yet swapped in (tests).
    public var pendingImageViewer: ImageViewerController? { imageViewerBox.pending }

    func showImage(_ url: URL) {
        if let shown = imageViewer, OpenRequestKey.path(shown.url) == OpenRequestKey.path(url),
           editor.auxiliaryFile.map(OpenRequestKey.path) == OpenRequestKey.path(url) { return }
        if let pending = imageViewerBox.pending, OpenRequestKey.path(pending.url) == OpenRequestKey.path(url) { return }
        let c = ImageViewerController(url: url)
        c.onLoaded = { [weak self, weak c] props in
            guard let self, let c, self.imageViewer === c else { return }
            self.inspector.imageProperties = props
        }
        if c.isReady {
            swapIn(c)
            return
        }
        imageViewerBox.pending = c
        c.onReady = { [weak self, weak c] in
            guard let self, let c, self.imageViewerBox.pending === c else { return }
            self.swapIn(c)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ImageViewerLayout.loadingDelay) { [weak self, weak c] in
            MainActor.assumeIsolated {
                guard let self, let c, self.imageViewerBox.pending === c else { return }
                self.swapIn(c)
            }
        }
    }

    /// The viewer, the jump bar, the inspector and the status bar change
    /// together, in one frame.
    private func swapIn(_ c: ImageViewerController) {
        imageViewer = c
        let url = c.url
        editor.showAuxiliary(c.view, path: jumpPath(for: url), file: url)
        editor.jumpBar.symbolTitle = "No Selection"
        inspector.imageProperties = c.properties
        inspector.show(file: url)
        // No "Line: Col:" for an image (editor-area.md §D.7).
        debugArea.setPosition(line: 0, column: 0)
    }
}

/// Holds the image viewer for the window controller's extension.
@MainActor
final class ImageViewerBox {
    var controller: ImageViewerController?
    /// An image decoding off the main thread, shown when ready.
    var pending: ImageViewerController?
}
