import Foundation
import YcodeDebug
import YcodeBuild
import YcodeProfiler
import YcodeSubprocess

/// A remote run recorded by Gauge (`specs/ide/profiler.md` §5): where the
/// simulator host writes the trace, the sample rate, and where the IDE
/// keeps the copy.
public struct RemoteProfile: Sendable, Equatable {
    public var remotePath: String
    public var rate: Int
    public var localURL: URL
    public init(remotePath: String, rate: Int = 1000, localURL: URL) {
        self.remotePath = remotePath
        self.rate = rate
        self.localURL = localURL
    }

    /// `~/Library/Developer/Ycode/Gauge`, where the IDE keeps traces.
    public static var localDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Ycode/Gauge", isDirectory: true)
    }

    /// "<App>-<yyyyMMdd-HHmmss>.gaugetrace".
    public static func fileName(app: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(app)-\(f.string(from: date)).gaugetrace"
    }
}

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
    /// The device directory name under `<data>/devices` (of the primary
    /// target; the others add their type and runtime, `targets`).
    public var deviceName: String
    /// More runtime roots on the remote (iOS 27.0 next to 27.1, …): each
    /// gives its own destinations (`targets`, run.md §Runtimes and device
    /// types).
    public var otherRuntimeRoots: [String] = []
    /// Versions read from the host, per runtime root.
    public var runtimeVersions: [String: String] = [:]
    /// Platforms read from the host ("iOS", "watchOS", "visionOS"), per
    /// runtime root (`SystemVersion.plist` `ProductName`).
    public var runtimePlatforms: [String: String] = [:]
    /// Devices the user created in Device Hub (`RemoteCreatedDevice`; read
    /// by `load`, written only by `saveCreatedDevices`).
    public var createdDevices: [RemoteCreatedDevice] = []
    /// Extra ycode-simd options (host-side: --shim, --host-libs, --timeout-ms, …),
    /// split into words like a shell would (quotes group) and passed after
    /// the generated options, each single-quoted.
    public var additionalArguments: String = ""
    /// Lean boot (off by default: every service boots, as in the reference
    /// simulator): ycode-simd skips background services
    /// (`YCODE_LEAN_BOOT=daemons`); `keepServices` lists launchd labels to
    /// keep (comma-separated). See `specs/ide/run.md`.
    public var leanBoot = false
    public var keepServices: String = ""
    public static let leanBootHelp = "Development option: skips background services such as Siri, Spotlight, suggestions and photo analysis, so apps that use them see them missing. Off (the default), every service boots."
    /// The defaults key of Lean boot. Until 2026-10-27 Lean boot was on by
    /// default and stored under `leanBootLegacyKey`; every save wrote it, so
    /// a stored `true` mostly meant the old default. That key is no longer
    /// read (and a save removes it): everyone starts with a full boot once,
    /// and a user who turns Lean boot on again is remembered under this key.
    public static let leanBootKey = "Ycode.remote.leanBootChoice"
    public static let leanBootLegacyKey = "Ycode.remote.leanBoot"
    /// Warm boot (on by default): the host-side launcher restores the
    /// device from a snapshot of its booted state when one is valid, and
    /// otherwise boots cold and saves one (`YCODE_WARM_BOOT=1`). Off: every
    /// run boots cold (`YCODE_WARM_BOOT=0`). See `specs/ide/run.md` §Warm boot.
    public var warmBoot = true
    public static let warmBootHelp = "Keeps the device's state between runs: when a run stops, the device is saved, and the next run continues from it in seconds instead of booting; apps and their data stay until the device is erased. Saves are replaced when the simulator or the runtime changes. Turn off to boot from scratch every time."
    /// The device's camera (`ycode-simd --camera`; `specs/simulator/camera.md`
    /// "Ycode implementation"): `off` (the default: no camera, as the
    /// reference simulator), `on` (the host's webcam, else the synthetic
    /// pattern) or `synthetic`. `cameraChosen` records that the user set it
    /// once: from then on every run passes it (the device keeps the last
    /// value it was given), before that runs pass nothing.
    public var camera = "off"
    public var cameraChosen = false
    /// A Vision Pro's display (device-hub.md §I.12): "" the device type's
    /// 3840 × 2160 (the desktop's), or "2160x3840" (the headset's full field
    /// of view). Applies when the device boots.
    public var visionDisplay = ""
    public static let headsetVisionDisplay = "2160x3840"
    public static let cameraModes = ["off", "on", "synthetic"]
    public static let cameraHelp = "Gives apps a camera: the host's USB webcam (or a test pattern when it has none) appears as the device's back camera (an iPad's external camera). Off by default."
    /// Local programs (tests point these at stand-ins).
    public var ssh: String
    public var rsync: String

    public init(destination: String = "", dataDirectory: String = "", runtimeRoot: String = "", simdPath: String = "",
                deviceName: String = "ycode-device", ssh: String = HostTool.path("ssh"), rsync: String = HostTool.path("rsync")) {
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

    /// Remembers the version read from the host for a runtime root (the
    /// primary root's also under the keys of a single runtime).
    public static func saveRuntimeVersion(_ version: String, root: String, _ d: UserDefaults, primary: Bool = true) {
        if primary {
            d.set(version, forKey: "Ycode.remote.runtimeVersion")
            d.set(root, forKey: "Ycode.remote.runtimeVersionRoot")
        }
        var all = d.dictionary(forKey: "Ycode.remote.runtimeVersions") as? [String: String] ?? [:]
        all[root] = version
        d.set(all, forKey: "Ycode.remote.runtimeVersions")
    }

    /// Remembers the platform read from the host for a runtime root.
    public static func saveRuntimePlatform(_ platform: String, root: String, _ d: UserDefaults) {
        var all = d.dictionary(forKey: "Ycode.remote.runtimePlatforms") as? [String: String] ?? [:]
        all[root] = platform
        d.set(all, forKey: "Ycode.remote.runtimePlatforms")
    }

    /// Whether the remembered version belongs to this runtime root.
    public static func hasRuntimeVersion(for root: String, _ d: UserDefaults) -> Bool {
        if d.string(forKey: "Ycode.remote.runtimeVersionRoot") == root && d.string(forKey: "Ycode.remote.runtimeVersion") != nil { return true }
        return (d.dictionary(forKey: "Ycode.remote.runtimeVersions") as? [String: String])?[root] != nil
    }

    static let keys = ["destination", "dataDirectory", "runtimeRoot", "simdPath", "deviceName"]

    public static func load(_ d: UserDefaults) -> RemoteSimulatorSettings {
        var s = RemoteSimulatorSettings()
        s.destination = d.string(forKey: "Ycode.remote.destination") ?? ""
        s.dataDirectory = d.string(forKey: "Ycode.remote.dataDirectory") ?? ""
        s.runtimeRoot = d.string(forKey: "Ycode.remote.runtimeRoot") ?? ""
        s.simdPath = d.string(forKey: "Ycode.remote.simdPath") ?? ""
        s.deviceName = d.string(forKey: "Ycode.remote.deviceName") ?? "ycode-device"
        s.otherRuntimeRoots = d.stringArray(forKey: "Ycode.remote.otherRuntimeRoots") ?? []
        s.runtimeVersions = d.dictionary(forKey: "Ycode.remote.runtimeVersions") as? [String: String] ?? [:]
        s.runtimePlatforms = d.dictionary(forKey: "Ycode.remote.runtimePlatforms") as? [String: String] ?? [:]
        s.createdDevices = createdDevices(d)
        s.additionalArguments = d.string(forKey: "Ycode.remote.additionalArguments") ?? ""
        s.leanBoot = d.object(forKey: leanBootKey) as? Bool ?? false
        s.keepServices = d.string(forKey: "Ycode.remote.keepServices") ?? ""
        s.warmBoot = d.object(forKey: "Ycode.remote.warmBoot") as? Bool ?? true
        s.camera = d.string(forKey: "Ycode.remote.camera").flatMap { cameraModes.contains($0) ? $0 : nil } ?? "off"
        s.cameraChosen = d.object(forKey: "Ycode.remote.camera") != nil
        s.visionDisplay = d.string(forKey: "Ycode.remote.visionDisplay") ?? ""
        s.runtimeVersion = hasRuntimeVersion(for: s.runtimeRoot, d) ? d.string(forKey: "Ycode.remote.runtimeVersion") : version(inPath: s.runtimeRoot)
        return s
    }

    public func save(_ d: UserDefaults) {
        d.set(destination, forKey: "Ycode.remote.destination")
        d.set(dataDirectory, forKey: "Ycode.remote.dataDirectory")
        d.set(runtimeRoot, forKey: "Ycode.remote.runtimeRoot")
        d.set(simdPath, forKey: "Ycode.remote.simdPath")
        d.set(deviceName, forKey: "Ycode.remote.deviceName")
        d.set(otherRuntimeRoots, forKey: "Ycode.remote.otherRuntimeRoots")
        d.set(additionalArguments, forKey: "Ycode.remote.additionalArguments")
        d.set(leanBoot, forKey: Self.leanBootKey)
        d.removeObject(forKey: Self.leanBootLegacyKey)
        d.set(keepServices, forKey: "Ycode.remote.keepServices")
        d.set(warmBoot, forKey: "Ycode.remote.warmBoot")
        if cameraChosen { d.set(camera, forKey: "Ycode.remote.camera") }
        d.set(visionDisplay, forKey: "Ycode.remote.visionDisplay")
    }
}

/// Command construction and helper calls for the remote simulator.
public struct RemoteSimulator: Sendable {
    public var settings: RemoteSimulatorSettings
    /// The runtime and device type this simulator runs (nil: the settings
    /// have no runtime root; the plain settings are used).
    public var target: RemoteSimulatorTarget?
    /// The display socket's file name when it is not `<device directory>.sock`
    /// (preview devices: a short name, `previews.md` §Pieces).
    public var displaySocketName: String?
    /// The simulator of a destination (its target by identifier; the
    /// primary target for nil or an unknown identifier).
    public init(settings: RemoteSimulatorSettings, destination: Destination? = nil) {
        self.settings = settings
        self.target = settings.target(for: destination)
    }

    public init(settings: RemoteSimulatorSettings, target: RemoteSimulatorTarget?) {
        self.settings = settings
        self.target = target
    }

    /// Every target's simulator (Settings order).
    public static func all(_ settings: RemoteSimulatorSettings) -> [RemoteSimulator] {
        settings.targets.map { RemoteSimulator(settings: settings, target: $0) }
    }

    /// Device Hub's simulators: every target's, then the watches of the
    /// watchOS runtime roots (`RemoteSimulatorSettings.hubTargets`).
    public static func hub(_ settings: RemoteSimulatorSettings) -> [RemoteSimulator] {
        settings.hubTargets.map { RemoteSimulator(settings: settings, target: $0) }
    }

    /// The runtime root this simulator boots.
    public var runtimeRoot: String { target?.runtimeRoot ?? settings.runtimeRoot }
    /// Its runtime version, when known.
    public var runtimeVersion: String? { target.map(\.runtimeVersion) ?? settings.runtimeVersion }

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
    public var destination: Destination { target?.destination ?? Self.destination(runtimeVersion: settings.runtimeVersion) }

    /// Every destination row of the settings (run.md §Runtimes and device
    /// types): the iOS targets, the watches (rows of watchOS schemes), and
    /// each phone with an active paired watch (`device-pairing.md` §11.4,
    /// §13; also a row of watchOS schemes).
    public static func destinations(_ settings: RemoteSimulatorSettings, pairs: [RemoteDevicePair] = []) -> [Destination] {
        settings.targets.map(\.destination) + settings.watchTargets.map(\.destination) + settings.pairedDestinations(pairs)
    }

    /// How long Stop waits for the launcher to save the device and end
    /// before it closes the connection itself (the launcher kills
    /// ycode-simd 120 s after a stop that has not finished).
    public var stopGrace: TimeInterval = 150

    /// POSIX shell single quoting.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public func remoteAppPath(_ app: URL) -> String { "\(settings.dataDirectory)/apps/\(app.lastPathComponent)" }
    public var remoteDevicePath: String { "\(settings.dataDirectory)/devices/\(target?.deviceDirectoryName ?? settings.deviceName)" }

    /// ssh options: keys only, never prompt.
    var sshOptions: [String] { ["-o", "BatchMode=yes"] }

    public func sshArguments(_ command: String) -> [String] { sshOptions + [settings.destination, command] }

    /// The apps directory and the display sockets' (Device Hub's live screen).
    public func mkdirCommand(_ app: URL) -> String {
        "mkdir -p \(Self.quote("\(settings.dataDirectory)/apps")) \(Self.quote("\(settings.dataDirectory)/display")) \(Self.quote(profilesDirectory))"
    }

    /// Where Gauge traces are written on the host (profiler.md §5).
    public var profilesDirectory: String { "\(settings.dataDirectory)/profiles" }

    /// A profile of a run of `app`: the trace's remote and local paths.
    public func profile(app: URL, rate: Int = 1000, date: Date = Date()) -> RemoteProfile {
        let name = RemoteProfile.fileName(app: app.deletingPathExtension().lastPathComponent, date: date)
        return RemoteProfile(remotePath: "\(profilesDirectory)/\(name)", rate: rate,
                             localURL: RemoteProfile.localDirectory.appendingPathComponent(name))
    }

    /// rsync of a remote trace to its local path.
    public func fetchArguments(_ profile: RemoteProfile) -> [String] {
        ["-az", "-e", ([settings.ssh] + sshOptions).joined(separator: " "),
         "\(settings.destination):\(profile.remotePath)", profile.localURL.path]
    }

    /// Copies the trace back (Gauge). Blocks: call it off the main actor.
    public func fetchProfile(_ profile: RemoteProfile) throws {
        try FileManager.default.createDirectory(at: profile.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (r, ro) = runLocal(settings.rsync, fetchArguments(profile))
        guard r == 0 else { throw Simctl.Failure(description: "the trace could not be copied from \(settings.destination) (rsync \(r)): \(ro)") }
    }

    public func rsyncArguments(_ app: URL) -> [String] {
        ["-az", "--delete", "-e", ([settings.ssh] + sshOptions).joined(separator: " "),
         app.path + "/", "\(settings.destination):\(remoteAppPath(app))/"]
    }

    /// The remote command: prints the shell's pid, then becomes ycode-simd
    /// (so a signal to that pid reaches it). `--environment-overrides`: the
    /// app is launched with Ycode's Environment Overrides library, so the
    /// debug bar can override its appearance and accessibility (`debug.md`
    /// §Environment Overrides; an app option, not part of the snapshot's
    /// fingerprint).
    /// `debug`: ycode-simd serves the debug stub for the app
    /// (`--debug-server`, `specs/simulator/debug-stub.md` §8).
    public func runCommand(app: URL, bundleID: String, profile: RemoteProfile? = nil, debug: Bool = false) -> String {
        let q = Self.quote
        return "echo YCODE-REMOTE-PID $$; exec \(environmentPrefix)\(q(settings.simdPath)) --device \(q(remoteDevicePath)) --runtime-root \(q(runtimeRoot))"
            + (target?.deviceTypeArguments ?? []).map { " " + q($0) }.joined()
            + " --install-app \(q(remoteAppPath(app))) --launch \(q(bundleID)) --environment-overrides"
            + (profile.map { " --profile \(q($0.remotePath)) --profile-rate \(q(String($0.rate)))" } ?? "")
            + (debug ? debugServerArguments.map { " " + q($0) }.joined() : "")
            + displayServerArguments.map { " " + q($0) }.joined()
            + Self.words(settings.additionalArguments).map { " " + q($0) }.joined()
            + cameraArguments.map { " " + q($0) }.joined()
            + visionDisplayArguments.map { " " + q($0) }.joined()
    }

    /// The Ycode simulator destination ycodebuild's test actions take
    /// (specs/xcodebuild/test-actions.md, "Ycode implementation").
    public static let testDestination = "platform=iOS Simulator,name=Ycode Simulator,arch=arm64"

    /// The `YCODE_SIM_*` variables that tell ycodebuild where this
    /// simulator runs, for Product ▸ Test on it: the same host, data
    /// directory, runtime, launcher, device and options as a run.
    public var testEnvironment: [String: String] {
        let q = Self.quote
        let options = (target?.deviceTypeArguments ?? []) + Self.words(settings.additionalArguments) + cameraArguments
        var env = [
            "YCODE_SIM_HOST": settings.destination, "YCODE_SIM_DATA": settings.dataDirectory, "YCODE_SIM_RUNTIME": runtimeRoot,
            "YCODE_SIM_SIMD": settings.simdPath, "YCODE_SIM_DEVICE": target?.deviceDirectoryName ?? settings.deviceName,
            "YCODE_SIM_OPTIONS": options.map(q).joined(separator: " "),
            "YCODE_SIM_ENV": ("YCODE_WARM_BOOT=\(settings.warmBoot ? 1 : 0) " + leanBootVariables).trimmingCharacters(in: .whitespaces),
        ]
        if settings.ssh != HostTool.path("ssh") { env["YCODE_SSH"] = settings.ssh }
        if settings.rsync != HostTool.path("rsync") { env["YCODE_RSYNC"] = settings.rsync }
        return env
    }

    /// `--camera <mode>` once the user chose a camera mode (Settings ▸
    /// Simulators); nothing before. The device keeps the mode, and the
    /// launcher's warm-boot fingerprint includes it, so a change boots cold.
    /// `--vision-display <w>x<h>` for a Vision Pro whose display was set for the headset.
    public var visionDisplayArguments: [String] {
        target?.isVision == true && !settings.visionDisplay.isEmpty ? ["--vision-display", settings.visionDisplay] : []
    }

    public var cameraArguments: [String] {
        settings.cameraChosen || settings.camera != "off" ? ["--camera", settings.camera] : []
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

    /// The activity-view text for a phase: the simulator run texts of
    /// `reference-ui-6.md` §3.3 with the remote device's name. "Launching
    /// <app>" also covers the upload and the boot; there are no step
    /// counters, and open retries show in the console only. Under the
    /// debugger "Configuring Debugger Actions" follows the launched line
    /// until lldb-dap is attached (`attachToRemoteSimulatorApp`).
    public static func status(_ p: Phase, app: String, device: String = RemoteSimulator.deviceName) -> String {
        switch p {
        case .booting, .launching: WorkspaceSession.RunActivityText.launching(app)
        case .running: WorkspaceSession.RunActivityText.running(app, on: device)
        }
    }

    // MARK: The debugger (debug-stub.md §8)

    /// The debug stub's socket on the host: one per device directory under
    /// `<data>/debug` (Ycode decision, like the display socket).
    public var debugSocketPath: String {
        "\(settings.dataDirectory)/debug/\(target?.deviceDirectoryName ?? settings.deviceName).sock"
    }

    public var debugServerArguments: [String] { ["--debug-server", "unix:" + debugSocketPath] }

    /// What ycode-simd prints once the stub listens ("ycode-simd: debug:
    /// gdb-remote stub listening on …").
    public static let debugStubListeningMarker = "debug: gdb-remote stub listening on "

    /// `ssh -N -L 127.0.0.1:<port>:<stub socket> <destination>`: the stub on
    /// a loopback port of the Mac, where lldb-dap connects.
    public func debugForwardArguments(localPort: Int) -> [String] {
        sshOptions + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
                      "-L", "127.0.0.1:\(localPort):\(debugSocketPath)", settings.destination]
    }

    /// Runs on the Ycode simulator attach the debugger, as runs on a Mac
    /// simulator do; the defaults key `Ycode.remote.debugger` = false turns
    /// it off.
    public static func attachesDebugger(_ d: UserDefaults) -> Bool { d.object(forKey: "Ycode.remote.debugger") as? Bool ?? true }

    /// lldb settings for a session on the stub (debug-stub.md §8.3): the
    /// guest's paths are not the Mac's, so lldb finds the build's binaries
    /// by name in the app's directory (UUIDs checked); the system images
    /// are read from the process's memory, in 16 KiB reads (one guest page)
    /// rather than 512 bytes, which cuts the attach from minutes to seconds
    /// over ssh; trampoline support is off (§11).
    public static func debuggerSettings(appDirectory: String) -> [String] {
        ["settings set target.exec-search-paths \"\(appDirectory)\"",
         "settings set target.process.memory-cache-line-size 16384",
         // lldb's Objective-C trampoline check crashes it on a step into a
         // function when libobjc is read from memory (debug-stub.md §11).
         "settings set target.enable-trampoline-support false"]
    }

    /// SOCK_STREAM as `socket` takes it on each platform.
    static var streamSocketType: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    /// A free loopback TCP port (bound and released; the forward takes it).
    public static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, RemoteSimulator.streamSocketType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// `YCODE-REMOTE-PID <n>`.
    public static func remotePID(_ line: String) -> Int? {
        guard line.hasPrefix("YCODE-REMOTE-PID ") else { return nil }
        return Int(line.dropFirst("YCODE-REMOTE-PID ".count).trimmingCharacters(in: .whitespaces))
    }

    @discardableResult
    package func runLocal(_ exe: String, _ args: [String], timeout: TimeInterval? = nil) -> (Int32, String) {
        let (status, data) = runLocalData(exe, args, errors: true, timeout: timeout)
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Runs a local program; its output (with stderr when `errors`) as data.
    /// With `timeout`, a program still running then is ended (SIGTERM).
    func runLocalData(_ exe: String, _ args: [String], errors: Bool, timeout: TimeInterval? = nil) -> (Int32, Data) {
        MainThreadGuard.blockingCall("\(URL(fileURLWithPath: exe).lastPathComponent) \(args.prefix(2).joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = errors ? out : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (127, Data("could not run \(exe)".utf8)) }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
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

    // MARK: Fold (`specs/simulator/foldable.md` §8.3 E1–E3)

    /// Whether this simulator's device type folds.
    public var isFoldable: Bool { target?.deviceType.isFoldable ?? false }

    /// `exec '<launcher>' --device '<dev>' --control <words…>`: one command
    /// to the running device's control socket (`fold closed|half|open|<deg>`,
    /// `rotate left|right`, `state`); the launcher passes it to ycode-simd,
    /// which answers with one line starting with "ok" or "error".
    public func controlCommand(_ words: [String]) -> String {
        "exec \(Self.quote(settings.simdPath)) --device \(Self.quote(remoteDevicePath)) --control"
            + words.map { " " + Self.quote($0) }.joined()
    }

    /// Sends a control command through ssh: (status, reply). Blocks: call it
    /// off the main actor.
    /// A command that does not answer within `controlTimeout` seconds is
    /// ended (it used to hold its caller, and a thread of the cooperative
    /// pool, until the IDE quit).
    public func control(_ words: [String]) -> (Int32, String) {
        runLocal(settings.ssh, sshArguments(controlCommand(words)), timeout: controlTimeout)
    }

    /// How long a control command may take (a host that is slow to answer
    /// still answers well within it).
    public var controlTimeout: TimeInterval = 60

    /// The hinge angle in a `state` reply ("ok angle 180° (Open Flat), …").
    public static func hingeAngle(stateReply: String) -> Int? {
        guard let r = stateReply.range(of: #"angle (\d+)"#, options: .regularExpression) else { return nil }
        return Int(stateReply[r].dropFirst("angle ".count))
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
        "cat \(Self.quote(runtimeRoot + "/System/Library/CoreServices/SystemVersion.plist"))"
    }

    /// `ProductVersion` of a `SystemVersion.plist` (XML or binary).
    public static func productVersion(plist data: Data) -> String? {
        let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return p?["ProductVersion"] as? String
    }

    /// The platform a `SystemVersion.plist` names: `ProductName` "Watch OS"
    /// (with the space; watchos.md §2.1) is watchOS, "xrOS" visionOS,
    /// anything else iOS; nil when the data is not a property list.
    public static func productPlatform(plist data: Data) -> String? {
        guard let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        switch p["ProductName"] as? String {
        case "Watch OS": return "watchOS"
        case "xrOS": return "visionOS"
        default: return "iOS"
        }
    }

    /// Reads the runtime's version from the host (nil when it cannot be
    /// read). Blocks: call it off the main actor.
    public func readRuntimeVersion() -> String? { readRuntimeSystemVersion()?.version }

    /// Reads the runtime's version and platform from the host (nil when
    /// they cannot be read). Blocks: call it off the main actor.
    public func readRuntimeSystemVersion() -> (version: String, platform: String)? {
        let (status, data) = runLocalData(settings.ssh, sshArguments(runtimeVersionCommand), errors: false)
        guard status == 0, let v = Self.productVersion(plist: data) else { return nil }
        return (v, Self.productPlatform(plist: data) ?? "iOS")
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
    public var isYcodeRemoteSimulator: Bool {
        guard let identifier else { return false }
        return identifier == RemoteSimulator.identifier || identifier.hasPrefix(RemoteSimulator.identifier + ":")
    }
}

extension WorkspaceSession {
    /// Runs an app on the remote Ycode simulator: upload, then ycode-simd
    /// with `--install-app` and `--launch` through ssh, its output streamed
    /// into the console.
    public func runOnRemoteSimulator(app appURL: URL, remote: RemoteSimulator, profile: RemoteProfile? = nil,
                                     onTrace: (@MainActor (Result<URL, Error>) -> Void)? = nil) async {
        // A run that ends before ycode-simd starts still answers a profile
        // (the profiler window would otherwise wait for a trace forever).
        func fail(_ text: String) { onTrace?(.failure(RemoteRunFailure(description: text))) }
        guard let app = AppBundle(url: appURL) else {
            appendConsole("Ycode: \(appURL.lastPathComponent) is not an application bundle.\n")
            fail("\(appURL.lastPathComponent) is not an application bundle")
            return
        }
        guard remote.settings.isConfigured else {
            appendConsole("Ycode: set the remote simulator in Settings ▸ Simulators first.\n")
            fail("the remote simulator is not set up (Settings ▸ Simulators)")
            return
        }
        let state = SimulatorRunState(target: .remote(destination: remote.settings.destination), app: app)
        state.remote = remote
        simulatorRun = state
        let device = remote.destination.name
        setActivity(.running(RemoteSimulator.status(.booting, app: app.executable, device: device)))
        do {
            try await Task.detached { try remote.upload(appURL) }.value
        } catch {
            appendConsole("Ycode: \(error)\n")
            simulatorRun = nil
            setActivity(.finished("Run failed"))
            fail("the upload failed: \(error)")
            return
        }
        // Stopped during the upload: nothing was launched.
        if state.stopRequested {
            appendConsole("Ycode: stopped before \(app.executable) was launched.\n", kind: .debugger)
            if simulatorRun === state { simulatorRun = nil }
            setActivity(.idle)
            fail("stopped before \(app.executable) was launched")
            return
        }
        // A device started from Device Hub runs without the app: it is shut
        // down (and saved) first, then the run boots or restores it.
        if RemoteDeviceSessions.shared.isRunning(remote) {
            appendConsole("Ycode: shutting down \(device) (started in Device Hub) for the run\n", kind: .debugger)
            await RemoteDeviceSessions.shared.shutDown(remote)
        }
        appendConsole("Ycode: launching \(app.bundleID) on \(remote.settings.destination)\n")
        var phase = RemoteSimulator.Phase.booting
        // ycode-simd says when its debug stub listens; an older one without
        // the stub (or a stand-in) never does, and no debugger attaches.
        var stubListening = false
        setActivity(.running(RemoteSimulator.status(phase, app: app.executable, device: device)))
        // The debugger attaches once the app runs (debug-stub.md §8); not
        // to a profiled run (Gauge measures the app alone).
        let debug = profile == nil && RemoteSimulator.attachesDebugger(Preferences.shared.defaults)
        let proc = StreamingProcess(executable: remote.settings.ssh,
                                    arguments: remote.sshArguments(remote.runCommand(app: appURL, bundleID: app.bundleID, profile: profile, debug: debug)))
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
                if debug, !stubListening, line.contains(RemoteSimulator.debugStubListeningMarker) { stubListening = true }
                if !state.stopRequested {
                    let next = RemoteSimulator.phase(after: line, current: phase)
                    if next != phase {
                        phase = next
                        let text = RemoteSimulator.status(phase, app: app.executable, device: device)
                        if self.activity != .running(text) { self.setActivity(.running(text)) }
                        if debug, stubListening, phase == .running {
                            self.setActivity(.running(WorkspaceSession.RunActivityText.configuringDebugger))
                            Task { [weak self] in await self?.attachToRemoteSimulatorApp(state, remote: remote, app: appURL, device: device) }
                        }
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
                if let f = state?.debugForward, f.isRunning { f.terminate() }
                guard let self else { return }
                let stopped = state?.stopRequested == true
                if state?.closedByIDE == true {
                    self.appendConsole("Ycode Simulator stopped\n")
                } else {
                    self.appendConsole("Ycode Simulator ended with status \(status)\(status == 0 || stopped ? "" : " (see ycode-simd's exit codes)")\n")
                }
                if self.simulatorRun === state { self.simulatorRun = nil }
                self.setActivity(.finished(status == 0 || stopped ? WorkspaceSession.RunActivityText.finished(app.executable, on: device) : "Run failed"))
                if let profile {
                    // Gauge: copy the trace back, add the build's symbols and lines.
                    self.appendConsole("Ycode: copying the Gauge trace from \(remote.settings.destination)\n", kind: .debugger)
                    let products = appURL.deletingLastPathComponent()
                    Task { [weak self] in
                        let result: Result<URL, Error> = await Task.detached {
                            do {
                                try remote.fetchProfile(profile)
                                try Self.symbolicateTrace(at: profile.localURL, searching: [products])
                                return .success(profile.localURL)
                            } catch {
                                return .failure(error)
                            }
                        }.value
                        if case .failure(let e) = result { self?.appendConsole("Ycode: Gauge: \(e)\n", kind: .debugger) }
                        onTrace?(result)
                    }
                }
            })
        } catch {
            appendConsole("Ycode: \(error)\n")
            simulatorRun = nil
            fail("ssh did not start: \(error)")
        }
    }
}

extension WorkspaceSession {
    /// The debugger for a run on the Ycode simulator (debug-stub.md §8):
    /// ssh forwards the stub's socket to a loopback port, and lldb-dap
    /// attaches through it (`gdb-remote-port`) with the local build of the
    /// app, so breakpoints, the debug bar and the variables view work as in
    /// a local run. The forward ends with the run.
    func attachToRemoteSimulatorApp(_ state: SimulatorRunState, remote: RemoteSimulator, app appURL: URL, device: String) async {
        guard let app = AppBundle(url: appURL), let port = RemoteSimulator.freeLoopbackPort() else { return }
        // The debug activity texts ("Paused <app>", "Running <app> on <device>").
        runningProduct = app.executable
        runningDeviceName = device
        let forward = Process()
        forward.executableURL = URL(fileURLWithPath: remote.settings.ssh)
        forward.arguments = remote.debugForwardArguments(localPort: port)
        forward.standardInput = FileHandle.nullDevice
        forward.standardOutput = FileHandle.nullDevice
        forward.standardError = FileHandle.nullDevice
        do { try forward.run() } catch {
            appendConsole("Ycode: the debugger's ssh forward did not start: \(error)\n", kind: .debugger)
            return
        }
        state.debugForward = forward
        // The forward is up once the port accepts a connection (at most 10 s).
        for _ in 0..<100 where forward.isRunning {
            if await Task.detached(operation: { Self.portAccepts(port) }).value { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard forward.isRunning, simulatorRun === state, !state.stopRequested else {
            if forward.isRunning { forward.terminate() }
            appendConsole("Ycode: the debugger could not reach \(remote.settings.destination)\n", kind: .debugger)
            if simulatorRun === state { setActivity(.running(WorkspaceSession.RunActivityText.running(app.executable, on: device))) }
            return
        }
        guard let path = await Task.detached(operation: { LLDBDAP.locate() }).value else {
            appendConsole("Ycode: lldb-dap was not found.\n")
            forward.terminate()
            return
        }
        do {
            let client = try DAPClient(transport: ProcessTransport(executable: path))
            debugClient = client
            Task { [weak self] in
                for await e in client.events { await self?.handle(e) }
                self?.sessionEnded()
                if forward.isRunning { forward.terminate() }
            }
            try await client.initialize()
            attachingSimulatorApp = true
            defer { attachingSimulatorApp = false }
            let dir = app.executableURL.deletingLastPathComponent().path
            try await client.attachRemote(port: port, program: app.executableURL.path, threadFormat: DebugThread.format,
                                          preRunCommands: RemoteSimulator.debuggerSettings(appDirectory: dir))
            // Attaching stops the app: resume it once so it runs to the breakpoints.
            for _ in 0..<100 where stoppedThread == nil { try? await Task.sleep(for: .milliseconds(100)) }
            attachingSimulatorApp = false
            if stoppedThread != nil { await continueOrPause() }
        } catch {
            appendConsole("Ycode: attach failed: \(error)\n")
            if forward.isRunning { forward.terminate() }
        }
        if simulatorRun === state, case .running = activity, stoppedThread == nil {
            setActivity(.running(WorkspaceSession.RunActivityText.running(app.executable, on: device)))
        }
    }

    /// True when a TCP connection to the loopback port succeeds.
    nonisolated static func portAccepts(_ port: Int) -> Bool {
        let fd = socket(AF_INET, RemoteSimulator.streamSocketType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}

/// Why a remote run ended before the simulator started.
public struct RemoteRunFailure: Error, CustomStringConvertible, Sendable {
    public var description: String
}

extension WorkspaceSession {
    /// Gauge (profiler.md §5): re-symbolicates a trace's app images from
    /// the build's products (dSYMs and binaries matched by UUID; source
    /// lines from the dSYM) and demangles Swift names.
    nonisolated static func symbolicateTrace(at url: URL, searching roots: [URL]) throws {
        var t = try GaugeTraceCodec.read(url)
        GaugeSymbolicator.symbolicateMachO(&t, searching: roots)
        GaugeSymbolicator.demangle(&t)
        try GaugeTraceCodec.write(t, to: url)
    }
}

extension WorkspaceSession {
    /// Sends a fold or rotate command to a running remote simulator
    /// (`foldable.md` §8.3), off the main actor: (succeeded, message). The
    /// reply goes to the console.
    public func controlRemoteSimulator(remote: RemoteSimulator, _ words: [String]) async -> (Bool, String) {
        guard remote.settings.isConfigured else { return (false, "Set the remote simulator in Settings ▸ Simulators first.") }
        let (status, output) = await Task.detached { remote.control(words) }.value
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.first != "state" && words.first != "settings" { appendConsole("Ycode: \(words.joined(separator: " ")): \(text)\n", kind: .debugger) }
        return (status == 0, text)
    }

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
