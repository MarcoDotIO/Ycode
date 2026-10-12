// ycode-simd --exec: the host side of a simulated device (stage 4b,
// specs/simulator/stage4b-contract.md §2, §7). Builds the `DarwinSystem`,
// installs the VMM's `ProcessLauncher`, spawns the root process (pid 100),
// supervises until it exits (or `--timeout-ms`), stops what remains, and
// prints a per-process summary. `--repeat N` runs the root process N times
// in sequence and reports host threads, RSS, and open fds after each run
// (the VM-teardown leak check).

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor
import YcodeMachO

/// What every image of a run shares: the runtime, the shim, the host stubs,
/// the host libraries, and the root's VFS layout.
final class ExecConfiguration: @unchecked Sendable {
    let options: Options
    let trace: Bool
    let execPath: String
    let root: String
    let dyldSimPath: String
    let shim: [UInt8]
    let stubs: [UInt8]
    let runDir: String
    /// The default `--exec` run directory, when this run created it: removed
    /// at exit unless `--keep-run-dir` (stage4c-contract.md §9.3). An explicit
    /// `--run-dir` and the device directory are never removed.
    let runDirToRemove: String?
    let prefixes: [DarwinFileSystem.Prefix]
    let hostLibraryPaths: Set<String>
    let cacheIndex: SharedCacheIndex
    let maxExits: Int
    let timeout: UInt64
    /// --repeat runs after the first: no per-image startup lines.
    var quietRuns = false
    /// Device mode (stage 4c): the device layout.
    let device: DeviceLayout?
    /// The root program's argv and environment.
    let rootArguments: [String]
    let rootEnvironment: [String]

    init(_ options: Options) throws {
        guard let rootArgument = options.runtimeRoot, options.execPath != nil || options.devicePath != nil else {
            die("--exec and --device need --runtime-root\n\(usage)", status: 64)
        }
        if options.execPath != nil && options.devicePath != nil { die("--exec and --device exclude each other", status: 64) }
        self.options = options
        trace = options.trace
        timeout = options.timeoutMilliseconds ?? 120_000
        maxExits = options.maxExits ?? 50_000_000
        var root = absolutePath(rootArgument)
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        self.root = root
        if let devicePath = options.devicePath {
            // Device mode: the root process is RR/sbin/launchd_sim.
            var layout = DeviceLayout(dev: absolutePath(devicePath), runtimeRoot: root, udid: options.udid,
                                      jobPaths: options.jobPaths.map(absolutePath), runtimePaths: options.runtimePaths,
                                      oneshots: options.oneshots, runtimeJobs: options.runtimeJobs)
            layout.plistBoolOverrides = options.plistBoolOverrides
            layout.oneshotDelay = options.oneshotDelay
            // The guest's /var, /tmp, and /etc are links into /private: a
            // host path below them (or below /private/...) is unreachable
            // at its own guest path.
            for (what, path) in [("device directory", layout.dev), ("runtime root", root)] + layout.jobPaths.map({ ("job path", $0) }) {
                for shadowed in ["/tmp", "/var", "/etc", "/private/tmp", "/private/var", "/private/etc"]
                    where path == shadowed || path.hasPrefix(shadowed + "/") {
                    die("the \(what) \(path) is under \(shadowed), which the guest sees as its own; put it elsewhere", status: 64)
                }
            }
            do { try layout.prepare() } catch { die("cannot prepare the device directory \(layout.dev): \(error)", status: 66) }
            device = layout
            execPath = layout.launchdSimPath
            rootArguments = ["launchd_sim", layout.plistPath] + options.execArguments
            rootEnvironment = layout.launchdEnvironment(overrides: options.environment)
            stderrLine("ycode-simd: device \(layout.dev), UDID \(layout.udid); bootstrap plist \(layout.plistPath); TMP \(layout.tmpGuestPath) -> \(layout.tmpHostPath)")
        } else {
            device = nil
            execPath = absolutePath(options.execPath!)
            rootArguments = [execPath] + options.execArguments
            var env = SimulatorEnvironment.make(runtimeRoot: root)
            for pair in options.environment {
                let key = pair.prefix { $0 != "=" }
                env.removeAll { $0.hasPrefix(key + "=") }
                env.append(pair)
            }
            rootEnvironment = env
        }
        dyldSimPath = root + "/usr/lib/dyld_sim"
        cacheIndex = SharedCacheIndex(cachePath: root + "/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64")
        for path in [execPath, dyldSimPath] where access(path, R_OK) != 0 {
            die("cannot read \(path): \(String(cString: strerror(errno)))", status: 66)
        }
        shim = readFile(locateSimShimFile("shim.bin", explicit: options.shimPath))
        stubs = readFile(locateSimShimFile("host_stubs.bin", explicit: options.hostStubsPath))
        guard !shim.isEmpty, UInt64(shim.count) <= VMLayout.shimRegionSize else { die("bad shim image", status: 66) }
        guard UInt64(stubs.count) == VMLayout.hostPageSize else {
            die("host_stubs.bin is \(stubs.count) bytes, expected \(VMLayout.hostPageSize)", status: 66)
        }
        let retWord = stubs.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: Int(hostPageRetStubOffset), as: UInt32.self)) }
        guard retWord == a64Ret else { die("host_stubs.bin has no `ret` at +\(hex(hostPageRetStubOffset))", status: 66) }

        // The per-run directory: guest /tmp lives in <run dir>/tmp (in
        // device mode, DEV/data/tmp).
        runDir = device.map { $0.data } ?? absolutePath(options.runDir ?? (NSTemporaryDirectory() + "/ycode-simd-\(getpid())"))
        let usesDefaultRunDir = device == nil && options.runDir == nil
        let runDirExisted = FileManager.default.fileExists(atPath: runDir)
        try FileManager.default.createDirectory(atPath: runDir + "/tmp", withIntermediateDirectories: true)
        runDirToRemove = usesDefaultRunDir && !runDirExisted && !options.keepRunDir ? runDir : nil

        // The guest VFS (stage3-contract.md §8): the runtime root, read-only;
        // the --exec program's directory at the same guest path, read-only
        // (stage4b-contract.md §2 item 6: a probe spawns its own argv[0]).
        let execDirectory = (execPath as NSString).deletingLastPathComponent
        var prefixes = [DarwinFileSystem.Prefix(guestPath: root, hostPath: root, writable: false)]
        if !execDirectory.hasPrefix(root + "/") {
            prefixes.append(DarwinFileSystem.Prefix(guestPath: execDirectory, hostPath: execDirectory, writable: false))
        }
        if let device {
            // Device mode (stage4c-contract.md §2): DEV, /private/var/tmp (TMP is in it)
            // (and /var/tmp), /tmp and /private/tmp, all writable.
            prefixes.append(DarwinFileSystem.Prefix(guestPath: device.dev, hostPath: device.dev, writable: true))
            // On macOS a simulator process sees the host's /System, and the
            // runtime opens some framework bundles at their unrooted install
            // paths (CoreFoundation's own bundle: CFBundleGetInfoDictionary
            // dereferences NULL without it; level 3, our runs). Ycode serves
            // RR/System there, read-only.
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/System", hostPath: root + "/System", writable: false))
            // Job directories outside DEV and RR: read-only at their own path.
            for path in device.jobPaths where !(path == device.dev || path.hasPrefix(device.dev + "/") || path == root || path.hasPrefix(root + "/")) {
                prefixes.append(DarwinFileSystem.Prefix(guestPath: path, hostPath: path, writable: false))
            }
            // /var/tmp and /tmp reach these through the guest links.
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/private/var/tmp", hostPath: device.privateVarTmpHostPath, writable: true))
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/private/tmp", hostPath: device.data + "/tmp", writable: true))
        }
        // Ycode's host libraries (host-libraries.md §5): three read-only
        // single-file prefixes; every other /usr/lib/system path stays ENOENT.
        var hostLibraryPaths: Set<String> = []
        let (hostLibDir, hostLibTried) = locateHostLibraryDirectory(explicit: options.hostLibsPath)
        if let hostLibDir {
            for name in hostLibraryNames {
                let file = "\(hostLibDir)/libsystem_\(name).dylib"
                let guest = hostLibraryGuestPath(name)
                if access(file, R_OK) == 0 {
                    prefixes.append(DarwinFileSystem.Prefix(guestPath: guest, hostPath: file, writable: false))
                    hostLibraryPaths.insert(guest)
                    stderrLine("ycode-simd: host library \(guest) -> \(file)")
                } else {
                    stderrLine("ycode-simd: warning: host library \(file) is missing; \(guest) will be ENOENT")
                }
            }
        } else {
            stderrLine("ycode-simd: warning: no host-library directory (tried \(hostLibTried.joined(separator: ", "))); pass --host-libs")
        }
        if device == nil {
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/tmp", hostPath: runDir + "/tmp", writable: true))
        }
        self.prefixes = prefixes
        self.hostLibraryPaths = hostLibraryPaths
    }

    /// The root process's VFS: fresh descriptor table, console on fds 0–2.
    /// Device mode (launchd-sim.md §2.3): fds 0 and 1 are /dev/null, 2 the
    /// console, 3 /dev/console write-only; the cwd is /.
    func makeRootFileSystem() -> DarwinFileSystem {
        let fs = DarwinFileSystem(prefixes: prefixes, console: { fd, bytes in writeFD(fd == 2 ? 2 : 1, bytes) })
        if device != nil {
            fs.guestSymlinks = DarwinFileSystem.darwinRootSymlinks
            do {
                try fs.installDeviceModeStandardDescriptors()
            } catch {
                stderrLine("ycode-simd: warning: cannot set up fds 0, 1, 3 from /dev (\(error)); fds 0-2 stay the console")
            }
            fs.cwd = "/"
        }
        return fs
    }

    /// The root process's spawn request. `--exec`: argv `[path]` plus
    /// `--exec-args`, the simulator environment plus `--env`. Device mode:
    /// RR/sbin/launchd_sim, argv `["launchd_sim", plist]`.
    var rootRequest: ProcessImageRequest {
        ProcessImageRequest(executablePath: execPath, hostExecutablePath: execPath, argv: rootArguments,
                            envp: rootEnvironment)
    }
}

/// Host resource use, from /proc (the leak check).
struct HostStats: CustomStringConvertible {
    var threads = 0
    var rssKiB = 0
    var fds = 0

    static func current() -> HostStats {
        var stats = HostStats()
        if let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2 else { continue }
                if parts[0] == "Threads:" { stats.threads = Int(parts[1]) ?? 0 }
                if parts[0] == "VmRSS:" { stats.rssKiB = Int(parts[1]) ?? 0 }
            }
        }
        // Minus the directory stream's own fd.
        stats.fds = max(0, ((try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd"))?.count ?? 1) - 1)
        return stats
    }

    var description: String {
        let vms = VMCounters.shared.snapshot
        return "\(threads) host threads, RSS \(rssKiB / 1024) MiB, \(fds) fds; VMs created \(vms.created), destroyed \(vms.destroyed)"
    }
}

/// Launchers whose images did not all stop (threads stuck in the kernel):
/// kept alive for the rest of the host process, never freed under them.
nonisolated(unsafe) var abandonedLaunchers: [VMMLauncher] = []

/// The holding-tank variable (stage4c-contract.md §8.3; `…_FD_HACK` is not set).
let holdingTankKey = "XPC_SIMULATOR_HOLDING_TANK_HACK"

/// One run of the root process. Returns the host exit status once the root
/// process ended and the rest of the system was stopped.
func runRootProcess(_ config: ExecConfiguration, quietSummary: Bool = false) -> Int32 {
    let system = DarwinSystem()
    if config.trace || !config.options.tracePIDs.isEmpty || !config.options.traceNames.isEmpty {
        MachIPC.traceMessageStrings = true
    }
    let launcher = VMMLauncher(config: config)
    system.launcher = launcher
    system.processExited = { [weak launcher] pid, status in launcher?.processExited(pid: pid, status: status) }

    // Device mode (stage4c-contract.md §3): every task starts with a send
    // right to the host bootstrap port as its bootstrap special port; the
    // logging service receives on it.
    var bootstrapLogger: HostBootstrapLogger?
    if config.device != nil || config.options.hostBootstrap {
        system.mach.hostBootstrapIsDefault = true
        let logPath = config.device?.hostBootstrapLogPath ?? config.runDir + "/ycode-host-bootstrap.log"
        let logger = HostBootstrapLogger(host: system.hostTask, logPath: logPath,
                                         discard: config.options.debugBootstrapDiscard)
        do { try logger.start() } catch { die("cannot start the host bootstrap service: \(error)", status: 1) }
        bootstrapLogger = logger
    }

    let rootKernel: DarwinKernel
    do {
        // Device mode (stage4c-contract.md §8.3): launchd_sim needs the pid of
        // a child of its own in XPC_SIMULATOR_HOLDING_TANK_HACK; the process
        // layer makes an already-exited one (bootstrap-wire.md §5.4).
        rootKernel = try system.spawnInitialProcess(config.rootRequest, fileSystem: config.makeRootFileSystem(),
                                                    exitedChildEnvironmentKey: config.device != nil ? holdingTankKey : nil)
    } catch {
        let detail = launcher.lastLaunchFailure ?? "\(config.execPath): \(error)"
        die("cannot start the root process: \(detail)", status: (error as? DarwinErrnoError) != nil ? 66 : 1)
    }
    _ = rootKernel
    let started = monotonicMilliseconds()
    if config.options.debugThreadReport {
        DarwinKernel.recordKnoteHistory = true
        system.lock.slowHoldNanoseconds = 20_000_000
        system.lock.profileHolds = true
        system.lock.slowHoldReporter = { context, ns in
            let what = context.map { c in
                "pid \(c.kernel?.pid ?? -1) thread \(c.threadID) trap \(c.trapInProgress.map { String(Int64(bitPattern: $0.x16)) } ?? "?")"
            } ?? "a service thread"
            stderrLine("ycode-simd: monitor: kernel lock held \(ns / 1_000_000) ms by \(what)")
        }
        // Every 20 s: vCPUs stuck in one handler call for 20 s or more
        // (threads parked or waiting in the kernel show here too).
        let monitor = Thread { [weak launcher] in
            var lastHeld: UInt64 = 0, lastCount: UInt64 = 0, lastTime = monotonicMilliseconds()
            while let l = launcher {
                Thread.sleep(forTimeInterval: 20)
                let (held, count) = system.lock.withLock { (system.lock.totalHeldNanoseconds, system.lock.acquisitions) }
                let now = monotonicMilliseconds()
                stderrLine("ycode-simd: monitor: kernel lock busy \((held - lastHeld) / 10_000 / max(now - lastTime, 1))% "
                    + "over \(now - lastTime) ms, \(count - lastCount) acquisitions")
                (lastHeld, lastCount, lastTime) = (held, count, now)
                let profile = system.lock.withLock { system.lock.holdProfile }
                let top = profile.sorted { $0.value.ns > $1.value.ns }.prefix(12).map {
                    "\($0.key == Int64.min ? "service" : String($0.key)): \($0.value.ns / 1_000_000) ms/\($0.value.count)"
                }
                stderrLine("ycode-simd: monitor: lock hold by trap (cumulative): " + top.joined(separator: ", "))
                for line in l.longHandlerReport(ms: 20_000) { stderrLine("ycode-simd: monitor: " + line) }
                for line in l.longGuestRunReport(ms: 5_000) { stderrLine("ycode-simd: monitor: " + line) }
                for line in l.rootWorkerStates() { stderrLine("ycode-simd: monitor: root " + line) }
            }
        }
        monitor.start()
    }

    // Debug: independent extra images running next to the root (VMM
    // concurrency and teardown; they bypass the process layer).
    var extraKernels: [DarwinKernel] = []
    for i in 0..<config.options.debugExtraImages {
        let path = config.options.debugExtraExec.map(absolutePath) ?? config.execPath
        let kernel = DarwinKernel(fileSystem: config.makeRootFileSystem(), pid: Int32(900 + i))
        let request = ProcessImageRequest(executablePath: path, hostExecutablePath: path,
                                          argv: [path] + config.options.debugExtraArguments,
                                          envp: SimulatorEnvironment.make(runtimeRoot: config.root))
        do {
            try kernel.lock.withLock { _ = try launcher.launch(request, kernel: kernel) }
            extraKernels.append(kernel)
        } catch {
            stderrLine("ycode-simd: debug extra image \(i): \(error)")
        }
    }

    var result = launcher.superviseRoot(timeoutMilliseconds: config.timeout)
    if config.options.debugExtraWait, !result.watchdog {
        let left = launcher.superviseAll(deadline: started + config.timeout)
        if left > 0 { result = (71, "watchdog: \(left) images still running after \(config.timeout) ms", true) }
    }
    var watchdogReport: String?
    if result.watchdog, config.device != nil, launcher.waitStatus(of: rootPID) == nil {
        // Device mode (stage4c-contract.md §8.1): a device runs until it is
        // stopped; `--timeout-ms` is the length of the run. Reaching it with
        // launchd_sim alive is a normal end: exit 0, every process stopped.
        result = (0, "device run ended after \(config.timeout) ms (--timeout-ms); launchd_sim (pid \(rootPID)) was still running", false)
        if config.trace || config.options.debugThreadReport { watchdogReport = launcher.watchdogReport() }
    } else if result.watchdog {
        watchdogReport = launcher.watchdogReport()
    }
    if !quietSummary || result.status != 0 { stderrLine("ycode-simd: \(result.message)") }
    if let watchdogReport { stderrLine(watchdogReport) }
    if config.options.debugThreadReport {
        // Where every thread of every live process waits (before the stop).
        for p in system.allProcesses {
            guard let k = p.kernel else { continue }
            let lines = k.lock.withLock { k.blockedThreadReport() }
            if lines.isEmpty { continue }
            stderrLine("ycode-simd: blocked threads of pid \(p.pid) (\((p.executablePath as NSString).lastPathComponent)):")
            for line in lines { stderrLine("  " + line) }
        }
    }

    // The root ended: stop every other process (and a root image still
    // stopping), tear down what returns in time. The process layer ends
    // them first (SIGKILL: blocked threads wake, exit bookkeeping runs).
    var stillAlive = launcher.liveCount
    if !result.watchdog {
        if stillAlive > 0 { system.terminateAllProcesses() }
        stillAlive = launcher.stopAll(milliseconds: 1000)
    }

    // Summary: the root's first image as in stage 3/4a, then every image.
    let records = launcher.records
    let locked = !result.watchdog
    if let first = records.first {
        let line = first.finalSummary ?? first.image?.summary(locked: locked) ?? "no summary"
        if !quietSummary { stderrLine("ycode-simd: \(line)") }
        if config.trace, locked, let unimplemented = first.image?.unimplementedSummary() {
            stderrLine("ycode-simd: unimplemented: " + unimplemented)
        }
    }
    if records.count > 1 && !quietSummary {
        stderrLine("ycode-simd: processes (\(records.count) images):")
        for record in records {
            var line = "  pid \(record.pid) [image \(record.serial)] \((record.executable as NSString).lastPathComponent): \(record.endDescription)"
            if let w = launcher.waitStatus(of: record.pid) { line += "; process \(VMMLauncher.describe(waitStatus: w))" }
            if !record.tornDown { line += "; still running at host exit" }
            if let summary = record.finalSummary ?? record.image?.summary(locked: false) {
                line += "; " + summary.split(separator: ";").first.map(String.init)!
            }
            if let missing = record.finalUnimplemented { line += "; unimplemented: " + missing }
            stderrLine(line)
        }
    }
    if records.count > 1 && !quietSummary {
        // The process layer's table (zombies the root never reaped, processes
        // stopped at host exit).
        let table = system.allProcesses
        if !table.isEmpty {
            stderrLine("ycode-simd: process table at host exit: " + table.map { "\($0)" }.joined(separator: "; "))
        }
    }
    if !quietSummary {
        stderrLine("ycode-simd: host: \(HostStats.current())" + (stillAlive > 0 ? "; \(stillAlive) images not torn down" : ""))
    }
    if let bootstrapLogger {
        bootstrapLogger.stop()
        if stillAlive == 0 { system.hostTask.shutdown() }
    }
    if let device = config.device, !quietSummary {
        let log = device.tmpHostPath + "/launchd.log"
        let size = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? nil
        stderrLine("ycode-simd: TMP/launchd.log (\(log)): " + (size.map { "\($0) bytes" } ?? "absent"))
        for index in device.oneshots.indices {
            for err in [false, true] {
                let path = device.oneshotOutputHostPath(index, err: err)
                guard let data = FileManager.default.contents(atPath: path) else {
                    stderrLine("ycode-simd: \(device.oneshotLabel(index)) \(err ? "stderr" : "stdout"): no file \(path)")
                    continue
                }
                stderrLine("ycode-simd: \(device.oneshotLabel(index)) \(err ? "stderr" : "stdout") (\(path), \(data.count) bytes)"
                    + (data.isEmpty ? "" : ":\n" + String(decoding: data, as: UTF8.self)))
            }
        }
    }
    if stillAlive > 0 { abandonedLaunchers.append(launcher) }
    extraKernels.removeAll()
    return result.status
}

/// Removes the run directory this run created (stage4c-contract.md §9.3).
func removeRunDirectory(_ config: ExecConfiguration) {
    guard let path = config.runDirToRemove else { return }
    do {
        try FileManager.default.removeItem(atPath: path)
    } catch {
        stderrLine("ycode-simd: warning: cannot remove the run directory \(path): \(error)")
    }
}

func runExec(_ options: Options) throws -> Never {
    let config = try ExecConfiguration(options)
    let count = options.repeatCount
    guard count > 1 else {
        let status = runRootProcess(config)
        removeRunDirectory(config)
        exit(status)
    }

    // --repeat: the leak check.
    var firstFailure: Int32?
    var afterFirst = HostStats()
    let before = HostStats.current()
    stderrLine("ycode-simd: repeat: before the first run: \(before)")
    for run in 1...count {
        config.quietRuns = run > 1 && !config.trace
        let status = runRootProcess(config, quietSummary: config.quietRuns)
        if status != 0 && firstFailure == nil { firstFailure = status }
        let stats = HostStats.current()
        if run == 1 { afterFirst = stats }
        if run == 1 || run == count || run % 10 == 0 || status != 0 {
            stderrLine("ycode-simd: repeat \(run)/\(count): status \(status); \(stats)")
        }
    }
    let after = HostStats.current()
    let vms = VMCounters.shared.snapshot
    stderrLine("ycode-simd: repeat summary: \(count) runs, \(firstFailure == nil ? "all exited 0" : "first failure status \(firstFailure!)"); "
        + "after run 1 -> after run \(count): host threads \(afterFirst.threads) -> \(after.threads), "
        + "RSS \(afterFirst.rssKiB / 1024) -> \(after.rssKiB / 1024) MiB, fds \(afterFirst.fds) -> \(after.fds); "
        + "VMs live \(vms.created - vms.destroyed)")
    // The verdict: no thread, fd, or VM growth; RSS may take one step of up
    // to 8 MiB after run 1 (the shared read-only file window warming up).
    let leakFree = after.threads == afterFirst.threads && after.fds == afterFirst.fds && vms.created == vms.destroyed
        && after.rssKiB - afterFirst.rssKiB <= 8 * 1024
    stderrLine("ycode-simd: repeat leak check: \(leakFree ? "ok" : "FAILED") "
        + "(threads, fds and VMs flat; RSS growth \((after.rssKiB - afterFirst.rssKiB) / 1024) MiB of 8 allowed)")
    removeRunDirectory(config)
    exit(firstFailure ?? 0)
}
#endif
