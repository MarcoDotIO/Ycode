import AppKit
import YcodeIDECore

/// Find navigator ▸ In … ▸ Custom Scopes…: the saved scopes on the left;
/// the selected one's name, "Match All | Any of the following rules" and
/// its rules (field, operator, value) on the right; Cancel and Save.
/// Ycode's own layout (`specs/ide/navigators.md` §Find navigator, "Ycode
/// implementation").
public final class FindScopeEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public private(set) var scopes: [CustomFindScope]
    public private(set) var selected: Int?
    var onSave: (([CustomFindScope]) -> Void)?

    private let list = NSTableView()
    private let nameField = NSTextField()
    private let matchPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rulesStack = NSStackView()
    private let detail = NSStackView()

    init(scopes: [CustomFindScope]) {
        self.scopes = scopes
        selected = scopes.isEmpty ? nil : 0
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Editing (also what the controls call)

    public func addScope() {
        var n = 1
        while scopes.contains(where: { $0.name == (n == 1 ? "Scope" : "Scope \(n)") }) { n += 1 }
        scopes.append(CustomFindScope(name: n == 1 ? "Scope" : "Scope \(n)", rules: [.init(.extension, .is, "swift")]))
        select(scopes.count - 1)
    }

    public func removeSelectedScope() {
        guard let i = selected else { return }
        scopes.remove(at: i)
        select(scopes.isEmpty ? nil : min(i, scopes.count - 1))
    }

    public func select(_ i: Int?) {
        selected = i
        refresh()
    }

    public func setName(_ name: String) {
        guard let i = selected, !name.isEmpty else { return }
        scopes[i].name = name
        if isViewLoaded { list.reloadData() }
    }

    public func setMatchAll(_ all: Bool) {
        guard let i = selected else { return }
        scopes[i].matchAll = all
    }

    public func addRule() {
        guard let i = selected else { return }
        scopes[i].rules.append(.init(.name, .contains, ""))
        refresh()
    }

    public func setRule(_ r: Int, _ rule: CustomFindScope.Rule) {
        guard let i = selected, scopes[i].rules.indices.contains(r) else { return }
        scopes[i].rules[r] = rule
    }

    public func removeRule(_ r: Int) {
        guard let i = selected, scopes[i].rules.indices.contains(r) else { return }
        scopes[i].rules.remove(at: r)
        refresh()
    }

    /// Saves (scopes without a name or rules are dropped) and closes.
    public func save() {
        onSave?(scopes.filter { !$0.name.isEmpty && !$0.rules.isEmpty })
        if presentingViewController != nil { dismiss(nil) }
    }

    // MARK: Views

    public override func loadView() {
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "Scopes"
        list.addTableColumn(col)
        list.headerView = nil
        list.dataSource = self
        list.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        let plus = NSButton(title: "+", target: self, action: #selector(plusClicked))
        let minus = NSButton(title: "−", target: self, action: #selector(minusClicked))
        for b in [plus, minus] { b.bezelStyle = .smallSquare }
        let left = NSStackView(views: [listScroll, NSStackView(views: [plus, minus])])
        left.orientation = .vertical
        left.alignment = .leading
        listScroll.widthAnchor.constraint(equalToConstant: 160).isActive = true
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        nameField.delegate = self
        nameField.placeholderString = "Name"
        matchPopUp.addItems(withTitles: ["All", "Any"])
        matchPopUp.target = self
        matchPopUp.action = #selector(matchChosen)
        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        let addRule = NSButton(title: "Add Rule", target: self, action: #selector(addRuleClicked))
        let matchRow = NSStackView(views: [NSTextField(labelWithString: "Match"), matchPopUp, NSTextField(labelWithString: "of the following rules:")])
        detail.orientation = .vertical
        detail.alignment = .leading
        for v in [nameField, matchRow, rulesStack, addRule] as [NSView] { detail.addArrangedSubview(v) }
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        let body = NSStackView(views: [left, detail])
        body.alignment = .top
        body.spacing = 16
        let stack = NSStackView(views: [NSTextField(labelWithString: "Custom Scopes"), body, NSStackView(views: [cancel, saveButton])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        view = stack
        refresh()
    }

    /// The rule rows as shown (tests): "Extension is swift".
    public var ruleTitles: [String] {
        guard let i = selected else { return [] }
        return scopes[i].rules.map { "\($0.field.title) \($0.op.title) \($0.value)" }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        list.reloadData()
        if let i = selected { list.selectRowIndexes([i], byExtendingSelection: false) }
        detail.isHidden = selected == nil
        guard let i = selected else { return }
        nameField.stringValue = scopes[i].name
        matchPopUp.selectItem(at: scopes[i].matchAll ? 0 : 1)
        for v in rulesStack.arrangedSubviews { v.removeFromSuperview() }
        for (r, rule) in scopes[i].rules.enumerated() { rulesStack.addArrangedSubview(ruleRow(r, rule)) }
    }

    private func ruleRow(_ r: Int, _ rule: CustomFindScope.Rule) -> NSView {
        let field = NSPopUpButton(frame: .zero, pullsDown: false)
        field.addItems(withTitles: CustomFindScope.Field.allCases.map(\.title))
        field.selectItem(at: CustomFindScope.Field.allCases.firstIndex(of: rule.field) ?? 0)
        let op = NSPopUpButton(frame: .zero, pullsDown: false)
        op.addItems(withTitles: CustomFindScope.Operator.allCases.map(\.title))
        op.selectItem(at: CustomFindScope.Operator.allCases.firstIndex(of: rule.op) ?? 0)
        let value = NSTextField(string: rule.value)
        value.placeholderString = rule.field == .location ? CustomFindScope.openFilesValue : "Value"
        value.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let remove = NSButton(title: "−", target: self, action: #selector(removeRuleClicked(_:)))
        remove.bezelStyle = .smallSquare
        let controls: [NSControl] = [field, op, value, remove]
        for (i, c) in controls.enumerated() {
            c.tag = r
            if i < 3 {
                c.target = self
                c.action = #selector(ruleEdited(_:))
            }
        }
        value.delegate = self
        return NSStackView(views: [field, op, value, remove])
    }

    @objc private func ruleEdited(_ sender: NSControl) {
        guard let row = sender.superview as? NSStackView, row.arrangedSubviews.count == 4,
              let f = row.arrangedSubviews[0] as? NSPopUpButton, let o = row.arrangedSubviews[1] as? NSPopUpButton,
              let v = row.arrangedSubviews[2] as? NSTextField else { return }
        setRule(sender.tag, .init(CustomFindScope.Field.allCases[max(0, f.indexOfSelectedItem)],
                                  CustomFindScope.Operator.allCases[max(0, o.indexOfSelectedItem)], v.stringValue))
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField { setName(field.stringValue) } else { ruleEdited(field) }
    }

    @objc private func plusClicked() { addScope() }
    @objc private func minusClicked() { removeSelectedScope() }
    @objc private func addRuleClicked() { addRule() }
    @objc private func removeRuleClicked(_ sender: NSButton) { removeRule(sender.tag) }
    @objc private func matchChosen() { setMatchAll(matchPopUp.indexOfSelectedItem == 0) }
    @objc private func cancelClicked() { dismiss(nil) }
    @objc private func saveClicked() { save() }

    public func numberOfRows(in tableView: NSTableView) -> Int { scopes.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: scopes[row].name)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let r = list.selectedRow
        if r >= 0, r != selected { select(r) }
    }
}
