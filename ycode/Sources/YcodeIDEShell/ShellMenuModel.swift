import Foundation
import YcodeIDECore

/// One row of the Linux shell's menu bar as `ShellMenus` draws it: what
/// the menu-bar parity test compares with the AppKit IDE's menus, item by
/// item (`ParityMenuTableTests`).
public struct ShellMenuRow: Equatable, Sendable, CustomStringConvertible {
    /// "File ▸ New", the menu the row is in.
    public var path: String
    public var title: String
    /// Menu notation, ⇧ spelled as a modifier ("⇧⌘K"); empty for none.
    public var shortcut: String
    public var isSubmenu: Bool
    public var isEnabled: Bool
    public var isChecked: Bool
    /// The `CommandTable` action and tag ("" for submenus and labels).
    public var action: String
    public var tag: Int
    /// The glyph drawn before the title (P-013), an OpenViews symbol name.
    public var symbol: String?

    public var description: String {
        "\(path) | \(title)\(isSubmenu ? " ▸" : "") | \(shortcut) | \(isEnabled ? "enabled" : "disabled")\(isChecked ? " ✓" : "")"
    }
}

/// What the Linux shell's menu bar shows and does, from the core's
/// `CommandTable` (`specs/ide/menus.md`): which items are listed, their
/// titles in context, shortcuts, enablement and check marks, and what each
/// performs. `ShellMenus` (the view) draws these; the tests read them.
///
/// An item is performed by its `ShellCommand` when it has one, else by the
/// structured editors' actions (`performEditorAction`), else by the menu
/// actions of `ShellAppModel+MenuActions.swift`; with none it is listed
/// disabled, as the AppKit IDE lists the commands it does not perform yet.
/// Alternates (shown while a modifier is held) are left out until the
/// toolkit can show them (L-048).
@MainActor
public enum ShellMenuModel {
    /// One evaluation of the menu bar: what every item's title, condition
    /// and enabled state read from shared state — the menu context and
    /// Integrate's state (`SourceControlShellModel.menuState`, which reads
    /// the change list and the disk) — built once and shared by the items
    /// instead of once per item (about 500 per model change). Make one per
    /// view body (`MenuSpecItems`) so what it reads is tracked there.
    @MainActor
    public final class Pass {
        public let app: ShellAppModel
        public init(_ app: ShellAppModel) { self.app = app }
        /// The workspace's menu context; nil with only Welcome open.
        public private(set) lazy var context: MenuContext? = app.workspace?.menuContext
        /// Integrate's state and whether a source-control operation runs.
        private lazy var integrate: (state: IntegrateMenuState, busy: Bool)? =
            app.workspace.map { ($0.sourceControl.menuState, $0.sourceControl.busy != nil) }

        /// `SourceControlShellModel.isEnabled(_:)` from the shared state.
        func sourceControlEnabled(_ selector: String) -> Bool {
            guard let i = integrate else { return false }
            if i.busy, selector != "refreshFileStatus:" { return false }
            if selector == "scmDiscardSelected:" { return i.state.selectedStatus != nil }
            return i.state.isEnabled(selector)
        }
    }

    /// Edit-menu actions the toolkit's own items perform.
    public static let toolkitEditActions: Set<String> = ["undo:", "redo:", "cut:", "copy:", "paste:", "delete:", "selectAll:"]

    /// The Editor menu's kind: with no editor open, the first block only
    /// ("Preview", P-006), as for editors without their own items.
    public static func editorKind(_ app: ShellAppModel) -> EditorKind {
        guard let w = app.workspace, w.document != nil || w.structuredEditor != nil else { return .other }
        return w.editorKind
    }

    /// A top-level menu's items (the Editor menu of the focused editor's kind).
    public static func items(_ menu: String, app: ShellAppModel) -> [MenuItemSpec] {
        // With only Welcome open, Welcome's Editor menu (P-006, as macOS).
        if menu == "Editor" { return app.workspace == nil ? EditorMenu.welcomeItems : EditorMenu.items(for: editorKind(app)) }
        return CommandTable.menus.first { $0.0 == menu }?.1 ?? []
    }

    /// The items shown: no alternates, conditional items only while their
    /// condition holds (as on macOS), no doubled, leading or trailing
    /// separators.
    public static func shown(_ items: [MenuItemSpec], app: ShellAppModel) -> [MenuItemSpec] { shown(items, in: Pass(app)) }

    public static func shown(_ items: [MenuItemSpec], in pass: Pass) -> [MenuItemSpec] {
        let ctx = pass.context
        var out: [MenuItemSpec] = []
        for i in items {
            switch i {
            case .command(let c) where c.isAlternate || !MenuConditions.isShown(c.condition, in: ctx): continue
            case .separator:
                if out.isEmpty || out.last == .separator { continue }
                out.append(i)
            default: out.append(i)
            }
        }
        while out.last == .separator { out.removeLast() }
        return out
    }

    /// The shell command that performs a table command, if any.
    public static func command(for c: MenuCommand) -> ShellCommand? { commandsByAction["\(c.action)#\(c.tag)"] }

    /// The shell commands by their table action and tag (the first of each).
    static let commandsByAction: [String: ShellCommand] = {
        var d: [String: ShellCommand] = [:]
        for s in ShellCommand.allCases {
            let (a, t) = s.action
            if d["\(a)#\(t)"] == nil { d["\(a)#\(t)"] = s }
        }
        return d
    }()

    /// The title in context (the item's own generic title: an action can
    /// be listed under two titles, "Canvas" and "Preview").
    public static func title(_ c: MenuCommand, app: ShellAppModel) -> String { title(c, in: Pass(app)) }

    public static func title(_ c: MenuCommand, in pass: Pass) -> String {
        // The workspace window always shows its toolbar on Linux.
        if c.action == "toggleToolbarShown:", pass.app.workspace != nil { return "Hide Toolbar" }
        return MenuTitles.title(for: c, in: pass.context)
    }

    /// A submenu's items as listed: View ▸ Inspectors has no inspectors
    /// with only Welcome open (Show Inspector alone); a workspace lists File,
    /// History and Quick Help even with no file open (P-006, council round
    /// 11, B02, as macOS).
    public static func submenuItems(_ title: String, _ items: [MenuItemSpec], app: ShellAppModel) -> [MenuItemSpec] {
        guard title == "Inspectors", app.workspace == nil else { return items }
        return items.filter { if case .command(let c) = $0 { return c.action != "showInspector:" }; return true }
    }

    /// Whether the item can be chosen now.
    public static func isEnabled(_ c: MenuCommand, app: ShellAppModel) -> Bool { isEnabled(c, in: Pass(app)) }

    public static func isEnabled(_ c: MenuCommand, in pass: Pass) -> Bool {
        let app = pass.app
        if let shell = command(for: c) {
            // Integrate's items from the pass's one source-control state.
            if shell.isSourceControl, app.workspace != nil { return pass.sourceControlEnabled(shell.action.selector) }
            return app.isEnabled(shell)
        }
        // The project navigator's commands (B5-NAVIGATOR, P-041, P-052).
        if let on = app.workspace?.validateProjectNavigatorAction(c.action) { return on }
        if let s = app.workspace?.editorActionState(c.action, tag: c.tag) { return s.enabled }
        if let s = app.menuActionState(c.action, tag: c.tag) { return s.enabled }
        return false
    }

    /// The check mark; nil for an item that is not a toggle.
    public static func checked(_ c: MenuCommand, app: ShellAppModel) -> Bool? {
        // With no workspace "Preview" is unchecked (P-006, council round 11, as macOS).
        if app.workspace == nil, c.action == "toggleCanvas:" { return false }
        if let shell = command(for: c) { return app.isChecked(shell) }
        if ["toggleRawKeysAndValues:", "setPlistValueType:"].contains(c.action),
           let s = app.workspace?.editorActionState(c.action, tag: c.tag) { return s.checked }
        guard ShellAppModel.toggleActions.contains(c.action) else { return nil }
        return app.menuActionState(c.action, tag: c.tag)?.checked
    }

    /// Chooses the item.
    public static func perform(_ c: MenuCommand, app: ShellAppModel) {
        if app.workspace?.performProjectNavigatorAction(c.action) == true { return }
        if let shell = command(for: c) { app.perform(shell); return }
        if app.workspace?.editorActionState(c.action, tag: c.tag) != nil {
            app.workspace?.performEditorAction(c.action, tag: c.tag)
            return
        }
        app.performMenuAction(c.action, tag: c.tag)
    }

    /// The glyph drawn before an item's title (P-013: Product's Run, Test,
    /// Profile, Analyze, Archive and Stop, Debug's steps), as on macOS.
    public static func symbol(_ c: MenuCommand) -> String? { MenuIcons.symbol(for: c) }

    /// Whether a menu's rows leave room for a glyph before their titles
    /// (some row has one), so every title starts at one place as AppKit
    /// draws it.
    public static func reservesGlyph(_ items: [MenuItemSpec]) -> Bool {
        items.contains { if case .command(let c) = $0 { return symbol(c) != nil }; return false }
    }

    /// The shortcut in menu notation (Settings ▸ Key Bindings applied).
    public static func shortcut(_ c: MenuCommand) -> String {
        ShellShortcut(command: KeyBindings.effective(c))?.text ?? ""
    }

    /// Every row of the menu bar, depth first, as `ShellMenus` lists it.
    /// The toolkit's own Edit items and Quit are left out (it draws its own).
    public static func rows(_ app: ShellAppModel) -> [ShellMenuRow] {
        var out: [ShellMenuRow] = []
        let pass = Pass(app)
        func walk(_ items: [MenuItemSpec], _ path: String) {
            for i in shown(items, in: pass) {
                switch i {
                case .separator: break
                case .label(let t):
                    out.append(ShellMenuRow(path: path, title: t, shortcut: "", isSubmenu: false, isEnabled: false, isChecked: false, action: "", tag: 0))
                case .submenu(let t, let sub):
                    out.append(ShellMenuRow(path: path, title: t, shortcut: "", isSubmenu: true, isEnabled: !sub.isEmpty,
                                            isChecked: false, action: "", tag: 0))
                    walk(submenuItems(t, sub, app: app), path + " ▸ " + t)
                case .command(let c):
                    if path == "Edit" && toolkitEditActions.contains(c.action) { continue }
                    out.append(ShellMenuRow(path: path, title: title(c, in: pass), shortcut: shortcut(c), isSubmenu: false,
                                            isEnabled: isEnabled(c, in: pass), isChecked: checked(c, app: app) ?? false,
                                            action: c.action, tag: c.tag, symbol: symbol(c)))
                }
            }
        }
        for (menu, _) in CommandTable.menus { walk(items(menu, app: app), menu) }
        return out
    }
}
