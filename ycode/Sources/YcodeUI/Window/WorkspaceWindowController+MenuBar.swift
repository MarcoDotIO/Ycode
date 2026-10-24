import AppKit

/// Menu-bar state and the commands added with the normative menu bar
/// (`specs/ide/reference-ui-5.md` §2). Titles and conditional items come
/// from `menuContext` (`MenuTitles`, `MenuConditions`); enablement is in
/// `validateMenuItem` (`validateMenuBarItem`).
extension WorkspaceWindowController {
    /// What the menu bar's titles and conditional items depend on. Cheap:
    /// it runs whenever a menu is searched for a key equivalent.
    public var menuContext: MenuContext {
        var c = MenuContext()
        c.containerKind = session.model.kind
        c.workspaceName = session.model.displayName
        c.fileName = editor.fileURL?.lastPathComponent
        c.sourceEditorFocused = editor.fileURL != nil && editor.auxiliary == nil
        c.editorKind = focusedEditorKind
        c.inlineIssuesShown = editor.showsInlineIssues
        c.caretLine = c.sourceEditorFocused ? editor.currentLine : nil
        c.editorTabCount = editorArea.tabs.count
        c.editorPaneCount = editorArea.tab.editors.count
        c.windowTabCount = window?.tabbedWindows?.count ?? 1
        c.isWindowTabBarVisible = window?.tabGroup?.isTabBarVisible ?? false
        c.isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        c.repositoryHasRemote = sourceControl.hasRemote
        c.isDebugging = session.debugClient != nil
        c.isPaused = session.stoppedThread != nil
        c.breakpointsActive = session.breakpoints.isActive
        if let caret = debugCaret { c.caretLineBreakpointsEnabled = session.breakpoints.lineIsEnabled(file: caret.file, line: caret.line) }
        c.navigatorShown = !navigatorItem.isCollapsed
        c.inspectorShown = !inspectorItem.isCollapsed
        c.debugAreaShown = !debugItem.isCollapsed
        c.editorTabBarShown = editorArea.isTabBarVisible
        c.editorTabPinned = editorArea.tab.isPinned
        let selected = navigatorSelectedFile
        c.hasNavigatorFileSelection = selected != nil
        c.selectedFileIsUntracked = selected.map { sourceControl.lastStatus[$0] == .untracked } ?? false
        return c
    }

    /// The file selected in the project or Changes navigator, if any.
    var navigatorSelectedFile: String? {
        switch navigator.selectedIndex {
        case 0: navigator.selectedPath
        case 1: sourceControl.selectedChange
        default: nil
        }
    }

    /// Actions whose title follows state wherever their item is (menu bar,
    /// or a plain item validated directly).
    static let titledActions: Set<String> = [
        "toggleNavigator:", "toggleInspector:", "toggleDebugArea:", "toggleEditorTabBar:", "togglePinEditorTab:", "closeTab:",
        "closeDocument:", "closeWorkspace:", "toggleBreakpointsActive:", "pauseOrContinue:", "toggleWindowTabBar:", "toggleWorkspaceFullScreen:",
        "toggleInlineIssues:", "formatSelection:", "formatFile:",
    ]

    /// The generic title of a menu-bar item, or of a plain item with one of
    /// `titledActions`; nil leaves the item's title alone (context menus).
    static func menuBarGenericTitle(_ item: NSMenuItem) -> String? {
        if let spec = (item as? CommandMenuItem)?.spec { return spec.title }
        guard let a = item.action.map(NSStringFromSelector), titledActions.contains(a) else { return nil }
        return CommandTable.command(action: a, tag: item.tag)?.title
    }

    /// Enablement of the commands in this file; nil = not one of them.
    func validateMenuBarItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(closeOtherTabs(_:)): return editorArea.tabs.count > 1
        case #selector(closeOtherWindowTabs(_:)), #selector(showNextWindowTab(_:)), #selector(showPreviousWindowTab(_:)):
            return (window?.tabbedWindows?.count ?? 1) > 1
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)): return editorArea.tabs.count > 1
        case #selector(jumpToNextCounterpart(_:)), #selector(jumpToPreviousCounterpart(_:)),
             #selector(jumpToNextCounterpartUsingTab(_:)), #selector(jumpToPreviousCounterpartUsingTab(_:)),
             #selector(jumpToNextCounterpartInNextEditorPane(_:)), #selector(jumpToPreviousCounterpartInNextEditorPane(_:)):
            return editor.fileURL.map { !Counterparts.of($0.path, in: workspaceFiles).isEmpty } ?? false
        case #selector(jumpToSelection(_:)), #selector(jumpToNextPlaceholder(_:)), #selector(jumpToPreviousPlaceholder(_:)),
             #selector(showQuickHelpForSelection(_:)):
            return editor.fileURL != nil && editor.auxiliary == nil
        case #selector(searchDocumentationForSelection(_:)): return !documentationQuery.isEmpty
        case #selector(scmDiscardSelected(_:)):
            let s = sourceControl.menuState()
            return menuContext.selectedFileIsUntracked && menuContext.hasNavigatorFileSelection
                ? s.isEnabled("scmTrashSelected:") : s.hasRepository && s.selectedStatus != nil && s.selectedStatus != .untracked
        case #selector(selectSchemeRow(_:)):
            let names = session.model.schemeNames
            let i = (item.representedObject as? Int) ?? -1
            item.state = names.indices.contains(i) && names[i] == session.scheme ? .on : .off
            return names.indices.contains(i)
        case let a? where JumpBarMenu.action(a) != nil:
            return !jumpBarEntries(JumpBarMenu.action(a)!).isEmpty
        default: return validateProductMenuItem(item)
        }
    }

    // MARK: File

    /// File ▸ Close Other Tabs (⌥⌘W): every editor tab but the selected one.
    @objc public func closeOtherTabs(_ sender: Any?) {
        let keep = editorArea.tab
        while editorArea.tabs.count > 1, let i = editorArea.tabs.firstIndex(where: { $0 !== keep }) {
            editorArea.closeTab(at: i)
        }
        if let i = editorArea.tabs.firstIndex(where: { $0 === keep }) { editorArea.selectTab(i) }
    }

    /// File ▸ Close Other Window Tabs (⌥⇧⌘W): the other windows of this
    /// window's tab group.
    @objc public func closeOtherWindowTabs(_ sender: Any?) {
        for w in window?.tabbedWindows ?? [] where w !== window { w.performClose(sender) }
    }

    // MARK: View

    /// View ▸ Show / Hide Window Tab Bar.
    @objc public func toggleWindowTabBar(_ sender: Any?) { window?.toggleTabBar(sender) }
    /// View ▸ Enter / Exit Full Screen (⌃⌘F).
    @objc public func toggleWorkspaceFullScreen(_ sender: Any?) { window?.toggleFullScreen(sender) }
    /// View ▸ Show All Window Tabs (⇧⌘\).
    @objc public func showAllWindowTabs(_ sender: Any?) { window?.toggleTabOverview(sender) }

    // MARK: Navigate

    /// Navigate ▸ Show Previous / Next Tab (⇧⌘[ / ⇧⌘]): editor tabs (the
    /// window's own tabs are Window ▸ Show Previous / Next Window Tab).
    @objc public func showPreviousTab(_ sender: Any?) { editorArea.selectPreviousTab() }
    @objc public func showNextTab(_ sender: Any?) { editorArea.selectNextTab() }

    /// Window ▸ Show Previous / Next Window Tab (⌃⇧⇥ / ⌃⇥).
    @objc public func showPreviousWindowTab(_ sender: Any?) { window?.selectPreviousTab(sender) }
    @objc public func showNextWindowTab(_ sender: Any?) { window?.selectNextTab(sender) }

    /// Navigate ▸ Jump to Selection (⌥⌘L): scrolls the editor to its selection.
    @objc public func jumpToSelection(_ sender: Any?) {
        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
    }

    /// Navigate ▸ Jump to Next / Previous Counterpart (⌃⌘↑ / ⌃⌘↓): the
    /// counterparts of `editor-area.md`, in order, wrapping.
    @objc public func jumpToNextCounterpart(_ sender: Any?) { stepCounterpart(forward: true) }
    @objc public func jumpToPreviousCounterpart(_ sender: Any?) { stepCounterpart(forward: false) }

    /// The counterpart a jump goes to: the next (or previous) one in the
    /// ring that started at the file the jumps began from, wrapping.
    func counterpartTarget(forward: Bool) -> String? {
        guard let current = editor.fileURL?.path else { return nil }
        let files = workspaceFiles
        guard let (next, ring) = Counterparts.step(from: current, ring: assistantExtra.counterpartRing, forward: forward,
                                                   counterparts: { Counterparts.of(current, in: files) }) else { return nil }
        assistantExtra.counterpartRing = ring
        return next
    }

    func stepCounterpart(forward: Bool) {
        guard let next = counterpartTarget(forward: forward) else { NSSound.beep(); return }
        open(path: next, line: nil)
    }

    /// … using Tab (⌃⌥⌘↑ / ⌃⌥⌘↓): the counterpart in a new editor tab.
    @objc public func jumpToNextCounterpartUsingTab(_ sender: Any?) { stepCounterpart(forward: true, in: .tab) }
    @objc public func jumpToPreviousCounterpartUsingTab(_ sender: Any?) { stepCounterpart(forward: false, in: .tab) }
    /// … in Next Editor Pane (⌃⌥⇧⌘↑ / ⌃⌥⇧⌘↓): in the next pane, made when there is none.
    @objc public func jumpToNextCounterpartInNextEditorPane(_ sender: Any?) { stepCounterpart(forward: true, in: .nextPane) }
    @objc public func jumpToPreviousCounterpartInNextEditorPane(_ sender: Any?) { stepCounterpart(forward: false, in: .nextPane) }

    enum JumpDestination { case tab, nextPane }

    func stepCounterpart(forward: Bool, in destination: JumpDestination) {
        guard let next = counterpartTarget(forward: forward) else { NSSound.beep(); return }
        switch destination {
        case .tab:
            editorArea.newTab()
            open(path: next, line: nil)
        case .nextPane:
            let t = editorArea.tab
            if t.editors.count > 1 {
                let target = t.editors[(t.focused + 1) % t.editors.count]
                open(path: next, line: nil, in: target)
                editorArea.focus(target)
            } else {
                open(path: next, line: nil, in: editorArea.split(sideBySide: true))
            }
        }
    }

    /// Navigate ▸ Jump to Next / Previous Placeholder (⌃/ / ⌃?): what Tab
    /// and ⇧Tab do on placeholders.
    @objc public func jumpToNextPlaceholder(_ sender: Any?) { if !editor.selectPlaceholder(backward: false) { NSSound.beep() } }
    @objc public func jumpToPreviousPlaceholder(_ sender: Any?) { if !editor.selectPlaceholder(backward: true) { NSSound.beep() } }

    // MARK: Product

    /// Product ▸ Scheme ▸ <scheme>: makes it the active scheme.
    @objc public func selectSchemeRow(_ sender: Any?) {
        let names = session.model.schemeNames
        guard let i = (sender as? NSMenuItem)?.representedObject as? Int ?? (sender as? Int), names.indices.contains(i) else { return }
        session.scheme = names[i]
        schemePopUp.selectItem(withTitle: names[i])
    }

    /// Product ▸ Destination ▸ Choose Destination (⌃⇧0): opens the
    /// toolbar's destination menu.
    @objc public func chooseDestination(_ sender: Any?) {
        guard window?.isVisible == true else { return }
        destinationPopUp.performClick(nil)
    }

    // MARK: Integrate

    /// Integrate ▸ Discard Changes in “<file>”… / in Selected Files…; with
    /// an untracked file selected, Move Selected Files to Trash….
    @objc public func scmDiscardSelected(_ sender: Any?) {
        if menuContext.hasNavigatorFileSelection && menuContext.selectedFileIsUntracked { scmTrashSelected(sender); return }
        guard let f = sourceControl.selectedFile else { NSSound.beep(); return }
        let name = URL(fileURLWithPath: f).lastPathComponent
        guard sourceControl.confirm("Discard changes in \u{201C}\(name)\u{201D}?", "The file returns to its last committed version.", "Discard Changes") else { return }
        sourceControl.perform { try $0.discard(f) }
    }

    // MARK: Help

    /// Help ▸ Show Quick Help for Selected Item (⌃⌘?): the Quick Help
    /// popover for the symbol at the caret.
    @objc public func showQuickHelpForSelection(_ sender: Any?) {
        guard let url = editor.fileURL else { NSSound.beep(); return }
        let tv = editor.textView
        let sel = tv.selectedRange()
        let anchor = tv.segmentRects(NSRange(location: sel.location, length: max(sel.length, 1))).first ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        showQuickHelp(url: url, at: editor.caretPosition, anchor: anchor)
    }

    /// Help ▸ Search Documentation for Selected Text (⌃⌥⌘/).
    @objc public func searchDocumentationForSelection(_ sender: Any?) {
        let q = documentationQuery
        guard !q.isEmpty, let url = AppCommands.Links.documentationSearch(q) else { NSSound.beep(); return }
        AppCommands.open(url)
    }

    /// The selected text, or the word at the caret.
    var documentationQuery: String {
        guard editor.fileURL != nil else { return "" }
        let tv = editor.textView
        let ns = tv.string as NSString
        var r = tv.selectedRange()
        if r.length == 0 { r = tv.selectionRange(forProposedRange: NSRange(location: r.location, length: 0), granularity: .selectByWord) }
        guard r.location != NSNotFound, NSMaxRange(r) <= ns.length else { return "" }
        return ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: View ▸ Editor (⌃1–⌃6): the jump bar's menus from the keyboard

    @objc public func showRelatedItemsMenu(_ sender: Any?) { popUpJumpBarMenu(.relatedItems) }
    @objc public func showPreviousHistoryMenu(_ sender: Any?) { popUpJumpBarMenu(.previousHistory) }
    @objc public func showPreviousFilesHistoryMenu(_ sender: Any?) { popUpJumpBarMenu(.previousFilesHistory) }
    @objc public func showNextHistoryMenu(_ sender: Any?) { popUpJumpBarMenu(.nextHistory) }
    @objc public func showNextFilesHistoryMenu(_ sender: Any?) { popUpJumpBarMenu(.nextFilesHistory) }
    @objc public func showTopLevelItemsMenu(_ sender: Any?) { popUpJumpBarMenu(.topLevelItems) }
    @objc public func showGroupFilesMenu(_ sender: Any?) { popUpJumpBarMenu(.groupFiles) }
    @objc public func showDocumentItemsMenu(_ sender: Any?) { popUpJumpBarMenu(.documentItems) }

    /// The entries of one jump-bar menu (`reference-ui-5.md` §6.1.3).
    public func jumpBarEntries(_ kind: JumpBarMenu) -> [JumpBarMenu.Entry] {
        let current = editor.fileURL?.path ?? editor.history.current
        func file(_ p: String) -> JumpBarMenu.Entry { .init(title: URL(fileURLWithPath: p).lastPathComponent, path: p) }
        func unique(_ paths: [String]) -> [String] {
            var seen = Set<String>()
            return paths.filter { $0 != current && seen.insert($0).inserted }
        }
        let h = editor.history
        switch kind {
        case .relatedItems:
            var out: [JumpBarMenu.Entry] = []
            let recent = unique(navigator.recentFiles.reversed())
            if !recent.isEmpty { out.append(.label("Recent Files")); out += recent.prefix(10).map(file) }
            let counterparts = current.map { Counterparts.of($0, in: workspaceFiles) } ?? []
            if !counterparts.isEmpty { out.append(.label("Counterparts")); out += counterparts.map(file) }
            return out
        case .previousHistory: return h.index > 0 ? h.items[..<h.index].reversed().map(file) : []
        case .nextHistory: return h.index + 1 < h.items.count ? h.items[(h.index + 1)...].map(file) : []
        case .previousFilesHistory: return h.index > 0 ? unique(h.items[..<h.index].reversed()).map(file) : []
        case .nextFilesHistory: return h.index + 1 < h.items.count ? unique(Array(h.items[(h.index + 1)...])).map(file) : []
        case .topLevelItems:
            return JumpBarMenu.entries(for: session.model.root.children)
        case .groupFiles:
            guard let current, let parent = JumpBarMenu.parent(of: current, in: session.model.root) else { return [] }
            return JumpBarMenu.entries(for: parent.children)
        case .documentItems:
            guard let path = editor.fileURL?.path else { return [] }
            func flat(_ s: [SymbolScanner.Symbol], _ depth: Int) -> [JumpBarMenu.Entry] {
                s.flatMap { [JumpBarMenu.Entry(title: String(repeating: "  ", count: depth) + $0.name, path: path, line: $0.line)] + flat($0.children, depth + 1) }
            }
            return flat(editor.documentSymbols, 0)
        }
    }

    /// Opens a jump-bar menu at the focused editor's jump bar. Returns the
    /// menu (it is only shown while the window is on screen).
    @discardableResult
    public func popUpJumpBarMenu(_ kind: JumpBarMenu) -> NSMenu {
        let menu = NSMenu(title: kind.title)
        func add(_ entries: [JumpBarMenu.Entry], to m: NSMenu) {
            for e in entries {
                if e.isLabel { m.addItem(.sectionHeader(title: e.title)); continue }
                let i = NSMenuItem(title: e.title, action: #selector(jumpBarEntryChosen(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = e
                if let p = e.path { i.image = NSWorkspace.shared.icon(forFile: p); i.image?.size = NSSize(width: 16, height: 16) }
                if !e.children.isEmpty {
                    let sub = NSMenu(title: e.title)
                    add(e.children, to: sub)
                    i.submenu = sub
                }
                m.addItem(i)
            }
        }
        let entries = jumpBarEntries(kind)
        add(entries, to: menu)
        if entries.isEmpty { menu.addItem(NSMenuItem(title: "No Items", action: nil, keyEquivalent: "")) }
        if window?.isVisible == true {
            menu.popUp(positioning: menu.items.first, at: NSPoint(x: 6, y: 0), in: editor.jumpBar)
        }
        return menu
    }

    @objc func jumpBarEntryChosen(_ sender: Any?) {
        guard let e = (sender as? NSMenuItem)?.representedObject as? JumpBarMenu.Entry, let p = e.path else { return }
        open(path: p, line: e.line)
        if let line = e.line { editor.reveal(line: line) }
    }
}

/// The jump-bar menus View ▸ Editor opens (⌃1–⌃6, `reference-ui-5.md` §6.1.3).
public enum JumpBarMenu: CaseIterable, Sendable {
    case relatedItems, previousHistory, previousFilesHistory, nextHistory, nextFilesHistory, topLevelItems, groupFiles, documentItems

    public final class Entry: NSObject, Sendable {
        public let title: String
        public let path: String?
        public let line: Int?
        public let isLabel: Bool
        public let children: [Entry]
        public init(title: String, path: String? = nil, line: Int? = nil, isLabel: Bool = false, children: [Entry] = []) {
            self.title = title
            self.path = path
            self.line = line
            self.isLabel = isLabel
            self.children = children
        }
        static func label(_ t: String) -> Entry { Entry(title: t, isLabel: true) }
    }

    public var title: String {
        switch self {
        case .relatedItems: "Related Items"
        case .previousHistory, .previousFilesHistory: "Previous History"
        case .nextHistory, .nextFilesHistory: "Next History"
        case .topLevelItems: "Top Level Items"
        case .groupFiles: "Group Files"
        case .documentItems: "Document Items"
        }
    }

    @MainActor static func action(_ s: Selector) -> JumpBarMenu? {
        switch s {
        case #selector(WorkspaceWindowController.showRelatedItemsMenu(_:)): .relatedItems
        case #selector(WorkspaceWindowController.showPreviousHistoryMenu(_:)): .previousHistory
        case #selector(WorkspaceWindowController.showPreviousFilesHistoryMenu(_:)): .previousFilesHistory
        case #selector(WorkspaceWindowController.showNextHistoryMenu(_:)): .nextHistory
        case #selector(WorkspaceWindowController.showNextFilesHistoryMenu(_:)): .nextFilesHistory
        case #selector(WorkspaceWindowController.showTopLevelItemsMenu(_:)): .topLevelItems
        case #selector(WorkspaceWindowController.showGroupFilesMenu(_:)): .groupFiles
        case #selector(WorkspaceWindowController.showDocumentItemsMenu(_:)): .documentItems
        default: nil
        }
    }

    /// Navigator rows as menu entries: groups and folders become submenus.
    static func entries(for nodes: [NavigatorNode]) -> [Entry] {
        nodes.map { n in
            n.kind == .file ? Entry(title: n.name, path: n.path) : Entry(title: n.name, children: entries(for: n.children))
        }
    }

    /// The row that holds the file at `path`.
    static func parent(of path: String, in node: NavigatorNode) -> NavigatorNode? {
        for c in node.children {
            if c.path == path && c.kind == .file { return node }
            if let p = parent(of: path, in: c) { return p }
        }
        return nil
    }
}
