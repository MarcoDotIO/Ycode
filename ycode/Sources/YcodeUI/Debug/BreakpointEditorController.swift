import AppKit

/// The breakpoint editor (double-click or ⌘-click a breakpoint): condition,
/// ignore count, one action (log message or debugger command), and
/// "Automatically continue after evaluating actions". See
/// `specs/ide/debug.md` §Breakpoint editing.
@MainActor
public final class BreakpointEditorController: NSViewController {
    public private(set) var breakpoint: BreakpointStore.Breakpoint
    public var onChange: ((BreakpointStore.Breakpoint) -> Void)?

    public let conditionField = NSTextField()
    public let ignoreField = NSTextField()
    public let actionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    public let actionField = NSTextField()
    public let continueCheckbox = NSButton(checkboxWithTitle: "Automatically continue after evaluating actions", target: nil, action: nil)

    public static let actionTitles = ["No Action", "Log Message", "Debugger Command"]

    public init(breakpoint: BreakpointStore.Breakpoint) {
        self.breakpoint = breakpoint
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 440, height: 210))
        let title = NSTextField(labelWithString: "\(URL(fileURLWithPath: breakpoint.file).lastPathComponent):\(breakpoint.line)")
        title.font = .boldSystemFont(ofSize: 12)
        conditionField.placeholderString = "Condition"
        conditionField.stringValue = breakpoint.condition
        ignoreField.stringValue = String(breakpoint.ignoreCount)
        ignoreField.alignment = .right
        ignoreField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        actionPopUp.addItems(withTitles: Self.actionTitles)
        actionField.placeholderString = "Message (use {expression} to show a value)"
        switch breakpoint.actions.first {
        case .log(let m)?: actionPopUp.selectItem(at: 1); actionField.stringValue = m
        case .debuggerCommand(let c)?: actionPopUp.selectItem(at: 2); actionField.stringValue = c
        case nil: actionPopUp.selectItem(at: 0)
        }
        continueCheckbox.state = breakpoint.autoContinue ? .on : .off
        for c in [conditionField, ignoreField, actionField] as [NSControl] {
            c.target = self
            c.action = #selector(changed)
        }
        actionPopUp.target = self
        actionPopUp.action = #selector(changed)
        continueCheckbox.target = self
        continueCheckbox.action = #selector(changed)
        let ignoreRow = NSStackView(views: [ignoreField, NSTextField(labelWithString: "times before stopping")])
        let grid = NSGridView(views: [
            [label("Condition"), conditionField],
            [label("Ignore"), ignoreRow],
            [label("Action"), actionPopUp],
            [NSGridCell.emptyContentView, actionField],
            [label("Options"), continueCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let stack = NSStackView(views: [title, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            conditionField.widthAnchor.constraint(equalToConstant: 300),
            actionField.widthAnchor.constraint(equalTo: conditionField.widthAnchor),
        ])
        view = root
        updateActionField()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func updateActionField() {
        actionField.isHidden = actionPopUp.indexOfSelectedItem == 0
        actionField.placeholderString = actionPopUp.indexOfSelectedItem == 2 ? "lldb command" : "Message (use {expression} to show a value)"
    }

    /// Reads the controls into the breakpoint and reports it.
    @objc public func changed() {
        breakpoint.condition = conditionField.stringValue.trimmingCharacters(in: .whitespaces)
        breakpoint.ignoreCount = max(0, Int(ignoreField.stringValue) ?? 0)
        let text = actionField.stringValue
        switch actionPopUp.indexOfSelectedItem {
        case 1: breakpoint.actions = text.isEmpty ? [] : [.log(text)]
        case 2: breakpoint.actions = text.isEmpty ? [] : [.debuggerCommand(text)]
        default: breakpoint.actions = []
        }
        breakpoint.autoContinue = continueCheckbox.state == .on
        updateActionField()
        onChange?(breakpoint)
    }
}
