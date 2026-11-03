import Foundation
import YcodeSubprocess

/// Devices started from the hub (Start), keyed by device path. A started
/// device runs until Shut Down (with warm boot it is saved, as at a run's
/// Stop) or until Ycode quits (Ycode decision for "Stop simulators on
/// quit", device-hub.md §2.3 Q3). A run on a started device shuts it
/// down first (the launcher holds one run of a device at a time).
@MainActor
public final class RemoteDeviceSessions {
    public static let shared = RemoteDeviceSessions()
    public static let didChange = Notification.Name("YcodeRemoteDeviceSessionsDidChange")

    final class Entry {
        let remote: RemoteSimulator
        let process: StreamingProcess
        var pid: Int?
        var stopping = false
        var exited: [CheckedContinuation<Void, Never>] = []
        var done = false
        init(remote: RemoteSimulator, process: StreamingProcess) {
            self.remote = remote
            self.process = process
        }
    }

    private var entries: [String: Entry] = [:]
    private var quitObserver: NSObjectProtocol?

    /// Ycode quits: every started device is shut down (SIGINT to its
    /// launcher, which saves it with warm boot; Q3, Ycode decision). The
    /// signals are sent before the app exits; the saves finish on the host.
    func shutDownAllForQuit() {
        for e in entries.values where !e.done {
            if let pid = e.pid { _ = e.remote.signalRemote(pid, signal: "INT") } else { e.process.signal(SIGINT) }
        }
    }
    /// The launcher's lines (the console of the window that started it).
    public var output: (String) -> Void = { _ in }

    public func isRunning(_ remote: RemoteSimulator) -> Bool { entries[remote.remoteDevicePath] != nil }
    public var runningDevicePaths: Set<String> { Set(entries.keys) }

    /// Starts the device; false when it runs already or cannot be started.
    @discardableResult
    public func start(_ remote: RemoteSimulator) -> Bool {
        guard remote.settings.isConfigured, entries[remote.remoteDevicePath] == nil else { return false }
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: IDEProcess.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemoteDeviceSessions.shared.shutDownAllForQuit() }
            }
        }
        let proc = StreamingProcess(executable: remote.settings.ssh, arguments: remote.sshArguments(remote.startCommand))
        let e = Entry(remote: remote, process: proc)
        entries[remote.remoteDevicePath] = e
        do {
            try proc.start(onLine: { [weak self, weak e] line in
                if let pid = RemoteSimulator.remotePID(line) { e?.pid = pid; return }
                self?.output(line)
            }, onExit: { [weak self, weak e] _ in
                guard let self, let e else { return }
                e.done = true
                if self.entries[e.remote.remoteDevicePath] === e { self.entries[e.remote.remoteDevicePath] = nil }
                e.exited.forEach { $0.resume() }
                e.exited = []
                NotificationCenter.default.post(name: Self.didChange, object: self)
            })
        } catch {
            entries[remote.remoteDevicePath] = nil
            return false
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    /// Shut Down (SIGINT to the launcher: with warm boot the device is
    /// saved) or Force Shut Down (SIGKILL to ycode-simd's shell: no save);
    /// returns when the launcher has ended (or after the stop grace).
    public func shutDown(_ remote: RemoteSimulator, force: Bool = false) async {
        guard let e = entries[remote.remoteDevicePath], !e.done else { return }
        e.stopping = true
        if let pid = e.pid {
            let status = await Task.detached { remote.signalRemote(pid, signal: force ? "KILL" : "INT") }.value
            if status != 0 { e.process.signal(SIGINT) }
        } else {
            e.process.signal(SIGINT)
        }
        let grace = remote.stopGrace
        Task { [weak e] in
            try? await Task.sleep(for: .seconds(grace))
            if let e, !e.done { e.process.signal(SIGINT) }
        }
        if !e.done { await withCheckedContinuation { e.exited.append($0) } }
    }

    /// Shuts every started device down (Ycode quits).
    public func shutDownAll() async {
        for e in entries.values { await shutDown(e.remote) }
    }
}
