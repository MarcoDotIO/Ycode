import AppKit
import YcodeIDECore

/// Get a Simulator Runtime… (`specs/simulator/runtime-onboarding.md` §11;
/// the headset wizard's layout, `device-hub.md` §I.12): the steps float on
/// a glass panel at the left; the selected step's choices, runtimes and
/// checks are plain text on the window's background, each check with its
/// state, reason and one fix; Re-check, Back and Next are glass buttons.
/// Nothing changes a machine until the user confirms a sheet that shows the
/// exact command. Ycode never downloads a runtime (#55).
@MainActor
public final class RuntimeSetupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    public let session: RuntimeSetupSession
    /// The one open wizard.
    public static var shared: RuntimeSetupWindowController?
    /// Answers confirmations instead of a sheet (tests: true confirms,
    /// false cancels, nil leaves it waiting for the test to answer).
    var answerConfirmation: ((RuntimeConfirmation) -> Bool?)?
    /// Picks a file instead of the open panel (tests).
    var pickFile: (() -> String?)?

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
    /// The content's scroll view and the footer (tests check they do not overlap).
    let scroll = NSScrollView()
    let footer = NSStackView()
    private var shownConfirmation: RuntimeConfirmation?
    // The choices' fields.
    let hostField = NSTextField()
    let dataField = NSTextField()
    let linkField = NSTextField()
    let portsField = NSTextField()

    /// Shows the wizard (one at a time), on `step` when given, else on the first problem.
    @discardableResult
    public static func show(step: RuntimeSetupStep? = nil, session: RuntimeSetupSession? = nil) -> RuntimeSetupWindowController {
        let wc = shared ?? RuntimeSetupWindowController(session: session ?? RuntimeSetupSession(defaults: Preferences.shared.defaults))
        shared = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        let t = wc.session.recheck()
        if let step { wc.session.show(step) } else {
            Task { @MainActor in
                await t.value
                if wc.session.step == .target, wc.session.report?.readyPlatforms.isEmpty == false { return }
                wc.session.openOnFirstProblem()
            }
        }
        return wc
    }

    /// First launch (§3, §11.4): once per installation, when this Mac has no
    /// usable runtime for the chosen platforms, the wizard opens. Not under
    /// tests or with `YCODE_NO_FIRST_LAUNCH`.
    @discardableResult
    public static func offerAtFirstLaunch(defaults: UserDefaults = Preferences.shared.defaults,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Task<Void, Never>? {
        guard !defaults.bool(forKey: RuntimeSetupChoices.offeredKey), environment["YCODE_NO_FIRST_LAUNCH"] == nil,
              environment["XCTestConfigurationFilePath"] == nil, NSClassFromString("XCTestCase") == nil,
              !CommandLine.arguments.contains(where: { $0.hasSuffix(".xctest") || $0.contains("swiftpm-testing-helper") }) else { return nil }
        defaults.set(true, forKey: RuntimeSetupChoices.offeredKey)
        let choices = RuntimeSetupChoices.load(defaults)
        return Task { @MainActor in
            let r = await RuntimeSetupChecker(choices: choices).run()
            if choices.useHost || r.readyPlatforms.isEmpty { show() }
        }
    }

    public init(session: RuntimeSetupSession) {
        self.session = session
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Simulator Runtimes"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 680, height: 460)
        w.identifier = .init("runtime-setup")
        super.init(window: w)
        w.delegate = self
        build()
        session.onChange = { [weak self] in self?.refresh() }
        refresh()
        w.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func windowWillClose(_ notification: Notification) {
        session.onChange = nil
        if Self.shared === self { Self.shared = nil }
    }

    // MARK: Navigation

    public func next() { if session.isLastStep { window?.close() } else { session.next() } }
    public func back() { session.back() }

    var primaryButton: NSButton { nextButton }

    // MARK: Views

    static let sidebarWidth = HeadsetSetupWindowController.sidebarWidth
    static let panelInset = HeadsetSetupWindowController.panelInset

    private func build() {
        guard let root = window?.contentView else { return }
        stepList.orientation = .vertical
        stepList.alignment = .leading
        stepList.spacing = 2
        stepList.edgeInsets = NSEdgeInsets(top: 44, left: 8, bottom: 12, right: 8)
        let listHost = NSView()
        stepList.translatesAutoresizingMaskIntoConstraints = false
        listHost.addSubview(stepList)
        NSLayoutConstraint.activate([
            stepList.topAnchor.constraint(equalTo: listHost.topAnchor), stepList.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
            stepList.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),
        ])
        let side = GlassBars.panel(content: listHost, cornerRadius: 18)
        side.identifier = .init("runtime-steps-panel")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        let leading = Self.sidebarWidth + Self.panelInset
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // The content ends above the footer (it never runs under Re-check, Back and Next).
        scroll.contentInsets = NSEdgeInsets(top: 28, left: leading, bottom: 12, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: -leading, bottom: 0, right: 0)
        let doc = FlippedStack()
        doc.orientation = .vertical
        doc.alignment = .leading
        doc.spacing = 10
        doc.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 16, right: 24)
        let experimental = NSTextField(wrappingLabelWithString: ExperimentalNotice.runtimes)
        experimental.font = .systemFont(ofSize: 11)
        experimental.textColor = .secondaryLabelColor
        experimental.identifier = .init("runtime-experimental")
        for v in [experimental, titleLabel, summaryLabel, content] { doc.addArrangedSubview(v) }
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.identifier = .init("runtime-status")
        statusLabel.maximumNumberOfLines = 2
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
        let bar = footer
        bar.setViews([spinner, statusLabel, NSView(), recheckButton, backButton, nextButton], in: .leading)
        bar.spacing = 8
        bar.identifier = .init("runtime-footer")
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
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 24), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: leading), doc.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48),
            experimental.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48),
            content.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -48),
        ])
        let h = session.choices.host
        hostField.stringValue = h.destination
        hostField.placeholderString = "user@sim-host"
        dataField.stringValue = h.dataDirectory
        dataField.placeholderString = "/data/ycode"
        linkField.stringValue = h.linkName
        linkField.placeholderString = "The host's name on Ycode's link"
        portsField.stringValue = "\(h.tcpPort)/\(h.udpPort)"
        portsField.placeholderString = "47800/47801"
        for (f, id) in [(hostField, "runtime-host"), (dataField, "runtime-data"), (linkField, "runtime-link"), (portsField, "runtime-ports")] {
            f.delegate = self
            f.identifier = .init(id)
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) { hostChanged() }

    @objc func hostChanged() {
        var h = session.choices.host
        h.destination = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        h.dataDirectory = dataField.stringValue.trimmingCharacters(in: .whitespaces)
        h.linkName = linkField.stringValue.trimmingCharacters(in: .whitespaces)
        if let (t, u) = RuntimeHostSettings.ports(portsField.stringValue) { (h.tcpPort, h.udpPort) = (t, u) }
        session.setHost(h)
    }

    @objc func backClicked() { back() }
    @objc func nextClicked() { next() }
    @objc func recheckClicked() { session.recheck() }

    static func symbol(_ s: SetupCheckState?) -> (String, NSColor) {
        switch s {
        case .ok: ("checkmark.circle.fill", .systemGreen)
        case .missing: ("xmark.circle.fill", .systemRed)
        case .notApplicable: ("minus.circle", .secondaryLabelColor)
        default: ("questionmark.circle", .secondaryLabelColor)
        }
    }

    /// Rebuilds the window from the session.
    func refresh() {
        // The fields follow the session unless the user is typing in one.
        let h = session.choices.host
        for (f, v) in [(hostField, h.destination), (dataField, h.dataDirectory), (linkField, h.linkName), (portsField, "\(h.tcpPort)/\(h.udpPort)")] where f.currentEditor() == nil && f.stringValue != v {
            f.stringValue = v
        }
        let busy = session.isChecking || session.running != nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        recheckButton.isEnabled = !session.isChecking
        statusLabel.stringValue = session.running ?? session.status ?? (session.isChecking ? "Checking…" : "")
        stepList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, s) in session.steps.enumerated() {
            let row = RuntimeStepRow(index: i, step: s, state: session.state(of: s), selected: s == session.step, target: self, action: #selector(stepClicked(_:)))
            stepList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stepList.widthAnchor, constant: -16).isActive = true
        }
        titleLabel.stringValue = session.step.title
        summaryLabel.stringValue = session.step.summary(machine: session.machine, target: session.choices.target)
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in stepViews() { content.addArrangedSubview(v) }
        if session.report == nil { content.addArrangedSubview(DevicesController.secondary(session.isChecking ? "Checking…" : "Not checked yet.")) }
        backButton.isEnabled = !session.isFirstStep
        nextButton.title = session.isLastStep ? "Done" : "Next"
        if let c = session.confirmation, c != shownConfirmation { present(c) }
    }

    @objc func stepClicked(_ sender: NSButton) {
        if let s = RuntimeSetupStep(rawValue: sender.tag) { session.show(s) }
    }

    // MARK: Step contents

    func stepViews() -> [NSView] {
        rowRecords = []
        fixActions = []
        var out: [NSView] = []
        switch session.step {
        case .target: out.append(targetChoices())
        case .host: out.append(hostChoices())
        case .prepare: out += prepareViews()
        case .runtimes: out += runtimeLists()
        case .add: out += addViews()
        case .finish: out += finishViews()
        }
        let checks = session.shownChecks
        if !checks.isEmpty {
            if session.step != .target && session.step != .host { out.append(heading("Checks")) }
            out += checks.map(row)
        }
        if session.logStep == session.step, !session.log.isEmpty { out.append(logView()) }
        return out
    }

    func heading(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    func note(_ t: String, id: String? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 540).isActive = true
        if let id { l.identifier = .init(id) }
        return l
    }

    func button(_ title: String, _ action: Selector, id: String, primary: Bool = false, tag: Int = 0) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        GlassBars.style(b, primary: primary)
        b.controlSize = .regular
        b.identifier = .init(id)
        b.tag = tag
        return b
    }

    private func targetChoices() -> NSView {
        let platforms = NSStackView()
        platforms.spacing = 14
        for (i, p) in SimPlatform.allCases.enumerated() {
            let b = NSButton(checkboxWithTitle: p.title, target: self, action: #selector(platformToggled(_:)))
            b.tag = i
            b.state = session.choices.platforms.contains(p) ? .on : .off
            b.identifier = .init("runtime-platform-\(p.rawValue)")
            platforms.addArrangedSubview(b)
        }
        let here = NSButton(radioButtonWithTitle: session.machine.isMac ? "On this Mac" : "On this computer", target: self, action: #selector(targetChanged(_:)))
        here.tag = 0
        here.state = session.choices.useHost ? .off : .on
        here.isEnabled = session.machine.canRunSimulatorHere
        here.identifier = .init("runtime-target-here")
        let host = NSButton(radioButtonWithTitle: "On a simulator host (arm64 Linux with KVM)", target: self, action: #selector(targetChanged(_:)))
        host.tag = 1
        host.state = session.choices.useHost ? .on : .off
        host.identifier = .init("runtime-target-host")
        let whereStack = NSStackView(views: [here, host])
        whereStack.orientation = .vertical
        whereStack.alignment = .leading
        whereStack.spacing = 6
        let grid = NSGridView(views: [[label("Platforms:"), platforms], [label("Simulators run:"), whereStack]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        let v = NSStackView(views: [grid, note(RuntimeSize.convention)])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        return v
    }

    func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        return l
    }

    @objc func platformToggled(_ sender: NSButton) {
        session.setPlatform(SimPlatform.allCases[sender.tag], on: sender.state == .on)
    }

    @objc func targetChanged(_ sender: NSButton) { session.setUseHost(sender.tag == 1) }

    private func hostChoices() -> NSView {
        let grid = NSGridView(views: [[label("Host:"), hostField], [label("Data folder:"), dataField], [label("Link name:"), linkField],
                                      [label("Ports (TCP/UDP):"), portsField],
                                      [NSGridCell.emptyContentView, note("Ycode logs in with an ssh key only and never asks for a password. The data folder holds runtimes and devices; choose a volume with room for them (about 16 GB per iOS runtime).")]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        for f in [hostField, dataField, linkField] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true }
        return grid
    }

    private func prepareViews() -> [NSView] {
        var out: [NSView] = []
        let run = button("Check Host", #selector(setupReportClicked), id: "runtime-setup-report", primary: session.hostSetup == nil)
        let view = button("View Script…", #selector(viewScriptClicked), id: "runtime-setup-view")
        let save = button("Save Script…", #selector(saveScriptClicked), id: "runtime-setup-save")
        run.isEnabled = session.running == nil && session.choices.host.isComplete
        out.append(NSStackView(views: [run, view, save]))
        out.append(note("The script only looks until you apply it. View it first, or save it and run it yourself: bash ycode-host-setup --report."))
        guard let setup = session.hostSetup else { return out }
        if !setup.rootSteps.isEmpty {
            out.append(heading("Needs root (run in your terminal)"))
            for s in setup.rootSteps { out.append(stepLine(s)) }
            let prep = button("Show Terminal Command…", #selector(rootStepsClicked), id: "runtime-setup-root")
            out.append(prep)
            out.append(commandLine(session.rootCommand, note: "sudo asks for your password in your terminal; Ycode never sees it."))
        }
        if !setup.userSteps.isEmpty {
            out.append(heading("Ycode can do as you"))
            for s in setup.userSteps { out.append(stepLine(s)) }
            let apply = button("Apply…", #selector(applyClicked), id: "runtime-setup-apply", primary: true)
            apply.isEnabled = session.running == nil
            out.append(apply)
        }
        if setup.isSettled { out.append(note(setup.passed == true ? "Nothing left to do: a second run only reports." : "Nothing more the script can do; the checks below say what is left.")) }
        return out
    }

    func stepLine(_ s: HostSetupOutput.Step) -> NSView {
        let t = NSTextField(labelWithString: s.command)
        t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        t.isSelectable = true
        t.lineBreakMode = .byTruncatingMiddle
        t.widthAnchor.constraint(lessThanOrEqualToConstant: 540).isActive = true
        let id = NSTextField(labelWithString: s.id)
        id.font = .systemFont(ofSize: 11, weight: .medium)
        id.textColor = .secondaryLabelColor
        id.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return NSStackView(views: [id, t])
    }

    func commandLine(_ cmd: String, note words: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: cmd)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isSelectable = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyCommand(_:)))
        GlassBars.style(copy)
        copy.controlSize = .small
        copy.toolTip = cmd
        let v = NSStackView(views: [NSStackView(views: [field, copy]), note(words)])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 2
        return v
    }

    private func runtimeLists() -> [NSView] {
        var out: [NSView] = []
        let r = session.report
        if session.choices.useHost {
            out.append(heading("On \(session.choices.host.hostName.isEmpty ? "the host" : session.choices.host.hostName)"))
            let host = r?.host ?? []
            if host.isEmpty { out.append(note(r == nil ? "Not checked yet." : "No runtimes on the host yet.")) }
            out += host.map { runtimeRow($0, copy: false) }
            out.append(heading(session.machine.isMac ? "On this Mac" : "On this computer"))
            let local = session.copyableRuntimes
            if local.isEmpty { out.append(note("No runtimes here to copy. Use Add a Runtime to pick a runtime bundle or RuntimeRoot.")) }
            out += local.map { runtimeRow($0, copy: true) }
        } else {
            let local = r?.local ?? []
            if local.isEmpty, r != nil { out.append(note("No runtimes yet.")) }
            out += local.map { runtimeRow($0, copy: false) }
        }
        return out
    }

    private var rowRecords: [SimRuntimeRecord] = []

    func runtimeRow(_ rec: SimRuntimeRecord, copy: Bool) -> NSView {
        let (sym, color) = Self.symbol(rec.isUsable ? .ok : .missing)
        let icon = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: rec.isUsable ? "usable" : "not usable") ?? NSImage())
        icon.contentTintColor = color
        let title = NSTextField(labelWithString: rec.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        var details = [rec.sizeText, rec.architectures.joined(separator: ", ")]
        if let used = rec.lastUsed { details.append("last used \(used.prefix(10))") }
        switch rec.owner {
        case .coreSimulator: details.append("installed by Xcode; manage it in Xcode")
        case .ycode: details.append("copied by Ycode")
        case .external: details.append("configured on the host")
        }
        if !rec.isUsable { details.append(rec.availabilityError ?? rec.state) }
        let detail = NSTextField(wrappingLabelWithString: details.filter { !$0.isEmpty }.joined(separator: " · "))
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text, NSView()])
        row.alignment = .top
        row.spacing = 8
        rowRecords.append(rec)
        let tag = rowRecords.count - 1
        if copy {
            let b = button("Copy to Host…", #selector(copyRecordClicked(_:)), id: "runtime-copy-\(rec.folderName)", tag: tag)
            b.isEnabled = session.running == nil && session.choices.host.isComplete
            row.addArrangedSubview(b)
        } else if rec.isRemovable {
            row.addArrangedSubview(button("Remove…", #selector(removeClicked(_:)), id: "runtime-remove-\(rec.folderName)", tag: tag))
        }
        row.identifier = .init("runtime-row-\(rec.location == .thisMachine ? "here" : "host")-\(rec.folderName)")
        row.setAccessibilityLabel("\(rec.title), \(rec.sizeText)")
        return row
    }

    private func addViews() -> [NSView] {
        var out: [NSView] = []
        let pick = button(session.choices.useHost || !session.machine.isMac ? "Choose Runtime…" : "Choose Runtime File…", #selector(chooseClicked),
                          id: "runtime-choose", primary: session.picked == nil)
        pick.isEnabled = session.running == nil
        out.append(pick)
        if session.machine.isMac && !session.choices.useHost {
            out.append(note("A runtime disk image (.dmg) you downloaded yourself. Ycode adds it with xcrun simctl runtime add after you confirm the command."))
        } else {
            out.append(note("A .simruntime bundle, or its RuntimeRoot, from your own Xcode installation."))
        }
        if let p = session.picked {
            let what: String
            switch p.kind {
            case .diskImage: what = "Runtime disk image"
            case .bundle: what = "Runtime bundle"
            case .runtimeRoot: what = "RuntimeRoot"
            case .unknown: what = "Not a runtime"
            }
            let line = NSTextField(wrappingLabelWithString: "\(what): \((p.path as NSString).lastPathComponent)" + (p.record.map { " — \($0.title), \($0.sizeText)" } ?? ""))
            line.identifier = .init("runtime-picked")
            out.append(line)
            if let a = session.pickedAction {
                let title: String
                switch a {
                case .importImage: title = "Add to This Mac…"
                case .copyToHost: title = "Copy to Host…"
                default: title = "Copy…"
                }
                let go = button(title, #selector(addPickedClicked), id: "runtime-add-picked", primary: true)
                go.isEnabled = session.running == nil
                out.append(go)
            }
        }
        if let t = session.transfer {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.identifier = .init("runtime-transfer-progress")
            bar.widthAnchor.constraint(equalToConstant: 360).isActive = true
            let text: String
            switch session.transferState {
            case .copying(let kb): bar.doubleValue = t.fraction(copiedKB: kb); text = "Copying \(t.record.title): " + t.progressText(copiedKB: kb)
            case .interrupted(let kb, let why): bar.doubleValue = t.fraction(copiedKB: kb); text = "Stopped at \(t.progressText(copiedKB: kb)). \(why)"
            case .finished: bar.doubleValue = 1; text = "\(t.record.title) is on \(t.host.hostName)."
            case .failed(let why): text = why
            case .idle: text = ""
            }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.identifier = .init("runtime-transfer-text")
            var line: [NSView] = [bar]
            if case .copying = session.transferState { line.append(button("Stop", #selector(stopClicked), id: "runtime-transfer-stop")) }
            if case .interrupted = session.transferState {
                line.append(button("Resume", #selector(resumeClicked), id: "runtime-transfer-resume", primary: true))
            }
            out.append(NSStackView(views: line))
            out.append(label)
        }
        // Where Xcode would download (§11.6): how to get one with your own tools.
        let missing = SimPlatform.allCases.filter { p in session.choices.platforms.contains(p) && !(session.report?.readyPlatforms.contains(p) ?? false) }
        if let p = missing.first {
            out.append(heading("Don't have a runtime?"))
            out.append(note(RuntimeSetupChecker.acquisitionNote(p), id: "runtime-acquisition"))
        }
        return out
    }

    private func finishViews() -> [NSView] {
        let ready = session.report?.readyPlatforms ?? []
        var out: [NSView] = []
        if ready.isEmpty {
            out.append(note("No platform has a runtime yet. Go back to Add a Runtime, or finish now and come back from Settings ▸ Components."))
        }
        for p in SimPlatform.allCases where session.choices.platforms.contains(p) {
            let ok = ready.contains(p)
            let (sym, color) = Self.symbol(ok ? .ok : .missing)
            let icon = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = color
            let whereText = session.choices.useHost ? "on \(session.choices.host.hostName)" : (session.machine.isMac ? "on this Mac" : "on this computer")
            let t = NSTextField(labelWithString: ok ? "\(p.title) simulators run \(whereText)." : "\(p.title): no runtime yet.")
            out.append(NSStackView(views: [icon, t]))
        }
        out += session.finishNotes.map { note($0, id: "runtime-finish-note") }
        return out
    }

    private func row(_ c: RuntimeCheck) -> NSView {
        let (name, color) = Self.symbol(c.state)
        let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: c.state.title) ?? NSImage())
        icon.contentTintColor = color
        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let reason = NSTextField(wrappingLabelWithString: c.reason)
        reason.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let fix = c.fix, c.state != .ok, c.state != .notApplicable { text.addArrangedSubview(fixView(fix, check: c)) }
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 8
        row.identifier = .init("runtime-check-\(c.id)")
        row.setAccessibilityLabel("\(c.title): \(c.state.title). \(c.reason)")
        reason.widthAnchor.constraint(lessThanOrEqualToConstant: 500).isActive = true
        return row
    }

    private var fixActions: [RuntimeAction] = []

    private func fixView(_ fix: RuntimeFix, check: RuntimeCheck) -> NSView {
        switch fix {
        case .command(let cmd):
            let host = check.id.hasPrefix("host.") || check.id.hasPrefix("setup.") ? "in your terminal" : "in Terminal"
            return commandLine(cmd, note: "Run this yourself \(host).")
        case .instructions(let words):
            let l = NSTextField(wrappingLabelWithString: words)
            l.font = .systemFont(ofSize: 12)
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 500).isActive = true
            return l
        case .step(let s):
            return button("Go to \(s.title)", #selector(goToStep(_:)), id: "runtime-fix-step-\(check.id)", tag: s.rawValue)
        case .action(let a):
            fixActions.append(a)
            let title: String
            switch a {
            case .remove: title = "Remove…"
            case .provisionApply: title = "Apply…"
            default: title = "Fix…"
            }
            return button(title, #selector(fixActionClicked(_:)), id: "runtime-fix-\(check.id)", primary: true, tag: fixActions.count - 1)
        }
    }

    func logView() -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.identifier = .init("runtime-log")
        let tv = scroll.documentView as? NSTextView
        tv?.isEditable = false
        tv?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tv?.string = session.log
        tv?.scrollToEndOfDocument(nil)
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        scroll.borderType = .lineBorder
        return scroll
    }

    // MARK: Actions

    @objc func goToStep(_ sender: NSButton) { if let s = RuntimeSetupStep(rawValue: sender.tag) { session.show(s) } }

    @objc func fixActionClicked(_ sender: NSButton) {
        guard sender.tag < fixActions.count else { return }
        session.request(fixActions[sender.tag])
    }

    @objc func removeClicked(_ sender: NSButton) {
        guard sender.tag < rowRecords.count else { return }
        session.request(.remove(rowRecords[sender.tag]))
    }

    @objc func copyRecordClicked(_ sender: NSButton) {
        guard sender.tag < rowRecords.count, let root = rowRecords[sender.tag].runtimeRoot else { return }
        session.request(.copyToHost(source: root, record: rowRecords[sender.tag], host: session.choices.host.destination))
    }

    @objc func chooseClicked() {
        let path: String?
        if let pickFile { path = pickFile() } else {
            let p = NSOpenPanel()
            p.canChooseFiles = true
            p.canChooseDirectories = true
            p.allowsMultipleSelection = false
            p.message = session.machine.isMac && !session.choices.useHost ? "Choose a simulator runtime disk image (.dmg)." : "Choose a .simruntime bundle or a RuntimeRoot folder."
            p.prompt = "Choose"
            path = p.runModal() == .OK ? p.url?.path : nil
        }
        if let path { session.pick(path: path) }
    }

    @objc func addPickedClicked() { if let a = session.pickedAction { session.request(a) } }
    @objc func stopClicked() { session.stop() }

    @objc func resumeClicked() {
        guard let t = session.transfer else { return }
        session.request(.copyToHost(source: t.source, record: t.record, host: t.host.destination))
    }

    @objc func setupReportClicked() { session.runSetupReport() }
    @objc func applyClicked() { session.request(.provisionApply) }
    @objc func rootStepsClicked() { session.prepareRootSteps() }

    @objc func viewScriptClicked() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = HostSetupScript.fileName
        w.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as? NSTextView
        tv?.isEditable = false
        tv?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv?.string = HostSetupScript.text
        w.contentView = scroll
        w.identifier = .init("runtime-script")
        scriptWindow = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private(set) var scriptWindow: NSWindow?

    @objc func saveScriptClicked() {
        let p = NSSavePanel()
        p.nameFieldStringValue = HostSetupScript.fileName
        p.message = "Save the setup script to run it by hand (bash ycode-host-setup --report)."
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try session.saveScript(to: url) } catch { NSApp.presentError(error) }
    }

    @objc func copyCommand(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.toolTip ?? "", forType: .string)
        statusLabel.stringValue = "Copied. Run it in your terminal."
    }

    // MARK: Confirmation

    /// The sheet that shows the exact command before anything runs.
    func present(_ c: RuntimeConfirmation) {
        shownConfirmation = c
        if let answerConfirmation {
            switch answerConfirmation(c) {
            case true?: shownConfirmation = nil; session.confirm()
            case false?: shownConfirmation = nil; session.cancelConfirmation()
            case nil: break
            }
            return
        }
        let a = Self.alert(for: c)
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.shownConfirmation = nil
                if r == .alertFirstButtonReturn { self.session.confirm() } else { self.session.cancelConfirmation() }
            }
        }
    }

    static func alert(for c: RuntimeConfirmation) -> NSAlert {
        let a = NSAlert()
        a.messageText = c.title
        a.informativeText = c.message
        a.alertStyle = c.isDestructive ? .warning : .informational
        let confirm = a.addButton(withTitle: c.confirmTitle)
        if c.isDestructive, #available(macOS 11.0, *) { confirm.hasDestructiveAction = true }
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(wrappingLabelWithString: c.command)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 10)
        field.preferredMaxLayoutWidth = 420
        field.frame.size = field.fittingSize
        field.identifier = .init("runtime-confirm-command")
        a.accessoryView = field
        return a
    }
}

/// One step in the glass panel (the headset wizard's row, for this wizard's steps).
@MainActor
final class RuntimeStepRow: NSView {
    init(index: Int, step: RuntimeSetupStep, state: SetupCheckState?, selected: Bool, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let (name, color) = RuntimeSetupWindowController.symbol(state)
        let mark = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: state?.title ?? "not checked") ?? NSImage())
        mark.contentTintColor = color
        let title = NSTextField(labelWithString: "\(index + 1). \(step.title)")
        title.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        title.textColor = .labelColor
        let b = NSButton(title: "", target: target, action: action)
        b.isBordered = false
        b.isTransparent = true
        b.tag = step.rawValue
        b.identifier = .init("runtime-step-\(step.rawValue)")
        b.setAccessibilityLabel("\(step.title): \(state?.title ?? "not checked")")
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
