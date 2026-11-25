import AppKit
import YcodeIDECore
import YcodeSimFeatures
import YcodeSubprocess

/// Keeps the menu bar's state current each time a menu is shown or
/// searched for a key equivalent (`specs/ide/reference-ui-5.md` §1):
/// titles in context (§1.3), conditional items and their separators
/// (§1.5), the menus filled from state (developer tools, the focused
/// editor's inspectors, the scheme rows), and the system's items that
/// collide with the table (§1.6).
@MainActor
public final class MenuBarDelegate: NSObject, NSMenuDelegate {
    public static let shared = MenuBarDelegate()
    /// Tag of items a filler adds (removed on the next update).
    static let dynamicTag = 9_918

    /// The workspace window the menus act on: the main window's controller.
    static var controller: WorkspaceWindowController? {
        (NSApp?.mainWindow?.windowController ?? NSApp?.keyWindow?.windowController) as? WorkspaceWindowController
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        update(menu, controller: Self.controller)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        // AppKit may add its items after the update; check again on display.
        removeSystemAdditions(menu)
        if menu.supermenu === NSApp?.mainMenu {
            MainMenu.removeSystemConflicts(in: menu)
            MainMenu.collapseSeparators(in: menu)
        }
    }

    /// Fills, titles, shows or hides and tidies one menu.
    public func update(_ menu: NSMenu, controller wc: WorkspaceWindowController?) {
        let ctx = wc?.menuContext
        removeSystemAdditions(menu)
        if let m = menu as? CommandMenu { DynamicMenus.fill(m, controller: wc) }
        for item in menu.items {
            disableIfEmpty(item)
            guard let c = item as? CommandMenuItem, let spec = c.spec else { continue }
            c.title = MenuTitles.title(for: spec, in: ctx)
            c.isHidden = !MenuConditions.isShown(spec.condition, in: ctx)
            MainMenu.restoreShortcut(c)
            gateTextSystemItem(c, action: spec.action, controller: wc)
            // P-007: the minimap's check mark whoever performs the item.
            if spec.action == "toggleMinimap:", let e = wc?.editor, e.fileURL != nil { c.state = e.showsMinimap ? .on : .off }
            MainMenu.applyGlyph(c)
        }
        if menu.supermenu === NSApp?.mainMenu, NSApp?.mainMenu != nil { MainMenu.removeSystemConflicts(in: menu) }
        MainMenu.collapseSeparators(in: menu)
    }
}

extension MenuBarDelegate {
    /// Submenus Ycode never fills are listed disabled (P-004, P-015:
    /// Debug ▸ Induce Device Conditions): the item gets an action no one
    /// performs, so AppKit's validation disables it.
    static let alwaysEmptySubmenus: Set<String> = ["Induce Device Conditions"]

    func disableIfEmpty(_ item: NSMenuItem) {
        guard let sub = item.submenu, Self.alwaysEmptySubmenus.contains(item.title), sub.items.isEmpty else { return }
        item.target = nil
        item.action = NSSelectorFromString("ycodeUnavailableEmptySubmenu:")
    }

    /// Rich-text commands of Edit ▸ Format that do not apply to code
    /// (P-009): disabled, unchecked, while a source editor has focus.
    static let richTextActions: Set<String> = [
        "underline:", "addFontTrait:", "alignLeft:", "alignCenter:", "alignJustified:", "alignRight:", "toggleGrammarChecking:",
        "orderFrontSubstitutionsPanel:", "toggleSmartInsertDelete:", "toggleAutomaticQuoteSubstitution:", "toggleAutomaticDashSubstitution:",
        "toggleAutomaticLinkDetection:", "toggleAutomaticDataDetection:", "toggleAutomaticTextReplacement:", "startSpeaking:", "stopSpeaking:",
    ]

    /// An object that performs nothing: an item targeting it is disabled.
    static let disabledTarget = NSObject()

    func gateTextSystemItem(_ item: NSMenuItem, action: String, controller wc: WorkspaceWindowController?) {
        // P-008: Page Setup… needs a document.
        if action == "runPageLayout:" {
            item.target = wc?.editor.fileURL == nil ? Self.disabledTarget : nil
            return
        }
        guard Self.richTextActions.contains(action) else { return }
        let code = (wc?.window?.firstResponder ?? NSApp?.keyWindow?.firstResponder) is SourceTextView
        item.target = code ? Self.disabledTarget : nil
        if code { item.state = .off }
    }

    /// System items Ycode leaves out (`reference-ui-6.md` §8 items 1–2):
    /// a second Open Recent in File, the feedback item in Help.
    func removeSystemAdditions(_ menu: NSMenu) {
        switch (menu as? CommandMenu)?.path {
        case "File": MainMenu.removeSystemRecentMenus(in: menu)
        case "Help": MainMenu.removeSystemFeedbackItem(in: menu)
        case "Ycode": removeSystemQuitAlternates(in: menu)
        default: break
        }
    }

    /// P-002: AppKit's own "Quit and Keep Windows" / "Quit and Close All
    /// Windows" beside the table's ⌥⌘Q alternate (so it is listed once).
    func removeSystemQuitAlternates(in menu: NSMenu) {
        for i in menu.items.reversed() where !(i is CommandMenuItem) && i.title.hasPrefix("Quit and ") { menu.removeItem(i) }
    }
}

/// Menus filled from state when they are shown.
@MainActor
enum DynamicMenus {
    static func fill(_ m: CommandMenu, controller wc: WorkspaceWindowController?) {
        switch m.path {
        case "Ycode ▸ Open Developer Tool": fillDeveloperTools(m, tools: DeveloperTools.installed)
        // P-006 (council round 11, B02): with only Welcome, Show Inspector
        // alone (disabled); in a workspace with no file open, File, History
        // and Quick Help before it.
        case "View ▸ Inspectors":
            fillInspectors(m, names: wc.map { $0.menuContext.editorKind == .other && $0.editor.fileURL == nil ? CommandTable.inspectors : $0.inspector.tabNames } ?? [])
        case "Product ▸ Scheme": fillSchemes(m, names: wc?.session.model.schemeNames ?? [], active: wc?.session.scheme, target: wc)
        case "Product ▸ Destination":
            guard let wc else { removeDynamic(m); break }
            fillDestinationMenu(m, model: wc.destinationMenuModel(), current: wc.session.destination, target: wc)   // P-014 (+Choosers.swift)
        case "Product ▸ Test Plan":
            guard let wc else { removeDynamic(m); break }
            fillTestPlans(m, rows: wc.session.testPlanRows, plans: wc.session.testPlanNames, active: wc.session.effectiveTestPlan, target: wc)
        // P-006: with no editor, the first block only. With only Welcome
        // open "Preview" is unchecked (council round 11).
        case "Editor":
            fillEditor(m, kind: wc?.menuContext.editorKind ?? .other, welcome: wc == nil)
            if wc == nil { m.items.first { $0.action == NSSelectorFromString("toggleCanvas:") }?.state = .off }
        case "Debug ▸ Simulate Location": fillMenuBarSimulateLocation(m, controller: wc)
        case "Debug ▸ Attach to Process": RunningProcesses.fillAsync(m, target: wc)
        default: break
        }
    }

    /// §2.7 / §2.8: the Editor menu of the focused editor's kind, rebuilt
    /// when the kind changes.
    static func fillEditor(_ m: CommandMenu, kind: EditorKind, welcome: Bool = false) {
        guard m.editorKind != kind || m.isWelcomeEditor != welcome else { return }
        let fresh = MainMenu.menu("Editor", welcome ? EditorMenu.welcomeItems : EditorMenu.items(for: kind), path: "Editor")
        m.removeAllItems()
        for i in fresh.items {
            fresh.removeItem(i)
            m.addItem(i)
        }
        m.editorKind = kind
        m.isWelcomeEditor = welcome
        MainMenu.markCheckedDisabled(in: m, kind: kind)
    }

    /// Debug ▸ Simulate Location (P-015): Don’t Simulate Location, the
    /// preset places, then Add GPS Exchange to Project…; the places are
    /// chosen while an app runs on the Ycode simulator (the debug bar's
    /// menu) and listed disabled otherwise.
    static func fillMenuBarSimulateLocation(_ m: NSMenu, controller wc: WorkspaceWindowController?) {
        fillSimulateLocation(m, controller: wc)
        m.autoenablesItems = false
        // The debug bar's note that a run is needed is not a menu-bar row.
        for i in m.items.reversed() where i.action == nil && !i.isSeparatorItem { m.removeItem(i) }
        let dont = "Don\u{2019}t Simulate Location"
        if let first = m.items.first, first.title.hasPrefix("Don") { first.title = dont } else {
            let i = NSMenuItem(title: dont, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.insertItem(i, at: 0)
        }
        let places = Set(SimLocation.presets.map(\.name))
        if !m.items.contains(where: { places.contains($0.title) }) {
            while m.items.last?.isSeparatorItem == true { m.removeItem(at: m.items.count - 1) }
            m.addItem(.separator())
            for p in SimLocation.presets {
                let i = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
                i.isEnabled = false
                m.addItem(i)
            }
        }
        while m.items.last?.isSeparatorItem == true { m.removeItem(at: m.items.count - 1) }
        m.addItem(.separator())
        let gpx = NSMenuItem(title: "Add GPS Exchange to Project…", action: nil, keyEquivalent: "")
        gpx.isEnabled = false
        m.addItem(gpx)
    }

    static func removeDynamic(_ m: NSMenu) {
        for i in m.items.reversed() where i.tag == MenuBarDelegate.dynamicTag { m.removeItem(i) }
    }

    /// §2.1 item 7: one item per tool found, before the separator.
    static func fillDeveloperTools(_ m: NSMenu, tools: [DeveloperTools.Tool]) {
        removeDynamic(m)
        for (n, t) in tools.enumerated() {
            let i = NSMenuItem(title: t.name, action: #selector(AppCommands.openDeveloperTool(_:)), keyEquivalent: "")
            i.target = AppCommands.shared
            i.representedObject = t.url
            i.tag = MenuBarDelegate.dynamicTag
            m.insertItem(i, at: n)
        }
    }

    /// §2.4 item 9: one item per inspector tab of the focused editor, ⌥⌘1…
    static func fillInspectors(_ m: NSMenu, names: [String]) {
        let end = m.items.firstIndex(where: \.isSeparatorItem) ?? 0
        guard m.items[..<end].map(\.title) != names else { return }
        for _ in 0..<end { m.removeItem(at: 0) }
        for (i, n) in names.enumerated() {
            let key = i < 9 ? "⌥⌘\(i + 1)" : ""
            let c = MenuCommand(n, shortcut: key, "showInspector:", tag: i)
            m.insertItem(MainMenu.item(for: KeyBindings.effective(c), base: nil), at: i)
        }
    }

    /// §2.9 item 19: the scheme rows after the commands, the active one checked.
    static func fillSchemes(_ m: NSMenu, names: [String], active: String?, target: AnyObject?) {
        removeDynamic(m)
        guard !names.isEmpty else { return }
        let sep = NSMenuItem.separator()
        sep.tag = MenuBarDelegate.dynamicTag
        m.addItem(sep)
        for (n, name) in names.enumerated() {
            let i = NSMenuItem(title: name, action: #selector(WorkspaceWindowController.selectSchemeRow(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = n
            i.tag = MenuBarDelegate.dynamicTag
            i.state = name == active ? .on : .off
            m.addItem(i)
        }
    }
}
