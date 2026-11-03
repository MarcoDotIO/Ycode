import AppKit
import YcodeIDECore

/// Set Up Headset… (`specs/ide/device-hub.md` §I.12): the onboarding as a
/// stepped checklist. The steps float on a glass panel at the left, over the
/// window's backdrop (`liquid-glass-ycode.md`: the system's materials, for the
/// controls layer only); the selected step's checks are plain text on the
/// window's background — each with its state, the reason, and its fix: a
/// command to copy and run yourself, words, Install on Headset… or Connect —
/// and Re-check, Back and Next are glass buttons, Next tinted. The first step
/// also holds the choices (viewer host, viewer, connection).
@MainActor
public final class HeadsetSetupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    unowned let hub: DevicesController
    public private(set) var step: HeadsetSetupStep = .viewerHost
    var onClose: (() -> Void)?
    private let stepList = NSStackView()
    private let backdrop = HeadsetBackdropView()
    private let content = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let recheckButton = NSButton(title: "Re-check", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var connectionPoll: Timer?
    // The first step's choices.
    let hostField = NSTextField()
    let viewerField = NSTextField()
    let simulatorField = NSTextField()
    let optionsField = NSTextField()
    let connectionPopUp = NSPopUpButton()

    init(hub: DevicesController) {
        self.hub = hub
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Set Up Headset"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }
        w.isReleasedWhenClosed = false
        w.isExcludedFromWindowsMenu = true  // a helper of the hub, as its sheets are
        w.contentMinSize = NSSize(width: 640, height: 440)
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

    /// Next / Finish (tests).
    var primaryButton: NSButton { nextButton }

    /// The selected step's check rows (tests).
    public var shownChecks: [HeadsetCheck] { hub.headset.report?.checks(in: step) ?? [] }

    // MARK: Views

    static let sidebarWidth: CGFloat = 196
    static let panelInset: CGFloat = 8

    private func build() {
        guard let root = window?.contentView else { return }
        stepList.orientation = .vertical
        stepList.alignment = .leading
        stepList.spacing = 2
        // Under the window's buttons, which sit on the panel.
        stepList.edgeInsets = NSEdgeInsets(top: 44, left: 8, bottom: 12, right: 8)
        let listHost = NSView()
        stepList.translatesAutoresizingMaskIntoConstraints = false
        listHost.addSubview(stepList)
        NSLayoutConstraint.activate([
            stepList.topAnchor.constraint(equalTo: listHost.topAnchor), stepList.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
            stepList.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),
        ])
        let side = GlassBars.panel(content: listHost, cornerRadius: 18)
        side.identifier = .init("headset-steps-panel")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        // The content runs the window's width, under the panel and the bar;
        // its insets keep the text clear of them.
        let leading = Self.sidebarWidth + Self.panelInset
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 28, left: leading, bottom: 56, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: -leading, bottom: 0, right: 0)
        let doc = FlippedStack()
        doc.orientation = .vertical
        doc.alignment = .leading
        doc.spacing = 10
        doc.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 16, right: 24)
        let experimental = NSTextField(wrappingLabelWithString: ExperimentalNotice.headset)
        experimental.font = .systemFont(ofSize: 11)
        experimental.textColor = .secondaryLabelColor
        experimental.identifier = .init("headset-experimental")
        for v in [experimental, titleLabel, summaryLabel, content] { doc.addArrangedSubview(v) }
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = .init("headset-action-status")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for (b, sel) in [(backButton, #selector(backClicked)), (nextButton, #selector(nextClicked)), (recheckButton, #selector(recheckClicked))] {
            b.target = self
            b.action = sel
            GlassBars.style(b, primary: b === nextButton)
            b.controlSize = .large
        }
        nextButton.keyEquivalent = "\r"
        let bar = NSStackView(views: [spinner, statusLabel, NSView(), recheckButton, backButton, nextButton])
        bar.spacing = 8
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [backdrop, scroll, side, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let inset = Self.panelInset
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor), backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset), side.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset), side.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 24), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: leading), doc.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48),
            experimental.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48),
            content.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48),
        ])
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

    static func symbol(_ s: HeadsetCheckState?) -> (String, NSColor) {
        switch s {
        case .ok: ("checkmark.circle.fill", .systemGreen)
        case .missing: ("xmark.circle.fill", .systemRed)
        default: ("questionmark.circle", .secondaryLabelColor)
        }
    }

    /// Rebuilds the window from the hub's report.
    func refresh() {
        let report = hub.headset.report
        let checking = hub.headset.checkTask != nil
        if checking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        recheckButton.isEnabled = !checking
        statusLabel.stringValue = hub.headset.actionStatus ?? (checking ? "Checking…" : report.map { "Status: \($0.status.rawValue)" } ?? "")
        // Steps.
        stepList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in HeadsetSetupStep.allCases {
            let state: HeadsetCheckState? = report.map { r in
                let cs = r.checks(in: s)
                if cs.allSatisfy({ $0.state == .ok }) { return .ok }
                return cs.contains { $0.state == .missing } ? .missing : .unknown
            }
            let row = HeadsetStepRow(step: s, state: state, selected: s == step, target: self, action: #selector(stepClicked(_:)))
            stepList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stepList.widthAnchor, constant: -16).isActive = true
        }
        // The step.
        titleLabel.stringValue = step.title
        summaryLabel.stringValue = step.summary
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if step == .viewerHost { content.addArrangedSubview(choices()) }
        for c in shownChecks { content.addArrangedSubview(row(c)) }
        if report == nil { content.addArrangedSubview(DevicesController.secondary(checking ? "Checking…" : "Not checked yet.")) }
        backButton.isEnabled = step != .viewerHost
        nextButton.title = step == .connect ? "Finish" : "Next"
        // The device's own picture under the panel, while it runs.
        backdrop.picture = hub.selected.flatMap { hub.links[$0.identifier]?.session.image }
    }

    @objc func stepClicked(_ sender: NSButton) { show(HeadsetSetupStep(rawValue: sender.tag) ?? .viewerHost) }

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
        grid.rowSpacing = 8
        for f in [hostField, viewerField, simulatorField, optionsField] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true }
        return grid
    }

    private func row(_ c: HeadsetCheck) -> NSView {
        let (name, color) = Self.symbol(c.state)
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: c.state.rawValue) ?? NSImage())
        icon.contentTintColor = color
        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let reason = NSTextField(wrappingLabelWithString: c.reason)
        reason.textColor = .secondaryLabelColor
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
        reason.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        return row
    }

    private func fixView(_ fix: HeadsetFix) -> NSView {
        switch fix {
        case .command(let cmd):
            let field = NSTextField(labelWithString: cmd)
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isSelectable = true
            field.identifier = .init("headset-fix-command")
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
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
            return l
        case .installClient(let p):
            let b = NSButton(title: "Install on Headset…", target: self, action: #selector(installClicked(_:)))
            GlassBars.style(b, primary: true)
            b.controlSize = .small
            b.identifier = .init("headset-install")
            let store = NSTextField(labelWithString: "WiVRn \(p.version) from WiVRn's releases (\(HeadsetClientPackage.license)), or the Meta Store.")
            store.font = .systemFont(ofSize: 11)
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
        statusLabel.stringValue = "Copied. Run it in a terminal on \(hub.headsetHost.title)."
    }

    @objc func installClicked(_ sender: Any?) {
        guard case .installClient(let p)? = hub.headset.report?.checks.first(where: { if case .installClient = $0.fix { true } else { false } })?.fix else { return }
        hub.installHeadsetClient(p)
    }

    @objc func connectClicked(_ sender: Any?) { hub.connectHeadset() }
}

/// One step in the glass panel: its state's mark in the system's colours (a
/// distinct shape for each state), the title in the label colour, which the
/// material keeps legible, and the recessed pill under the selected step.
@MainActor
final class HeadsetStepRow: NSView {
    init(step: HeadsetSetupStep, state: HeadsetCheckState?, selected: Bool, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let (name, color) = HeadsetSetupWindowController.symbol(state)
        let mark = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: state?.rawValue ?? "not checked") ?? NSImage())
        mark.contentTintColor = color
        let title = NSTextField(labelWithString: "\(step.rawValue + 1). \(step.title)")
        title.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        title.textColor = .labelColor
        // The whole row clicks; the mark and title show through a clear button.
        let b = NSButton(title: "", target: target, action: action)
        b.isBordered = false
        b.isTransparent = true
        b.tag = step.rawValue
        b.identifier = .init("headset-step-\(step.rawValue)")
        b.setAccessibilityLabel("\(step.title): \(state?.rawValue ?? "not checked")")
        let pill = SelectionPillView()
        pill.isHidden = !selected
        for v in [pill, mark, title, b] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor), pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 2), pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 7), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            b.leadingAnchor.constraint(equalTo: leadingAnchor), b.trailingAnchor.constraint(equalTo: trailingAnchor),
            b.topAnchor.constraint(equalTo: topAnchor), b.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// What the window's glass panel floats over: the window's background, with
/// the running device's picture fading in from the leading edge (a quiet accent
/// wash when there is none: glass over one flat colour reads as a plain
/// rectangle), gone by where the text starts. Plain with Reduce Transparency
/// or Increase Contrast.
final class HeadsetBackdropView: NSView {
    var picture: CGImage? { didSet { if picture !== oldValue { needsDisplay = true } } }
    private let pictureLayer = CALayer()
    private let fade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(pictureLayer)
        pictureLayer.contentsGravity = .resizeAspectFill
        pictureLayer.masksToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        pictureLayer.mask = fade
        identifier = .init("headset-backdrop")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    static var plain: Bool {
        let w = NSWorkspace.shared
        return w.accessibilityDisplayShouldReduceTransparency || w.accessibilityDisplayShouldIncreaseContrast
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // Gone before the text starts (24 points past the panel).
        let width = HeadsetSetupWindowController.sidebarWidth + HeadsetSetupWindowController.panelInset + 20
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        fade.frame = pictureLayer.bounds
        fade.locations = [0, 0.8, 1]
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        pictureLayer.isHidden = Self.plain
        pictureLayer.contents = picture
        pictureLayer.backgroundColor = picture == nil ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}
