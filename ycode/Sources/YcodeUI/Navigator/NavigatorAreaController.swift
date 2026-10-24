import AppKit
import YcodeBuild
import YcodeDebug

/// A row in any navigator outline.
public final class OutlineItem: NSObject {
    public let title: String
    public let symbol: String
    public let tint: NSColor?
    public var children: [OutlineItem]
    /// Where selecting the row goes.
    public let path: String?
    public let line: Int?
    public let frameID: Int?
    public let reportIndex: Int?
    /// Source-control letter shown at the row's right (M, A, ?, …).
    public var badge: String?
    /// A report row's page (test runs), see `setReports`.
    public var reportPage: String?
    /// Secondary text after the title ("3 issues").
    public var detail: String?
    /// Wrap the title to this many lines (0: one truncated line); the
    /// selected row shows all of it.
    public var maxLines = 0
    /// Debugger rows: greyed text, middle truncation, a dotted separator,
    /// and a breakpoint's enabled marker at the right (DebugNavigatorRows).
    public var dimmed = false
    public var middleTruncation = false
    public var isSeparator = false
    public var enabledMarker: Bool?
    /// Source Control navigator routing key (see SourceControlNavigatorModel).
    public var scmKey: String?
    /// Project navigator rows: the row's kind and its key for the saved
    /// expansion (`NavigatorNode.expansionKey`).
    public var nodeKind: NavigatorNode.Kind?
    public var expansionKey: String?
    /// A glyph at the row's right end (the Test navigator's status
    /// diamonds, a done bookmark's check).
    public var trailingSymbol: String?
    public var trailingTint: NSColor?
    /// The bookmark a Bookmark navigator row shows.
    public var bookmark: Bookmark?
    /// A level bar before the badge, 0…1 (the Debug navigator's Energy
    /// Impact gauge).
    public var level: Double?
    /// Small buttons at the row's right end (the Debug navigator's process
    /// row): symbol, tooltip and the action sent up the responder chain.
    public var rowButtons: [(symbol: String, toolTip: String, action: String)] = []

    public init(title: String, symbol: String, tint: NSColor? = nil, children: [OutlineItem] = [], path: String? = nil, line: Int? = nil,
                frameID: Int? = nil, reportIndex: Int? = nil) {
        self.frameID = frameID
        self.reportIndex = reportIndex
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.children = children
        self.path = path
        self.line = line
    }

    /// SF Symbol names by file kind (looked up at runtime through the public API).
    static func symbol(for node: NavigatorNode) -> String {
        switch node.kind {
        case .container:
            if node.path?.hasSuffix(".xcworkspace") == true { return "square.stack.3d.up" }
            return node.path?.hasSuffix(".xcodeproj") == true ? "folder.badge.gearshape" : "shippingbox"
        case .group: return "folder"
        case .folder: return "folder.fill"
        case .file: return fileSymbol(node.name)
        }
    }

    /// The file-type glyph of a file name or path.
    static func fileSymbol(_ name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension {
        case "swift": "chevron.left.forwardslash.chevron.right"
        case "h", "m", "c", "mm", "cpp": "c.square"
        case "xcassets": "photo.on.rectangle"
        case "xcstrings": "character.book.closed"
        case "plist", "json": "list.bullet.rectangle"
        case "storyboard", "xib": "rectangle.on.rectangle"
        case "xcconfig": "gearshape"
        case "app", "framework", "xctest", "a", "dylib": "shippingbox"
        default: "doc.text"
        }
    }

    public convenience init(_ node: NavigatorNode) { self.init(node, hideExtensions: false) }

    /// `hideExtensions`: file rows without their extension (Settings ▸
    /// General ▸ File Extensions ▸ Hide All).
    public convenience init(_ node: NavigatorNode, hideExtensions: Bool) {
        // Files open in the editor; a project row opens the project editor.
        let opens = node.kind == .file || node.path?.hasSuffix(".xcodeproj") == true
        let title = hideExtensions && node.kind == .file ? (node.name as NSString).deletingPathExtension : node.name
        self.init(title: title.isEmpty ? node.name : title, symbol: Self.symbol(for: node),
                  children: node.children.map { OutlineItem($0, hideExtensions: hideExtensions) }, path: opens ? node.path : nil)
        nodeKind = node.kind
        expansionKey = node.kind == .file ? nil : node.expansionKey
    }
}

/// The left navigator area: a selector bar of nine navigators above the
/// selected navigator's content, with a filter field at the bottom. See
/// `specs/ide/navigators.md`.
@MainActor
public final class NavigatorAreaController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public static let symbols = [
        "folder", "arrow.triangle.branch", "bookmark", "magnifyingglass", "exclamationmark.triangle",
        "checkmark.diamond", "gauge.with.dots.needle.33percent", "tag", "list.bullet.rectangle",
    ]

    public private(set) var selectedIndex = 0
    public var onOpen: ((String, Int?) -> Void)?

    private(set) var roots: [[OutlineItem]] = Array(repeating: [], count: CommandTable.navigators.count)
    /// Each navigator's filter text (the field shows the selected one's).
    private var filterTexts: [Int: String] = [:]
    /// The selected navigator's rows with its filter applied (navigators
    /// other than Project; Project filters through `applyProjectFilter`).
    private var filteredRoots: [OutlineItem]?
    private var shownRoots: [OutlineItem] { filteredRoots ?? roots[selectedIndex] }

    /// The rows the selected navigator shows (tests).
    public var shownRows: [OutlineItem] { shownRoots }
    /// The selector buttons' tooltips (tests).
    public var selectorToolTips: [String] { buttons.map { $0.toolTip ?? "" } }
    /// The left pull-down button of the bottom bar (nil while hidden; tests).
    public var leftButtonToolTip: String?? { addBreakpointButton.isHidden ? nil : .some(addBreakpointButton.toolTip) }

    /// Keeps rows whose title contains the text, and parents of such rows.
    func refilter() {
        let t = (filterTexts[selectedIndex] ?? "").lowercased()
        guard selectedIndex != 0, !t.isEmpty else { filteredRoots = nil; return }
        func keep(_ item: OutlineItem) -> OutlineItem? {
            if item.title.lowercased().contains(t) { return item }
            let kids = item.children.compactMap(keep)
            guard !kids.isEmpty else { return nil }
            let copy = OutlineItem(title: item.title, symbol: item.symbol, tint: item.tint, children: kids, path: item.path, line: item.line,
                                   frameID: item.frameID, reportIndex: item.reportIndex)
            copy.badge = item.badge
            copy.detail = item.detail
            copy.reportPage = item.reportPage
            copy.dimmed = item.dimmed
            copy.middleTruncation = item.middleTruncation
            copy.enabledMarker = item.enabledMarker
            copy.level = item.level
            copy.rowButtons = item.rowButtons
            return copy
        }
        filteredRoots = roots[selectedIndex].compactMap(keep)
    }

    /// Sets the selected navigator's filter text.
    public func setFilter(_ text: String) {
        _ = view
        filter.stringValue = text
        filterChanged()
    }
    private let selector = NSStackView()
    private var buttons: [NSButton] = []
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    /// The bottom bar's filter field, its leading options menu, and the
    /// two in-field toggles (reference-ui.md §2).
    public let filter = NSSearchField()
    /// The Coding Assistant pane: Ycode has no assistant, so a placeholder.
    public let assistantPlaceholder = NSTextField(wrappingLabelWithString: "Coding Assistant\n\nYcode does not include a coding assistant.")
    /// The left area's content changed (navigators ↔ Coding Assistant).
    public var onContentChange: (() -> Void)?
    public var showsCodingAssistant = false {
        didSet {
            if oldValue != showsCodingAssistant { onContentChange?() }
            guard isViewLoaded else { return }
            for v in view.subviews where v !== assistantPlaceholder { v.isHidden = showsCodingAssistant }
            assistantPlaceholder.isHidden = !showsCodingAssistant
            if !showsCodingAssistant { select(selectedIndex) }
        }
    }
    public let filterOptions = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The in-field toggles of the selected navigator, left to right
    /// (`NavigatorBars.specs`); unused ones are hidden.
    public let recentToggle = NSButton()
    public let sourceControlToggle = NSButton()
    public let thirdToggle = NSButton()
    public var toggleButtons: [NSButton] { [recentToggle, sourceControlToggle, thirdToggle] }
    let rowMenu = NSMenu(title: "Row")
    let toggleStack = NSStackView()
    private var optionsAfterLeftButton: NSLayoutConstraint!
    private var optionsAtEdge: NSLayoutConstraint!
    /// The Test navigator's header: the test-plan pop-up and the Mode
    /// radio buttons (Group by Test Hierarchy | Group by Tags).
    public let testHeader = NSStackView()
    public let testPlanPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    public let testModeControl = NSSegmentedControl(images: [NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: NavigatorBars.testModes[0])!,
                                                             NSImage(systemSymbolName: "tag", accessibilityDescription: NavigatorBars.testModes[1])!],
                                                    trackingMode: .selectOne, target: nil, action: nil)
    /// Source Control navigator: Changes | Repositories (reference-ui-4.md §2).
    public let sourceControlMode = NSSegmentedControl(labels: SourceControlNavigatorModel.modeTitles, trackingMode: .selectOne, target: nil, action: nil)
    public var onSourceControlMode: ((SourceControlNavigatorModel.Mode) -> Void)?
    /// A Source Control navigator row was clicked (its scmKey).
    public var onSourceControlRow: ((String) -> Void)?
    /// Files opened in this window (the Recent files toggle).
    public var recentFiles: [String] = [] { didSet { if filterRecent { applyProjectFilter() } } }
    public var filterRecent = false { didSet { syncToggleStates(); applyProjectFilter() } }
    public var filterSourceControl = false { didSet { syncToggleStates(); applyProjectFilter() } }
    public var filterText = "" { didSet { applyProjectFilter() } }
    private var unfilteredProject: [OutlineItem] = []
    /// Symbols of the workspace's files (no navigator since Bookmarks took
    /// its place; used by the jump bar and Open Quickly).
    public private(set) var symbolRows: [OutlineItem] = []
    /// The "+" button's menu per navigator (set by the window).
    public var addMenuItems: ((Int) -> [NSMenuItem])?
    /// The Find navigator's query field, shown only for that navigator.
    public let findField = NSSearchField()
    private var findHeight: NSLayoutConstraint!
    private var optionsHeight: NSLayoutConstraint!
    /// Find header (reference-ui-2.md §3): Mode › Kind › Match pop-ups and
    /// the "Aa" match-case toggle; under the field, the scope pop-up.
    public let findMode = NSPopUpButton(frame: .zero, pullsDown: false)
    public let findStyle = NSPopUpButton(frame: .zero, pullsDown: false)
    public let findMatch = NSPopUpButton(frame: .zero, pullsDown: false)
    public let findCaseToggle = NSButton(title: "Aa", target: nil, action: nil)
    public let findScope = NSPopUpButton(frame: .zero, pullsDown: false)
    public static let findModes = ["Find", "Replace"]
    public static let findKinds = ["Text", "Multiple Words", "Regular Expression", "Symbols", "Ancestor Types", "Descendent Types",
                                   "Conforming Types", "Call Hierarchy", "Asset References"]
    public static let findMatches = ["Containing", "Matching Word", "Starting With", "Ending With"]
    /// Ycode implements Find with Text and Regular Expression; the other
    /// modes and kinds are listed disabled.
    static let supportedKinds: Set<Int> = [0, 2]
    private let findOptions = NSStackView()
    private var scopeHeight: NSLayoutConstraint!
    private var reportScopeHeight: NSLayoutConstraint!
    /// The selected scope: the whole workspace, the current results' files,
    /// or one containing group (its path).
    public enum FindScope: Equatable { case workspace, currentResults, group(String) }
    public private(set) var findScopeValue: FindScope = .workspace
    private var lastResultFiles: [String] = []
    /// Called to list the groups containing the selected file, outermost first.
    public var containingGroups: (() -> [(name: String, path: String)])?
    private var lastQuery = ""

    public var findOptionsValue: WorkspaceSearch.Options {
        get {
            let m = findMatch.indexOfSelectedItem
            return WorkspaceSearch.Options(regularExpression: findStyle.indexOfSelectedItem == 2,
                                           wholeWord: m == 1, ignoreCase: findCaseToggle.state != .on,
                                           anchor: m == 2 ? .start : m == 3 ? .end : .none)
        }
        set {
            findStyle.selectItem(at: newValue.regularExpression ? 2 : 0)
            findMatch.selectItem(at: newValue.wholeWord ? 1 : newValue.anchor == .start ? 2 : newValue.anchor == .end ? 3 : 0)
            findCaseToggle.state = newValue.ignoreCase ? .off : .on
        }
    }
    /// The workspace tree, for find and symbols.
    private var workspaceRoot: NavigatorNode?
    public var onOpenReport: ((Int) -> Void)?

    public override func loadView() {
        let root = NSView()
        selector.orientation = .horizontal
        selector.distribution = .fillEqually
        selector.spacing = 0
        for (i, name) in CommandTable.navigators.enumerated() {
            let img = NSImage(systemSymbolName: Self.symbols[i], accessibilityDescription: "\(name) navigator")
                ?? NSImage(systemSymbolName: "circle", accessibilityDescription: name)!
            let b = NSButton(image: img, target: self, action: #selector(selectorClicked(_:)))
            b.isBordered = false
            b.tag = i
            b.toolTip = NavigatorBars.selectorToolTips[i]   // reference-ui-5.md §5.2
            b.setButtonType(.toggle)
            buttons.append(b)
            selector.addArrangedSubview(b)
        }

        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        column.resizingMask = .autoresizingMask
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = Self.rowSizeStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        rowMenu.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.preferredMaxLayoutWidth = 220
        filter.placeholderString = "Filter"
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(filterChanged)
        filterOptions.isBordered = false
        filterOptions.addItem(withTitle: "")
        filterOptions.item(at: 0)?.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter options")
        rebuildFilterOptionsMenu()
        for (i, b) in toggleButtons.enumerated() {
            b.setButtonType(.toggle)
            b.isBordered = false
            b.tag = i
            b.target = self
            b.action = #selector(toggleClicked(_:))
            toggleStack.addArrangedSubview(b)
        }
        toggleStack.spacing = 2

        let sep = NSBox.hairline()
        findField.placeholderString = "Find"
        findField.sendsWholeSearchString = true
        findField.target = self
        findField.action = #selector(findSubmitted)
        // §5.4: the search field keeps a recent-search history.
        findField.maximumRecents = 10
        findField.searchMenuTemplate = Self.recentSearchesMenu()
        for (i, (p, titles)) in [(findMode, Self.findModes), (findStyle, Self.findKinds), (findMatch, Self.findMatches)].enumerated() {
            p.autoenablesItems = false
            p.addItems(withTitles: titles)
            p.controlSize = .small
            p.font = .systemFont(ofSize: 10)
            p.isBordered = false
            p.target = self
            p.action = #selector(findOptionChanged)
            if i > 0 {
                let chevron = NSTextField(labelWithString: "›")
                chevron.textColor = .tertiaryLabelColor
                findOptions.addArrangedSubview(chevron)
            }
            findOptions.addArrangedSubview(p)
        }
        findMode.item(at: 1)?.isEnabled = false
        for i in Self.findKinds.indices where !Self.supportedKinds.contains(i) { findStyle.item(at: i)?.isEnabled = false }
        findCaseToggle.setButtonType(.pushOnPushOff)
        findCaseToggle.bezelStyle = .inline
        findCaseToggle.font = .systemFont(ofSize: 10)
        findCaseToggle.toolTip = "Case Sensitive"   // reference-ui-5.md §5.2
        findCaseToggle.target = self
        findCaseToggle.action = #selector(findOptionChanged)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        findOptions.addArrangedSubview(spacer)
        findOptions.addArrangedSubview(findCaseToggle)
        findOptions.spacing = 2
        findScope.controlSize = .small
        findScope.font = .systemFont(ofSize: 10)
        findScope.isBordered = false
        findScope.autoenablesItems = false
        findScope.target = self
        findScope.action = #selector(findScopeChosen)
        findScope.menu?.delegate = self
        rebuildScopeMenu()
        addBreakpointButton.isBordered = false
        addBreakpointButton.menu?.delegate = self
        rebuildAddMenu()
        for v in [selector, sep, findField, findOptions, findScope, reportScope, sourceControlMode, testHeader, scroll, emptyLabel, filter, addBreakpointButton, filterOptions, toggleStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        filterLeading = filter.leadingAnchor.constraint(equalTo: filterOptions.trailingAnchor, constant: 0)
        optionsAfterLeftButton = filterOptions.leadingAnchor.constraint(equalTo: addBreakpointButton.trailingAnchor, constant: 2)
        optionsAtEdge = filterOptions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            selector.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            selector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            selector.heightAnchor.constraint(equalToConstant: 26),
            sep.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 2),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findOptions.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 2),
            findOptions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            findOptions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            findField.topAnchor.constraint(equalTo: findOptions.bottomAnchor, constant: 2),
            findField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            findField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            findScope.topAnchor.constraint(equalTo: findField.bottomAnchor, constant: 2),
            findScope.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            reportScope.topAnchor.constraint(equalTo: findScope.bottomAnchor, constant: 2),
            reportScope.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sourceControlMode.topAnchor.constraint(equalTo: reportScope.topAnchor),
            sourceControlMode.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sourceControlMode.heightAnchor.constraint(equalTo: reportScope.heightAnchor),
            testHeader.topAnchor.constraint(equalTo: reportScope.topAnchor),
            testHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            testHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            testHeader.heightAnchor.constraint(equalTo: reportScope.heightAnchor),
            scroll.topAnchor.constraint(equalTo: reportScope.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: filter.topAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -24),
            addBreakpointButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            addBreakpointButton.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            addBreakpointButton.widthAnchor.constraint(equalToConstant: 34),
            optionsAfterLeftButton,
            filterOptions.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            filterOptions.widthAnchor.constraint(equalToConstant: 32),
            filterLeading,
            toggleStack.leadingAnchor.constraint(equalTo: filter.trailingAnchor, constant: 2),
            toggleStack.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            toggleStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            filter.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        findHeight = findField.heightAnchor.constraint(equalToConstant: 0)
        findHeight.isActive = true
        optionsHeight = findOptions.heightAnchor.constraint(equalToConstant: 0)
        optionsHeight.isActive = true
        scopeHeight = findScope.heightAnchor.constraint(equalToConstant: 0)
        scopeHeight.isActive = true
        reportScopeHeight = reportScope.heightAnchor.constraint(equalToConstant: 0)
        reportScopeHeight.isActive = true
        reportScope.selectedSegment = 0
        for (i, t) in NavigatorBars.reportScopeToolTips.enumerated() { reportScope.setToolTip(t, forSegment: i) }
        reportScope.target = self
        reportScope.action = #selector(reportScopeChanged)
        reportScope.controlSize = .small
        reportScope.isHidden = true
        configureTestHeader()
        sourceControlMode.controlSize = .small
        sourceControlMode.selectedSegment = 0
        sourceControlMode.isHidden = true
        sourceControlMode.target = self
        sourceControlMode.action = #selector(sourceControlModeChanged)
        assistantPlaceholder.alignment = .center
        assistantPlaceholder.textColor = .secondaryLabelColor
        assistantPlaceholder.isHidden = true
        assistantPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(assistantPlaceholder)
        NSLayoutConstraint.activate([
            assistantPlaceholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            assistantPlaceholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            assistantPlaceholder.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
        ])
        view = root
        select(0)
    }

    // MARK: Content

    /// The project tree, then the Package Dependencies section (if any).
    public func setProjectTree(_ node: NavigatorNode, packages: NavigatorNode? = nil) {
        workspaceRoot = node
        let hide = Preferences.shared.fileExtensions == .hide
        unfilteredProject = [OutlineItem(node, hideExtensions: hide)] + (packages.map { [OutlineItem($0, hideExtensions: hide)] } ?? [])
        // The rebuilt rows keep the last status letters (the source-control
        // status is read in the background and arrives once per change).
        applyBadges()
        applyProjectFilter()
    }

    /// The project tree with the bottom bar's filters applied: file rows
    /// whose name contains the text, opened in this window (Recent), or
    /// with a source-control status; groups stay when a row under them does.
    func applyProjectFilter() {
        let text = filterText.lowercased()
        let active = !text.isEmpty || filterRecent || filterSourceControl
        func keep(_ item: OutlineItem) -> OutlineItem? {
            if item.children.isEmpty {
                guard item.path != nil else { return active ? nil : item }
                let ok = (text.isEmpty || item.title.lowercased().contains(text))
                    && (!filterRecent || recentFiles.contains(item.path!))
                    && (!filterSourceControl || fileBadges[item.path!] != nil)
                return ok ? item : nil
            }
            let kids = item.children.compactMap(keep)
            if !active { return item }
            guard !kids.isEmpty else { return nil }
            let copy = OutlineItem(title: item.title, symbol: item.symbol, tint: item.tint, children: kids, path: item.path, line: item.line,
                                   frameID: item.frameID, reportIndex: item.reportIndex)
            copy.badge = item.badge
            copy.detail = item.detail
            copy.reportPage = item.reportPage
            return copy
        }
        roots[0] = active ? unfilteredProject.compactMap(keep) : unfilteredProject
        reloadIfShowing(0)
        if isViewLoaded && selectedIndex == 0 { if active { outline.expandItem(nil, expandChildren: true) } else { restoreProjectExpansion() } }
    }

    // MARK: Project navigator expansion (reference-ui-5.md §5.1, N4)

    /// The saved expansion (expansion keys); nil at first open, when the
    /// root and its first group are expanded.
    public var savedProjectExpansion: [String]?
    /// Called when the user expands or collapses a project row.
    public var onProjectExpansionChange: (([String]) -> Void)?
    private var restoringExpansion = false
    private var projectFilterActive: Bool { !filterText.isEmpty || filterRecent || filterSourceControl }

    /// Expands the project rows: the saved set, or the first-open default.
    func restoreProjectExpansion() {
        guard let root = workspaceRoot else { return }
        let keys = Set(savedProjectExpansion ?? NavigatorTree.initiallyExpanded(root))
        restoringExpansion = true
        defer { restoringExpansion = false }
        func expand(_ items: [OutlineItem]) {
            for i in items where i.expansionKey.map(keys.contains) == true {
                outline.expandItem(i)
                expand(i.children)
            }
        }
        expand(roots[0])
    }

    /// The expansion keys of the expanded project rows, in tree order.
    public var projectExpansion: [String] {
        guard isViewLoaded, selectedIndex == 0 else { return savedProjectExpansion ?? [] }
        var out: [String] = []
        func walk(_ items: [OutlineItem]) {
            for i in items where outline.isItemExpanded(i) {
                if let k = i.expansionKey { out.append(k) }
                walk(i.children)
            }
        }
        walk(roots[0])
        return out
    }

    private func projectExpansionChanged() {
        guard selectedIndex == 0, !restoringExpansion, !projectFilterActive else { return }
        let now = projectExpansion
        savedProjectExpansion = now
        onProjectExpansionChange?(now)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) { projectExpansionChanged() }
    public func outlineViewItemDidCollapse(_ notification: Notification) { projectExpansionChanged() }

    @objc private func filterChanged() {
        filterTexts[selectedIndex] = filter.stringValue
        if selectedIndex == 0 { filterText = filter.stringValue; return }
        refilter()
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        updateEmpty()
    }
    @objc private func toggleClicked(_ b: NSButton) {
        setToggle(selectedIndex, b.tag, !toggleValue(selectedIndex, b.tag))
    }
    /// Filter options ▸ a toggle's item (tag = toggle index).
    @objc private func toggleMenuChosen(_ item: NSMenuItem) {
        setToggle(selectedIndex, item.tag, !toggleValue(selectedIndex, item.tag))
    }

    /// The bottom bar of navigator `index` (reference-ui-5.md §5.2): the
    /// left pull-down (or none, and the filter takes the width), the
    /// in-field toggles, the filter's placeholder and options menu.
    func configureToggles(_ index: Int) {
        let spec = NavigatorBars.specs[index]
        rebuildFilterOptionsMenu()
        if index != 4 || issueModel.tokens.isEmpty { filter.placeholderString = NavigatorBars.filterPlaceholder }
        for (i, b) in toggleButtons.enumerated() {
            guard i < spec.toggles.count else { b.isHidden = true; continue }
            let t = spec.toggles[i]
            b.isHidden = false
            b.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            b.setAccessibilityLabel(t.title)
            b.toolTip = t.toolTip
        }
        syncToggleStates()
        // The left button.
        let left = spec.left
        addBreakpointButton.isHidden = left == .none
        optionsAfterLeftButton.isActive = left != .none
        optionsAtEdge.isActive = left == .none
        let (symbol, tip): (String, String?) = switch left {
        case .add(let t): ("plus", t)
        case .more: ("ellipsis.circle", "More")
        case .pullDown, .none: ("chevron.down.circle", nil)
        }
        addBreakpointButton.menu?.item(at: 0)?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip ?? "Options")
        addBreakpointButton.toolTip = tip
    }

    /// The toggle buttons show the selected navigator's values.
    func syncToggleStates() {
        guard isViewLoaded else { return }
        for (i, b) in toggleButtons.enumerated() where !b.isHidden { b.state = toggleValue(selectedIndex, i) ? .on : .off }
    }

    /// The value of toggle `i` of navigator `nav`.
    public func toggleValue(_ nav: Int, _ i: Int) -> Bool {
        switch (nav, i) {
        case (0, 0): filterRecent
        case (0, 1): filterSourceControl
        case (2, 0): bookmarksIncompleteOnly
        case (4, 0): issuesRecentOnly
        case (4, 1): issuesErrorsOnly
        case (5, 0): testsIncludedOnly
        case (5, 1): testsRecentOnly
        case (6, 0): compressedStackFrames
        case (6, 1): interestingContentOnly
        case (6, 2): runningBlocksOnly
        case (7, 0): breakpointFilter.customizedOnly
        case (7, 1): breakpointFilter.enabledOnly
        case (8, 0): reportsRecentOnly
        default: false
        }
    }

    /// Sets toggle `i` of navigator `nav` and refilters that navigator.
    public func setToggle(_ nav: Int, _ i: Int, _ on: Bool) {
        switch (nav, i) {
        case (0, 0): filterRecent = on
        case (0, 1): filterSourceControl = on
        case (2, 0): bookmarksIncompleteOnly = on
        case (4, 0): issuesRecentOnly = on
        case (4, 1): issuesErrorsOnly = on
        case (5, 0): testsIncludedOnly = on
        case (5, 1): testsRecentOnly = on
        case (6, 0): compressedStackFrames = on
        case (6, 1): interestingContentOnly = on
        case (6, 2): runningBlocksOnly = on
        case (7, 0): breakpointFilter.customizedOnly = on; if let s = lastBreakpointStore { setBreakpoints(s) }
        case (7, 1): breakpointFilter.enabledOnly = on; if let s = lastBreakpointStore { setBreakpoints(s) }
        case (8, 0): reportsRecentOnly = on
        default: return
        }
        syncToggleStates()
        if nav == selectedIndex { rebuildFilterOptionsMenu() }
    }

    /// The empty state the selected navigator shows now (no lines when it
    /// has rows or has no empty state).
    public var emptyStateLines: [String] {
        guard isViewLoaded, !emptyLabel.isHidden else { return [] }
        return emptyLabel.stringValue.components(separatedBy: "\n")
    }

    /// The "+" menu: the window's items for this navigator, else (for
    /// Breakpoints) the breakpoint kinds.
    func rebuildAddMenu() {
        guard let menu = addBreakpointButton.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        if selectedIndex == 7 {
            for (i, t) in DebugNavigatorRows.addKinds.map(\.0).enumerated() {
                let item = NSMenuItem(title: t, action: #selector(addBreakpointChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        } else {
            for item in addMenuItems?(selectedIndex) ?? [] { menu.addItem(item) }
        }
    }

    /// The "+" menu's titles (tests).
    public var addMenuTitles: [String] { (addBreakpointButton.menu?.items.dropFirst() ?? []).map(\.title) }

    /// Bookmarks navigator: by file, then each bookmark (line and label).
    /// Done bookmarks carry a check badge; Incomplete Items hides them
    /// (reference-ui-5.md §5.2).
    public func setBookmarks(_ list: [Bookmark]) {
        allBookmarks = list
        let shown = bookmarksIncompleteOnly ? list.filter { $0.done != true } : list
        let byFile = Dictionary(grouping: shown, by: \.file)
        roots[2] = byFile.keys.sorted().map { file in
            OutlineItem(title: URL(fileURLWithPath: file).lastPathComponent, symbol: OutlineItem.fileSymbol(file), children: byFile[file]!.map { b in
                let row = OutlineItem(title: b.line.map { "\(b.label) — line \($0)" } ?? b.label, symbol: "bookmark.fill", tint: .systemBlue,
                                      path: b.file, line: b.line)
                row.maxLines = Preferences.shared.bookmarkNavigatorDetail
                row.bookmark = b
                if b.done == true { row.trailingSymbol = "checkmark.circle.fill"; row.trailingTint = .secondaryLabelColor }
                return row
            }, path: byFile[file]!.contains { $0.line == nil } ? file : nil)
        }
        reloadIfShowing(2)
        if selectedIndex == 2 { outline.expandItem(nil, expandChildren: true) }
    }

    /// The issue navigator lists issues grouped by file; issues without a
    /// file come last, directly under the root (N9).
    /// The workspace name (the Issue navigator's root row).
    public var workspaceName = ""
    /// Issue navigator toggles (reference-ui-2.md §1): only issues from
    /// open documents and recently built sources; only errors.
    public var issuesRecentOnly = false { didSet { syncToggleStates(); setIssues(allIssues) } }
    public var issuesErrorsOnly = false { didSet { syncToggleStates(); setIssues(allIssues) } }
    private var allIssues: [Diagnostic] = []

    /// Issue navigator (reference-ui-2.md §1): the workspace root with
    /// "N issues", one group per file (named without its extension,
    /// sorted by name), issues in compiler order wrapping to three lines.
    public func setIssues(_ issues: [Diagnostic]) {
        allIssues = issues
        issueModel.errorsOnly = issuesErrorsOnly
        let recent = issuesRecentOnly ? recentFiles : nil
        let entries = issueModel.entries(fresh: issues, keepFile: { recent?.contains($0) ?? true })
        func issueRow(_ e: IssueNavigatorModel.Entry) -> OutlineItem {
            let d = e.diagnostic
            let row = OutlineItem(title: d.message,
                                  symbol: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                                  tint: e.isStale ? .tertiaryLabelColor : (d.severity == .error ? Theme.errorColor : Theme.warningColor),
                                  path: d.location?.file, line: d.location?.line)
            row.maxLines = Preferences.shared.issueNavigatorDetail
            return row
        }
        // File groups, then the issues without a file as rows directly
        // under the root (reference-ui-5.md §5.3.1, N9).
        let fileGroups = IssueNavigatorModel.groups(entries).map { g in
            OutlineItem(title: g.title, symbol: OutlineItem.fileSymbol(g.file), children: g.entries.map(issueRow))   // §5.3.3
        } + IssueNavigatorModel.rootEntries(entries).map(issueRow)
        let count = entries.count
        if count == 0 {
            roots[4] = []
        } else {
            let root = OutlineItem(title: workspaceName.isEmpty ? "Workspace" : workspaceName, symbol: "shippingbox", children: fileGroups)
            root.detail = "\(count) issue\(count == 1 ? "" : "s")"
            roots[4] = [root]
        }
        refilter()
        reloadIfShowing(4)
        if selectedIndex == 4 { outline.expandItem(nil, expandChildren: true) }
    }

    /// Stale tracking and filter tokens (reference-ui-2.md §1.5, §1.8).
    public var issueModel = IssueNavigatorModel()
    /// Call when a build finishes; `full` clears stale issues;
    /// `compiledFiles` are the file names it compiled (nil: unknown).
    public func issuesBuildFinished(_ issues: [Diagnostic], full: Bool, compiledFiles: Set<String>? = nil) {
        issueModel.finishBuild(issues, full: full, compiledFiles: compiledFiles)
        setIssues(issues)
    }

    /// Call when a build starts: the last build's issues stay, stale.
    public func issuesBuildStarted() {
        issueModel.startBuild()
        setIssues(allIssues)
    }

    /// The filter-options menu for the Issue navigator (§1.8), else the
    /// Project navigator's items.
    func rebuildFilterOptionsMenu() {
        guard let menu = filterOptions.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        func add(_ title: String, _ sel: Selector, tag: Int = 0, state: Bool = false) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.tag = tag; i.state = state ? .on : .off
            menu.addItem(i)
        }
        if selectedIndex == 4 {
            for (n, (section, items)) in IssueNavigatorModel.menuSections.enumerated() {
                if n > 0 { menu.addItem(.separator()) }
                if !section.isEmpty { menu.addItem(.sectionHeader(title: section)) }
                for (k, t) in items.enumerated() { add(t, #selector(issueFilterChosen(_:)), tag: n * 10 + k, state: n == 0 && issueModel.deprecationOnly) }
            }
        } else {
            for (i, t) in NavigatorBars.specs[selectedIndex].toggles.enumerated() {
                add(t.menuTitle, #selector(toggleMenuChosen(_:)), tag: i, state: toggleValue(selectedIndex, i))
            }
            if selectedIndex == 6 {
                // The process view options (reference-ui-4.md §5.3).
                menu.addItem(.separator())
                add("View Process by Queue", #selector(debugViewOptionChosen(_:)), tag: 0, state: showThreadsByQueue)
                add("Show Gauges", #selector(debugViewOptionChosen(_:)), tag: 1, state: showsGauges)
            }
        }
    }
    /// The filter-options menu's titles (tests).
    public var filterOptionTitles: [String] { (filterOptions.menu?.items.dropFirst() ?? []).map { $0.isSeparatorItem ? "-" : $0.title } }

    @objc func issueFilterChosen(_ item: NSMenuItem) { chooseIssueFilter(tag: item.tag) }
    /// Applies a filter-options item by tag (section * 10 + index).
    public func chooseIssueFilter(tag: Int) {
        switch tag {
        case 0: issueModel.deprecationOnly.toggle()
        case 10: issueModel.addToken(.kind("Build"))
        case 11: issueModel.addToken(.notDeprecation)
        case 20: issueModel.clearRecents(); issueModel.tokens = []
        default: return
        }
        filter.placeholderString = issueModel.tokens.isEmpty ? "Filter" : issueModel.tokens.map(\.title).joined(separator: " ")
        rebuildFilterOptionsMenu()
        setIssues(allIssues)
    }

    public enum NewBreakpointKind { case exception, swiftError, symbolic, runtimeIssue, constraintError, testFailure }
    /// The breakpoint navigator's + menu.
    public var onAddBreakpoint: ((NewBreakpointKind) -> Void)?
    let addBreakpointButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var filterLeading: NSLayoutConstraint!

    @objc func addBreakpointChosen(_ sender: NSMenuItem) {
        onAddBreakpoint?(DebugNavigatorRows.addKinds[sender.tag].1)
    }

    public func setBreakpoints(_ store: BreakpointStore) {
        lastBreakpointStore = store
        roots[7] = DebugNavigatorRows.breakpointTree(project: workspaceName.isEmpty ? "Workspace" : workspaceName, store: store,
                                                     watchpoints: watchpointRows, ids: breakpointIDs, filter: breakpointFilter)
        reloadIfShowing(7)
        if selectedIndex == 7 { outline.expandItem(nil, expandChildren: true) }
    }

    /// Runs a workspace search and shows the results grouped by file.
    public func find(_ query: String) {
        _ = view
        findField.stringValue = query
        lastQuery = query
        guard let root = workspaceRoot else { return }
        var results: [WorkspaceSearch.FileResult]
        switch findScopeValue {
        case .workspace: results = WorkspaceSearch.search(query, in: root, options: findOptionsValue)
        case .group(let dir):
            results = WorkspaceSearch.search(query, in: root, options: findOptionsValue, limit: 100_000).filter { $0.path.hasPrefix(dir + "/") }
        case .currentResults:
            let keep = Set(lastResultFiles)
            results = WorkspaceSearch.search(query, in: root, options: findOptionsValue, limit: 100_000).filter { keep.contains($0.path) }
        }
        if findScopeValue != .currentResults { lastResultFiles = results.map(\.path) }
        roots[3] = results.map { f in
            OutlineItem(title: "\(URL(fileURLWithPath: f.path).lastPathComponent)  (\(f.matches.count))", symbol: "doc.text",
                        children: f.matches.map { m in
                            let row = OutlineItem(title: m.text, symbol: "text.magnifyingglass", tint: .secondaryLabelColor, path: f.path, line: m.line)
                            row.maxLines = Preferences.shared.findNavigatorDetail
                            return row
                        })
        }
        reloadIfShowing(3)
        if selectedIndex == 3 { outline.expandItem(nil, expandChildren: true) }
    }

    /// Shows a symbol search (references or call hierarchy) in the Find
    /// navigator: a heading row, then its tree.
    public func showSymbolResults(title: String, symbol: String, children: [OutlineItem]) {
        _ = view
        roots[3] = [OutlineItem(title: title, symbol: symbol, children: children)]
        select(3)
        outline.expandItem(nil, expandChildren: true)
    }

    @objc private func findSubmitted() {
        let q = findField.stringValue
        if !q.isEmpty { noteRecentSearch(q) }
        find(q)
    }

    /// The Find field's recent searches, newest first (§5.4).
    public var recentSearches: [String] { findField.recentSearches }
    public func noteRecentSearch(_ q: String) {
        findField.recentSearches = Array(([q] + findField.recentSearches.filter { $0 != q }).prefix(findField.maximumRecents))
    }

    /// The search field's menu: Recent Searches, the entries, Clear.
    static func recentSearchesMenu() -> NSMenu {
        let m = NSMenu(title: "Recent Searches")
        let title = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        m.addItem(title)
        let recents = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recents.tag = NSSearchField.recentsMenuItemTag
        m.addItem(recents)
        let none = NSMenuItem(title: "No Recent Searches", action: nil, keyEquivalent: "")
        none.tag = NSSearchField.noRecentsMenuItemTag
        m.addItem(none)
        let sep = NSMenuItem.separator()
        sep.tag = NSSearchField.recentsTitleMenuItemTag
        m.addItem(sep)
        let clear = NSMenuItem(title: "Clear Recent Searches", action: nil, keyEquivalent: "")
        clear.tag = NSSearchField.clearRecentsMenuItemTag
        m.addItem(clear)
        return m
    }

    /// The scope menu (reference-ui-2.md §3.5): the workspace (Package or
    /// Project), its dependencies (disabled), Current Find Results,
    /// Containing Groups of the selected file, Custom Scopes… (disabled).
    func rebuildScopeMenu() {
        guard let menu = findScope.menu else { return }
        menu.removeAllItems()
        let unit = isPackage ? "Package" : (isWorkspace ? "Workspace" : "Project")   // reference-ui-5.md §5.4
        func add(_ title: String, enabled: Bool, tag: Int, path: String? = nil) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = enabled
            i.tag = tag
            i.representedObject = path
            menu.addItem(i)
        }
        add(unit, enabled: true, tag: 0)
        add("\(unit) Dependencies", enabled: false, tag: -1)
        add("\(unit) and \(unit) Dependencies", enabled: false, tag: -1)
        menu.addItem(.separator())
        add("Current Find Results", enabled: !lastResultFiles.isEmpty, tag: 1)
        let groups = containingGroups?() ?? []
        if !groups.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Containing Groups"))
            for g in groups { add(g.name, enabled: true, tag: 2, path: g.path) }
        }
        menu.addItem(.separator())
        add("Custom Scopes…", enabled: false, tag: -1)
        let title: String
        switch findScopeValue {
        case .workspace: title = unit
        case .currentResults: title = "Current Find Results"
        case .group(let p): title = groups.first { $0.path == p }?.name ?? URL(fileURLWithPath: p).lastPathComponent
        }
        if let item = menu.items.first(where: { $0.title == title }) { findScope.select(item) }
        if let cell = findScope.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: "In " + title, action: nil, keyEquivalent: "")
        }
    }

    /// Whether the workspace is a package (scope titles say "Package"), or
    /// a workspace file ("Workspace"); otherwise a project ("Project").
    public var isPackage = false
    public var isWorkspace = false

    public func setFindScope(_ s: FindScope) {
        findScopeValue = s
        rebuildScopeMenu()
        if !lastQuery.isEmpty { find(lastQuery) }
    }

    @objc private func findScopeChosen() {
        guard let item = findScope.selectedItem else { return }
        switch item.tag {
        case 1: setFindScope(.currentResults)
        case 2: if let p = item.representedObject as? String { setFindScope(.group(p)) }
        default: setFindScope(.workspace)
        }
    }
    /// Changing an option re-runs the last search.
    @objc private func findOptionChanged() { if !lastQuery.isEmpty { find(lastQuery) } }

    /// Collects the workspace's symbols: files with their declarations.
    public func refreshSymbols() {
        guard let root = workspaceRoot else { return }
        symbolRows = root.allFiles.compactMap { file -> OutlineItem? in
            guard let path = file.path else { return nil }
            let lang = SourceTokenizer.Language(fileName: file.name)
            guard lang != .plain, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let syms = SymbolScanner.symbols(in: text, language: lang)
            guard !syms.isEmpty else { return nil }
            @MainActor func item(_ s: SymbolScanner.Symbol) -> OutlineItem {
                OutlineItem(title: s.name, symbol: Self.symbolGlyph(s.kind), tint: Self.symbolTint(s.kind),
                            children: s.children.map(item), path: path, line: s.line)
            }
            return OutlineItem(title: file.name, symbol: "doc.text", children: syms.map(item))
        }
    }

    /// Letter badges in our own style: C class, S struct, E enum, P protocol,
    /// X extension, A actor, F function, T typealias, M macro.
    static func symbolGlyph(_ k: SymbolScanner.Symbol.Kind) -> String {
        switch k {
        case .class, .interface, .implementation: "c.square.fill"
        case .struct: "s.square.fill"
        case .enum: "e.square.fill"
        case .protocol: "p.square.fill"
        case .extension: "x.square.fill"
        case .actor: "a.square.fill"
        case .function: "f.square.fill"
        case .typealias: "t.square.fill"
        case .macro: "m.square.fill"
        case .property: "v.square.fill"
        case .enumCase: "e.square"
        case .initializer: "i.square.fill"
        }
    }

    static func symbolTint(_ k: SymbolScanner.Symbol.Kind) -> NSColor {
        switch k {
        case .function, .initializer: .systemBlue
        case .property, .enumCase: .systemTeal
        case .protocol, .extension: .systemOrange
        default: .systemPurple
        }
    }

    /// Report navigator (reference-ui-2.md §4): one group per scheme,
    /// then "Package"; rows "<action>  <day>, <time>", newest first, with an
    /// error badge when failed; a test run is "<scheme>/<plan>" with
    /// Insights, Coverage, Tests, Log and Build under it. The Local | Cloud
    /// switch and the clock (recent only) toggle filter the rows.
    public func setReports(_ reports: [BuildReport]) {
        allReports = reports
        let location: ReportLocation = reportScope.selectedSegment == 1 ? .cloud : .local
        func item(_ r: ReportNavigatorModel.Row) -> OutlineItem {
            let o = OutlineItem(title: r.title, symbol: r.symbol, tint: r.failed ? Theme.errorColor : .secondaryLabelColor,
                                children: r.children.map(item), reportIndex: r.index)
            o.reportPage = r.page
            o.detail = r.detail
            o.badge = r.badge
            return o
        }
        roots[8] = ReportNavigatorModel.groups(reports, location: location, recentOnly: reportsRecentOnly).map {
            OutlineItem(title: $0.title, symbol: $0.isPackage ? "shippingbox" : "square.stack.3d.up", children: $0.rows.map(item))
        }
        if selectedIndex == 8 { refilter() }
        reloadIfShowing(8)
        if selectedIndex == 8 { outline.expandItem(nil, expandChildren: false); for g in shownRoots { outline.expandItem(g) } }
    }
    private var allReports: [BuildReport] = []
    /// The Report navigator's clock toggle: only reports from the last day.
    public var reportsRecentOnly = false { didSet { syncToggleStates(); setReports(allReports) } }
    @objc private func reportScopeChanged() { setReports(allReports) }

    /// Report navigator's Local | Cloud control (Cloud: not available).
    public let reportScope = NSSegmentedControl(labels: ["Local", "Cloud"], trackingMode: .selectOne, target: nil, action: nil)
    /// Called with a report and a page ("Insights", "Coverage", "Tests", "Log", "Build").
    public var onOpenReportPage: ((Int, String) -> Void)?

    /// The Test navigator: files, then classes/suites, then tests, each
    /// with a diamond showing the last result.
    /// The test plan's name (the Test navigator's root).
    public var testPlanName = "Tests" {
        didSet { if isViewLoaded { testPlanPopUp.removeAllItems(); testPlanPopUp.addItem(withTitle: testPlanName) } }
    }
    /// The test target a file belongs to.
    public var testTarget: ((String) -> String)?

    /// Test navigator (reference-ui-2.md §6): the plan, then each test
    /// target, then suites and test functions with parentheses; plan and
    /// target rows add "N Tests, M Failing".
    public func setTests(_ tests: [DiscoveredTest], results: [DiscoveredTest: TestOutcome.Status]) {
        lastTests = (tests, results)
        refreshTests()
    }

    /// The Test navigator from the last tests, with its toggles and mode
    /// applied (reference-ui-5.md §5.2). Status diamonds sit at the rows'
    /// right end.
    func refreshTests() {
        var (tests, results) = lastTests
        if testsIncludedOnly { tests = tests.filter { !skippedTests.contains($0.identifier) } }
        if testsRecentOnly {
            let open = Set(recentFiles)
            tests = tests.filter { open.contains($0.file) || results[$0] != nil }
        }
        func diamond(_ s: TestOutcome.Status?) -> (String, NSColor) {
            switch s {
            case .passed?: ("checkmark.diamond.fill", .systemGreen)
            case .failed?: ("xmark.diamond.fill", Theme.errorColor)
            case .skipped?: ("arrow.right.circle", .secondaryLabelColor)
            case nil: ("diamond", .secondaryLabelColor)
            }
        }
        func state(_ list: [DiscoveredTest]) -> TestOutcome.Status? {
            let all = list.map { results[$0] }
            return all.contains(.failed) ? .failed : (!all.isEmpty && all.allSatisfy { $0 == .passed } ? .passed : nil)
        }
        func counts(_ list: [DiscoveredTest]) -> String {
            let failing = list.filter { results[$0] == .failed }.count
            return "\(list.count) Test\(list.count == 1 ? "" : "s"), \(failing) Failing"
        }
        var targets: [(String, [DiscoveredTest])] = []
        for t in tests {
            let name = testTarget?(t.file) ?? URL(fileURLWithPath: t.file).deletingLastPathComponent().lastPathComponent
            if let i = targets.firstIndex(where: { $0.0 == name }) { targets[i].1.append(t) } else { targets.append((name, [t])) }
        }
        let targetRows = targets.map { target, list -> OutlineItem in
            var suites: [(String, [DiscoveredTest])] = []
            for t in list {
                let key = t.suite ?? ""
                if let i = suites.firstIndex(where: { $0.0 == key }) { suites[i].1.append(t) } else { suites.append((key, [t])) }
            }
            let rows: [OutlineItem] = suites.flatMap { suite, members -> [OutlineItem] in
                let leaves = members.map { leaf($0) }
                if suite.isEmpty { return leaves }
                return [row(suite, "c.square", members, children: leaves, path: members.first?.file, line: members.first?.suiteLine)]
            }
            let r = row(target, "scope", list, children: rows)
            r.detail = counts(list)
            return r
        }
        func leaf(_ t: DiscoveredTest) -> OutlineItem {
            let item = OutlineItem(title: "\(t.name)()", symbol: "t.square", tint: .secondaryLabelColor, path: t.file, line: t.line)
            (item.trailingSymbol, item.trailingTint) = diamond(results[t])
            return item
        }
        func row(_ title: String, _ symbol: String, _ members: [DiscoveredTest], children: [OutlineItem], path: String? = nil, line: Int? = nil) -> OutlineItem {
            let item = OutlineItem(title: title, symbol: symbol, tint: .secondaryLabelColor, children: children, path: path, line: line)
            (item.trailingSymbol, item.trailingTint) = diamond(state(members))
            return item
        }
        if tests.isEmpty {
            roots[5] = []
        } else if groupTestsByTags {
            // Group by Tags: one group per swift-testing tag, then Untagged Tests.
            var texts: [String: String] = [:]
            var byTag: [String: [DiscoveredTest]] = [:]
            var untagged: [DiscoveredTest] = []
            for t in tests {
                if texts[t.file] == nil { texts[t.file] = (try? String(contentsOfFile: t.file, encoding: .utf8)) ?? "" }
                let tags = TestTags.tags(of: t, text: texts[t.file]!)
                if tags.isEmpty { untagged.append(t) }
                for tag in tags { byTag[tag, default: []].append(t) }
            }
            var groups = byTag.keys.sorted().map { tag in row(tag, "tag", byTag[tag]!, children: byTag[tag]!.map(leaf)) }
            if !untagged.isEmpty { groups.append(row(NavigatorBars.untaggedTests, "tag.slash", untagged, children: untagged.map(leaf))) }
            let plan = row(testPlanName, "checklist", tests, children: groups)
            plan.detail = counts(tests)
            roots[5] = [plan]
        } else {
            let plan = row(testPlanName, "checklist", tests, children: targetRows)
            plan.detail = counts(tests)
            roots[5] = [plan]
        }
        testPlanPopUp.removeAllItems()
        testPlanPopUp.addItem(withTitle: testPlanName)
        reloadIfShowing(5)
        if selectedIndex == 5 { outline.expandItem(nil, expandChildren: true) }
    }

    /// Source-control state for badges: absolute path → letter.
    private var fileBadges: [String: String] = [:]

    /// Badges in the project navigator (M, A, ?, D, R, C), on file rows
    /// only: never on the project, group or folder rows
    /// (`reference-ui-5.md` §5.1, N3).
    public func setFileStatus(_ status: [String: GitRepository.FileStatus]) {
        fileBadges = status.mapValues(\.rawValue)
        defer { if filterSourceControl { applyProjectFilter() } }
        applyBadges()
        reloadIfShowing(0)
    }

    private func applyBadges() {
        func apply(_ item: OutlineItem) {
            item.children.forEach(apply)
            let isFile = item.nodeKind.map { $0 == .file } ?? item.children.isEmpty
            item.badge = isFile ? item.path.flatMap { fileBadges[$0] } : nil
        }
        unfilteredProject.forEach(apply)
    }

    @objc private func sourceControlModeChanged() {
        onSourceControlMode?(SourceControlNavigatorModel.Mode(rawValue: sourceControlMode.selectedSegment) ?? .changes)
    }

    /// Replaces the Source Control navigator's tree (Changes or Repositories).
    public func setSourceControlRoots(_ items: [OutlineItem]) {
        roots[1] = items
        reloadIfShowing(1)
        if selectedIndex == 1 { outline.expandItem(nil, expandChildren: true) }
    }

    /// The Source Control navigator: the repository, then Branches, Tags
    /// and Remotes (current branch marked).
    public func setRepository(name: String, branches: [GitRepository.Ref], tags: [GitRepository.Ref],
                              remotes: [GitRepository.Remote], remoteBranches: [GitRepository.Ref]) {
        let branchRows = branches.map { OutlineItem(title: $0.isCurrent ? "\($0.name) (current)" : $0.name, symbol: "arrow.triangle.branch") }
        let tagRows = tags.map { OutlineItem(title: $0.name, symbol: "tag") }
        let remoteRows = remotes.map { r in
            OutlineItem(title: r.name, symbol: "cloud", children: remoteBranches.filter { $0.name.hasPrefix(r.name + "/") }
                .map { OutlineItem(title: String($0.name.dropFirst(r.name.count + 1)), symbol: "arrow.triangle.branch") })
        }
        roots[1] = [OutlineItem(title: name, symbol: "externaldrive", children: [
            OutlineItem(title: "Branches", symbol: "folder", children: branchRows),
            OutlineItem(title: "Tags", symbol: "folder", children: tagRows),
            OutlineItem(title: "Remotes", symbol: "folder", children: remoteRows),
        ])]
        reloadIfShowing(1)
        if selectedIndex == 1 { outline.expandItem(nil, expandChildren: true) }
    }

    /// The Debug navigator: threads, each with its frames (only the stopped
    /// thread's frames are fetched). Rows carry the frame id in `line`'s
    /// place through `frameID`.
    /// Debug navigator: group threads by dispatch queue instead of listing them.
    public var showThreadsByQueue = false
    /// Debug navigator toggles (reference-ui-5.md §5.2): fold system
    /// frames (on), only the stopped thread and threads with user frames,
    /// only running blocks in the queue view (on).
    public var compressedStackFrames = true { didSet { refreshDebugTree() } }
    public var interestingContentOnly = false { didSet { refreshDebugTree() } }
    public var runningBlocksOnly = true { didSet { refreshDebugTree() } }
    /// Bookmark navigator: hide done bookmarks.
    public var bookmarksIncompleteOnly = false { didSet { setBookmarks(allBookmarks) } }
    var allBookmarks: [Bookmark] = []
    /// A bookmark row's context menu changed its done state.
    public var onSetBookmarkDone: ((Bookmark, Bool) -> Void)?
    /// Test navigator: only tests the active plan includes; only tests of
    /// open files and of the last run.
    public var testsIncludedOnly = false { didSet { refreshTests() } }
    public var testsRecentOnly = false { didSet { refreshTests() } }
    /// Tests the active test plan skips (identifiers); the autocreated plan skips none.
    public var skippedTests: Set<String> = [] { didSet { refreshTests() } }
    /// Group by Test Hierarchy (false) or Group by Tags (true).
    public var groupTestsByTags = false { didSet { testModeControl.selectedSegment = groupTestsByTags ? 1 : 0; refreshTests() } }
    var lastTests: ([DiscoveredTest], [DiscoveredTest: TestOutcome.Status]) = ([], [:])
    /// Debugger navigators' state (see NavigatorAreaController+Debug.swift).
    public var debugProcess: DebugProcessInfo?
    public var showsGauges = true
    var lastDebugState: ([DebugThread], Int?, [StackFrame]) = ([], nil, [])
    /// Adapter breakpoint ids ("n.m") by "file:line".
    public var breakpointIDs: [String: String] = [:]
    public var breakpointFilter = DebugNavigatorRows.BreakpointFilter()
    /// A click on a breakpoint row's enabled marker.
    public var onToggleBreakpointEnabled: ((String, Int) -> Void)?
    var lastBreakpointStoreForDebug: BreakpointStore? { lastBreakpointStore }
    /// Watchpoints shown in the Breakpoint navigator.
    private var watchpointRows: [OutlineItem] = []
    private var lastBreakpointStore: BreakpointStore?

    public func setWatchpoints(_ list: [Watchpoint]) {
        watchpointRows = list.isEmpty ? [] : [OutlineItem(title: "Watchpoints", symbol: "eye", children: list.map {
            OutlineItem(title: "\($0.name) (\($0.accessType))" + ($0.verified ? "" : " — not set"), symbol: "eye",
                        tint: $0.verified ? Theme.breakpointColor : .secondaryLabelColor)
        })]
        if let s = lastBreakpointStore { setBreakpoints(s) }
    }

    public func setDebugState(threads: [DebugThread], stoppedThread: Int?, frames: [StackFrame]) {
        lastDebugState = (threads, stoppedThread, frames)
        roots[6] = DebugNavigatorRows.debugTree(process: debugProcess, gauges: showsGauges, threads: threads, stoppedThread: stoppedThread, frames: frames,
                                                byQueue: showThreadsByQueue, compressed: compressedStackFrames, interestingOnly: interestingContentOnly,
                                                runningBlocksOnly: runningBlocksOnly)
        reloadIfShowing(6)
        if selectedIndex == 6 { outline.expandItem(nil, expandChildren: true) }
    }

    public var onSelectFrame: ((Int) -> Void)?

    /// The current rows of a navigator (for tests).
    public func rows(_ index: Int) -> [OutlineItem] { roots[index] }

    private func reloadIfShowing(_ i: Int) {
        guard isViewLoaded, selectedIndex == i else { return }
        refilter()
        outline.reloadData()
        updateEmpty()
    }

    // MARK: Selection

    public func select(_ index: Int) {
        selectedIndex = index
        filter.stringValue = filterTexts[index] ?? ""
        refilter()
        findHeight?.constant = index == 3 ? 22 : 0
        optionsHeight?.constant = index == 3 ? 18 : 0
        scopeHeight?.constant = index == 3 ? 18 : 0
        reportScopeHeight?.constant = index == 8 || index == 1 || index == 5 ? 20 : 0
        reportScope.isHidden = index != 8
        sourceControlMode.isHidden = index != 1
        testHeader.isHidden = index != 5
        // Only bookmark rows have a context menu (Mark as Done).
        outline.menu = index == 2 ? rowMenu : nil
        findScope.isHidden = index != 3
        findField.isHidden = index != 3
        findOptions.isHidden = index != 3
        rebuildAddMenu()
        configureToggles(index)
        for b in buttons { b.state = b.tag == index ? .on : .off; b.contentTintColor = b.tag == index ? .controlAccentColor : .secondaryLabelColor }
        outline.reloadData()
        if index != 0 { outline.expandItem(nil, expandChildren: true) } else if projectFilterActive { outline.expandItem(nil, expandChildren: true) } else { restoreProjectExpansion() }
        updateEmpty()
    }

    /// The navigator's empty state (reference-ui-5.md §5.2): a title and,
    /// for some, a second line in smaller text.
    private func updateEmpty() {
        let lines = NavigatorBars.specs[selectedIndex].emptyState
        emptyLabel.isHidden = !shownRoots.isEmpty || lines.isEmpty
        let text = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        for (i, l) in lines.enumerated() {
            text.append(NSAttributedString(string: (i > 0 ? "\n" : "") + l, attributes: [
                .font: i == 0 ? NSFont.systemFont(ofSize: 13, weight: .medium) : NSFont.systemFont(ofSize: 11),
                .foregroundColor: i == 0 ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor, .paragraphStyle: center,
            ]))
        }
        emptyLabel.attributedStringValue = text
    }

    @objc private func selectorClicked(_ sender: NSButton) { select(sender.tag) }

    /// The selected row's file, if any.
    public var selectedPath: String? {
        guard isViewLoaded, outline.selectedRow >= 0 else { return nil }
        return (outline.item(atRow: outline.selectedRow) as? OutlineItem)?.path
    }

    /// The selected row, if any (Product ▸ Perform Action ▸ Test runs the
    /// tests selected in the Test navigator).
    public var selectedItem: OutlineItem? {
        guard isViewLoaded, outline.selectedRow >= 0 else { return nil }
        return outline.item(atRow: outline.selectedRow) as? OutlineItem
    }

    @objc private func rowClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? OutlineItem else { return }
        if item.enabledMarker != nil, let path = item.path, let line = item.line, let e = NSApp.currentEvent,
           outline.convert(e.locationInWindow, from: nil).x > outline.bounds.maxX - 26 {
            onToggleBreakpointEnabled?(path, line)
            return
        }
        if let k = item.scmKey { onSourceControlRow?(k); return }
        if let f = item.frameID { onSelectFrame?(f) }
        if let r = item.reportIndex {
            if let page = item.reportPage { onOpenReportPage?(r, page) } else { onOpenReport?(r) }
        }
        if let path = item.path { onOpen?(path, item.line) }
    }

    // MARK: Outline data source

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OutlineItem)?.children.count ?? shownRoots.count
    }

    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? OutlineItem)?.children[index] ?? shownRoots[index]
    }

    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? OutlineItem)?.children.isEmpty ?? true)
    }

    public func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? OutlineItem else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
        image.contentTintColor = item.tint ?? .controlAccentColor
        let label = NSTextField(labelWithString: item.title)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: Self.rowFontSize)
        if item.maxLines > 0 {
            let selected = o.selectedRow >= 0 && o.item(atRow: o.selectedRow) as? OutlineItem === item
            label.maximumNumberOfLines = selected ? 0 : item.maxLines
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
            label.preferredMaxLayoutWidth = max(80, o.bounds.width - o.indentationPerLevel * CGFloat(o.level(forItem: item) + 1) - 30)
        }
        if item.middleTruncation { label.lineBreakMode = .byTruncatingMiddle }
        if item.dimmed { label.textColor = .secondaryLabelColor }
        if let detail = item.detail {
            label.attributedStringValue = NSAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: Self.rowFontSize)])
                + NSAttributedString(string: "  " + detail, attributes: [.font: NSFont.systemFont(ofSize: Self.rowFontSize - 1),
                                                                          .foregroundColor: NSColor.secondaryLabelColor])
        }
        for v in [image, label] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            item.maxLines > 0 ? label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2) : label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if item.maxLines > 0 { image.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = false }
        if let badge = item.badge {
            let b = NSTextField(labelWithString: badge)
            b.font = .boldSystemFont(ofSize: 10)
            b.textColor = .secondaryLabelColor
            if item.scmKey?.hasPrefix("change:") == true { b.wantsLayer = true; b.layer?.borderWidth = 1; b.layer?.cornerRadius = 3; b.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor; b.stringValue = " \(badge) " }
            b.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                b.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        if let on = item.enabledMarker { addEnabledMarker(on, to: cell) }
        if let level = item.level { addLevelBar(level, to: cell) }
        if !item.rowButtons.isEmpty { addRowButtons(item.rowButtons, to: cell) }
        if let t = item.trailingSymbol { addTrailingGlyph(t, tint: item.trailingTint, to: cell, label: label) }
        cell.textField = label
        cell.imageView = image
        return cell
    }
}

extension NavigatorAreaController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === findScope.menu { rebuildScopeMenu() } else if menu === rowMenu { rebuildRowMenu(menu) } else { rebuildAddMenu() }
    }

    /// The row context menu: for a bookmark, Mark as Done / Not Done.
    func rebuildRowMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let b = (outline.item(atRow: row) as? OutlineItem)?.bookmark else { return }
        for item in bookmarkMenuItems(b) { menu.addItem(item) }
    }
}

extension NavigatorAreaController {
    /// "Thread N — name": the adapter already formats names as
    /// "Thread <index>{ name = …}{ queue = …}" (debug.md), so that index is
    /// used and the rest becomes the detail; other names follow the id.
    public static func threadTitle(_ t: DebugThread) -> String {
        let name = t.name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("Thread ") {
            let rest = name.dropFirst("Thread ".count)
            let number = rest.prefix { $0.isNumber }
            if !number.isEmpty {
                let detail = rest.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
                return "Thread \(number)" + (detail.isEmpty ? "" : " — \(detail)")
            }
        }
        return "Thread \(t.id)" + (name.isEmpty ? "" : " — \(name)")
    }
}

func + (a: NSAttributedString, b: NSAttributedString) -> NSAttributedString {
    let m = NSMutableAttributedString(attributedString: a)
    m.append(b)
    return m
}

extension NavigatorAreaController {
    /// Wrapped rows (issues) are as tall as their text: up to `maxLines`
    /// lines, or all of it when selected.
    public func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? OutlineItem, item.maxLines > 0 else { return o.rowHeight }
        let width = max(80, o.bounds.width - o.indentationPerLevel * CGFloat(o.level(forItem: item) + 1) - 30)
        let font = NSFont.systemFont(ofSize: Self.rowFontSize)
        let full = (item.title as NSString).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        let selected = o.selectedRow >= 0 && o.item(atRow: o.selectedRow) as? OutlineItem === item
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let shown = selected ? full : min(full, lineHeight * CGFloat(item.maxLines))
        return max(o.rowHeight, ceil(shown) + 4)
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        // The selected issue (bookmark, find result) grows to show all of it.
        guard [2, 3, 4].contains(selectedIndex) else { return }
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
        let visible = outline.rows(in: outline.visibleRect)
        if visible.length > 0 { outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0]) }
    }
}

/// Settings ▸ General ▸ Navigator size and the navigators' detail lines
/// (reference-ui-5.md §9.1).
extension NavigatorAreaController {
    /// The effective size: "Use System Setting" follows the system's
    /// sidebar size (`NSTableViewDefaultSizeMode`: 1 small, 2 medium,
    /// 3 large; medium when unset).
    static var effectiveSize: Preferences.NavigatorSize {
        switch Preferences.shared.navigatorSize {
        case .system:
            switch UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode") {
            case 1: return .small
            case 3: return .large
            default: return .medium
            }
        case let s: return s
        }
    }

    static var rowSizeStyle: NSTableView.RowSizeStyle {
        switch effectiveSize { case .small: .small; case .large: .large; default: .medium }
    }

    /// The row font size: 11 / 13 / 15 points for small / medium / large.
    public static var rowFontSize: CGFloat {
        switch effectiveSize { case .small: 11; case .large: 15; default: 13 }
    }

    /// The outline's row size style (tests).
    public var rowSizeStyle: NSTableView.RowSizeStyle { outline.rowSizeStyle }

    /// Re-applies the size and the detail lines to the shown rows.
    public func applyDisplayPreferences() {
        guard isViewLoaded else { return }
        let p = Preferences.shared
        var changed = outline.rowSizeStyle != Self.rowSizeStyle
        outline.rowSizeStyle = Self.rowSizeStyle
        for (index, lines) in [(2, p.bookmarkNavigatorDetail), (3, p.findNavigatorDetail), (4, p.issueNavigatorDetail)] {
            func walk(_ items: [OutlineItem]) {
                for i in items {
                    if i.line != nil, i.children.isEmpty, i.maxLines != lines { i.maxLines = lines; changed = true }
                    walk(i.children)
                }
            }
            walk(rows(index))
        }
        guard changed, outline.numberOfRows > 0 else { return }
        let all = IndexSet(integersIn: 0..<outline.numberOfRows)
        outline.noteHeightOfRows(withIndexesChanged: all)
        outline.reloadData(forRowIndexes: all, columnIndexes: [0])
    }
}
