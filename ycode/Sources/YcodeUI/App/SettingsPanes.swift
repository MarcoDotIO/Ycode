import AppKit
import UniformTypeIdentifiers
import YcodeCompletion
import YcodeIDECore
import YcodeSettings
import YcodeWorkspace
import YcodeSubprocess

/// Shared form helpers for the settings panes: the grouped-card form of
/// `specs/ide/settings.md` R3.3. A heading starts a section (its header
/// over a new card); rows go into the current card, separated by lines;
/// notes become the help text of the row before them; anything else (a
/// preview, a list, a way back) sits between the cards.
@MainActor
public class SettingsPane: NSViewController {
    let prefs: Preferences
    let stack = NSStackView()

    init(_ title: String, prefs: Preferences) {
        self.prefs = prefs
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The form's row titles in order (labels, or the button title for
    /// rows without a label); headings are listed as "# <title>". Rebuilt
    /// with the form (for tests and the spec).
    public private(set) var rowTitles: [String] = []
    /// The rows by title, for tests that drive controls.
    private var rowsByTitle: [(title: String, row: SettingsRowView)] = []
    /// The cards in order (for tests and the geometry checks).
    public private(set) var cards: [SettingsCardView] = []
    /// The section headers in order.
    public private(set) var headers: [NSTextField] = []
    private var currentCard: SettingsCardView?
    private enum Kind { case header, card, footnote, loose }
    private var lastKind: Kind?
    /// Where the scrolling form starts under the title area (the
    /// Appearance pane keeps a fixed part above it, R5.1).
    var listTop: CGFloat { 0 }
    /// The first card's distance from the form's top (20 under the title
    /// area: R4.1; 0 for a list under a fixed part).
    var firstCardInset: CGFloat { SettingsMetrics.firstCardTop - SettingsMetrics.titleAreaHeight }
    /// The first header's cap top in the window (76; Components' 59, R5.2).
    var firstHeaderCapTop: CGFloat { SettingsMetrics.firstHeaderCapTop }
    /// The form's scroll view.
    public private(set) var formScroll: NSScrollView?
    /// Adds the views that do not scroll (above `listTop`).
    func buildFixed(in root: NSView) {}

    public override func loadView() {
        let root = SettingsFillView(SettingsColors.detail)
        root.frame = NSRect(x: 0, y: 0, width: SettingsMetrics.windowSize.width - SettingsMetrics.detailX,
                            height: SettingsMetrics.windowSize.height - SettingsMetrics.titleAreaHeight)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        // The first header's cap top is 76 down the window (24 under the
        // title area; a 13-point label's cap top is 3 inside its frame).
        stack.edgeInsets = NSEdgeInsets(top: firstHeaderCapTop - SettingsMetrics.titleAreaHeight - 3,
                                        left: SettingsMetrics.cardInset, bottom: SettingsMetrics.cardInset, right: SettingsMetrics.cardInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Long forms (General, Editing ▸ Display) scroll.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        formScroll = scroll
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: listTop), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            // The cards keep x 200–690 whatever the scroller style: a
            // legacy scroller's track covers the right margin (R3.3).
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        view = root
        buildFixed(in: root)
        build()
    }

    func build() {}

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowTitles = []
        rowsByTitle = []
        cards = []
        headers = []
        currentCard = nil
        lastKind = nil
        build()
    }

    /// Adds a view to the form with the measured spacing before it: a card
    /// 33 to the next header's cap top, a header's cap top 22.5 above its
    /// card, 12 around anything else.
    private func append(_ v: NSView, _ kind: Kind) {
        if let last = stack.arrangedSubviews.last, let lastKind {
            let gap: CGFloat
            switch (lastKind, kind) {
            case (.card, .header): gap = SettingsMetrics.cardToHeader - 3
            case (.header, .card): gap = SettingsMetrics.headerToCard + 3 - 16
            case (.card, .card): gap = SettingsMetrics.cardGap
            case (.card, .footnote): gap = 6
            case (.footnote, .header): gap = SettingsMetrics.cardToHeader - 3
            default: gap = 12
            }
            stack.setCustomSpacing(gap, after: last)
        } else {
            // A pane that starts with a card has it 20 under the title area
            // (R4.1); one that starts with a header has the header's cap top
            // 24 under it.
            stack.edgeInsets.top = kind == .card ? firstCardInset
                : firstHeaderCapTop - SettingsMetrics.titleAreaHeight - 3
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        if kind != .loose {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * SettingsMetrics.cardInset).isActive = true
        }
        lastKind = kind
    }

    /// The card rows go into, started when there is none.
    private var card: SettingsCardView {
        if let currentCard { return currentCard }
        let c = SettingsCardView()
        append(c, .card)
        cards.append(c)
        currentCard = c
        return c
    }

    /// The width of a card (and of the views between them).
    static var contentWidth: CGFloat { SettingsMetrics.cardWidth }

    /// A row of the current card: the label at the left (no colon), the
    /// control at the right. An empty label takes the title of a switch
    /// or button control.
    func row(_ label: String, _ control: NSView) {
        var t = label
        if t.hasSuffix(":") { t.removeLast() }
        var controls = [control]
        if let s = control as? NSStackView { controls = s.arrangedSubviews; s.arrangedSubviews.forEach { s.removeView($0) } }
        var shown = t
        if t.isEmpty, let sw = control as? ClosureSwitch { t = sw.title; shown = sw.title }
        if t.isEmpty, let b = control as? NSButton { t = b.title }
        if t.isEmpty, let b = controls.first as? NSButton { t = b.title }
        let r = SettingsRowView(label: shown, controls: controls)
        card.add(r)
        rowTitles.append(t)
        rowsByTitle.append((t, r))
    }

    /// Help text under the last row's label; a card of its own when the
    /// section has no row yet.
    func note(_ s: String) {
        if let r = currentCard?.rowViews.last as? SettingsRowView, !r.isContent {
            r.setHelp(s)
            return
        }
        let r = SettingsRowView(label: "", controls: [])
        r.setHelp(s)
        card.add(r)
    }

    /// A row that opens a sub-page: its title and a disclosure chevron; the
    /// whole row is the button. With an icon it is a navigation row (R4.1):
    /// 44 tall, the icon at the leading edge, the label after it.
    func drill(_ title: String, icon: SettingsRowIcon? = nil, _ action: @escaping () -> Void) {
        let r = SettingsRowView(label: title, controls: [SettingsDisclosureView()], icon: icon)
        r.onClick = action
        r.setAccessibilityRole(.button)
        r.setAccessibilityLabel(title)
        card.add(r)
    }

    /// A sub-page's way back ("‹ Editing"), above its cards.
    func backRow(_ title: String, _ action: @escaping () -> Void) {
        // "‹ Editing" in the accent colour, 13 points, 10 inside the cards'
        // edge: the Linux IDE's back row too.
        let b = ClosureButton(title: "\u{2039} " + title, target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: "\u{2039} " + title, attributes: [
            .font: NSFont.systemFont(ofSize: SettingsMetrics.fontSize), .foregroundColor: SettingsColors.selection,
        ])
        b.onChange = { _ in action() }
        let box = NSView()
        b.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsMetrics.labelInset),
            b.topAnchor.constraint(equalTo: box.topAnchor), b.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            b.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
        ])
        loose(box)
    }

    /// A view between the cards (it ends the current card).
    func loose(_ v: NSView) {
        currentCard = nil
        append(v, .loose)
    }

    /// A note under the current card, in the help style (it ends the card).
    func footnote(_ text: String) {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = SettingsRowView.helpText(text)
        f.preferredMaxLayoutWidth = SettingsMetrics.cardWidth - 2 * SettingsMetrics.labelInset
        let box = NSView()
        f.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsMetrics.labelInset),
            f.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
            f.topAnchor.constraint(equalTo: box.topAnchor), f.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        currentCard = nil
        append(box, .footnote)
    }

    /// A row of the current card that is a view of its own (Components'
    /// rows), its full width; `title` names it for `rowView(_:)`.
    func cardRow(_ v: NSView, title: String) {
        card.add(v)
        rowTitles.append(title)
    }

    /// A card that holds one view (a list, a preview), inset `inset`.
    func cardContent(_ v: NSView, inset: CGFloat = SettingsMetrics.labelInset) {
        card.add(SettingsRowView(content: v, inset: inset))
    }

    /// Ends the current card: the next row starts a new one.
    func endCard() { currentCard = nil }

    func heading(_ s: String) {
        let h = SettingsHeaderView(s)
        currentCard = nil
        append(h, .header)
        headers.append(h.label)
        rowTitles.append("# " + s)
    }

    /// The control in the row titled `title` (tests drive controls by row).
    public func control<T: NSView>(_ type: T.Type, inRow title: String) -> T? {
        _ = view
        for (t, r) in rowsByTitle where t == title {
            if let c = r.controls.first(where: { $0 is T }) as? T { return c }
        }
        for (_, r) in rowsByTitle {
            if let c = r.controls.first(where: { ($0 as? NSButton)?.title == title && $0 is T }) as? T { return c }
        }
        return nil
    }

    /// The row titled `title`.
    public func rowView(_ title: String) -> SettingsRowView? {
        _ = view
        return rowsByTitle.first { $0.title == title }?.row
    }

    /// Selects a pop-up item in a row and fires its action, as a click would.
    public func choose(_ item: String, inRow title: String) {
        guard let p = control(NSPopUpButton.self, inRow: title) else { return }
        p.selectItem(withTitle: item)
        if let a = p.action { _ = (p.target as AnyObject?)?.perform(a, with: p) }
    }

    /// Flips a switch (or checkbox) row, as a click would.
    public func toggle(_ title: String) {
        if let s = control(NSSwitch.self, inRow: title) {
            s.state = s.state == .on ? .off : .on
            if let a = s.action { _ = (s.target as AnyObject?)?.perform(a, with: s) }
            return
        }
        guard let b = control(NSButton.self, inRow: title) else { return }
        b.state = b.state == .on ? .off : .on
        if let a = b.action { _ = (b.target as AnyObject?)?.perform(a, with: b) }
    }

    /// A card pop-up: the value and a circular chevron button.
    func popUp(_ titles: [String], selected: String, _ action: @escaping (String) -> Void) -> NSPopUpButton {
        let p = ClosurePopUp(frame: .zero, pullsDown: false, card: true)
        p.addItems(withTitles: titles)
        p.selectItem(withTitle: selected)
        p.onChange = action
        return p
    }

    /// A switch; a row with an empty label takes its title.
    func check(_ title: String, _ on: Bool, _ action: @escaping (Bool) -> Void) -> NSSwitch {
        let s = ClosureSwitch(title: title)
        s.state = on ? .on : .off
        s.onChange = { action($0.state == .on) }
        return s
    }

    func number(_ value: Int, _ action: @escaping (Int) -> Void) -> NSTextField {
        let f = ClosureField(string: "\(value)")
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 50).isActive = true
        f.onCommit = { if let n = Int($0.stringValue) { action(n) } }
        return f
    }

    /// A trailing value (read-only text) in the label colour.
    func value(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }
}

final class ClosurePopUp: NSPopUpButton {
    var onChange: ((String) -> Void)?
    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        target = self
        action = #selector(fire)
    }
    /// A card's pop-up (`SettingsCardPopUpCell`).
    convenience init(frame: NSRect, pullsDown: Bool, card: Bool) {
        self.init(frame: frame, pullsDown: pullsDown)
        guard card else { return }
        let c = SettingsCardPopUpCell(textCell: "", pullsDown: pullsDown)
        c.isBordered = false
        cell = c
        target = self
        action = #selector(fire)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc func fire() { onChange?(titleOfSelectedItem ?? "") }

    // A card pop-up is as wide as its cell (the value, the 12.5 gap and the
    // well): AppKit's own sizing takes the bezel's margins off, which put
    // the value against the well (R4.2).
    override var intrinsicContentSize: NSSize {
        guard let c = cell as? SettingsCardPopUpCell else { return super.intrinsicContentSize }
        return NSSize(width: c.cellSize.width, height: SettingsMetrics.popUpCircle)
    }

    override var alignmentRectInsets: NSEdgeInsets { cell is SettingsCardPopUpCell ? NSEdgeInsetsZero : super.alignmentRectInsets }

    override func select(_ item: NSMenuItem?) {
        super.select(item)
        invalidateIntrinsicContentSize()
    }

    override func selectItem(at index: Int) {
        super.selectItem(at: index)
        invalidateIntrinsicContentSize()
    }

    override func selectItem(withTitle title: String) {
        super.selectItem(withTitle: title)
        invalidateIntrinsicContentSize()
    }
}

final class ClosureButton: NSButton {
    var onChange: ((NSButton) -> Void)? { didSet { target = self; action = #selector(fire) } }
    @objc func fire() { onChange?(self) }
}

final class ClosureField: NSTextField {
    var onCommit: ((NSTextField) -> Void)? { didSet { target = self; action = #selector(fire) } }
    @objc func fire() { onCommit?(self) }
}

// MARK: General

/// Settings ▸ General (reference-ui-5.md §9.1).
@MainActor
public final class GeneralSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("General", prefs: prefs) }

    /// The last confirmation text shown (tests); nil when none.
    public private(set) var lastConfirmation: String?

    override func build() {
        heading("Starting Points")
        row("Restore open projects and workspaces:", popUp(Preferences.RestoreWindows.allCases.map(\.rawValue), selected: prefs.restoreWindows.rawValue) { [prefs] in
            prefs.restoreWindows = Preferences.RestoreWindows(rawValue: $0) ?? .system
        })
        note(Self.restoreHelp)

        heading("Navigation and Files")
        row("Navigator size:", popUp(Preferences.NavigatorSize.allCases.map(\.rawValue), selected: prefs.navigatorSize.rawValue) { [prefs] in
            prefs.navigatorSize = Preferences.NavigatorSize(rawValue: $0) ?? .system
        })
        let details: [(String, ReferenceWritableKeyPath<Preferences, Int>)] = [
            ("Bookmark navigator detail:", \.bookmarkNavigatorDetail), ("Find navigator detail:", \.findNavigatorDetail),
            ("Issue navigator detail:", \.issueNavigatorDetail),
        ]
        for (label, key) in details {
            row(label, popUp(Preferences.detailLineChoices.map(Preferences.detailTitle), selected: Preferences.detailTitle(prefs[keyPath: key])) { [prefs] in
                if let n = Preferences.detailLines(fromTitle: $0) { prefs[keyPath: key] = n }
            })
        }
        row("", check("Window tabs have independent sidebar widths", prefs.independentSidebarWidths) { [prefs] in prefs.independentSidebarWidths = $0 })
        note(Self.sidebarWidthsHelp)
        row("", check("Automatically unlock files", prefs.autoUnlockFiles) { [prefs] in prefs.autoUnlockFiles = $0 })
        row("File extensions:", popUp(Preferences.FileExtensions.allCases.map(\.rawValue), selected: prefs.fileExtensions.rawValue) { [prefs] in
            prefs.fileExtensions = Preferences.FileExtensions(rawValue: $0) ?? .hide
        })

        heading("Issues")
        row("Issue presentation:", popUp(Preferences.IssuePresentation.allCases.map(\.rawValue), selected: prefs.issuePresentation.rawValue) { [prefs] in
            prefs.issuePresentation = Preferences.IssuePresentation(rawValue: $0) ?? .inline
        })
        row("", check("Predictive Issues", prefs.showLiveIssues) { [prefs] in prefs.showLiveIssues = $0 })
        row("", check("Stop build on first error", prefs.stopBuildOnFirstError) { [prefs] in prefs.stopBuildOnFirstError = $0 })

        heading("Test Parallelization")
        row("Testing on Mac:", popUp(Preferences.TestParallelization.allCases.map(\.rawValue), selected: prefs.testParallelizationMac.rawValue) { [prefs] in
            prefs.testParallelizationMac = Preferences.TestParallelization(rawValue: $0) ?? .automatic
        })
        row("Testing on Simulator:", popUp(Preferences.TestParallelization.allCases.map(\.rawValue), selected: prefs.testParallelizationSimulator.rawValue) { [prefs] in
            prefs.testParallelizationSimulator = Preferences.TestParallelization(rawValue: $0) ?? .automatic
        })

        heading("Report Navigator")
        row("Local report history:", popUp(Preferences.reportHistoryChoices.map(Preferences.reportHistoryTitle),
                                           selected: Preferences.reportHistoryTitle(prefs.reportHistoryLimit)) { [prefs] t in
            if let n = Preferences.reportHistoryChoices.first(where: { Preferences.reportHistoryTitle($0) == t }) { prefs.reportHistoryLimit = n }
        })

        heading("Settings Import & Export")
        row("", NSStackView(views: [button("Export…") { [weak self] in self?.exportClicked() }, button("Import…") { [weak self] in self?.importClicked() }]))

        heading("Reset Ycode")
        row("Reset Settings:", button("Reset…") { [weak self] in self?.resetClicked() })
        row("\u{201C}Don\u{2019}t ask me\u{201D} warnings:", button("Reset All") { [weak self] in self?.resetWarningsClicked() })
    }

    /// The help under Restore open projects and workspaces (Ycode's words).
    public static let restoreHelp = "Use System Setting reopens them unless \u{201C}Close windows when quitting an application\u{201D} is on in "
        + "System Settings \u{25B8} Desktop & Dock."
    /// The help under Window tabs have independent sidebar widths.
    public static let sidebarWidthsHelp = "Each tab of a window keeps its own navigator and inspector widths, so the tab bar moves when you "
        + "switch between tabs."

    func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.onChange = { _ in action() }
        return b
    }

    public static let resetSettingsMessage = "Reset all Ycode settings to their defaults?"
    public static let resetWarningsMessage = "Show all warnings you chose not to be asked about again?"

    /// Asks first (as a sheet), then runs `action`.
    func confirm(_ message: String, _ info: String, _ action: @escaping () -> Void) {
        lastConfirmation = message
        guard let w = view.window, w.isVisible else { return }
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { action() } }
    }

    @objc public func resetClicked() {
        confirm(Self.resetSettingsMessage, "Settings return to their factory values. Themes and recent projects are kept.") { [weak self] in
            self?.prefs.resetSettings()
            self?.rebuild()
        }
    }

    @objc public func resetWarningsClicked() {
        confirm(Self.resetWarningsMessage, "Warnings you suppressed with \u{201C}Don\u{2019}t ask me\u{201D} will be shown again.") { [weak self] in
            self?.prefs.resetSuppressedWarnings()
        }
    }

    /// Writes the settings file (Export…).
    public func exportSettings(to url: URL) throws { try prefs.exportSettings().write(to: url, options: .atomic) }

    /// Reads a settings file (Import…) and shows its values.
    public func importSettings(from url: URL) throws {
        try prefs.importSettings(Data(contentsOf: url))
        if isViewLoaded { rebuild() }
    }

    @objc func exportClicked() {
        guard let w = view.window, w.isVisible else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "Ycode Settings.json"
        p.allowedContentTypes = [.json]
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { do { try self?.exportSettings(to: u) } catch { NSApp.presentError(error) } }
        }
    }

    @objc func importClicked() {
        guard let w = view.window, w.isVisible else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { do { try self?.importSettings(from: u) } catch { NSApp.presentError(error) } }
        }
    }
}

// MARK: Accounts

@MainActor
public final class AccountsSettingsPane: SettingsPane, NSTableViewDataSource {
    public init(prefs: Preferences = .shared) { super.init(AccountsPage.title, prefs: prefs) }
    // Informational only: Ycode never asks for or stores credentials.
    /// The explanation shown by + (for tests).
    public static let notSupported = AccountsPage.explanation(keychain: true)
    public private(set) var shownMessage: String?
    /// The App Store Connect API keys the list shows (none until #43).
    var keyStore: any AppStoreConnectKeyStore = NoAppStoreConnectKeys()

    /// The list's card: the list, then a bar with + under a separator.
    public static let listHeight: CGFloat = 240
    public static let barHeight: CGFloat = 28
    /// The empty list's text (for tests).
    public private(set) var emptyLabel: NSTextField?
    public private(set) var addButton: NSButton?

    override func build() {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("a")))
        table.headerView = nil
        table.dataSource = self
        table.backgroundColor = .clear
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: AccountsPage.addLabel)!, target: self, action: #selector(addClicked))
        add.isBordered = false
        add.toolTip = AccountsPage.addLabel
        let empty = NSTextField(labelWithString: AccountsPage.emptyText)
        empty.textColor = .secondaryLabelColor
        empty.isHidden = numberOfRows(in: table) > 0
        let line = SettingsSeparatorView()
        let box = NSView()
        for v in [scroll, empty, line, add] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: SettingsMetrics.cardWidth),
            box.heightAnchor.constraint(equalToConstant: Self.listHeight),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor), line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.barHeight),
            add.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsMetrics.labelInset),
            add.centerYAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.barHeight / 2),
            add.widthAnchor.constraint(equalToConstant: 20), add.heightAnchor.constraint(equalToConstant: 20),
        ])
        emptyLabel = empty
        addButton = add
        cardContent(box, inset: 0)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { AccountsPage.rows(from: keyStore).count }

    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let r = AccountsPage.rows(from: keyStore)[row]
        return "\(r.title) (\(r.detail))"
    }

    /// The sheet + shows.
    public func makeAlert() -> NSAlert {
        let a = NSAlert()
        a.messageText = AccountsPage.sheetTitle
        a.informativeText = Self.notSupported
        return a
    }

    @objc public func addClicked() {
        shownMessage = Self.notSupported
        guard view.window?.isVisible == true, let w = view.window else { return }
        makeAlert().beginSheetModal(for: w)
    }
}

// MARK: Behaviors

/// Categories, each drilling into its events; each event lists its actions
/// with + (add) and − (remove) (reference-ui.md §4).
@MainActor
public final class BehaviorsSettingsPane: SettingsPane {
    public private(set) var event: Preferences.Event = .buildStarts
    /// The open category (nil = the category list).
    public private(set) var category: String?
    public init(prefs: Preferences = .shared) { super.init("Behaviors", prefs: prefs) }

    public func events(in c: String) -> [Preferences.Event] { Preferences.Event.allCases.filter { $0.category == c } }
    public func count(in c: String) -> Int { events(in: c).filter { !prefs.behavior($0).actionTitles.isEmpty }.count }

    public func open(category c: String?) {
        category = c
        if isViewLoaded { rebuild() }
    }

    public func select(_ e: Preferences.Event) {
        event = e
        open(category: e.category)
    }

    /// The actions + offers.
    public static func addableActions() -> [String] { Preferences.Behavior.addableActions() }

    public func add(_ action: String, to e: Preferences.Event) {
        event = e
        update { $0.add(action: action) }
        if isViewLoaded { rebuild() }
    }

    public func remove(_ action: String, from e: Preferences.Event) {
        event = e
        update { $0.remove(action: action) }
        if isViewLoaded { rebuild() }
    }

    /// Event groups the user collapsed (each group's disclosure button).
    public private(set) var collapsed: Set<Preferences.Event> = []
    public func isCollapsed(_ e: Preferences.Event) -> Bool { collapsed.contains(e) }
    public func toggleCollapsed(_ e: Preferences.Event) {
        if collapsed.contains(e) { collapsed.remove(e) } else { collapsed.insert(e) }
        if isViewLoaded { rebuild() }
    }

    override func build() {
        guard let category else {
            for c in Preferences.behaviorCategories {
                let n = count(in: c)
                drill("\(c)  (\(n) behavior\(n == 1 ? "" : "s"))") { [weak self] in self?.open(category: c) }
            }
            return
        }
        backRow("Behaviors") { [weak self] in self?.open(category: nil) }
        heading(category)
        let list = events(in: category)
        if list.isEmpty { note("Ycode has no events in this category.") }
        // One card per event: its name with a disclosure button, its
        // actions with −, and + to add one.
        for e in list {
            let disclose = ClosureButton(title: "", target: nil, action: nil)
            disclose.bezelStyle = .disclosure
            disclose.setButtonType(.pushOnPushOff)
            disclose.state = isCollapsed(e) ? .off : .on
            disclose.onChange = { [weak self] _ in self?.toggleCollapsed(e) }
            disclose.setAccessibilityLabel(e.rawValue)
            row(e.rawValue, disclose)
            if !isCollapsed(e) {
                for t in prefs.behavior(e).actionTitles {
                    let minus = ClosureButton(title: "−", target: nil, action: nil)
                    minus.bezelStyle = .inline
                    minus.setAccessibilityLabel("Remove \(t)")
                    minus.onChange = { [weak self] _ in self?.remove(t, from: e) }
                    row(t, minus)
                }
                let plus = ClosurePopUp(frame: .zero, pullsDown: true)
                plus.addItems(withTitles: ["+"] + Self.addableActions())
                plus.onChange = { [weak self] t in self?.add(t, to: e) }
                row("Add an action", plus)
            }
            endCard()
        }
    }

    func update(_ f: (inout Preferences.Behavior) -> Void) {
        var b = prefs.behavior(event)
        f(&b)
        prefs.setBehavior(b, for: event)
    }
}

// MARK: Notifications
// (Settings ▸ Coding Assistant is CodingAssistantSettingsPane.swift.)

/// Which events notify (the Behaviors "Notify" action), per event.
@MainActor
public final class NotificationsSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("Notifications", prefs: prefs) }
    override func build() {
        heading("Notify when")
        for e in Preferences.Event.allCases {
            row("", check(e.notificationTitle, prefs.behavior(e).notify) { [prefs] on in
                var b = prefs.behavior(e)
                b.notify = on
                prefs.setBehavior(b, for: e)
            })
        }
        footnote("Notifications bounce the Dock icon while Ycode is in the background.")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Navigation

/// Settings ▸ Navigation (reference-ui-5.md §9.2).
@MainActor
public final class NavigationSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("Navigation", prefs: prefs) }

    override func build() {
        let content = Preferences.NewEditorContent.allCases.map(\.rawValue)
        row("New Editor Tabs Open With:", popUp(content, selected: prefs.newEditorTabsOpenWith.rawValue) { [prefs] in
            prefs.newEditorTabsOpenWith = Preferences.NewEditorContent(rawValue: $0) ?? .startPage
        })
        row("New Editor Panes Open With:", popUp(content, selected: prefs.newEditorPanesOpenWith.rawValue) { [prefs] in
            prefs.newEditorPanesOpenWith = Preferences.NewEditorContent(rawValue: $0) ?? .sameDocument
        })
        row("Pin Editor Tabs:", popUp(Preferences.PinEditorTabs.allCases.map(\.rawValue), selected: prefs.pinEditorTabs.rawValue) { [prefs] in
            prefs.pinEditorTabs = Preferences.PinEditorTabs(rawValue: $0) ?? .manually
        })

        heading("Click on Code")
        let clicks: [(String, ReferenceWritableKeyPath<Preferences, Preferences.CodeClick>)] = [
            ("With Option:", \.optionClickOnCode), ("With Command:", \.commandClickOnCode), ("With Command & Control:", \.commandControlClickOnCode),
        ]
        for (label, key) in clicks {
            row(label, popUp(Preferences.CodeClick.allCases.map(\.rawValue), selected: prefs[keyPath: key].rawValue) { [prefs] in
                if let c = Preferences.CodeClick(rawValue: $0) { prefs[keyPath: key] = c }
            })
        }

        heading("Navigation")
        row("Destination:", popUp(Preferences.NavigationDestination.allCases.map(\.rawValue), selected: prefs.navigationDestination.rawValue) { [prefs] in
            prefs.navigationDestination = Preferences.NavigationDestination(rawValue: $0) ?? .focusedPane
        })
        let targets: [(String, ReferenceWritableKeyPath<Preferences, Preferences.NavigationTarget>)] = [
            ("With Option:", \.navigationWithOption), ("With Option & Shift:", \.navigationWithOptionShift),
            ("With Double-click:", \.navigationWithDoubleClick),
        ]
        for (label, key) in targets {
            row(label, popUp(Preferences.NavigationTarget.allCases.map(\.rawValue), selected: prefs[keyPath: key].rawValue) { [prefs] in
                if let t = Preferences.NavigationTarget(rawValue: $0) { prefs[keyPath: key] = t }
            })
        }
        row("", check("Use Window Tabs In Full Screen", prefs.useWindowTabsInFullScreen) { [prefs] in prefs.useWindowTabsInFullScreen = $0 })
        row("", check("Animate Open Quickly With Multiple Editor Panes", prefs.animateOpenQuickly) { [prefs] in prefs.animateOpenQuickly = $0 })
    }
}

// MARK: Themes

// MARK: Editing

/// Editing, with Display, Completion and Indentation sub-pages.
@MainActor
public final class TextEditingSettingsPane: SettingsPane {
    public enum Page: String { case main = "Editing", display = "Display", completion = "Completion", indentation = "Indentation" }
    public var page: Page = .main { didSet { if isViewLoaded { rebuild() } } }
    public init(prefs: Preferences = .shared) { super.init("Editing", prefs: prefs) }
    /// The default encoding and line endings (the only ones Ycode writes).
    public static let textEncoding = "Unicode (UTF-8)"
    public static let lineEndings = "macOS / Unix (LF)"
    /// Predictive completion's Test result and download progress
    /// (TextEditingSettingsPane+Prediction.swift).
    public internal(set) var predictionProbe: BackendProbe?
    public internal(set) var predictionMessage = ""
    var predictionTask: Task<Void, Never>?

    override func build() {
        switch page {
        case .main:
            // R4.1: the navigation rows' card, then text encoding alone in a
            // card, then line endings and the convert switch, 10 apart with
            // no header. Ycode reads and writes UTF-8 with LF only, so each
            // pop-up offers the one value.
            for p in [Page.display, .completion, .indentation] {
                drill(p.rawValue, icon: SettingsRowIcon.forEditingPage(p.rawValue)) { [weak self] in self?.page = p }
            }
            endCard()
            row("Default text encoding", popUp([Self.textEncoding], selected: Self.textEncoding) { _ in })
            endCard()
            row("Default line endings", popUp([Self.lineEndings], selected: Self.lineEndings) { _ in })
            row("", check("Convert existing files on save", prefs.convertExistingFilesOnSave) { [prefs] in prefs.convertExistingFilesOnSave = $0 })
            heading("When Editing")
            row("", check("Automatically trim trailing whitespace", prefs.trimTrailingWhitespace) { [prefs] in prefs.trimTrailingWhitespace = $0 })
            row("", check("Trim whitespace-only lines", prefs.trimWhitespaceOnlyLines) { [prefs] in prefs.trimWhitespaceOnlyLines = $0 })
            // specs/ide/predictive-completion.md §5: the switch; its backend is on the Completion page.
            row("", check("Predictive code completion", prefs.predictiveCompletion.enabled) { [prefs] on in
                var s = prefs.predictiveCompletion
                s.enabled = on
                prefs.predictiveCompletion = s
            })
            heading("Localized Strings")
            row("", check("Automatically generate string catalog comments", prefs.generateStringCatalogComments) { [prefs] in
                prefs.generateStringCatalogComments = $0
            })
        case .display:
            // reference-ui-5.md §9.3, in order. The minimap is Editor ▸ Minimap.
            backRow("Editing") { [weak self] in self?.page = .main }
            heading("Display")
            row("", check("Line numbers", prefs.showLineNumbers) { [prefs] in prefs.showLineNumbers = $0 })
            row("", check("Code folding ribbon", prefs.showFoldingRibbon) { [prefs] in prefs.showFoldingRibbon = $0 })
            row("", check("Code structure headers", prefs.showCodeStructureHeaders) { [prefs] in prefs.showCodeStructureHeaders = $0 })
            row("", check("MARK separators", prefs.showMarkSeparators) { [prefs] in prefs.showMarkSeparators = $0 })
            row("", check("Code coverage iteration counts", prefs.showCoverageCounts) { [prefs] in prefs.showCoverageCounts = $0 })
            row("", check("Condition on #endif lines", prefs.showEndifConditions) { [prefs] in prefs.showEndifConditions = $0 })
            row("Scope guides:", popUp(Preferences.ScopeGuides.allCases.map(\.rawValue), selected: prefs.scopeGuides.rawValue) { [prefs] in
                prefs.scopeGuides = Preferences.ScopeGuides(rawValue: $0) ?? .none
            })
            row("Reformat code at column:", number(prefs.reformatColumn) { [prefs] in prefs.reformatColumn = $0 })
            row("", check("Show reformatting guide", prefs.showReformattingGuide) { [prefs] in prefs.showReformattingGuide = $0 })
            row("", check("Automatically reformat when completing", prefs.reformatWhenCompleting) { [prefs] in prefs.reformatWhenCompleting = $0 })
            row("", check("Dim inactive code", prefs.dimInactiveCode) { [prefs] in prefs.dimInactiveCode = $0 })
            row("", check("Highlight instances of selected symbol", prefs.highlightSelectedSymbol) { [prefs] in prefs.highlightSelectedSymbol = $0 })
            let delay = ClosureField(string: String(prefs.highlightDelay))
            delay.widthAnchor.constraint(equalToConstant: 50).isActive = true
            delay.onCommit = { [prefs] in if let d = Double($0.stringValue) { prefs.highlightDelay = d } }
            row("Highlighting delay:", delay)
            row("Editor overscroll:", popUp(Preferences.EditorOverscroll.allCases.map(\.rawValue), selected: prefs.editorOverscroll.rawValue) { [prefs] in
                prefs.editorOverscroll = Preferences.EditorOverscroll(rawValue: $0) ?? .medium
            })
            heading("Line Wrapping")
            row("", check("Wrap lines to editor width", prefs.wrapLines) { [prefs] in prefs.wrapLines = $0 })
            row("Indent wrapped lines:", number(prefs.wrappedLineIndent) { [prefs] in prefs.wrappedLineIndent = $0 })
            heading("Documentation Comments")
            row("", check("Fade delimiters", prefs.fadeDocCommentDelimiters) { [prefs] in prefs.fadeDocCommentDelimiters = $0 })
            row("", check("Fade comment delimiters", prefs.fadeCommentDelimiters) { [prefs] in prefs.fadeCommentDelimiters = $0 })
        case .completion:
            backRow("Editing") { [weak self] in self?.page = .main }
            heading("Code Completion")
            note("Completions come from the language server as you type.")
            buildPredictionRows()
        case .indentation:
            backRow("Editing") { [weak self] in self?.page = .main }
            heading("Indentation")
            row("Prefer indent using:", popUp(["Spaces", "Tabs"], selected: prefs.indentWithTabs ? "Tabs" : "Spaces") { [prefs] in prefs.indentWithTabs = $0 == "Tabs" })
            row("Tab width:", number(prefs.tabWidth) { [prefs] in prefs.tabWidth = $0 })
            row("Indent width:", number(prefs.indentWidth) { [prefs] in prefs.indentWidth = $0 })
            row("Tab key:", popUp(TabKeyBehavior.allCases.map(\.title), selected: prefs.tabKeyBehavior.title) { [prefs] t in
                prefs.tabKeyBehavior = TabKeyBehavior.allCases.first { $0.title == t } ?? .indentsInLeadingWhitespace
            })
            heading("Typing")
            row("", check("Syntax-aware indenting", prefs.autoIndent) { [prefs] in prefs.autoIndent = $0 })
            row("", check("Automatically insert closing brackets and quotes", prefs.autoInsertClosers) { [prefs] in prefs.autoInsertClosers = $0 })
            row("", check("Enclose selection in matching delimiters", prefs.encloseSelection) { [prefs] in prefs.encloseSelection = $0 })
        }
    }
}

// MARK: Key Bindings

@MainActor
public final class KeyBindingsSettingsPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public private(set) var rows: [KeyBindings.Entry] = []
    public private(set) var lastConflicts: [KeyBindings.Entry] = []
    let table = NSTableView()
    let search = NSSearchField()
    let conflictLabel = NSTextField(labelWithString: "")
    public var query = "" { didSet { reload() } }

    public init(prefs: Preferences = .shared) { super.init("Shortcuts", prefs: prefs) }

    override func build() {
        search.placeholderString = "Filter"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 300).isActive = true
        for (id, title, w) in [("command", "Command", 200.0), ("key", "Key", 100.0), ("menu", "Menu", 140.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        table.style = .plain
        scroll.widthAnchor.constraint(equalToConstant: SettingsMetrics.cardWidth - 2 * SettingsMetrics.labelInset).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        conflictLabel.textColor = .systemRed
        loose(search)
        cardContent(scroll)
        loose(conflictLabel)
        reload()
    }

    func reload() {
        rows = KeyBindings.search(query, prefs)
        if isViewLoaded { table.reloadData() }
    }

    public func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { query = search.stringValue }
    }

    /// Sets a shortcut from text like `⌃⇧⌘K` (empty clears). Returns false
    /// on a conflict (shown under the table) or unreadable text.
    @discardableResult
    public func setShortcut(_ text: String, forRow i: Int) -> Bool {
        guard rows.indices.contains(i), let (key, mods) = Self.parse(text) else { return false }
        lastConflicts = KeyBindings.set(rows[i].id, key: key, modifiers: mods, prefs)
        conflictLabel.stringValue = lastConflicts.isEmpty ? "" : "Conflicts with: " + lastConflicts.map { "\($0.title) (\($0.menu))" }.joined(separator: ", ")
        reload()
        return lastConflicts.isEmpty
    }

    /// `⌃⌥⇧⌘` prefixes then one key (or `F6`, `↩`, …); the core's parser,
    /// shared with the Linux IDE.
    static func parse(_ text: String) -> (String, MenuCommand.Modifiers)? {
        KeyBindings.parse(text).map { ($0.key, $0.modifiers) }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let e = rows[row]
        switch c?.identifier.rawValue {
        case "key":
            let f = ClosureField(string: e.command.shortcutText)
            f.isBordered = false
            f.drawsBackground = false
            f.font = .systemFont(ofSize: 11, weight: e.customized ? .semibold : .regular)
            f.onCommit = { [weak self] field in self?.setShortcut(field.stringValue, forRow: row) }
            return f
        case "menu": return NSTextField(labelWithString: e.menu)
        default: return NSTextField(labelWithString: e.title)
        }
    }
}

// MARK: Source Control

@MainActor
public final class SourceControlSettingsPane: SettingsPane {
    /// Reads a git configuration key; nil reads git's global
    /// configuration off the main thread when the pane is shown.
    let readConfig: ((String) -> String?)?
    /// The author read in the background (`readConfig` nil).
    private var loadedAuthor: (name: String?, email: String?)?
    /// The background read, while it runs.
    public private(set) var loading: Task<Void, Never>?

    public init(prefs: Preferences = .shared, readConfig: ((String) -> String?)? = nil) {
        self.readConfig = readConfig
        super.init("Source Control", prefs: prefs)
    }

    public override func loadView() {
        super.loadView()
        guard readConfig == nil, loadedAuthor == nil, loading == nil else { return }
        loading = Task { [weak self] in
            let author = await Task.detached { (name: Self.gitConfig("user.name"), email: Self.gitConfig("user.email")) }.value
            guard let self else { return }
            self.loadedAuthor = author
            self.loading = nil
            self.rebuild()
        }
    }

    /// `git config --global --get <key>` (read-only).
    public nonisolated static func gitConfig(_ key: String) -> String? {
        MainThreadGuard.blockingCall("git config \(key)")
        return GitGlobalConfig.value(key)
    }

    public var authorName: String { value("user.name", loadedAuthor?.name) }
    public var authorEmail: String { value("user.email", loadedAuthor?.email) }

    private func value(_ key: String, _ loaded: String??) -> String {
        if let readConfig { return readConfig(key) ?? "Not set" }
        guard loadedAuthor != nil else { return "" }   // still reading
        // swiftlint:disable:next redundant_nil_coalescing - flattens a double optional
        return (loaded ?? nil) ?? "Not set"
    }

    override func build() {
        row("", check("Enable source control", prefs.sourceControlEnabled) { [prefs] in prefs.sourceControlEnabled = $0 })
        heading("Git")
        row("Author Name:", value(authorName))
        row("Author Email:", value(authorEmail))
        note("From git's global configuration (read-only).")
    }
}
