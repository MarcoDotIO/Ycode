import AppKit
import YcodeIDECore

/// Image files in the editor (`specs/ide/editor-area.md` §C.6): the image
/// viewer replaces the text, the jump bar names the file, and the File
/// inspector switches to the image's sections, all in one pass.
extension WorkspaceWindowController {
    /// The image viewer, while an image is shown.
    public var imageViewer: ImageViewerController? {
        get { imageViewerBox.controller }
        set { imageViewerBox.controller = newValue }
    }

    func showImage(_ url: URL) {
        if let shown = imageViewer, shown.url.standardizedFileURL == url.standardizedFileURL, editor.auxiliaryFile == url { return }
        let c = ImageViewerController(url: url)
        imageViewer = c
        c.onLoaded = { [weak self, weak c] props in
            guard let self, let c, self.imageViewer === c else { return }
            self.inspector.imageProperties = props
        }
        editor.showAuxiliary(c.view, path: jumpPath(for: url), file: url)
        editor.jumpBar.symbolTitle = "No Selection"

        inspector.imageProperties = nil
        inspector.show(file: url)
    }
}

/// Holds the image viewer for the window controller's extension.
@MainActor
final class ImageViewerBox {
    var controller: ImageViewerController?
}
