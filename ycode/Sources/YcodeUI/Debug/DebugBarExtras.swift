import AppKit
import YcodeDebug

/// The paused debug bar's extra buttons, path and branch; the variables
/// view's badges and spinner; the highlighted "killed" console line
/// (specs/ide/reference-ui-4.md §1.2, §5.4–5.6).
extension DebugAreaController {
    /// After Step Out: Backtrace in Editor, View Hierarchy, Memory Graph,
    /// Environment Overrides, Simulate Location.
    public static let extraBarButtons: [(String, String, String)] = [
        ("list.bullet.indent", "Enable Backtrace in Editor", "toggleBacktraceInEditor:"),
        ("square.3.layers.3d.down.right", "Debug View Hierarchy", "debugViewHierarchy:"),
        ("circle.hexagongrid", "Debug Memory Graph", "debugMemoryGraph:"),
        ("slider.horizontal.3", "Environment Overrides", "showEnvironmentOverrides:"),
        ("location", "Simulate Location", "simulateLocation:"),
    ]

    /// The branch button: a branch glyph and the branch name; it opens a
    /// menu of the local branches (reference-ui-5.md §6.2).
    func makeBranchView() -> NSStackView {
        let glyph = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")!)
        glyph.contentTintColor = .secondaryLabelColor
        branchLabel.font = .systemFont(ofSize: 11)
        branchLabel.textColor = .secondaryLabelColor
        let button = branchButton
        button.isBordered = false
        button.image = nil
        button.title = ""
        button.toolTip = Self.branchButtonToolTip
        button.setAccessibilityLabel("Branch")
        button.target = self
        button.action = #selector(branchClicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        let v = NSStackView(views: [glyph, branchLabel])
        v.spacing = 3
        v.isHidden = true
        v.toolTip = Self.branchButtonToolTip
        // The button covers the glyph and the name, so a click anywhere opens the menu.
        v.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: v.leadingAnchor), button.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            button.topAnchor.constraint(equalTo: v.topAnchor), button.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    public static let branchButtonToolTip = "Shows a list of available branches"

    /// The branch menu: the local branches, the current one checked.
    public func branchMenu() -> NSMenu {
        let menu = NSMenu(title: "Branches")
        for (name, current) in branchesProvider?() ?? [] {
            let item = NSMenuItem(title: name, action: #selector(branchChosen(_:)), keyEquivalent: "")
            item.target = self
            item.state = current ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: "No Branches", action: nil, keyEquivalent: "")) }
        return menu
    }

    @objc func branchClicked(_ sender: NSButton) {
        let menu = branchMenu()
        guard sender.window?.isVisible == true else { return }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc func branchChosen(_ item: NSMenuItem) { onSwitchBranch?(item.title) }

    /// Shows (or with nil removes) the Code Review controls in the bar.
    public func setReviewControls(_ v: NSView?) {
        _ = view
        for old in reviewSlot.arrangedSubviews where old !== v { old.removeFromSuperview() }
        if let v, v.superview !== reviewSlot { v.removeFromSuperview(); reviewSlot.addArrangedSubview(v) }
    }

    /// The current git branch at the bar's right end (hidden when none).
    public func setBranch(_ name: String?) {
        _ = view
        branchLabel.stringValue = name ?? ""
        branchView.isHidden = name == nil
    }

    /// "<process> › Thread <n> › <index> <function>" while paused.
    public func setPath(_ path: String) {
        guard !path.isEmpty else { return }
        setFrame(path)
    }

    public var shownPath: String { _ = view; return frameLabel.stringValue }

    public func setVariableBadges(_ b: [String: String]) {
        guard b != variableBadges else { return }
        variableBadges = b
        applyVariablesFilter()
    }

    func addVariablesSpinner(over scroll: NSView) {
        variablesSpinner.style = .spinning
        variablesSpinner.controlSize = .small
        variablesSpinner.isDisplayedWhenStopped = false
        variablesSpinner.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(variablesSpinner)
        NSLayoutConstraint.activate([
            variablesSpinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            variablesSpinner.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    public var isLoadingVariables: Bool { _ = view; return loadingFlag }
    private var loadingFlag: Bool { variablesSpinner.toolTip == "Loading" }

    public func setLoadingVariables(_ on: Bool) {
        _ = view
        variablesSpinner.toolTip = on ? "Loading" : nil
        if on { variablesSpinner.startAnimation(nil) } else { variablesSpinner.stopAnimation(nil) }
    }

    /// "A name: Type = value" with the letter in a small badge.
    func badgedRow(_ badge: String, _ v: Variable) -> NSView {
        let tint: NSColor = badge == "A" ? .systemPurple : .systemBlue
        let s = NSMutableAttributedString(string: " \(badge) ", attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white,
                                                                             .backgroundColor: tint])
        s.append(NSAttributedString(string: " " + v.name, attributes: [.font: Theme.boldFont]))
        let type = v.type.flatMap { $0.isEmpty || $0 == "<no-type>" ? nil : $0 }
        if let type { s.append(NSAttributedString(string: ": \(type)", attributes: [.font: Theme.font, .foregroundColor: NSColor.secondaryLabelColor])) }
        s.append(NSAttributedString(string: " = \(v.value)", attributes: [.font: Theme.font]))
        let f = NSTextField(labelWithAttributedString: s)
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    /// The row text of a top-level variable (tests).
    public func variableRowText(_ name: String) -> String? {
        guard let n = roots.first(where: { $0.variable.name == name }) else { return nil }
        return variableBadges[name].map { DebugPresentation.variableRow(badge: $0, n.variable) }
    }

    /// "Debug session ended with code 9: killed" is drawn highlighted.
    func highlightKilledLine() {
        guard let storage = consoleView.textStorage else { return }
        let text = storage.string as NSString
        var r = text.range(of: DebugPresentation.killedLine)
        while r.location != NSNotFound {
            storage.addAttributes([.backgroundColor: NSColor.systemRed.withAlphaComponent(0.2), .font: NSFont.boldSystemFont(ofSize: consoleView.font?.pointSize ?? 11)], range: r)
            let next = NSMaxRange(r)
            r = text.range(of: DebugPresentation.killedLine, range: NSRange(location: next, length: text.length - next))
        }
    }

    // MARK: Extra buttons

    @objc func toggleBacktraceInEditor(_ sender: NSButton) {
        backtraceInEditor.toggle()
        sender.contentTintColor = backtraceInEditor ? .controlAccentColor : .secondaryLabelColor
    }

    /// Debug View Hierarchy and Debug Memory Graph (D4) stay disabled
    /// placeholders until the simulator can capture them
    /// (`reference-ui-5.md` §0, R37): listed in the bar, never enabled.
    public static let placeholderBarActions: Set<String> = ["debugViewHierarchy:", "debugMemoryGraph:"]

    @objc func showEnvironmentOverrides(_ sender: NSButton) {
        showPopover(text: "Environment overrides (Appearance, Text, Accessibility) apply to simulator runs.", from: sender)
    }

    @objc func simulateLocation(_ sender: NSButton) {
        let menu = NSMenu()
        let none = NSMenuItem(title: "Don't Simulate Location", action: nil, keyEquivalent: "")
        none.state = .on
        menu.addItem(none)
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Location simulation needs a simulator run", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
}
