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
    let prefixes: [DarwinFileSystem.Prefix]
    let hostLibraryPaths: Set<String>
    let cacheIndex: SharedCacheIndex
    let maxExits: Int
    let timeout: UInt64
    /// --repeat runs after the first: no per-image startup lines.
    var quietRuns = false

    init(_ options: Options) throws {
        guard let execArgument = options.execPath, let rootArgument = options.runtimeRoot else {
            die("--exec needs --runtime-root\n\(usage)", status: 64)
        }
        self.options = options
        trace = options.trace
        timeout = options.timeoutMilliseconds ?? 120_000
        maxExits = options.maxExits ?? 50_000_000
        execPath = absolutePath(execArgument)
        var root = absolutePath(rootArgument)
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        self.root = root
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

        // The per-run directory: guest /tmp lives in <run dir>/tmp.
        runDir = absolutePath(options.runDir ?? (NSTemporaryDirectory() + "/ycode-simd-\(getpid())"))
        try FileManager.default.createDirectory(atPath: runDir + "/tmp", withIntermediateDirectories: true)

        // The guest VFS (stage3-contract.md §8): the runtime root, read-only;
        // the --exec program's directory at the same guest path, read-only
        // (stage4b-contract.md §2 item 6: a probe spawns its own argv[0]).
        let execDirectory = (execPath as NSString).deletingLastPathComponent
        var prefixes = [DarwinFileSystem.Prefix(guestPath: root, hostPath: root, writable: false)]
        if !execDirectory.hasPrefix(root + "/") {
            prefixes.append(DarwinFileSystem.Prefix(guestPath: execDirectory, hostPath: execDirectory, writable: false))
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
        prefixes.append(DarwinFileSystem.Prefix(guestPath: "/tmp", hostPath: runDir + "/tmp", writable: true))
        self.prefixes = prefixes
        self.hostLibraryPaths = hostLibraryPaths
    }

    /// The root process's VFS: fresh descriptor table, console on fds 0–2.
    func makeRootFileSystem() -> DarwinFileSystem {
        DarwinFileSystem(prefixes: prefixes, console: { fd, bytes in writeFD(fd == 2 ? 2 : 1, bytes) })
    }

    /// The root process's spawn request (argv `[path]`, the simulator environment).
    var rootRequest: ProcessImageRequest {
        ProcessImageRequest(executablePath: execPath, hostExecutablePath: execPath, argv: [execPath],
                            envp: SimulatorEnvironment.make(runtimeRoot: root))
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

/// One run of the root process. Returns the host exit status once the root
/// process ended and the rest of the system was stopped.
func runRootProcess(_ config: ExecConfiguration, quietSummary: Bool = false) -> Int32 {
    let system = DarwinSystem()
    let launcher = VMMLauncher(config: config)
    system.launcher = launcher
    system.processExited = { [weak launcher] pid, status in launcher?.processExited(pid: pid, status: status) }

    let rootKernel: DarwinKernel
    do {
        rootKernel = try system.spawnInitialProcess(config.rootRequest, fileSystem: config.makeRootFileSystem())
    } catch {
        let detail = launcher.lastLaunchFailure ?? "\(config.execPath): \(error)"
        die("cannot start the root process: \(detail)", status: (error as? DarwinErrnoError) != nil ? 66 : 1)
    }
    _ = rootKernel
    let started = monotonicMilliseconds()

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
    if result.watchdog {
        watchdogReport = launcher.watchdogReport()
    }
    if !quietSummary || result.status != 0 { stderrLine("ycode-simd: \(result.message)") }
    if let watchdogReport { stderrLine(watchdogReport) }

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
    if stillAlive > 0 { abandonedLaunchers.append(launcher) }
    extraKernels.removeAll()
    return result.status
}

func runExec(_ options: Options) throws -> Never {
    let config = try ExecConfiguration(options)
    let count = options.repeatCount
    guard count > 1 else { exit(runRootProcess(config)) }

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
    exit(firstFailure ?? 0)
}
#endif
