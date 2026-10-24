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
import YcodeHostServices
import YcodeHypervisor

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
    /// The launched app's pid ("ylaunch: launched <id> pid N"), and whether
    /// the app steps are still running (the stop snapshot, snapshot.md §12).
    private var appPID: Int32?
    private var appStepsBusy = false
    var launchedAppPID: Int32? { lock.withLock { appPID } }
    var appStepsRunning: Bool { lock.withLock { appStepsBusy } }
    /// When the pending spawn request was sent (nil: none pending).
    private var requestSince: Date?
    /// Host-side names to register into user/<uid> (701), each a host-task
    /// send right, and the tokens of the queued requests.
    var hostServices: [(name: String, port: UInt32)] = []
    private var queuedRegistrations: [(name: String, token: UInt32)] = []

    init(layout: DeviceLayout, host: MachHostTask, makeFileSystem: @escaping () -> DarwinFileSystem) {
        self.layout = layout
        self.host = host
        self.makeFileSystem = makeFileSystem
        // Host services that need no configuration (YcodeHostServices'
        // own table: the SCDynamicStore host server, scdynamicstore-host.md).
        hostServices += DefaultHostServices.start(host: host, log: { stderrLine("ycode-simd: " + $0) })
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

    // MARK: Snapshot (snapshot.md §2.6, §9)

    /// The control channel and the bound session port (host-task names), for
    /// a snapshot; nil before the session is bound.
    var snapshotState: (channel: UInt32, session: UInt32)? {
        guard let c = lock.withLock({ control }), let port = c.boundSessionPort else { return nil }
        return (c.channel, port)
    }

    /// After a restore: the host task holds the recorded channel and session
    /// rights under their recorded names again. The session is adopted (no
    /// new 700; launchd_sim's domains exist) and the app steps run as after
    /// a boot.
    func reattach(channel: UInt32, session: UInt32) {
        let c = LaunchSimControl(host: host, channel: channel, log: { [weak self] in self?.emit($0) })
        c.adoptSession(session)
        lock.withLock { control = c }
        // Diagnostics: while a spawn request (704) waits for launchd_sim's
        // answer, the channel's state every 30 s (for 10 minutes).
        Thread.detachNewThread { [self] in
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 30)
                if isEnding { return }
                if let since = lock.withLock({ requestSince }) {
                    emit("control: spawn request waiting \(Int(Date().timeIntervalSince(since))) s; channel 0x\(String(channel, radix: 16)): "
                        + host.debugPortState(channel))
                }
            }
        }
        // Guest liveness (snapshot.md §12.5): the restored frame is on the
        // display before any guest thread runs, so a lit frame says nothing
        // about a guest that hangs. A 703 round trip to launchd_sim needs
        // the restored threads to run, launchd_sim's request loop to take
        // the message and the kernel's IPC to carry the reply.
        let probeStart = Date()
        Thread.detachNewThread { [self] in
            for attempt in 1...10 {
                if isEnding { return }
                do {
                    _ = try c.domainEnvironment(Self.livenessProbeName)
                    emit("snapshot: restore: guest live: launchd_sim answered "
                        + "\(Int(Date().timeIntervalSince(probeStart) * 1000)) ms after its session was adopted")
                    announceClockChange(c)
                    return
                } catch {
                    // A timeout (30 s per request) or a refusal: say so and ask again.
                    emit("snapshot: restore: liveness request \(attempt) not answered: \(error)")
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        if layout.stagedAppGuestPath != nil || layout.launchBundleID != nil {
            let t = Thread { [self] in runApps(c) }
            t.name = "ycode-apps"
            t.start()
        }
    }

    /// The `user/<uid>` environment variable the liveness request asks for
    /// (never set: launchd_sim answers "not set").
    static let livenessProbeName = "YCODE_LIVENESS_PROBE"

    /// After a restore the calendar has jumped (snapshot.md §5, §12.5), as
    /// after a sleep, but timers the guest set on mach time (a status bar's
    /// next-minute timer) still wait out the time they had left. The
    /// Darwin notification that announces a set clock
    /// (`com.apple.system.clock_set`, libnotify's `kNotifyClockSet`) is
    /// posted once with the runtime's `notifyutil`, as a one-shot.
    private func announceClockChange(_ c: LaunchSimControl) {
        guard let gap = SnapshotSupport.shared?.restoreCalendarGapSeconds, gap >= 1 else { return }
        let tool = layout.runtimeRoot + "/usr/bin/notifyutil"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        do {
            let r = try runGuestProgram(c, name: "notifyutil clock_set", path: tool,
                                        argv: ["notifyutil", "-p", Self.clockSetNotification],
                                        out: layout.data + "/tmp/ycode-clock-set.out", err: layout.data + "/tmp/ycode-clock-set.err")
            emit("snapshot: restore: \(Self.clockSetNotification) posted (the calendar moved \(gap) s since the save): "
                + describe(waitStatus: r.status))
        } catch {
            emit("snapshot: restore: \(Self.clockSetNotification) not posted: \(error)")
        }
    }

    static let clockSetNotification = "com.apple.system.clock_set"

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

    /// Runs `path` (a host path the guest can reach; one in DEV is given to
    /// the guest at DEV's guest path) as a one-shot with stdout and stderr
    /// in the host files `out` and `err` (in DEV); waits for it. Returns the
    /// pid and wait status, or throws.
    private func runGuestProgram(_ c: LaunchSimControl, name: String, path: String, argv: [String], environment: [String] = [],
                                 out: String, err: String, started: ((Int32) -> Void)? = nil) throws -> (pid: Int32, status: Int32) {
        let fs = makeFileSystem()
        var ports: [UInt32] = []
        do {
            for file in [out, err] { ports.append(try outputFileport(fs, layout.guestPath(file))) }
        } catch {
            ports.forEach { try? host.deallocate($0) }
            throw error
        }
        let attributes = LaunchSimSpawnAttributes(path: layout.guestPath(path), argv: argv, environment: environment, workingDirectory: "/")
        let pid: Int32
        lock.withLock { requestSince = Date() }
        do {
            pid = try c.spawn(attributes, stdin: 0, stdout: ports[0], stderr: ports[1])
            lock.withLock { requestSince = nil }
        } catch {
            lock.withLock { requestSince = nil }
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
        // The open request is retried until SpringBoard serves it; on Ycode a
        // second boot reaches the home screen after about 3.5 minutes and an
        // install takes about 7, so the helper retries an open for up to 10
        // minutes and waits up to 20 for an install (app-install-launch.md
        // §6 item 3).
        let r = try runGuestProgram(c, name: "ylaunch \(step)", path: tool, argv: ["ylaunch"] + arguments,
                                    environment: ["YLAUNCH_RETRY_SECONDS=600", "YLAUNCH_INSTALL_SECONDS=1200"], out: out, err: err)
        let text = (FileManager.default.contents(atPath: out)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for line in text.split(separator: "\n") { emit("app: " + line) }
        if let e = FileManager.default.contents(atPath: err), !e.isEmpty {
            emit("app: ylaunch \(step) stderr: " + String(decoding: e.prefix(2000), as: UTF8.self))
        }
        return (r.status, text)
    }

    private func runApps(_ c: LaunchSimControl) {
        lock.withLock { appStepsBusy = true }
        defer { lock.withLock { appStepsBusy = false } }
        // SNAPSHOT (snapshot.md §9, the IDE's warm boot): with
        // YCODE_SNAPSHOT_HOLD_APPS the app steps wait for the home-screen snapshot.
        SnapshotSupport.shared?.holdAppsUntilSnapshot { [self] in isEnding }
        let bundleID = layout.launchBundleID
        if let app = layout.stagedAppGuestPath {
            do {
                let r = try ylaunch(c, step: "install", ["install", layout.guestPath(app)])
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
        if let url = layout.appURL { arguments += ["--url", url] }
        for e in layout.appEnvironment { arguments += ["--env", e] }
        do {
            let began = monotonicNanoseconds()
            let r = try ylaunch(c, step: "open", arguments)
            // The open request's length: spawn of ylaunch to its exit, which
            // follows FrontBoard's answer (the app's process runs; app-launch.md §5).
            stderrLine("ycode-simd: app launch: open request took \((monotonicNanoseconds() &- began) / 1_000_000) ms")
            let launched = r.output.split(separator: "\n").first { $0.hasPrefix("ylaunch: launched ") }
            if let launched, let range = launched.range(of: " pid ", options: .backwards),
               let pid = Int32(launched[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
                lock.withLock { appPID = pid }
            }
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
