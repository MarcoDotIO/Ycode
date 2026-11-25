import AppKit
import YcodeIDECore

/// Device Hub opened with no workspace window (Product ▸ Destination ▸
/// Manage Devices… or Open Developer Tool ▸ Device Hub from the Welcome
/// window): Ycode's own simulators are listed and operated as from a
/// workspace (start, shut down, restart, the live screen, fold and rotate,
/// settings, erase), and the Mac's simctl simulators start in the simulator
/// viewer. Without a workspace there is no run to stop and no console: the
/// commands' output goes nowhere and a device a run uses is reported as
/// busy. Pairing needs a workspace (its forms report into its console).
extension DevicesController {
    /// Sets the hub up as `WorkspaceWindowController.configureYcodeRemoteDevice`
    /// does, without a workspace session. `ssh` replaces the ssh program (tests).
    public func configureStandalone(defaults: UserDefaults = Preferences.shared.defaults, ssh: String? = nil,
                                    simctl: SimctlDeviceControl? = SimctlDeviceControl()) {
        simctlControl = simctl
        let settings = RemoteSimulatorSettings.load(defaults)
        guard settings.isConfigured else { return }
        let inUse: (RemoteSimulator) -> Bool = { _ in WorkspaceWindowController.remoteSimulatorInUse }
        // Running: a run uses it, the hub started it, or ycrun booted it.
        let running: (RemoteSimulator) -> Bool = { [weak self] r in
            inUse(r) || RemoteDeviceSessions.shared.isRunning(r) || (self?.isYcrunBooted(r) ?? false)
        }
        ycrunHost = {
            var s = RemoteSimulatorSettings.load(defaults)
            if let ssh { s.ssh = ssh }
            return s
        }
        setYcodeRemote(rows: RemoteSimulator.hub(settings).map { DeviceRow.ycodeRemote($0, running: running($0)) })
        currentRemoteRows = {
            RemoteSimulator.hub(RemoteSimulatorSettings.load(defaults)).map { DeviceRow.ycodeRemote($0, running: running($0)) }
        }
        let remoteFor: (DeviceRow) -> RemoteSimulator? = { row in
            var settings = RemoteSimulatorSettings.load(defaults)
            if let ssh { settings.ssh = ssh }
            return RemoteSimulator.hub(settings).first { "\(settings.destination):\($0.remoteDevicePath)" == row.identifier }
        }
        let notSet = "Set the remote simulator in Settings ▸ Components ▸ Simulator Host first."
        startDevice = { row in
            guard let remote = remoteFor(row) else { return (false, notSet) }
            if inUse(remote) { return (false, "\(row.name) is running an app.") }
            return RemoteDeviceSessions.shared.start(remote) ? (true, "Started") : (false, "\(row.name) could not be started.")
        }
        shutDownDevice = { [weak self] row, force in
            guard let remote = remoteFor(row) else { return (false, notSet) }
            if RemoteDeviceSessions.shared.isRunning(remote) {
                await RemoteDeviceSessions.shared.shutDown(remote, force: force)
                return (true, "Shut down")
            }
            if let self, self.isYcrunBooted(remote) { return await self.stopYcrunDevice(remote) }
            return (false, "\(row.name) is used by a workspace\u{2019}s run; stop it there.")
        }
        makeDisplayLink = { row in
            guard let remote = remoteFor(row) else { return nil }
            return RemoteDisplayLink(remote: remote, name: remote.target?.deviceType.name ?? row.name, os: "\(row.platform) \(row.osVersion)")
        }
        cameraSetting = DevicesController.cameraSetting(defaults)
        headset.visionDisplay = (get: { RemoteSimulatorSettings.load(defaults).visionDisplay },
                                 set: { v in var s = RemoteSimulatorSettings.load(defaults); s.visionDisplay = v; s.save(defaults) })
        let control: (DeviceRow, [String]) async -> (Bool, String) = { row, words in
            guard let remote = remoteFor(row) else { return (false, notSet) }
            let (status, output) = await Task.detached { remote.control(words) }.value
            return (status == 0, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        foldDevice = control
        deviceSettings = control
        eraseDevice = { [weak self] row in
            guard let remote = remoteFor(row) else { return (false, notSet) }
            if inUse(remote) { return (false, "Stop the run on \(row.name) before erasing it.") }
            let (status, output) = await Task.detached { remote.erase() }.value
            guard status == 0 else {
                let last = output.split(separator: "\n").last.map(String.init) ?? ""
                return (false, "Erase failed (status \(status))" + (last.isEmpty ? "" : ": \(last)"))
            }
            self?.updateYcodeRemote(DeviceRow.ycodeRemote(remote, running: false))
            return (true, "Erased")
        }
    }
}
