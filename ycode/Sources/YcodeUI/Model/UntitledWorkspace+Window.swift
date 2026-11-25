import AppKit
import YcodeIDECore

extension NewProjectFlow {
    /// The empty workspace window the template sheet sits on, centred on
    /// the visible frame of `screen` (the screen New Project was started
    /// from, P-023).
    @MainActor
    static func emptyWorkspaceWindow(on screen: NSScreen? = nil) -> WorkspaceWindowController {
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: .untitled()), loadDestinations: false, startLanguageService: false,
                                           userStateURL: nil)
        wc.window?.title = "Untitled"
        wc.makeBareChooserHost()   // P-183
        if let window = wc.window, let visible = screen?.visibleFrame {
            window.setFrame(centered(window.frame.size, in: visible), display: false)
        }
        return wc
    }

    /// A frame of `size` centred in `visible`, never larger than it.
    static func centered(_ size: NSSize, in visible: NSRect) -> NSRect {
        let w = min(size.width, visible.width), h = min(size.height, visible.height)
        return NSRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2).rounded(), width: w, height: h)
    }
}
