import AppKit
import YcodeBuild
import YcodeIDECore
import YcodeWorkspace

/// The scheme and destination choosers as popovers (`specs/ide/popovers.md`
/// §2; P-111, P-113, P-195), opened on mouse-down of the capsule's halves
/// (`SchemePopUpButton`, `DestinationPopUpButton`), and the New Scheme
/// sheet (§3, P-112). The pop-up buttons keep their menus as the model of
/// the capsule's titles; the popovers list `ChooserList` rows.
extension WorkspaceWindowController {
    /// The scheme chooser: Filter, ✓ schemes with their app icons, Edit
    /// Scheme…, New Scheme…, Manage Schemes…. Shown under the scheme half
    /// while the window is on screen; returned in any case.
    @discardableResult
    public func showSchemeChooser() -> ChooserPopoverController {
        let names = session.model.schemeNames
        let c = ChooserPopoverController(bodyWidth: CGFloat(PopoverMetrics.schemeBodyWidth)) { [weak self] filter, _ in
            SchemeChooser.list(schemes: names, current: self?.session.scheme, filter: filter,
                               canEdit: self?.session.model.schemeForEditing(named: self?.session.scheme) != nil)
        }
        let model = session.model
        c.rowsView.image = { r in
            r.kind == .choice ? SchemeCapsuleImages.schemeImage(appIcon: SchemeCapsuleIcons.appIconURL(scheme: r.title, model: model)) : nil
        }
        c.onChoose = { [weak self] r in self?.schemeChooserChose(r) }
        present(chooser: c, from: schemePopUp)
        return c
    }

    /// The destination chooser: Filter, Recent, Devices, Simulators and
    /// Build with their rows (each destination once), Incompatible
    /// expanding in place, Manage Devices…. Ycode's own rows sit under
    /// Simulators.
    @discardableResult
    public func showDestinationChooser(expanded: Bool = false) -> ChooserPopoverController {
        let c = ChooserPopoverController(bodyWidth: CGFloat(PopoverMetrics.destinationBodyWidth), expanded: expanded) { [weak self] filter, open in
            guard let self else { return ChooserList(rows: []) }
            return DestinationChooser.list(model: self.destinationMenuModel(filter: filter), current: self.chooserCurrentDestination,
                                           expanded: open, extras: filter.isEmpty ? self.destinationChooserExtras : [])
        }
        c.rowsView.image = { r in r.symbol == "laptopcomputer" ? SchemeCapsuleImages.hostImage() : nil }
        c.onChoose = { [weak self] r in self?.destinationChooserChose(r) }
        present(chooser: c, from: destinationPopUp)
        return c
    }

    /// The destination the capsule shows: the session's, else the pop-up's
    /// selected row (a workspace that has not chosen one yet shows its
    /// default), so the chooser opens with that row checked and highlighted
    /// (§2.7).
    var chooserCurrentDestination: Destination? {
        if let d = session.destination { return d }
        guard let key = destinationPopUp.selectedItem?.representedObject as? String else { return nil }
        let all = session.model.destinations + destinationMenuModel().sections.flatMap(\.destinations)
        return Self.destination(forKey: key, in: all)
    }

    /// Ycode's own rows (`reference-ui-5.md` §11.5): Get a Simulator
    /// Runtime…, and Set Up Ycode Simulator… while none is set up.
    var destinationChooserExtras: [ChooserRow] {
        var rows = [ChooserRow(kind: .command, title: Self.getRuntimeTitle, key: Self.getRuntimeKey)]
        let all = session.model.destinations
        if !all.contains(where: \.isYcodeRemoteSimulator) {
            rows.append(ChooserRow(kind: .command, title: "\(Self.setUpSimulatorTitle)", trailing: ExperimentalNotice.label, key: Self.setUpSimulatorKey))
        }
        return rows
    }

    static let getRuntimeKey = "command:getRuntime"
    static let setUpSimulatorKey = "command:setUpSimulator"

    /// Shows a chooser under one half of the capsule, the half pressed while
    /// it is open (§2.1).
    func present(chooser c: ChooserPopoverController, from button: NSPopUpButton) {
        _ = c.view
        let host = button.superview ?? button
        // The capsule's full height, so the arrow's tip is at its bottom edge.
        let f = host === button ? button.bounds : NSRect(x: button.frame.minX, y: host.bounds.minY, width: button.frame.width, height: host.bounds.height)
        let popover = AnchoredPopover.show(c, anchor: f, of: host, edge: .below) { [weak button] in button?.highlight(false) }
        guard let popover else { return }
        button.highlight(true)
        c.onDismiss = { [weak popover] in popover?.performClose(nil) }
        c.view.window?.makeFirstResponder(c.field)
    }

    func schemeChooserChose(_ r: ChooserRow) {
        if let command = SchemeChooser.command(r) {
            // The sheets open after the popover has closed (on the run
            // loop's next turn).
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated {
                    switch command {
                    case .edit: self?.editScheme(nil)
                    case .new: self?.newScheme(nil)
                    case .manage: self?.manageSchemes(nil)
                    }
                }
            }
            return
        }
        guard let name = r.key else { return }
        schemePopUp.selectItem(withTitle: name)
        schemeChosen(schemePopUp)
    }

    func destinationChooserChose(_ r: ChooserRow) {
        switch r.key {
        case DestinationChooser.manageDevicesKey?: manageDevicesChosen(nil)
        case Self.getRuntimeKey?: getRuntimeChosen(nil)
        case Self.setUpSimulatorKey?: setUpSimulatorChosen(nil)
        case let key?: selectDestinationRow(key)
        case nil: break
        }
    }

    // MARK: New Scheme (§3, P-112)

    /// Product ▸ Scheme ▸ New Scheme… and the chooser's New Scheme…: the
    /// sheet, centred on the window. Returns its controller (nil for a
    /// package, which has no targets to make schemes for).
    @discardableResult
    @objc public func newScheme(_ sender: Any?) -> NewSchemeSheetController? {
        guard session.model.kind != .package else { NSSound.beep(); return nil }
        let c = NewSchemeSheetController(model: NewSchemeModel(model: session.model, preferring: session.scheme), workspace: session.model)
        c.onCreated = { [weak self] scheme in self?.schemeCreated(scheme.name) }
        if window?.isVisible == true { contentViewController?.presentAsSheet(c) } else { _ = c.view }
        return c
    }

    /// Lists the new scheme and makes it the active one.
    func schemeCreated(_ name: String) {
        let names = session.model.loadSchemes().map(\.name)
        if !names.isEmpty { session.model.schemeNames = names }
        session.scheme = name
        reloadSchemes()
        schemePopUp.selectItem(withTitle: name)
        schemeChosen(schemePopUp)
    }
}

/// The New Scheme sheet (§3): 493 × 122; "Target" and a pop-up of the
/// workspace's targets with their icons, "Name" and a field whose text
/// (the target's name) is selected; Cancel and OK (the default button).
@MainActor
public final class NewSchemeSheetController: NSViewController, NSTextFieldDelegate {
    public private(set) var model: NewSchemeModel
    let workspace: WorkspaceModel
    public let targetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    public let nameField = NSTextField()
    public let okButton = NSButton(title: "OK", target: nil, action: nil)
    public let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// The scheme OK wrote.
    public var onCreated: ((Scheme) -> Void)?
    public private(set) var lastError: NewSchemeModel.Failure?

    public init(model: NewSchemeModel, workspace: WorkspaceModel) {
        self.model = model
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        typealias M = NewSchemeSheetMetrics
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: M.width, height: M.height))
        func label(_ s: String, y: Double, height: Double) -> NSTextField {
            let l = NSTextField(labelWithString: s + ":")
            l.alignment = .right
            l.frame = NSRect(x: 0, y: y, width: M.labelRight, height: height)
            return l
        }
        root.addSubview(label(NewSchemeModel.targetLabel, y: M.targetRowY + 3, height: 17))
        root.addSubview(label(NewSchemeModel.nameLabel, y: M.nameRowY + 2, height: 17))
        for t in model.targets {
            targetPopUp.addItem(withTitle: t.name)
            targetPopUp.lastItem?.image = SchemeCapsuleImages.schemeImage(appIcon: nil)
        }
        targetPopUp.selectItem(at: model.selected)
        targetPopUp.target = self
        targetPopUp.action = #selector(targetChosen(_:))
        targetPopUp.frame = NSRect(x: M.controlX - 3, y: M.targetRowY, width: M.popUpWidth, height: 22)
        targetPopUp.setAccessibilityIdentifier("newScheme.target")
        nameField.stringValue = model.name
        nameField.delegate = self
        nameField.frame = NSRect(x: M.controlX, y: M.nameRowY, width: M.fieldWidth, height: M.fieldHeight)
        nameField.setAccessibilityIdentifier("newScheme.name")
        okButton.frame = NewSchemeSheetMetrics.okFrame
        cancelButton.frame = NewSchemeSheetMetrics.cancelFrame
        okButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        okButton.target = self
        okButton.action = #selector(ok(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        for b in [okButton, cancelButton] { b.bezelStyle = .push; b.controlSize = .regular }
        for v in [targetPopUp, nameField, cancelButton, okButton] as [NSView] { root.addSubview(v) }
        view = root
        preferredContentSize = root.frame.size
        updateOK()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    /// Whether the name's text is selected for typing over (§3).
    public var selectsName: Bool { true }

    @objc func targetChosen(_ p: NSPopUpButton) {
        model.select(p.indexOfSelectedItem)
        nameField.stringValue = model.name
        updateOK()
    }

    public func controlTextDidChange(_ obj: Notification) {
        model.name = nameField.stringValue
        updateOK()
    }

    func updateOK() { okButton.isEnabled = model.canCreate }

    /// Chooses target `i` and sets the name (tests type through these).
    public func choose(target i: Int, name: String? = nil) {
        _ = view
        targetPopUp.selectItem(at: i)
        targetChosen(targetPopUp)
        if let name {
            nameField.stringValue = name
            model.name = name
            updateOK()
        }
    }

    /// OK (Return): writes the scheme and closes.
    @objc public func ok(_ sender: Any?) { create() }

    /// Writes the scheme and closes; a failure beeps and keeps the sheet.
    @discardableResult
    public func create() -> Scheme? {
        model.name = nameField.stringValue
        do {
            let s = try model.create(in: workspace)
            close()
            onCreated?(s)
            return s
        } catch let f as NewSchemeModel.Failure {
            lastError = f
            NSSound.beep()
        } catch {
            NSSound.beep()
        }
        return nil
    }

    @objc public func cancel(_ sender: Any?) { close() }

    func close() {
        if presentingViewController != nil { dismiss(nil) }
    }
}

// MARK: Product ▸ Destination (P-014)

extension DynamicMenus {
    /// Product ▸ Destination with the reference's rows (`popovers.md` §9):
    /// the Devices, Simulators and Build headings only when they have rows
    /// (no empty heading), each row "<name> <OS version>" ("Any Mac
    /// (arm64, x86_64)"), the current one checked, and the Incompatible
    /// cascade's rows enabled (choosing one switches to it).
    static func fillDestinationMenu(_ m: NSMenu, model: DestinationMenuModel, current: Destination?, target: AnyObject?) {
        fillDestinations(m, model: model, current: current, target: target)
        let currentKey = current.map(WorkspaceWindowController.menuKey(for:))
        for item in m.items where item.action == #selector(WorkspaceWindowController.selectDestinationRow(_:)) {
            guard let key = item.representedObject as? String,
                  let d = model.sections.flatMap(\.destinations).first(where: { WorkspaceWindowController.menuKey(for: $0) == key }) else { continue }
            item.title = DestinationProductMenu.title(d)
        }
        // Empty headings go, with the separator after them.
        for label in ["Devices", "Simulators", "Build"] {
            guard let at = m.items.firstIndex(where: { $0.isSectionHeader && $0.title == label }) else { continue }
            let empty = model.rows(label).isEmpty
            m.items[at].isHidden = empty
            if at + 1 < m.items.count, m.items[at + 1].isSeparatorItem { m.items[at + 1].isHidden = empty }
        }
        if let sub = m.items.first(where: { $0.title == DestinationMenuModel.incompatibleTitle })?.submenu {
            for (i, d) in model.incompatible.enumerated() where i < sub.items.count {
                let item = sub.items[i]
                item.title = DestinationProductMenu.title(d)
                item.action = #selector(WorkspaceWindowController.selectDestinationRow(_:))
                item.target = target
                item.representedObject = WorkspaceWindowController.menuKey(for: d)
                item.state = WorkspaceWindowController.menuKey(for: d) == currentKey ? .on : .off
                item.isEnabled = true
            }
        }
    }
}
