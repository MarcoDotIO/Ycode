import Foundation
import YcodeIDECore

/// Menu-bar items the Linux shell performs by their `CommandTable` action
/// without a `ShellCommand` of their own (beta 4, B4-MENUS): the close
/// group, focus movement between editor panes, the items the view layer
/// performs, and the menu context the titles and conditional items read.
extension ShellAppModel {
    /// Actions the view layer (`ShellMenus`) performs: it opens Settings
    /// on a pane. Listed here so the menu model knows they are enabled.
    public static let viewLayerActions: Set<String> = ["showSettings:", "chooseTheme:", "showBehaviorsSettings:"]
    /// The actions of `menuActionState` that carry a check mark.
    public static let toggleActions: Set<String> = ["toggleWrapLines:", "toggleMinimap:", "ycodeUnavailableDontSimulateLocation:"]

    /// Whether a table action applies now, and its check mark; nil for an
    /// action the shell does not perform this way.
    public func menuActionState(_ action: String, tag: Int = 0) -> (enabled: Bool, checked: Bool)? {
        if Self.viewLayerActions.contains(action) { return (true, false) }
        switch action {
        // File: ⌘W closes the file, then the workspace; ⇧⌘W the window (P-008).
        case "closeTab:", "performClose:": return (workspace != nil, false)
        case "closeOtherWindowTabs:": return (false, false)
        case "clearRecentProjects:": return (!recent.isEmpty, false)
        // Help, Window and Ycode ▸ Open Developer Tool: web pages (as macOS).
        case "showDeveloperDocumentation:", "showHumanInterfaceGuidelines:", "openMoreDeveloperTools:": return (true, false)
        default: break
        }
        guard workspace != nil else { return nil }
        switch action {
        // Navigate (P-012): focus between editor panes.
        case "moveFocusToNextEditorPane:", "moveFocusToPreviousEditorPane:": return (true, false)
        // File and View (P-008, P-011).
        case "openTerminalAtLocation:", "changeEditorOrientation:": return (true, false)
        // Debug ▸ Simulate Location (P-015): the current choice, listed
        // disabled until a run on the Ycode simulator takes locations.
        case "ycodeUnavailableDontSimulateLocation:": return (false, true)
        // Editor (P-007): Wrap Lines is the editing preference the Linux
        // editor follows; the Linux minimap is always drawn (its check mark).
        case "toggleWrapLines:": return (workspace?.editor != nil, Preferences.shared.wrapLines)
        case "toggleMinimap:": return (false, workspace?.editor != nil)
        // Editor ▸ Show Editor Only (P-006): hides the canvas.
        case "showEditorOnly:": return (true, false)
        default: return nil
        }
    }

    /// Performs a table action (`menuActionState` says which); false when
    /// it is not one.
    @discardableResult
    public func performMenuAction(_ action: String, tag: Int = 0) -> Bool {
        switch action {
        case "closeTab:":
            guard let w = workspace else { return false }
            if w.document != nil || w.structuredEditor != nil { w.closeCurrentDocument() } else { closeWorkspace() }
        case "performClose:": closeWorkspace()
        case "clearRecentProjects:": clearRecent()
        case "showDeveloperDocumentation:": openLink(HelpLinks.developerDocumentation)
        case "showHumanInterfaceGuidelines:": openLink(HelpLinks.humanInterfaceGuidelines)
        case "openMoreDeveloperTools:": openLink(HelpLinks.moreDeveloperTools)
        case "moveFocusToNextEditorPane:": workspace?.focusNeighbourPane(forward: true)
        case "moveFocusToPreviousEditorPane:": workspace?.focusNeighbourPane(forward: false)
        case "openTerminalAtLocation:": workspace?.openTerminal()
        case "changeEditorOrientation:": workspace?.panes.sideBySide.toggle()
        case "toggleWrapLines:": Preferences.shared.wrapLines.toggle()
        case "showEditorOnly:":
            if workspace?.isPreviewCommandChecked(.toggleCanvas) == true { workspace?.perform(.toggleCanvas) }
        default: return false
        }
        return true
    }
}

extension WorkspaceShellModel {
    /// Focuses the next (or previous) editor pane, wrapping; with one pane
    /// the editor keeps focus.
    public func focusNeighbourPane(forward: Bool) {
        let p = panes
        guard p.panes.count > 1 else { focusEditor(); return }
        let i = (p.focused + (forward ? 1 : p.panes.count - 1)) % p.panes.count
        focusPane(p.panes[i].id)
    }

    /// The folder File ▸ Open Terminal at Location opens: the open file's,
    /// else the workspace's.
    public var terminalLocation: URL {
        if let p = document?.path { return URL(fileURLWithPath: p).deletingLastPathComponent() }
        let u = session.model.url
        return u.hasDirectoryPath && !["xcodeproj", "xcworkspace"].contains(u.pathExtension) ? u : u.deletingLastPathComponent()
    }

    /// Where Open Terminal at Location starts a terminal (tests replace it).
    nonisolated(unsafe) public static var launchTerminal: (URL) -> Void = { dir in
        // The desktop's terminal (Debian's alternatives name it).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["x-terminal-emulator"]
        p.currentDirectoryURL = dir
        try? p.run()
    }

    /// File ▸ Open Terminal at Location.
    public func openTerminal() { Self.launchTerminal(terminalLocation) }

    /// What `menuContext` adds for the menu bar's conditional items and
    /// titles (the macOS IDE's `WorkspaceWindowController.menuContext`).
    func fillMenuBarContext(_ c: inout MenuContext) {
        c.sourceEditorFocused = editor != nil && structuredEditor == nil
        c.caretLine = c.sourceEditorFocused ? editor.map { $0.buffer.caretLine + 1 } : nil
        c.editorKind = document == nil && structuredEditor == nil ? .other : editorKind
        c.editorPaneCount = panes.panes.count
        c.repositoryHasRemote = sourceControl.menuState.hasRemote
        if let id = selection, let item = root.find(id: id) {
            c.hasNavigatorFileSelection = item.isFile
            c.projectSelection = item.isFile ? .file : .group
        }
    }
}
