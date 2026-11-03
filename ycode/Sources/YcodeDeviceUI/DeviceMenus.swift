// The device windows' menus (device-hub.md §7, "Ycode implementation"):
// the View menu's zoom and bezel items, the Device menu (the settings
// submenus of simulator-features.md §7.1, Orientation, Keyboard, the
// iPhone Duo's Fold) and the Controls menu, in the reference's order with
// its labels, contextual to the device. Every item carries a
// `DeviceCommand` (or an orientation) and goes to the key window's canvas.

#if os(macOS)
import AppKit
import YcodeDeviceModel

/// Finds the canvas the menus act on (the key device window's).
@MainActor
public protocol DeviceMenuTarget: AnyObject {
    var activeCanvas: DeviceCanvasView? { get }
}

@MainActor
public final class DeviceMenus: NSObject, NSMenuItemValidation {
    public weak var target: DeviceMenuTarget?

    public init(target: DeviceMenuTarget?) {
        self.target = target
    }

    /// One command's menu item with its key equivalent.
    public func item(_ c: DeviceCommand) -> NSMenuItem {
        let e = c.keyEquivalent
        let i = NSMenuItem(title: c.title, action: #selector(performCommand(_:)), keyEquivalent: e?.key ?? "")
        var mods: NSEvent.ModifierFlags = []
        if let m = e?.modifiers {
            if m.contains(.command) { mods.insert(.command) }
            if m.contains(.shift) { mods.insert(.shift) }
            if m.contains(.option) { mods.insert(.option) }
            if m.contains(.control) { mods.insert(.control) }
        }
        i.keyEquivalentModifierMask = mods
        i.representedObject = c.rawValue
        i.target = self
        return i
    }

    /// Controls: Home, Lock, App Switcher, Action Button, Rotate Left,
    /// Rotate Right, Screenshot, Record Screen / Stop Recording; Ycode adds
    /// Volume Up / Down.
    public func controlsMenu() -> NSMenu {
        let m = NSMenu(title: "Controls")
        for c in DeviceCommand.controlsMenu {
            m.addItem(c.map(item) ?? .separator())
        }
        return m
    }

    /// The View menu's device items: Zoom In, Zoom Out, Zoom to Fit,
    /// Physical Size, then Show / Hide Bezels.
    public func viewItems() -> [NSMenuItem] {
        DeviceCommand.zoomMenu.map(item) + [.separator(), item(.toggleBezels)]
    }

    /// The Device menu's own items: Orientation ▸, Keyboard ▸ (Keyboard
    /// Capture), and Fold ▸ for the iPhone Duo (Ycode: its pose commands).
    public func deviceItems() -> [NSMenuItem] {
        let orientation = NSMenuItem(title: "Orientation", action: nil, keyEquivalent: "")
        let om = NSMenu(title: "Orientation")
        for o in DeviceOrientation.allCases {
            let i = NSMenuItem(title: o.title, action: #selector(orientationChosen(_:)), keyEquivalent: "")
            i.representedObject = o.rawValue
            i.target = self
            om.addItem(i)
        }
        orientation.submenu = om
        let keyboard = NSMenuItem(title: "Keyboard", action: nil, keyEquivalent: "")
        let km = NSMenu(title: "Keyboard")
        km.addItem(item(.captureKeyboard))
        keyboard.submenu = km
        let fold = NSMenuItem(title: "Fold", action: nil, keyEquivalent: "")
        let fm = NSMenu(title: "Fold")
        for c in [DeviceCommand.poseClosed, .posePartiallyOpen, .poseOpen] { fm.addItem(item(c)) }
        fold.submenu = fm
        // A Vision Pro's room (visionos.md §2.6, §5.5.4; the reference's
        // Simulated Scenes): switched live through the device's `vision room`.
        let room = NSMenuItem(title: "Room", action: nil, keyEquivalent: "")
        let rm = NSMenu(title: "Room")
        for (key, title) in Self.rooms {
            let i = NSMenuItem(title: title, action: #selector(roomChosen(_:)), keyEquivalent: "")
            i.representedObject = key
            i.target = self
            rm.addItem(i)
        }
        room.submenu = rm
        return [orientation, keyboard, fold, room]
    }

    /// The runtime's rooms by key, with Ycode's titles (visionos.md §2.6).
    public static let rooms: [(key: String, title: String)] = [
        ("LivingRoomDay", "Living Room (Day)"), ("LivingRoomNight", "Living Room (Night)"),
        ("KitchenDay", "Kitchen (Day)"), ("KitchenNight", "Kitchen (Night)"),
        ("MuseumDay", "Museum (Day)"), ("MuseumNight", "Museum (Night)"),
    ]

    @objc public func roomChosen(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let canvas = target?.activeCanvas, let s = canvas.session else { return }
        canvas.showBanner("Loading \(sender.title)…", seconds: 3)
        s.sendCommand("vision room \(key)") { [weak canvas] reply in
            canvas?.showBanner(reply.hasPrefix("ok") ? "\(sender.title)" : "Room: \(reply)", seconds: 3)
        }
    }

    @objc public func performCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = DeviceCommand(rawValue: raw) else { return }
        target?.activeCanvas?.perform(c)
    }

    @objc public func orientationChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let o = DeviceOrientation(rawValue: raw) else { return }
        target?.activeCanvas?.session?.setOrientation(o)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let canvas = target?.activeCanvas else { return false }
        if item.action == #selector(roomChosen(_:)) {
            guard let s = canvas.session else { return false }
            return s.isLive && s.isSpatial
        }
        if item.action == #selector(orientationChosen(_:)) {
            guard let s = canvas.session, let raw = item.representedObject as? String else { return false }
            item.state = s.orientation.rawValue == raw ? .on : .off
            return s.isLive && s.canRotate && raw != DeviceOrientation.portraitUpsideDown.rawValue
        }
        guard let raw = item.representedObject as? String, let c = DeviceCommand(rawValue: raw) else { return true }
        let s = canvas.session
        switch c {
        case .recordScreen: item.title = s?.isRecording == true ? "Stop Recording" : "Record Screen"
        case .toggleBezels: item.title = canvas.showsBezels ? "Hide Bezels" : "Show Bezels"
        case .captureKeyboard: item.state = canvas.capturesKeyboard ? .on : .off
        case .poseClosed, .posePartiallyOpen, .poseOpen:
            let p: DevicePosture = c == .poseClosed ? .closed : c == .posePartiallyOpen ? .halfOpen : .openFlat
            item.state = s?.hingeTarget == p.angle ? .on : .off
        case .zoomToFit: item.state = canvas.mode == .hub && canvas.zoom == .fit ? .on : .off
        case .physicalSize: item.state = canvas.mode == .hub && canvas.zoom == .actual ? .on : .off
        default: break
        }
        // Items for features the device does not have are hidden (§7).
        switch c {
        case .actionButton: item.isHidden = s?.spec.hasActionButton != true
        case .volumeUp, .volumeDown: item.isHidden = s.map { !$0.spec.hasVolumeButtons } ?? false
        case .appSwitcher: item.isHidden = s?.spec.family == .watch
        case .resetCamera: item.isHidden = s?.isSpatial != true
        case .viewInHeadset:
            item.isHidden = canvas.headsetCommandEnabled == nil || (s != nil && s?.isSpatial != true && s?.isTakenOver != true)
            item.title = canvas.headsetCommandTitle?() ?? c.title
        case .poseClosed, .posePartiallyOpen, .poseOpen: item.isHidden = s?.isFoldable != true
        default: break
        }
        if canvas.mode == .compact, [.zoomIn, .zoomOut, .zoomToFit, .physicalSize].contains(c) { return false }
        return canvas.canPerform(c)
    }
}
#endif
