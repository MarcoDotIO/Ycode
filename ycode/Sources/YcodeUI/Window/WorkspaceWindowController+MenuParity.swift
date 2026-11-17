import AppKit
import YcodeIDECore

/// Menu-bar commands and enable states of the beta 4 menu parity pass
/// (B4-MENUS; `specs/ide/parity-inventory.md` P-004 … P-016): File's Save
/// All, Open Terminal at Location, Print…; View's Change Editor
/// Orientation; Navigate's Open using Tab / in Next Editor Pane, focus
/// movement between areas and editor panes, Jump to Definition using Tab /
/// in Next Editor Pane; and the enable states the reference measured.
extension WorkspaceWindowController {
    // MARK: File

    /// File ▸ Save All (⌥⌘S): every edited file of every editor, and the
    /// project files.
    @objc public func saveAllDocuments(_ sender: Any?) {
        do {
            for e in editorArea.allEditors where e.fileURL != nil && e.isDirty { try e.save() }
            try session.model.saveProjects()
            refreshFileStatus(nil)
        } catch {
            presentError(error)
        }
    }

    /// The folder File ▸ Open Terminal at Location opens: the selected
    /// navigator item's (or the open file's) folder, else the workspace's.
    var terminalLocation: URL {
        if let p = navigator.selectedPath ?? editor.fileURL?.path {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: p) }
            return URL(fileURLWithPath: p).deletingLastPathComponent()
        }
        let u = session.model.url
        return u.hasDirectoryPath && !["xcodeproj", "xcworkspace"].contains(u.pathExtension) ? u : u.deletingLastPathComponent()
    }

    /// File ▸ Open Terminal at Location: the system's terminal at
    /// `terminalLocation`.
    @objc public func openTerminalAtLocation(_ sender: Any?) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { NSSound.beep(); return }
        NSWorkspace.shared.open([terminalLocation], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// File ▸ Print… (⌘P): the focused source editor's text.
    @objc public func printEditor(_ sender: Any?) {
        guard hasSourceFile, let window, window.isVisible else { NSSound.beep(); return }
        let op = NSPrintOperation(view: editor.textView)
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: View

    /// View ▸ Change Editor Orientation: editor panes side by side become
    /// stacked, and back (the next split follows it too).
    @objc public func changeEditorOrientation(_ sender: Any?) {
        let t = editorArea.tab
        t.sideBySide.toggle()
        editorArea.layout(t)
    }

    // MARK: Navigate

    /// Navigate ▸ Open using Tab (⌥⌘,): the navigator's selected file in a
    /// new editor tab.
    @objc public func openUsingTab(_ sender: Any?) { openInNewTab(sender) }

    /// Navigate ▸ Open in Next Editor Pane (⌥⌘<): the navigator's selected
    /// file in the next editor pane (made when there is one only).
    @objc public func openInNextEditorPane(_ sender: Any?) {
        guard let path = navigator.selectedPath ?? editor.fileURL?.path else { NSSound.beep(); return }
        open(path: path, line: nil, in: nextEditorPane())
    }

    /// The pane after the focused one, focused; a new one beside it when
    /// the tab has a single pane.
    func nextEditorPane() -> SourceEditorController {
        let t = editorArea.tab
        guard t.editors.count > 1 else { return editorArea.split(sideBySide: true) }
        let e = t.editors[(t.focused + 1) % t.editors.count]
        editorArea.focus(e)
        return e
    }

    /// The window's areas in focus order, those shown: navigator, editor,
    /// inspector, debug area.
    var focusAreas: [NSView] {
        var out: [NSView] = []
        if !navigatorItem.isCollapsed { out.append(navigator.view) }
        out.append(editor.view)
        if !inspectorItem.isCollapsed { out.append(inspector.view) }
        if !debugItem.isCollapsed { out.append(debugArea.view) }
        return out
    }

    /// Navigate ▸ Move Focus to Next / Previous Area (⌥⌘` / ⌥⇧⌘`).
    @objc public func moveFocusToNextArea(_ sender: Any?) { moveFocusBetweenAreas(forward: true) }
    @objc public func moveFocusToPreviousArea(_ sender: Any?) { moveFocusBetweenAreas(forward: false) }

    func moveFocusBetweenAreas(forward: Bool) {
        guard let window else { return }
        let areas = focusAreas
        let current = (window.firstResponder as? NSView).flatMap { v in areas.firstIndex { v.isDescendant(of: $0) } }
        let start = current ?? (forward ? areas.count - 1 : 0)
        for step in 1...areas.count {
            let i = (start + (forward ? step : areas.count * 2 - step)) % areas.count
            if focus(area: areas[i], in: window) { return }
        }
        NSSound.beep()
    }

    /// Makes the area's first focusable view the first responder (the
    /// editor's text for the editor).
    func focus(area: NSView, in window: NSWindow) -> Bool {
        if area === editor.view { return window.makeFirstResponder(editor.textView) }
        func first(_ v: NSView) -> NSView? {
            if !v.isHidden, v.acceptsFirstResponder, v.canBecomeKeyView { return v }
            for s in v.subviews { if let f = first(s) { return f } }
            return nil
        }
        guard let target = first(area) else { return false }
        return window.makeFirstResponder(target)
    }

    /// Navigate ▸ Move Focus to Next / Previous Editor Pane (⌃` / ⌃⇧`).
    @objc public func moveFocusToNextEditorPane(_ sender: Any?) { moveFocusBetweenPanes(forward: true) }
    @objc public func moveFocusToPreviousEditorPane(_ sender: Any?) { moveFocusBetweenPanes(forward: false) }

    func moveFocusBetweenPanes(forward: Bool) {
        let t = editorArea.tab
        let n = t.editors.count
        let e = t.editors[(t.focused + (forward ? 1 : n - 1)) % n]
        editorArea.focus(e)
        window?.makeFirstResponder(e.textView)
    }

    /// Navigate ▸ Jump to Definition using Tab (⌃⌥⌘J) / in Next Editor
    /// Pane (⌃⌥⇧⌘J): the definition in a new tab, or the next pane.
    @objc public func jumpToDefinitionUsingTab(_ sender: Any?) { jumpToDefinition(in: .tab) }
    @objc public func jumpToDefinitionInNextEditorPane(_ sender: Any?) { jumpToDefinition(in: .nextPane) }

    func jumpToDefinition(in destination: JumpDestination) {
        guard let url = editor.fileURL else { NSSound.beep(); return }
        let at = editor.caretPosition
        Task {
            guard let loc = await session.definition(url, at: at) else { return NSSound.beep() }
            let target: SourceEditorController
            switch destination {
            case .tab:
                editorArea.newTab()
                target = editor
            case .nextPane: target = nextEditorPane()
            }
            open(path: loc.url.standardizedFileURL.path, line: nil, in: target)
            target.reveal(position: loc.start)
        }
    }

    // MARK: The focused editor's commands from anywhere in the window

    // P-007: Comment Selection (⌘/), the fold commands, Minimap and the
    // completions act on the focused editor even while another area (the
    // navigator, the inspector) has keyboard focus, as in the reference.
    @objc public func commentSelection(_ sender: Any?) { if hasEditableSource { editor.commentSelection(sender) } else { NSSound.beep() } }
    @objc public func fold(_ sender: Any?) { if hasSourceFile { editor.fold(sender) } else { NSSound.beep() } }
    @objc public func unfold(_ sender: Any?) { if hasSourceFile { editor.unfold(sender) } else { NSSound.beep() } }
    @objc public func unfoldAll(_ sender: Any?) { if hasSourceFile { editor.unfoldAll(sender) } else { NSSound.beep() } }
    @objc public func toggleMinimap(_ sender: Any?) { editor.toggleMinimap(sender) }
    @objc public override func complete(_ sender: Any?) {
        guard hasEditableSource, let window else { NSSound.beep(); return }
        window.makeFirstResponder(editor.textView)
        editor.textView.complete(sender)
    }
    @objc public func showPredictiveCompletion(_ sender: Any?) {
        guard hasEditableSource, let window else { NSSound.beep(); return }
        window.makeFirstResponder(editor.textView)
        editor.showPredictiveCompletion(sender)
    }

    /// The caret's line is a comment (Rename… does not apply there, P-007).
    var caretOnCommentLine: Bool {
        guard hasSourceFile else { return false }
        let ns = editor.textView.string as NSString
        let at = min(editor.textView.selectedRange().location, ns.length)
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: at, length: 0))).trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*")
    }

    /// Languages Rename… works in (the language service's).
    static let renameExtensions: Set<String> = ["swift", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh"]

    // MARK: Enable states

    /// Enablement of this file's commands and the states the reference
    /// measured for existing ones; nil = not one of them.
    func validateMenuParityItem(_ item: NSMenuItem) -> Bool? {
        guard let a = item.action else { return nil }
        switch NSStringFromSelector(a) {
        case "saveAllDocuments:", "openTerminalAtLocation:", "changeEditorOrientation:", "openUsingTab:", "openInNextEditorPane:",
             "moveFocusToNextArea:", "moveFocusToPreviousArea:", "duplicateEditorTab:":
            return true
        case "printEditor:": return hasSourceFile
        case "moveFocusToNextEditorPane:", "moveFocusToPreviousEditorPane:": return true
        case "jumpToDefinitionUsingTab:", "jumpToDefinitionInNextEditorPane:": return hasSourceFile
        // P-008: the document commands need a document.
        case "saveDocument:", "runPageLayout:": return editor.fileURL != nil
        // View (P-011).
        case "showAllWindowTabs:": return (window?.tabbedWindows?.count ?? 1) > 1
        case "showRelatedItemsMenu:", "showGroupFilesMenu:", "showDocumentItemsMenu:": return true
        // Navigate (P-012): only with somewhere to go.
        case "jumpToNextIssue:", "jumpToPreviousIssue:": return !navigableIssues.isEmpty
        case "goBack:": return editor.history.canGoBack
        case "goForward:": return editor.history.canGoForward
        case "revealInProjectNavigator:": return editor.fileURL != nil
        case "jumpToNextChange:", "jumpToPreviousChange:", "jumpToNextLocalOrUpstreamChange:", "jumpToPreviousLocalOrUpstreamChange:":
            return hasSourceFile
        // Product (P-013).
        case "clearAllIssues:": return !session.displayedIssues.isEmpty
        case "testProduct:", "testWithoutBuilding:": return session.model.hasTestTargets && !session.isBusy
        // Debug (P-015).
        case "toggleBreakpointAtCurrentLine:", "createColumnBreakpoint:": return hasSourceFile
        case "createTestFailureBreakpoint:", "deleteAllBreakpoints:", "reloadConsole:": return true
        // Editor (P-007).
        case "commentSelection:", "complete:", "showPredictiveCompletion:": return hasEditableSource
        case "fold:", "unfold:", "unfoldAll:": return hasSourceFile
        case "toggleMinimap:":
            item.state = editor.showsMinimap ? .on : .off
            return hasSourceFile
        case "splitSelectionByLines:", "resetFontSize:", "codingToolGeneratePreview:": return hasSourceFile
        case "renameSymbol:":
            guard let ext = editor.fileURL?.pathExtension.lowercased(), Self.renameExtensions.contains(ext), !caretOnCommentLine else { return false }
            return canAskLanguageService
        // Edit (P-009): with code focused.
        case "copySymbolName:", "copyQualifiedSymbolName:": return hasSourceFile
        case "moveItemHere:": return navigator.itemsToMove != nil
        default: return nil
        }
    }
}
