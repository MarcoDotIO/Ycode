// `ycode sim headset …` and `ycode sim remote view <device> --xr --background
// | --desktop` (specs/ide/device-hub.md §I.12): the headset checklist and the
// switch from a terminal, with the viewer on this machine (Linux) or on a
// viewer host reached by ssh. The Linux shell's hook: until `ycode-ide`
// shows devices itself, its Run opens the desktop viewer and these commands
// move the running device to the headset and back.

import Foundation

public enum HeadsetCLI {
    public static let usage = """
        usage: ycode sim headset check [--viewer-host user@host] [--wifi] [--viewer PATH] [ROUTE]
               ycode sim headset view <device> [--viewer-host user@host] [--viewer PATH] [--wait S] ROUTE [-- viewer options]
               ycode sim headset desktop <device> [--viewer-host user@host]
               ycode sim headset state <device> [--viewer-host user@host]
          ROUTE: --link [--host N]                     the viewer reaches the device over Ycode's link
                 --ssh <user@simhost> --socket <path>  …or through an ssh forward to the device's display socket
          view starts ycode-xr-viewer detached and waits until the headset has the device (it takes the
          display over; the device keeps running); desktop ends it (the desktop viewer takes the display back).
          Nothing is installed and nothing runs sudo: check prints the commands for you to run.
        """

    /// Runs a command line; `out` gets the lines. Returns the exit status.
    public static func main(_ arguments: [String], runner override: (any HeadsetCommandRunner)? = nil,
                            out: @escaping @Sendable (String) -> Void = { print($0) }) async -> Int32 {
        var a = arguments
        var passthrough: [String] = []
        if let i = a.firstIndex(of: "--") { passthrough = Array(a[(i + 1)...]); a.removeSubrange(i...) }
        func take(_ name: String) -> String? {
            guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
            defer { a.removeSubrange(i...(i + 1)) }
            return a[i + 1]
        }
        func flag(_ name: String) -> Bool {
            guard let i = a.firstIndex(of: name) else { return false }
            a.remove(at: i)
            return true
        }
        guard !a.isEmpty else { out(usage); return 64 }
        let cmd = a.removeFirst()
        var settings = HeadsetSettings()
        if let h = take("--viewer-host") { settings.viewerHost = h }
        if let v = take("--viewer") { settings.viewerPath = v }
        if flag("--wifi") { settings.connection = .wifi }
        let wait = take("--wait").flatMap(Double.init) ?? HeadsetSwitch.enterTimeout
        let link = flag("--link"), linkHost = take("--host")
        let ssh = take("--ssh"), socket = take("--socket")
        #if os(Linux)
        let host = settings.host(hubIsLinux: true)
        #else
        let host = settings.host(hubIsLinux: false)
        #endif
        let runner: any HeadsetCommandRunner = override ?? {
            switch host {
            case .ssh(let d): return SSHHeadsetRunner(destination: d)
            default: return LocalHeadsetRunner()
            }
        }()
        func route(_ device: String?) -> HeadsetRoute? {
            if link, let device { return .link(device: device, host: linkHost) }
            if let ssh, let socket { return .sshSocket(destination: ssh, socket: socket) }
            return nil
        }
        switch cmd {
        case "check":
            let r = await HeadsetChecker(host: host, settings: settings, route: route(a.first), runner: runner).run()
            for step in HeadsetSetupStep.allCases {
                out("\(step.rawValue + 1). \(step.title)")
                for c in r.checks(in: step) {
                    out("   [\(c.state == .ok ? "ok" : c.state == .missing ? "missing" : "?")] \(c.title): \(c.reason)")
                    switch c.fix {
                    case .command(let s)? where c.state != .ok: out("        run yourself: \(s)")
                    case .instructions(let s)? where c.state != .ok: out("        \(s)")
                    case .installClient(let p)? where c.state != .ok:
                        out("        install: \(p.url)" + (p.sha256.map { " (sha256 \($0))" } ?? ""))
                        if let serial = r.serial { out("        run yourself: " + HeadsetActions.installCommand(serial: serial, package: p)) }
                    case .connect? where c.state != .ok:
                        if let serial = r.serial, let p = r.clientPackage { out("        run yourself: " + HeadsetActions.connectCommand(serial: serial, package: p)) }
                    default: break
                    }
                }
            }
            out("status: \(r.status.rawValue)" + (r.isConnected ? " (connected)" : ""))
            return r.isReady ? 0 : 1
        case "view", "desktop", "state":
            guard let device = a.first else { out(usage); return 64 }
            let r = route(device) ?? .link(device: device, host: linkHost)
            let plan = HeadsetViewerPlan(device: device, route: r, viewerPath: settings.viewerPath,
                                         options: passthrough.isEmpty ? settings.viewerOptions.split(separator: " ").map(String.init) : passthrough)
            let launcher = ScriptHeadsetViewerLauncher(runner: runner, plan: plan)
            switch cmd {
            case "state":
                let s = await launcher.state()
                out(s.phase.rawValue + (s.message.map { " (\($0))" } ?? ""))
                return 0
            case "desktop":
                let t0 = Date()
                await launcher.stop()
                out(String(format: "headset viewer stopped in %.2f s; the desktop viewer takes the display back when it connects", Date().timeIntervalSince(t0)))
                return 0
            default:
                let t0 = Date()
                do { try await launcher.start() } catch { out("ycode sim headset: \(error)"); return 1 }
                while Date().timeIntervalSince(t0) < wait {
                    let s = await launcher.state()
                    switch s.phase {
                    case .streaming:
                        out(String(format: "in headset after %.2f s", Date().timeIntervalSince(t0)))
                        return 0
                    case .stopped:
                        out("ycode sim headset: the viewer ended: \(s.message ?? "see viewer.log in \(plan.directory)")")
                        return 1
                    default:
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                out("ycode sim headset: the headset did not take over within \(Int(wait)) s; stopping the viewer")
                await launcher.stop()
                return 1
            }
        default:
            out(usage)
            return 64
        }
    }
}

extension HeadsetCLI {
    /// `remote [--host N] view <device> --xr --background [viewer options]` → `headset view <device> --link [--host N] -- options`;
    /// `remote [--host N] view <device> --desktop [--no-window]` → `headset desktop <device>`, then the desktop viewer
    /// (`remote [--host N] view <device>`) unless `--no-window`. nil: not a switch (the plain `view`).
    public static func remoteView(_ args: [String]) -> (headset: [String], viewer: [String]?)? {
        var a = args
        var host: [String] = []
        if let i = a.firstIndex(of: "--host"), i + 1 < a.count { host = ["--host", a[i + 1]]; a.removeSubrange(i...(i + 1)) }
        guard a.count >= 2, a[0] == "view" else { return nil }
        let device = a[1]
        var rest = Array(a.dropFirst(2))
        if let i = rest.firstIndex(of: "--desktop") {
            rest.remove(at: i)
            let noWindow = rest.contains("--no-window")
            return (["desktop", device], noWindow ? nil : host + ["view", device])
        }
        guard rest.contains("--xr"), let b = rest.firstIndex(of: "--background") else { return nil }
        rest.remove(at: b)
        rest.removeAll { $0 == "--xr" }
        return (["view", device, "--link"] + host + (rest.isEmpty ? [] : ["--"] + rest), nil)
    }
}
