import AppKit
import YcodeIDECore

/// Image files in the editor (`specs/ide/editor-area.md` §C.6, E.3, F.8;
/// checklist rows 72 and 109): the image viewer replaces the text at once,
/// the jump bar names the file, and the File inspector switches to the
/// image's sections, all in one pass. An ordinary file decodes before the
/// swap, so its image is in that frame; a large one swaps in as an empty
/// canvas with its "Open with Preview" button, the image appears when it
/// has decoded, "Loading…" only once it has taken
/// `ImageViewerLayout.loadingDelay`, and the inspector reads "--" for
/// the properties not read yet.
extension WorkspaceWindowController {
    /// The image viewer, while an image is shown.
    public var imageViewer: ImageViewerController? {
        get { imageViewerBox.controller }
        set { imageViewerBox.controller = newValue }
    }

    func showImage(_ url: URL) {
        if let shown = imageViewer, OpenRequestKey.path(shown.url) == OpenRequestKey.path(url),
           editor.auxiliaryFile.map(OpenRequestKey.path) == OpenRequestKey.path(url) { return }
        let c = ImageViewerController(url: url)
        c.onLoaded = { [weak self, weak c] props in
            guard let self, let c, self.imageViewer === c else { return }
            self.inspector.imageProperties = props
        }
        swapIn(c)
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
}
