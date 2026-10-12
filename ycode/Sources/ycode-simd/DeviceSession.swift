// ycode-simd --device: the host's control session with launchd_sim
// (stage7-contract.md §3.2 item 1; specs/simulator/launch-sim-control.md
// §5.2). When the 808 reply has handed launchd_sim its service port, a
// session thread binds the session (700) with a port the host keeps, then
// runs the `--oneshot` programs as real one-shots (704 spawn with fileports
// for stdout and stderr, 705 waitpid). At the end of the run the host
// destroys the session port, and launchd_sim shuts the guest down.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinABI
import YcodeDarwinKernel

final class DeviceSession: @unchecked Sendable {
    let layout: DeviceLayout
    let host: MachHostTask
    /// A file system for opening the one-shots' stdio files (host side).
    let makeFileSystem: () -> DarwinFileSystem
    private let lock = NSLock()
    private var control: LaunchSimControl?
    private var ending = false
    /// One line per one-shot (by index; 1000 = app install, 1001 = app launch).
    private var results: [Int: String] = [:]
    private var thread: Thread?
    /// Host-side names to register into user/<uid> (701), each a host-task
    /// send right, and the tokens of the queued requests.
    var hostServices: [(name: String, port: UInt32)] = []
    private var queuedRegistrations: [(name: String, token: UInt32)] = []

    init(layout: DeviceLayout, host: MachHostTask, makeFileSystem: @escaping () -> DarwinFileSystem) {
        self.layout = layout
        self.host = host
        self.makeFileSystem = makeFileSystem
    }

    private func emit(_ text: String) { stderrLine("ycode-simd: " + text) }

    /// The service port exists and is about to be handed over: queue the
    /// host-side names' 701 requests on it (launch-sim-control.md §5.2 step 1).
    func servicePortCreated(_ channel: UInt32) {
        let c = LaunchSimControl(host: host, channel: channel, log: { [weak self] in self?.emit($0) })
        var queued: [(name: String, token: UInt32)] = []
        for (name, port) in hostServices {
            do { queued.append((name, try c.queueRegistration(name, port: port))) } catch {
                emit("control: 701 register \(name) could not be queued: \(error)")
            }
        }
        lock.withLock {
            control = c
            queuedRegistrations = queued
        }
    }

    /// The control channel arrived (service thread): start the session thread.
    func channelArrived(_ channel: UInt32) {
        let c = lock.withLock { () -> LaunchSimControl in
            if let c = control, c.channel == channel { return c }
            let c = LaunchSimControl(host: host, channel: channel, log: { [weak self] in self?.emit($0) })
            control = c
            return c
        }
        let t = Thread { [self] in run(c) }
        t.name = "ycode-session"
        lock.withLock { thread = t }
        t.start()
    }

    private var isEnding: Bool { lock.withLock { ending } }

    private func run(_ c: LaunchSimControl) {
        // Queued until launchd_sim has created its domains (§5.1).
        do {
            try c.bindSession()
        } catch {
            emit("control: bind failed: \(error) (system-domain jobs stay held)")
        }
        for (name, token) in lock.withLock({ queuedRegistrations }) {
            do {
                try c.finishRegistration(token, name: name)
                emit("control: 701 registered \(name)")
            } catch {
                emit("control: 701 register \(name) failed: \(error)")
            }
        }
        if layout.stagedAppGuestPath != nil || layout.launchBundleID != nil {
            let t = Thread { [self] in runApps(c) }
            t.name = "ycode-apps"
            t.start()
        }
        guard !layout.oneshots.isEmpty else { return }
        if let delay = layout.oneshotDelay {
            let until = Date().addingTimeInterval(TimeInterval(delay))
            while Date() < until, !isEnding { Thread.sleep(forTimeInterval: 0.2) }
        }
        for index in layout.oneshots.indices where !isEnding {
            runOneshot(c, index)
        }
    }

    /// A send right (host task) to a fileport of the host file `path`, opened
    /// for writing (created, truncated). The descriptor is closed again: the
    /// fileport holds the open file description.
    private func outputFileport(_ fs: DarwinFileSystem, _ path: String) throws -> UInt32 {
        let fd = try fs.open(path, flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT | DarwinOpen.O_TRUNC, mode: 0o644)
        defer { try? fs.close(fd) }
        return try host.makeFileport(try fs.openFile(for: fd))
    }

    /// Runs `path` (a host path the guest can reach) as a one-shot with
    /// stdout and stderr in the host files `out` and `err`; waits for it.
    /// Returns the pid and wait status, or throws.
    private func runGuestProgram(_ c: LaunchSimControl, name: String, path: String, argv: [String],
                                 out: String, err: String, started: ((Int32) -> Void)? = nil) throws -> (pid: Int32, status: Int32) {
        let fs = makeFileSystem()
        var ports: [UInt32] = []
        do {
            for file in [out, err] { ports.append(try outputFileport(fs, file)) }
        } catch {
            ports.forEach { try? host.deallocate($0) }
            throw error
        }
        let attributes = LaunchSimSpawnAttributes(path: path, argv: argv, workingDirectory: "/")
        let pid: Int32
        do {
            pid = try c.spawn(attributes, stdin: 0, stdout: ports[0], stderr: ports[1])
        } catch {
            // The moved rights came back on failure (pseudo-receive) or are gone.
            ports.forEach { try? host.deallocate($0) }
            throw error
        }
        emit("control: one-shot \(name) spawned (704): pid \(pid)")
        started?(pid)
        let status = try c.waitpid(pid, timeout: nil)
        emit("control: one-shot \(name) (pid \(pid)) ended (705): " + describe(waitStatus: status))
        return (pid, status)
    }

    private func runOneshot(_ c: LaunchSimControl, _ index: Int) {
        let name = layout.oneshotLabel(index)
        do {
            let r = try runGuestProgram(c, name: name, path: layout.oneshotProgram(index), argv: layout.oneshots[index],
                                        out: layout.oneshotOutputHostPath(index, err: false),
                                        err: layout.oneshotOutputHostPath(index, err: true),
                                        started: { [self] pid in record(index, "\(name): pid \(pid), still running") })
            record(index, "\(name): pid \(r.pid), " + describe(waitStatus: r.status))
        } catch {
            if !isEnding { record(index, "\(name): failed: \(error)") }
        }
    }

    // MARK: Apps (stage7-contract.md §3.2 items 2, 3)

    /// `ylaunch <arguments>` as a one-shot; its stdout and stderr go to
    /// DEV/data/tmp/ycode-ylaunch-<step>.{out,err}. Returns the exit status
    /// and the stdout text.
    private func ylaunch(_ c: LaunchSimControl, step: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        guard let tool = layout.ylaunchPath else { throw LaunchSimControlError(operation: "ylaunch: not staged", code: 2) }
        let out = layout.data + "/tmp/ycode-ylaunch-\(step).out", err = layout.data + "/tmp/ycode-ylaunch-\(step).err"
        let r = try runGuestProgram(c, name: "ylaunch \(step)", path: tool, argv: ["ylaunch"] + arguments, out: out, err: err)
        let text = (FileManager.default.contents(atPath: out)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for line in text.split(separator: "\n") { emit("app: " + line) }
        if let e = FileManager.default.contents(atPath: err), !e.isEmpty {
            emit("app: ylaunch \(step) stderr: " + String(decoding: e.prefix(2000), as: UTF8.self))
        }
        return (r.status, text)
    }

    private func runApps(_ c: LaunchSimControl) {
        let bundleID = layout.launchBundleID
        if let app = layout.stagedAppGuestPath {
            do {
                let r = try ylaunch(c, step: "install", ["install", app])
                let installed = r.output.split(separator: "\n").compactMap { line -> String? in
                    line.hasPrefix("ylaunch: installed ") ? String(line.dropFirst("ylaunch: installed ".count)) : nil
                }.first
                guard r.status == 0, let installed else {
                    record(1000, "app install: failed (" + describe(waitStatus: r.status) + ")")
                    return
                }
                record(1000, "app install: \(installed) installed")
            } catch {
                record(1000, "app install: failed: \(error)")
                return
            }
        }
        guard let bundleID, !isEnding else { return }
        var arguments = ["open", bundleID, "--stdout", DeviceLayout.appStdoutGuestPath, "--stderr", DeviceLayout.appStderrGuestPath]
        for a in layout.appArguments { arguments += ["--arg", a] }
        for e in layout.appEnvironment { arguments += ["--env", e] }
        do {
            let r = try ylaunch(c, step: "open", arguments)
            let launched = r.output.split(separator: "\n").first { $0.hasPrefix("ylaunch: launched ") }
            record(1001, launched.map { "app launch: " + $0.dropFirst("ylaunch: ".count) }
                   ?? "app launch: failed (" + describe(waitStatus: r.status) + ")")
        } catch {
            record(1001, "app launch: failed: \(error)")
        }
    }

    private func describe(waitStatus s: Int32) -> String {
        s & 0x7F == 0 ? "exit \((s >> 8) & 0xFF)" : "signal \(s & 0x7F)"
    }

    private func record(_ index: Int, _ line: String) { lock.withLock { results[index] = line } }

    /// The one-shots' results, in order.
    var resultLines: [String] { lock.withLock { results.keys.sorted().map { results[$0]! } } }

    /// Ends the session: launchd_sim shuts the guest down (§3.1).
    func end() {
        let c = lock.withLock { () -> LaunchSimControl? in ending = true; return control }
        c?.endSession()
    }

    var isBound: Bool { lock.withLock { control }?.isBound ?? false }
}
#endif
