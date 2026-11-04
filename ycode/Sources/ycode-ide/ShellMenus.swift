import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// The menu bar (`specs/ide/menus.md`): the AppKit IDE's menus from the
/// core's `CommandTable` — Ycode, File, Edit, View, Find, Navigate, Editor,
/// Product, Debug, Integrate, Window, Help — with the same items, order,
/// separators, submenus, titles (dynamic ones through `MenuTitles`) and
/// shortcuts. The commands the shell performs (`ShellCommand`) are
/// enabled; the others are listed disabled, as the AppKit IDE lists the
/// commands it does not perform yet. The toolkit keeps its own Undo, Redo
/// and pasteboard items (they act on the focused text), Quit and the window
/// list; alternates (shown while ⌥ is held) and conditional items are left
/// out.
struct ShellMenus: Commands {
    var app: ShellAppModel

    /// Edit-menu actions the toolkit's own items perform.
    static let toolkitEditActions: Set<String> = ["undo:", "redo:", "cut:", "copy:", "paste:", "delete:", "selectAll:"]

    static func items(_ menu: String) -> [MenuItemSpec] {
        CommandTable.menus.first { $0.0 == menu }?.1 ?? []
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            MenuSpecItems(app: app, items: Self.items("Ycode").filter { if case .command(let c) = $0 { return c.action != "terminate:" }; return true })
        }
        CommandGroup(replacing: .appVisibility) {}
        CommandGroup(replacing: .newItem) { MenuSpecItems(app: app, items: Self.items("File")) }
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .textEditing) {
            MenuSpecItems(app: app, items: Self.items("Edit").filter {
                if case .command(let c) = $0 { return !Self.toolkitEditActions.contains(c.action) }
                return true
            }, trimSeparators: true)
        }
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) { MenuSpecItems(app: app, items: Self.items("View")) }
        CommandMenu("Find") { MenuSpecItems(app: app, items: Self.items("Find")) }
        CommandMenu("Navigate") { MenuSpecItems(app: app, items: Self.items("Navigate")) }
        CommandMenu("Editor") { MenuSpecItems(app: app, items: Self.items("Editor")) }
        CommandMenu("Product") { MenuSpecItems(app: app, items: Self.items("Product")) }
        CommandMenu("Debug") { MenuSpecItems(app: app, items: Self.items("Debug")) }
        CommandMenu("Integrate") { MenuSpecItems(app: app, items: Self.items("Integrate")) }
        CommandGroup(replacing: .windowSize) { MenuSpecItems(app: app, items: Self.items("Window")) }
        CommandGroup(replacing: .help) { MenuSpecItems(app: app, items: Self.items("Help")) }
    }
}

/// Menu items from the core's table (recursively for submenus).
struct MenuSpecItems: View {
    var app: ShellAppModel
    var items: [MenuItemSpec]
    var trimSeparators = false

    var body: some View {
        ForEach(Array(shown.enumerated()), id: \.offset) { pair in
            view(pair.element)
        }
    }

    /// The items shown: no alternates, no conditional items, no doubled,
    /// leading or trailing separators.
    var shown: [MenuItemSpec] {
        var out: [MenuItemSpec] = []
        for i in items {
            switch i {
            // Conditional items are left out, except the ones this shell
            // performs (Jump to Line… is "when a source editor is open").
            case .command(let c) where c.isAlternate
                || (c.condition != nil && !ShellCommand.allCases.contains { $0.action == (c.action, c.tag) }): continue
            case .separator:
                if out.isEmpty || out.last == .separator { continue }
                out.append(i)
            default: out.append(i)
            }
        }
        while out.last == .separator { out.removeLast() }
        return out
    }

    func view(_ spec: MenuItemSpec) -> AnyView {
        switch spec {
        case .separator:
            return AnyView(Divider())
        case .label(let t):
            return AnyView(Button(t) {}.disabled(true))
        case .submenu(let title, let sub):
            return AnyView(Menu(title) {
                if title == "Scheme", let w = app.workspace {
                    ForEach(w.schemes, id: \.self) { s in Button(s) { w.scheme = s } }
                    if !w.schemes.isEmpty { Divider() }
                }
                if title == "Destination", let w = app.workspace {
                    ForEach(w.destinations, id: \.specifier) { d in Button(d.name) { w.destination = d } }
                    if !w.destinations.isEmpty { Divider() }
                }
                MenuSpecItems(app: app, items: sub)
            })
        case .command(let c):
            let shell = ShellCommand.allCases.first { $0.action == (c.action, c.tag) }
            let title = shell.map { app.title($0) } ?? MenuTitles.title(for: c, in: app.workspace?.menuContext)
            let shortcut = ShellShortcut(command: c)?.keyboardShortcut
            return AnyView(Button(title) { if let shell { app.perform(shell) } }
                .keyboardShortcut(shortcut)
                .disabled(shell.map { !app.isEnabled($0) } ?? true))
        }
    }
}
