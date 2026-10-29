import AppKit

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
            u("Authors"),
            u("Code Coverage"),
            .separator,
            u("Invisibles"),
            u("Scope Guides"),
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
        let p = toolbarControls.editorModesPullDown
        p.isBordered = false
        p.controlSize = .small
        (p.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        p.setAccessibilityTitle("Editor Modes")
        p.toolTip = "Editor Modes"
        updateEditorModesPullDown()
        updateAreaToggleTitles()
    }

    /// Fits the toolbar on the next turn of the run loop (changes come in
    /// bursts: a build's activity text, issue counts).
    func scheduleToolbarFit() {
        guard !toolbarControls.fitScheduled else { return }
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
    static let toolbarSpacers: Set<NSToolbarItem.Identifier> = [.flexibleSpace, .space, .sidebarTrackingSeparator, .inspectorTrackingSeparator]

    /// Recovers room in the order of §2.2.2 until no item overflows: the
    /// editor modes fold into one pull-down, then the scheme name
    /// truncates, then the activity subtitle (in the middle). Each step is
    /// tried after a layout of the window's frame; a wider window undoes
    /// them. Item 11 (Show Inspector) has the highest visibility priority.
    public func fitToolbar() {
        guard let window, let frame = window.contentView?.superview, window.toolbar != nil, !toolbarControls.fitting else { return }
        toolbarControls.fitting = true
        defer { toolbarControls.fitting = false }
        func fits(_ f: ToolbarFit) -> Bool {
            apply(f)
            frame.layoutSubtreeIfNeeded()
            return overflowedToolbarItems.isEmpty
        }
        let natural = (scheme: schemeNaturalWidth, activity: activityView.naturalWidth)
        for f in ToolbarFit.steps(schemeNatural: natural.scheme, activityNatural: natural.activity) where fits(f) {
            toolbarControls.fit = f
            return
        }
        // Nothing fits: keep the tightest step; the lowest-priority items
        // (history, activity) overflow before the right group.
        toolbarControls.fit = ToolbarFit.steps(schemeNatural: natural.scheme, activityNatural: natural.activity).last ?? ToolbarFit()
        apply(toolbarControls.fit)
    }

    /// The scheme pop-up's width for its whole title.
    var schemeNaturalWidth: CGFloat {
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.isBordered = schemePopUp.isBordered
        probe.controlSize = schemePopUp.controlSize
        probe.addItem(withTitle: schemePopUp.titleOfSelectedItem ?? "")
        return ceil(probe.intrinsicContentSize.width)
    }

    func apply(_ f: ToolbarFit) {
        // Editor modes: the segmented control or the pull-down.
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.editorModesID }) {
            let view: NSView = f.editorModesCollapsed ? toolbarControls.editorModesPullDown : toolbarControls.editorModes
            if item.view !== view { item.view = view }
        }
        // Scheme name cap.
        if let cap = f.schemeWidth {
            if let c = toolbarControls.schemeCap { c.constant = cap } else {
                let c = schemePopUp.widthAnchor.constraint(lessThanOrEqualToConstant: cap)
                c.isActive = true
                toolbarControls.schemeCap = c
            }
        } else if let c = toolbarControls.schemeCap {
            c.isActive = false
            toolbarControls.schemeCap = nil
        }
        activityView.maximumWidth = f.activityWidth ?? .greatestFiniteMagnitude
    }

    // MARK: Editor modes pull-down (§2.2.2.1)

    /// The collapsed editor modes: the current mode's glyph with a chevron;
    /// its menu holds the three modes, the current one checked.
    func updateEditorModesPullDown() {
        let p = toolbarControls.editorModesPullDown
        let mode = activeEditorMode
        let symbols = ["rectangle.righthalf.inset.filled", "rectangle.split.2x1", "arrow.left.arrow.right"]
        let titles = ["Canvas", "Assistant", "Code Review"]
        let menu = NSMenu()
        let shown = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        shown.image = NSImage(systemSymbolName: symbols[mode?.rawValue ?? 0], accessibilityDescription: mode.map { titles[$0.rawValue] } ?? "Editor Modes")
        menu.addItem(shown)
        for m in EditorMode.allCases {
            let i = NSMenuItem(title: titles[m.rawValue], action: #selector(editorModeMenuChosen(_:)), keyEquivalent: "")
            i.target = self
            i.tag = m.rawValue
            i.image = NSImage(systemSymbolName: symbols[m.rawValue], accessibilityDescription: nil)
            i.state = m == mode ? .on : .off
            menu.addItem(i)
        }
        p.menu = menu
    }

    @objc func editorModeMenuChosen(_ item: NSMenuItem) {
        if let m = EditorMode(rawValue: item.tag) { setEditorMode(m) }
        updateToolbarState()
    }
}

/// How the toolbar recovers room (`reference-ui-6.md` §2.2): each step
/// adds to the previous one.
public struct ToolbarFit: Equatable, Sendable {
    /// The editor-mode capsule is one pull-down.
    public var editorModesCollapsed = false
    /// The scheme pop-up's width cap (nil: its whole name).
    public var schemeWidth: CGFloat?
    /// The activity view's width cap (nil: its whole subtitle).
    public var activityWidth: CGFloat?
    public init(editorModesCollapsed: Bool = false, schemeWidth: CGFloat? = nil, activityWidth: CGFloat? = nil) {
        self.editorModesCollapsed = editorModesCollapsed
        self.schemeWidth = schemeWidth
        self.activityWidth = activityWidth
    }

    /// The narrowest the scheme pop-up and the activity view get.
    public static let schemeMinimum: CGFloat = 56
    public static let activityMinimum: CGFloat = 72

    /// The steps in order, from nothing collapsed to the tightest: fold the
    /// editor modes; then shorten the scheme name in steps down to
    /// `schemeMinimum`; then the activity view down to `activityMinimum`.
    public static func steps(schemeNatural: CGFloat, activityNatural: CGFloat) -> [ToolbarFit] {
        var out = [ToolbarFit(), ToolbarFit(editorModesCollapsed: true)]
        func shrink(_ natural: CGFloat, _ minimum: CGFloat) -> [CGFloat] {
            var widths: [CGFloat] = []
            var w = natural
            while w > minimum {
                w = max(minimum, (w - max(24, natural * 0.15)).rounded(.down))
                widths.append(w)
            }
            return widths
        }
        let scheme = shrink(schemeNatural, schemeMinimum)
        for w in scheme { out.append(ToolbarFit(editorModesCollapsed: true, schemeWidth: w)) }
        let schemeLast = scheme.last
        for w in shrink(activityNatural, activityMinimum) {
            out.append(ToolbarFit(editorModesCollapsed: true, schemeWidth: schemeLast, activityWidth: w))
        }
        return out
    }
}
