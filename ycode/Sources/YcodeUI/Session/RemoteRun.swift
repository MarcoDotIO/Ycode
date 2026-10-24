import Foundation
import YcodeBuild
import YcodeSubprocess

/// Where the Ycode iOS simulator runs on an arm64 Linux host. Kept in the
/// user's defaults only (Settings ▸ Simulators). See `specs/ide/run.md`
/// §Remote Ycode simulator.
public struct RemoteSimulatorSettings: Equatable, Sendable {
    /// `user@host` (an SSH destination; keys only — BatchMode, no passwords).
    public var destination: String
    /// The remote data directory (apps and devices live under it).
    public var dataDirectory: String
    /// The iOS simulator runtime root on the remote.
    public var runtimeRoot: String
    /// The remote `ycode-simd` executable.
    public var simdPath: String
    /// The device directory name under `<data>/devices`.
    public var deviceName: String
    /// Extra ycode-simd options (host-side: --shim, --host-libs, --timeout-ms, …),
    /// split into words like a shell would (quotes group) and passed after
    /// the generated options, each single-quoted.
    public var additionalArguments: String = ""
    /// Lean boot (on by default): ycode-simd skips background services
    /// (`YCODE_LEAN_BOOT=daemons`); `keepServices` lists launchd labels to
    /// keep (comma-separated). See `specs/ide/run.md`.
    public var leanBoot = true
    public var keepServices: String = ""
    public static let leanBootHelp = "Faster boot for development: skips background services such as Siri, Spotlight, suggestions and photo analysis. Turn off to boot every service, as the reference simulator does."
    /// Warm boot (on by default): the host-side launcher restores the
    /// device from a snapshot of its booted state when one is valid, and
    /// otherwise boots cold and saves one (`YCODE_WARM_BOOT=1`). Off: every
    /// run boots cold (`YCODE_WARM_BOOT=0`). See `specs/ide/run.md` §Warm boot.
    public var warmBoot = true
    public static let warmBootHelp = "Keeps the device's state between runs: when a run stops, the device is saved, and the next run continues from it in seconds instead of booting; apps and their data stay until the device is erased. Saves are replaced when the simulator or the runtime changes. Turn off to boot from scratch every time."
    /// Local programs (tests point these at stand-ins).
    public var ssh: String
    public var rsync: String

    public init(destination: String = "", dataDirectory: String = "", runtimeRoot: String = "", simdPath: String = "",
                deviceName: String = "ycode-device", ssh: String = "/usr/bin/ssh", rsync: String = "/usr/bin/rsync") {
        self.destination = destination
        self.dataDirectory = dataDirectory
        self.runtimeRoot = runtimeRoot
        self.simdPath = simdPath
        self.deviceName = deviceName
        self.ssh = ssh
        self.rsync = rsync
    }

    public var isConfigured: Bool { !destination.isEmpty && !dataDirectory.isEmpty && !runtimeRoot.isEmpty && !simdPath.isEmpty }

    /// The runtime's version, for the destination row ("<device name>
    /// <runtime version>", `reference-ui-5.md` §11.5): the version read
    /// from the host for this runtime root (`saveRuntimeVersion`), else a
    /// version in the runtime root's path ("…/iOS 27.1/…"), else nil.
    public var runtimeVersion: String?

    /// A dotted version after "iOS" in a path ("/rt/iOS_27.1.simruntime" → "27.1").
    public static func version(inPath p: String) -> String? {
        guard let r = p.range(of: #"iOS[ _-]?([0-9]+(\.[0-9]+)+)"#, options: .regularExpression) else { return nil }
        let m = p[r].drop { !$0.isNumber }
        return String(m)
    }

    /// Remembers the version read from the host for a runtime root.
    public static func saveRuntimeVersion(_ version: String, root: String, _ d: UserDefaults) {
        d.set(version, forKey: "Ycode.remote.runtimeVersion")
        d.set(root, forKey: "Ycode.remote.runtimeVersionRoot")
    }

    /// Whether the remembered version belongs to this runtime root.
    public static func hasRuntimeVersion(for root: String, _ d: UserDefaults) -> Bool {
        d.string(forKey: "Ycode.remote.runtimeVersionRoot") == root && d.string(forKey: "Ycode.remote.runtimeVersion") != nil
    }

    static let keys = ["destination", "dataDirectory", "runtimeRoot", "simdPath", "deviceName"]

    public static func load(_ d: UserDefaults) -> RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings()
        s.destination = d.string(forKey: "Ycode.remote.destination") ?? ""
        s.dataDirectory = d.string(forKey: "Ycode.remote.dataDirectory") ?? ""
        s.runtimeRoot = d.string(forKey: "Ycode.remote.runtimeRoot") ?? ""
        s.simdPath = d.string(forKey: "Ycode.remote.simdPath") ?? ""
        s.deviceName = d.string(forKey: "Ycode.remote.deviceName") ?? "ycode-device"
        s.additionalArguments = d.string(forKey: "Ycode.remote.additionalArguments") ?? ""
        s.leanBoot = d.object(forKey: "Ycode.remote.leanBoot") as? Bool ?? true
        s.keepServices = d.string(forKey: "Ycode.remote.keepServices") ?? ""
        s.warmBoot = d.object(forKey: "Ycode.remote.warmBoot") as? Bool ?? true
        s.runtimeVersion = hasRuntimeVersion(for: s.runtimeRoot, d) ? d.string(forKey: "Ycode.remote.runtimeVersion") : version(inPath: s.runtimeRoot)
        return s
    }

    public func save(_ d: UserDefaults) {
        d.set(destination, forKey: "Ycode.remote.destination")
        d.set(dataDirectory, forKey: "Ycode.remote.dataDirectory")
        d.set(runtimeRoot, forKey: "Ycode.remote.runtimeRoot")
        d.set(simdPath, forKey: "Ycode.remote.simdPath")
        d.set(deviceName, forKey: "Ycode.remote.deviceName")
        d.set(additionalArguments, forKey: "Ycode.remote.additionalArguments")
        d.set(leanBoot, forKey: "Ycode.remote.leanBoot")
        d.set(keepServices, forKey: "Ycode.remote.keepServices")
        d.set(warmBoot, forKey: "Ycode.remote.warmBoot")
    }
}

/// Command construction and helper calls for the remote simulator.
public struct RemoteSimulator: Sendable {
    public var settings: RemoteSimulatorSettings
    public init(settings: RemoteSimulatorSettings) { self.settings = settings }

    /// The destination's identifier (its menu key and remembered choice).
    public static let identifier = "ycode-remote-simulator"
    /// The device's name in the destination menu and the Devices window.
    public static let deviceName = "Ycode Simulator"
    /// The destination shown in the scheme pop-up, without its runtime
    /// version. It is listed with the simulators (`reference-ui-5.md`
    /// §11.5); it builds for the generic iOS Simulator destination, so its
    /// kind stays `.generic` (it is not a `simctl` device). Compare with
    /// `Destination.isYcodeRemoteSimulator`: the row carries the version.
    public static let destination = Destination(name: deviceName, specifier: "generic/platform=iOS Simulator",
                                                platform: "iOS", kind: .generic, identifier: identifier)

    /// The destination row: "<device name> <runtime version>" (§11.5).
    public static func destination(runtimeVersion: String?) -> Destination {
        var d = destination
        d.osVersion = runtimeVersion
        return d
    }

    /// This simulator's destination row.
    public var destination: Destination { Self.destination(runtimeVersion: settings.runtimeVersion) }

    /// How long Stop waits for the launcher to save the device and end
    /// before it closes the connection itself (the launcher kills
    /// ycode-simd 120 s after a stop that has not finished).
    public var stopGrace: TimeInterval = 150

    /// POSIX shell single quoting.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public func remoteAppPath(_ app: URL) -> String { "\(settings.dataDirectory)/apps/\(app.lastPathComponent)" }
    public var remoteDevicePath: String { "\(settings.dataDirectory)/devices/\(settings.deviceName)" }

    /// ssh options: keys only, never prompt.
    var sshOptions: [String] { ["-o", "BatchMode=yes"] }

    public func sshArguments(_ command: String) -> [String] { sshOptions + [settings.destination, command] }

    public func mkdirCommand(_ app: URL) -> String { "mkdir -p \(Self.quote("\(settings.dataDirectory)/apps"))" }

    public func rsyncArguments(_ app: URL) -> [String] {
        ["-az", "--delete", "-e", ([settings.ssh] + sshOptions).joined(separator: " "),
         app.path + "/", "\(settings.destination):\(remoteAppPath(app))/"]
    }

    /// The remote command: prints the shell's pid, then becomes ycode-simd
    /// (so a signal to that pid reaches it).
    public func runCommand(app: URL, bundleID: String) -> String {
        let q = Self.quote
        return "echo YCODE-REMOTE-PID $$; exec \(environmentPrefix)\(q(settings.simdPath)) --device \(q(remoteDevicePath)) --runtime-root \(q(settings.runtimeRoot))"
            + " --install-app \(q(remoteAppPath(app))) --launch \(q(bundleID))"
            + Self.words(settings.additionalArguments).map { " " + q($0) }.joined()
    }

    /// `env YCODE_WARM_BOOT=1|0 [YCODE_LEAN_BOOT=daemons
    /// [YCODE_LEAN_BOOT_KEEP='<labels>']] `: warm boot on or off; the lean
    /// boot variables only when Lean boot is on.
    public var environmentPrefix: String {
        "env YCODE_WARM_BOOT=\(settings.warmBoot ? 1 : 0) " + leanBootVariables
    }

    /// `YCODE_LEAN_BOOT=daemons [YCODE_LEAN_BOOT_KEEP='<labels>'] ` when
    /// Lean boot is on; empty when off.
    public var leanBootVariables: String {
        guard settings.leanBoot else { return "" }
        let labels = settings.keepServices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return "YCODE_LEAN_BOOT=daemons " + (labels.isEmpty ? "" : "YCODE_LEAN_BOOT_KEEP=\(Self.quote(labels.joined(separator: ","))) ")
    }

    /// Splits text into words: whitespace separates; '…' and "…" group;
    /// a backslash escapes the next character (outside single quotes).
    public static func words(_ text: String) -> [String] {
        var out: [String] = [], cur = "", inWord = false
        var quote: Character?
        var escape = false
        for c in text {
            if escape { cur.append(c); escape = false; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" { escape = true } else { cur.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; inWord = true }
            else if c == "\\" { escape = true }
            else if c.isWhitespace { if inWord { out.append(cur); cur = ""; inWord = false } }
            else { cur.append(c); inWord = true }
        }
        if inWord { out.append(cur) }
        return out
    }

    /// The run phase a ycode-simd output line shows, if any:
    /// launched → running; an open retry ("no completion within") →
    /// still launching (not an error).
    public enum Phase: Equatable, Sendable { case booting, launching(retries: Int), running }
    public static func phase(after line: String, current: Phase) -> Phase {
        let l = line.lowercased()
        if l.hasPrefix("launched ") || l.contains(" launched ") && l.contains(" pid ") { return .running }
        if current == .running { return .running }
        if l.contains("no completion within") {
            if case .launching(let n) = current { return .launching(retries: n + 1) }
            return .launching(retries: 1)
        }
        if l.contains("install") || l.contains("launch") || l.contains("open") {
            if case .launching = current { return current }
            return .launching(retries: 0)
        }
        return current
    }

    /// The activity-view text for a phase (steps 1–3).
    public static func status(_ p: Phase, app: String) -> String {
        switch p {
        case .booting: "Booting Ycode Simulator… (1 of 3)"
        case .launching(let n): "Launching \(app)… (2 of 3)" + (n > 0 ? " — retry \(n)" : "")
        case .running: "Running \(app) on Ycode Simulator (3 of 3)"
        }
    }

    /// `YCODE-REMOTE-PID <n>`.
    public static func remotePID(_ line: String) -> Int? {
        guard line.hasPrefix("YCODE-REMOTE-PID ") else { return nil }
        return Int(line.dropFirst("YCODE-REMOTE-PID ".count).trimmingCharacters(in: .whitespaces))
    }

    @discardableResult
    func runLocal(_ exe: String, _ args: [String]) -> (Int32, String) {
        let (status, data) = runLocalData(exe, args, errors: true)
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Runs a local program; its output (with stderr when `errors`) as data.
    func runLocalData(_ exe: String, _ args: [String], errors: Bool) -> (Int32, Data) {
        MainThreadGuard.blockingCall("\(URL(fileURLWithPath: exe).lastPathComponent) \(args.prefix(2).joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = errors ? out : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (127, Data("could not run \(exe)".utf8)) }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, d)
    }

    /// Copies the app to the remote (mkdir, then rsync over ssh).
    public func upload(_ app: URL) throws {
        let (m, mo) = runLocal(settings.ssh, sshArguments(mkdirCommand(app)))
        guard m == 0 else { throw Simctl.Failure(description: "ssh mkdir failed (\(m)): \(mo)") }
        let (r, ro) = runLocal(settings.rsync, rsyncArguments(app))
        guard r == 0 else { throw Simctl.Failure(description: "rsync failed (\(r)): \(ro)") }
    }

    /// Sends a signal (`INT`, `TERM`) to a remote pid through ssh; returns
    /// ssh's status (0: delivered). Blocks: call it off the main actor.
    @discardableResult
    public func signalRemote(_ pid: Int, signal: String) -> Int32 {
        runLocal(settings.ssh, sshArguments("kill -\(signal) \(pid)")).0
    }

    // MARK: Erase (`run.md` §Warm boot item 7)

    /// `exec '<launcher>' --erase --device '<data>/devices/<device>'`: the
    /// host-side launcher waits for the device lock (a run of the device
    /// and its save end first), then discards the device's snapshot and
    /// its directory; the next run boots a new device.
    public var eraseCommand: String {
        "exec \(Self.quote(settings.simdPath)) --erase --device \(Self.quote(remoteDevicePath))"
    }

    /// Erases the device through ssh: (status, output). Blocks: call it off
    /// the main actor.
    public func erase() -> (Int32, String) {
        runLocal(settings.ssh, sshArguments(eraseCommand))
    }

    // MARK: Runtime version (the destination row)

    /// Prints the runtime root's `SystemVersion.plist`.
    public var runtimeVersionCommand: String {
        "cat \(Self.quote(settings.runtimeRoot + "/System/Library/CoreServices/SystemVersion.plist"))"
    }

    /// `ProductVersion` of a `SystemVersion.plist` (XML or binary).
    public static func productVersion(plist data: Data) -> String? {
        let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return p?["ProductVersion"] as? String
    }

    /// Reads the runtime's version from the host (nil when it cannot be
    /// read). Blocks: call it off the main actor.
    public func readRuntimeVersion() -> String? {
        let (status, data) = runLocalData(settings.ssh, sshArguments(runtimeVersionCommand), errors: false)
        return status == 0 ? Self.productVersion(plist: data) : nil
    }

    // MARK: Stop

    /// The activity text while a stopped run ends: with warm boot the
    /// launcher saves the device first (`snapshot.md` §12.2).
    public static func stoppingStatus(app: String, saves: Bool) -> String {
        saves ? "Stopping \(app) — saving Ycode Simulator…" : "Stopping \(app)…"
    }

    /// The launcher's last word after a stop: the save is in place (or
    /// was not made); the connection can close.
    public static func endsStop(_ line: String) -> Bool {
        line.hasPrefix("ycode-sim: ") && (line.contains("the device was saved") || line.contains("the device was not saved"))
    }
}

extension Destination {
    /// Ycode's remote simulator, with or without its runtime version.
    public var isYcodeRemoteSimulator: Bool { identifier == RemoteSimulator.identifier }
}

extension WorkspaceSession {
    /// Runs an app on the remote Ycode simulator: upload, then ycode-simd
    /// with `--install-app` and `--launch` through ssh, its output streamed
    /// into the console.
    public func runOnRemoteSimulator(app appURL: URL, remote: RemoteSimulator) async {
        guard let app = AppBundle(url: appURL) else { appendConsole("Ycode: \(appURL.lastPathComponent) is not an application bundle.\n"); return }
        guard remote.settings.isConfigured else {
            appendConsole("Ycode: set the remote simulator in Settings ▸ Simulators first.\n")
            return
        }
        let state = SimulatorRunState(target: .remote(destination: remote.settings.destination), app: app)
        state.remote = remote
        simulatorRun = state
        setActivity(.running("Uploading \(appURL.lastPathComponent) to \(remote.settings.destination)"))
        do {
            try await Task.detached { try remote.upload(appURL) }.value
        } catch {
            appendConsole("Ycode: \(error)\n")
            simulatorRun = nil
            setActivity(.finished("Run failed"))
            return
        }
        // Stopped during the upload: nothing was launched.
        if state.stopRequested {
            appendConsole("Ycode: stopped before \(app.executable) was launched.\n", kind: .debugger)
            if simulatorRun === state { simulatorRun = nil }
            setActivity(.idle)
            return
        }
        appendConsole("Ycode: launching \(app.bundleID) on \(remote.settings.destination)\n")
        var phase = RemoteSimulator.Phase.booting
        setActivity(.running(RemoteSimulator.status(phase, app: app.executable)))
        let proc = StreamingProcess(executable: remote.settings.ssh, arguments: remote.sshArguments(remote.runCommand(app: appURL, bundleID: app.bundleID)))
        state.process = proc
        do {
            try proc.start(onLine: { [weak self, weak state] line in
                guard let self, let state else { return }
                if let pid = RemoteSimulator.remotePID(line) {
                    state.remotePID = pid
                    // Stop came before the pid: send it now.
                    if state.stopRequested { self.sendRemoteStop(state, pid: pid, remote: remote) }
                    return
                }
                if !state.stopRequested {
                    let next = RemoteSimulator.phase(after: line, current: phase)
                    if next != phase {
                        phase = next
                        self.setActivity(.running(RemoteSimulator.status(phase, app: app.executable)))
                    }
                }
                // Simulator progress (including open retries), the
                // launcher's lines and everything after Stop are Ycode's
                // status, not program output.
                let status = state.stopRequested || line.hasPrefix("ycode-sim: ") || phase != .running || line.lowercased().hasPrefix("launched ")
                self.appendConsole(line + "\n", kind: status ? .debugger : .target)
                // The save at the stop is in place (or was not made): the
                // launcher is done; ycode-simd's teardown need not be awaited.
                if state.stopRequested, RemoteSimulator.endsStop(line) {
                    Task { [weak state] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let state, state.exitStatus == nil else { return }
                        state.closedByIDE = true
                        state.process?.signal(SIGINT)
                    }
                }
            }, onExit: { [weak self, weak state] status in
                state?.exitStatus = status
                guard let self else { return }
                let stopped = state?.stopRequested == true
                if state?.closedByIDE == true {
                    self.appendConsole("Ycode Simulator stopped\n")
                } else {
                    self.appendConsole("Ycode Simulator ended with status \(status)\(status == 0 || stopped ? "" : " (see ycode-simd's exit codes)")\n")
                }
                if self.simulatorRun === state { self.simulatorRun = nil }
                self.setActivity(.finished(status == 0 || stopped ? "Finished running \(app.executable)" : "Run failed"))
            })
        } catch {
            appendConsole("Ycode: \(error)\n")
            simulatorRun = nil
        }
    }
}

extension WorkspaceSession {
    /// Erases the remote simulator's device (`ycode-sim --erase`, run.md
    /// §Warm boot item 7) through ssh, off the main actor: (succeeded,
    /// message). Refused while this workspace runs an app on it. The
    /// launcher waits for another run of the device, and its save, to end.
    public func eraseRemoteSimulator(remote: RemoteSimulator) async -> (Bool, String) {
        guard remote.settings.isConfigured else { return (false, "Set the remote simulator in Settings ▸ Simulators first.") }
        if case .remote = simulatorRun?.target { return (false, "Stop the run on \(RemoteSimulator.deviceName) before erasing it.") }
        appendConsole("Ycode: erasing \(RemoteSimulator.deviceName) (\(remote.remoteDevicePath) on \(remote.settings.destination))\n", kind: .debugger)
        let (status, output) = await Task.detached { remote.erase() }.value
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { appendConsole(text + "\n", kind: .debugger) }
        guard status == 0 else {
            let last = text.split(separator: "\n").last.map(String.init) ?? ""
            return (false, "Erase failed (status \(status))" + (last.isEmpty ? "" : ": \(last)"))
        }
        return (true, "Erased")
    }
}
