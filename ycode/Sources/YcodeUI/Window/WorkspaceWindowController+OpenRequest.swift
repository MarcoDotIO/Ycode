import AppKit
import YcodeIDECore

/// Open-document requests for a file the workspace holds (Finder, `open`,
/// the system's "open this file" event; `editor-area.md` E.4, checklist
/// row 73).
extension WorkspaceWindowController {
    /// The file the focused editor shows (or is about to: an image still
    /// decoding), if any.
    var shownDocumentURL: URL? { editor.fileURL ?? editor.auxiliaryFile ?? imageViewerBox.pending?.url }

    /// Opens `url` in the focused editor. A request for the file already
    /// shown changes nothing (no reload, no repaint); otherwise the file
    /// opens under the project's own path, so the inspector and the jump
    /// bar read as for a click in the navigator. Returns whether it opened
    /// anything.
    @discardableResult
    public func handleOpenRequest(_ url: URL) -> Bool {
        let key = OpenRequestKey.path(url)
        if let shown = shownDocumentURL, OpenRequestKey.path(shown) == key { return false }
        open(path: session.model.root.projectPath(forOpening: url) ?? url.path, line: nil)
        return true
    }
}
