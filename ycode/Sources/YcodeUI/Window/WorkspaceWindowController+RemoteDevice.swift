import AppKit

/// Ycode's remote simulator in Devices and Simulators: its row and Erase All
/// Content and Settings… (`run.md` §Warm boot item 7; the Devices window
/// spec, `devices.md`, has no erase command yet: see the round's report).
extension WorkspaceWindowController {
    /// Whether a workspace window runs an app on the remote simulator.
    static var remoteSimulatorInUse: Bool {
        NSApp?.windows.contains { w in
            guard let wc = w.windowController as? WorkspaceWindowController, case .remote = wc.session.simulatorRun?.target else { return false }
            return true
        } ?? false
    }

    /// Adds the remote simulator's row (when it is set up) and the erase
    /// action to a Devices and Simulators controller. `ssh` replaces the
    /// ssh program (tests).
    func configureYcodeRemoteDevice(_ c: DevicesController, defaults: UserDefaults = Preferences.shared.defaults, ssh: String? = nil) {
        let settings = RemoteSimulatorSettings.load(defaults)
        guard settings.isConfigured else { return }
        let running: Bool = {
            if case .remote = session.simulatorRun?.target { return true }
            return Self.remoteSimulatorInUse
        }()
        c.setYcodeRemote(DeviceRow.ycodeRemote(RemoteSimulator(settings: settings), running: running))
        c.eraseDevice = { [weak self, weak c] _ in
            guard let self else { return (false, "The workspace was closed.") }
            if Self.remoteSimulatorInUse { return (false, "Stop the run on \(RemoteSimulator.deviceName) before erasing it.") }
            var settings = RemoteSimulatorSettings.load(defaults)
            if let ssh { settings.ssh = ssh }
            let remote = RemoteSimulator(settings: settings)
            let result = await self.session.eraseRemoteSimulator(remote: remote)
            if result.0 { c?.setYcodeRemote(DeviceRow.ycodeRemote(remote, running: false)) }
            return result
        }
    }
}
