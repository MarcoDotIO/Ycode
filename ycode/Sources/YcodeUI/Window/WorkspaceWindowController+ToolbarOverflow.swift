import AppKit
import YcodeIDECore

/// The toolbar in a narrow window (P-025, `ToolbarOverflow`): each item's
/// visibility priority, so the title area and Back | Forward stay while
/// the right group goes into the system's "»" overflow; and each item's
/// entry in that menu, with its glyph and, for an item with a menu or
/// segments, a sub-menu. The Run segment's press-and-hold menu (P-028,
/// `RunButtonMenu`) is attached here as well.
extension WorkspaceWindowController {
    /// Once the toolbar's items exist: their ranks, Run's menu and the
    /// overflow menu's entries.
    func setUpToolbarOverflow() {
        for item in window?.toolbar?.items ?? [] {
            guard let i = ToolbarOverflow.Item(rawValue: item.itemIdentifier.rawValue) else { continue }
            item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: ToolbarOverflow.rank(i))
        }
        attachRunHoldMenu()
        updateOverflowMenuForms()
    }

    /// Refreshes every item's entry in the "»" menu (the shown pane, the
    /// editor mode, the schemes and destinations change).
    /// `only`: just these identifiers (a fit refreshes the items it has
    /// moved into the menu; the scheme's rows cost a destination listing).
    func updateOverflowMenuForms(only: Set<String>? = nil) {
        for item in window?.toolbar?.items ?? [] {
            if let only, !only.contains(item.itemIdentifier.rawValue) { continue }
            guard let i = ToolbarOverflow.Item(rawValue: item.itemIdentifier.rawValue), let form = overflowMenuItem(i) else { continue }
            item.menuFormRepresentation = form
        }
    }

    /// The "»" menu's entry for an item (nil: the item never leaves).
    func overflowMenuItem(_ i: ToolbarOverflow.Item) -> NSMenuItem? {
        let entry = ToolbarOverflow.entry(i)
        let top = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        top.image = Self.overflowGlyph(entry.symbol)
        func sub(_ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: entry.title)
            items.forEach(m.addItem)
            return m
        }
        func row(_ title: String, _ symbol: String, _ action: Selector, tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let r = NSMenuItem(title: title, action: action, keyEquivalent: "")
            r.target = self
            r.tag = tag
            r.image = Self.overflowGlyph(symbol)
            r.state = on ? .on : .off
            return r
        }
        switch i {
        case .inspectorToggle: return nil
        case .leftPanes:
            let shown = shownLeftPane
            let rows = ToolbarOverflow.segments(.leftPanes).enumerated().map { n, s in
                row(s.title, s.symbol, #selector(overflowLeftPaneChosen(_:)), tag: n, on: n == 0 ? shown == .navigators : shown == .codingAssistant)
            }
            top.submenu = sub(rows)
        case .run:
            var rows = RunButtonMenu.rows.map { r in runMenuRow(r) }
            rows.append(.separator())
            rows.append(row("Stop", WorkspaceChrome.runStop.symbols[1], #selector(stopProduct(_:))))
            top.submenu = sub(rows)
        case .history:
            let s = ToolbarOverflow.segments(.history)
            top.submenu = sub([row(s[0].title, s[0].symbol, #selector(goBack(_:))), row(s[1].title, s[1].symbol, #selector(goForward(_:)))])
        case .activity:
            // Disabled (no action), Ycode's mark as its glyph.
            top.image = NavigatorRowImages.ycodeMark(side: 16)
        case .newConversation:
            top.action = #selector(toggleNewConversationPrompt(_:))
            top.target = self
        case .scheme:
            // No glyph, as the reference's Scheme and Destination entries.
            top.submenu = sub(overflowSchemeRows())
        case .issues:
            // The most severe kind's symbol; a row per kind with its count,
            // each opening the Issue navigator as the capsule's parts do.
            let kinds: [(IssueSummary.Kind, Int)] = [(.error, issueCapsule.errors), (.warning, issueCapsule.warnings),
                                                     (.testFailure, issueCapsule.failedTests)].filter { $0.1 > 0 }
            // The entry's glyph is the outlined warning triangle whatever
            // the kinds (`window-layout.md` §2.4 row 8; `entry(.issues)`).
            top.submenu = sub(kinds.map { k, n in row(ToolbarOverflow.issueRow(k, count: n), k.symbol, #selector(overflowShowIssues(_:))) })
        case .addEditor:
            top.submenu = EditorOptionsMenu.addMenu()
        case .editorOptions:
            top.submenu = EditorOptionsMenu.menu()
        case .editorModes:
            let modes = editorModesMenuItem()
            top.submenu = modes.submenu
            modes.submenu = nil
        }
        return top
    }

    /// A glyph of the overflow menu: the system's symbol, at the menu's
    /// size (none for an empty name).
    static func overflowGlyph(_ symbol: String) -> NSImage? {
        symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// The scheme entry's rows: each scheme (the current one checked),
    /// then the run destinations under their heading.
    func overflowSchemeRows() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for (n, s) in schemePopUp.itemArray.enumerated() where !s.isSeparatorItem && !s.title.isEmpty {
            let r = NSMenuItem(title: s.title, action: #selector(overflowSchemeChosen(_:)), keyEquivalent: "")
            r.target = self
            r.tag = n
            r.image = s.image
            r.state = n == schemePopUp.indexOfSelectedItem ? .on : .off
            out.append(r)
        }
        let sections = destinationMenuModel().sections.filter { !$0.destinations.isEmpty }
        guard !sections.isEmpty else { return out }
        out.append(.separator())
        out.append(NSMenuItem.sectionHeader(title: ToolbarOverflow.destinationsHeading))
        let current = destinationPopUp.selectedItem?.representedObject as? String
        var seen = Set<String>()
        for d in sections.flatMap(\.destinations) {
            let key = Self.menuKey(for: d)
            guard seen.insert(key).inserted else { continue }
            let r = NSMenuItem(title: d.name, action: #selector(overflowDestinationChosen(_:)), keyEquivalent: "")
            r.target = self
            r.representedObject = key
            r.image = d.kind == .mac ? SchemeCapsuleImages.hostImage() : NSImage(systemSymbolName: Self.symbol(for: d), accessibilityDescription: nil)
            r.state = key == current ? .on : .off
            out.append(r)
        }
        return out
    }

    @objc func overflowLeftPaneChosen(_ item: NSMenuItem) { setLeftPane(codingAssistant: item.tag == 1) }

    @objc func overflowSchemeChosen(_ item: NSMenuItem) {
        guard schemePopUp.itemArray.indices.contains(item.tag) else { return }
        schemePopUp.selectItem(at: item.tag)
        schemeChosen(schemePopUp)
        updateOverflowMenuForms()
    }

    @objc func overflowDestinationChosen(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String,
              let target = destinationPopUp.itemArray.first(where: { ($0.representedObject as? String) == key }) else { return }
        destinationPopUp.select(target)
        destinationChosen(destinationPopUp)
        updateOverflowMenuForms()
    }

    /// The issues entry opens the Issue navigator, as the capsule does.
    @objc func overflowShowIssues(_ sender: Any?) { showNavigator(4) }

    // MARK: P-028: Run's press-and-hold menu

    /// One row of Run's menu: the Product menu's action and the scheme
    /// editor's glyph. The window validates it as the menu bar's item.
    func runMenuRow(_ r: RunButtonMenu.Row) -> NSMenuItem {
        let item = NSMenuItem(title: r.title, action: NSSelectorFromString(r.selector), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: r.symbol, accessibilityDescription: nil)
        return item
    }

    /// The menu the Run segment shows while the mouse is held on it.
    public func runHoldMenu() -> NSMenu {
        let m = NSMenu(title: "Run")
        RunButtonMenu.rows.forEach { m.addItem(runMenuRow($0)) }
        return m
    }

    /// Run | Stop's control (nil before the toolbar exists).
    public var runStopControl: NSSegmentedControl? {
        window?.toolbar?.items.first { $0.itemIdentifier == Self.runID }?.view as? NSSegmentedControl
    }

    /// Gives the Run segment its menu. AppKit shows a momentary segment's
    /// menu when the mouse is held on it and sends the action on a click;
    /// the segment draws no menu arrow (the reference's has none).
    func attachRunHoldMenu() {
        guard let c = runStopControl else { return }
        c.setMenu(runHoldMenu(), forSegment: 0)
        c.setShowsMenuIndicator(false, forSegment: 0)
    }
}
