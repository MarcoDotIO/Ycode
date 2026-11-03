// Switching a running visionOS device between the desktop canvas and the
// headset (specs/ide/device-hub.md §I.12). The device keeps running: the
// display server serves one viewer at a time and a new connection takes
// over (display-stream.md §1), so switching only starts or stops the
// headset viewer on the viewer host and lets the desktop's stream wait or
// come back. Portable: the macOS hub, the Linux shell and the CLI drive the
// same machine.

import Foundation

/// What the headset viewer reports in its state file (`ycode-xr-viewer
/// --state-file`, xr-viewer.md §7.2).
public enum HeadsetViewerPhase: String, Sendable, Equatable, Codable {
    /// Started; waiting for the OpenXR runtime (WiVRn waits for its headset).
    case waitingForHeadset
    /// The headset session runs and the stream is connected: it owns the device's display.
    case streaming
    /// Ended (by a stop, the wearer, a takeover or an error).
    case stopped
    /// Not running and no state file (never started, or removed).
    case absent
}

/// The viewer's state file: one JSON object, rewritten whole.
public struct HeadsetViewerState: Sendable, Equatable, Codable {
    public var phase: HeadsetViewerPhase
    public var pid: Int32?
    public var message: String?
    public init(phase: HeadsetViewerPhase, pid: Int32? = nil, message: String? = nil) {
        self.phase = phase
        self.pid = pid
        self.message = message
    }
}

/// Starts and stops the headset viewer on the viewer host.
public protocol HeadsetViewerLauncher: Sendable {
    /// Starts it for the device; returns once it was started (not once it streams).
    func start() async throws
    func state() async -> HeadsetViewerState
    /// Asks it to end (SIGTERM; then SIGKILL after a grace time) and ends the forward.
    func stop() async
}

/// The desktop's own stream of the device (the hub's canvas).
@MainActor
public protocol HeadsetDesktopStream: AnyObject {
    /// Keep showing until another viewer takes over, then do not reconnect.
    func holdForHeadset()
    /// Reconnect now (taking the display back) and restore the desktop's camera.
    func returnFromHeadset()
}

/// The switch's states.
public enum HeadsetSwitchState: Sendable, Equatable {
    case desktop
    /// The viewer was started; the desktop shows its picture until the headset takes over.
    case enteringHeadset
    case inHeadset
    case returningToDesktop
}

/// What the machine asks its owner to do.
public enum HeadsetSwitchAction: Sendable, Equatable {
    case holdDesktopStream, startViewer, stopViewer, resumeDesktopStream, notice(String)
}

public enum HeadsetSwitchEvent: Sendable, Equatable {
    case viewInHeadset, backToDesktop
    case viewerStarted, viewerFailed(String)
    case viewerPhase(HeadsetViewerPhase)
    /// Too long without the headset taking over.
    case timeout
    case viewerStoppedConfirmed
    case deviceStopped
}

/// The state machine (pure; the controller carries out its actions).
public struct HeadsetSwitch: Sendable, Equatable {
    public private(set) var state = HeadsetSwitchState.desktop
    public init() {}

    /// Seconds to wait for the headset (the runtime waits for the headset's app).
    public static let enterTimeout: TimeInterval = 45

    public var isInHeadset: Bool { state == .inHeadset || state == .enteringHeadset }

    public mutating func handle(_ e: HeadsetSwitchEvent) -> [HeadsetSwitchAction] {
        switch (state, e) {
        case (.desktop, .viewInHeadset):
            state = .enteringHeadset
            return [.holdDesktopStream, .startViewer]
        case (.enteringHeadset, .viewerFailed(let why)):
            state = .desktop
            return [.resumeDesktopStream, .notice("The headset view could not start: \(why)")]
        case (.enteringHeadset, .viewerPhase(.streaming)):
            state = .inHeadset
            return []
        case (.enteringHeadset, .viewerPhase(.stopped)), (.enteringHeadset, .viewerPhase(.absent)):
            state = .desktop
            return [.resumeDesktopStream, .notice("The headset view ended before it started.")]
        case (.enteringHeadset, .timeout):
            state = .returningToDesktop
            return [.stopViewer, .resumeDesktopStream, .notice("The headset did not join in time. Put it on, check that WiVRn's app is connected, and try again.")]
        case (.enteringHeadset, .backToDesktop), (.inHeadset, .backToDesktop):
            // The desktop reconnects at once (it takes the display over); the viewer is stopped alongside.
            state = .returningToDesktop
            return [.resumeDesktopStream, .stopViewer]
        case (.inHeadset, .viewerPhase(.stopped)), (.inHeadset, .viewerPhase(.absent)):
            // The wearer quit, the runtime ended, or another viewer took over.
            state = .desktop
            return [.resumeDesktopStream, .notice("The headset view ended; back on the desktop.")]
        case (.returningToDesktop, .viewerStoppedConfirmed):
            state = .desktop
            return []
        case (_, .deviceStopped):
            let was = state
            state = .desktop
            return was == .desktop ? [] : [.stopViewer]
        default:
            return []
        }
    }
}

/// Runs the machine against a launcher and the desktop stream; polls the
/// viewer's state while it is in or entering the headset.
@MainActor
public final class HeadsetSwitchController {
    public private(set) var machine = HeadsetSwitch()
    public let launcher: any HeadsetViewerLauncher
    public weak var desktop: (any HeadsetDesktopStream)?
    /// A notice for the user (a banner).
    public var onNotice: (String) -> Void = { _ in }
    public var onChange: (HeadsetSwitchState) -> Void = { _ in }
    /// How often the viewer's state is read while entering; at most once a second in the headset.
    public var pollInterval: TimeInterval = 0.2
    public var enterTimeout = HeadsetSwitch.enterTimeout
    private var poll: Task<Void, Never>?
    private var enteredAt = Date()
    /// Timestamps of the last switch, for the spec's timings.
    public private(set) var lastSwitch: (requested: Date, done: Date?)?

    public init(launcher: any HeadsetViewerLauncher, desktop: (any HeadsetDesktopStream)?) {
        self.launcher = launcher
        self.desktop = desktop
    }

    public var state: HeadsetSwitchState { machine.state }

    public func viewInHeadset() async { lastSwitch = (Date(), nil); await send(.viewInHeadset) }
    public func backToDesktop() async { lastSwitch = (Date(), nil); await send(.backToDesktop) }
    public func deviceStopped() async { await send(.deviceStopped) }

    func send(_ e: HeadsetSwitchEvent) async {
        let before = machine.state
        let actions = machine.handle(e)
        if machine.state != before {
            if machine.state == .enteringHeadset { enteredAt = Date() }
            if machine.state == .inHeadset || machine.state == .desktop, let l = lastSwitch, l.done == nil { lastSwitch = (l.requested, Date()) }
            onChange(machine.state)
        }
        for a in actions { await perform(a) }
        updatePolling()
    }

    private func perform(_ a: HeadsetSwitchAction) async {
        switch a {
        case .holdDesktopStream: desktop?.holdForHeadset()
        case .resumeDesktopStream: desktop?.returnFromHeadset()
        case .notice(let text): onNotice(text)
        case .startViewer:
            do {
                try await launcher.start()
                await send(.viewerStarted)
            } catch {
                await send(.viewerFailed("\(error)"))
            }
        case .stopViewer:
            await launcher.stop()
            await send(.viewerStoppedConfirmed)
        }
    }

    private func updatePolling() {
        let wants = machine.state == .enteringHeadset || machine.state == .inHeadset
        if wants, poll == nil {
            poll = Task { [weak self] in
                while let self, !Task.isCancelled, self.machine.state == .enteringHeadset || self.machine.state == .inHeadset {
                    let wait = self.machine.state == .enteringHeadset ? self.pollInterval : max(self.pollInterval, 1)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                    await self.tick()
                }
                self?.poll = nil
            }
        } else if !wants {
            poll?.cancel()
            poll = nil
        }
    }

    /// One poll (tests call it directly).
    public func tick() async {
        guard machine.state == .enteringHeadset || machine.state == .inHeadset else { return }
        let s = await launcher.state()
        guard machine.state == .enteringHeadset || machine.state == .inHeadset else { return }
        if machine.state == .enteringHeadset, s.phase == .waitingForHeadset || s.phase == .absent && Date().timeIntervalSince(enteredAt) < 3 {
            if Date().timeIntervalSince(enteredAt) > enterTimeout { await send(.timeout) }
            return
        }
        await send(.viewerPhase(s.phase))
    }
}

/// The headset viewer on the viewer host, started detached through a
/// `HeadsetCommandRunner` (this machine or ssh). Its files live in one
/// directory there: `viewer.pid`, `forward.pid`, `state.json`, `viewer.log`,
/// and the forwarded display socket.
public struct ScriptHeadsetViewerLauncher: HeadsetViewerLauncher {
    public var runner: any HeadsetCommandRunner
    public var plan: HeadsetViewerPlan

    public init(runner: any HeadsetCommandRunner, plan: HeadsetViewerPlan) {
        self.runner = runner
        self.plan = plan
    }

    public struct Failure: Error, CustomStringConvertible { public let description: String }

    public func start() async throws {
        let r = await runner.run(plan.startCommand)
        guard r.ok else { throw Failure(description: r.output.trimmed.isEmpty ? "the viewer host refused (status \(r.status))" : r.output.trimmed) }
    }

    public func state() async -> HeadsetViewerState {
        let r = await runner.run(plan.stateCommand)
        return HeadsetViewerPlan.parseState(r.output)
    }

    public func stop() async { _ = await runner.run(plan.stopCommand) }
}

/// The commands of one headset viewer for one device.
public struct HeadsetViewerPlan: Sendable, Equatable {
    public var device: String
    public var route: HeadsetRoute
    public var viewerPath: String
    public var options: [String]
    /// WiVRn's manifest for the viewer's own process (no system change).
    public var runtimeManifest: String?

    public init(device: String, route: HeadsetRoute, viewerPath: String = "ycode-xr-viewer", options: [String] = [],
                runtimeManifest: String? = HeadsetChecker.wivrnManifest) {
        self.device = device
        self.route = route
        self.viewerPath = viewerPath
        self.options = options
        self.runtimeManifest = runtimeManifest
    }

    /// The directory on the viewer host (one per device).
    public var directory: String {
        let safe = device.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "_" }
        return "${XDG_RUNTIME_DIR:-/tmp}/ycode-headset/\(String(safe))"
    }

    /// The viewer's arguments (after its path).
    public var viewerArguments: [String] {
        var a: [String]
        switch route {
        case .link(let device, let host): a = ["--link", device] + (host.map { ["--host", $0] } ?? [])
        case .sshSocket: a = ["--connect", "unix:$D/display.sock"]
        }
        return a + ["--state-file", "$D/state.json"] + options
    }

    /// Words of the viewer's command line; `$D` stays a shell variable.
    private var viewerWords: String {
        viewerArguments.map { $0.contains("$D") ? "\"\($0)\"" : $0.shellQuoted }.joined(separator: " ")
    }

    /// Starts the viewer detached (its own session; output to viewer.log) and
    /// returns. A viewer already running for the device is left as it is.
    public var startCommand: String {
        var s = "D=\(directory); mkdir -p \"$D\" && chmod 700 \"$D\" || exit 1; S=$(command -v setsid); "
        s += "if [ -f \"$D/viewer.pid\" ] && kill -0 \"$(cat \"$D/viewer.pid\")\" 2>/dev/null; then echo 'already running'; exit 0; fi; "
        s += "rm -f \"$D/state.json\" \"$D/display.sock\"; "
        if case .sshSocket(let dest, let socket) = route {
            s += "$S nohup ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -L \"$D/display.sock:\(socket)\" \(dest.shellQuoted) "
            s += "> \"$D/forward.log\" 2>&1 < /dev/null & echo $! > \"$D/forward.pid\"; "
            s += "i=0; while [ ! -S \"$D/display.sock\" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; "
            s += "[ -S \"$D/display.sock\" ] || { echo 'the forward to the simulator host did not start'; cat \"$D/forward.log\"; exit 1; }; "
        }
        let env = runtimeManifest.map { "if [ -f \($0.shellQuoted) ]; then export XR_RUNTIME_JSON=\($0.shellQuoted); fi; " } ?? ""
        s += env
        s += "$S nohup \(viewerPath.shellQuoted) \(viewerWords) > \"$D/viewer.log\" 2>&1 < /dev/null & echo $! > \"$D/viewer.pid\"; exit 0"
        return s
    }

    /// Prints the state file, or "absent" when the viewer is not running.
    public var stateCommand: String {
        "D=\(directory); if [ -f \"$D/viewer.pid\" ] && kill -0 \"$(cat \"$D/viewer.pid\")\" 2>/dev/null; then cat \"$D/state.json\" 2>/dev/null || echo '{\"phase\":\"waitingForHeadset\"}'; "
            + "elif [ -f \"$D/state.json\" ]; then cat \"$D/state.json\"; else echo '{\"phase\":\"absent\"}'; fi"
    }

    /// Ends the viewer (SIGTERM: it leaves its session cleanly; SIGKILL after
    /// 5 s) and the forward. Only the recorded PIDs, and only when they are
    /// still the programs that were started.
    public var stopCommand: String {
        let name = String((viewerPath as NSString).lastPathComponent.prefix(15))
        var s = "D=\(directory); p=$(cat \"$D/viewer.pid\" 2>/dev/null); "
        s += "if [ -n \"$p\" ] && [ \"$(cat /proc/$p/comm 2>/dev/null)\" = \(name.shellQuoted) ]; then kill -TERM \"$p\"; "
        s += "i=0; while kill -0 \"$p\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; kill -0 \"$p\" 2>/dev/null && kill -KILL \"$p\"; fi; "
        s += "f=$(cat \"$D/forward.pid\" 2>/dev/null); if [ -n \"$f\" ] && [ \"$(cat /proc/$f/comm 2>/dev/null)\" = ssh ]; then kill -TERM \"$f\"; fi; "
        s += "rm -f \"$D/viewer.pid\" \"$D/forward.pid\" \"$D/display.sock\"; exit 0"
        return s
    }

    public static func parseState(_ text: String) -> HeadsetViewerState {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }),
              let s = try? JSONDecoder().decode(HeadsetViewerState.self, from: Data(line.utf8)) else { return HeadsetViewerState(phase: .absent) }
        return s
    }
}
