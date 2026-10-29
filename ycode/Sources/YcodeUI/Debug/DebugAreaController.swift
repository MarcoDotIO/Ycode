import AppKit
import YcodeSimFeatures
import YcodeDebug

/// A row of the variables view. Children load lazily on first expansion.
@MainActor
public final class VariableNode: NSObject {
    public let variable: Variable
    public internal(set) var children: [VariableNode]?
    init(_ v: Variable) { variable = v }
    public var isExpandable: Bool { variable.variablesReference != 0 }
}

/// The bottom debug area: the debug bar, then the variables view (left)
/// and the console (right). See `specs/ide/workspace-window.md` §Debug area.
@MainActor
public final class DebugAreaController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Debug-bar buttons: (symbol, tooltip, action).
    public static let barButtons: [(String, String, String)] = [
        ("tag", "Activate or deactivate breakpoints", "toggleBreakpointsActive:"),
        ("play", "Continue program execution", "pauseOrContinue:"),
        ("arrow.turn.down.right", "Step over", "stepOver:"),
        ("arrow.down.to.line", "Step into", "stepInto:"),
        ("arrow.up.to.line", "Step out", "stepOut:"),
    ] + extraBarButtons

    public private(set) var roots: [VariableNode] = []
    private var prefsObserver: NSObjectProtocol?

    /// The console's font and colors follow the theme.
    public func applyTheme() {
        consoleView.font = Theme.consoleFont
        consoleView.textColor = Theme.consoleTextColor
        consoleView.backgroundColor = Theme.consoleBackgroundColor
        consoleField.font = Theme.consoleFont
    }

    /// The console's current font (tests).
    public var consoleFont: NSFont? { _ = view; return consoleView.font }
    /// Fetches a variable's children by reference (set by the window).
    public var loadChildren: ((Int) async -> [Variable])?
    private let varsOutline = NSOutlineView()
    let consoleView = NSTextView()
    /// The console's input line (after the `(lldb)` prompt).
    public let consoleField = NSTextField(string: "")
    let filterPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The console filter (All / Debugger / Target Output).
    public private(set) var consoleFilter: ConsoleEntry.Filter = .all
    /// Called with a console line to evaluate.
    public var onConsoleLine: ((String) async -> Void)?
    /// Called when the filter changes (the window re-renders the console).
    public var onFilterChange: (() -> Void)?
    /// Previously entered lines, oldest first.
    public private(set) var history: [String] = []
    private var historyCursor: Int?
    /// Variables-view actions: (action, variable name, value/argument).
    public var onVariableAction: ((VariableAction, Variable) -> Void)?
    public enum VariableAction { case printDescription, copyValue, watch, watchRead, watchReadWrite, editValue, addExpression }
    /// The variables view's Registers toggle.
    public let registersCheck = NSButton(checkboxWithTitle: "Registers", target: nil, action: nil)
    let frameLabel = NSTextField(labelWithString: "")
    /// Debug bar, right: "Line: N Col: N" and the show/hide toggle.
    public let positionLabel = NSTextField(labelWithString: "")
    /// The debug bar (with its top hairline). The window places it under
    /// the editor so it stays visible while the debug area is hidden
    /// (reference-ui.md §3, §5).
    public let debugBar = NSView()
    /// The editor's bottom bar is translucent over the editor (macOS 26+).
    static var translucentBar: Bool { GlassBars.enabled }
    /// The debug bar's height with its separator: 36 with the Liquid
    /// Glass design (liquid-glass.md §2.6), 27 before.
    static var debugBarHeight: CGFloat { translucentBar ? 36 : 27 }
    /// Debug bar extras (DebugBarExtras.swift): the branch at the right
    /// end, the variables' A/L badges and loading spinner.
    public let branchLabel = NSTextField(labelWithString: "")
    lazy var branchView: NSStackView = makeBranchView()
    /// The click target over the branch glyph and name.
    public let branchButton = NSButton()
    /// The local branches (name, current) for the branch menu, and what
    /// choosing one does (set by the window).
    public var branchesProvider: (() -> [(String, Bool)])?
    /// Environment Overrides of the running app (EnvironmentOverridesPanel.swift):
    /// sends the overrides; nil when no run takes them. Set by the window.
    public var applyEnvironmentOverrides: ((EnvironmentOverrides) async -> (Bool, String))?
    /// The overrides last applied to the running app.
    public var environmentOverrides = EnvironmentOverrides()
    /// The run the overrides and the location belong to (the bundle id and
    /// the run's pid; nil: no run on the Ycode simulator). A new run starts
    /// with none (ycode-simd removes the app's overrides at its launch).
    public var simulatorRunKey: (() -> String?)?
    var overridesRunKey: String?
    /// Simulate Location for the running app's device: the words after
    /// `location` (`set <lat>,<lon>`, `run <scenario>`, `clear`); nil when no
    /// run takes them. Set by the window.
    public var simulateLocationHandler: (([String]) async -> (Bool, String))?
    /// The location item last chosen ("Don't Simulate Location" when nil).
    public var simulatedLocation: String?
    public var onSwitchBranch: ((String) -> Void)?
    /// The debug bar's row and its far-right show/hide toggle (tests).
    public internal(set) var debugBarStack: NSStackView?
    public internal(set) var debugAreaToggle: NSButton?

    /// The debug-area toggle's title and tooltip name what it does
    /// (`reference-ui-6.md` §2.5, T7).
    public static func debugAreaToggleTitle(shown: Bool) -> String { shown ? "hide debug area" : "show debug area" }

    /// Updates the debug-area toggle for the area's state.
    public func setDebugAreaShown(_ shown: Bool) {
        guard let b = debugAreaToggle else { return }
        let t = Self.debugAreaToggleTitle(shown: shown)
        guard b.toolTip != t else { return }
        b.toolTip = t
        b.setAccessibilityTitle(t)
        b.image?.accessibilityDescription = t
    }
    /// Holds the Code Review controls while comparing (reference-ui-4 §15.1).
    public let reviewSlot = NSStackView()
    public internal(set) var variableBadges: [String: String] = [:]
    let variablesSpinner = NSProgressIndicator()
    public internal(set) var backtraceInEditor = false
    /// Variables bottom bar (reference-ui.md §5): scope pop-up, two
    /// toggles, filter.
    public let scopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    public let variablesFilter = NSSearchField()
    /// Console bottom bar: two output toggles, filter, clear, and the
    /// buttons that show or hide each half.
    /// Quick Look buttons (variables and console bars) and the console's
    /// output-options button (reference-ui-2.md §9).
    public let variablesQuickLook = NSButton()
    public let consoleQuickLook = NSButton()
    public let outputOptionsButton = NSButton()
    /// The console's metadata columns (output-options popover).
    public private(set) var metadata = ConsoleMetadata()
    public func setMetadata(_ m: ConsoleMetadata) { metadata = m; onFilterChange?() }
    public let debuggerOutputToggle = NSButton()
    public let targetOutputToggle = NSButton()
    public let consoleSearch = NSSearchField()
    public let clearButton = NSButton()
    public let showVariablesButton = NSButton()
    public let showConsoleButton = NSButton()
    private var varsHalf: NSView?
    private var consoleHalf: NSView?
    private var allRoots: [VariableNode] = []
    var consoleRaw = ""

    public func setPosition(line: Int, column: Int) {
        positionLabel.stringValue = line > 0 ? "Line: \(line)  Col: \(column)" : ""
    }
    public private(set) var barButtonViews: [NSButton] = []
    /// The variables and console bottom bars and the Print Description
    /// button (reference-ui-5.md §8.1, §8.3).
    public private(set) var variablesBarStack: NSStackView?
    public private(set) var consoleBarStack: NSStackView?
    public private(set) var printDescriptionButton: NSButton?
    /// The bars' items left to right, by tooltip (tests).
    public var variablesBarTitles: [String] { _ = view; return variablesBarStack?.arrangedSubviews.map { $0.toolTip ?? "" } ?? [] }
    public var consoleBarTitles: [String] { _ = view; return consoleBarStack?.arrangedSubviews.map { $0.toolTip ?? "" } ?? [] }

    public override func loadView() {
        let root = NSView()
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for (symbol, tip, action) in Self.barButtons {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: Selector(action))
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = .secondaryLabelColor
            if Self.extraBarButtons.contains(where: { $0.2 == action }) { b.target = self }
            if Self.placeholderBarActions.contains(action) {
                // D4: a disabled placeholder; its action is never sent.
                b.action = nil
                b.target = nil
                b.isEnabled = false
            }
            barButtonViews.append(b)
            bar.addArrangedSubview(b)
        }
        frameLabel.font = .systemFont(ofSize: 11)
        frameLabel.textColor = .secondaryLabelColor
        bar.addArrangedSubview(frameLabel)
        bar.addArrangedSubview(reviewSlot)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bar.addArrangedSubview(spacer)
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor
        bar.addArrangedSubview(positionLabel)
        // reference-ui-5.md §6.2: "Line: N  Col: N", the branch button,
        // then the debug-area toggle at the far right.
        bar.addArrangedSubview(branchView)
        let hide = NSButton(image: NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "Hide Debug Area")!,
                            target: nil, action: Selector(("toggleDebugArea:")))
        hide.isBordered = false
        debugAreaToggle = hide
        setDebugAreaShown(false)
        bar.addArrangedSubview(hide)
        debugBarStack = bar

        let column = NSTableColumn(identifier: .init("v"))
        varsOutline.addTableColumn(column)
        varsOutline.outlineTableColumn = column
        varsOutline.headerView = nil
        varsOutline.rowSizeStyle = .small
        varsOutline.dataSource = self
        varsOutline.delegate = self
        let varsScroll = NSScrollView()
        varsScroll.documentView = varsOutline
        varsScroll.hasVerticalScroller = true

        consoleView.isEditable = false
        consoleView.font = Theme.font
        consoleView.autoresizingMask = [.width]
        consoleView.isVerticallyResizable = true
        let consoleScroll = NSScrollView()
        consoleScroll.documentView = consoleView
        consoleScroll.hasVerticalScroller = true
        let prompt = NSTextField(labelWithString: "(lldb)")
        prompt.font = Theme.boldFont
        prompt.textColor = .secondaryLabelColor
        consoleField.font = Theme.font
        consoleField.isBordered = false
        consoleField.drawsBackground = false
        consoleField.focusRingType = .none
        consoleField.placeholderString = "LLDB command or expression"
        consoleField.delegate = self
        filterPopUp.addItems(withTitles: ConsoleEntry.Filter.allCases.map(\.rawValue))
        filterPopUp.controlSize = .small
        filterPopUp.font = .systemFont(ofSize: 11)
        filterPopUp.target = self
        filterPopUp.action = #selector(filterChosen)
        let inputRow = NSStackView(views: [prompt, consoleField])
        inputRow.spacing = 6
        inputRow.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        func icon(_ b: NSButton, _ symbol: String, _ tip: String, _ sel: Selector, toggle: Bool) {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.isBordered = false
            b.toolTip = tip
            if toggle { b.setButtonType(.toggle) }
            b.target = self
            b.action = sel
        }
        icon(debuggerOutputToggle, "terminal", "Show debugger output", #selector(outputTogglesChanged), toggle: true)
        icon(targetOutputToggle, "text.alignleft", "Show target output", #selector(outputTogglesChanged), toggle: true)
        debuggerOutputToggle.state = .on
        targetOutputToggle.state = .on
        icon(clearButton, "trash", "Clear Console", #selector(clearClicked), toggle: false)
        icon(showVariablesButton, "rectangle.lefthalf.filled", "Show or hide the variables view", #selector(toggleVariablesHalf), toggle: false)
        icon(showConsoleButton, "rectangle.righthalf.filled", "Show or hide the console", #selector(toggleConsoleHalf), toggle: false)
        consoleSearch.placeholderString = "Filter"
        consoleSearch.controlSize = .small
        consoleSearch.target = self
        consoleSearch.action = #selector(consoleSearchChanged)
        icon(consoleQuickLook, "eye", "Quick Look", #selector(quickLookConsole), toggle: false)
        icon(outputOptionsButton, "list.bullet.rectangle", "Metadata Options", #selector(showOutputOptions(_:)), toggle: false)
        filterPopUp.toolTip = "Filter options"
        consoleSearch.toolTip = "Filter"
        // reference-ui-6.md §7 (D1): no output-kind pop-up; output filtering
        // is the filter field's and Metadata Options' (the toggles keep
        // `consoleFilter`).
        let consoleBar = NSStackView(views: [consoleQuickLook, outputOptionsButton, consoleSearch, clearButton, showVariablesButton, showConsoleButton])
        consoleBar.spacing = 6
        consoleBarStack = consoleBar
        consoleBar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        // §7 (D1): the command-entry line shows only during a debug session.
        let inputRule = NSBox.hairline()
        consoleInputViews = [inputRule, inputRow]
        for v in consoleInputViews { v.isHidden = true }
        // liquid-glass.md §2.6: no separator line above the bottom bars
        // (macOS 26+).
        let consoleBarRule = NSBox.hairline()
        consoleBarRule.isHidden = GlassBars.enabled
        let consoleColumn = NSStackView(views: [consoleScroll, inputRule, inputRow, consoleBarRule, consoleBar])
        consoleColumn.orientation = .vertical
        consoleColumn.spacing = 0
        consoleScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let menu = NSMenu()
        func item(_ title: String, _ tag: Int) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(variableMenuChosen(_:)), keyEquivalent: "")
            i.tag = tag
            i.target = self
            return i
        }
        menu.addItem(item("Print Description", 0))
        menu.addItem(item("Copy Value", 1))
        let watch = NSMenuItem(title: "Watch Variable", action: nil, keyEquivalent: "")
        watch.submenu = NSMenu(title: "Watch Variable")
        watch.submenu?.addItem(item("Write", 2))
        watch.submenu?.addItem(item("Read", 3))
        watch.submenu?.addItem(item("Read & Write", 4))
        menu.addItem(watch)
        menu.addItem(item("Edit Value…", 5))
        menu.addItem(item("Add Expression…", 6))
        registersCheck.target = self
        registersCheck.action = #selector(registersToggled)
        registersCheck.controlSize = .small
        registersCheck.state = Preferences.shared.showRegisters ? .on : .off
        varsOutline.menu = menu
        varsOutline.target = self
        varsOutline.doubleAction = #selector(variableDoubleClicked)

        scopePopUp.addItems(withTitles: VariableScope.allCases.map(\.title))
        scopePopUp.controlSize = .small
        scopePopUp.font = .systemFont(ofSize: 11)
        scopePopUp.target = self
        scopePopUp.action = #selector(scopeChosen)
        let info = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Print Description")!, target: self, action: #selector(infoClicked))
        info.isBordered = false
        info.toolTip = "Print Description"   // reference-ui-5.md §8.1
        printDescriptionButton = info
        registersCheck.title = ""
        registersCheck.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show registers")
        registersCheck.setButtonType(.toggle)
        registersCheck.isBordered = false
        registersCheck.toolTip = "Show registers"
        variablesFilter.placeholderString = "Filter"
        variablesFilter.controlSize = .small
        variablesFilter.target = self
        variablesFilter.action = #selector(variablesFilterChanged)
        scopePopUp.widthAnchor.constraint(equalToConstant: 76).isActive = true
        variablesFilter.setContentHuggingPriority(.init(1), for: .horizontal)
        consoleSearch.setContentHuggingPriority(.init(1), for: .horizontal)
        filterPopUp.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        variablesQuickLook.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick Look")
        variablesQuickLook.isBordered = false
        variablesQuickLook.toolTip = "Quick Look"
        variablesQuickLook.target = self
        variablesQuickLook.action = #selector(quickLookVariable)
        let varsBar = NSStackView(views: [scopePopUp, variablesQuickLook, info, variablesFilter])
        varsBar.spacing = 6
        variablesBarStack = varsBar
        variablesFilter.toolTip = "Filter"
        scopePopUp.toolTip = "Variables scope"
        varsBar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        let varsBarRule = NSBox.hairline()
        varsBarRule.isHidden = GlassBars.enabled
        let varsColumn = NSStackView(views: [varsScroll, varsBarRule, varsBar])
        varsColumn.orientation = .vertical
        varsColumn.spacing = 0
        varsScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        addVariablesSpinner(over: varsScroll)
        varsHalf = varsColumn
        consoleHalf = consoleColumn

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(varsColumn)
        split.addArrangedSubview(consoleColumn)

        let topSep = NSBox.hairline()
        if Self.translucentBar {
            // liquid-glass.md §2.6, §3.2: a translucent bar over the editor
            // text scrolled beneath it, strongly blurred, with a hard edge
            // (the separator above); the system's header material.
            let material = NSVisualEffectView()
            material.material = .headerView
            material.blendingMode = .withinWindow
            material.state = .active   // blurred in inactive windows too (§3.2 was observed inactive)
            material.translatesAutoresizingMaskIntoConstraints = false
            debugBar.addSubview(material)
            NSLayoutConstraint.activate([
                material.topAnchor.constraint(equalTo: debugBar.topAnchor), material.bottomAnchor.constraint(equalTo: debugBar.bottomAnchor),
                material.leadingAnchor.constraint(equalTo: debugBar.leadingAnchor), material.trailingAnchor.constraint(equalTo: debugBar.trailingAnchor),
            ])
        }
        for v in [topSep, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            debugBar.addSubview(v)
        }
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            topSep.topAnchor.constraint(equalTo: debugBar.topAnchor),
            topSep.leadingAnchor.constraint(equalTo: debugBar.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: debugBar.trailingAnchor),
            bar.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: debugBar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: debugBar.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: debugBar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.debugBarHeight - 1),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            varsColumn.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.5, constant: -1).withPriority(.defaultLow),
        ])
        view = root
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        applyTheme()
    }

    public func setVariables(_ v: [Variable]) {
        allRoots = v.map(VariableNode.init)
        applyVariablesFilter()
    }

    func applyVariablesFilter() {
        let f = variablesFilter.stringValue.lowercased()
        let scope = variableScope
        roots = allRoots.filter { scope.includes($0.variable.name) && (f.isEmpty || $0.variable.name.lowercased().contains(f)) }
        varsOutline.reloadData()
    }

    /// The scope chosen in the variables bar.
    public var variableScope: VariableScope { VariableScope(rawValue: scopePopUp.indexOfSelectedItem) ?? .auto }

    @objc func variablesFilterChanged() { applyVariablesFilter() }
    /// Registers show only in "All Variables, Registers, Globals and
    /// Statics" (reference-ui-2.md §9).
    @objc func scopeChosen() {
        let all = variableScope.showsRegisters
        if Preferences.shared.showRegisters != all { Preferences.shared.showRegisters = all }
        applyVariablesFilter()
    }

    /// The selected variable's value, or the console's selected text, in a
    /// popover (only for a window on screen).
    @objc func quickLookVariable() {
        let row = varsOutline.selectedRow
        guard row >= 0, let n = varsOutline.item(atRow: row) as? VariableNode else { NSSound.beep(); return }
        showPopover(text: "\(n.variable.name) = \(n.variable.value)", from: variablesQuickLook)
    }

    @objc func quickLookConsole() {
        let r = consoleView.selectedRange()
        let text = r.length > 0 ? (consoleView.string as NSString).substring(with: r) : consoleView.string.split(separator: "\n").last.map(String.init) ?? ""
        showPopover(text: text, from: consoleQuickLook)
    }

    func showPopover(text: String, from v: NSView) {
        guard view.window?.isVisible == true else { return }
        let p = NSPopover()
        p.behavior = .transient
        let vc = NSViewController()
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = Theme.consoleFont
        f.isSelectable = true
        f.preferredMaxLayoutWidth = 360
        let box = NSStackView(views: [f])
        box.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        vc.view = box
        p.contentViewController = vc
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxY)
    }

    /// The output-options popover: a Metadata switch and the metadata
    /// columns. Ycode records Type and Timestamp; the other columns have no
    /// data in Ycode's console and are shown disabled.
    @objc func showOutputOptions(_ sender: NSButton) {
        guard view.window?.isVisible == true else { return }
        let p = NSPopover()
        p.behavior = .transient
        let vc = NSViewController()
        let sw = NSSwitch()
        sw.state = metadata.enabled ? .on : .off
        sw.target = self
        sw.action = #selector(metadataSwitched(_:))
        var rows: [NSView] = [NSStackView(views: [NSTextField(labelWithString: "Metadata"), sw])]
        for (i, name) in ConsoleMetadata.columns.enumerated() {
            let b = NSButton(checkboxWithTitle: name, target: self, action: #selector(metadataColumn(_:)))
            b.tag = i
            b.state = metadata.isOn(i) ? .on : .off
            b.isEnabled = ConsoleMetadata.supportedColumns.contains(i)
            rows.append(b)
        }
        let box = NSStackView(views: rows)
        box.orientation = .vertical
        box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        vc.view = box
        p.contentViewController = vc
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc func metadataSwitched(_ s: NSSwitch) { var m = metadata; m.enabled = s.state == .on; setMetadata(m) }
    @objc func metadataColumn(_ b: NSButton) { var m = metadata; m.set(b.tag, b.state == .on); setMetadata(m) }
    /// Selects a top-level variable row by name (tests, Print Description).
    @discardableResult
    public func selectVariable(named name: String) -> Bool {
        guard let n = roots.first(where: { $0.variable.name == name }) else { return false }
        let row = varsOutline.row(forItem: n)
        guard row >= 0 else { return false }
        varsOutline.selectRowIndexes([row], byExtendingSelection: false)
        return true
    }

    @objc func infoClicked() {
        let row = varsOutline.selectedRow
        if row >= 0, let n = varsOutline.item(atRow: row) as? VariableNode { onVariableAction?(.printDescription, n.variable) }
    }
    @objc func outputTogglesChanged() {
        let d = debuggerOutputToggle.state == .on, t = targetOutputToggle.state == .on
        consoleFilter = d == t ? .all : d ? .debugger : .target
        filterPopUp.selectItem(withTitle: consoleFilter.rawValue)
        onFilterChange?()
    }
    @objc func clearClicked() { NSApp.sendAction(Selector(("clearConsole:")), to: nil, from: self) }
    @objc public func toggleVariablesHalf() { varsHalf?.isHidden.toggle(); if varsHalf?.isHidden == true { consoleHalf?.isHidden = false } }
    @objc public func toggleConsoleHalf() { consoleHalf?.isHidden.toggle(); if consoleHalf?.isHidden == true { varsHalf?.isHidden = false } }
    @objc func consoleSearchChanged() { renderConsole() }
    /// The variables view and console halves are shown (tests).
    public var halvesShown: (variables: Bool, console: Bool) { (!(varsHalf?.isHidden ?? false), !(consoleHalf?.isHidden ?? false)) }

    /// Loads (once) and returns a node's children.
    @discardableResult
    public func expand(_ node: VariableNode) async -> [VariableNode] {
        if let c = node.children { return c }
        let kids = await loadChildren?(node.variable.variablesReference) ?? []
        node.children = kids.map(VariableNode.init)
        varsOutline.reloadItem(node, reloadChildren: true)
        return node.children!
    }

    public func setFrame(_ text: String) { frameLabel.stringValue = text }

    // MARK: Console input

    /// Evaluates the console line and clears it.
    public func submitConsoleLine() async {
        let line = consoleField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        history.append(line)
        historyCursor = nil
        consoleField.stringValue = ""
        await onConsoleLine?(line)
    }

    /// The history entry `back` steps from the newest (1 = newest).
    public func historyItem(back: Int) -> String? {
        let i = history.count - back
        return history.indices.contains(i) ? history[i] : nil
    }

    /// ↑ / ↓ in the input line move through the history.
    func moveHistory(older: Bool) {
        guard !history.isEmpty else { return }
        let c = historyCursor ?? history.count
        let next = older ? max(0, c - 1) : min(history.count, c + 1)
        historyCursor = next
        consoleField.stringValue = next < history.count ? history[next] : ""
    }

    @objc private func filterChosen() {
        consoleFilter = ConsoleEntry.Filter.allCases[max(0, filterPopUp.indexOfSelectedItem)]
        onFilterChange?()
    }

    public func setFilter(_ f: ConsoleEntry.Filter) {
        consoleFilter = f
        filterPopUp.selectItem(withTitle: f.rawValue)
        onFilterChange?()
    }

    // MARK: Variables context menu

    @objc private func variableMenuChosen(_ item: NSMenuItem) {
        let row = varsOutline.clickedRow >= 0 ? varsOutline.clickedRow : varsOutline.selectedRow
        let node = row >= 0 ? varsOutline.item(atRow: row) as? VariableNode : nil
        let actions: [VariableAction] = [.printDescription, .copyValue, .watch, .watchRead, .watchReadWrite, .editValue, .addExpression]
        guard let action = actions.indices.contains(item.tag) ? actions[item.tag] : nil else { return }
        onVariableAction?(action, node?.variable ?? Variable(name: "", value: ""))
    }

    @objc private func registersToggled() { Preferences.shared.showRegisters = registersCheck.state == .on }

    @objc private func variableDoubleClicked() {
        guard varsOutline.clickedRow >= 0, let node = varsOutline.item(atRow: varsOutline.clickedRow) as? VariableNode else { return }
        onVariableAction?(.editValue, node.variable)
    }

    /// Copy Value: the value on the general pasteboard.
    public static func copy(_ v: Variable) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v.value, forType: .string)
    }

    public func setConsole(_ text: String) {
        _ = view
        consoleRaw = text
        renderConsole()
    }

    /// The console text with the bar's filter applied (matching lines).
    public var shownConsole: String { consoleView.string }

    func renderConsole() {
        let f = consoleSearch.stringValue
        consoleView.string = f.isEmpty ? consoleRaw
            : consoleRaw.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(f) }.joined(separator: "\n")
        applyTheme()
        highlightKilledLine()
        consoleView.scrollToEndOfDocument(nil)
    }

    /// Pause becomes Continue while stopped.
    public func setPaused(_ paused: Bool) {
        guard let b = pauseContinueButton else { return }
        b.image = NSImage(systemSymbolName: paused ? "play" : "pause", accessibilityDescription: nil)
        b.toolTip = paused ? "Continue program execution" : "Pause program execution"
    }

    /// Continue and the step buttons show only during a debug session;
    /// the breakpoint toggle is always there (reference-ui.md §2). So does
    /// the console's command-entry line (reference-ui-6.md §7, D1).
    public func setDebugging(_ on: Bool) {
        _ = view
        for b in barButtonViews where b.action != Selector(("toggleBreakpointsActive:")) { b.isHidden = !on }
        for v in consoleInputViews where v.isHidden == on { v.isHidden = !on }
    }

    /// The console's command-entry line and the rule above it.
    private var consoleInputViews: [NSView] = []
    /// Whether the command-entry line is shown (tests).
    public var isConsoleInputShown: Bool { _ = view; return consoleInputViews.contains { !$0.isHidden } }

    /// The debug bar's Pause / Continue button.
    public var pauseContinueButton: NSButton? {
        _ = view
        return barButtonViews.first { $0.action == Selector(("pauseOrContinue:")) }
    }

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? VariableNode else { return roots.count }
        if node.children == nil { Task { await expand(node) } }
        return node.children?.count ?? 0
    }

    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? VariableNode)?.children?[index] ?? roots[index]
    }

    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? VariableNode)?.isExpandable ?? false
    }

    public func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? VariableNode else { return nil }
        let v = node.variable
        // Top-level rows carry the A/L badge (reference-ui-4.md §5.5).
        if o.level(forItem: item) == 0, let badge = variableBadges[v.name] { return badgedRow(badge, v) }
        let s = NSMutableAttributedString(string: v.name, attributes: [.font: Theme.boldFont])
        if let t = v.type, !t.isEmpty, t != "<no-type>" { s.append(NSAttributedString(string: " (\(t))", attributes: [.font: Theme.font, .foregroundColor: NSColor.secondaryLabelColor])) }
        s.append(NSAttributedString(string: " = \(v.value)", attributes: [.font: Theme.font]))
        return NSTextField(labelWithAttributedString: s)
    }
}

extension DebugAreaController: NSTextFieldDelegate {
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === consoleField else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): Task { await submitConsoleLine() }; return true
        case #selector(NSResponder.moveUp(_:)): moveHistory(older: true); return true
        case #selector(NSResponder.moveDown(_:)): moveHistory(older: false); return true
        default: return false
        }
    }
}

extension NSBox {
    /// A horizontal separator line of fixed height.
    static func hairline() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
