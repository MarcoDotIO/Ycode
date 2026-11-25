import AppKit
import YcodeIDECore

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
        /// The menus above it, top first (§5.1's rows).
        public var menuPath: [String] = []

        /// The row model both IDEs draw (`QuickActionEntry`).
        public var entry: QuickActionEntry { QuickActionEntry(menuPath: menuPath, title: title, shortcut: shortcut) }
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
                out.append(Action(title: i.title, path: path.joined(separator: " ▸ "), shortcut: MainMenu.canonicalShortcut(i), item: i,
                                  menuPath: path))
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

    /// The actions Quick Actions lists for a query (§5.1's ranking), best
    /// first; none for an empty query.
    public static func ranked(_ actions: [Action], _ query: String) -> [Action] {
        QuickActionRanking.rank(actions.map(\.entry), query: query).map { actions[$0] }
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

/// The Quick Actions capsule (P-086, `popovers.md` §5 and §5.1): 560 × 55,
/// 3 points under the toolbar, "Quick Actions" in a borderless field; once
/// something is typed, a hairline under the field and two-line 56-point
/// rows (the command's glyph, its title with the matched part semibold,
/// its menu path, its key equivalent), the first selected; the panel grows
/// downward to 495 points and the list scrolls inside it. Return runs the
/// selected command.
@MainActor
public final class QuickActionsController: PaletteController {
    public let all: [QuickActions.Action]
    /// Runs the chosen action (after the panel closes).
    var onChoose: ((QuickActions.Action) -> Void)?
    public let rowsView = QuickActionRowsView()
    public let scroller = NSScrollView()
    let hairline = QuickActionHairline()

    public init(actions: [QuickActions.Action]) {
        all = actions
        super.init(.quickActions, rowHeight: QuickActionRowMetrics.rowHeight) { q in
            QuickActions.ranked(actions, q).map { PaletteRow(title: $0.entry.displayTitle, detail: $0.entry.subtitle, trailing: $0.shortcut, symbol: $0.entry.symbol) }
        }
        onSubmit = { [weak self] _, i in
            guard let self, let i, self.actions.indices.contains(i) else { return }
            self.onChoose?(self.actions[i])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        super.loadView()
        resultsView.isHidden = true
        resultsView.removeFromSuperview()
        scroller.documentView = rowsView
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.scrollerStyle = .overlay
        scroller.autohidesScrollers = true
        scroller.borderType = .noBorder
        rowsView.onClick = { [weak self] i in
            self?.resultsView.selected = i
            self?.submit()
        }
        view.addSubview(hairline)
        view.addSubview(scroller)
        reload()
    }

    /// The listed actions, in list order.
    public var actions: [QuickActions.Action] { QuickActions.ranked(all, field.stringValue) }

    public override var panelHeight: CGFloat {
        CGFloat(QuickActionRowMetrics.panelHeight(count: resultsView.rows.count))
    }

    override func reload() {
        super.reload()
        guard scroller.superview != nil else { return }
        let m = QuickActionRowMetrics.self
        let rows = actions
        let w = CGFloat(spec.width)
        rowsView.entries = rows.map(\.entry)
        rowsView.query = field.stringValue
        rowsView.selected = 0
        let n = rows.count
        hairline.isHidden = n == 0
        scroller.isHidden = n == 0
        hairline.frame = NSRect(x: 0, y: CGFloat(m.hairlineY), width: w, height: 1)
        scroller.frame = NSRect(x: 0, y: CGFloat(m.rowsTop), width: w, height: CGFloat(m.listHeight(count: n)))
        rowsView.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(Double(n) * m.rowHeight))
        rowsView.scroll(.zero)
    }

    public override func move(_ d: Int) {
        super.move(d)
        rowsView.selected = resultsView.selected
        let m = QuickActionRowMetrics.self
        rowsView.scrollToVisible(NSRect(x: 0, y: CGFloat(Double(rowsView.selected) * m.rowHeight), width: 1, height: CGFloat(m.rowHeight)))
    }
}

/// The hairline at the field row's bottom (§5.1).
@MainActor
public final class QuickActionHairline: NSView {
    public override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(quickActionHex: QuickActionRowMetrics.hairline(dark: dark)).setFill()
        bounds.fill()
    }
}

/// Quick Actions' rows (§5.1): the glyph centred 33 from the panel's left,
/// the title at 64 (the match semibold, the rest light grey) over the menu
/// path in secondary grey, the key equivalent right-aligned; the selected
/// row a #0059D1 rounded rectangle (radius 14) with everything white.
@MainActor
public final class QuickActionRowsView: NSView {
    public var entries: [QuickActionEntry] = [] { didSet { needsDisplay = true } }
    public var query = "" { didSet { needsDisplay = true } }
    public var selected = 0 { didSet { needsDisplay = true } }
    var onClick: ((Int) -> Void)?

    public override var isFlipped: Bool { true }

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / CGFloat(QuickActionRowMetrics.rowHeight))
        if entries.indices.contains(i) { onClick?(i) }
    }

    /// The row's title as attributed text: the matched part semibold.
    public static func title(_ e: QuickActionEntry, query: String, lit: Bool, dark: Bool) -> NSAttributedString {
        let m = QuickActionRowMetrics.self
        let size = CGFloat(m.titleFontSize)
        let rest = lit ? NSColor.white : NSColor(quickActionHex: m.title(dark: dark))
        let match = lit ? NSColor.white : NSColor(quickActionHex: m.match(dark: dark))
        let s = NSMutableAttributedString(string: e.displayTitle, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: rest])
        let length = (e.displayTitle as NSString).length
        for r in QuickActionRanking.matchedRanges(e, query: query) {
            let start = e.displayTitle.index(e.displayTitle.startIndex, offsetBy: r.lowerBound, limitedBy: e.displayTitle.endIndex) ?? e.displayTitle.endIndex
            let end = e.displayTitle.index(start, offsetBy: r.count, limitedBy: e.displayTitle.endIndex) ?? e.displayTitle.endIndex
            let ns = NSRange(start..<end, in: e.displayTitle)
            guard ns.location + ns.length <= length else { continue }
            s.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: match], range: ns)
        }
        return s
    }

    public override func draw(_ dirtyRect: NSRect) {
        let m = QuickActionRowMetrics.self
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let h = CGFloat(m.rowHeight)
        for (i, e) in entries.enumerated() {
            let f = NSRect(x: 0, y: CGFloat(i) * h, width: bounds.width, height: h)
            guard f.intersects(dirtyRect) else { continue }
            let lit = i == selected
            let hl = m.highlightFrame(row: i, width: Double(bounds.width))
            if lit {
                NSColor(quickActionHex: m.highlight(dark: dark)).setFill()
                NSBezierPath(roundedRect: hl, xRadius: CGFloat(m.highlightRadius), yRadius: CGFloat(m.highlightRadius)).fill()
            }
            // Glyph.
            let ink = lit ? NSColor.white : NSColor(quickActionHex: m.glyph(dark: dark))
            if let image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: CGFloat(m.glyphPointSize), weight: .regular)) {
                let sz = image.size
                let k = min(1, CGFloat(m.glyphColumn) / max(sz.width, sz.height, 1))
                let box = NSRect(x: CGFloat(m.glyphCenterX) - sz.width * k / 2, y: f.minY + h / 2 - sz.height * k / 2, width: sz.width * k, height: sz.height * k)
                let tinted = NSImage(size: sz, flipped: false) { rect in
                    image.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Key equivalent, right-aligned.
            let keyRight = CGFloat(hl.maxX - m.keyRightInset)
            var textRight = keyRight
            if !e.shortcut.isEmpty {
                let key = NSAttributedString(string: e.shortcut, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(m.keyFontSize)),
                                                                              .foregroundColor: lit ? NSColor.white : NSColor(quickActionHex: m.key(dark: dark))])
                let ks = key.size()
                key.draw(at: NSPoint(x: keyRight - ks.width, y: f.minY + CGFloat(m.titleCenterY) - ks.height / 2))
                textRight = keyRight - ks.width - 12
            }
            let x = CGFloat(m.textX)
            let title = Self.title(e, query: query, lit: lit, dark: dark)
            let ts = title.size()
            title.draw(with: NSRect(x: x, y: f.minY + CGFloat(m.titleCenterY) - ts.height / 2, width: max(0, textRight - x), height: ts.height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let sub = NSAttributedString(string: e.subtitle, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(m.subtitleFontSize)),
                                                                          .foregroundColor: lit ? NSColor.white : NSColor(quickActionHex: m.subtitle(dark: dark))])
            let ss = sub.size()
            sub.draw(with: NSRect(x: x, y: f.minY + CGFloat(m.subtitleCenterY) - ss.height / 2, width: max(0, CGFloat(hl.maxX) - 12 - x), height: ss.height),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? { "Results" }
}

extension NSColor {
    convenience init(quickActionHex v: UInt32) {
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension WorkspaceWindowController {
    /// View ▸ Show Quick Actions… (⇧⌘A): the capsule over the window.
    /// Returns its controller.
    @discardableResult
    @objc public func showQuickActions(_ sender: Any?) -> QuickActionsController? {
        let bar = NSApp?.mainMenu ?? MainMenu.make()
        let c = QuickActionsController(actions: QuickActions.collect(from: bar, controller: self))
        c.onChoose = { a in
            DispatchQueue.main.async { if let act = a.item.action { NSApp.sendAction(act, to: a.item.target, from: a.item) } }
        }
        present(palette: c)
        return c
    }
}
