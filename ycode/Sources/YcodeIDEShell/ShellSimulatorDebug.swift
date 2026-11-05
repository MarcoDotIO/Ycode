// Run under the debugger on a Ycode simulator host on this machine
// (specs/ide/debug.md, "The Linux IDE: apps on the simulator"). Run on a
// link destination (ShellRemoteRun) asks the host to start the app with the
// debug stub; once the host's log shows the app launched, the session
// attaches lldb-dap to the stub's socket (WorkspaceSession
// .attachToSimulatorStub) and the Linux IDE's debug UI works as for a
// package: breakpoints, the debug bar, the variables view, the console.
//
// The stub's socket is a path on the host, so only a host on this machine
// can be debugged this way; a host elsewhere runs the app without the
// debugger until the link carries the stub (#50).

import Foundation
import YcodeBuild
import YcodeIDECore
import YcodeSimLink
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ShellSimulatorDebug {
    /// Run on a simulator destination runs under the debugger unless
    /// `YCODE_IDE_SIM_DEBUGGER=0` (the Mac's `Ycode.remote.debugger` key).
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["YCODE_IDE_SIM_DEBUGGER"] != "0"
    }

    /// True when `address` names this computer: a loopback address,
    /// `localhost`, this machine's host name, or one of its interfaces'
    /// addresses.
    public static func isThisMachine(_ address: String, interfaceAddresses: Set<String>? = nil,
                                     hostName: String = ProcessInfo.processInfo.hostName) -> Bool {
        var a = address.lowercased()
        if a.hasPrefix("["), a.hasSuffix("]") { a = String(a.dropFirst().dropLast()) }
        if a == "localhost" || a.hasSuffix(".localhost") || a == "::1" || a.hasPrefix("127.") { return true }
        if !hostName.isEmpty, a == hostName.lowercased() || a.split(separator: ".").first.map(String.init) == hostName.lowercased() { return true }
        return (interfaceAddresses ?? localAddresses()).contains(a)
    }

    /// The addresses of this machine's network interfaces (getifaddrs).
    public static func localAddresses() -> Set<String> {
        var out: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(sa, len, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                // A scoped IPv6 address ("fe80::1%eth0") without its scope.
                let text = String(cString: name).split(separator: "%").first.map(String.init) ?? ""
                if !text.isEmpty { out.insert(text.lowercased()) }
            }
        }
        return out
    }

    /// Whether Run on `host` asks for the debugger: enabled, and the host is
    /// this machine (the stub's socket is a path there).
    public static func wantsDebugger(host: LinkHost, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment: environment) && isThisMachine(host.host)
    }

    /// The guest pid in a host log line "… ylaunch: launched <bundle id> pid N".
    public static func launchedPID(_ line: String, bundleID: String?) -> Int? {
        guard let r = line.range(of: "ylaunch: launched ") else { return nil }
        let rest = line[r.upperBound...].split(separator: " ")
        guard rest.count >= 3, rest[1] == "pid", let pid = Int(rest[2]) else { return nil }
        if let bundleID, rest[0] != bundleID { return nil }
        return pid
    }

    /// Waits until the host's log for `device` shows the app launched, asking
    /// with the link's `log` request every `interval` seconds. False when the
    /// device stopped first, `cancelled` turned true, or `timeout` passed.
    public static func waitForLaunch(host: LinkHost, device: String, bundleID: String?, timeout: Double = 900, interval: Double = 1,
                                     cancelled: @escaping @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await cancelled() { return false }
            let (lines, state): ([String], String?) = await Task.detached { () -> ([String], String?) in
                guard let c = try? LinkClient().control(host) else { return ([], nil) }
                defer { c.close() }
                let log = (try? c.request(LinkRequest(op: "log", device: device, lines: 400)))?.log ?? []
                let state = (try? c.request(LinkRequest(op: "devices")))?.devices?.first { $0.name == device }?.state
                return (log, state)
            }.value
            if lines.contains(where: { launchedPID($0, bundleID: bundleID) != nil }) { return true }
            // The run ended before the app launched (a failed boot, a Stop elsewhere).
            if state == "shutdown", Date().timeIntervalSince(start) > 5 { return false }
            try? await Task.sleep(for: .seconds(interval))
        }
        return false
    }

    /// Product ▸ Run on a link destination: builds, uploads, launches and
    /// opens the device window (ShellRemoteRun.start); with the debugger
    /// enabled and the host on this computer, waits for the launch and
    /// attaches. `started` gets the device window's process; `isCurrent`
    /// turns false when Stop (or another Run) replaced it. `phase` and
    /// `cancel` are ShellRemoteRun's (the activity, Stop before the window).
    @MainActor
    public static func run(session: WorkspaceSession, scheme: String, destination: Destination, packageRoot: URL,
                           phase: @escaping @Sendable (RemoteRunPhase) -> Void = { _ in }, cancel: RemoteRunCancel = RemoteRunCancel(),
                           started: (Process) -> Void, isCurrent: @escaping @MainActor (Process) -> Bool) async throws {
        let out: @Sendable (String) -> Void = { text in Task { @MainActor in session.appendConsole(text, kind: .debugger) } }
        let s = try await ShellRemoteRun.start(project: session.model.url.path, scheme: scheme, destination: destination, packageRoot: packageRoot,
                                               debug: isEnabled(), output: out, phase: phase, cancel: cancel)
        started(s.viewer)
        guard let socket = s.debugSocket else {
            if isEnabled(), !isThisMachine(s.host.host) {
                out("The debugger attaches only to a simulator host on this computer; \(s.host.name) runs \(s.app.deletingPathExtension().lastPathComponent) without it.\n")
            }
            return
        }
        let viewer = s.viewer, host = s.host, device = s.device, bundleID = s.bundleID
        await session.attachToSimulatorStub(socketPath: socket, app: s.app, device: "\(device) (\(host.name))", waitForLaunch: {
            await waitForLaunch(host: host, device: device, bundleID: bundleID) { await MainActor.run { !isCurrent(viewer) } }
        }, cancelled: { !isCurrent(viewer) })
    }
}
