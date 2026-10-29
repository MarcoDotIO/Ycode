import AppKit
import YcodeSimFeatures

/// The debug bar's Environment Overrides pop-over (`specs/ide/debug.md`
/// §Environment Overrides; `specs/simulator/simulator-features.md` §7.3).
/// Ycode's layout (the reference's was not observed, Q11): one section per
/// category — Appearance (Light / Dark), Dynamic Type (a 12-step slider with
/// the size's name), Accessibility (the nine switches as check boxes) —
/// each with a switch that turns its overrides on (off: No Override), and
/// "Disable All Overrides" at the bottom. Every change is sent at once to
/// the running app only (`overrides <bundle id> …`); the device's settings
/// stay as they are.
@MainActor
public final class EnvironmentOverridesController: NSViewController {
    weak var debugArea: DebugAreaController?
    public private(set) var sections: EnvironmentOverrides.Sections
    /// The last result shown under the sections.
    public private(set) var status = ""
    private let statusLabel = NSTextField(labelWithString: "")
    /// The send in flight (tests await it).
    public private(set) var sendTask: Task<Void, Never>?

    public init(debugArea: DebugAreaController) {
        self.debugArea = debugArea
        sections = debugArea.environmentOverrides.sections
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The sections' controls (tests read them).
    let appearanceSwitch = NSSwitch()
    let appearanceControl = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    let typeSwitch = NSSwitch()
    let typeSlider = NSSlider(value: Double(ContentSize.large.index), minValue: 0, maxValue: 11, target: nil, action: nil)
    let typeLabel = NSTextField(labelWithString: "")
    let accessibilitySwitch = NSSwitch()
    var checks: [EnvironmentOverrides.Item: NSButton] = [:]

    public override func loadView() {
        func header(_ title: String, _ sw: NSSwitch) -> NSView {
            let l = NSTextField(labelWithString: title)
            l.font = .boldSystemFont(ofSize: 12)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            sw.controlSize = .small
            sw.target = self
            sw.action = #selector(changed(_:))
            sw.setAccessibilityLabel(title)
            let row = NSStackView(views: [l, spacer, sw])
            row.distribution = .fill
            return row
        }
        appearanceControl.target = self
        appearanceControl.action = #selector(changed(_:))
        appearanceControl.setAccessibilityLabel("Appearance")
        typeSlider.numberOfTickMarks = 12
        typeSlider.allowsTickMarkValuesOnly = true
        typeSlider.isContinuous = false
        typeSlider.target = self
        typeSlider.action = #selector(changed(_:))
        typeSlider.setAccessibilityLabel("Dynamic Type")
        typeLabel.font = .systemFont(ofSize: 11)
        typeLabel.textColor = .secondaryLabelColor
        var rows: [NSView] = [header("Appearance", appearanceSwitch), appearanceControl,
                              header("Dynamic Type", typeSwitch), typeSlider, typeLabel,
                              header("Accessibility", accessibilitySwitch)]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        var pair: [NSView] = []
        for item in EnvironmentOverrides.accessibilityItems {
            let b = NSButton(checkboxWithTitle: item.title, target: self, action: #selector(changed(_:)))
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            checks[item] = b
            pair.append(b)
            if pair.count == 2 { grid.addRow(with: pair); pair = [] }
        }
        if !pair.isEmpty { grid.addRow(with: pair + [NSView()]) }
        rows.append(grid)
        let disable = NSButton(title: "Disable All Overrides", target: self, action: #selector(disableAll(_:)))
        disable.controlSize = .small
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        rows += [disable, statusLabel]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for v in rows where v is NSStackView { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
        view = stack
        show()
    }

    /// Puts `sections` into the controls.
    func show() {
        appearanceSwitch.state = sections.appearance != nil ? .on : .off
        appearanceControl.selectedSegment = sections.appearance == .dark ? 1 : 0
        appearanceControl.isEnabled = sections.appearance != nil
        typeSwitch.state = sections.dynamicType != nil ? .on : .off
        let size = sections.dynamicType ?? .large
        typeSlider.integerValue = size.index
        typeSlider.isEnabled = sections.dynamicType != nil
        typeLabel.stringValue = EnvironmentOverrides.Item.dynamicType.choices[size.index].title
        accessibilitySwitch.state = sections.accessibility != nil ? .on : .off
        for (item, b) in checks {
            b.state = sections.accessibility?[item] == true ? .on : .off
            b.isEnabled = sections.accessibility != nil
        }
        statusLabel.stringValue = status
    }

    /// Reads the controls into `sections`.
    func read() {
        sections.appearance = appearanceSwitch.state == .on ? (appearanceControl.selectedSegment == 1 ? .dark : .light) : nil
        sections.dynamicType = typeSwitch.state == .on ? ContentSize.allCases[min(11, max(0, typeSlider.integerValue))] : nil
        sections.accessibility = accessibilitySwitch.state == .on
            ? Dictionary(uniqueKeysWithValues: EnvironmentOverrides.accessibilityItems.map { ($0, checks[$0]?.state == .on) }) : nil
    }

    @objc func changed(_ sender: Any?) {
        read()
        send()
    }

    @objc func disableAll(_ sender: Any?) {
        sections = EnvironmentOverrides.Sections()
        send()
    }

    /// Applies the sections to the running app.
    @discardableResult
    public func send() -> Task<Void, Never>? {
        let overrides = EnvironmentOverrides(sections: sections)
        show()
        guard let debugArea, let apply = debugArea.applyEnvironmentOverrides else { return nil }
        debugArea.environmentOverrides = overrides
        status = "Applying…"
        statusLabel.stringValue = status
        let task = Task { [weak self] in
            let (ok, reply) = await apply(overrides)
            guard let self else { return }
            self.status = ok ? (overrides.isEmpty ? "No overrides" : "Applied to the running app") : reply
            self.show()
        }
        sendTask = task
        return task
    }

    /// For tests: set the controls as a user would, then send.
    public func set(_ s: EnvironmentOverrides.Sections) -> Task<Void, Never>? {
        _ = view
        sections = s
        return send()
    }
}
