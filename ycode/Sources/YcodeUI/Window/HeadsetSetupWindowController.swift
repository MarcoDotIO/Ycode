import AppKit
import YcodeIDECore

/// Set Up Headset… (`specs/ide/device-hub.md` §I.12): the onboarding as a
/// paged assistant (`liquid-glass-ycode.md` §11). Page dots show every
/// step's state and jump to it; each page has the step's glyph, title and
/// summary, then its checks in a grouped box — each with its state, the
/// reason, and its fix: a command to copy and run yourself, words, Install on
/// Headset… or Connect. Back, Re-check and Continue (Finish on the last
/// step) are in the footer. The first step also holds the choices (viewer
/// host, viewer, connection).
@MainActor
public final class HeadsetSetupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    unowned let hub: DevicesController
    public private(set) var step: HeadsetSetupStep = .viewerHost
    var onClose: (() -> Void)?
    let assistant = SetupAssistant(footnote: ExperimentalNotice.headset, footnoteID: "headset-experimental",
                                   statusID: "headset-action-status", dotsID: "headset-steps-panel")
    /// The step the page shows (a change moves the page).
    private var shownStep: HeadsetSetupStep?
    private var connectionPoll: Timer?
    // The first step's choices.
    let hostField = NSTextField()
    let viewerField = NSTextField()
    let simulatorField = NSTextField()
    let optionsField = NSTextField()
    let connectionPopUp = NSPopUpButton()

    init(hub: DevicesController) {
        self.hub = hub
        let w = SetupAssistant.makeWindow(title: "Set Up Headset")
        w.isExcludedFromWindowsMenu = true  // a helper of the hub, as its sheets are
        super.init(window: w)
        w.delegate = self
        build()
        if let r = hub.headset.report { step = r.isReady ? .connect : r.firstProblemStep }
        refresh()
        w.center()
        // The live connection state while the window is open.
        connectionPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.step == .connect, self.hub.headset.checkTask == nil, self.window?.isVisible == true else { return }
                self.hub.checkHeadset()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func windowWillClose(_ notification: Notification) {
        connectionPoll?.invalidate()
        onClose?()
    }

    // MARK: Navigation (tests drive these)

    public func show(_ s: HeadsetSetupStep) {
        step = s
        refresh()
    }

    public func next() {
        if let n = HeadsetSetupStep(rawValue: step.rawValue + 1) { show(n) } else { window?.close() }
    }

    public func back() {
        if let p = HeadsetSetupStep(rawValue: step.rawValue - 1) { show(p) }
    }

    @discardableResult
    public func recheck() -> Task<Void, Never> {
        let t = hub.checkHeadset()
        refresh()
        return t
    }

    /// Continue / Finish (tests).
    var primaryButton: NSButton { assistant.continueButton }
    var backButton: NSButton { assistant.backButton }

    /// The selected step's check rows (tests).
    public var shownChecks: [HeadsetCheck] { hub.headset.report?.checks(in: step) ?? [] }

    // MARK: Views

    private func build() {
        guard let root = window?.contentView else { return }
        assistant.install(in: root, target: self, back: #selector(backClicked), next: #selector(nextClicked), recheck: #selector(recheckClicked))
        assistant.dots.onSelect = { [weak self] i in self?.show(HeadsetSetupStep(rawValue: i) ?? .viewerHost) }
        let s = hub.headsetSettings
        hostField.stringValue = s.viewerHost
        hostField.placeholderString = hub.headset.hubIsLinux ? "This machine" : "user@linux-workstation"
        viewerField.stringValue = s.viewerPath
        simulatorField.stringValue = s.simulatorHostFromViewer
        simulatorField.placeholderString = "The hub's simulator host"
        optionsField.stringValue = s.viewerOptions
        connectionPopUp.addItems(withTitles: HeadsetConnectionKind.allCases.map(\.title))
        connectionPopUp.selectItem(at: HeadsetConnectionKind.allCases.firstIndex(of: s.connection) ?? 0)
        connectionPopUp.target = self
        connectionPopUp.action = #selector(choicesChanged)
        for (f, id) in [(hostField, "headset-host"), (viewerField, "headset-viewer"), (simulatorField, "headset-simulator"), (optionsField, "headset-options")] {
            f.delegate = self
            f.identifier = .init(id)
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) { choicesChanged() }

    @objc func choicesChanged() {
        var s = hub.headsetSettings
        s.viewerHost = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        s.viewerPath = viewerField.stringValue.trimmingCharacters(in: .whitespaces)
        s.simulatorHostFromViewer = simulatorField.stringValue.trimmingCharacters(in: .whitespaces)
        s.viewerOptions = optionsField.stringValue
        s.connection = HeadsetConnectionKind.allCases[max(0, connectionPopUp.indexOfSelectedItem)]
        guard s != hub.headsetSettings else { return }
        hub.headsetSettings = s
        recheck()
    }

    @objc func backClicked() { back() }
    @objc func nextClicked() { next() }
    @objc func recheckClicked() { recheck() }

    static func dotState(_ s: HeadsetCheckState?) -> SetupDotState {
        switch s {
        case .ok?: .ok
        case .missing?: .missing
        case .unknown?: .unknown
        case nil: .notChecked
        }
    }

    /// A step's state: ok when every check is, missing when one is.
    func state(of s: HeadsetSetupStep) -> HeadsetCheckState? {
        hub.headset.report.map { r in
            let cs = r.checks(in: s)
            if cs.allSatisfy({ $0.state == .ok }) { return .ok }
            return cs.contains { $0.state == .missing } ? .missing : .unknown
        }
    }

    /// Rebuilds the window from the hub's report.
    func refresh() {
        let report = hub.headset.report
        let checking = hub.headset.checkTask != nil
        let a = assistant
        if checking { a.spinner.startAnimation(nil) } else { a.spinner.stopAnimation(nil) }
        a.recheckButton.isEnabled = !checking
        a.statusLabel.stringValue = hub.headset.actionStatus ?? (checking ? "Checking…" : report.map { "Status: \($0.status.rawValue)" } ?? "")
        a.dots.update(HeadsetSetupStep.allCases.map { ($0.title, Self.dotState(state(of: $0))) }, current: step.rawValue)
        let fill = { [self] in
            a.setHeader(glyph: step.glyph, title: step.title, summary: step.summary)
            var views: [NSView] = []
            if step == .viewerHost { views.append(SetupCentered(choices())) }
            let checks = shownChecks
            if !checks.isEmpty { views.append(SetupGroupBox(rows: checks.map(row), identifier: "headset-checks")) }
            if report == nil { views.append(DevicesController.secondary(checking ? "Checking…" : "Not checked yet.")) }
            a.setColumn(views)
        }
        if let shown = shownStep, shown != step { a.turn(forward: step.rawValue > shown.rawValue, fill: fill) } else { fill() }
        shownStep = step
        a.backButton.isHidden = step == .viewerHost
        a.continueButton.title = step == .connect ? "Finish" : "Continue"
    }

    private func choices() -> NSView {
        func label(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            return l
        }
        let note = NSTextField(wrappingLabelWithString: hub.headset.hubIsLinux
            ? "Leave the viewer host empty to use this machine."
            : "WiVRn does not run on macOS: the headset view runs on a Linux PC, reached with an ssh key.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        let grid = NSGridView(views: [[label("Viewer host:"), hostField], [label("Viewer:"), viewerField],
                                      [label("Simulator host from there:"), simulatorField], [label("Viewer options:"), optionsField],
                                      [label("Headset connects by:"), connectionPopUp], [NSGridCell.emptyContentView, note]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.identifier = .init("headset-choices")
        for f in [hostField, viewerField, simulatorField, optionsField] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        note.preferredMaxLayoutWidth = 300
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return grid
    }

    private func row(_ c: HeadsetCheck) -> NSView {
        let (name, color) = SetupAssistant.mark(Self.dotState(c.state))
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: c.state.rawValue) ?? NSImage())
        icon.contentTintColor = color
        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let reason = NSTextField(wrappingLabelWithString: c.reason)
        reason.textColor = .secondaryLabelColor
        reason.preferredMaxLayoutWidth = SetupGroupBox.textWidth
        let text = NSStackView(views: [title, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let fix = c.fix, c.state != .ok { text.addArrangedSubview(fixView(fix)) }
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 8
        row.identifier = .init("headset-check-\(c.id.rawValue)")
        row.setAccessibilityLabel("\(c.title): \(c.state.rawValue). \(c.reason)")
        reason.widthAnchor.constraint(lessThanOrEqualToConstant: SetupGroupBox.textWidth).isActive = true
        return row
    }

    private func fixView(_ fix: HeadsetFix) -> NSView {
        switch fix {
        case .command(let cmd):
            let field = NSTextField(wrappingLabelWithString: cmd)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            field.identifier = .init("headset-fix-command")
            field.preferredMaxLayoutWidth = SetupGroupBox.textWidth - 72
            field.widthAnchor.constraint(lessThanOrEqualToConstant: SetupGroupBox.textWidth - 72).isActive = true
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyCommand(_:)))
            GlassBars.style(copy)
            copy.controlSize = .small
            copy.toolTip = cmd
            let note = NSTextField(labelWithString: "Run this yourself on \(hub.headsetHost.title).")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .tertiaryLabelColor
            let line = NSStackView(views: [field, copy])
            let v = NSStackView(views: [line, note])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 2
            return v
        case .instructions(let words):
            let l = NSTextField(wrappingLabelWithString: words)
            l.font = .systemFont(ofSize: 12)
            l.preferredMaxLayoutWidth = SetupGroupBox.textWidth
            l.widthAnchor.constraint(lessThanOrEqualToConstant: SetupGroupBox.textWidth).isActive = true
            return l
        case .installClient(let p):
            let b = NSButton(title: "Install on Headset…", target: self, action: #selector(installClicked(_:)))
            GlassBars.style(b, primary: true)
            b.controlSize = .small
            b.identifier = .init("headset-install")
            let store = NSTextField(wrappingLabelWithString: "WiVRn \(p.version) from WiVRn's releases (\(HeadsetClientPackage.license)), or the Meta Store.")
            store.font = .systemFont(ofSize: 11)
            store.preferredMaxLayoutWidth = SetupGroupBox.textWidth - 160
            store.widthAnchor.constraint(lessThanOrEqualToConstant: SetupGroupBox.textWidth - 160).isActive = true
            store.textColor = .secondaryLabelColor
            let v = NSStackView(views: [b, store])
            v.alignment = .centerY
            return v
        case .connect:
            let b = NSButton(title: "Connect", target: self, action: #selector(connectClicked(_:)))
            GlassBars.style(b, primary: true)
            b.controlSize = .small
            b.identifier = .init("headset-connect")
            return b
        }
    }

    @objc func copyCommand(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.toolTip ?? "", forType: .string)
        assistant.statusLabel.stringValue = "Copied. Run it in a terminal on \(hub.headsetHost.title)."
    }

    @objc func installClicked(_ sender: Any?) {
        guard case .installClient(let p)? = hub.headset.report?.checks.first(where: { if case .installClient = $0.fix { true } else { false } })?.fix else { return }
        hub.installHeadsetClient(p)
    }

    @objc func connectClicked(_ sender: Any?) { hub.connectHeadset() }
}
