import AppKit
import YcodeIDECore

/// Menu commands that work with only the Welcome window open (P-004,
/// `specs/ide/parity-inventory.md`): Window ▸ Organizer, Product ▸
/// Destination ▸ Manage Devices… and Open Developer Tool ▸ Device Hub,
/// Integrate ▸ Clone…, Editor ▸ Choose Theme…. The application delegate
/// ends the responder chain, so a workspace window's own commands come
/// first.
extension AppDelegate {
    /// The windows these commands open without a workspace.
    @MainActor enum WelcomeWindows {
        static var organizer: NSWindow?
        static var devices: NSWindow?
    }

    /// Window ▸ Organizer (⌥⇧⌘O) without a workspace window: the
    /// Organizer on the default archives folder.
    @objc public func showOrganizer(_ sender: Any?) {
        let c = OrganizerController()
        c.reload()
        let w = WelcomeWindows.organizer ?? NSWindow(contentViewController: c)
        w.contentViewController = c
        w.title = "Organizer"
        WelcomeWindows.organizer = w
        c.installToolbar()
        w.makeKeyAndOrderFront(nil)
    }

    /// Device Hub without a workspace window.
    @objc public func showDevices(_ sender: Any?) {
        if let w = WelcomeWindows.devices, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor in
            let lists = await Task.detached { DevicesList.load() }.value
            let c = DevicesController(devices: lists.devices, simulators: lists.simulators)
            // Ycode's simulators and the Mac's simctl ones operate without a workspace too.
            c.configureStandalone()
            let w = c.makeWindow()
            c.restoreState()
            WelcomeWindows.devices = w
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Integrate ▸ Clone… without a workspace window: the Welcome
    /// window's Clone….
    @objc public func scmClone(_ sender: Any?) {
        (welcome ?? showWelcomeWindow(nil)).cloneClicked(sender)
    }

    /// Editor ▸ Choose Theme… without a workspace window: Settings ▸
    /// Appearance.
    @objc public func chooseTheme(_ sender: Any?) { SettingsWindowController.shared.show(pane: "Appearance") }
}
