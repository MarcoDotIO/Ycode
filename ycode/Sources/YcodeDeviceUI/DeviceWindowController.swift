// The compact device window (device-hub.md §2.2): a unified toolbar with
// the device's name as title and its OS as subtitle and one capsule at the
// right, Expand │ More Actions; the device in its frame filling the width
// with a small margin; the device-control row centred below it. Resizing
// the window scales the device (the window keeps the device's aspect plus
// the toolbar and the control row); rotating the device or switching the
// iPhone Duo's panel reshapes the window at the same scale. The window's
// scale and position are kept per device type.
//
// The same controller also has an expanded form (the standalone viewer's
// Expand, which has no hub to open; Ycode decision for Q5): the hub's
// canvas toolbar — Capture Keyboard, the zoom segments, Open in New Window
// │ More Actions — around a resizable canvas, without sidebar or inspector.

#if os(macOS)
import AppKit
import YcodeDeviceModel

@MainActor
public final class DeviceWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, DeviceLiveSessionObserver {
    public enum Kind { case compact, expanded }
    public private(set) var kind: Kind
    public private(set) var session: DeviceLiveSession
    public private(set) var canvas: DeviceCanvasView
    /// Expand: the owner opens the hub with this device (the IDE), or nil
    /// (the window switches to its expanded form).
    public var onExpand: (() -> Void)?
    /// Items the owner adds to More Actions before Ycode's own (Shut Down,
    /// Restart in the IDE; Q6).
    public var extraMoreItems: (() -> [NSMenuItem])?
    public var onClose: (() -> Void)?
    /// Where the window's state is kept.
    public var defaults: UserDefaults = .standard
    /// A scale to open the compact window at instead of the saved one
    /// (the viewer's `--zoom`).
    public var initialScale: Double?

    private var toolbarHeight = CGFloat(CompactWindowLayout.toolbarHeight)
    private var lastDeviceSize: CGSize = .zero
    private var resizing = false
    private let moreMenu = NSMenu(title: "More Actions")
    private weak var zoomGroup: NSToolbarItemGroup?
    private weak var captureButton: NSButton?

    public init(session: DeviceLiveSession, kind: Kind = .compact) {
        self.session = session
        self.kind = kind
        canvas = DeviceCanvasView(mode: kind == .compact ? .compact : .hub)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        if #available(macOS 11.0, *) { window.titlebarSeparatorStyle = .none }
        window.backgroundColor = .windowBackgroundColor
        window.tabbingMode = .disallowed
        installCanvas()
        installToolbar()
        session.addObserver(self)
        updateTitle()
        moreMenu.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var defaultsKey: String { "YcodeDeviceWindow.\(kind == .compact ? "compact" : "expanded").\(session.spec.typeID)" }

    private func installCanvas() {
        guard let window else { return }
        canvas.removeFromSuperview()
        canvas = DeviceCanvasView(mode: kind == .compact ? .compact : .hub)
        canvas.handlesKeyEquivalents = handlesKeyEquivalents
        canvas.showsBezels = defaults.object(forKey: "YcodeDeviceWindow.bezels") as? Bool ?? true
        canvas.showsStatistics = defaults.bool(forKey: "YcodeDeviceWindow.statistics")
        canvas.show(session: session)
        canvas.onGeometryChange = { [weak self] in self?.deviceShapeChanged() }
        canvas.onZoomChange = { [weak self] in self?.updateZoomSelection() }
        canvas.onCaptureChange = { [weak self] on in self?.captureButton?.state = on ? .on : .off }
        window.contentView = canvas
        if kind == .compact {
            window.contentMinSize = NSSize(width: CompactWindowLayout.minimumWidth, height: 300)
        } else {
            window.contentMinSize = NSSize(width: 420, height: 420)
        }
    }

    /// The window's key equivalents for device commands (the IDE's windows;
    /// the viewer's menus carry them instead).
    public var handlesKeyEquivalents = false { didSet { canvas.handlesKeyEquivalents = handlesKeyEquivalents } }

    /// Shows the window: the saved scale and position, else the default
    /// size centred.
    public func present() {
        guard let window else { return }
        toolbarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        if toolbarHeight < 20 { toolbarHeight = CGFloat(CompactWindowLayout.toolbarHeight) }
        canvas.topInset = toolbarHeight
        lastDeviceSize = canvas.deviceSize
        let saved = defaults.dictionary(forKey: defaultsKey)
        if kind == .compact {
            let scale = max(initialScale ?? (saved?["scale"] as? Double) ?? CompactWindowLayout.defaultScale(device: lastDeviceSize),
                            CompactWindowLayout.scale(device: lastDeviceSize, windowWidth: CompactWindowLayout.minimumWidth))
            initialScale = nil
            resize(to: CompactWindowLayout.contentSize(device: lastDeviceSize, scale: scale, toolbar: toolbarHeight), keepTop: false)
        } else {
            let w = (saved?["width"] as? Double) ?? 760, h = (saved?["height"] as? Double) ?? 820
            window.setContentSize(NSSize(width: w, height: h))
        }
        if let x = saved?["x"] as? Double, let top = saved?["top"] as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: x + 20, y: top - 20)) }) {
            window.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas.frameView.screen)
    }

    private func saveState() {
        guard let window else { return }
        var d: [String: Any] = ["x": window.frame.minX, "top": window.frame.maxY]
        if kind == .compact {
            d["scale"] = CompactWindowLayout.scale(device: canvas.deviceSize, windowWidth: window.contentLayoutRect.width)
        } else {
            d["width"] = window.contentLayoutRect.width
            d["height"] = window.frame.height
        }
        defaults.set(d, forKey: defaultsKey)
    }

    // MARK: Shape

    /// Content size (whole content view, toolbar area included).
    private func resize(to content: CGSize, keepTop: Bool) {
        guard let window else { return }
        resizing = true
        let top = window.frame.maxY, midX = window.frame.midX
        window.setContentSize(content)
        if keepTop {
            var f = window.frame
            f.origin.x = (midX - f.width / 2).rounded()
            f.origin.y = top - f.height
            window.setFrame(f, display: true, animate: false)
        }
        resizing = false
    }

    /// Rotation, the other panel or the bezels: same scale, new shape.
    private func deviceShapeChanged() {
        guard kind == .compact, let window, window.isVisible else { lastDeviceSize = canvas.deviceSize; return }
        let new = canvas.deviceSize
        guard new != lastDeviceSize, lastDeviceSize.width > 0 else { lastDeviceSize = new; return }
        let size = CompactWindowLayout.rotatedContentSize(oldDevice: lastDeviceSize, newDevice: new,
                                                          contentWidth: Double(window.contentLayoutRect.width), toolbar: toolbarHeight)
        lastDeviceSize = new
        resize(to: size, keepTop: true)
        saveState()
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard kind == .compact, !resizing else { return frameSize }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        let c = CompactWindowLayout.constrainedContentSize(device: canvas.deviceSize, proposed: content.size, toolbar: toolbarHeight)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: c)).size
    }

    public func windowDidResize(_ notification: Notification) { if !resizing { saveState() } }
    public func windowDidMove(_ notification: Notification) { saveState() }
    public func windowDidResignKey(_ notification: Notification) { canvas.frameView.screen.cancelInput() }

    public func windowWillClose(_ notification: Notification) {
        saveState()
        canvas.setCapturesKeyboard(false)
        session.removeObserver(self)
        onClose?()
    }

    // MARK: Session

    public func session(_ s: DeviceLiveSession, changed: DeviceSessionChange) {
        if changed == .hello || changed == .phase { updateTitle() }
    }

    private func updateTitle() {
        window?.title = session.title
        window?.subtitle = session.subtitle
    }

    // MARK: Expand / Open in New Window

    @objc public func expand(_ sender: Any?) {
        if let onExpand { onExpand(); return }
        switchKind(to: .expanded)
    }

    @objc public func openInNewWindow(_ sender: Any?) { switchKind(to: .compact) }

    /// Switches between the compact and the expanded form in place.
    public func switchKind(to k: Kind) {
        guard k != kind, let window else { return }
        saveState()
        kind = k
        installCanvas()
        window.toolbar = nil
        installToolbar()
        present()
    }

    // MARK: Toolbar

    static let expandID = NSToolbarItem.Identifier("device.expand")
    static let moreID = NSToolbarItem.Identifier("device.more")
    static let captureID = NSToolbarItem.Identifier("device.capture")
    static let zoomID = NSToolbarItem.Identifier("device.zoom")
    static let openID = NSToolbarItem.Identifier("device.open")

    private func installToolbar() {
        let t = NSToolbar(identifier: kind == .compact ? "YcodeCompactDevice" : "YcodeExpandedDevice")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        window?.toolbar = t
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        kind == .compact ? [.flexibleSpace, Self.expandID, Self.moreID]
            : [.flexibleSpace, Self.captureID, Self.zoomID, Self.openID, Self.moreID]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func image(_ name: String, _ label: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: label) }
        switch id {
        case Self.expandID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = image("arrow.up.left.and.arrow.down.right", "Expand")
            item.label = "Expand"
            item.toolTip = "Expand to view all controls"
            item.isBordered = true
            item.target = self
            item.action = #selector(expand(_:))
            item.visibilityPriority = .high
            return item
        case Self.openID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = image("arrow.down.right.and.arrow.up.left", "Open in New Window")
            item.label = "Open in New Window"
            item.toolTip = "Switch to compact window"
            item.isBordered = true
            item.target = self
            item.action = #selector(openInNewWindow(_:))
            return item
        case Self.moreID:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = image("ellipsis", "More Actions")
            item.label = "More Actions"
            item.toolTip = "More Actions"
            item.showsIndicator = false
            item.menu = moreMenu
            item.visibilityPriority = .high
            return item
        case Self.captureID:
            let b = NSButton(image: image("keyboard", "Capture Keyboard") ?? NSImage(), target: self, action: #selector(toggleCapture(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.toolTip = "Capture Keyboard"
            b.setAccessibilityLabel("Capture Keyboard")
            captureButton = b
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = b
            item.label = "Capture Keyboard"
            return item
        case Self.zoomID:
            let images = ["minus.magnifyingglass", "arrow.up.left.and.down.right.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"]
                .compactMap { image($0, "") }
            let g = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne,
                                       labels: ["Zoom Out", "Zoom to Fit", "Zoom To Actual Size", "Zoom In"],
                                       target: self, action: #selector(zoomChosen(_:)))
            for (sub, tip) in zip(g.subitems, ["Zoom Out", "Zoom to Fit", "Zoom To Actual Size", "Zoom In"]) { sub.toolTip = tip }
            zoomGroup = g
            updateZoomSelection()
            return g
        default:
            return nil
        }
    }

    @objc private func zoomChosen(_ sender: NSToolbarItemGroup) {
        let commands: [DeviceCommand] = [.zoomOut, .zoomToFit, .physicalSize, .zoomIn]
        guard commands.indices.contains(sender.selectedIndex) else { return }
        canvas.perform(commands[sender.selectedIndex])
    }

    private func updateZoomSelection() {
        guard let g = zoomGroup else { return }
        switch canvas.zoom {
        case .fit: g.selectedIndex = 1
        case .actual: g.selectedIndex = 2
        case .scale: break
        }
    }

    @objc func toggleCapture(_ sender: NSButton) { canvas.setCapturesKeyboard(sender.state == .on) }

    // MARK: More Actions (Q6, Ycode decision)

    /// More Actions: the owner's items (Shut Down, Restart), Show / Hide
    /// Bezels, Show Frame Rate (the debug status line, §9 item 9) and
    /// Refresh Display.
    public func moreItems() -> [NSMenuItem] {
        var items = extraMoreItems?() ?? []
        if !items.isEmpty { items.append(.separator()) }
        let bezels = NSMenuItem(title: canvas.showsBezels ? "Hide Bezels" : "Show Bezels", action: #selector(toggleBezels(_:)), keyEquivalent: "")
        bezels.target = self
        let stats = NSMenuItem(title: "Show Frame Rate", action: #selector(toggleStatistics(_:)), keyEquivalent: "")
        stats.target = self
        stats.state = canvas.showsStatistics ? .on : .off
        let refresh = NSMenuItem(title: "Refresh Display", action: #selector(refreshDisplay(_:)), keyEquivalent: "")
        refresh.target = self
        return items + [bezels, stats, refresh]
    }

    @objc public func toggleBezels(_ sender: Any?) {
        canvas.showsBezels.toggle()
        defaults.set(canvas.showsBezels, forKey: "YcodeDeviceWindow.bezels")
    }

    @objc public func toggleStatistics(_ sender: Any?) {
        canvas.showsStatistics.toggle()
        defaults.set(canvas.showsStatistics, forKey: "YcodeDeviceWindow.statistics")
    }

    @objc func refreshDisplay(_ sender: Any?) { session.refreshDisplay() }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleBezels(_:)) { return canvas.canPerform(.toggleBezels) }
        return true
    }
}

extension DeviceWindowController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === moreMenu else { return }
        menu.removeAllItems()
        for i in moreItems() { menu.addItem(i) }
    }
}
#endif
