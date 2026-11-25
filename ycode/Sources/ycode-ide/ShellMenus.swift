import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// The menu bar (`specs/ide/menus.md`): the AppKit IDE's menus from the
/// core's `CommandTable` — Ycode, File, Edit, View, Find, Navigate, Editor,
/// Product, Debug, Integrate, Window, Help — with the same items, order,
/// separators, submenus, titles (dynamic ones through `MenuTitles`) and
/// shortcuts. What each item shows and does is `ShellMenuModel`'s (the
/// menu-bar parity test reads the same model). The toolkit keeps its own
/// Undo, Redo and pasteboard items (they act on the focused text), Quit and
/// the window list; alternates (shown while ⌥ is held) are left out.
struct ShellMenus: Commands {
    var app: ShellAppModel

    /// Edit-menu actions the toolkit's own items perform.
    static let toolkitEditActions = ShellMenuModel.toolkitEditActions

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
                if case .command(let c) = $0 { return !ShellMenuModel.toolkitEditActions.contains(c.action) }
                return true
            })
        }
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) { MenuSpecItems(app: app, items: Self.items("View")) }
        CommandMenu("Find") { MenuSpecItems(app: app, items: Self.items("Find")) }
        CommandMenu("Navigate") { MenuSpecItems(app: app, items: Self.items("Navigate")) }
        // The focused editor's own Editor menu (property list, asset catalog;
        // with no editor, the first block, P-006).
        CommandMenu("Editor") { MenuSpecItems(app: app, items: ShellMenuModel.items("Editor", app: app)) }
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Settings ▸ Shortcuts: a changed shortcut rebuilds the items.
        let _ = ShellPreferences.shared.revision
        // The menu context and Integrate's state, once for this menu's items.
        let pass = ShellMenuModel.Pass(app)
        ForEach(Array(ShellMenuModel.shown(items, in: pass).enumerated()), id: \.offset) { pair in
            view(pair.element, pass)
        }
    }

    /// The menu has glyph rows (P-013): every title then starts after the
    /// glyph column, as AppKit lays the menu out.
    var reservesGlyph: Bool { ShellMenuModel.reservesGlyph(items) }

    /// A row's title, after its glyph (OpenViews' own artwork) or an empty
    /// glyph column.
    @ViewBuilder
    func label(_ title: String, symbol: String?) -> some View {
        if reservesGlyph {
            Label {
                Text(title)
            } icon: {
                if let symbol { Image(systemName: symbol).frame(width: Self.glyphWidth) } else { Color.clear.frame(width: Self.glyphWidth, height: 1) }
            }
        } else {
            Text(title)
        }
    }

    /// The glyph column's width (AppKit's menu image size).
    static let glyphWidth: CGFloat = 16

    func view(_ spec: MenuItemSpec, _ pass: ShellMenuModel.Pass) -> AnyView {
        switch spec {
        case .separator:
            return AnyView(Divider())
        case .label(let t):
            return AnyView(Button(t) {}.disabled(true))
        case .submenu(let title, let sub):
            // Product ▸ Destination (P-014): headings, versions, Incompatible (DestinationMenuItems.swift).
            if title == "Destination", let w = app.workspace {
                return AnyView(Menu { DestinationMenuItems(app: app, model: w, items: sub) } label: { label(title, symbol: nil) })
            }
            return AnyView(Menu {
                if title == "Scheme", let w = app.workspace {
                    ForEach(w.schemes, id: \.self) { s in Button(s) { w.scheme = s } }
                    if !w.schemes.isEmpty { Divider() }
                }
                // File ▸ Open Recent: the recent workspaces, newest first
                // (same-named ones with their folder), then Clear Menu.
                if title == "Open Recent" {
                    ForEach(Array(zip(app.recent, RecentProjects.menuTitles(app.recent)).enumerated()), id: \.offset) { pair in
                        Button(pair.element.1) { app.open(path: pair.element.0.path) }
                    }
                    if !app.recent.isEmpty { Divider() }
                }
                MenuSpecItems(app: app, items: ShellMenuModel.submenuItems(title, sub, app: app))
            } label: {
                label(title, symbol: nil)
            }.disabled(sub.isEmpty))
        case .command(let c):
            let title = ShellMenuModel.title(c, in: pass)
            let shortcut = ShellShortcut(command: KeyBindings.effective(c))?.keyboardShortcut
            let enabled = ShellMenuModel.isEnabled(c, in: pass)
            let symbol = ShellMenuModel.symbol(c)
            if let on = ShellMenuModel.checked(c, app: app) {
                return AnyView(Toggle(isOn: Binding(get: { on }, set: { _ in perform(c) })) { label(title, symbol: symbol) }
                    .keyboardShortcut(shortcut)
                    .disabled(!enabled))
            }
            return AnyView(Button { perform(c) } label: { label(title, symbol: symbol) }
                .keyboardShortcut(shortcut)
                .disabled(!enabled))
        }
    }

    /// The view layer's own actions (`ShellAppModel.viewLayerActions`),
    /// else the model's.
    func perform(_ c: MenuCommand) {
        switch c.action {
        case "showSettings:": openSettings()
        case "chooseTheme:":
            ShellSettingsModel.shared.select(.appearance)
            openSettings()
        case "showBehaviorsSettings:":
            ShellSettingsModel.shared.select(.behaviors)
            openSettings()
        default: ShellMenuModel.perform(c, app: app)
        }
    }
}
