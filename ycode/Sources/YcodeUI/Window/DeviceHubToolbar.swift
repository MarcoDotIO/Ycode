import AppKit
import YcodeDeviceModel
import YcodeDeviceUI

/// The hub window's toolbar (`specs/ide/device-hub.md` §3), left to right:
/// [Add Device · Filter] over the sidebar, Hide / Show Sidebar, the title
/// and subtitle, then at the right end of the canvas Capture Keyboard, the
/// zoom segments (Zoom Out · Zoom to Fit · Zoom To Actual Size · Zoom In)
/// and [Open in New Window · More Actions], and over the inspector its
/// three tabs (Settings, Reports, Info). Unified style, no bar background:
/// every item is the system's glass shape (`liquid-glass-ycode.md` §2).
/// Resize mode is not built (§4.7, Ycode decision), so its toggle is left
/// out.
@MainActor
final class DeviceHubToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate, NSToolbarItemValidation {
    unowned let owner: DevicesController
    private weak var zoomGroup: NSToolbarItemGroup?
    private weak var tabGroup: NSToolbarItemGroup?
    private weak var captureButton: NSButton?
    private weak var filterItem: NSMenuToolbarItem?
    private let addMenu = NSMenu(title: "Add Device")
    private let filterMenu = NSMenu(title: "Filter")
    private let moreMenu = NSMenu(title: "More Actions")

    static let add = NSToolbarItem.Identifier("hub.addDevice")
    static let filter = NSToolbarItem.Identifier("hub.filter")
    static let capture = NSToolbarItem.Identifier("hub.captureKeyboard")
    static let zoom = NSToolbarItem.Identifier("hub.zoom")
    static let open = NSToolbarItem.Identifier("hub.openInNewWindow")
    static let more = NSToolbarItem.Identifier("hub.more")
    static let tabs = NSToolbarItem.Identifier("hub.inspectorTabs")

    init(owner: DevicesController) {
        self.owner = owner
        super.init()
        for m in [addMenu, filterMenu, moreMenu] { m.delegate = self }
    }

    func install(on w: NSWindow) {
        let t = NSToolbar(identifier: "YcodeDeviceHub")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        w.toolbar = t
    }

    /// The item order (§3).
    static let order: [NSToolbarItem.Identifier] = [add, filter, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
                                                    capture, zoom, open, more, .inspectorTrackingSeparator, .flexibleSpace, tabs]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if #available(macOS 14.0, *) { return Self.order }
        return Self.order.filter { $0 != .inspectorTrackingSeparator }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func image(_ n: String, _ l: String) -> NSImage? { NSImage(systemSymbolName: n, accessibilityDescription: l) }
        switch id {
        case Self.add:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = image("plus", "Add Device")
            i.label = "Add Device"
            i.toolTip = "Add Device"
            i.showsIndicator = false
            i.menu = addMenu
            return i
        case Self.filter:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = image("line.3.horizontal.decrease", "Filter")
            i.label = "Filter"
            i.toolTip = "Filter"
            i.showsIndicator = false
            i.menu = filterMenu
            filterItem = i
            updateFilterLook()
            return i
        case .toggleSidebar:
            // The system's item; its action goes to the split view controller.
            return nil
        case Self.capture:
            let b = NSButton(image: image("keyboard", "Capture Keyboard") ?? NSImage(), target: self, action: #selector(captureClicked(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.toolTip = "Capture Keyboard"
            b.setAccessibilityLabel("Capture Keyboard")
            captureButton = b
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = b
            i.label = "Capture Keyboard"
            return i
        case Self.zoom:
            let labels = ["Zoom Out", "Zoom to Fit", "Zoom To Actual Size", "Zoom In"]
            let images = ["minus.magnifyingglass", "arrow.up.left.and.down.right.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"]
                .enumerated().compactMap { image($0.element, labels[$0.offset]) }
            let g = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne, labels: labels,
                                       target: self, action: #selector(zoomChosen(_:)))
            for (sub, l) in zip(g.subitems, labels) { sub.toolTip = l }
            zoomGroup = g
            updateZoom()
            return g
        case Self.open:
            let i = NSToolbarItem(itemIdentifier: id)
            i.image = image("arrow.down.right.and.arrow.up.left", "Open in New Window")
            i.label = "Open in New Window"
            i.toolTip = "Switch to compact window"
            i.isBordered = true
            i.target = self
            i.action = #selector(openClicked(_:))
            return i
        case Self.more:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.image = image("ellipsis", "More Actions")
            i.label = "More Actions"
            i.toolTip = "More Actions"
            i.showsIndicator = false
            i.menu = moreMenu
            return i
        case Self.tabs:
            let labels = ["Settings", "Reports", "Info"]
            let images = ["slider.horizontal.3", "doc.text", "info.circle"].enumerated().compactMap { image($0.element, labels[$0.offset]) }
            let g = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne, labels: labels,
                                       target: self, action: #selector(tabChosen(_:)))
            for (sub, l) in zip(g.subitems, labels) { sub.toolTip = l }
            tabGroup = g
            updateTabs()
            return g
        default:
            return nil
        }
    }

    // MARK: State

    func update() {
        updateZoom()
        updateTabs()
        updateFilterLook()
        captureButton?.state = owner.canvas.capturesKeyboard ? .on : .off
        owner.view.window?.toolbar?.validateVisibleItems()
    }

    func updateZoom() {
        guard let g = zoomGroup else { return }
        switch owner.canvas.zoom {
        case .fit: g.selectedIndex = 1
        case .actual: g.selectedIndex = 2
        case .scale: break
        }
    }

    func updateTabs() { tabGroup?.selectedIndex = owner.inspectorTab.rawValue }

    func updateCapture(_ on: Bool) { captureButton?.state = on ? .on : .off }

    /// The Filter button is drawn filled while a filter applies (§5.3).
    func updateFilterLook() {
        let filtered = owner.sidebarModel.filter != .all
        filterItem?.image = NSImage(systemSymbolName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                                    accessibilityDescription: "Filter")
    }

    /// Items 6–10 are dimmed while nothing is selected (§3).
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.capture, Self.zoom, Self.more: return owner.selected != nil
        case Self.open: return owner.selected?.state == "Booted" && owner.selected?.isYcodeRemote == true
        default: return true
        }
    }

    // MARK: Actions

    @objc func captureClicked(_ sender: NSButton) { owner.canvas.setCapturesKeyboard(sender.state == .on); updateCapture(owner.canvas.capturesKeyboard) }

    @objc func zoomChosen(_ sender: NSToolbarItemGroup) {
        let commands: [DeviceCommand] = [.zoomOut, .zoomToFit, .physicalSize, .zoomIn]
        guard commands.indices.contains(sender.selectedIndex) else { return }
        owner.canvas.perform(commands[sender.selectedIndex])
    }

    @objc func openClicked(_ sender: Any?) { owner.openInNewWindow() }

    @objc func tabChosen(_ sender: NSToolbarItemGroup) {
        owner.selectInspectorTab(DevicesController.InspectorTab(rawValue: sender.selectedIndex) ?? .settings)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === addMenu {
            for i in Self.addItems(target: self) { menu.addItem(i) }
        } else if menu === filterMenu {
            for i in filterItems() { menu.addItem(i) }
        } else if menu === moreMenu {
            for i in moreItems() { menu.addItem(i) }
        }
    }

    /// Add Device (§3 item 2; §2.3): the simulator kinds and Pair Nearby
    /// Device…. Ycode decision: Ycode's simulators are its runtimes and
    /// device types, set in Settings ▸ Simulators, so iPhone… and iPad…
    /// open that pane; Ycode has no watch, TV or headset simulator yet and
    /// does not pair devices, so those items are disabled.
    static func addItems(target: AnyObject?) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for (title, on) in [("iPhone…", true), ("iPad…", true), ("Apple Watch…", false), ("Apple Vision Pro…", false), ("Apple TV…", false)] {
            let i = NSMenuItem(title: title, action: on ? #selector(addSimulator(_:)) : nil, keyEquivalent: "")
            i.target = target
            i.isEnabled = on
            out.append(i)
        }
        out.append(.separator())
        let pair = NSMenuItem(title: "Pair Nearby Device…", action: nil, keyEquivalent: "")
        pair.isEnabled = false
        out.append(pair)
        return out
    }

    @objc func addSimulator(_ sender: Any?) { SettingsWindowController.shared.show(pane: "Simulators") }

    /// Filter (§5.3): All Devices, Simulators, Physical Devices, Sort By ▸.
    func filterItems() -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for f in HubFilter.allCases {
            let i = NSMenuItem(title: f.rawValue, action: #selector(filterChosen(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = f.rawValue
            i.state = owner.sidebarModel.filter == f ? .on : .off
            out.append(i)
        }
        out.append(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sm = NSMenu(title: "Sort By")
        for s in HubSort.allCases {
            let i = NSMenuItem(title: s.rawValue, action: #selector(sortChosen(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.rawValue
            i.state = owner.sortChosen && owner.sidebarModel.sort == s ? .on : .off
            sm.addItem(i)
        }
        sort.submenu = sm
        out.append(sort)
        return out
    }

    @objc func filterChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let f = HubFilter(rawValue: raw) else { return }
        owner.setFilter(f)
        updateFilterLook()
    }

    @objc func sortChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = HubSort(rawValue: raw) else { return }
        owner.setSort(owner.sortChosen && owner.sidebarModel.sort == s ? nil : s)
    }

    /// More Actions (Q6, Ycode decision): Start or Shut Down / Restart /
    /// Force Shut Down, then the canvas's view items (bezels, frame rate),
    /// Erase All Content and Settings….
    func moreItems() -> [NSMenuItem] {
        guard let r = owner.selected else { return [] }
        var out = owner.lifecycleItems(for: r)
        let bezels = NSMenuItem(title: owner.canvas.showsBezels ? "Hide Bezels" : "Show Bezels", action: #selector(toggleBezels(_:)), keyEquivalent: "")
        bezels.target = self
        let stats = NSMenuItem(title: "Show Frame Rate", action: #selector(toggleStatistics(_:)), keyEquivalent: "")
        stats.target = self
        stats.state = owner.canvas.showsStatistics ? .on : .off
        out += [bezels, stats]
        if r.isYcodeRemote, let i = owner.rows.firstIndex(where: { $0.identifier == r.identifier }) {
            out.append(.separator())
            let erase = NSMenuItem(title: DevicesController.eraseTitle, action: #selector(DevicesController.eraseChosen(_:)), keyEquivalent: "")
            erase.target = owner
            erase.tag = i
            out.append(erase)
        }
        return out
    }

    @objc func toggleBezels(_ sender: Any?) {
        owner.canvas.showsBezels.toggle()
        owner.defaults.set(owner.canvas.showsBezels, forKey: DevicesController.bezelsKey)
    }

    @objc func toggleStatistics(_ sender: Any?) { owner.canvas.showsStatistics.toggle() }
}
