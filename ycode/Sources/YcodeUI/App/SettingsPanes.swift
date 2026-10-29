import AppKit
import UniformTypeIdentifiers
import YcodeSettings
import YcodeWorkspace
import YcodeSubprocess

/// Shared form helpers for the settings panes.
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

    /// The form's row titles in order (labels without their colon, or the
    /// checkbox or button title for rows without a label); headings are
    /// listed as "# <title>". Rebuilt with the form (for tests and the spec).
    public private(set) var rowTitles: [String] = []

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 20, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Long forms (General, Editing ▸ Display) scroll.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        view = root
        build()
    }

    func build() {}

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowTitles = []
        build()
    }

    func row(_ label: String, _ control: NSView) {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let r = NSStackView(views: [l, control])
        r.alignment = .firstBaseline
        stack.addArrangedSubview(r)
        var t = label
        if t.hasSuffix(":") { t.removeLast() }
        if t.isEmpty, let b = control as? NSButton { t = b.title }
        if t.isEmpty, let s = control as? NSStackView, let b = s.arrangedSubviews.first as? NSButton { t = b.title }
        rowTitles.append(t)
    }

    func note(_ s: String) {
        let n = NSTextField(wrappingLabelWithString: s)
        n.font = .systemFont(ofSize: 11)
        n.textColor = .secondaryLabelColor
        stack.addArrangedSubview(n)
    }

    /// A button that opens a sub-page (drill-down row).
    func drill(_ title: String, _ action: @escaping () -> Void) {
        let b = ClosureButton(title: title + "  ›", target: nil, action: nil)
        b.bezelStyle = .inline
        b.onChange = { _ in action() }
        stack.addArrangedSubview(b)
    }

    func backRow(_ title: String, _ action: @escaping () -> Void) {
        let b = ClosureButton(title: "‹ " + title, target: nil, action: nil)
        b.bezelStyle = .inline
        b.onChange = { _ in action() }
        stack.addArrangedSubview(b)
    }

    func heading(_ s: String) {
        let h = NSTextField(labelWithString: s)
        h.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(h)
        rowTitles.append("# " + s)
    }

    /// The pop-up in the row titled `title` (tests drive controls by row).
    public func control<T: NSView>(_ type: T.Type, inRow title: String) -> T? {
        _ = view
        for r in stack.arrangedSubviews.compactMap({ $0 as? NSStackView }) {
            guard let l = r.arrangedSubviews.first as? NSTextField else { continue }
            var t = l.stringValue
            if t.hasSuffix(":") { t.removeLast() }
            let views = r.arrangedSubviews.dropFirst().flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [$0] }
            if t == title, let c = views.first(where: { $0 is T }) as? T { return c }
            if t.isEmpty, let c = views.first(where: { ($0 as? NSButton)?.title == title && $0 is T }) as? T { return c }
        }
        return nil
    }

    /// Selects a pop-up item in a row and fires its action, as a click would.
    public func choose(_ item: String, inRow title: String) {
        guard let p = control(NSPopUpButton.self, inRow: title) else { return }
        p.selectItem(withTitle: item)
        if let a = p.action { _ = (p.target as AnyObject?)?.perform(a, with: p) }
    }

    /// Toggles a checkbox row, as a click would.
    public func toggle(_ title: String) {
        guard let b = control(NSButton.self, inRow: title) else { return }
        b.state = b.state == .on ? .off : .on
        if let a = b.action { _ = (b.target as AnyObject?)?.perform(a, with: b) }
    }

    func popUp(_ titles: [String], selected: String, _ action: @escaping (String) -> Void) -> NSPopUpButton {
        let p = ClosurePopUp(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.selectItem(withTitle: selected)
        p.onChange = action
        return p
    }

    func check(_ title: String, _ on: Bool, _ action: @escaping (Bool) -> Void) -> NSButton {
        let b = ClosureButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        b.onChange = { action($0.state == .on) }
        return b
    }

    func number(_ value: Int, _ action: @escaping (Int) -> Void) -> NSTextField {
        let f = ClosureField(string: "\(value)")
        f.widthAnchor.constraint(equalToConstant: 50).isActive = true
        f.onCommit = { if let n = Int($0.stringValue) { action(n) } }
        return f
    }
}

final class ClosurePopUp: NSPopUpButton {
    var onChange: ((String) -> Void)?
    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        target = self
        action = #selector(fire)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc func fire() { onChange?(titleOfSelectedItem ?? "") }
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
    public init(prefs: Preferences = .shared) { super.init("Accounts", prefs: prefs) }
    // Informational only: Ycode never asks for or stores credentials.
    /// The explanation shown by + (for tests).
    public static let notSupported = "Ycode does not sign in to accounts. Signing uses identities already in your keychain; Ycode never asks for or stores passwords."
    public private(set) var shownMessage: String?

    override func build() {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("a")))
        table.headerView = nil
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add account")!, target: self, action: #selector(addClicked))
        add.bezelStyle = .smallSquare
        let empty = NSTextField(labelWithString: "No Accounts")
        empty.textColor = .secondaryLabelColor
        stack.addArrangedSubview(NSStackView(views: [scroll, empty]))
        stack.addArrangedSubview(add)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { 0 }

    @objc public func addClicked() {
        shownMessage = Self.notSupported
        guard view.window?.isVisible == true, let w = view.window else { return }
        let a = NSAlert()
        a.messageText = "Accounts Are Not Supported"
        a.informativeText = Self.notSupported
        a.beginSheetModal(for: w)
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
    public static func addableActions() -> [String] {
        CommandTable.navigators.map { "Navigator: \($0)" } + [Preferences.showDebuggerAction, Preferences.hideDebuggerAction,
            Preferences.hideDebuggerIfNoOutputAction, Preferences.notifyAction, "Play Sound: Glass", "Play Sound: Basso", "Play Sound: Hero"]
    }

    public func add(_ action: String, to e: Preferences.Event) {
        event = e
        update { b in
            if action.hasPrefix("Navigator: ") { b.showNavigator = CommandTable.navigators.firstIndex(of: String(action.dropFirst(11))) }
            else if action == Preferences.showDebuggerAction { b.showDebugArea = true }
            else if action == Preferences.hideDebuggerAction { b.showDebugArea = false }
            else if action == Preferences.hideDebuggerIfNoOutputAction { b.hideDebugAreaIfNoOutput = true }
            else if action == Preferences.notifyAction { b.notify = true }
            else if action.hasPrefix("Play Sound: ") { b.sound = String(action.dropFirst(12)) }
        }
        if isViewLoaded { rebuild() }
    }

    public func remove(_ action: String, from e: Preferences.Event) {
        event = e
        update { b in
            if action.hasPrefix("Navigator: ") { b.showNavigator = nil }
            else if action == Preferences.hideDebuggerIfNoOutputAction { b.hideDebugAreaIfNoOutput = false }
            else if action.hasPrefix("Debugger: ") { b.showDebugArea = nil }
            else if action == Preferences.notifyAction { b.notify = false }
            else if action.hasPrefix("Play Sound: ") { b.sound = nil }
        }
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
        for e in list {
            // A disclosure triangle collapses the event's group.
            let disclose = ClosureButton(title: "", target: nil, action: nil)
            disclose.bezelStyle = .disclosure
            disclose.setButtonType(.pushOnPushOff)
            disclose.state = isCollapsed(e) ? .off : .on
            disclose.onChange = { [weak self] _ in self?.toggleCollapsed(e) }
            let title = NSTextField(labelWithString: e.rawValue)
            title.font = .boldSystemFont(ofSize: 12)
            stack.addArrangedSubview(NSStackView(views: [disclose, title]))
            guard !isCollapsed(e) else { continue }
            for t in prefs.behavior(e).actionTitles {
                let minus = ClosureButton(title: "−", target: nil, action: nil)
                minus.bezelStyle = .inline
                minus.onChange = { [weak self] _ in self?.remove(t, from: e) }
                stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "    " + t), minus]))
            }
            let plus = ClosurePopUp(frame: .zero, pullsDown: true)
            plus.addItems(withTitles: ["+"] + Self.addableActions())
            plus.onChange = { [weak self] t in self?.add(t, to: e) }
            stack.addArrangedSubview(plus)
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
            row("", check(e.rawValue.replacingOccurrences(of: "When ", with: "").capitalizedFirst, prefs.behavior(e).notify) { [prefs] on in
                var b = prefs.behavior(e)
                b.notify = on
                prefs.setBehavior(b, for: e)
            })
        }
        note("Notifications bounce the Dock icon while Ycode is in the background.")
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

@MainActor
public final class ThemesSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("Appearance", prefs: prefs) }
    public enum Segment: Int { case theme, fonts, editor }
    public var segment: Segment = .theme { didSet { if isViewLoaded { rebuild() } } }

    /// One color row and one font row per token kind, in Ycode's token set
    /// (reference-ui-5.md §9.4). Plain Text is the theme's text color and
    /// source font.
    public static let tokenRows: [(title: String, kind: SourceTokenizer.Kind)] = [
        ("Plain Text", .identifier), ("Comments", .comment), ("Documentation Comments", .docComment), ("Strings", .string),
        ("Numbers", .number), ("Keywords", .keyword), ("Preprocessor Statements", .preprocessor), ("Attributes", .attribute),
        ("Type Names", .typeName),
    ]

    /// The System / Light / Dark thumbnails.
    public private(set) var appearanceButtons: [NSButton] = []
    /// The live code preview under the thumbnails.
    public let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
    public static let previewCode = """
    /// A greeting, said once.
    struct Greeter {
        let name = "Ycode" // who to greet
        #if DEBUG
        @MainActor func greet(times: Int = 1) { print("Hello, \\(name)") }
        #endif
    }
    """

    override func build() {
        appearanceButtons = Preferences.Appearance.allCases.map { a in
            let b = ClosureButton(title: a.rawValue, image: Self.thumbnail(a), target: nil, action: nil)
            b.imagePosition = .imageAbove
            b.setButtonType(.onOff)
            b.isBordered = false
            b.state = prefs.appearance == a ? .on : .off
            b.onChange = { [weak self] _ in self?.chooseAppearance(a) }
            return b
        }
        let thumbs = NSStackView(views: appearanceButtons)
        thumbs.spacing = 18
        stack.addArrangedSubview(thumbs)
        buildPreview()
        let seg = NSSegmentedControl(labels: ["Theme", "Fonts", "Editor"], trackingMode: .selectOne, target: self, action: #selector(segmentChosen(_:)))
        seg.selectedSegment = segment.rawValue
        stack.addArrangedSubview(seg)
        switch segment {
        case .theme: buildTheme()
        case .fonts: buildFonts()
        case .editor:
            row("Cursor style:", popUp(["Vertical Bar"], selected: "Vertical Bar") { _ in })
        }
    }

    /// A thumbnail: a small window drawn light, dark, or split (System).
    static func thumbnail(_ a: Preferences.Appearance) -> NSImage {
        NSImage(size: NSSize(width: 68, height: 44), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            let light = NSColor(white: 0.93, alpha: 1), dark = NSColor(white: 0.18, alpha: 1)
            switch a {
            case .light: light.setFill(); path.fill()
            case .dark: dark.setFill(); path.fill()
            case .system:
                light.setFill(); path.fill()
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                dark.setFill()
                NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }

    public func chooseAppearance(_ a: Preferences.Appearance) {
        prefs.appearance = a
        for (b, x) in zip(appearanceButtons, Preferences.Appearance.allCases) { b.state = x == a ? .on : .off }
    }

    /// The preview shows sample code in the selected theme.
    func buildPreview() {
        preview.isEditable = false
        preview.isSelectable = false
        preview.textContainerInset = NSSize(width: 8, height: 6)
        preview.string = Self.previewCode
        preview.backgroundColor = Theme.backgroundColor
        if let ts = preview.textStorage { Theme.highlight(ts, language: .swift) }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 520).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 120).isActive = true
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.addArrangedSubview(preview)
    }

    @objc func segmentChosen(_ c: NSSegmentedControl) { segment = Segment(rawValue: c.selectedSegment) ?? .theme }

    /// Selects a theme (the "Choose…" menu).
    public func chooseTheme(_ name: String) {
        prefs.themeName = name
        if isViewLoaded { rebuild() }
    }

    func buildTheme() {
        let t = prefs.theme
        let builtIn = EditorTheme.builtIns.contains { $0.name == t.name }
        let choose = ClosurePopUp(frame: .zero, pullsDown: true)
        choose.addItems(withTitles: ["Choose…"] + prefs.themes.map(\.name))
        choose.onChange = { [weak self] in self?.chooseTheme($0) }
        let name = NSTextField(labelWithString: t.name)
        name.font = .boldSystemFont(ofSize: 12)
        row("Theme:", NSStackView(views: [name, choose]))
        for (title, kind) in Self.tokenRows {
            let current = kind == .identifier ? (EditorTheme.color(t.foreground) ?? Theme.textColor)
                : (EditorTheme.color(t.tokens[kind.rawValue]) ?? Theme.color(for: kind))
            let well = ClosureColorWell(color: current)
            well.isEnabled = !builtIn
            well.onChange = { [weak self] c in self?.setColor(c, for: kind) }
            row(title + ":", well)
        }
        heading("Console")
        row("Font size:", number(Int(t.consoleFontSize)) { [weak self] n in self?.edit { $0.consoleFontSize = Double(max(6, min(48, n))) } })
        if builtIn {
            let note = NSTextField(labelWithString: "Built-in themes cannot be changed; duplicate one to edit it.")
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
        }
        let dup = NSButton(title: "Duplicate", target: self, action: #selector(duplicateClicked))
        let del = NSButton(title: "Delete", target: self, action: #selector(deleteClicked))
        del.isEnabled = !builtIn
        let imp = NSButton(title: "Import…", target: self, action: #selector(importClicked))
        let exp = NSButton(title: "Export…", target: self, action: #selector(exportClicked))
        stack.addArrangedSubview(NSStackView(views: [dup, del, imp, exp]))
    }

    /// One font row per token kind: the font's name and an editable size.
    func buildFonts() {
        let t = prefs.theme
        for (title, kind) in Self.tokenRows {
            let f = font(for: kind)
            let name = NSTextField(labelWithString: f.name.isEmpty ? (t.font.displayName ?? "System Monospaced") : f.name)
            let size = number(Int(f.size)) { [weak self] n in
                guard let self else { return }
                var spec = self.font(for: kind)
                spec.size = Double(max(6, min(48, n)))
                self.setFont(spec, for: kind)
            }
            row(title + ":", NSStackView(views: [name, size]))
        }
        heading("Console")
        row("Font size:", number(Int(t.consoleFontSize)) { [weak self] n in self?.edit { $0.consoleFontSize = Double(max(6, min(48, n))) } })
    }

    /// A token kind's font as the Fonts rows show it.
    public func font(for kind: SourceTokenizer.Kind) -> EditorTheme.FontSpec {
        let t = prefs.theme
        if kind != .identifier, let f = t.tokenFonts?[kind.rawValue] { return f }
        return EditorTheme.FontSpec(name: t.fontName, size: t.fontSize)
    }

    /// Sets a token kind's font (Plain Text: the source font) in the
    /// selected user theme.
    public func setFont(_ f: EditorTheme.FontSpec, for kind: SourceTokenizer.Kind) {
        edit { t in
            if kind == .identifier { t.fontName = f.name; t.fontSize = f.size } else { t.tokenFonts = (t.tokenFonts ?? [:]).merging([kind.rawValue: f]) { $1 } }
        }
    }

    /// Sets a token kind's color (Plain Text: the text color).
    public func setColor(_ c: NSColor, for kind: SourceTokenizer.Kind) {
        edit { t in if kind == .identifier { t.foreground = EditorTheme.hex(c) } else { t.tokens[kind.rawValue] = EditorTheme.hex(c) } }
    }

    /// Edits the selected user theme (built-ins are left alone).
    public func edit(_ f: (inout EditorTheme) -> Void) {
        var t = prefs.theme
        guard !EditorTheme.builtIns.contains(where: { $0.name == t.name }) else { return }
        f(&t)
        try? prefs.save(t)
    }

    @objc public func duplicateClicked() {
        _ = try? prefs.duplicate(prefs.theme)
        if isViewLoaded { rebuild() }
    }

    @objc func deleteClicked() {
        prefs.deleteTheme(named: prefs.themeName)
        rebuild()
    }

    @objc func importClicked() {
        guard let w = view.window, w.isVisible else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = []
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { _ = try? self?.prefs.importTheme(from: u); self?.rebuild() }
        }
    }

    @objc func exportClicked() {
        guard let w = view.window, w.isVisible else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = prefs.theme.fileName
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url, let t = self?.prefs.theme { try? self?.prefs.exportTheme(t, to: u) }
        }
    }
}

final class ClosureColorWell: NSColorWell {
    var onChange: ((NSColor) -> Void)?
    convenience init(color: NSColor) {
        self.init(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        self.color = color
        target = self
        action = #selector(fire)
    }
    @objc func fire() { onChange?(color) }
}

// MARK: Editing

/// Editing, with Display, Completion and Indentation sub-pages.
@MainActor
public final class TextEditingSettingsPane: SettingsPane {
    public enum Page: String { case main = "Editing", display = "Display", completion = "Completion", indentation = "Indentation" }
    public var page: Page = .main { didSet { if isViewLoaded { rebuild() } } }
    public init(prefs: Preferences = .shared) { super.init("Editing", prefs: prefs) }

    override func build() {
        switch page {
        case .main:
            for p in [Page.display, .completion, .indentation] { drill(p.rawValue) { [weak self] in self?.page = p } }
            row("Default text encoding:", NSTextField(labelWithString: "Unicode (UTF-8)"))
            row("Default line endings:", NSTextField(labelWithString: "macOS / Unix (LF)"))
            row("", check("Convert existing files on save", prefs.convertExistingFilesOnSave) { [prefs] in prefs.convertExistingFilesOnSave = $0 })
            heading("When Editing")
            row("", check("Automatically trim trailing whitespace", prefs.trimTrailingWhitespace) { [prefs] in prefs.trimTrailingWhitespace = $0 })
            row("", check("Trim whitespace-only lines", prefs.trimWhitespaceOnlyLines) { [prefs] in prefs.trimWhitespaceOnlyLines = $0 })
            heading("Localized Strings")
            row("", check("Automatically generate string catalog comments", prefs.generateStringCatalogComments) { [prefs] in
                prefs.generateStringCatalogComments = $0
            })
        case .display:
            // reference-ui-5.md §9.3, in order. The minimap is Editor ▸ Minimap.
            backRow("Editing") { [weak self] in self?.page = .main }
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
            note("Completions come from the language server as you type.")
        case .indentation:
            backRow("Editing") { [weak self] in self?.page = .main }
            row("Prefer indent using:", popUp(["Spaces", "Tabs"], selected: prefs.indentWithTabs ? "Tabs" : "Spaces") { [prefs] in prefs.indentWithTabs = $0 == "Tabs" })
            row("Tab width:", number(prefs.tabWidth) { [prefs] in prefs.tabWidth = $0 })
            row("Indent width:", number(prefs.indentWidth) { [prefs] in prefs.indentWidth = $0 })
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
        for (id, title, w) in [("command", "Command", 260.0), ("key", "Key", 120.0), ("menu", "Menu", 180.0)] {
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
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        conflictLabel.textColor = .systemRed
        stack.addArrangedSubview(search)
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(conflictLabel)
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

    /// `⌃⌥⇧⌘` prefixes then one key (or `F6`, `↩`, …).
    static func parse(_ text: String) -> (String, MenuCommand.Modifiers)? {
        var mods: MenuCommand.Modifiers = []
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.isEmpty { return ("", []) }
        while let c = rest.first, "⌃⌥⇧⌘".contains(c) {
            switch c {
            case "⌃": mods.insert(.control)
            case "⌥": mods.insert(.option)
            case "⇧": mods.insert(.shift)
            default: mods.insert(.command)
            }
            rest = rest.dropFirst()
        }
        let names = ["↑": Key.up, "↓": Key.down, "←": Key.left, "→": Key.right, "F6": Key.f6, "F7": Key.f7, "F8": Key.f8, "↩": Key.return, "Space": Key.space]
        if let k = names[String(rest)] { return (k, mods) }
        guard rest.count == 1 else { return nil }
        return (rest.lowercased(), mods)
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "config", "--global", "--get", key]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
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
        row("Author Name:", NSTextField(labelWithString: authorName))
        row("Author Email:", NSTextField(labelWithString: authorEmail))
        let note = NSTextField(labelWithString: "From git's global configuration (read-only).")
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
    }
}

// MARK: Components

@MainActor
public final class ComponentsSettingsPane: SettingsPane {
    public struct Component: Equatable, Sendable {
        public var name: String
        public var version: String
        public var kind: String
    }
    /// The installed components; read in the background (simctl) when
    /// none are given.
    public private(set) var components: [Component]
    public private(set) var loading: Task<Void, Never>?
    private var loaded: Bool

    public init(prefs: Preferences = .shared, components: [Component]? = nil) {
        self.components = components ?? []
        loaded = components != nil
        super.init("Components", prefs: prefs)
    }

    public override func loadView() {
        super.loadView()
        guard !loaded, loading == nil else { return }
        loading = Task { [weak self] in
            let list = await Task.detached { Self.installed() }.value
            guard let self else { return }
            self.components = list
            self.loaded = true
            self.loading = nil
            self.rebuild()
        }
    }

    /// SDKs of the active developer directory, then simulator runtimes
    /// from `xcrun simctl list runtimes -j` (both read-only).
    public nonisolated static func installed() -> [Component] {
        var out: [Component] = []
        if let dev = Workspace.activeDeveloperDirectory() {
            out += SDKCatalog(developerDirectory: dev).sdks.map { Component(name: $0.canonicalName, version: $0.version, kind: "SDK") }
        }
        out += runtimes(fromSimctlJSON: run(["simctl", "list", "runtimes", "-j"]) ?? Data())
        return out
    }

    /// `runtimes[]`: `name`, `version`, `isAvailable`.
    public nonisolated static func runtimes(fromSimctlJSON data: Data) -> [Component] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["runtimes"] as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let name = r["name"] as? String else { return nil }
            let available = r["isAvailable"] as? Bool ?? true
            return Component(name: name, version: r["version"] as? String ?? "", kind: available ? "Simulator Runtime" : "Simulator Runtime (unavailable)")
        }
    }

    nonisolated static func run(_ args: [String]) -> Data? {
        MainThreadGuard.blockingCall("xcrun \(args.joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? d : nil
    }

    override func build() {
        heading("Installed (read-only)")
        if components.isEmpty && loaded { stack.addArrangedSubview(NSTextField(labelWithString: "None found")) }
        for c in components { row("\(c.kind):", NSTextField(labelWithString: "\(c.name)  \(c.version)")) }
    }
}

// MARK: Simulators (the remote Ycode simulator)

@MainActor
public final class SimulatorsSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("Simulators", prefs: prefs) }

    public var settings: RemoteSimulatorSettings { RemoteSimulatorSettings.load(prefs.defaults) }

    /// Changes one field and saves (user defaults only).
    public func update(_ f: (inout RemoteSimulatorSettings) -> Void) {
        var s = settings
        f(&s)
        s.save(prefs.defaults)
        prefs.changed()
    }

    override func build() {
        heading("Ycode Simulator")
        let note = NSTextField(wrappingLabelWithString: "Runs apps on the Ycode iOS simulator on an arm64 Linux host over SSH (keys only; Ycode never asks for a password). These values stay in your user settings.")
        note.preferredMaxLayoutWidth = 480
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        let s = settings
        let fields: [(String, String, String)] = [("SSH destination:", s.destination, "user@host"), ("Remote data directory:", s.dataDirectory, "/data/ycode"),
                                                  ("Runtime root:", s.runtimeRoot, "/data/ycode/runtime"), ("ycode-simd path:", s.simdPath, "/data/ycode/bin/ycode-simd"),
                                                  ("Device name:", s.deviceName, "ycode-device"),
                                                  ("Additional arguments:", s.additionalArguments, "--timeout-ms 600000 --shim /path"),
                                                  ("Keep services:", s.keepServices, "com.example.label, …")]
        for (key, (label, value, placeholder)) in fields.enumerated() {
            let f = ClosureField(string: value)
            f.placeholderString = placeholder
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
            f.onCommit = { [weak self] field in
                let v = field.stringValue.trimmingCharacters(in: .whitespaces)
                self?.update { s in
                    switch key {
                    case 0: s.destination = v
                    case 1: s.dataDirectory = v
                    case 2: s.runtimeRoot = v
                    case 3: s.simdPath = v
                    case 4: s.deviceName = v.isEmpty ? "ycode-device" : v
                    case 5: s.additionalArguments = v
                    default: s.keepServices = v
                    }
                }
            }
            row(label, f)
        }
        // More runtimes (run.md §Runtimes and device types): each root adds
        // a destination per device type that runs on it.
        let others = ClosureField(string: s.otherRuntimeRoots.joined(separator: ", "))
        others.placeholderString = "/data/ycode/runtimes/iOS-27.0, …"
        others.widthAnchor.constraint(equalToConstant: 320).isActive = true
        others.onCommit = { [weak self] field in
            let roots = RemoteSimulatorSettings.runtimeRoots(fromText: field.stringValue)
            self?.update { $0.otherRuntimeRoots = roots }
        }
        row("Other runtime roots:", others)
        let rootsHelp = NSTextField(wrappingLabelWithString: RemoteSimulatorSettings.runtimesHelp)
        rootsHelp.font = .systemFont(ofSize: 11)
        rootsHelp.textColor = .secondaryLabelColor
        rootsHelp.preferredMaxLayoutWidth = 420
        row("", rootsHelp)
        // Lean boot (off by default: a full boot, as the reference simulator) with its help text (run.md).
        let lean = check("Lean boot", s.leanBoot) { [weak self] on in self?.update { $0.leanBoot = on } }
        row("", lean)
        let help = NSTextField(wrappingLabelWithString: RemoteSimulatorSettings.leanBootHelp)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 420
        row("", help)
        // The device's camera (off by default, as the reference; camera.md "Ycode implementation").
        let camera = popUp(["Off", "Host webcam", "Synthetic pattern"],
                           selected: ["off": "Off", "on": "Host webcam", "synthetic": "Synthetic pattern"][s.camera] ?? "Off") { [weak self] title in
            let mode = ["Off": "off", "Host webcam": "on", "Synthetic pattern": "synthetic"][title] ?? "off"
            self?.update {
                $0.camera = mode
                $0.cameraChosen = true
            }
        }
        row("Camera:", camera)
        let cameraHelp = NSTextField(wrappingLabelWithString: RemoteSimulatorSettings.cameraHelp)
        cameraHelp.font = .systemFont(ofSize: 11)
        cameraHelp.textColor = .secondaryLabelColor
        cameraHelp.preferredMaxLayoutWidth = 420
        row("", cameraHelp)
        // Warm boot (on by default): restore a snapshot of the booted device (run.md §Warm boot).
        let warm = check("Warm boot from snapshot", s.warmBoot) { [weak self] on in self?.update { $0.warmBoot = on } }
        row("", warm)
        let warmHelp = NSTextField(wrappingLabelWithString: RemoteSimulatorSettings.warmBootHelp)
        warmHelp.font = .systemFont(ofSize: 11)
        warmHelp.textColor = .secondaryLabelColor
        warmHelp.preferredMaxLayoutWidth = 420
        row("", warmHelp)
    }
}
