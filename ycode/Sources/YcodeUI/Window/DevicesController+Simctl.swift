import AppKit
import YcodeDeviceModel
import YcodeDeviceUI
import YcodeIDECore

/// Device Hub and the Mac's own simulators, the ones `xcrun simctl list`
/// reports (`specs/ide/device-hub.md` "Ycode decisions (2026-11-17)"):
/// Start (`simctl boot`, then the simulator viewer opens; with none
/// installed the device stays booted and the banner says so), Shut Down,
/// Restart and Erase All Content and Settings… (a shut-down device, behind
/// the hub's confirmation) from the status view, the row's context menu and
/// More Actions. Their screens show in the simulator viewer, so while one
/// runs the canvas draws its picture with a glass capsule naming it, its
/// state and Show in Viewer; Screenshot acts through simctl and the other
/// controls say the viewer has them. The 2-second poll follows their state.
/// The UI names no Apple product: "simulator viewer" is Ycode's own term.
extension DevicesController {
    /// A simulator from simctl's list that the hub operates: not a physical
    /// device, not one of Ycode's, and the window set simctl's control.
    public func isSimctlOperated(_ r: DeviceRow) -> Bool {
        simctlControl != nil && !r.isYcodeRemote && !devices.contains { $0.identifier == r.identifier }
    }

    public static let showInViewerTitle = "Show in Viewer"
    /// The controls' reason while a Mac simulator runs in the simulator viewer…
    public static let simctlRunningReason = "The simulator viewer has these controls."
    /// …and while it is shut down.
    public static let simctlStoppedReason = "Start this simulator to use its controls."

    /// The capsule's second line: the device's state in words.
    public static func simctlStateText(_ state: String) -> String {
        switch state {
        case "Booted": "Running in the simulator viewer"
        case "Shutdown": "Shut down"
        case "Booting": "Starting"
        case "Shutting Down": "Shutting down"
        default: state
        }
    }

    /// The canvas for a Mac simulator: the running one's capsule, or the
    /// stopped one's Start.
    func showSimctlCanvas(_ r: DeviceRow, spec: DeviceFrameSpec, os: String) {
        if r.state == "Booted" {
            canvas.unavailableControlsReason = Self.simctlRunningReason
            canvas.availableControls = [.screenshot]
            canvas.showElsewhere(spec: spec, title: r.name, detail: Self.simctlStateText(r.state), action: Self.showInViewerTitle)
        } else {
            canvas.unavailableControlsReason = Self.simctlStoppedReason
            canvas.availableControls = []
            canvas.showStopped(spec: spec, name: r.name, os: os, action: canStart(r) ? "Start" : nil)
        }
    }

    /// The status view's button: Show in Viewer for a running Mac
    /// simulator, else Start.
    func canvasActionChosen() {
        guard let r = selected else { return }
        if isSimctlOperated(r), r.state == "Booted" { showInViewer(r) } else { start(r) }
    }

    // MARK: Commands

    func startSimctl(_ r: DeviceRow) -> Task<Void, Never>? {
        guard canStart(r), let control = simctlControl else { return nil }
        let udid = r.identifier
        // Booted with no viewer (or one that did not open) is still Booted;
        // the banner says why nothing shows.
        return runSimctl(r, newState: "Booted") {
            let s = control.start(udid)
            return (s.booted, s.message)
        }
    }

    func shutDownSimctl(_ r: DeviceRow) -> Task<Void, Never>? {
        guard canShutDown(r), let control = simctlControl else { return nil }
        let udid = r.identifier
        return runSimctl(r, newState: "Shutdown") {
            let (ok, message) = control.shutDown(udid)
            return (ok, ok ? nil : message)
        }
    }

    /// Show in Viewer: the simulator viewer opens again on the device.
    @discardableResult
    public func showInViewer(_ r: DeviceRow? = nil) -> Task<Void, Never>? {
        guard let r = r ?? selected, isSimctlOperated(r), r.state == "Booted", let control = simctlControl else { return nil }
        let udid = r.identifier
        let task = Task { [weak self] in
            let (ok, message) = await Task.detached { control.show(udid) }.value
            if !ok { self?.canvas.showBanner(message, seconds: 4) }
            self?.simctlTask = nil
        }
        simctlTask = task
        return task
    }

    func canEraseSimctl(_ r: DeviceRow) -> Bool {
        isSimctlOperated(r) && r.state == "Shutdown" && eraseTask == nil && !busyDevices.contains(r.identifier)
    }

    /// Erase All Content and Settings… of a shut-down Mac simulator, after
    /// the hub's confirmation.
    func eraseSimctl(_ r: DeviceRow) -> Task<Void, Never>? {
        guard isSimctlOperated(r), let control = simctlControl, eraseTask == nil else { return nil }
        guard r.state == "Shutdown" else {
            canvas.showBanner("Shut down \u{201C}\(r.name)\u{201D} before erasing it.", seconds: 4)
            return nil
        }
        guard confirmErase(r) else { return nil }
        let udid = r.identifier
        let task = runSimctl(r, newState: nil) {
            let (ok, message) = control.erase(udid)
            return (ok, ok ? "Erased" : message)
        }
        eraseTask = task
        return task
    }

    /// Runs one simctl command off the main actor with the device shown busy;
    /// on success the row takes `newState`. The work's banner (a failure, a
    /// notice or a confirmation) shows on the canvas: 4 seconds unless it is
    /// a plain confirmation.
    private func runSimctl(_ r: DeviceRow, newState: String?,
                           _ work: @escaping @Sendable () -> (ok: Bool, banner: String?)) -> Task<Void, Never> {
        busyDevices.insert(r.identifier)
        refreshCanvas()
        let task = Task { [weak self] in
            let (ok, banner) = await Task.detached { work() }.value
            guard let self else { return }
            self.busyDevices.remove(r.identifier)
            if ok, let newState { self.setSimctlState(r.identifier, newState) }
            if let banner { self.canvas.showBanner(banner, seconds: ok && newState == nil ? 2 : 4) }
            self.simctlTask = nil
            self.lifecycleTask = nil
            if self.eraseTask != nil, newState == nil { self.eraseTask = nil }
            if self.isViewLoaded, self.selected?.identifier == r.identifier { self.showDetails() } else { self.refreshCanvas() }
        }
        simctlTask = task
        lifecycleTask = task
        return task
    }

    /// A Mac simulator's state changed (a command or the poll).
    func setSimctlState(_ id: String, _ state: String) {
        guard let i = simulators.firstIndex(where: { $0.identifier == id && !$0.isYcodeRemote }), simulators[i].state != state else { return }
        simulators[i].state = state
        rebuildModel()
        reloadSidebar()
        if selected?.identifier == id {
            selected = simulators[i]
            if isViewLoaded { showDetails() }
        }
    }

    /// The controls without a live display, for a Mac simulator: Screenshot
    /// through simctl, and the lifecycle commands.
    func performSimctl(_ c: DeviceCommand, _ r: DeviceRow) -> Bool {
        switch c {
        case .screenshot:
            guard r.state == "Booted", let control = simctlControl else { return false }
            let path = DeviceLiveSession.captureDirectory.appendingPathComponent(DeviceCaptureNames.screenshot(device: r.name, at: Date())).path
            let task = Task { [weak self] in
                let (ok, message) = await Task.detached { control.screenshot(r.identifier, to: path) }.value
                // "Screenshot Saved", "2 Screenshots Saved" (one per lit screen), or the failure.
                self?.canvas.showBanner(message, seconds: ok ? 2 : 4)
                self?.simctlTask = nil
            }
            simctlTask = task
            return true
        case .start: return start(r) != nil
        case .shutDown, .forceShutDown: return shutDown(r) != nil
        case .restart: return restart(r) != nil
        default: return false
        }
    }

    // MARK: Menus

    /// Start, or Shut Down and Restart (simctl has no forced shutdown).
    func simctlLifecycleItems(_ r: DeviceRow) -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = r.identifier
            i.isEnabled = enabled
            return i
        }
        if r.state == "Booted" {
            return [item("Shut Down", #selector(shutDownChosen(_:)), enabled: canShutDown(r)),
                    item("Restart", #selector(restartChosen(_:)), enabled: canShutDown(r)), .separator()]
        }
        return [item("Start", #selector(startChosen(_:)), enabled: canStart(r)), .separator()]
    }

    /// Show in Viewer, for More Actions and the context menu (empty for other rows).
    func simctlShowItems(for r: DeviceRow) -> [NSMenuItem] {
        guard isSimctlOperated(r) else { return [] }
        let i = NSMenuItem(title: Self.showInViewerTitle, action: #selector(showInViewerChosen(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = r.identifier
        i.isEnabled = r.state == "Booted"
        return [i, .separator()]
    }

    /// A Mac simulator's context menu: its lifecycle, Show in Viewer,
    /// and Erase All Content and Settings… (enabled while it is shut down).
    func simctlContextMenu(_ r: DeviceRow) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for i in simctlLifecycleItems(r) + simctlShowItems(for: r) { menu.addItem(i) }
        let erase = NSMenuItem(title: Self.eraseTitle, action: #selector(eraseChosen(_:)), keyEquivalent: "")
        erase.target = self
        erase.tag = rows.firstIndex { $0.identifier == r.identifier } ?? -1
        erase.isEnabled = canEraseSimctl(r)
        menu.addItem(erase)
        return menu
    }

    @objc func showInViewerChosen(_ sender: Any?) {
        let id = (sender as? NSMenuItem)?.representedObject as? String
        showInViewer(id.flatMap { id in allRows.first { $0.identifier == id } })
    }

    // MARK: State

    /// Every 2 seconds while the hub shows: simctl's states, read off the
    /// main actor (one read at a time).
    func pollSimctl() {
        guard let control = simctlControl, !simctlPolling else { return }
        simctlPolling = true
        Task { [weak self] in
            let now = await Task.detached { control.list() }.value
            guard let self else { return }
            self.simctlPolling = false
            for r in now ?? [] where !self.busyDevices.contains(r.identifier) { self.setSimctlState(r.identifier, r.state) }
        }
    }
}
