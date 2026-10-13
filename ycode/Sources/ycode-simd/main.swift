// ycode-simd: the Ycode micro-VM monitor.
//
//   ycode-simd --exec <macho> --runtime-root <dir> [--run-dir <dir>] [--trace]
//              [--timeout-ms N] [--max-exits N] [--shim <shim.bin>]
//              [--host-stubs <host_stubs.bin>] [--host-libs <dir>] [--repeat N]
//              [--env K=V]... [--exec-args <arg>...]
//   ycode-simd --device <dir> --runtime-root <dir> [--udid <UDID>] [--job-path <dir>]...
//              [--oneshot "/guest/program arg..."]... [--runtime-job <label>]...
//              [--env K=V]... [--trace] [--keep-going] [--timeout-ms N] [--exec-args <arg>...]
//   ycode-simd --shim <shim.bin> --el0 <el0.bin> [--trace] [--timeout-ms N] [--max-exits N]
//   ycode-simd --kvm-smoke
//
// Stage 2 (`--el0`): boots the EL1 shim in a KVM vCPU with the page tables,
// boot info, and EL0 image laid out as in specs/simulator/vm-shim-protocol.md,
// then serves the shim's doorbell exits with DarwinTrapDispatcher.
//
// Stage 3a (`--exec`): builds a Darwin process image as in
// specs/simulator/stage3-contract.md (main executable and dyld_sim mapped
// with YcodeMachO, the Ycode host page, the kernel argument block, the
// commpage), boots it at the host page's `_ycode_launch`, and serves traps
// with the YcodeDarwinKernel dispatcher.
//
// Stage 3a-ii (specs/simulator/host-libraries.md): Ycode's three host
// libraries (`--host-libs`, default `SimHostLibs/out` next to the package)
// appear in the guest as `/usr/lib/system/libsystem_{kernel,platform,pthread}.dylib`,
// and the VMM builds the main thread's pthread/TSD block before boot
// (TPIDRRO_EL0 = block + 224).
//
// Stage 4b (specs/simulator/stage4b-contract.md §2, §7): every guest process
// of the device runs in this one host process, one KVM VM per image
// (`ImageLauncher.swift`, the kernel's `ProcessLauncher`), supervised by
// `ExecHost.swift`. The host exits when the root process (pid 100, the
// `--exec` program) exits. `--repeat N` (debug) runs the root process N
// times in sequence in one host process and reports host threads, RSS, and
// open fds, to prove that VM teardown leaks nothing.
//
// Stage 4c (specs/simulator/stage4c-contract.md §2, §3; `DeviceMode.swift`):
// `--device` boots a simulated device: Ycode writes the device directory and
// the bootstrap plist, starts the runtime's `launchd_sim` as the root
// process with the host bootstrap port (a port of the VMM's host task) as
// its bootstrap special port, and logs every message sent to that port.
// `--exec-args` takes every remaining argument as more argv for the root
// program; `--env K=V` adds or replaces an environment variable.
//
// Stage 4c-iii (stage4c-contract.md §9), stage 7 (stage7-contract.md §3.2):
// `--oneshot "/bin/launchctl print system"` runs the program once as a
// one-shot of launchd_sim's control channel (704 spawn, 705 waitpid;
// launch-sim-control.md §3.6), with stdout/stderr as fileports of
// DEV/data/tmp/ycode-oneshot-<n>.{out,err}. A program path inside DEV or RR
// is used as is; any other absolute path is under RR. The outputs and exit
// statuses are printed at the end of the run. `--runtime-job <label>` copies
// RR's `<label>.plist` (LaunchDaemons, LaunchAngels, Developer LaunchDaemons)
// into DEV/ycode-jobs, which is rebuilt on every boot and appended to the job
// paths. `--job-path` directories outside DEV and RR are served read-only at
// their own guest path.
//
// The control channel: right after the 708 → 808 exchange the host binds the
// session (700) with a port it keeps; the bootstrap plist says
// `RequireDomainBinding = true`. At the end of a device run the host destroys
// the session port and launchd_sim shuts the guest down and exits 0
// (launch-sim-control.md §3.1); `--debug-no-session-end` keeps the old end
// (every process is killed at --timeout-ms).
//
// Stage 7 (stage7-contract.md §3.2 item 3; app-install-launch.md §4.6):
// `--install-app <host .app>` copies the bundle into DEV/data/tmp/ycode-apps
// and installs it with the guest helper `ylaunch install` (InstallCoordination)
// run as a one-shot; `--launch <bundle id>` then opens it with `ylaunch open`
// (FrontBoardServices, debug options) with stdout/stderr in
// /tmp/ycode-app.{out,err} (DEV/data/tmp), plus `--app-arg`/`--app-env`.
// Both outputs are printed at the end. `ylaunch` is taken from
// `--guest-tools <dir>` (default: <shim dir>/guest-tests/stage7, as built by
// SimShim/guest-tests/build-stage7.sh) and copied to DEV/data/tmp/ycode-tools.
//
// SIMULATOR_FRAMEBUFFER_FRAMEWORK names Ycode's headless SimFramebuffer
// library (SimGuestFrameworks/build.sh; specs/simulator/simframebuffer.md),
// copied to DEV/ycode-frameworks: `--framebuffer-library <binary>`, default
// SimGuestFrameworks/out/SimFramebuffer.framework/SimFramebuffer next to the
// shim's SimShim directory when it exists; `none` leaves the variable empty.
// The VMM serves com.apple.IOSurface.Remote (iosurface-remote.md), registered
// with 701 before any job starts. `--screenshot <path.png>` writes the
// presented display buffer as a PNG at the end of the run (before the
// session ends); `--screenshot-at S` (repeatable) also at S seconds, as
// <path>-<S>s.png.
//
// Stage 6 (stage6-contract.md §1): `--runtime-paths` puts CoreSimulator's
// four job directories first in `Paths` (RR/System/Library/LaunchDaemons,
// RR/System/Library/LaunchAngels, RR/Developer/Library/LaunchDaemons,
// DEV/data/Library/LaunchDaemons; launchd-sim.md §4.1); `--oneshot-delay S`
// makes the one-shots start S seconds after the bind, e.g. a `launchctl
// list` near the end of a boot.
//
// `--debug-plist-bool KEY=true|false` replaces a top-level boolean of the
// bootstrap plist (Ycode writes `RequireDomainBinding` false: it has no
// session bind yet, and with true launchd_sim defers every `system` job).
//
// The default `--exec` run directory (under the host's temporary directory)
// is removed at exit unless `--keep-run-dir`; an explicit `--run-dir` is kept.
//
// `--keep-going` (with --trace) logs unimplemented traps and library
// functions but resumes the guest instead of exiting 72/73.
//
// Exit status: the root process's exit status (128 + signal when a signal
// ended it). Device mode: `--timeout-ms` (default 120 000) is the length of
// the run, and reaching it while launchd_sim still runs exits 0 (every guest
// process is stopped first); launchd_sim exiting earlier gives its status as
// above. Otherwise: 70 for a fatal guest trap; 71 for an
// unexpected VM exit or the watchdog; 72 for the first unimplemented trap in
// --trace mode; 73 for the first unimplemented host-library function in
// --trace mode; 134 for abort_with_payload; 64 for bad usage; 66 for
// unreadable input; 1 for host (KVM) failures.

import YcodeDarwinABI
import YcodeHypervisor

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinKernel
import YcodeMachO

let usage = """
    usage: ycode-simd --exec <macho> --runtime-root <dir> [--run-dir <dir> | --keep-run-dir] [--trace]
                      [--timeout-ms N] [--max-exits N] [--shim <shim.bin>] [--host-stubs <host_stubs.bin>]
                      [--host-libs <dir>] [--keep-going] [--libfunc-return <name>=<value>[,...]] [--repeat N]
                      [--env K=V]... [--host-bootstrap [--debug-bootstrap-discard]] [--exec-args <arg>...]
           ycode-simd --device <dir> --runtime-root <dir> [--udid <UDID>] [--job-path <dir>]... [--env K=V]...
                      [--runtime-paths] [--oneshot "/guest/program arg..."]... [--oneshot-delay S] [--runtime-job <label>]...
                      [--install-app <host .app>] [--launch <bundle id> [--app-arg A]... [--app-env K=V]...]
                      [--guest-tools <dir with ylaunch>] [--framebuffer-library <SimFramebuffer binary> | none]
                      [--screenshot <path.png> [--screenshot-at S]...] [--skip-first-boot-migration]
                      [--metal-translator <ycode-airc>] (default: $YCODE_AIRC, next to ycode-simd, $PATH)
                      [--gpu-cache-dir <dir>] (Vulkan pipeline cache and ycode-airc translation cache)
                      [--debug-plist-bool KEY=true|false]... [--debug-no-session-end]
                      [--trace] [--keep-going] [--timeout-ms N] [--host-libs <dir>] [--debug-bootstrap-discard]
                      [--exec-args <arg>...]
                      [--debug-extra-images N [--debug-extra-exec <macho>] [--debug-extra-arg A]... [--debug-extra-wait]]
           ycode-simd --shim <shim.bin> --el0 <el0.bin> [--trace] [--timeout-ms N] [--max-exits N]
                      [--vcpus N [--rounds R]]
           ycode-simd --kvm-smoke
    """

struct Options {
    var shimPath: String?
    var el0Path: String?
    var execPath: String?
    var runtimeRoot: String?
    var runDir: String?
    /// Keep the default run directory at exit (it is removed otherwise).
    var keepRunDir = false
    var hostStubsPath: String?
    var hostLibsPath: String?
    var trace = false
    /// With --trace: log unimplemented traps and library functions, but resume.
    var keepGoing = false
    /// Debug aid: unimplemented host-library functions whose call the VMM
    /// completes itself (x0 = value, return to LR), to look past them.
    var libfuncReturns: [String: UInt64] = [:]
    var kvmSmoke = false
    /// Stage-2 multi-vCPU check: run the self-test on N vCPUs at once, R rounds.
    var vcpus: Int?
    var rounds = 2
    var timeoutMilliseconds: UInt64?
    var maxExits: Int?
    /// Stage 4c device mode: the device directory, its UDID, job directories.
    var devicePath: String?
    var udid: String?
    var jobPaths: [String] = []
    /// Device mode: one-shot programs (argv split on spaces, run through the
    /// control channel) and runtime job plists by label (in DEV/ycode-jobs).
    var oneshots: [[String]] = []
    var runtimeJobs: [String] = []
    /// Device mode: CoreSimulator's four job directories (launchd-sim.md §4.1).
    var runtimePaths = false
    /// Device mode: one-shots start this many seconds after the bind.
    var oneshotDelay: Int?
    /// Debug: at the end of a device run, kill every process instead of
    /// ending the control session (launchd_sim's clean shutdown).
    var debugNoSessionEnd = false
    /// PNG captures of the display (`--screenshot PATH`, at the end of the
    /// run; `--screenshot-at S`, repeatable: PATH with `-<S>s` before `.png`).
    var screenshotPath: String?
    /// Record the first-boot data migration as done before the boot.
    var skipFirstBootMigration = false
    var screenshotTimes: [Int] = []
    /// Debug: start no Metal host service.
    var debugNoMetal = false
    /// The shader translator (`ycode-airc`) for the Metal back end; nil:
    /// $YCODE_AIRC, next to this executable, or on $PATH.
    var metalTranslator: String?
    /// Persistent GPU caches: <dir>/vulkan-pipelines.bin
    /// ($YCODE_VULKAN_PIPELINE_CACHE) and <dir>/airc ($YCODE_AIRC_CACHE).
    var gpuCacheDirectory: String?
    /// Debug: offer no host services (IOSurface) to the guest.
    var debugNoHostServices = false
    /// Stage 7: install a host `.app`, launch a bundle id, with these
    /// arguments and environment; `ylaunch` comes from `guestTools`.
    var installApp: String?
    var launchBundleID: String?
    var appArguments: [String] = []
    var appEnvironment: [String] = []
    var guestTools: String?
    /// The headless SimFramebuffer library (`--framebuffer-library`; "none" = empty variable).
    var framebufferLibrary: String?
    /// Debug: the identity (pid, uid, gid) the host task's messages carry.
    var debugHostIdentity: (pid: Int32, uid: UInt32, gid: UInt32)?
    /// Debug: at the end of a device run, report every image's vCPUs
    /// (running, parked, blocked in which trap), as --trace does.
    var debugThreadReport = false
    /// Debug: trace only these pids (as --trace --keep-going would).
    var tracePIDs: Set<Int32> = []
    /// Debug: trace every image of these executables (file name).
    var traceNames: Set<String> = []
    /// Debug: replace top-level booleans of the bootstrap plist.
    var plistBoolOverrides: [String: Bool] = [:]
    /// Debug: the logging host bootstrap service drops requests (instead of
    /// keeping them unanswered).
    var debugBootstrapDiscard = false
    /// --exec mode: use the host bootstrap port and its logging service as
    /// in device mode (the log goes to <run dir>/ycode-host-bootstrap.log).
    var hostBootstrap = false
    /// More argv for the root program (after argv[0], or after the plist path).
    var execArguments: [String] = []
    /// Environment additions/overrides for the root program ("K=V").
    var environment: [String] = []
    /// Debug: run the --exec root process this many times in sequence.
    var repeatCount = 1
    /// Debug (VMM concurrency): also launch this many independent images
    /// (pids 900...; each its own one-process kernel, outside the root's
    /// process table) of `--debug-extra-exec` (default: the --exec program).
    var debugExtraImages = 0
    var debugExtraExec: String?
    /// Debug: arguments after argv[0] for the extra images.
    var debugExtraArguments: [String] = []
    /// Debug: the host waits for the extra images instead of stopping them
    /// when the root process exits.
    var debugExtraWait = false
}

/// Writes all of `text` to a file descriptor, unbuffered (guest output and the
/// trap log interleave in order).
func writeFD(_ fd: Int32, _ text: String) { writeFD(fd, Array(text.utf8)) }

func writeFD(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { Glibc.write(fd, $0.baseAddress! + offset, $0.count - offset) }
        if n < 0 {
            if errno == EINTR { continue }
            return
        }
        offset += n
    }
}

func stderrLine(_ text: String) { writeFD(2, text + "\n") }

func die(_ message: String, status: Int32) -> Never {
    stderrLine("ycode-simd: \(message)")
    exit(status)
}

func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let value = iterator.next() else { die("\(flag) needs a value\n\(usage)", status: 64) }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "--shim": options.shimPath = value(for: argument)
        case "--el0": options.el0Path = value(for: argument)
        case "--exec": options.execPath = value(for: argument)
        case "--runtime-root": options.runtimeRoot = value(for: argument)
        case "--run-dir": options.runDir = value(for: argument)
        case "--keep-run-dir": options.keepRunDir = true
        case "--host-stubs": options.hostStubsPath = value(for: argument)
        case "--host-libs": options.hostLibsPath = value(for: argument)
        case "--trace": options.trace = true
        case "--keep-going": options.keepGoing = true
        case "--libfunc-return":
            for item in value(for: argument).split(separator: ",") {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { die("--libfunc-return needs name=value", status: 64) }
                let text = parts[1].hasPrefix("0x") ? String(parts[1].dropFirst(2)) : parts[1]
                guard let v = parts[1].hasPrefix("-") ? Int64(parts[1]).map({ UInt64(bitPattern: $0) })
                        : UInt64(text, radix: parts[1].hasPrefix("0x") ? 16 : 10) else {
                    die("--libfunc-return: bad value '\(parts[1])'", status: 64)
                }
                options.libfuncReturns[parts[0]] = v
            }
        case "--kvm-smoke": options.kvmSmoke = true
        case "--vcpus":
            guard let n = Int(value(for: argument)), n > 0, n <= VCPUSlots.count else { die("--vcpus needs 1...\(VCPUSlots.count)", status: 64) }
            options.vcpus = n
        case "--rounds":
            guard let n = Int(value(for: argument)), n > 0 else { die("--rounds needs a positive integer", status: 64) }
            options.rounds = n
        case "--timeout-ms":
            guard let n = UInt64(value(for: argument)), n > 0 else { die("--timeout-ms needs a positive integer", status: 64) }
            options.timeoutMilliseconds = n
        case "--repeat":
            guard let n = Int(value(for: argument)), n > 0 else { die("--repeat needs a positive integer", status: 64) }
            options.repeatCount = n
        case "--debug-extra-images":
            guard let n = Int(value(for: argument)), n >= 0, n <= 64 else { die("--debug-extra-images needs 0...64", status: 64) }
            options.debugExtraImages = n
        case "--debug-extra-exec": options.debugExtraExec = value(for: argument)
        case "--debug-extra-wait": options.debugExtraWait = true
        case "--debug-extra-arg": options.debugExtraArguments.append(value(for: argument))
        case "--device": options.devicePath = value(for: argument)
        case "--udid": options.udid = value(for: argument)
        case "--debug-bootstrap-discard": options.debugBootstrapDiscard = true
        case "--host-bootstrap": options.hostBootstrap = true
        case "--job-path": options.jobPaths.append(value(for: argument))
        case "--oneshot":
            let argv = value(for: argument).split(separator: " ").map(String.init)
            guard let program = argv.first, program.hasPrefix("/") else { die("--oneshot needs \"/guest/program [arg]...\"", status: 64) }
            options.oneshots.append(argv)
        case "--runtime-job": options.runtimeJobs.append(value(for: argument))
        case "--runtime-paths": options.runtimePaths = true
        case "--debug-thread-report": options.debugThreadReport = true
        case "--debug-no-session-end": options.debugNoSessionEnd = true
        case "--debug-no-host-services": options.debugNoHostServices = true
        case "--debug-no-metal": options.debugNoMetal = true
        case "--metal-translator": options.metalTranslator = value(for: argument)
        case "--gpu-cache-dir": options.gpuCacheDirectory = value(for: argument)
        case "--screenshot": options.screenshotPath = value(for: argument)
        case "--skip-first-boot-migration": options.skipFirstBootMigration = true
        case "--screenshot-at":
            guard let n = Int(value(for: argument)), n > 0 else { die("--screenshot-at needs seconds > 0", status: 64) }
            options.screenshotTimes.append(n)
        case "--install-app": options.installApp = value(for: argument)
        case "--launch": options.launchBundleID = value(for: argument)
        case "--app-arg": options.appArguments.append(value(for: argument))
        case "--app-env":
            let pair = value(for: argument)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { die("--app-env needs K=V", status: 64) }
            options.appEnvironment.append(pair)
        case "--guest-tools": options.guestTools = value(for: argument)
        case "--framebuffer-library": options.framebufferLibrary = value(for: argument)
        case "--debug-host-identity":
            let parts = value(for: argument).split(separator: ":").compactMap { Int64($0) }
            guard parts.count == 3 else { die("--debug-host-identity needs PID:UID:GID", status: 64) }
            options.debugHostIdentity = (Int32(parts[0]), UInt32(parts[1]), UInt32(parts[2]))
        case "--trace-name": options.traceNames.insert(value(for: argument))
        case "--trace-pid":
            guard let n = Int32(value(for: argument)) else { die("--trace-pid needs a pid", status: 64) }
            options.tracePIDs.insert(n)
        case "--oneshot-delay":
            guard let n = Int(value(for: argument)), n > 0 else { die("--oneshot-delay needs seconds > 0", status: 64) }
            options.oneshotDelay = n
        case "--debug-plist-bool":
            let parts = value(for: argument).split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let flag = Bool(parts[1]) else { die("--debug-plist-bool needs KEY=true|false", status: 64) }
            options.plistBoolOverrides[parts[0]] = flag
        case "--env":
            let pair = value(for: argument)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { die("--env needs K=V", status: 64) }
            options.environment.append(pair)
        case "--exec-args":
            while let rest = iterator.next() { options.execArguments.append(rest) }
        case "--max-exits":
            guard let n = Int(value(for: argument)), n > 0 else { die("--max-exits needs a positive integer", status: 64) }
            options.maxExits = n
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            die("unknown argument '\(argument)'\n\(usage)", status: 64)
        }
    }
    return options
}

func readFile(_ path: String) -> [UInt8] {
    guard let file = fopen(path, "rb") else { die("cannot open \(path): \(String(cString: strerror(errno)))", status: 66) }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = fread(&buffer, 1, buffer.count, file)
        if n > 0 { bytes.append(contentsOf: buffer[0..<n]) }
        if n < buffer.count {
            if ferror(file) != 0 { die("cannot read \(path)", status: 66) }
            break
        }
    }
    return bytes
}

/// Prints the vCPU state after an unexpected exit.
func dumpVCPU(_ vcpu: VCPU) {
    var parts: [String] = []
    func add(_ name: String, _ read: () throws -> UInt64) {
        if let value = try? read() { parts.append("\(name)=\(hex(value))") } else { parts.append("\(name)=?") }
    }
    add("pc") { try vcpu.get(.pc) }
    add("pstate") { try vcpu.get(.pstate) }
    add("sp_el1") { try vcpu.get(.spEL1) }
    add("elr_el1") { try vcpu.get(.elrEL1) }
    add("spsr_el1") { try vcpu.get(.spsrEL1) }
    add("esr_el1") { try vcpu.get(.esrEL1) }
    add("far_el1") { try vcpu.get(.farEL1) }
    add("vbar_el1") { try vcpu.get(.vbarEL1) }
    add("sctlr_el1") { try vcpu.get(.sctlrEL1) }
    stderrLine("ycode-simd: vCPU state: " + parts.joined(separator: " "))
    if let esr = try? vcpu.get(.esrEL1) {
        stderrLine("ycode-simd: ESR_EL1 EC=\(hex((esr >> 26) & 0x3F)) IL=\((esr >> 25) & 1) ISS=\(hex(esr & 0x1FF_FFFF))")
    }
}

// MARK: - Stage 2

/// The value the VMM puts in TPIDRRO_EL0 and passes to the self-test in x0.
let initialTPIDRRO: UInt64 = 0x0000_0001_5943_0000

func runStage2(_ options: Options) throws -> Never {
    guard let shimPath = options.shimPath, let el0Path = options.el0Path else { die("missing --shim or --el0\n\(usage)", status: 64) }
    let timeout = options.timeoutMilliseconds ?? 10_000
    let maxExits = options.maxExits ?? 100_000
    let shim = readFile(shimPath)
    let el0Image = readFile(el0Path)
    guard !shim.isEmpty, UInt64(shim.count) <= VMLayout.shimRegionSize else {
        die("shim image is empty or larger than \(VMLayout.shimRegionSize) bytes", status: 66)
    }
    guard !el0Image.isEmpty else { die("EL0 image is empty", status: 66) }

    let vm = try VirtualMachine(ramGPA: VMLayout.ramGPA, ramSize: Int(VMLayout.ramSize))

    // Stage-1 tables (§3): EL1 identity regions, then EL0 regions backed by
    // consecutive pages of the EL0 pool.
    var tables = PageTableBuilder(tableArenaGPA: VMLayout.pageTableArenaGPA, tableArenaSize: Int(VMLayout.pageTableArenaSize))
    for region in VMLayout.el1Regions { try tables.mapIdentity(region) }
    // With --vcpus the vCPU slots (stage4a-contract.md §4) take the start of
    // the stage-2 EL0 pool; the EL0 pages follow them.
    let multi = options.vcpus != nil
    if multi { try tables.mapIdentity(VCPUSlots.region) }
    var nextPoolGPA = multi ? VCPUSlots.baseGPA + VCPUSlots.regionSize : VMLayout.el0PoolGPA
    for region in VMLayout.selfTestRegions(imageSize: UInt64(el0Image.count)) {
        guard nextPoolGPA + region.size <= VMLayout.el0PoolGPA + VMLayout.el0PoolSize else {
            die("EL0 pool exhausted mapping \(region.name)", status: 66)
        }
        try tables.map(va: region.va, pa: nextPoolGPA, size: region.size, attributes: region.attributes)
        if options.trace {
            stderrLine("ycode-simd: map \(region.name) va \(hex(region.va))-\(hex(region.end)) -> pa \(hex(nextPoolGPA)) \(region.attributes)")
        }
        nextPoolGPA += region.size
    }
    for table in tables.tables { try vm.write(gpa: table.gpa, bytes: table.bytes) }

    // Images.
    try vm.write(gpa: VMLayout.shimGPA, bytes: shim)
    let loader = TranslatedGuestMemory(vm: vm, pageTables: tables, enforceEL0Permissions: false)
    try loader.write(va: VMLayout.selfTestImageVA, bytes: el0Image)

    // Boot info (§4).
    let bootInfo = BootInfo(
        ttbr0EL1: tables.rootGPA,
        el0EntryPC: VMLayout.selfTestImageVA,
        el0InitialSP: VMLayout.el0StackTop,
        trapFrameAddress: VMLayout.trapFrameGPA,
        doorbellAddress: VMLayout.doorbellGPA,
        tpidrroEL0: initialTPIDRRO,
        tpidrEL0: 0,
        el0Registers: [initialTPIDRRO, UInt64(VMLayout.guestPID), 0, 0, 0, 0, 0, 0],
        el1StackTop: VMLayout.el1StackTop)
    try vm.write(gpa: VMLayout.bootInfoGPA, bytes: bootInfo.encoded())
    if options.trace {
        stderrLine("ycode-simd: \(tables.tables.count) table pages, root \(hex(tables.rootGPA)); shim \(shim.count) bytes; EL0 image \(el0Image.count) bytes")
    }

    if let count = options.vcpus {
        try runStage2Pool(options, vm: vm, tables: tables, shimSize: shim.count, count: count, timeout: timeout, maxExits: maxExits)
    }

    // vCPU reset state.
    let vcpu = try vm.makeVCPU()
    try vcpu.set(.pc, VMLayout.shimEntryGPA)
    try vcpu.set(.pstate, VMLayout.el1BootPSTATE)
    try vcpu.set(.x(0), VMLayout.bootInfoGPA)

    let memory = TranslatedGuestMemory(vm: vm, pageTables: tables)
    var dispatcher = DarwinTrapDispatcher(
        pid: VMLayout.guestPID,
        stdout: { text in writeFD(1, text) },
        stderr: { text in writeFD(2, text) },
        log: { line in stderrLine("[trap] " + line) })

    try Watchdog.arm(milliseconds: timeout)
    while true {
        guard vcpu.exitCount < maxExits else {
            dumpVCPU(vcpu)
            die("guest exceeded \(maxExits) VM exits", status: 71)
        }
        let exit = try vcpu.run()
        if options.trace { stderrLine("ycode-simd: exit #\(vcpu.exitCount): \(exit)") }

        switch exit {
        case let .mmio(.write, address, frameAddress, 8) where address == VMLayout.doorbellGPA:
            guard frameAddress == VMLayout.trapFrameGPA else {
                dumpVCPU(vcpu)
                die("doorbell carried frame address \(hex(frameAddress)), expected \(hex(VMLayout.trapFrameGPA))", status: 71)
            }
            var frame = try TrapFrame(decoding: vm.read(gpa: frameAddress, count: TrapFrame.byteCount))
            let outcome = dispatcher.handle(&frame, memory: memory)
            switch outcome {
            case .resume:
                try vm.write(gpa: frameAddress, bytes: frame.encoded())
            case let .exit(status):
                if options.trace { stderrLine("ycode-simd: guest exited with status \(status) after \(vcpu.exitCount) VM exits") }
                Glibc.exit(status)
            case let .fatal(message):
                // The dispatcher's message carries the decoded ESR and the frame dump.
                die("fatal guest trap:\n\(message)", status: VMLayout.fatalExitStatus)
            }
        case .watchdog:
            dumpVCPU(vcpu)
            die("watchdog: guest still running after \(timeout) ms", status: 71)
        default:
            dumpVCPU(vcpu)
            die("unexpected VM exit: \(exit)", status: 71)
        }
    }
}

/// `--vcpus N`: the self-test runs on N vCPUs at once (one host thread
/// each), `--rounds` times. A thread's `exit(0)` parks its vCPU; later
/// rounds reuse the parked vCPUs. Exercises the stage-4a pool: lazy vCPU
/// creation while others run, per-vCPU slots, concurrent traps, and reuse.
func runStage2Pool(_ options: Options, vm: VirtualMachine, tables: PageTableBuilder, shimSize: Int,
                   count: Int, timeout: UInt64, maxExits: Int) throws -> Never {
    let pool = try VCPUPool(vm: vm, bootTemplate: BootInfo(ttbr0EL1: tables.rootGPA, el0EntryPC: 0), maxExitsPerVCPU: maxExits)
    stderrLine("ycode-simd: KVM_CAP_MAX_VCPUS \(vm.maxVCPUs), KVM_CAP_NR_VCPUS \(vm.recommendedVCPUs); pool capacity \(pool.capacity)")
    guard count <= pool.capacity else { die("--vcpus \(count) exceeds the pool capacity \(pool.capacity)", status: 64) }
    pool.preBootCleanRanges = { [(VMLayout.shimGPA, shimSize), (tables.rootGPA, tables.tables.count * Int(VMLayout.pageSize))] }
    if options.trace { pool.log = { stderrLine("ycode-simd: " + $0) } }
    let memory = TranslatedGuestMemory(vm: vm, pageTables: tables)
    let lock = HostMutex()
    var finished = 0
    var dispatcher = DarwinTrapDispatcher(
        pid: VMLayout.guestPID,
        stdout: { text in writeFD(1, text) },
        stderr: { text in writeFD(2, text) },
        log: { line in if options.trace { stderrLine("[trap] " + line) } })
    pool.trapHandler = { worker, frame in
        let outcome = lock.withLock { dispatcher.handle(&frame, memory: memory) }
        switch outcome {
        case .resume:
            return .resume
        case let .exit(status) where status == 0:
            lock.withLock { finished += 1 }
            return .park
        case let .exit(status):
            return .terminate(status: status, message: "vCPU \(worker.index): self-test exited with status \(status)")
        case let .fatal(message):
            return .terminate(status: VMLayout.fatalExitStatus, message: "vCPU \(worker.index): fatal guest trap:\n\(message)")
        }
    }
    let state = VCPUStartState(pc: VMLayout.selfTestImageVA, sp: VMLayout.el0StackTop,
                                 registers: [initialTPIDRRO, UInt64(VMLayout.guestPID)], tpidrro: initialTPIDRRO)
    var started = Date()
    for round in 1...options.rounds {
        for _ in 0..<count {
            guard try pool.start(state, context: nil) != nil else { die("round \(round): the vCPU pool is exhausted", status: 71) }
        }
        // Wait until every thread of the round exited and parked its vCPU.
        while true {
            if let end = pool.currentTermination { die(end.message, status: end.status) }
            if lock.withLock({ finished }) == round * count && pool.parkedCount == count { break }
            if Date().timeIntervalSince(started) * 1000 > Double(timeout) {
                let report = pool.stopAll()
                die("watchdog: round \(round) still running after \(timeout) ms\n\(report)", status: 71)
            }
            usleep(500)
        }
        stderrLine("ycode-simd: round \(round): \(count) threads exited 0 on \(pool.vcpuCount) vCPUs")
        started = Date()
    }
    stderrLine("ycode-simd: multi-vCPU self-test ok (\(count) vCPUs x \(options.rounds) rounds)")
    exit(0)
}

let options = parseOptions(CommandLine.arguments)
if let n = getenv("YCODE_DEBUG_MEMCHECK").flatMap({ Int(String(cString: $0)) }), n > 0 {
    HardwareWatchpoint.startMemoryCheck(threads: n)
    stderrLine("ycode-simd: debug: \(n) lost-write checker threads")
}
if DebugAccessGuard.enabled {
    HardwareWatchpoint.installFrameCapture()
    stderrLine("ycode-simd: debug: reader/writer check on interval maps")
}
if getenv("YCODE_DEBUG_HWWATCH").map({ String(cString: $0) == "1" }) ?? false {
    // Diagnostics: hardware write watchpoints on the backings' allocator maps.
    DebugHardwareWatch.arm = { HardwareWatchpoint.arm($0, $1) }
    DebugHardwareWatch.disarm = { HardwareWatchpoint.disarm($0) }
    stderrLine("ycode-simd: debug: hardware write watch on allocator map elements")
}
if let dir = options.gpuCacheDirectory {
    // Before any other thread starts: the Metal back end and ycode-airc read
    // these variables.
    let absolute = dir.hasPrefix("/") ? dir : FileManager.default.currentDirectoryPath + "/" + dir
    do {
        try FileManager.default.createDirectory(atPath: absolute + "/airc", withIntermediateDirectories: true)
    } catch {
        die("--gpu-cache-dir: cannot create \(absolute): \(error)", status: 66)
    }
    setenv("YCODE_VULKAN_PIPELINE_CACHE", absolute + "/vulkan-pipelines.bin", 1)
    setenv("YCODE_AIRC_CACHE", absolute + "/airc", 1)
}
do {
    if options.kvmSmoke {
        try KVMSmokeTest.run { print($0) }
        exit(0)
    }
    if options.execPath != nil || options.devicePath != nil {
        try runExec(options)
    }
    try runStage2(options)
} catch {
    die("\(error)", status: 1)
}
#else
print("ycode-simd: the micro-VM needs Linux with KVM (arm64)")
#endif
