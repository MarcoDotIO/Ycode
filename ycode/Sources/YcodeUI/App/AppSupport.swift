import AppKit
import YcodeLanguage

/// One open workspace. Ycode opens `.xcodeproj`, `.xcworkspace` and package
/// folders; saving writes edited sources and changed projects (through the
/// byte-exact pbxproj writer).
@MainActor
public final class WorkspaceDocument: NSDocument {
    nonisolated(unsafe) public private(set) var model: WorkspaceModel?
    public static let typeName = "org.ycode.workspace"

    public override class var autosavesInPlace: Bool { false }

    nonisolated public override func read(from url: URL, ofType typeName: String) throws {
        model = try WorkspaceModel(url: url)
    }

    public override func makeWindowControllers() {
        guard let model else { return }
        // Also recorded by the document controller; noted here as well so
        // the list never depends on the bundle's document types.
        RecentProjects.shared.note(model.url)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model))
        addWindowController(wc)
        wc.window?.center()
        wc.applyDefaultLayout()
    }

    /// Saving goes through the window controller (editor files + projects),
    /// not NSDocument's file wrapper.
    public override func save(_ sender: Any?) {
        (windowControllers.first as? WorkspaceWindowController)?.saveDocument(sender)
    }
}

/// Opens any supported container as a `WorkspaceDocument`, so the app does
/// not depend on Info.plist document types when run unbundled.
@MainActor
public final class YcodeDocumentController: NSDocumentController {
    public override func typeForContents(of url: URL) throws -> String { WorkspaceDocument.typeName }
    public override func documentClass(forType typeName: String) -> AnyClass? { WorkspaceDocument.self }
    public override var defaultType: String? { WorkspaceDocument.typeName }

    /// File ▸ Open… (⌘O) is always available: unbundled (no Info.plist
    /// document types) AppKit would otherwise disable it.
    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(openDocument(_:)) ? true : super.validateUserInterfaceItem(item)
    }

    public override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        openPanel.canChooseDirectories = true
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.allowedContentTypes = []
        return super.runModalOpenPanel(openPanel, forTypes: nil)
    }

    /// Every opened workspace is also recorded for File ▸ Open Recent and
    /// the Welcome window (`reference-ui-5.md` §3.2).
    public override func noteNewRecentDocumentURL(_ url: URL) {
        RecentProjects.shared.note(url)
        super.noteNewRecentDocumentURL(url)
    }

    public override func clearRecentDocuments(_ sender: Any?) {
        RecentProjects.shared.clear()
        super.clearRecentDocuments(sender)
    }
}

/// A menu-bar item built from a `CommandTable` command; `spec` keeps the
/// generic title and condition for `MenuBarDelegate`.
@MainActor
public final class CommandMenuItem: NSMenuItem {
    public var spec: MenuCommand?
}

/// A menu built from `CommandTable`; `path` names it ("View ▸ Inspectors").
@MainActor
public final class CommandMenu: NSMenu {
    public var path = ""
    /// For the Editor menu: the editor kind its items are for (§2.7, §2.8).
    public var editorKind: EditorKind = .source
}

/// Builds the menu bar from `CommandTable` (`specs/ide/reference-ui-5.md`
/// §1–§2): alternates (§1.2), section labels (§1.4), conditional items
/// (§1.5, hidden until `MenuBarDelegate` shows them) and no copies of the
/// system's items (§1.6).
@MainActor
public enum MainMenu {
    /// Menus whose contents AppKit or another delegate manages.
    static let foreignMenus: Set<String> = ["Ycode ▸ Services", "File ▸ Open Recent", "Editor ▸ Refactor"]

    public static func make() -> NSMenu {
        // §1.6: no second full-screen item from AppKit (the View menu has ⌃⌘F).
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        let bar = NSMenu()
        for (title, items) in CommandTable.menus {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu(title, items, path: title)
            bar.addItem(top)
            if title == "Window" { NSApp?.windowsMenu = top.submenu }
            if title == "Editor", let m = top.submenu { markCheckedDisabled(in: m, kind: .source) }
            if title == "Help" { NSApp?.helpMenu = top.submenu }
        }
        return bar
    }

    static func menu(_ title: String, _ items: [MenuItemSpec], path: String? = nil) -> NSMenu {
        let path = path ?? title
        let m = CommandMenu(title: title)
        m.path = path
        if !foreignMenus.contains(path) { m.delegate = MenuBarDelegate.shared }
        var base: MenuCommand?
        for item in items {
            switch item {
            case .separator: m.addItem(.separator())
            case .label(let t): m.addItem(.sectionHeader(title: t))
            case .submenu(let t, let sub):
                let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                i.submenu = menu(t, sub, path: path + " ▸ " + t)
                if t == "Refactor" { i.submenu?.delegate = RefactorMenuDelegate.shared }
                if path == "Ycode", t == "Services" { NSApp?.servicesMenu = i.submenu }
                if t == "Open Recent" { i.submenu?.delegate = RecentProjectsMenuDelegate.shared }
                m.addItem(i)
            case .command(let original):
                // Settings ▸ Key Bindings can change the shortcut.
                let c = KeyBindings.effective(original)
                m.addItem(MainMenu.item(for: c, base: c.isAlternate ? base : nil))
                if !c.isAlternate { base = c }
            }
        }
        return m
    }

    /// One command's item. An alternate whose key is spelled shifted
    /// ("⌥⌘<" under "⌥⌘,") uses its base's key plus ⇧, so AppKit pairs them.
    static func item(for c: MenuCommand, base: MenuCommand?) -> CommandMenuItem {
        var key = c.key, mods = c.modifiers
        if let base, !key.isEmpty, key != base.key, Key.shiftedBase[key] == base.key {
            key = base.key
            mods.insert(.shift)
        }
        let i = CommandMenuItem(title: c.title, action: Selector(c.action), keyEquivalent: key)
        i.spec = c
        i.keyEquivalentModifierMask = modifierFlags(mods, key: key)
        i.tag = c.tag
        i.isAlternate = c.isAlternate
        if AppCommands.handles(c.action) { i.target = AppCommands.shared }
        if !MenuConditions.isShown(c.condition, in: nil) { i.isHidden = true }
        return i
    }

    /// Disabled items that show a check mark (`EditorMenu.checkedDisabled`).
    static func markCheckedDisabled(in menu: NSMenu, kind: EditorKind) {
        let titles = EditorMenu.checkedDisabled[kind] ?? []
        guard !titles.isEmpty else { return }
        for i in menu.items {
            if let s = i.submenu { markCheckedDisabled(in: s, kind: kind) }
            if titles.contains(i.title), let c = (i as? CommandMenuItem)?.spec, !c.isAvailable { i.state = .on }
        }
    }

    /// Puts back a shortcut the system changed (§1.6: AppKit rebinds the
    /// ⌃⌘F full-screen item to fn-F).
    static func restoreShortcut(_ i: CommandMenuItem) {
        guard let c = i.spec, !c.isAlternate, !c.key.isEmpty else { return }
        let mask = modifierFlags(c.modifiers, key: c.key)
        if i.keyEquivalent != c.key || i.keyEquivalentModifierMask != mask {
            i.keyEquivalent = c.key
            i.keyEquivalentModifierMask = mask
        }
    }

    static func modifierFlags(_ m: MenuCommand.Modifiers, key: String) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if m.contains(.command) { mask.insert(.command) }
        if m.contains(.shift) { mask.insert(.shift) }
        if m.contains(.option) { mask.insert(.option) }
        if m.contains(.control) { mask.insert(.control) }
        // Function keys carry no implicit modifier (an empty mask; AppKit
        // takes .function only on its own items).
        return mask
    }

    /// An item's shortcut in canonical notation ("" for none).
    static func canonicalShortcut(_ i: NSMenuItem) -> String {
        guard !i.keyEquivalent.isEmpty else { return "" }
        let f = i.keyEquivalentModifierMask
        var m: MenuCommand.Modifiers = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        return Shortcut.canonical(key: i.keyEquivalent, modifiers: m)
    }

    /// Every shortcut in the table (§1.6: the system's items give way).
    static let tableShortcuts: Set<String> = Set(CommandTable.allCommands.map(\.canonicalShortcut).filter { !$0.isEmpty })
    /// System items that repeat one of the table's commands under another
    /// action (the table has its own window-tab and full-screen items).
    static let systemDuplicateActions: Set<String> = [
        "toggleFullScreen:", "toggleTabBar:", "toggleTabOverview:", "selectNextTab:", "selectPreviousTab:",
    ]

    /// Removes items the system added to a table menu whose shortcut is
    /// one of the table's, or which repeat one of its commands
    /// (reference-ui-5.md §1.6: "Close All ⌥⇧⌘W", the fn-F full-screen
    /// item, AppKit's window-tab items).
    static func removeSystemConflicts(in menu: NSMenu) {
        for i in menu.items.reversed() where !(i is CommandMenuItem) && !i.isSeparatorItem && !i.isSectionHeader && i.submenu == nil {
            let action = i.action.map(NSStringFromSelector) ?? ""
            if tableShortcuts.contains(canonicalShortcut(i)) || systemDuplicateActions.contains(action) { menu.removeItem(i) }
        }
    }

    /// Shows only the separators that still divide visible items (§1.5).
    static func collapseSeparators(in menu: NSMenu) {
        let items = menu.items
        let shown = MenuConditions.visibleSeparators(isSeparator: items.map(\.isSeparatorItem),
                                                     isVisible: items.map { !$0.isHidden && !$0.isAlternate })
        for (i, item) in items.enumerated() where item.isSeparatorItem { item.isHidden = !shown[i] }
    }
}

/// Fills Editor ▸ Refactor with the code actions last fetched at the caret
/// of the key workspace window (after Rename…), and starts a new fetch.
@MainActor
final class RefactorMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RefactorMenuDelegate()
    static let dynamicTag = 9_917

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.dynamicTag { menu.removeItem(item) }
        guard let wc = NSApp.keyWindow?.windowController as? WorkspaceWindowController else { return }
        Self.fill(menu, with: wc.cachedCodeActions, target: wc)
        Task { await wc.codeActionsAtCaret() }
    }

    static func fill(_ menu: NSMenu, with actions: [CodeAction], target: AnyObject) {
        // Actions already behind a fixed Refactor item (RefactorCatalog) are not repeated.
        let refactors = RefactorCatalog.unmatched(actions).map { ($0, actions[$0]) }
        guard !refactors.isEmpty else { return }
        let sep = NSMenuItem.separator()
        sep.tag = dynamicTag
        menu.addItem(sep)
        for (i, a) in refactors {
            let item = NSMenuItem(title: a.title, action: #selector(WorkspaceWindowController.performCachedCodeAction(_:)), keyEquivalent: "")
            item.tag = dynamicTag
            item.representedObject = i
            item.target = target
            menu.addItem(item)
        }
    }
}

/// Fills File ▸ Open Recent from `RecentProjects` (`reference-ui-5.md`
/// §3.2): the entries newest first, then a separator and Clear Menu.
@MainActor
final class RecentProjectsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentProjectsMenuDelegate()
    static let clearTitle = "Clear Menu"

    func menuNeedsUpdate(_ menu: NSMenu) { Self.fill(menu, with: RecentProjects.shared.urls) }

    static func fill(_ menu: NSMenu, with urls: [URL]) {
        menu.removeAllItems()
        for (url, title) in zip(urls, RecentProjects.menuTitles(urls)) {
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.openRecentProject(_:)), keyEquivalent: "")
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: clearTitle, action: #selector(AppDelegate.clearRecentProjects(_:)), keyEquivalent: ""))
    }
}

/// What launching does (`reference-ui-5.md` §3.1, L1).
public enum LaunchAction: Equatable {
    /// Open these paths.
    case open([String])
    /// No document to open: the Welcome window, never an Open panel.
    case welcome
    /// Documents are already open (state restoration): nothing more.
    case none

    public static func decide(arguments: [String], openDocumentCount: Int) -> LaunchAction {
        let paths = LaunchArguments.documentPaths(arguments)
        if !paths.isEmpty { return .open(paths) }
        return openDocumentCount == 0 ? .welcome : .none
    }
}

/// App delegate: installs the menu bar, opens the workspaces given at
/// launch, and otherwise shows the Welcome window.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The Welcome window, once shown.
    public private(set) var welcome: WelcomeWindowController?

    public override init() {
        _ = YcodeDocumentController() // the first instance becomes shared
        super.init()
    }

    public func applicationWillFinishLaunching(_ n: Notification) {
        MainThreadWatchdog.startIfRequested()
        DeveloperTools.prefetch()
        NSApp.mainMenu = MainMenu.make()
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSApp.mainMenu = MainMenu.make()
                NSApp.appearance = Preferences.shared.nsAppearance
            }
        }
        NSApp.appearance = Preferences.shared.nsAppearance
    }

    public func applicationDidFinishLaunching(_ n: Notification) {
        if case .open(let paths) = LaunchAction.decide(arguments: Array(CommandLine.arguments.dropFirst()), openDocumentCount: 0) {
            for a in paths {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: a), display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
            return
        }
        // After restored windows (if any) have reopened.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if LaunchAction.decide(arguments: [], openDocumentCount: NSDocumentController.shared.documents.count) == .welcome {
                    self.showWelcomeWindow(nil)
                }
            }
        }
    }

    /// Window ▸ Welcome to Ycode (⇧⌘1).
    @discardableResult
    @objc public func showWelcomeWindow(_ sender: Any?) -> WelcomeWindowController {
        let w = welcome ?? WelcomeWindowController()
        welcome = w
        w.present()
        return w
    }

    /// Clicking the Dock icon with no window open shows the Welcome window.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcomeWindow(nil) }
        return true
    }

    /// File ▸ Open Recent ▸ <entry>. The Welcome window stays open.
    @objc public func openRecentProject(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    /// File ▸ Open Recent ▸ Clear Menu: empties the menu and the Welcome list.
    @objc public func clearRecentProjects(_ sender: Any?) {
        RecentProjects.shared.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(clearRecentProjects(_:)) { return !RecentProjects.shared.urls.isEmpty }
        return true
    }

    /// Ycode ▸ Settings… (Command-,).
    @objc public func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

/// Launch arguments: document paths and NSArgumentDomain pairs.
public enum LaunchArguments {
    /// The paths to open. A `-Key value` pair (NSArgumentDomain style,
    /// e.g. `-ApplePersistenceIgnoreState YES`) is skipped as a whole;
    /// `--` ends option parsing.
    public static func documentPaths(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { out += args[(i + 1)...]; break }
            if a.hasPrefix("-") && a.count > 1 {
                // The value, when one follows (not another flag).
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
            } else {
                out.append(a)
            }
            i += 1
        }
        return out
    }
}
