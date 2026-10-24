import AppKit

/// View ▸ Show Quick Actions… (⇧⌘A, `specs/ide/reference-ui-5.md` §2.4
/// item 5): a command palette listing every enabled menu command by title;
/// choosing one runs it. Its layout is Ycode's (the reference's is still to
/// observe, §12).
public enum QuickActions {
    public struct Action {
        public var title: String
        /// The menus above it, "File ▸ New".
        public var path: String
        public var shortcut: String
        public var item: NSMenuItem
    }

    /// The enabled commands of a menu bar, in menu order. Menus are brought
    /// up to date first (titles, conditions); each command is validated by
    /// the responder that would perform it (the controller's window first).
    @MainActor
    public static func collect(from bar: NSMenu, controller: WorkspaceWindowController?) -> [Action] {
        var out: [Action] = []
        @MainActor func walk(_ menu: NSMenu, _ path: [String]) {
            MenuBarDelegate.shared.update(menu, controller: controller)
            for i in menu.items where !i.isSeparatorItem && !i.isSectionHeader && !i.isHidden {
                if let sub = i.submenu {
                    if sub !== NSApp?.servicesMenu { walk(sub, path + [i.title]) }
                    continue
                }
                guard let a = i.action, a != #selector(WorkspaceWindowController.showQuickActions(_:)),
                      isEnabled(i, action: a, controller: controller) else { continue }
                out.append(Action(title: i.title, path: path.joined(separator: " ▸ "), shortcut: MainMenu.canonicalShortcut(i), item: i))
            }
        }
        for top in bar.items { if let m = top.submenu { walk(m, [top.title]) } }
        return out
    }

    /// Whether the responder that would perform the item's action enables it.
    @MainActor
    static func isEnabled(_ i: NSMenuItem, action a: Selector, controller: WorkspaceWindowController?) -> Bool {
        var target: AnyObject? = i.target
        if target == nil, let w = controller?.window, w.isKeyWindow || w.isMainWindow {
            target = NSApp.target(forAction: a, to: nil, from: i) as AnyObject?
        }
        if target == nil, controller?.responds(to: a) == true { target = controller }
        if target == nil { target = NSApp.target(forAction: a, to: nil, from: i) as AnyObject? }
        guard let t = target as? NSObject, t.responds(to: a) else { return false }
        if let v = t as? NSMenuItemValidation { return v.validateMenuItem(i) }
        if let v = t as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(i) }
        return true
    }

    /// The actions matching a query (fuzzy, by title), best first; all of
    /// them in menu order for an empty query.
    public static func filter(_ actions: [Action], _ query: String) -> [Action] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return actions }
        return actions.enumerated()
            .compactMap { i, a in FuzzyMatch.score(q, a.title).map { (i, a, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}

/// The Quick Actions sheet: a search field over the list of commands.
@MainActor
public final class QuickActionsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public let field = NSSearchField()
    public let table = NSTableView()
    public private(set) var all: [QuickActions.Action]
    public private(set) var shown: [QuickActions.Action]
    /// Runs the chosen action (after the sheet closes).
    var onChoose: ((QuickActions.Action) -> Void)?
    var onCancel: (() -> Void)?

    public init(actions: [QuickActions.Action]) {
        all = actions
        shown = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        field.placeholderString = "Search Commands"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        for (id, w) in [("title", 300.0), ("menu", 170.0), ("key", 70.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.width = w
            table.addTableColumn(col)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseSelected)
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(field)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        reload()
    }

    public func setQuery(_ q: String) {
        _ = view
        field.stringValue = q
        reload()
    }

    func reload() {
        shown = QuickActions.filter(all, field.stringValue)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = shown[row]
        let id = tableColumn?.identifier.rawValue ?? "title"
        let text = id == "title" ? a.title : id == "menu" ? a.path : a.shortcut
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingTail
        if id != "title" { l.textColor = .secondaryLabelColor }
        return l
    }

    public func controlTextDidChange(_ obj: Notification) { reload() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !shown.isEmpty else { return true }
            let d = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let r = min(max(table.selectedRow + d, 0), shown.count - 1)
            table.selectRowIndexes([r], byExtendingSelection: false)
            table.scrollRowToVisible(r)
            return true
        case #selector(NSResponder.insertNewline(_:)): chooseSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }

    @objc func chooseSelected() {
        let r = table.selectedRow
        guard shown.indices.contains(r) else { return }
        onChoose?(shown[r])
    }
}

extension WorkspaceWindowController {
    /// View ▸ Show Quick Actions… (⇧⌘A). Returns the palette (shown as a
    /// sheet while the window is on screen).
    @discardableResult
    @objc public func showQuickActions(_ sender: Any?) -> QuickActionsController? {
        let bar = NSApp?.mainMenu ?? MainMenu.make()
        let c = QuickActionsController(actions: QuickActions.collect(from: bar, controller: self))
        guard let window, window.isVisible else { _ = c.view; return c }
        let sheet = NSPanel(contentViewController: c)
        sheet.title = "Quick Actions"
        c.onCancel = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
        c.onChoose = { [weak window, weak sheet] a in
            if let sheet { window?.endSheet(sheet) }
            DispatchQueue.main.async { if let act = a.item.action { NSApp.sendAction(act, to: a.item.target, from: a.item) } }
        }
        window.beginSheet(sheet)
        sheet.makeFirstResponder(c.field)
        return c
    }
}
