import AppKit
import YcodeIDECore
import YcodeSimControl

/// Devices `ycrun` booted on the hub's simulator host (`specs/ide/ycrun.md`
/// §11): each has a pid file, `<data>/ycrun/<device>.pid`, naming its
/// launcher. The hub lists such a device as running (its live screen is the
/// same display socket a hub start serves), and Shut Down stops it as
/// `ycrun simctl shutdown` does: SIGTERM to that pid, which saves the
/// device with warm boot. The host is asked every few seconds while the hub
/// shows, off the main thread, one question at a time.
extension DevicesController {
    /// How often the host is asked (seconds).
    static let ycrunPollInterval: TimeInterval = 4

    /// A remote simulator's device directory (`<data>/devices/<directory>`).
    static func deviceDirectory(_ remote: RemoteSimulator) -> String {
        URL(fileURLWithPath: remote.remoteDevicePath).lastPathComponent
    }

    /// Whether ycrun booted this device, as last asked.
    public func isYcrunBooted(_ remote: RemoteSimulator) -> Bool {
        ycrunBooted.contains(Self.deviceDirectory(remote))
    }

    /// Asks the host which devices ycrun booted (every `ycrunPollInterval`
    /// seconds, or now with `force`); the rows follow on the next poll.
    @discardableResult
    public func pollYcrun(force: Bool = false) -> Task<Void, Never>? {
        guard ycrunTask == nil, let host = ycrunHost?(), host.isConfigured else { return nil }
        if !force, let last = ycrunPolledAt, Date().timeIntervalSince(last) < Self.ycrunPollInterval { return nil }
        ycrunPolledAt = Date()
        let remote = RemoteSimulator(settings: host)
        let command = YcrunDeviceFiles.bootedCommand(data: host.dataDirectory)
        let task = Task { [weak self] in
            let (status, output) = await Task.detached { remote.runRemote(command) }.value
            guard let self else { return }
            // A host that does not answer keeps the last answer.
            if status == 0 {
                let now = YcrunDeviceFiles.parseBooted(output)
                if now != self.ycrunBooted {
                    self.ycrunBooted = now
                    self.applyRemoteRows()
                }
            }
            self.ycrunTask = nil
        }
        ycrunTask = task
        return task
    }

    /// Shut Down of a device ycrun booted: SIGTERM to its launcher, then
    /// up to `stopGrace` seconds for the save (ycrun's own rule).
    public func stopYcrunDevice(_ remote: RemoteSimulator) async -> (Bool, String) {
        let dir = Self.deviceDirectory(remote)
        let command = YcrunDeviceFiles.stopCommand(pidFile: YcrunDeviceFiles.pidFile(data: remote.settings.dataDirectory, directory: dir),
                                                   grace: Int(remote.stopGrace))
        let (status, output) = await Task.detached { remote.runRemote(command) }.value
        if status == 3 || status == 0 { ycrunBooted.remove(dir) }
        if status == 0 { return (true, "Shut down") }
        if status == 3 { return (true, "Already shut down") }
        let last = output.split(separator: "\n").last.map(String.init) ?? ""
        return (false, "Could not shut down the device ycrun started (status \(status))" + (last.isEmpty ? "" : ": \(last)"))
    }

    /// Takes the rows' running state from `currentRemoteRows` now.
    func applyRemoteRows() {
        guard let now = currentRemoteRows?() else { return }
        for r in now {
            guard let old = simulators.first(where: { $0.isYcodeRemote && $0.identifier == r.identifier }),
                  old.state != r.state, !busyDevices.contains(r.identifier) else { continue }
            updateYcodeRemote(r)
        }
    }
}
