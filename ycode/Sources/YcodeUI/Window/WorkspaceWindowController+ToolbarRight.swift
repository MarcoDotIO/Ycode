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

    /// Adjust Editor Options, in order (P-065): Layout places the canvas,
    /// as Editor ▸ Layout does; the toggles carry the Editor menu's key
    /// equivalents and check marks. The choices apply to the focused editor.
    static var items: [MenuItemSpec] {
        func c(_ t: String, _ s: String, _ a: String, tag: Int = 0) -> MenuItemSpec { .command(.init(t, shortcut: s, a, tag: tag)) }
        return [
            .submenu("Layout", [
                c("Automatic", "", "setCanvasLayout:", tag: 0),
                .separator,
                c("Canvas on Right", "", "setCanvasLayout:", tag: 1),
                c("Canvas on Bottom", "", "setCanvasLayout:", tag: 2),
            ]),
            .separator,
            c("Inline Comparison", "", "showInlineComparison:"),
            c("Side By Side Comparison", "", "showSideBySideComparison:"),
            .separator,
            c("Minimap", "⌃⇧⌘M", "toggleMinimap:"),
            c("Authors", "⌃⇧⌘A", "toggleAuthors:"),
            c("Code Coverage", "", "toggleCodeCoverage:"),
            .separator,
            c("Invisibles", "", "toggleInvisibles:"),
            c("Scope Guides", "", "toggleScopeGuides:"),
            c("Wrap Lines", "⌃⇧⌘L", "toggleWrapLines:"),
            .separator,
            c("Choose Workspace Theme…", "", "chooseTheme:"),
        ]
    }

    /// Add Editor Tabs or Editor Panes (P-065, `editor-area.md` D.9): Tab,
    /// a separator, then the two panes, with File ▸ New's key equivalents.
    static var addItems: [MenuItemSpec] {
        [
            .command(.init("Tab", shortcut: "⌘T", "newTab:")),
            .separator,
            .command(.init("Editor Pane On Right", shortcut: "⌃⌘T", "splitEditor:")),
            .command(.init("Editor Pane Below", shortcut: "⌃⌥⌘T", "splitEditorBelow:")),
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
            MainActor.assumeIsolated {
                // Inside the window's own frame change the toolbar's items
                // are not set again (`unstickOverflow`); a fit on the next
                // turn may.
                guard let self else { return }
                Self.fittingInResize = true
                self.fitToolbar()
                Self.fittingInResize = false
                if self.toolbarControls.fitNeedsUnstick {
                    self.toolbarControls.fitNeedsUnstick = false
                    self.scheduleToolbarFit()
                }
            }
        })
        leftAreaObservation.tokens.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: mainSplit.splitView,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleToolbarFit() }
        })
        // The toggles' titles follow at once (they change no item's size);
        // the rest of the toolbar's state, the window's minimum and the fit
        // on the next turn: KVO can fire inside a layout pass (a collapse
        // from a window resize).
        leftAreaObservation.tokens.append(inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateAreaToggleTitles()
                self?.scheduleToolbarStateUpdate()
                self?.scheduleToolbarFit()
            }
        })
        leftAreaObservation.tokens.append(debugItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateAreaToggleTitles() }
        })
        setUpToolbarOverflow()   // +ToolbarOverflow.swift (P-025, P-028)
        updateEditorModesPullDown()
        updateAreaToggleTitles()
    }

    /// Fits the toolbar on the next turn of the run loop (changes come in
    /// bursts: a build's activity text, issue counts).
    func scheduleToolbarFit() {
        // The inspector's slide fits the toolbar once, at its end (row 106).
        // A request made while the fit runs comes from the fit's own steps
        // (the issue capsule's counts appear and go as each step is tried):
        // the fit measures after them, so it needs no second fit, and one
        // would try the steps again and ask again, every turn (B6).
        guard !toolbarControls.fitScheduled, !toolbarControls.fitting, !isInspectorSliding else { return }
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
        // The steps follow the activity view's natural width without its
        // leading pad, so the fit's own layout (which measures the gap
        // before the view and sets the pad) cannot change them. When that
        // layout changed the pad, the view is wider or narrower: one more
        // fit measures with it.
        let natural = activityView.naturalFrameWidth
        defer {
            toolbarControls.fitting = false
            if abs(activityView.naturalFrameWidth - natural) >= 1 { scheduleToolbarFit() }
        }
        // The first try lays out the whole frame (the toolbar's room follows
        // the areas' dividers); the steps only change toolbar items, so later
        // tries lay out the title bar alone, not the editor's text again
        // (`editor-area.md` F.6, row 107: the resize call blocked 264 ms).
        let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview
        var laidOut = false
        var lastGlyphs = schemeShowsGlyphsOnly
        func fits(_ f: ToolbarFit) -> Bool {
            apply(f)
            // The scheme's titles going (or coming back) change the bar the
            // most: that try lays out the whole frame, as the first does.
            let full = !laidOut || f.schemeGlyphsOnly != lastGlyphs
            lastGlyphs = f.schemeGlyphsOnly
            let view = full ? frame : (titlebar ?? frame)
            view.layoutSubtreeIfNeeded()
            laidOut = true
            if f.accepts(overflowed: overflowedToolbarItems) { return true }
            // An item moved into "»" for an earlier, wider try comes back
            // only on a later pass (with the subtitle's many steps the
            // whole bar could stay in "»", council round 12's fit).
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            if f.accepts(overflowed: overflowedToolbarItems) { return true }
            unstickOverflow(allowed: f.overflowAllowance, frame: view)
            return f.accepts(overflowed: overflowedToolbarItems)
        }
        // Council round 12 (`window-layout.md` §2.3): the content section's
        // width puts the right group's items in "»" at fixed widths.
        let forced = Set(ToolbarOverflow.forcedOut(content: toolbarContentWidth).map(\.rawValue))
        activityView.reservedWidth = 0
        let steps = ToolbarFit.steps(activityNatural: activityView.naturalWidth, forced: forced)
        defer {
            // The editor modes are left to the fit: sent by force, the "»"
            // they leave for takes Editor Options' room too.
            forceOverflow(forced.subtracting([ToolbarFit.editorModesItem]), frame: frame)
            settleFit(frame: frame)
            updateOverflowMenuForms(only: Set(overflowedToolbarItems))
        }
        for (k, f) in steps.enumerated() where fits(f) {
            // The refining probes lay out the whole frame, twice after a
            // miss: an item the toolbar moved into "»" for a wider probe
            // comes back only on a later pass.
            func probe(_ g: ToolbarFit) -> Bool {
                apply(g)
                // Items a wider probe sent into "»" are measured anew.
                unstickOverflow(allowed: [], frame: frame)
                frame.layoutSubtreeIfNeeded()
                if g.accepts(overflowed: overflowedToolbarItems) { return true }
                frame.needsLayout = true
                frame.layoutSubtreeIfNeeded()
                if g.accepts(overflowed: overflowedToolbarItems) { return true }
                unstickOverflow(allowed: g.overflowAllowance, frame: frame)
                return g.accepts(overflowed: overflowedToolbarItems)
            }
            toolbarControls.fit = f.activityWidth == nil || k == 0 ? f : widestActivity(f, before: steps[k - 1], fits: probe)
            return
        }
        // Nothing fits: keep the tightest step; the remaining items
        // overflow by visibility priority.
        toolbarControls.fit = steps.last ?? ToolbarFit()
        apply(toolbarControls.fit)
    }

    /// The toolbar's content section: the window less the navigator's
    /// column (≈ 255 with it hidden) and the inspector's (≈ 50 with it
    /// hidden; `ToolbarOverflow.contentWidth`).
    var toolbarContentWidth: Double {
        guard let window else { return 0 }
        let nav = navigatorItem.isCollapsed || isNavigatorSliding ? nil : Double(navigator.view.frame.width)
        let insp = inspectorItem.isCollapsed ? nil : Double(inspector.view.frame.width)
        return ToolbarOverflow.contentWidth(window: Double(window.frame.width), navigator: nav, inspector: insp)
    }

    /// The fit's searches lay out the title bar alone between full
    /// layouts, and an item at the edge of the room can still leave in the
    /// full one (New Conversation beside a subtitle widened by the scheme
    /// capsule's leaving): the cap comes down in small steps until only the
    /// items the fit allows are in "»".
    func settleFit(frame: NSView) {
        var f = toolbarControls.fit
        // An item the toolbar moved into "»" for a wider try comes back only
        // on a later pass: judge after two.
        func accepted() -> Bool {
            if f.accepts(overflowed: overflowedToolbarItems) { return true }
            frame.needsLayout = true
            frame.layoutSubtreeIfNeeded()
            if f.accepts(overflowed: overflowedToolbarItems) { return true }
            unstickOverflow(allowed: f.overflowAllowance, frame: frame)
            return f.accepts(overflowed: overflowedToolbarItems)
        }
        var tries = 0
        while !accepted(), tries < 40 {
            let cap = f.activityWidth ?? activityView.naturalWidth
            guard cap > ToolbarFit.activityMinimum else { break }
            f.activityWidth = max(ToolbarFit.activityMinimum, cap - 2)
            apply(f)
            frame.layoutSubtreeIfNeeded()
            tries += 1
        }
        // Room the title keeps for a forced "»" is the subtitle's to use:
        // the widest cap that still leaves only the allowed items in "»",
        // to 2 points.
        if activityView.reservedWidth > 0, let cap = f.activityWidth {
            var lo = max(cap, (activityView.reservedWidth - activityView.leadingPad).rounded(.down)), hi = activityView.naturalWidth
            var best = f
            best.activityWidth = min(lo, hi)
            while hi - lo > 2 {
                var g = f
                g.activityWidth = ((lo + hi) / 2).rounded(.down)
                apply(g)
                frame.layoutSubtreeIfNeeded()
                var ok = g.accepts(overflowed: overflowedToolbarItems)
                if !ok {
                    frame.needsLayout = true
                    frame.layoutSubtreeIfNeeded()
                    ok = g.accepts(overflowed: overflowedToolbarItems)
                }
                if ok { lo = g.activityWidth ?? lo; best = g } else { hi = g.activityWidth ?? hi }
            }
            f = best
            apply(f)
            frame.layoutSubtreeIfNeeded()
        }
        toolbarControls.fit = f
    }

    /// Whether the running fit was called from the window's resize.
    nonisolated(unsafe) static var fittingInResize = false

    /// AppKit's toolbar keeps items in "»" that left for a wider try even
    /// when the room is back (only a change of the toolbar's width or of
    /// its items brings them back): each such item's view, set again, is
    /// measured anew.
    func unstickOverflow(allowed: Set<String>, frame: NSView) {
        guard let toolbar = window?.toolbar else { return }
        let out = Set(overflowedToolbarItems).subtracting(allowed)
        guard !out.isEmpty else { return }
        // Not while the window changes its frame: AppKit is laying the
        // toolbar out around this call (a full run crashed in its layout).
        guard !Self.fittingInResize else {
            toolbarControls.fitNeedsUnstick = true
            return
        }
        // An item in "»" keeps the size it had when it left (the scheme
        // capsule with its titles): its view, set again, is measured anew.
        for item in toolbar.items where out.contains(item.itemIdentifier.rawValue) {
            guard let v = item.view else { continue }
            v.invalidateIntrinsicContentSize()
            item.view = nil
            item.view = v
        }
        frame.needsLayout = true
        frame.layoutSubtreeIfNeeded()
    }

    /// Moves `forced` into "»" when the toolbar still has room for them:
    /// the title area keeps blank room after its text (its rank is above
    /// the right group's, so the toolbar gives up those items instead), the
    /// least that sends them all.
    func forceOverflow(_ forced: Set<String>, frame: NSView) {
        guard let window, !forced.isEmpty, !forced.isSubset(of: Set(overflowedToolbarItems)) else { return }
        func sends(_ r: CGFloat) -> Bool {
            activityView.reservedWidth = r
            frame.layoutSubtreeIfNeeded()
            if forced.isSubset(of: Set(overflowedToolbarItems)) { return true }
            frame.needsLayout = true
            frame.layoutSubtreeIfNeeded()
            return forced.isSubset(of: Set(overflowedToolbarItems))
        }
        var lo = activityView.frame.width, hi = window.frame.width
        guard sends(hi) else {
            activityView.reservedWidth = 0
            frame.layoutSubtreeIfNeeded()
            return
        }
        while hi - lo > 2 {
            let mid = ((lo + hi) / 2).rounded(.down)
            if sends(mid) { hi = mid } else { lo = mid }
        }
        _ = sends(hi)
    }

    /// P-029 (N02): the subtitle keeps all the room there is. `f` is the
    /// first step that fits and `before` the one before it, which did not:
    /// the widest cap between the two that still fits, to 2 points (about
    /// six layouts of the title bar), so the subtitle is not cut by more
    /// than the step's 24 points ("Build …23 PM" where the reference
    /// shows "Build Fail…6:39 PM").
    func widestActivity(_ f: ToolbarFit, before: ToolbarFit, fits: (ToolbarFit) -> Bool) -> ToolbarFit {
        guard let low = f.activityWidth else { return f }
        var best = f, lo = low, hi = before.activityWidth ?? activityView.naturalWidth
        var lastTried = f
        // The step before was judged on the title bar's layout alone, which
        // can miss by a few points (with the issue capsule in the toolbar,
        // P-120): a full probe of its cap decides, and when it fits the
        // search goes on above it.
        if before.activityWidth != nil {
            var g = f
            g.activityWidth = hi
            lastTried = g
            if fits(g) { lo = hi; best = g; hi = activityView.naturalWidth }
        }
        while hi - lo > 2 {
            var g = f
            g.activityWidth = ((lo + hi) / 2).rounded(.down)
            lastTried = g
            if fits(g) { lo = g.activityWidth ?? lo; best = g } else { hi = g.activityWidth ?? hi }
        }
        if lastTried != best { _ = fits(best) }
        return best
    }

    func apply(_ f: ToolbarFit) {
        setSchemeGlyphsOnly(f.schemeGlyphsOnly)
        // The issue capsule shows its symbols only with the scheme's glyphs
        // (editor-area.md G.4, G.8).
        issueCapsule.symbolsOnly = f.schemeGlyphsOnly
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

    /// The entries in the "»" menu that follow the shown panes and modes
    /// (`ToolbarOverflow`): "Editor Modes" with the three modes, the
    /// current one checked; Navigators with the shown pane checked.
    func updateEditorModesPullDown() {
        updateOverflowMenuForms(only: [Self.editorModesID.rawValue, Self.leftPanesID.rawValue])
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
