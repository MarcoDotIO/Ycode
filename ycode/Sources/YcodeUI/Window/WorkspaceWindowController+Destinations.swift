import AppKit
import YcodeBuild

/// The run destination pop-up (`specs/ide/reference-ui-3.md` §4).
extension WorkspaceWindowController {
    /// The menu's layout for the current destinations and filter.
    public func destinationMenuModel(filter: String = "") -> DestinationMenuModel {
        let all = session.model.destinationGroups.flatMap(\.destinations)
        let proj = session.model.projects.keys.sorted().first.flatMap { session.model.projects[$0] }
        let (platforms, ipad) = proj.map(DestinationMenuModel.platforms(of:)) ?? ([], false)
        // §11.4 item 3: destinations below the deployment target are incompatible.
        let product = proj.map(DestinationMenuModel.productPlatform(of:))
        var targets: [String: String] = [:]
        if let p = product?.platform, let t = product?.deploymentTarget { targets[p] = t }
        // §11.5: Ycode's remote simulator is listed with the simulators.
        return DestinationMenuModel(current: session.destination,
                                    devices: all.filter { $0.kind == .device },
                                    simulators: all.filter { $0.kind == .simulator || $0.isYcodeRemoteSimulator },
                                    platforms: platforms, designedForIPad: ipad, deploymentTargets: targets, filter: filter)
    }

    /// Rebuilds the toolbar's destination menu. `expandIncompatible`
    /// (Product ▸ Destination ▸ Show All Run Destinations, §11.4 item 5)
    /// lists the incompatible rows in the menu itself, under an
    /// "Incompatible" header, instead of in the submenu.
    func rebuildDestinationMenu(filter: String = "", expandIncompatible: Bool = false) {
        let menu = destinationPopUp.menu!
        let filterItem: NSMenuItem
        if let existing = menu.items.first, existing.view is NSSearchField {
            filterItem = existing
        } else {
            let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Filter"
            field.target = self
            field.action = #selector(destinationFilterChanged(_:))
            field.sendsSearchStringImmediately = true
            // NSMenuItem() is titled "NSMenuItem"; the pop-up would show that.
            filterItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            filterItem.view = field
        }
        menu.removeAllItems()
        menu.addItem(filterItem)
        let model = destinationMenuModel(filter: filter)
        func row(_ d: Destination) -> NSMenuItem {
            // The OS version shows in the menu rows only, never in the
            // pop-up's title (reference-ui-6.md §2.4, T2).
            let item = DestinationMenuItem(title: d.name, action: nil, keyEquivalent: "")
            item.representedObject = Self.menuKey(for: d)
            item.image = NSImage(systemSymbolName: Self.symbol(for: d), accessibilityDescription: nil)
            item.osVersion = d.osVersion
            item.name = d.name
            return item
        }
        // The pop-up also puts .on on its selected item (at first the
        // filter row), so the Recent row is remembered by index.
        var recent: Int?
        for s in model.sections {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: s.title))
            for d in s.destinations {
                let item = row(d)
                if s.title == "Recent" { item.state = .on; recent = recent ?? menu.items.count }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        if expandIncompatible && !model.incompatible.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: DestinationMenuModel.incompatibleTitle))
            for d in model.incompatible { let i = row(d); i.representedObject = nil; i.isEnabled = false; menu.addItem(i) }
            menu.addItem(.separator())
        } else {
            let inc = NSMenuItem(title: DestinationMenuModel.incompatibleTitle, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for d in model.incompatible { let i = row(d); i.isEnabled = false; sub.addItem(i) }
            sub.autoenablesItems = false
            inc.submenu = sub
            inc.isEnabled = !model.incompatible.isEmpty
            menu.addItem(inc)
        }
        menu.addItem(NSMenuItem(title: DestinationMenuModel.manageDevicesTitle, action: #selector(manageDevicesChosen(_:)), keyEquivalent: ""))
        menu.items.last?.target = self
        let current = session.destination.map(Self.menuKey(for:))
        if let i = recent ?? menu.items.firstIndex(where: { ($0.representedObject as? String) == current })
            ?? menu.items.firstIndex(where: { $0.representedObject is String }) {
            destinationPopUp.selectItem(at: i)
        }
        // Rows of the Incompatible submenu always show their versions.
        for item in menu.items { item.submenu?.items.forEach { ($0 as? DestinationMenuItem)?.showsVersion = true } }
        destinationPopUp.invalidateIntrinsicContentSize()
        scheduleToolbarFit()
    }

    // MARK: Default destination (reference-ui-5.md §4.3, T1; reference-ui-6.md §2.4, T3, T11)

    /// The product's platform and deployment target: the first project's
    /// first target (nil for packages, which run on the Mac).
    public var productPlatform: (platform: String?, deploymentTarget: String?) {
        let proj = session.model.projects.keys.sorted().first.flatMap { session.model.projects[$0] }
        return proj.map(DestinationMenuModel.productPlatform(of:)) ?? (nil, nil)
    }

    /// The first project's first target: whether it supports macOS and
    /// the device families it targets (none for packages).
    public var defaultDestinationTraits: (supportsMacOS: Bool, deviceFamilies: Set<String>?) {
        let proj = session.model.projects.keys.sorted().first.flatMap { session.model.projects[$0] }
        return proj.map(DestinationMenuModel.defaultDestinationTraits(of:)) ?? (false, nil)
    }

    /// Picks the scheme's destination: the one remembered for the scheme
    /// in user data, else the default for the product
    /// (`DestinationCatalog.defaultDestination`). A destination chosen
    /// explicitly (not by an earlier default) is kept.
    func chooseDefaultDestination() {
        let scheme = session.scheme ?? ""
        let (platform, target) = productPlatform
        let anySim = platform.map(DestinationCatalog.anySimulator)
        let known = session.model.destinations + [anySim, .anyMac].compactMap { $0 }
        if let key = userState.destinations[scheme], let d = Self.destination(forKey: key, in: known) {
            session.destination = d
            destinationDefault.applied = d
            return
        }
        let current = session.destination
        // The session starts on the first destination (My Mac); that is a
        // default too.
        let isDefault = current == nil || current == destinationDefault.applied
            || (destinationDefault.applied == nil && current == session.model.destinations.first)
        guard isDefault else { return }
        // Ycode's remote simulator rows are rows of the Simulators section
        // (reference-ui-5.md §11.5) and rank there like local simulators:
        // by runtime, then family and name, so a local simulator of the same
        // type and runtime comes first (reference-ui-6.md §2.4.3).
        let sims = session.model.destinations.filter { $0.kind == .simulator || $0.isYcodeRemoteSimulator }
        let traits = defaultDestinationTraits
        let d = DestinationCatalog.defaultDestination(platform: platform, deploymentTarget: target, simulators: sims,
                                                      supportsMacOS: traits.supportsMacOS, deviceFamilies: traits.deviceFamilies,
                                                      order: DestinationMenuModel.orderedSimulators)
        session.destination = d
        destinationDefault.applied = d
    }

    /// Remembers the current destination for the current scheme.
    func rememberDestination() {
        guard let d = session.destination else { return }
        destinationDefault.applied = nil
        let scheme = session.scheme ?? ""
        // Simulators and Ycode's remote simulator by identifier; generic
        // destinations by specifier.
        updateUserState { $0.destinations[scheme] = Self.menuKey(for: d) }
    }

    /// The key that names one destination: its identifier (simulators,
    /// devices, Ycode's remote simulator), else its specifier (generic
    /// destinations). Specifiers alone are not unique: the remote
    /// simulator builds for "generic/platform=iOS Simulator", the same as
    /// Any iOS Simulator Device. Menu rows carry it; the scheme's
    /// remembered choice is stored as it.
    public static func menuKey(for d: Destination) -> String { d.identifier ?? d.specifier }

    /// The destination a key names: by identifier, else a destination
    /// without one whose specifier matches.
    public static func destination(forKey key: String, in list: [Destination]) -> Destination? {
        list.first { $0.identifier == key } ?? list.first { $0.identifier == nil && $0.specifier == key }
    }

    /// The destination name the toolbar shows.
    public var destinationTitle: String {
        destinationPopUp.titleOfSelectedItem ?? ""
    }

    @objc func destinationFilterChanged(_ f: NSSearchField) { rebuildDestinationMenu(filter: f.stringValue) }
    @objc func manageDevicesChosen(_ sender: Any?) { _ = showDevices(sender) }

    // MARK: Ycode's remote simulator row (reference-ui-5.md §11.5)

    /// Reads each remote runtime's version once per runtime root (ssh, off
    /// the main actor) and relists the destinations with them. Nothing
    /// happens when the remote simulator is not set up or every version is
    /// already known. `ssh` replaces the ssh program (tests).
    @discardableResult
    public func refreshRemoteRuntimeVersion(defaults: UserDefaults = Preferences.shared.defaults, ssh: String? = nil) -> Task<Void, Never>? {
        var settings = RemoteSimulatorSettings.load(defaults)
        if let ssh { settings.ssh = ssh }
        let roots = settings.allRuntimeRoots.filter { !RemoteSimulatorSettings.hasRuntimeVersion(for: $0, defaults) }
        guard settings.isConfigured, !roots.isEmpty else { return nil }
        let primary = settings.runtimeRoot
        let probes = roots.map { root in
            RemoteSimulator(settings: settings, target: RemoteSimulatorTarget(runtimeRoot: root, runtimeVersion: nil, deviceType: .simdDefault,
                                                                              deviceDirectoryName: settings.deviceName, isPrimary: false))
        }
        return Task { [weak self] in
            var found = false
            for remote in probes {
                guard let v = await Task.detached(operation: { remote.readRuntimeVersion() }).value else { continue }
                RemoteSimulatorSettings.saveRuntimeVersion(v, root: remote.runtimeRoot, defaults, primary: remote.runtimeRoot == primary)
                found = true
            }
            guard found, let self else { return }
            self.setDestinationGroups(self.session.model.destinationGroups)
        }
    }
}

/// A destination row: the destination's name, and its OS version
/// right-aligned while the menu is open (`reference-ui-6.md` §2.4, T2).
final class DestinationMenuItem: NSMenuItem {
    var osVersion: String?
    /// Shows "<name>\t<version>" (menu open) or the name alone. (Setting
    /// an attributed title also replaces `title`; the name is restored.)
    var showsVersion = false {
        didSet {
            guard showsVersion != oldValue else { return }
            let name = self.name
            guard showsVersion, let v = osVersion else { attributedTitle = nil; title = name; return }
            let text = NSMutableAttributedString(string: name + "\t" + v)
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .right, location: 300)]
            text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                              range: NSRange(location: name.utf16.count + 1, length: v.utf16.count))
            attributedTitle = text
        }
    }
    /// The destination's name (the plain title).
    lazy var name: String = title
}

/// The destination pop-up: its title is the destination's glyph and name
/// only, and it is as wide as that title, not as its widest menu row
/// (`reference-ui-6.md` §2.4, T2). The menu rows show OS versions while
/// the menu is open.
final class DestinationPopUpButton: NSPopUpButton, NSMenuDelegate {
    override init(frame: NSRect, pullsDown flag: Bool) {
        super.init(frame: frame, pullsDown: flag)
        menu?.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var menu: NSMenu? {
        didSet { menu?.delegate = self }
    }

    /// The width of a pop-up holding only the selected row.
    override var intrinsicContentSize: NSSize {
        let probe = NSPopUpButton(frame: .zero, pullsDown: false)
        probe.isBordered = isBordered
        probe.controlSize = controlSize
        probe.font = font
        let item = NSMenuItem(title: selectedItem?.title ?? "", action: nil, keyEquivalent: "")
        item.image = selectedItem?.image
        probe.menu?.addItem(item)
        probe.select(item)
        return NSSize(width: ceil(probe.intrinsicContentSize.width), height: super.intrinsicContentSize.height)
    }

    override func select(_ item: NSMenuItem?) {
        super.select(item)
        invalidateIntrinsicContentSize()
    }

    override func selectItem(at index: Int) {
        super.selectItem(at: index)
        invalidateIntrinsicContentSize()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { versions(true, in: menu) }
    func menuDidClose(_ menu: NSMenu) {
        versions(false, in: menu)
        invalidateIntrinsicContentSize()
    }

    private func versions(_ on: Bool, in menu: NSMenu) {
        guard menu === self.menu else { return }
        for item in menu.items { (item as? DestinationMenuItem)?.showsVersion = on }
    }
}
