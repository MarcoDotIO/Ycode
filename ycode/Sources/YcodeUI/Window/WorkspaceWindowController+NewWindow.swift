import AppKit
import YcodeIDECore

/// Second windows on one workspace (P-022, `reference-ui-3.md` §5 item 1):
/// File ▸ New ▸ Window (⇧⌘T) and Window Tab. Each window has its own
/// editors, panes and session; the workspace document keeps every window
/// it shows, so ⌘W on one closes that window only and the next one
/// becomes key; the document closes with its last window.
extension WorkspaceWindowController {
    /// File ▸ New ▸ Window (⇧⌘T): another window on this workspace,
    /// offset from this one as the system cascades document windows.
    @discardableResult
    @objc public func newWorkspaceWindow(_ sender: Any?) -> WorkspaceWindowController {
        let wc = makeSiblingWindow()
        if let frame = window?.frame, let w = wc.window {
            w.setFrame(frame.offsetBy(dx: Self.cascadeOffset, dy: -Self.cascadeOffset), display: false)
        }
        if window?.isVisible == true { wc.showWindow(sender) }
        return wc
    }

    /// File ▸ New ▸ Window Tab: another window on this workspace, as a tab
    /// of this window's tab group (the tab bar's + does the same).
    @discardableResult
    @objc public func newWorkspaceWindowTab(_ sender: Any?) -> WorkspaceWindowController {
        let wc = makeSiblingWindow()
        if let w = wc.window, let window {
            w.tabbingMode = .preferred
            window.addTabbedWindow(w, ordered: .above)
            if window.isVisible { w.makeKeyAndOrderFront(sender) }
        }
        return wc
    }

    /// The system's action for a new tab (the tab bar's + button, File ▸
    /// New ▸ Window Tab's selector).
    public override func newWindowForTab(_ sender: Any?) { newWorkspaceWindowTab(sender) }

    /// File ▸ New ▸ Project… ▸ Choose Template… (⌥⇧⌘N): the template sheet
    /// on a new empty window.
    @discardableResult
    @objc public func chooseProjectTemplate(_ sender: Any?) -> NewProjectSheetController { chooseProjectTemplate() }

    /// How far a new window sits from the one it was made from (down and
    /// right), as AppKit's cascade.
    static let cascadeOffset: CGFloat = 22

    /// A window controller on the same workspace, owned by the same
    /// document, laid out as a new window.
    func makeSiblingWindow() -> WorkspaceWindowController {
        let live = !Self.isTestProcess
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: session.model), loadDestinations: live, startLanguageService: live)
        (document as? NSDocument)?.addWindowController(wc)
        wc.applyDefaultLayout()
        return wc
    }
}
