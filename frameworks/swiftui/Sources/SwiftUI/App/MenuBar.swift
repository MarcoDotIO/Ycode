import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The menu bar (round R11). Linux desktops have no global menu bar, so every
// main window draws its own, in the window, above the toolbar (Ycode's
// choice; exporting through the D-Bus menu protocol is left for later).
//
// Menus, in order: the application menu (titled with the app's name), File,
// Edit, View, the app's `CommandMenu`s (after View, as the public
// documentation places them), Window, Help. Each standard menu is a list of
// standard groups (`CommandGroupPlacement`); a group shows its default items,
// or a `CommandGroup(replacing:)`'s items, with `CommandGroup(before:)` and
// `(after:)` items around them; non-empty groups are separated by a
// separator. Menus with no items are not shown.
//
// Default items (Ycode's, with the Linux shortcuts): About <App>; Settings…
// (Ctrl+, — when the app has a `Settings` scene); Quit <App> (Ctrl+Q); New
// Window (Ctrl+N — when the app has a `WindowGroup`); Close Window (Ctrl+W);
// Undo (Ctrl+Z), Redo (Ctrl+Shift+Z), Cut (Ctrl+X), Copy (Ctrl+C), Paste
// (Ctrl+V), Select All (Ctrl+A) — acting on the focused text view; Show/Hide
// Toolbar (when the window has a toolbar), Show/Hide Sidebar (Ctrl+Alt+S,
// with `SidebarCommands`); Minimize (Ctrl+M), the open windows, the app's
// single `Window` scenes; <App> Help (disabled: no help book).
//
// Interaction: a press on a title opens its menu (a pop-up window, R8); while
// a menu is open, moving the pointer over another title opens that one; Left
// and Right move between menus, Up and Down between items, Escape closes; F10
// opens the first menu. Items run on release, as in R8's menus.

// MARK: - What the host offers the standard items

/// Actions of the application host for the standard menu items of one window.
@MainActor
package final class AppCommandActions {
    package typealias Action = @MainActor @Sendable () -> Void
    package var appName = "OpenViews"
    package var quit: Action = {}
    package var newWindow: Action?
    package var closeWindow: Action = {}
    package var openSettings: Action?
    package var minimize: Action = {}
    package var about: Action = {}
    /// Open main windows: title, whether it is this window, activation.
    package var windows: @MainActor () -> [(title: String, isCurrent: Bool, activate: Action)] = { [] }
    /// The app's single-window scenes (`Window`): title and opener.
    package var singleWindows: [(title: String, open: Action)] = []
    package init() {}
}

private enum AppCommandsKey: EnvironmentKey { static let defaultValue: AppCommandActions? = nil }
private enum PopupOwnerServicesKey: EnvironmentKey { static let defaultValue: WindowServices? = nil }

extension EnvironmentValues {
    package var _appCommands: AppCommandActions? {
        get { self[AppCommandsKey.self] }
        set { self[AppCommandsKey.self] = newValue }
    }

    /// In a pop-up: the services of the window that presented it (Edit menu
    /// items act on that window's focused text view).
    package var _popupOwnerServices: WindowServices? {
        get { self[PopupOwnerServicesKey.self] }
        set { self[PopupOwnerServicesKey.self] = newValue }
    }
}

// MARK: - Shortcut text

extension KeyboardShortcut {
    /// The shortcut as a Linux menu shows it: "Ctrl+Shift+Z" (`.command` is
    /// Ctrl, 09-open-design.md §4.1).
    package var displayText: String {
        var parts: [String] = []
        let ctrl = modifiers.contains(.command) || modifiers.contains(.control)
        if modifiers.contains(.command) && modifiers.contains(.control) { parts.append("Super") }
        if ctrl { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        let k: String
        switch key {
        case .return: k = "Enter"
        case .escape: k = "Esc"
        case .delete: k = "Backspace"
        case .deleteForward: k = "Delete"
        case .tab: k = "Tab"
        case .space: k = "Space"
        case .upArrow: k = "Up"
        case .downArrow: k = "Down"
        case .leftArrow: k = "Left"
        case .rightArrow: k = "Right"
        case .home: k = "Home"
        case .end: k = "End"
        case .pageUp: k = "Page Up"
        case .pageDown: k = "Page Down"
        default: k = String(key.character).uppercased()
        }
        parts.append(k)
        return parts.joined(separator: "+")
    }
}

// MARK: - Standard items

/// Edit actions on the focused text view (R8's editing core).
package enum StandardEditCommand: String, CaseIterable, Sendable {
    case undo, redo, cut, copy, paste, delete, selectAll

    var title: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .delete: return "Delete"
        case .selectAll: return "Select All"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .undo: return KeyboardShortcut("z")
        case .redo: return KeyboardShortcut("z", modifiers: [.command, .shift])
        case .cut: return KeyboardShortcut("x")
        case .copy: return KeyboardShortcut("c")
        case .paste: return KeyboardShortcut("v")
        case .delete: return nil
        case .selectAll: return KeyboardShortcut("a")
        }
    }
}

/// An Edit menu item: enabled when the focused text view can perform it. In
/// the commands host it draws nothing (text views take these keys
/// themselves, R8).
struct EditCommandItem: View {
    let command: StandardEditCommand
    @Environment(\._inCommandHost) private var hidden
    @Environment(\._windowServices) private var services
    @Environment(\._popupOwnerServices) private var ownerServices

    var body: some View {
        if !hidden {
            let target = ownerServices ?? services
            let client = target?.focus.focusedClient
            let enabled = client?.canPerform(command, clipboard: target?.clipboard) ?? false
            Button(command.title) { target?.focus.focusedClient?.perform(command, clipboard: target?.clipboard) }
                .keyboardShortcut(command.shortcut)
                .disabled(!enabled)
        }
    }
}

/// A standard item that runs a host action.
struct StandardItem: View {
    let title: String
    let shortcut: KeyboardShortcut?
    var enabled = true
    let action: AppCommandActions.Action

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(shortcut)
            .disabled(!enabled)
    }
}

/// Show/Hide Toolbar.
struct ToolbarToggleItem: View {
    @Environment(\._windowServices) private var services
    @Environment(\._popupOwnerServices) private var ownerServices
    var body: some View {
        let target = ownerServices ?? services
        if let toolbar = target?.toolbar, toolbar.hasItems {
            Button(toolbar.isVisible ? "Hide Toolbar" : "Show Toolbar") { toolbar.isVisible.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}

/// Show/Hide Sidebar (with `SidebarCommands`).
struct SidebarToggleItem: View {
    @Environment(\._windowServices) private var services
    @Environment(\._popupOwnerServices) private var ownerServices
    var body: some View {
        let target = ownerServices ?? services
        let sidebar = target?.sidebar
        Button(sidebar?.isVisible == false ? "Show Sidebar" : "Hide Sidebar") { sidebar?.toggle() }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(sidebar == nil)
    }
}

/// The open windows (Window menu).
struct WindowListItems: View {
    let actions: AppCommandActions
    @Environment(\._inCommandHost) private var hidden
    var body: some View {
        if !hidden {
            let list = actions.windows()
            ForEach(Array(list.enumerated()), id: \.offset) { pair in
                let w = pair.element
                Toggle(w.title.isEmpty ? "Window \(pair.offset + 1)" : w.title,
                       isOn: Binding(get: { w.isCurrent }, set: { _ in w.activate() }))
            }
        }
    }
}

// MARK: - Assembly

/// One menu of the bar.
package struct MenuBarMenu {
    package let title: String
    package let sections: [AnyView]
}

@MainActor
enum MenuAssembly {
    struct Placed {
        var before: [AnyView] = []
        var replacing: [AnyView]?
        var after: [AnyView] = []
    }

    /// The standard menus and their groups.
    static func standardMenus(appName: String) -> [(title: String, groups: [CommandGroupPlacement])] {
        [
            (appName, [.appInfo, .appSettings, .systemServices, .appVisibility, .appTermination]),
            ("File", [.newItem, .saveItem, .importExport, .printItem]),
            ("Edit", [.undoRedo, .pasteboard, .textEditing, .textFormatting]),
            ("View", [.toolbar, .sidebar]),
            ("Window", [.windowSize, .windowArrangement, .windowList, .singleWindowList]),
            ("Help", [.help]),
        ]
    }

    /// The default items of a group.
    static func defaults(_ g: CommandGroupPlacement, actions: AppCommandActions, standard: Set<String>) -> [AnyView] {
        switch g {
        case .appInfo:
            return [AnyView(StandardItem(title: "About \(actions.appName)", shortcut: nil, action: actions.about))]
        case .appSettings:
            guard let open = actions.openSettings else { return [] }
            return [AnyView(StandardItem(title: "Settings…", shortcut: KeyboardShortcut(","), action: open))]
        case .appTermination:
            return [AnyView(StandardItem(title: "Quit \(actions.appName)", shortcut: KeyboardShortcut("q"), action: actions.quit))]
        case .newItem:
            var items: [AnyView] = []
            if let n = actions.newWindow {
                items.append(AnyView(StandardItem(title: "New Window", shortcut: KeyboardShortcut("n"), action: n)))
            }
            items.append(AnyView(StandardItem(title: "Close Window", shortcut: KeyboardShortcut("w"), action: actions.closeWindow)))
            return items
        case .undoRedo:
            return [AnyView(EditCommandItem(command: .undo)), AnyView(EditCommandItem(command: .redo))]
        case .pasteboard:
            return [StandardEditCommand.cut, .copy, .paste, .delete, .selectAll].map { AnyView(EditCommandItem(command: $0)) }
        case .toolbar:
            return [AnyView(ToolbarToggleItem())]
        case .sidebar:
            return standard.contains("sidebar") ? [AnyView(SidebarToggleItem())] : []
        case .windowSize:
            return [AnyView(StandardItem(title: "Minimize", shortcut: KeyboardShortcut("m"), action: actions.minimize))]
        case .windowList:
            return [AnyView(WindowListItems(actions: actions))]
        case .singleWindowList:
            return actions.singleWindows.map { w in AnyView(StandardItem(title: w.title, shortcut: nil, action: w.open)) }
        case .help:
            return [AnyView(StandardItem(title: "\(actions.appName) Help", shortcut: nil, enabled: false, action: {}))]
        default:
            return []
        }
    }

    /// The default items of the groups no `CommandGroup(replacing:)`
    /// replaces (built in the commands host so their shortcuts work while
    /// the menus are closed).
    static func hostDefaults(_ contributions: [CommandContribution], actions: AppCommandActions) -> [AnyView] {
        var replaced = Set<CommandGroupPlacement>()
        var standard = Set<String>()
        for c in contributions {
            if case .group(let p, .replacing, _) = c { replaced.insert(p) }
            if case .standard(let name) = c { standard.insert(name) }
        }
        return standardMenus(appName: actions.appName).flatMap(\.groups).filter { !replaced.contains($0) }
            .flatMap { defaults($0, actions: actions, standard: standard) }
    }

    /// The menus from the evaluated contributions.
    static func menus(_ contributions: [CommandContribution], actions: AppCommandActions) -> [MenuBarMenu] {
        var placed: [CommandGroupPlacement: Placed] = [:]
        var custom: [(title: String, items: [AnyView])] = []
        var standard = Set<String>()
        for c in contributions {
            switch c {
            case .menu(let title, let content):
                if let i = custom.firstIndex(where: { $0.title == title }) {
                    custom[i].items.append(content)
                } else {
                    custom.append((title, [content]))
                }
            case .group(let placement, let position, let content):
                var p = placed[placement] ?? Placed()
                switch position {
                case .before: p.before.append(content)
                case .after: p.after.append(content)
                case .replacing: p.replacing = (p.replacing ?? []) + [content]
                }
                placed[placement] = p
            case .standard(let name):
                standard.insert(name)
            case .removeDefaults:
                break
            }
        }
        var out: [MenuBarMenu] = []
        for (index, menu) in standardMenus(appName: actions.appName).enumerated() {
            var sections: [AnyView] = []
            for g in menu.groups {
                let p = placed[g] ?? Placed()
                let items = p.before + (p.replacing ?? defaults(g, actions: actions, standard: standard)) + p.after
                if !items.isEmpty { sections.append(AnyView(MenuSectionView(items: items))) }
            }
            // Custom menus with a standard title join that menu.
            if let i = custom.firstIndex(where: { $0.title == menu.title }) {
                sections.append(AnyView(MenuSectionView(items: custom[i].items)))
                custom.remove(at: i)
            }
            if !sections.isEmpty { out.append(MenuBarMenu(title: menu.title, sections: sections)) }
            if index == 3 {
                // After View: the app's own menus.
                for m in custom where !standardMenus(appName: actions.appName).contains(where: { $0.title == m.title }) {
                    out.append(MenuBarMenu(title: m.title, sections: [AnyView(MenuSectionView(items: m.items))]))
                }
                custom.removeAll { m in !standardMenus(appName: actions.appName).contains { $0.title == m.title } }
            }
        }
        return out
    }
}

/// The items of one group.
struct MenuSectionView: View {
    let items: [AnyView]
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { $0.element }
    }
}

/// The items of an open menu: its groups with separators between them.
struct MenuContentView: View {
    let sections: [AnyView]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = ControlPalette(scheme)
        ForEach(Array(sections.enumerated()), id: \.offset) { pair in
            if pair.offset > 0 {
                Rectangle().fill(palette.separator).frame(height: 1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
            }
            pair.element
        }
    }
}

// MARK: - The bar

/// The menu bar's state: which menu is open.
@MainActor
@Observable
package final class MenuBarController {
    package private(set) var openIndex: Int?
    @ObservationIgnored var refs: [NodeRef] = []
    @ObservationIgnored var menus: [MenuBarMenu] = []
    @ObservationIgnored weak var services: WindowServices?
    @ObservationIgnored private var handle: PopupHandle?

    package init() {}

    package var menuTitles: [String] { menus.map(\.title) }

    package func open(_ i: Int) {
        guard menus.indices.contains(i), i < refs.count, let popups = services?.popups,
              let frame = refs[i].windowFrame else { return }
        handle?.dismiss()
        let menu = menus[i]
        openIndex = i
        weak var me = self
        let h = popups.presentPopup(content: AnyView(MenuContentView(sections: menu.sections)),
                                    origin: CGPoint(x: frame.minX, y: frame.maxY), minWidth: 180, chrome: .menu,
                                    fallbackKeys: { k in
                                        guard let me, k.isDown else { return false }
                                        switch k.key {
                                        case .leftArrow: me.step(-1)
                                        case .rightArrow: me.step(1)
                                        default: return false
                                        }
                                        return true
                                    },
                                    onDismiss: {
                                        guard let me else { return }
                                        if me.openIndex == i { me.openIndex = nil }
                                    })
        handle = h
        if h == nil { openIndex = nil }
    }

    package func close() {
        handle?.dismiss()
        handle = nil
        openIndex = nil
    }

    package func toggle(_ i: Int) {
        if openIndex == i { close() } else { open(i) }
    }

    func step(_ d: Int) {
        guard let i = openIndex, !menus.isEmpty else { return }
        open((i + d + menus.count) % menus.count)
    }

    /// F10: the first menu.
    package func openFirst() { open(0) }
}

/// The menu bar view at the top of a window.
struct MenuBarView: View {
    let model: CommandsModel
    let actions: AppCommandActions
    @Environment(\._windowServices) private var services
    @Environment(\.colorScheme) private var scheme
    @State private var controller = MenuBarController()

    var body: some View {
        _ = model.revision
        let menus = MenuAssembly.menus(model.ordered, actions: actions)
        let c = controller
        c.menus = menus
        c.services = services
        while c.refs.count < menus.count { c.refs.append(NodeRef()) }
        services?.menuBar = c
        let palette = ControlPalette(scheme)
        return HStack(spacing: 0) {
            ForEach(Array(menus.enumerated()), id: \.offset) { pair in
                MenuBarTitle(title: pair.element.title, index: pair.offset, isAppMenu: pair.offset == 0, controller: c)
                    .modifier(NodeCaptureModifier(ref: c.refs[pair.offset]))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: MenuBarMetrics.height)
        .background(palette.barBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1 / 3).allowsHitTesting(false) }
        .accessibilityControl(.menuBar, children: .contain)
    }
}

enum MenuBarMetrics {
    static let height: CGFloat = 26
}

struct MenuBarTitle: View {
    let title: String
    let index: Int
    let isAppMenu: Bool
    let controller: MenuBarController
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let palette = ControlPalette(scheme)
        let open = controller.openIndex == index
        Text(title)
            .font(isAppMenu ? .subheadline.weight(.semibold) : .subheadline)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: MenuBarMetrics.height - 4)
            .background {
                if open || hovered { RoundedRectangle(cornerRadius: 4).fill(open ? palette.fill : palette.menuHighlight) }
            }
            .contentShape(Rectangle())
            .onHover { h in
                hovered = h
                if h, let o = controller.openIndex, o != index { controller.open(index) }
            }
            .gesture(ControlPressGesture(onPressed: { p in if p { controller.toggle(index) } }, onAction: {}))
            .accessibilityControl(.menuBarItem, label: title, actions: ["default": { [controller, index] in controller.toggle(index) }])
    }
}

/// The standard items in the commands host (no layout; shortcuts only).
struct StandardCommandsHost: View {
    let model: CommandsModel
    let actions: AppCommandActions
    var body: some View {
        _ = model.revision
        let items = MenuAssembly.hostDefaults(model.ordered, actions: actions)
        return ForEach(Array(items.enumerated()), id: \.offset) { $0.element }
            .environment(\._inCommandHost, true)
    }
}
