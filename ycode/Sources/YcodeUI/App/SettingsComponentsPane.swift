import AppKit
import YcodeCompletion
import YcodeIDECore
import YcodeSettings
import YcodeSubprocess
import YcodeWorkspace

// MARK: Components

/// Settings ▸ Components (`specs/ide/settings.md` R5.2): "Platform Support"
/// (this Mac, then one row per simulator platform: its symbol, the newest
/// runtime's version, its size or "Built-in", "Last used" when known and an
/// info button listing the SDKs and runtimes), then "Other Components"
/// (predictive code completion, and Ycode's simulator host at the end, R5.5,
/// whose info button opens the host page). Nothing is downloaded or deleted
/// here; Simulator Runtimes… (in the info popovers and on the host page)
/// opens the runtime wizard.
@MainActor
public final class ComponentsSettingsPane: SettingsPane {
    public struct Component: Equatable, Sendable {
        public var name: String
        public var version: String
        public var kind: String
    }
    /// What the pane lists; read in the background when none is given.
    public private(set) var inventory: ComponentsInventory
    public private(set) var loading: Task<Void, Never>?
    private var loaded: Bool
    /// The rows shown (for tests and the spec).
    private(set) var rowViews: [ComponentsRowView] = []
    /// Opens the simulator-host page (Ycode's own, R5.5).
    public var onOpenSimulators: (() -> Void)?
    /// Opens Editing ▸ Completion (predictive code completion's info button).
    public var onOpenCompletion: (() -> Void)?
    /// The info popover shown, if any.
    public private(set) var infoPopover: NSPopover?
    /// "Last used" is relative to this date (tests fix it).
    var now: () -> Date = Date.init

    public init(prefs: Preferences = .shared, components: [Component]? = nil, inventory: ComponentsInventory? = nil) {
        if let inventory {
            self.inventory = inventory
        } else {
            let sdks = (components ?? []).filter { $0.kind == "SDK" }.map { ComponentsInventory.SDK(canonicalName: $0.name, version: $0.version) }
            self.inventory = ComponentsInventory(sdks: sdks)
        }
        loaded = components != nil || inventory != nil
        super.init("Components", prefs: prefs)
    }

    override var firstHeaderCapTop: CGFloat { SettingsComponentsLayout.firstHeaderCapTop }

    public override func loadView() {
        super.loadView()
        guard !loaded, loading == nil else { return }
        let choices = RuntimeSetupChoices.load(prefs.defaults)
        loading = Task { [weak self] in
            let sdks = await Task.detached { Self.installedSDKs() }.value
            let inv = await ComponentsInventory.read(choices: choices, sdks: sdks)
            guard let self else { return }
            self.inventory = inv
            self.loaded = true
            self.loading = nil
            self.rebuild()
        }
    }

    /// The SDKs of the active developer directory.
    public nonisolated static func installedSDKs() -> [ComponentsInventory.SDK] {
        guard let dev = Workspace.activeDeveloperDirectory() else { return [] }
        return SDKCatalog(developerDirectory: dev).sdks.map { ComponentsInventory.SDK(canonicalName: $0.canonicalName, version: $0.version) }
    }

    /// SDKs of the active developer directory, then simulator runtimes
    /// from `xcrun simctl list runtimes -j` (both read-only).
    public nonisolated static func installed() -> [Component] {
        var out = installedSDKs().map { Component(name: $0.canonicalName, version: $0.version, kind: "SDK") }
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

    /// The rows of both sections, as both IDEs build them.
    public var rows: (platforms: [ComponentsRow], other: [ComponentsRow]) {
        let p = prefs.predictiveCompletion
        return (ComponentsPage.platformRows(inventory, isMac: true, now: now()),
                ComponentsPage.otherRows(predictiveEnabled: p.enabled, predictiveBackend: p.backend.displayName, predictiveModel: p.model,
                                         hostDestination: SimulatorHostPage.destination(prefs.defaults)))
    }

    override func build() {
        rowViews = []
        let r = rows
        heading(ComponentsPage.platformHeader)
        for row in r.platforms { add(row) }
        heading(ComponentsPage.otherHeader)
        for row in r.other { add(row) }
    }

    func add(_ row: ComponentsRow) {
        let v = ComponentsRowView(row)
        v.identifier = .init("components-row-\(row.glyph.rawValue)")
        v.info.onPress = { [weak self] b in self?.showInfo(row, from: b) }
        cardRow(v, title: row.title)
        rowViews.append(v)
    }

    /// The info button: the host page, Editing ▸ Completion, or a popover
    /// with the platform's SDKs and runtimes.
    public func showInfo(_ row: ComponentsRow, from b: NSView? = nil) {
        switch row.kind {
        case .simulatorHost: onOpenSimulators?()
        case .predictiveCompletion: onOpenCompletion?()
        case .thisComputer, .platform:
            guard let b, let w = b.window, w.isVisible else { return }
            var button: NSButton?
            if case .platform = row.kind {
                let get = SettingsPushButton(SimulatorHostPage.runtimesButton)
                get.identifier = .init("components-runtimes")
                get.onPress = { [weak self] _ in
                    self?.infoPopover?.close()
                    RuntimeSetupWindowController.show(step: .runtimes)
                }
                button = get
            }
            let vc = NSViewController()
            vc.view = ComponentsInfoView(row, button: button)
            let p = NSPopover()
            p.behavior = .transient
            p.contentViewController = vc
            infoPopover = p
            p.show(relativeTo: b.bounds, of: b, preferredEdge: .maxX)
        }
    }

    public static let runtimesTitle = SimulatorHostPage.runtimesButton
    @objc func showRuntimes(_ sender: Any?) { RuntimeSetupWindowController.show(step: .runtimes) }
}

// MARK: The simulator host (Ycode's own page, R5.5)

/// Settings ▸ Components ▸ Simulator Host: the host's own settings, designed
/// as the rest of Settings (the grouped cards, rows and controls) with a
/// header card in the system's settings style: the host's icon, its name or
/// "Not set up", and what it is. Per-device settings, the camera among them,
/// are in the device window's Settings inspector.
@MainActor
public final class SimulatorsSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("Simulators", prefs: prefs) }
    /// The way back to Components (the page is reached from its row's info
    /// button; nil when the pane stands alone).
    public var onBack: (() -> Void)? { didSet { if isViewLoaded { rebuild() } } }
    /// The text fields by field (tests type into them).
    public private(set) var fields: [SimulatorHostPage.Field: NSTextField] = [:]

    public var settings: RemoteSimulatorSettings { RemoteSimulatorSettings.load(prefs.defaults) }

    /// Changes the run settings and saves (user defaults only).
    public func update(_ f: (inout RemoteSimulatorSettings) -> Void) {
        var s = settings
        f(&s)
        s.save(prefs.defaults)
        prefs.changed()
    }

    /// Saves a field as typed (as a commit in its text field does).
    public func set(_ field: SimulatorHostPage.Field, _ value: String) {
        SimulatorHostPage.set(field, value, prefs.defaults)
        prefs.changed()
        fields[field]?.stringValue = SimulatorHostPage.value(field, prefs.defaults)
        hero?.update(destination: SimulatorHostPage.destination(prefs.defaults))
    }

    private(set) var hero: SimulatorHostHeroView?

    override func build() {
        fields = [:]
        if let onBack { backRow("Components", onBack) }
        let h = SimulatorHostHeroView(destination: SimulatorHostPage.destination(prefs.defaults))
        hero = h
        cardRow(h, title: SimulatorHostPage.title)
        for section in SimulatorHostPage.Section.allCases {
            heading(section.rawValue)
            for f in section.fields {
                let box = SettingsTextFieldBox(placeholder: f.placeholder, value: SimulatorHostPage.value(f, prefs.defaults))
                box.field.identifier = .init("settings-host-\(f.rawValue)")
                box.field.setAccessibilityLabel(f.title)
                box.onCommit = { [weak self] v in self?.set(f, v) }
                fields[f] = box.field
                row(f.title, box)
                if let help = f.help { note(help) }
            }
            for sw in section.switches {
                row("", check(sw.title, SimulatorHostPage.isOn(sw, prefs.defaults)) { [weak self] on in
                    guard let self else { return }
                    SimulatorHostPage.set(sw, on, self.prefs.defaults)
                    self.prefs.changed()
                })
                note(sw.help)
            }
            if section == .runtimes {
                let get = SettingsPushButton(SimulatorHostPage.runtimesButton)
                get.identifier = .init("settings-host-runtimes")
                get.onPress = { _ in RuntimeSetupWindowController.show(step: .runtimes) }
                row("Runtimes on the host", get)
                note(SimulatorHostPage.runtimesHelp)
            }
        }
    }
}

/// The host page's header card: the 40-point icon, "Simulator Host" in
/// bold with "Experimental" beside it, the host or "Not set up", and what
/// the host is.
final class SimulatorHostHeroView: NSView {
    let icon = SimulatorHostIconView()
    let title = NSTextField(labelWithString: SimulatorHostPage.title)
    let badge = NSTextField(labelWithString: ExperimentalNotice.label)
    let status = NSTextField(labelWithString: "")
    let summary = NSTextField(wrappingLabelWithString: "")

    init(destination: String) {
        super.init(frame: .zero)
        let P = SimulatorHostPage.self
        title.font = .boldSystemFont(ofSize: SettingsMetrics.fontSize)
        title.textColor = SettingsColors.label
        badge.font = .systemFont(ofSize: SettingsMetrics.helpFontSize, weight: .medium)
        badge.textColor = SettingsR5Colors.subtitle
        status.font = .systemFont(ofSize: SettingsMetrics.helpFontSize)
        status.textColor = SettingsR5Colors.subtitle
        status.identifier = .init("settings-host-status")
        summary.attributedStringValue = SettingsRowView.helpText(P.summary + " " + ExperimentalNotice.simulator)
        summary.preferredMaxLayoutWidth = SettingsMetrics.cardWidth - 2 * P.heroInset - P.heroIconSize - 12
        for v in [icon, title, badge, status, summary] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let textX = P.heroInset + P.heroIconSize + 12
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P.heroInset),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: P.heroInset),
            icon.widthAnchor.constraint(equalToConstant: P.heroIconSize), icon.heightAnchor.constraint(equalToConstant: P.heroIconSize),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textX),
            title.topAnchor.constraint(equalTo: topAnchor, constant: P.heroInset + 2),
            badge.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            badge.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -P.heroInset),
            summary.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -P.heroInset),
        ])
        update(destination: destination)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(destination: String) { status.stringValue = SimulatorHostPage.subtitle(destination: destination) }
}

/// The host page's icon: the simulator row icon's green gradient in a
/// 40-point rounded square, the host symbol in white.
final class SimulatorHostIconView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let g = SettingsRowIcon.simulator.gradient
        let square = NSBezierPath(roundedRect: r, xRadius: SimulatorHostPage.heroIconRadius, yRadius: SimulatorHostPage.heroIconRadius)
        NSGradient(starting: SettingsColors.rgb(g.top), ending: SettingsColors.rgb(g.bottom))?.draw(in: square, angle: 90)
        let glyph = ComponentGlyph.simulatorHost
        let scale: CGFloat = 1.2
        let ox = r.midX - glyph.size.width * scale / 2, oy = r.midY - glyph.size.height * scale / 2
        NSColor.white.set()
        for part in glyph.parts {
            switch part {
            case .roundedRect(let q, let radius, _):
                let p = NSBezierPath(roundedRect: NSRect(x: ox + q.minX * scale, y: oy + q.minY * scale, width: q.width * scale, height: q.height * scale),
                                     xRadius: radius * scale, yRadius: radius * scale)
                p.lineWidth = 1.6
                p.stroke()
            case .dot(let c, let d):
                NSBezierPath(ovalIn: NSRect(x: ox + (c.x - d / 2) * scale, y: oy + (c.y - d / 2) * scale, width: d * scale, height: d * scale)).fill()
            default: break
            }
        }
    }
}

/// A text field in the host page's style: 220 × 22, radius 6, a 1-point
/// border, 12 points, committed on Return or when it loses focus.
final class SettingsTextFieldBox: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    var onCommit: ((String) -> Void)?

    init(placeholder: String, value: String) {
        super.init(frame: .zero)
        let P = SimulatorHostPage.self
        field.stringValue = value
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: P.fieldFontSize)
        field.textColor = SettingsColors.label
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: P.fieldSize.width), heightAnchor.constraint(equalToConstant: P.fieldSize.height),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P.fieldPadding),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P.fieldPadding),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let P = SimulatorHostPage.self
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: P.fieldRadius, yRadius: P.fieldRadius)
        SettingsColors.dynamic(P.fieldFill).setFill()
        p.fill()
        SettingsColors.dynamic(P.fieldBorder).setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(field.stringValue) }
}
