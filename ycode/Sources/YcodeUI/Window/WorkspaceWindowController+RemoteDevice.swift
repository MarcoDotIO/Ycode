import AppKit

/// Ycode's remote simulator in Devices and Simulators: its row, the fold
/// controls of a foldable one (`foldable.md` §8.3) and Erase All
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
        // The run in this window, else any window's (one remote run at a time per device).
        let busy: (RemoteSimulator) -> Bool = { [weak self] remote in
            if let r = self?.session.simulatorRun, case .remote = r.target {
                return r.remote?.remoteDevicePath == nil || r.remote?.remoteDevicePath == remote.remoteDevicePath
            }
            return Self.remoteSimulatorInUse
        }
        // Running: a run uses it, or it was started from the hub.
        let running: (RemoteSimulator) -> Bool = { busy($0) || RemoteDeviceSessions.shared.isRunning($0) }
        c.setYcodeRemote(rows: RemoteSimulator.all(settings).map { DeviceRow.ycodeRemote($0, running: running($0)) })
        c.currentRemoteRows = {
            RemoteSimulator.all(RemoteSimulatorSettings.load(defaults)).map { DeviceRow.ycodeRemote($0, running: running($0)) }
        }
        let remoteFor: (DeviceRow) -> RemoteSimulator? = { row in
            var settings = RemoteSimulatorSettings.load(defaults)
            if let ssh { settings.ssh = ssh }
            return RemoteSimulator.all(settings).first { "\(settings.destination):\($0.remoteDevicePath)" == row.identifier }
        }
        // Start / Shut Down from the hub (device-hub.md "Ycode implementation").
        c.startDevice = { [weak self] row in
            guard let remote = remoteFor(row) else { return (false, "Set the remote simulator in Settings ▸ Simulators first.") }
            if busy(remote) { return (false, "\(row.name) is running an app.") }
            RemoteDeviceSessions.shared.output = { [weak self] line in self?.session.appendConsole(line + "\n", kind: .debugger) }
            self?.session.appendConsole("Ycode: starting \(row.name) on \(remote.settings.destination)\n", kind: .debugger)
            return RemoteDeviceSessions.shared.start(remote) ? (true, "Started") : (false, "\(row.name) could not be started.")
        }
        c.shutDownDevice = { [weak self] row, force in
            guard let remote = remoteFor(row) else { return (false, "Set the remote simulator in Settings ▸ Simulators first.") }
            if RemoteDeviceSessions.shared.isRunning(remote) {
                await RemoteDeviceSessions.shared.shutDown(remote, force: force)
                return (true, "Shut down")
            }
            // A run uses it: Shut Down is the run's Stop.
            if let self, let run = self.session.simulatorRun, case .remote = run.target, run.remote?.remoteDevicePath == remote.remoteDevicePath {
                self.session.stopSimulatorRun(remote: remote)
                return (true, "Stopping the run")
            }
            return (false, "\(row.name) is used by another window's run; stop it there.")
        }
        c.makeDisplayLink = { row in
            guard let remote = remoteFor(row) else { return nil }
            // The compact window's title is the device type's name (its row
            // adds " (Ycode)"): it leaves room for the Expand │ More capsule.
            return RemoteDisplayLink(remote: remote, name: remote.target?.deviceType.name ?? row.name, os: "iOS \(row.osVersion)")
        }
        // The camera of Ycode's simulators (camera.md "Ycode implementation"): the same setting as Settings ▸ Simulators.
        c.cameraSetting = DevicesController.cameraSetting(defaults)
        c.eraseDevice = { [weak self, weak c] row in
            guard let self else { return (false, "The workspace was closed.") }
            if Self.remoteSimulatorInUse { return (false, "Stop the run on \(RemoteSimulator.deviceName) before erasing it.") }
            var settings = RemoteSimulatorSettings.load(defaults)
            if let ssh { settings.ssh = ssh }
            let all = RemoteSimulator.all(settings)
            guard let remote = all.first(where: { "\(settings.destination):\($0.remoteDevicePath)" == row.identifier }) ?? all.first else {
                return (false, "Set the remote simulator in Settings ▸ Simulators first.")
            }
            let result = await self.session.eraseRemoteSimulator(remote: remote)
            if result.0 { c?.updateYcodeRemote(DeviceRow.ycodeRemote(remote, running: false)) }
            return result
        }
        // Fold, hinge and rotation of a running iPhone Duo (foldable.md §8.3 E1).
        c.foldDevice = { [weak self] row, words in
            guard let self else { return (false, "The workspace was closed.") }
            var settings = RemoteSimulatorSettings.load(defaults)
            if let ssh { settings.ssh = ssh }
            guard let remote = RemoteSimulator.all(settings).first(where: { "\(settings.destination):\($0.remoteDevicePath)" == row.identifier }) else {
                return (false, "Set the remote simulator in Settings ▸ Simulators first.")
            }
            return await self.session.controlRemoteSimulator(remote: remote, words)
        }
        // Appearance, accessibility, location and sound of a running Ycode
        // simulator (devices.md §Settings): the same control path.
        c.deviceSettings = { [weak self] row, words in
            guard let self else { return (false, "The workspace was closed.") }
            var settings = RemoteSimulatorSettings.load(defaults)
            if let ssh { settings.ssh = ssh }
            guard let remote = RemoteSimulator.all(settings).first(where: { "\(settings.destination):\($0.remoteDevicePath)" == row.identifier }) else {
                return (false, "Set the remote simulator in Settings ▸ Simulators first.")
            }
            return await self.session.controlRemoteSimulator(remote: remote, words)
        }
    }
}
