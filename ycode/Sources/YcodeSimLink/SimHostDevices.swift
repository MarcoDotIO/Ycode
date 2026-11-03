// The host service's devices (sim-link.md §6.3): each is a directory under
// `<home>/devices/<name>` with a sidecar `<name>.json` (its device type and
// runtime), run by the host-side launcher (scripts/ycode-sim.sh, the IDE's
// `ycode-sim`) with a display socket `<home>/run/<name>.sock`, warm boot,
// and boot slots, as scripts/ycode-sim-serve runs one. A run with an app
// installs and launches it at boot (the launcher's --install-app/--launch;
// a running device is stopped, i.e. saved, first).

import Foundation

public struct SimHostConfig: Sendable, Equatable {
    public var home: String
    public var tree: String
    public var launcher: String
    /// Runtime roots by device type ("" for the default).
    public var runtimes: [String: String]
    /// Pristine devices by device type ("" for the default).
    public var pristines: [String: String]
    public var locks: String?
    public var slots: Int
    public var gpuCache: String?
    public var guestTools: String?
    public var hours: Int
    public var listenHost: String
    public var controlPort: Int
    public var mediaPort: Int
    public var name: String

    /// From `KEY=value` lines (a sim-serve.env style file) over the environment.
    public static func load(text: String, environment: [String: String]) throws -> SimHostConfig {
        var v: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            v[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = value
        }
        for (k, x) in environment where k.hasPrefix("YCODE_SIM") { v[k] = x }
        func need(_ k: String) throws -> String {
            guard let x = v[k], !x.isEmpty else { throw LinkError.refused("\(k) is not set in the host configuration") }
            return x
        }
        let home = try need("YCODE_SIM_HOME"), tree = try need("YCODE_SIM_TREE")
        var runtimes: [String: String] = ["": try need("YCODE_SIM_RUNTIME")]
        var pristines: [String: String] = [:]
        if let p = v["YCODE_SIM_PRISTINE"], !p.isEmpty { pristines[""] = p }
        for (k, x) in v {
            if k.hasPrefix("YCODE_SIM_RUNTIME_") { runtimes[typeID(suffix: String(k.dropFirst("YCODE_SIM_RUNTIME_".count)))] = x }
            if k.hasPrefix("YCODE_SIM_PRISTINE_") { pristines[typeID(suffix: String(k.dropFirst("YCODE_SIM_PRISTINE_".count)))] = x }
        }
        let listen = v["YCODE_SIMHOST_LISTEN"] ?? "0.0.0.0:\(LinkDefaults.controlPort)"
        let (lh, lp) = splitHostPort(listen, defaultPort: LinkDefaults.controlPort)
        return SimHostConfig(home: home, tree: tree, launcher: v["YCODE_SIM_LAUNCHER"] ?? "\(home)/bin/ycode-sim",
                             runtimes: runtimes, pristines: pristines, locks: v["YCODE_SIM_LOCKS"], slots: Int(v["YCODE_SIM_SLOTS"] ?? "") ?? 4,
                             gpuCache: v["YCODE_SIM_GPU_CACHE"], guestTools: v["YCODE_SIM_GUEST_TOOLS"], hours: Int(v["YCODE_SIM_HOURS"] ?? "") ?? 4,
                             listenHost: lh, controlPort: lp, mediaPort: Int(v["YCODE_SIMHOST_MEDIA_PORT"] ?? "") ?? LinkDefaults.mediaPort,
                             name: v["YCODE_SIMHOST_NAME"] ?? ProcessInfo.processInfo.hostName)
    }

    /// "IPHONE_18_PRO" → "iphone-18-pro".
    public static func typeID(suffix: String) -> String { suffix.lowercased().replacingOccurrences(of: "_", with: "-") }

    public static func splitHostPort(_ s: String, defaultPort: Int) -> (String, Int) {
        if let i = s.lastIndex(of: ":"), let p = Int(s[s.index(after: i)...]) { return (String(s[..<i]), p) }
        return (s, defaultPort)
    }

    public func runtime(for type: String) -> String { runtimes[type] ?? runtimes[""]! }
    public var devicesDirectory: String { home + "/devices" }
    public var runDirectory: String { home + "/run" }
    public var appsDirectory: String { home + "/apps" }
    public func socketPath(_ device: String) -> String { runDirectory + "/" + device + ".sock" }
    public func logPath(_ device: String) -> String { runDirectory + "/" + device + ".log" }
    public var simd: String { tree + "/.build/release/ycode-simd" }

    /// The launcher's environment and arguments for a run (`ycode-sim-serve start`'s).
    public func launch(device: String, type: String, app: String?, bundleID: String?, cold: Bool) -> (env: [String: String], args: [String]) {
        var env = ["YCODE_SIM_TREE": tree, "YCODE_SIM_DATA": home, "YCODE_SIM_SLOTS": String(slots),
                   "YCODE_SIM_LOCKS": locks ?? home + "/locks", "YCODE_SIM_GPU_CACHE": gpuCache ?? home + "/gpu-cache",
                   "YCODE_SIM_TIMEOUT_MS": String(hours * 3600 * 1000), "YCODE_WARM_BOOT": "1"]
        if let guestTools { env["YCODE_SIM_GUEST_TOOLS"] = guestTools }
        if cold { env["YCODE_WARM_FORCE_COLD"] = "1" }
        var args = ["--device", devicesDirectory + "/" + device, "--runtime-root", runtime(for: type), "--display-server", "unix:" + socketPath(device)]
        if type != "iphone-duo" && !type.isEmpty { args += ["--device-type", type] }
        if let app, let bundleID { args += ["--install-app", app, "--launch", bundleID, "--environment-overrides"] }
        return (env, args)
    }
}

/// A name a client may use for a device or app (one path component, no dots first).
public func isSafeName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 64 && !s.hasPrefix(".") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
}

public final class SimHostDevices: @unchecked Sendable {
    public let config: SimHostConfig
    public var log: @Sendable (String) -> Void = { _ in }
    private let lock = NSLock()
    private var running: [String: (pid: pid_t, app: String?, started: Date)] = [:]
    private var stopping: Set<String> = []

    struct Sidecar: Codable { var deviceType: String; var runtime: String }

    public init(config: SimHostConfig) { self.config = config }

    func sidecarURL(_ name: String) -> URL { URL(fileURLWithPath: config.devicesDirectory + "/" + name + ".json") }

    func sidecar(_ name: String) -> Sidecar? {
        FileManager.default.contents(atPath: sidecarURL(name).path).flatMap { try? JSONDecoder().decode(Sidecar.self, from: $0) }
    }

    public func deviceTypes() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.simd)
        p.arguments = ["--list-device-types"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    public func state(_ name: String) -> String {
        lock.withLock {
            if stopping.contains(name) { return "stopping" }
            guard running[name] != nil else { return "shutdown" }
            return FileManager.default.fileExists(atPath: config.socketPath(name)) ? "running" : "booting"
        }
    }

    public func list() -> [LinkDeviceInfo] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: config.devicesDirectory)) ?? []).filter {
            var dir: ObjCBool = false
            return isSafeName($0) && FileManager.default.fileExists(atPath: config.devicesDirectory + "/" + $0, isDirectory: &dir) && dir.boolValue
                && !$0.contains(".old.") && !$0.hasSuffix(".partial")
        }.sorted()
        return names.map { n in
            let s = sidecar(n)
            let app = lock.withLock { running[n]?.app }
            return LinkDeviceInfo(name: n, deviceType: s?.deviceType ?? "iphone-duo", runtime: s?.runtime ?? config.runtime(for: s?.deviceType ?? ""),
                                  state: state(n), app: app)
        }
    }

    /// Makes a device from the pristine copy of its type.
    public func create(_ name: String, type: String) throws {
        guard isSafeName(name) else { throw LinkError.refused("bad device name") }
        let dir = config.devicesDirectory + "/" + name
        guard !FileManager.default.fileExists(atPath: dir) else { throw LinkError.refused("\(name) exists") }
        guard let pristine = config.pristines[type] ?? (type == "iphone-duo" ? config.pristines[""] : nil) else {
            throw LinkError.refused("no pristine device for \(type) in the host configuration (YCODE_SIM_PRISTINE_\(type.uppercased().replacingOccurrences(of: "-", with: "_")))")
        }
        try FileManager.default.createDirectory(atPath: config.devicesDirectory, withIntermediateDirectories: true)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-a", pristine, dir + ".partial"]
        try cp.run()
        cp.waitUntilExit()
        guard cp.terminationStatus == 0, rename(dir + ".partial", dir) == 0 else { throw LinkError.refused("copying the pristine device failed") }
        try JSONEncoder().encode(Sidecar(deviceType: type, runtime: config.runtime(for: type))).write(to: sidecarURL(name))
        log("simhost: created \(name) (\(type)) from \(pristine)")
    }

    /// Boots a device (with an app: installs and launches it).
    public func start(_ name: String, app: String? = nil, bundleID: String? = nil, cold: Bool = false) throws {
        guard isSafeName(name), FileManager.default.fileExists(atPath: config.devicesDirectory + "/" + name) else {
            throw LinkError.refused("no device \(name)")
        }
        if lock.withLock({ running[name] != nil }) {
            guard app != nil else { return }  // already running
            stop(name)
        }
        let type = sidecar(name)?.deviceType ?? "iphone-duo"
        let (env, args) = config.launch(device: name, type: type, app: app.map { config.appsDirectory + "/" + $0 }, bundleID: bundleID, cold: cold)
        try FileManager.default.createDirectory(atPath: config.runDirectory, withIntermediateDirectories: true)
        let logPath = config.logPath(name)
        if FileManager.default.fileExists(atPath: logPath) { _ = rename(logPath, logPath + ".1") }
        FileManager.default.createFile(atPath: logPath, contents: nil)
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        // Its own session (POSIX_SPAWN_SETSID), so a last-resort kill of the group reaches ycode-simd too.
        let pid = try Spawn.run(config.launcher, args, environment: environment, output: logPath, newSession: true)
        lock.withLock { running[name] = (pid, app, Date()) }
        let t = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            guard let self else { return }
            self.lock.withLock {
                if self.running[name]?.pid == pid { self.running.removeValue(forKey: name) }
                self.stopping.remove(name)
            }
            self.log("simhost: \(name) ended (wait status \(status))")
        }
        t.start()
        log("simhost: started \(name) (pid \(pid))" + (app.map { " with \($0)" } ?? ""))
    }

    /// Stops a device (the launcher saves it), waiting up to 150 s.
    public func stop(_ name: String) {
        guard let pid = lock.withLock({ () -> pid_t? in
            guard let r = running[name] else { return nil }
            stopping.insert(name)
            return r.pid
        }) else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(150)
        while lock.withLock({ running[name]?.pid == pid }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        if lock.withLock({ running[name]?.pid == pid }) {
            kill(-pid, SIGKILL)
            while lock.withLock({ running[name]?.pid == pid }) { Thread.sleep(forTimeInterval: 0.1) }
        }
    }

    public func stopAll() {
        for n in lock.withLock({ Array(running.keys) }) { stop(n) }
    }

    public func logTail(_ name: String, lines: Int) -> [String] {
        guard let d = FileManager.default.contents(atPath: config.logPath(name)) else { return [] }
        return Array(String(decoding: d, as: UTF8.self).split(separator: "\n").suffix(max(1, min(lines, 2000))).map(String.init))
    }
}

/// posix_spawn with an output file and, optionally, a new session.
enum Spawn {
    static func run(_ exe: String, _ args: [String], environment: [String: String], output: String, newSession: Bool) throws -> pid_t {
        #if os(Linux)
        var fa = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #else
        var fa: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #endif
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // No blocked or ignored signals in the child: the launcher saves the device on SIGTERM.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var flags = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        #if os(Linux)
        if newSession { flags |= Int16(0x80) }  // POSIX_SPAWN_SETSID (glibc 2.26)
        #endif
        posix_spawnattr_setflags(&attr, flags)
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var pid: pid_t = 0
        let r = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
        guard r == 0 else { throw LinkError.refused("cannot start \(exe): \(String(cString: strerror(r)))") }
        return pid
    }
}
