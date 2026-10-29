import AppKit
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
            guard let c = item as? CommandMenuItem, let spec = c.spec else { continue }
            c.title = MenuTitles.title(for: spec, in: ctx)
            c.isHidden = !MenuConditions.isShown(spec.condition, in: ctx)
            MainMenu.restoreShortcut(c)
        }
        if menu.supermenu === NSApp?.mainMenu, NSApp?.mainMenu != nil { MainMenu.removeSystemConflicts(in: menu) }
        MainMenu.collapseSeparators(in: menu)
    }
}

extension MenuBarDelegate {
    /// System items Ycode leaves out (`reference-ui-6.md` §8 items 1–2):
    /// a second Open Recent in File, the feedback item in Help.
    func removeSystemAdditions(_ menu: NSMenu) {
        switch (menu as? CommandMenu)?.path {
        case "File": MainMenu.removeSystemRecentMenus(in: menu)
        case "Help": MainMenu.removeSystemFeedbackItem(in: menu)
        default: break
        }
    }
}

/// Menus filled from state when they are shown.
@MainActor
enum DynamicMenus {
    static func fill(_ m: CommandMenu, controller wc: WorkspaceWindowController?) {
        switch m.path {
        case "Ycode ▸ Open Developer Tool": fillDeveloperTools(m, tools: DeveloperTools.installed)
        case "View ▸ Inspectors": fillInspectors(m, names: wc?.inspector.tabNames ?? CommandTable.inspectors)
        case "Product ▸ Scheme": fillSchemes(m, names: wc?.session.model.schemeNames ?? [], active: wc?.session.scheme, target: wc)
        case "Product ▸ Destination":
            guard let wc else { removeDynamic(m); break }
            fillDestinations(m, model: wc.destinationMenuModel(), current: wc.session.destination, target: wc)
        case "Product ▸ Test Plan":
            guard let wc else { removeDynamic(m); break }
            fillTestPlans(m, rows: wc.session.testPlanRows, plans: wc.session.testPlanNames, active: wc.session.effectiveTestPlan, target: wc)
        case "Editor": fillEditor(m, kind: wc?.menuContext.editorKind ?? .source)
        case "Debug ▸ Attach to Process": RunningProcesses.fill(m, target: wc, entries: RunningProcesses.recent())
        default: break
        }
    }

    /// §2.7 / §2.8: the Editor menu of the focused editor's kind, rebuilt
    /// when the kind changes.
    static func fillEditor(_ m: CommandMenu, kind: EditorKind) {
        guard m.editorKind != kind else { return }
        let fresh = MainMenu.menu("Editor", EditorMenu.items(for: kind), path: "Editor")
        m.removeAllItems()
        for i in fresh.items {
            fresh.removeItem(i)
            m.addItem(i)
        }
        m.editorKind = kind
        MainMenu.markCheckedDisabled(in: m, kind: kind)
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

/// The developer tools in the active developer directory (§2.1 item 7).
public enum DeveloperTools {
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var url: URL
    }

    /// The order the reference lists them in; a missing tool is left out.
    public static let order = ["Instruments", "Device Hub", "Icon Composer", "Accessibility Inspector", "FileMerge", "Create ML"]

    /// Tools under `<developer dir>/Applications`.
    public static func tools(inDeveloperDirectory dir: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Tool] {
        order.compactMap { name in
            let url = dir.appendingPathComponent("Applications").appendingPathComponent(name + ".app")
            return exists(url.path) ? Tool(name: name, url: url) : nil
        }
    }

    /// `DEVELOPER_DIR`, else `xcode-select -p`.
    public static func activeDeveloperDirectory() -> URL? {
        if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        MainThreadGuard.blockingCall("xcode-select -p")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? URL(fileURLWithPath: s) : nil
    }

    /// Looked up once per launch, in the background (`prefetch()`, at
    /// launch); empty until then.
    @MainActor public static var installed: [Tool] {
        if let cached { return cached }
        prefetch()
        return []
    }

    @MainActor private static var cached: [Tool]?

    nonisolated static func lookUp() -> [Tool] { activeDeveloperDirectory().map { tools(inDeveloperDirectory: $0) } ?? [] }

    /// Starts the lookup off the main thread (`xcode-select -p`).
    @MainActor public static func prefetch() {
        guard cached == nil, !fetching else { return }
        fetching = true
        Task {
            let list = await Task.detached { lookUp() }.value
            cached = list
            fetching = false
        }
    }

    @MainActor private static var fetching = false
}
