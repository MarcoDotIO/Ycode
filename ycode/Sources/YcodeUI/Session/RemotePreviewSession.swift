import AppKit
import YcodeDeviceUI
import YcodeDisplayStream
import YcodeIDECore
import YcodeSubprocess

/// A preview device running the preview host, with its display stream and
/// the host's reports. One per preview device, shared by every workspace
/// window (`RemotePreviewSessions`). See `specs/ide/previews.md`.
@MainActor
public final class RemotePreviewSession {
    public enum Phase: Equatable {
        case stopped
        case uploading
        /// Booting or restoring the device, installing and launching the host.
        case starting(String)
        case running
        case failed(String)
    }

    public let remote: RemoteSimulator
    public let platform: PreviewPlatform
    public private(set) var phase: Phase = .stopped
    public private(set) var link: RemoteDisplayLink?
    public private(set) var host = PreviewHostState(running: false)
    /// The last plan the host reported ready, and the plan in flight.
    public private(set) var readyGeneration = 0
    public private(set) var generation = 0
    public private(set) var lastPlan: PreviewPlan?
    /// Times of the start (seconds from `start` to the host's `started`).
    public private(set) var startSeconds: Double?
    public var onChange: (() -> Void)?
    /// The launcher's lines (diagnostics; the canvas does not show them).
    public var onLine: ((String) -> Void)?
    private var process: StreamingProcess?
    private var reports: StreamingProcess?
    private var remotePID: Int?
    private var waiters: [Int: CheckedContinuation<PreviewHost.Report, Never>] = [:]
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    private let controlPath: String
    /// The deployment target of the host (the runtime's version).
    public let deploymentTarget: String

    public init(remote: RemoteSimulator, platform: PreviewPlatform) {
        self.remote = remote.previewDevice
        self.platform = platform
        deploymentTarget = remote.runtimeVersion.map(Self.majorMinor) ?? "27.0"
        controlPath = "/tmp/ycode-pv-\(getuid())-%C"
    }

    static func majorMinor(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }

    /// ssh options: keys only, and one shared connection for every call
    /// (uploads cost one round trip instead of a new login).
    var sshOptions: [String] {
        ["-o", "BatchMode=yes", "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=600",
         "-o", "ServerAliveInterval=15"]
    }

    func ssh(_ command: String) -> [String] { sshOptions + [remote.settings.destination, command] }

    public var isRunning: Bool { phase == .running }

    /// Uploads the host, starts the device and waits (up to `timeout`) for the
    /// host's `started` report. Returns false when it did not start.
    @discardableResult
    public func start(hostApp: URL, timeout: TimeInterval = 900) async -> Bool {
        switch phase {
        case .running: return true
        case .starting, .uploading: return await withCheckedContinuation { startWaiters.append($0) }
        default: break
        }
        let t0 = Date()
        phase = .uploading
        onChange?()
        let r = remote, opts = sshOptions, platform = platform, dest = remote.settings.destination
        let upload: (Int32, String) = await Task.detached {
            let path = r.remotePreviewHostPath(platform: platform)
            let dir = (path as NSString).deletingLastPathComponent
            let m = r.runLocal(r.settings.ssh, opts + [dest, "mkdir -p \(RemoteSimulator.quote(dir))"])
            guard m.0 == 0 else { return m }
            return r.runLocal(r.settings.rsync, ["-az", "--delete", "-e", ([r.settings.ssh] + opts).joined(separator: " "),
                                                 hostApp.path + "/", "\(dest):\(path)/"])
        }.value
        guard upload.0 == 0 else { return fail("Could not copy the preview host to the simulator host: \(upload.1)") }
        phase = .starting("Starting the preview device")
        onChange?()
        // The host's reports first, so `started` is not missed.
        let rep = StreamingProcess(executable: r.settings.ssh, arguments: ssh(r.previewReportCommand))
        reports = rep
        try? rep.start(onLine: { [weak self] line in self?.report(line) }, onExit: { _ in })
        let proc = StreamingProcess(executable: r.settings.ssh, arguments: ssh(r.previewCommand(platform: platform)))
        process = proc
        do {
            try proc.start(onLine: { [weak self] line in self?.launcherLine(line) },
                           onExit: { [weak self] status in self?.ended(status) })
        } catch { return fail("Could not start ssh: \(error)") }
        link?.close()
        link = RemoteDisplayLink(remote: r, name: r.target?.name ?? RemoteSimulator.deviceName, os: r.runtimeVersion.map { "iOS \($0)" } ?? "")
        let ok = await withCheckedContinuation { c in
            startWaiters.append(c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishStart(false)
            }
        }
        if ok { startSeconds = Date().timeIntervalSince(t0) }
        return ok
    }

    private func fail(_ message: String) -> Bool {
        phase = .failed(message)
        finishStart(false)
        onChange?()
        return false
    }

    private func finishStart(_ ok: Bool) {
        let w = startWaiters
        startWaiters = []
        w.forEach { $0.resume(returning: ok) }
    }

    private func launcherLine(_ line: String) {
        if let pid = RemoteSimulator.remotePID(line) { remotePID = pid; return }
        onLine?(line)
        if case .starting = phase {
            if line.contains("restoring the device") { phase = .starting("Restoring the preview device"); onChange?() }
            else if line.contains("cold boot") { phase = .starting("Booting the preview device"); onChange?() }
            else if line.contains("home screen at") { phase = .starting("Launching the preview host"); onChange?() }
        }
        if line.contains("ylaunch: launched \(PreviewHost.bundleIdentifier)") { host.running = true }
    }

    private func report(_ line: String) {
        guard let r = PreviewHost.parseReport(line) else { return }
        switch r {
        case .started:
            host = PreviewHostState(running: true)
            phase = .running
            finishStart(true)
            onChange?()
        case .ready(let g, _):
            readyGeneration = max(readyGeneration, g)
            host.failed = false
            for (k, w) in waiters where k <= g { waiters[k] = nil; w.resume(returning: r) }
        case .error(let g, _):
            if g == 0 || line.contains("load") { host.failed = true }
            if let w = waiters[g] { waiters[g] = nil; w.resume(returning: r) }
        }
    }

    private func ended(_ status: Int32) {
        process = nil
        reports?.signal(SIGTERM)
        reports = nil
        host = PreviewHostState(running: false)
        let w = waiters
        waiters = [:]
        for (g, c) in w { c.resume(returning: .error(generation: g, message: "The preview device stopped")) }
        if case .failed = phase {} else { phase = status == 0 ? .stopped : .failed("The preview device ended with status \(status)") }
        finishStart(false)
        link?.close()
        link = nil
        onChange?()
    }

    /// Timings of one delivery, in seconds.
    public struct Delivery: Equatable, Sendable {
        public var generation: Int
        public var upload: Double
        /// From the upload's end to the host's `ready`.
        public var load: Double
        public var hostMilliseconds: Int
    }

    /// Sends a plan (with a new payload, or the loaded one) and waits for
    /// the host to show it.
    public func deliver(payload: URL?, regions: [PreviewRegion], timeout: TimeInterval = 60) async throws(PreviewFailure) -> Delivery {
        guard phase == .running else { throw .host("The preview device is not running") }
        generation += 1
        let g = generation
        let payloadName = payload.map { _ in "payload-\(g).dylib" }
        let guestPayload = payloadName.map { "\(PreviewHost.guestDirectory)/\($0)" } ?? lastPlan?.payload ?? ""
        let plan = PreviewPlan(generation: g, payload: guestPayload, regions: regions)
        let cmd = remote.previewDeliverCommand(payloadName: payloadName, plan: plan.json(), keep: PreviewUpdatePlanner.maximumLoads)
        let args = ssh(cmd), sshPath = remote.settings.ssh
        let t0 = Date()
        let status: Int32 = await Task.detached {
            MainThreadGuard.blockingCall("ssh deliver")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sshPath)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if let payload, let h = try? FileHandle(forReadingFrom: payload) { p.standardInput = h } else { p.standardInput = FileHandle.nullDevice }
            guard (try? p.run()) != nil else { return 127 }
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        let t1 = Date()
        guard status == 0 else { throw .host("Could not send the preview to the device (ssh status \(status))") }
        lastPlan = plan
        if payload != nil { host.loads += 1 }
        let r: PreviewHost.Report = await withCheckedContinuation { c in
            if readyGeneration >= g { c.resume(returning: .ready(generation: g, milliseconds: 0)); return }
            waiters[g] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let w = self?.waiters[g] { self?.waiters[g] = nil; w.resume(returning: .error(generation: g, message: "The preview host did not answer")) }
            }
        }
        switch r {
        case .ready(_, let ms): return Delivery(generation: g, upload: t1.timeIntervalSince(t0), load: Date().timeIntervalSince(t1), hostMilliseconds: ms)
        case .error(_, let m): throw .host(m)
        case .started: throw .host("The preview host restarted")
        }
    }

    /// Stops the device (the launcher saves it for the next start).
    public func stop() async {
        guard process != nil else { return }
        if let pid = remotePID {
            let r = remote, args = ssh("kill -INT \(pid)")
            _ = await Task.detached { r.runLocal(r.settings.ssh, args) }.value
        } else {
            process?.signal(SIGINT)
        }
    }

    /// Ycode quits: SIGINT to the launcher without waiting (it saves the device).
    func stopForQuit() {
        if let pid = remotePID { _ = remote.runLocal(remote.settings.ssh, ssh("kill -INT \(pid)")) } else { process?.signal(SIGINT) }
        reports?.signal(SIGTERM)
    }
}

/// The running preview devices, keyed by device directory; they run until
/// Ycode quits (then they are saved, as a run's device is at Stop).
@MainActor
public final class RemotePreviewSessions {
    public static let shared = RemotePreviewSessions()
    private var sessions: [String: RemotePreviewSession] = [:]
    private var quitObserver: NSObjectProtocol?

    public func session(for remote: RemoteSimulator, platform: PreviewPlatform) -> RemotePreviewSession {
        let key = remote.previewDevice.remoteDevicePath
        if let s = sessions[key] { return s }
        let s = RemotePreviewSession(remote: remote, platform: platform)
        sessions[key] = s
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemotePreviewSessions.shared.sessions.values.forEach { $0.stopForQuit() } }
            }
        }
        return s
    }

    public var all: [RemotePreviewSession] { Array(sessions.values) }
}
