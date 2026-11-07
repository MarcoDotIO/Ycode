import AppKit
import YcodeIDECore

/// The toolbar's right group and the Adjust Editor Options menu
/// (`specs/ide/reference-ui-4.md` §14, `reference-ui-6.md` §2.1).
public enum EditorOptionsMenu {
    static let addEditorID = NSToolbarItem.Identifier("addEditor")
    static let editorOptionsID = NSToolbarItem.Identifier("editorOptions")

    /// The right group, left to right, ending with the three-way toggle
    /// (no Account item, reference-ui-6.md §2.1).
    public static let rightGroup = ["addEditor", "editorOptions", "editorModes"]

    /// Adjust Editor Options, in order. The choices apply to the focused editor.
    static var items: [MenuItemSpec] {
        let u = CommandTable.unavailable
        return [
            .submenu("Layout", [
                .command(.init("Editor Pane On Right", "", [], "splitEditor:")),
                .command(.init("Editor Pane Below", "", [], "splitEditorBelow:")),
            ]),
            .separator,
            .command(.init("Inline Comparison", "", [], "showInlineComparison:")),
            .command(.init("Side By Side Comparison", "", [], "showSideBySideComparison:")),
            .separator,
            .command(.init("Minimap", "", [], "toggleMinimap:")),
            .command(.init("Authors", "", [], "toggleAuthors:")),
            u("Code Coverage"),
            .separator,
            .command(.init("Invisibles", "", [], "toggleInvisibles:")),
            .command(.init("Scope Guides", "", [], "toggleScopeGuides:")),
            .command(.init("Wrap Lines", "", [], "toggleWrapLines:")),
            .separator,
            .command(.init("Choose Workspace Theme…", "", [], "chooseTheme:")),
        ]
    }

    /// Add Editor Tabs or Editor Panes.
    static var addItems: [MenuItemSpec] {
        [
            .command(.init("Add Editor Tab", "", [], "newTab:")),
            .command(.init("Add Editor Pane on Right", "", [], "splitEditor:")),
            .command(.init("Add Editor Pane Below", "", [], "splitEditorBelow:")),
        ]
    }

    @MainActor public static func menu() -> NSMenu { MainMenu.menu("Adjust Editor Options", items) }
    @MainActor public static func addMenu() -> NSMenu { MainMenu.menu("Add Editor Tabs or Editor Panes", addItems) }
}

/// Segment widths that give the toolbar's glass capsules the drawn sizes
/// of `specs/ide/liquid-glass.md` §2.2 (the system adds its own padding):
/// Navigators | Coding Assistant 78, Run | Stop and Back | Forward 75,
/// Canvas | Assistant | Code Review 125 points; all 38 tall. Before macOS
/// 26 the earlier 38-point segments stay.
enum ToolbarGlass {
    static var glass: Bool { if #available(macOS 26, *) { return true }; return false }
    static var leftPanesSegment: CGFloat { glass ? 31.5 : 38 }
    static var pairSegment: CGFloat { glass ? 30 : 0 }
    static var editorModesSegment: CGFloat { glass ? 35 : 38 }
}

extension WorkspaceWindowController {
    /// Toolbar items of the right group (nil for other identifiers). The
    /// accessibility title is the short label ("Add Editor", "Editor
    /// Options"); the tooltips keep the long text (reference-ui-6.md §2.1).
    func rightGroupToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        func menuItem(_ symbol: String, _ label: String, _ tip: String, _ menu: NSMenu) -> NSToolbarItem {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = tip
            item.menu = menu
            item.showsIndicator = false
            item.visibilityPriority = .high
            return item
        }
        switch id {
        case EditorOptionsMenu.addEditorID:
            return menuItem("plus.rectangle.on.rectangle", "Add Editor", "Add Editor Tabs or Editor Panes", EditorOptionsMenu.addMenu())
        case EditorOptionsMenu.editorOptionsID:
            return menuItem("line.3.horizontal", "Editor Options", "Adjust Editor Options", EditorOptionsMenu.menu())
        default:
            return nil
        }
    }

    // MARK: State-dependent titles (reference-ui-6.md §2.5, T7)

    public static func inspectorToggleTitle(shown: Bool) -> String { shown ? "Hide Inspector" : "Show Inspector" }

    /// The toolbar inspector toggle and the debug bar's debug-area toggle
    /// name the action they perform.
    func updateAreaToggleTitles() {
        guard let inspectorItem, let debugItem else { return }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.inspectorToggleID }) {
            let t = Self.inspectorToggleTitle(shown: !inspectorItem.isCollapsed)
            if item.label != t { item.label = t; item.toolTip = t }
        }
        debugArea.setDebugAreaShown(!debugItem.isCollapsed)
    }

    /// The inspector toggle's title as the toolbar shows it (tests).
    public var inspectorToggleItemTitle: String? {
        window?.toolbar?.items.first { $0.itemIdentifier == Self.inspectorToggleID }?.label
    }

    // MARK: Room (reference-ui-6.md §2.2, T1)

    /// Refits the toolbar whenever its room or its items' widths change:
    /// the window's size, the left area and the inspector (shown, hidden,
    /// divider drags), the debug area (toggle titles).
    func observeToolbarRoom() {
        let center = NotificationCenter.default
        leftAreaObservation.tokens.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToolbar() }
        })
        leftAreaObservation.tokens.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: mainSplit.splitView,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleToolbarFit() }
        })
        leftAreaObservation.tokens.append(inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateAreaToggleTitles()
                self?.scheduleToolbarFit()
            }
        })
        leftAreaObservation.tokens.append(debugItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateAreaToggleTitles() }
        })
        updateEditorModesPullDown()
        updateAreaToggleTitles()
    }

    /// Fits the toolbar on the next turn of the run loop (changes come in
    /// bursts: a build's activity text, issue counts).
    func scheduleToolbarFit() {
        // The inspector's slide fits the toolbar once, at its end (row 106).
        guard !toolbarControls.fitScheduled, !isInspectorSliding else { return }
        toolbarControls.fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.toolbarControls.fitScheduled = false
                self.fitToolbar()
            }
        }
    }

    /// The toolbar's current fitting state (tests).
    public var toolbarFit: ToolbarFit { toolbarControls.fit }

    /// The toolbar items in the overflow menu (none once it fits).
    public var overflowedToolbarItems: [String] {
        guard let toolbar = window?.toolbar else { return [] }
        let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        // A hidden item (the issue capsule with nothing to show) is not
        // an overflow.
        return toolbar.items.filter { !$0.isHidden }.map(\.itemIdentifier)
            .filter { !visible.contains($0) && !Self.toolbarSpacers.contains($0) }.map(\.rawValue)
    }
    static let toolbarSpacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator, FlushSidebar.trackingSeparatorID,
                                                                 .inspectorTrackingSeparator]

    /// Recovers room in the order of `ToolbarFit` (liquid-glass.md §8.2)
    /// until nothing but what the step allows sits in the overflow: the
    /// editor-mode group goes into the "»" menu, then the scheme capsule
    /// drops its titles, then the activity subtitle truncates in the
    /// middle. Each step is tried after a layout of the window's frame; a
    /// wider window undoes them. Show Inspector has the highest visibility
    /// priority and the editor modes the lowest, so the system's overflow
    /// takes them first.
    public func fitToolbar() {
        guard let window, let frame = window.contentView?.superview, window.toolbar != nil, !toolbarControls.fitting, !isInspectorSliding else { return }
        toolbarControls.fitting = true
        toolbarControls.fitRuns += 1
        defer { toolbarControls.fitting = false }
        // The first try lays out the whole frame (the toolbar's room follows
        // the areas' dividers); the steps only change toolbar items, so later
        // tries lay out the title bar alone, not the editor's text again
        // (`editor-area.md` F.6, row 107: the resize call blocked 264 ms).
        let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview
        var laidOut = false
        func fits(_ f: ToolbarFit) -> Bool {
            apply(f)
            if laidOut, let titlebar, titlebar !== frame { titlebar.layoutSubtreeIfNeeded() } else { frame.layoutSubtreeIfNeeded() }
            laidOut = true
            return f.accepts(overflowed: overflowedToolbarItems)
        }
        let steps = ToolbarFit.steps(activityNatural: activityView.naturalWidth)
        for f in steps where fits(f) {
            toolbarControls.fit = f
            return
        }
        // Nothing fits: keep the tightest step; the remaining items
        // overflow by visibility priority.
        toolbarControls.fit = steps.last ?? ToolbarFit()
        apply(toolbarControls.fit)
    }

    func apply(_ f: ToolbarFit) {
        setSchemeGlyphsOnly(f.schemeGlyphsOnly)
        activityView.maximumWidth = f.activityWidth ?? .greatestFiniteMagnitude
    }

    /// The scheme capsule with its titles (the scheme's name, "›", the
    /// destination's name) or, short of room, its glyphs only
    /// (liquid-glass.md §8.2: about 87 points). The titles move to the
    /// tooltips meanwhile; the accessibility titles stay.
    func setSchemeGlyphsOnly(_ glyphsOnly: Bool) {
        for p in [schemePopUp, destinationPopUp] {
            let position: NSControl.ImagePosition = glyphsOnly ? .imageOnly : .imageLeading
            if p.imagePosition != position {
                p.imagePosition = position
                p.invalidateIntrinsicContentSize()
            }
            let tip = glyphsOnly ? p.titleOfSelectedItem : nil
            if p.toolTip != tip { p.toolTip = tip }
        }
        // The glyphs keep the reference's spacing: about 87 points in all.
        if #available(macOS 26, *), let stack = schemePopUp.superview as? NSStackView {
            let side: CGFloat = glyphsOnly ? 14 : 8
            if stack.edgeInsets.left != side { stack.edgeInsets = NSEdgeInsets(top: 0, left: side, bottom: 0, right: side) }
            stack.spacing = glyphsOnly ? 4 : 0
        }
    }

    /// Whether the scheme capsule shows glyphs only (tests).
    public var schemeShowsGlyphsOnly: Bool { schemePopUp.imagePosition == .imageOnly }

    /// The scheme capsule's width (its content and side insets; tests).
    public var schemeCapsuleWidth: CGFloat {
        guard let v = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.schemeID })?.view else { return 0 }
        v.layoutSubtreeIfNeeded()
        return v.fittingSize.width
    }

    // MARK: Editor modes in the overflow menu (liquid-glass.md §8.2)

    /// The editor-mode group's entry in the "»" menu: "Editor Modes" with
    /// the three modes, the current one checked.
    func updateEditorModesPullDown() {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.editorModesID }) else { return }
        item.menuFormRepresentation = editorModesMenuItem()
    }

    func editorModesMenuItem() -> NSMenuItem {
        let mode = activeEditorMode
        let symbols = WorkspaceChrome.editorModes.symbols
        let titles = ["Canvas", "Assistant", "Code Review"]
        let menu = NSMenu(title: "Editor Modes")
        for m in EditorMode.allCases {
            let i = NSMenuItem(title: titles[m.rawValue], action: #selector(editorModeMenuChosen(_:)), keyEquivalent: "")
            i.target = self
            i.tag = m.rawValue
            if symbols.indices.contains(m.rawValue) { i.image = NSImage(systemSymbolName: symbols[m.rawValue], accessibilityDescription: nil) }
            i.state = m == mode ? .on : .off
            menu.addItem(i)
        }
        let top = NSMenuItem(title: "Editor Modes", action: nil, keyEquivalent: "")
        top.submenu = menu
        return top
    }

    @objc func editorModeMenuChosen(_ item: NSMenuItem) {
        if let m = EditorMode(rawValue: item.tag) { setEditorMode(m) }
        updateToolbarState()
    }
}

extension WorkspaceChrome.ToolbarItem {
    /// The item's symbols as AppKit images (the tooltips as descriptions,
    /// or `descriptions`).
    @MainActor func images(descriptions: [String]? = nil) -> [NSImage] {
        zip(symbols, descriptions ?? toolTips).map { NSImage(systemSymbolName: $0, accessibilityDescription: $1)! }
    }
    @MainActor var images: [NSImage] { images() }
}
