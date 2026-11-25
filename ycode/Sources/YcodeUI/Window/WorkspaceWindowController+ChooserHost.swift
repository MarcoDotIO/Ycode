import AppKit
import YcodeIDECore

extension WorkspaceWindowController {
    /// P-183: the empty window New Project's template sheet sits on is
    /// bare, as the reference's: no navigator rows, no title in the
    /// toolbar, no scheme or destination, and no editor (so no text area
    /// or find bar is exposed to accessibility). The window keeps its
    /// accessibility title, "Untitled".
    func makeBareChooserHost() {
        activityView.workspaceName = ""
        activityView.status = ""
        navigator.workspaceName = ""
        if let scroll = navigator.outlineView.enclosingScrollView { scroll.isHidden = true } else { navigator.outlineView.isHidden = true }
        for p in [schemePopUp, destinationPopUp] { p.isHidden = true }
        editorArea.view.isHidden = true
        inspector.view.isHidden = true
    }

    /// Whether the window is the bare chooser host (tests).
    var isBareChooserHost: Bool {
        editorArea.view.isHidden && schemePopUp.isHidden && activityView.workspaceName.isEmpty
    }
}
