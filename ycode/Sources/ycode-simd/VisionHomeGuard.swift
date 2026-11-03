// The visionOS shell watch and home guard (visionos.md §10.21, §10.26). At
// the end of a first boot two guest processes raced: assistantd, once its
// start-up was done, asked the shell (SurfBoard) to open Siri's orb pre-warm
// scene, and the shell, once the device was unlocked and the cover sheet was
// gone, brings up the home view (RealityLauncher) unless a foreground scene
// "will be running". A request that reached the shell after data migration
// was allowed after the unlock, Siri's pre-warm scene was in the foreground
// at the resume, and nothing brought the home view up later. On the
// reference the pre-warm comes 90 s or more after the home view (§9 Q27).
//
// The fix (§10.26.1): assistantd's start hold lasts until the shell is
// ready (`DarwinSystem.shellReadyHoldLabels`, `markShellReady`). This
// thread marks the shell ready when RealityLauncher runs or at the room's
// first lit frame, whichever comes first, in every visionOS device run.
//
// In a run without an app launch of its own it then stays as the home
// guard, a fallback that logs whenever it acts: when the shell has not
// launched RealityLauncher `delay` seconds after the first lit frame, it
// presses Home once through the HID service (what a user of the simulator
// does), and again `delay` seconds later if there is still no
// RealityLauncher, at most `maxPresses` times. It never presses while
// RealityLauncher runs (a press then would close the home view).
// `YCODE_VISIONOS_HOME_GUARD=0` turns the guard off,
// `YCODE_VISIONOS_HOME_GUARD_S` sets `delay`, `YCODE_VISIONOS_SHELL_HOLD`
// the held jobs.

import Foundation

/// The guard's decisions, apart from frames, processes and HID (tested).
struct VisionHomeGuardPolicy: Equatable {
    var delay: Double = 60
    var maxPresses = 2

    enum Action: Equatable {
        /// Check again later.
        case wait
        /// Press Home now.
        case press
        /// Done: the home view was launched, or every press was used.
        case stop
    }

    private(set) var presses = 0
    private var lastPress: Double?

    init(delay: Double = 60, maxPresses: Int = 2) {
        self.delay = delay
        self.maxPresses = maxPresses
    }

    /// `secondsSinceRoom`: seconds since the first lit frame (nil: none yet);
    /// `launcherRunning`: a RealityLauncher process exists.
    mutating func step(secondsSinceRoom: Double?, launcherRunning: Bool) -> Action {
        if launcherRunning { return .stop }
        guard let t = secondsSinceRoom else { return .wait }
        if presses >= maxPresses { return .stop }
        let due = (lastPress ?? 0) + delay
        guard t >= due else { return .wait }
        presses += 1
        lastPress = t
        return .press
    }

    /// From the environment: nil when the guard is off.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> VisionHomeGuardPolicy? {
        if env["YCODE_VISIONOS_HOME_GUARD"] == "0" { return nil }
        var p = VisionHomeGuardPolicy()
        if let s = env["YCODE_VISIONOS_HOME_GUARD_S"].flatMap(Double.init), s > 0 { p.delay = s }
        return p
    }

    /// The jobs whose start hold lasts until the shell is ready (the room's
    /// first lit frame or the home view launched; visionos.md §10.26.1):
    /// Siri's assistant daemon, whose orb pre-warm otherwise races the
    /// shell's home resume. `YCODE_VISIONOS_SHELL_HOLD`: a comma-separated
    /// list instead, `0` none.
    static func shellReadyHoldLabels(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        guard let v = env["YCODE_VISIONOS_SHELL_HOLD"] else { return ["com.apple.assistantd"] }
        if v == "0" || v.isEmpty { return [] }
        return Set(v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Whether `path` is the home view's executable.
    static func isLauncher(_ path: String) -> Bool { path.hasSuffix("/RealityLauncher.app/RealityLauncher") }
}

#if os(Linux) && arch(arm64)
import YcodeDarwinKernel
import YcodeHostServices
import YcodeHypervisor

enum VisionHomeGuard {
    /// Starts the watcher thread of a visionOS device run: it marks the
    /// shell ready at the room's first lit frame or when the home view runs
    /// (releasing the shell-ready holds), and with a `policy` (a run without
    /// an app launch of its own) it is also the home guard, a fallback that
    /// logs every press.
    static func start(policy: VisionHomeGuardPolicy?, statePath: String, surfaces: IOSurfaceHostService,
                      hid: HIDHostService?, system: DarwinSystem) {
        let thread = Thread {
            let guarding = policy != nil && hid != nil
            var policy = policy ?? VisionHomeGuardPolicy()
            let reader = FrameRecordReader(path: statePath)
            var last = reader.read()
            var lit = 0, firstLit: UInt64 = 0, lastCheck: UInt64 = 0, lastLauncherCheck: UInt64 = 0
            let deadline = monotonicNanoseconds() &+ 3_600_000_000_000
            while monotonicNanoseconds() < deadline {
                if firstLit == 0 {
                    usleep(20_000)
                    let now0 = monotonicNanoseconds()
                    if now0 &- lastLauncherCheck >= 1_000_000_000 {
                        lastLauncherCheck = now0
                        if system.allProcesses.contains(where: { !$0.isZombie && VisionHomeGuardPolicy.isLauncher($0.executablePath) }) {
                            system.markShellReady(reason: "the home view runs")
                        }
                    }
                    guard let r = reader.read(), r != last else { continue }
                    last = r
                    let now = monotonicNanoseconds()
                    guard now &- lastCheck >= 100_000_000 else { continue }
                    lastCheck = now
                    guard let c = FrameProfile.checkSurface(r.surface, surfaces: surfaces) else { continue }
                    lit = c.dark < 900 ? lit + 1 : 0
                    if lit >= 2 {
                        firstLit = now
                        system.markShellReady(reason: "the room's first lit frame")
                        if !guarding { return }
                    }
                    continue
                }
                usleep(500_000)
                let since = Double(monotonicNanoseconds() &- firstLit) / 1e9
                let running = system.allProcesses.contains { !$0.isZombie && VisionHomeGuardPolicy.isLauncher($0.executablePath) }
                switch policy.step(secondsSinceRoom: since, launcherRunning: running) {
                case .wait:
                    continue
                case .stop:
                    if !running {
                        stderrLine("ycode-simd: visionOS home guard: RealityLauncher still not launched after \(policy.presses) Home presses")
                    } else if policy.presses > 0 {
                        stderrLine("ycode-simd: visionOS home guard: RealityLauncher launched after \(policy.presses) Home press(es)")
                    }
                    return
                case .press:
                    stderrLine("ycode-simd: visionOS home guard: the shell has not launched the home view "
                        + String(format: "%.0f", since) + " s after the room's first frame; pressing Home "
                        + "(press \(policy.presses) of \(policy.maxPresses); visionos.md §10.21)")
                    _ = hid?.send(.button(usagePage: 0x0C, usage: 0x40, down: true))
                    usleep(100_000)
                    _ = hid?.send(.button(usagePage: 0x0C, usage: 0x40, down: false))
                }
            }
        }
        thread.name = "ycode visionOS shell watch"
        thread.start()
    }
}
#endif
