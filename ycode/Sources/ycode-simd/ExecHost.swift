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
import YcodeHostServices
import YcodeSimFeatures
import YcodeMetalHost
import YcodeVulkan

/// What every image of a run shares: the runtime, the shim, the host stubs,
/// the host libraries, and the root's VFS layout.
final class ExecConfiguration: @unchecked Sendable {
    /// Device mode's guest volume devices (st_dev = f_fsid.val[0]): "/" and
    /// the synthetic directories above the prefixes, then one per prefix in
    /// order (an APFS-style major 1; the Mac's simulator volumes read
    /// 0x01000xxx, level 3).
    static let rootDevice: UInt32 = 0x0100_0010
    static let firstPrefixDevice: UInt32 = 0x0100_0011
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
    /// Cache-only image files reported by `stat` (app-launch.md §3.5); nil
    /// with `YCODE_CACHE_IMAGE_FILES=0`.
    let cacheImageFiles: CacheImageFiles?
    let maxExits: Int
    let timeout: UInt64
    /// --repeat runs after the first: no per-image startup lines.
    var quietRuns = false
    /// Device mode (stage 4c): the device layout.
    let device: DeviceLayout?
    /// The device's camera (CameraDevice.swift; nil outside device mode).
    private(set) var camera: DeviceCamera?
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
            // Without --device-type: the type the device recorded (it keeps
            // it, ipad.md R2), else the runtime's default type.
            let platform = layout.runtimePlatform()
            let recorded = DeviceLayout.recordedDeviceType(in: layout.dev).flatMap(DeviceType.named).flatMap { $0.platform == platform ? $0 : nil }
            layout.deviceType = options.deviceType ?? recorded ?? DeviceType.default(for: platform, version: layout.runtimeVersion().version)
            layout.oneshotDelay = options.oneshotDelay
            layout.installApp = options.installApp.map(absolutePath)
            layout.launchBundleID = options.launchBundleID
            layout.appArguments = options.appArguments
            layout.appURL = options.appURL
            layout.appEnvironment = options.appEnvironment
            if options.framebufferLibrary != "none" {
                let fallback = options.shimPath.map { shim -> String in
                    let simShim = ((absolutePath(shim) as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                    return ((simShim as NSString).deletingLastPathComponent as NSString)
                        .appendingPathComponent("SimGuestFrameworks/out/SimFramebuffer.framework/SimFramebuffer")
                }
                layout.framebufferLibrary = options.framebufferLibrary.map(absolutePath)
                    ?? fallback.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            }
            layout.hidBundle = hidBundlePath(options, foldable: layout.deviceType.isFoldable)
            // Ycode's guest agents (simulator-features.md "Ycode implementation").
            let agentsOut = options.shimPath.map { shim -> String in
                let simShim = ((absolutePath(shim) as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                return ((simShim as NSString).deletingLastPathComponent as NSString).appendingPathComponent("SimGuestAgents/out")
            }
            func guestAgentFile(_ name: String) -> String? {
                [options.guestTools.map(absolutePath), agentsOut].compactMap { $0 }.map { $0 + "/" + name }
                    .first { FileManager.default.fileExists(atPath: $0) }
            }
            layout.settingsAgent = options.settingsAgent == "none" ? nil
                : options.settingsAgent.map(absolutePath) ?? guestAgentFile("ycode-settings-agent")
            if options.environmentOverrides {
                layout.overridesLibrary = guestAgentFile("libYcodeEnvironmentOverrides.dylib")
                if layout.overridesLibrary == nil {
                    stderrLine("ycode-simd: warning: --environment-overrides: no libYcodeEnvironmentOverrides.dylib in the guest tools")
                }
            }
            layout.skipFirstBootMigration = options.skipFirstBootMigration
            // SNAPSHOT (snapshot.md §7): a restore keeps DEV as the snapshot left it.
            layout.restoring = !(ProcessInfo.processInfo.environment["YCODE_RESTORE_DIR"] ?? "").isEmpty
            layout.guestTools = options.guestTools.map(absolutePath)
                ?? options.shimPath.map { ((absolutePath($0) as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent("guest-tests/stage7") }
            // The guest's /var, /tmp, and /etc are links into /private: a
            // host path below them (or below /private/...) is unreachable
            // at its own guest path.
            // DEV's guest path: the one its data carries (a copy keeps the
            // original's; app-launch.md §3.3).
            layout.guestDev = layout.resolveGuestDevicePath()
            for (what, path) in [("device directory", layout.dev), ("runtime root", root)] + layout.jobPaths.map({ ("job path", $0) }) {
                for shadowed in ["/tmp", "/var", "/etc", "/private/tmp", "/private/var", "/private/etc"]
                    where path == shadowed || path.hasPrefix(shadowed + "/") {
                    die("the \(what) \(path) is under \(shadowed), which the guest sees as its own; put it elsewhere", status: 64)
                }
            }
            do { try layout.prepare() } catch { die("cannot prepare the device directory \(layout.dev): \(error)", status: 66) }
            layout.appEnvironment += layout.overridesEnvironment
            device = layout
            camera = DeviceCamera(options: options, layout: layout)
            execPath = layout.launchdSimPath
            rootArguments = ["launchd_sim", layout.guestPath(layout.plistPath)] + options.execArguments
            rootEnvironment = layout.launchdEnvironment(overrides: options.environment)
            let t = layout.deviceType
            // Diagnostics: YCODE_GUEST_MEMSIZE=<bytes> sets the guest's memory
            // size (hw.memsize, commpage) before the first image builds them.
            if let bytes = ProcessInfo.processInfo.environment["YCODE_GUEST_MEMSIZE"].flatMap(UInt64.init) {
                Stage3Layout.memorySize = bytes
                stderrLine("ycode-simd: guest memory size \(bytes >> 20) MiB")
            }
            stderrLine("ycode-simd: device type \(t.id) (\(t.name), \(t.modelIdentifier), \(t.screen.width)x\(t.screen.height) @\(Int(t.screen.scale)))")
            stderrLine("ycode-simd: device \(layout.dev)\(layout.guestDev == layout.dev ? "" : " (guest path \(layout.guestDev))"), UDID \(layout.udid); bootstrap plist \(layout.plistPath); TMP \(layout.tmpGuestPath) -> \(layout.tmpHostPath)")
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
        let index = SharedCacheIndex(cachePath: root + "/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64")
        cacheIndex = index
        cacheImageFiles = CacheImageFiles.enabledByEnvironment
            ? CacheImageFiles(runtimeRoot: root, imagePaths: { index.imagePaths() }) : nil
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
            // The runtime root's files belong to root:admin, as on the Mac's
            // mounted runtime image (level 3), and its executables are
            // platform binaries (csops status; home-screen.md §3.4).
            prefixes[0].ownerUID = 0
            prefixes[0].ownerGID = 80
            DarwinKernel.setPlatformCodeRoots([root])
            // proc_info's process platform: the runtime's (visionos.md §2.2).
            DarwinKernel.simulatorPlatform = device.runtimePlatform().machOPlatform
            // Device mode (stage4c-contract.md §2): DEV, /private/var/tmp (TMP is in it)
            // (and /var/tmp), /tmp and /private/tmp, all writable.
            prefixes.append(DarwinFileSystem.Prefix(guestPath: device.guestDev, hostPath: device.dev, writable: true))
            // The data volume's document-ID counter lives with its data
            // (VolumeFeatures.swift).
            VolumeMetadata.documentIDStateDirectory = device.data
            // On macOS a simulator process sees the host's /System, and the
            // runtime opens some framework bundles at their unrooted install
            // paths (CoreFoundation's own bundle: CFBundleGetInfoDictionary
            // dereferences NULL without it; level 3, our runs). Ycode serves
            // RR/System there, read-only.
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/System", hostPath: root + "/System", writable: false,
                                                    ownerUID: 0, ownerGID: 0))
            // Job directories outside DEV and RR: read-only at their own path.
            for path in device.jobPaths where !(path == device.dev || path.hasPrefix(device.dev + "/") || path == root || path.hasPrefix(root + "/")) {
                prefixes.append(DarwinFileSystem.Prefix(guestPath: path, hostPath: path, writable: false))
            }
            // /var/tmp and /tmp reach these through the guest links.
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/private/var/tmp", hostPath: device.privateVarTmpHostPath, writable: true))
            prefixes.append(DarwinFileSystem.Prefix(guestPath: "/private/tmp", hostPath: device.data + "/tmp", writable: true))
            // The memory directory (frame record, timing rings; DeviceMemoryFiles.swift).
            prefixes.append(DarwinFileSystem.Prefix(guestPath: device.memoryGuestPath, hostPath: device.memoryHostPath, writable: true))
            // The host's resolver configuration at the guest's /etc/resolv.conf
            // (libresolv's fallback; networking.md §7 item 8), read-only.
            if GuestNetwork.enabled, let resolv = realpath("/etc/resolv.conf", nil) {
                prefixes.append(DarwinFileSystem.Prefix(guestPath: "/private/etc/resolv.conf", hostPath: String(cString: resolv),
                                                        writable: false, ownerUID: 0, ownerGID: 0))
                free(resolv)
            }
        }
        // Ycode's host libraries (host-libraries.md §5): three read-only
        // single-file prefixes; every other /usr/lib/system path stays ENOENT.
        var hostLibraryPaths: Set<String> = []
        let (hostLibDir, hostLibTried) = locateHostLibraryDirectory(explicit: options.hostLibsPath)
        if let hostLibDir {
            // A visionOS runtime: copies built for its platform, in DEV
            // (GuestImagePlatform.swift; visionos.md §7.2 R1).
            let platform = device?.runtimePlatform() ?? .iOS
            for name in hostLibraryNames {
                var file = "\(hostLibDir)/libsystem_\(name).dylib"
                let guest = hostLibraryGuestPath(name)
                if let device, platform != .iOS, access(file, R_OK) == 0 {
                    do {
                        file = try GuestImagePlatform.adaptedCopy(of: file, to: device.dev + "/ycode-frameworks/host-libs/libsystem_\(name).dylib",
                                                                  for: platform, version: device.runtimeVersion().version)
                    } catch { die("cannot adapt the host library \(file) to \(platform.displayName): \(error)", status: 66) }
                }
                if access(file, R_OK) == 0 {
                    prefixes.append(DarwinFileSystem.Prefix(guestPath: guest, hostPath: file, writable: false,
                                                            ownerUID: device == nil ? nil : 0, ownerGID: device == nil ? nil : 80))
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
        } else {
            // Device mode: each directory prefix is a volume of its own, with
            // its own st_dev = f_fsid (statfs and getfsstat list it, its root
            // is the mount point); a single-file prefix (a host library)
            // belongs to the runtime root's volume. Foundation finds a file's
            // volume by matching its fsid in getfsstat; LaunchServices
            // registers nothing without it (specs/simulator/first-boot.md §3).
            //
            // Since 2026-10-13 only the runtime root is a volume of its own
            // (on the Mac it is a mounted disk image). DEV, /System, the
            // temporary directories and job directories are part of "/"'s
            // volume, as on the Mac, where a simulator process sees the
            // host's /System/Library, /private/var, /private/tmp and the
            // device directory on one device (level 3, `stat`; installcoordinationd
            // refuses an app to install whose path is on another volume than
            // its staging location; home-screen.md §6).
            for i in prefixes.indices {
                let isDirectory = (try? FileManager.default.attributesOfItem(atPath: prefixes[i].hostPath)[.type]
                    as? FileAttributeType) == .typeDirectory
                if !isDirectory || prefixes[i].guestPath == root {
                    prefixes[i].device = Self.firstPrefixDevice
                } else {
                    prefixes[i].device = Self.rootDevice
                    prefixes[i].mountPoint = "/"
                }
            }
        }
        self.prefixes = prefixes
        self.hostLibraryPaths = hostLibraryPaths
    }

    /// The root process's VFS: fresh descriptor table, console on fds 0–2.
    /// Device mode (launchd-sim.md §2.3): fds 0 and 1 are /dev/null, 2 the
    /// console, 3 /dev/console write-only; the cwd is /.
    func makeRootFileSystem() -> DarwinFileSystem {
        let fs = DarwinFileSystem(prefixes: prefixes, console: { fd, bytes in writeFD(fd == 2 ? 2 : 1, bytes) })
        fs.cacheImageFiles = cacheImageFiles
        if device != nil {
            fs.rootDevice = Self.rootDevice
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
        let deferred = VCPUPool.deferredCreations.load(ordering: .relaxed)
        let deferredNs = VCPUPool.deferredCreationNanoseconds.load(ordering: .relaxed)
        return "\(threads) host threads, RSS \(rssKiB / 1024) MiB, \(fds) fds; VMs created \(vms.created), destroyed \(vms.destroyed); "
            + "vCPUs created off the kernel lock \(deferred) (avg \(deferred == 0 ? 0 : deferredNs / deferred / 1000) us); "
            + "TLB flush resumes \(VCPUPool.tlbFlushResumes.load(ordering: .relaxed)) "
            + "(\(VCPUPool.tlbFlushByVAResumes.load(ordering: .relaxed)) by VA)"
            + (VCPUPool.flushKeepsICache ? " (TLB only)" : " (TLB and I-cache)")
    }
}

/// Launchers whose images did not all stop (threads stuck in the kernel):
/// kept alive for the rest of the host process, never freed under them.
nonisolated(unsafe) var abandonedLaunchers: [VMMLauncher] = []
/// The SIGUSR1 source of the thread report (kept for the life of the run).
nonisolated(unsafe) var threadReportSignalSource: DispatchSourceSignal?

/// The holding-tank variable (stage4c-contract.md §8.3; `…_FD_HACK` is not set).
let holdingTankKey = "XPC_SIMULATOR_HOLDING_TANK_HACK"

/// One run of the root process. Returns the host exit status once the root
/// process ended and the rest of the system was stopped.
func runRootProcess(_ config: ExecConfiguration, quietSummary: Bool = false) -> Int32 {
    // Profiling: host locks are named for the futex report from here on.
    _ = TrapProfile.shared
    // Thread CPU numbers stay below the guest CPU count (darwin-process-start.md).
    VCPUPool.guestCPUCount = GuestCPUs.count
    // Diagnostics: `YCODE_BOOT_PROFILE=<path>` (BootProfile.swift).
    BootProfile.shared?.enable()
    // The full shared-cache image index (fault reports, traces) is built in
    // the background; the libSystem milestone never waits for it
    // (performance-contract.md §6, C15). `YCODE_CACHE_INDEX_PREWARM=0`: built
    // on first use, as before.
    if getenv("YCODE_CACHE_INDEX_PREWARM").map({ String(cString: $0) != "0" }) ?? true { config.cacheIndex.prewarm() }
    let system = DarwinSystem()
    // The objects every process start asks for by id are in the object
    // index from the start (boot-profile.md §7).
    let prewarmed = system.prewarmObjectPaths(fileSystem: config.makeRootFileSystem())
    if BootProfile.shared != nil { stderrLine("ycode-simd: object index: \(prewarmed) start-up objects noted") }
    // Scheduling policy (scheduling-policy.md §6): the switches and the hold log.
    if SchedPolicy.holdEnabled || SchedPolicy.qosEnabled {
        HostSched.threadID = { ckvmThreadID() }
        stderrLine("ycode-simd: sched: start hold \(SchedPolicy.holdEnabled ? "on" : "off"), thread QoS \(SchedPolicy.qosEnabled ? "on" : "off")"
            + (SchedPolicy.qosEnabled ? ", lock admission \(SchedPolicy.admissionEnabled ? "on" : "off"), host \(HostSched.configure())" : ""))
        system.holdLog = { stderrLine("ycode-simd: sched: " + $0) }
    }
    if config.trace || !config.options.tracePIDs.isEmpty || !config.options.traceNames.isEmpty {
        MachIPC.traceMessageStrings = true
    }
    let launcher = VMMLauncher(config: config)
    system.launcher = launcher
    // The device's camera layer goes into apps (CameraDevice.swift).
    config.camera?.install(on: system)
    system.processExited = { [weak launcher] pid, status in launcher?.processExited(pid: pid, status: status) }

    // Device mode (stage4c-contract.md §3): every task starts with a send
    // right to the host bootstrap port as its bootstrap special port; the
    // logging service receives on it.
    var bootstrapLogger: HostBootstrapLogger?
    var session: DeviceSession?
    var ioSurfaceService: IOSurfaceHostService?
    var metalService: MetalHostService?
    var hidService: HIDHostService?
    if config.device != nil || config.options.hostBootstrap {
        system.mach.hostBootstrapIsDefault = true
        let logPath = config.device?.hostBootstrapLogPath ?? config.runDir + "/ycode-host-bootstrap.log"
        let logger = HostBootstrapLogger(host: system.hostTask, logPath: logPath,
                                         discard: config.options.debugBootstrapDiscard)
        if config.device != nil {
            // The host's messages carry the identity of launchd_sim's parent
            // (pid 1 in Ycode's process table) and the guest user, as on the
            // Mac, where the host is launchd_sim's parent process running as
            // the user. launchd_sim refuses control requests (700, 704:
            // EPERM) from euid 0, and crashed handling a 704 from pid 0, a
            // pid with no process (level 3, our runs).
            system.hostTask.pid = DarwinSystem.initPID
            system.hostTask.uid = DarwinFileSystem.guestUID
            system.hostTask.gid = DarwinFileSystem.guestGID
        }
        if let identity = config.options.debugHostIdentity {
            (system.hostTask.pid, system.hostTask.uid, system.hostTask.gid) = identity
        }
        if let device = config.device, !config.options.debugBootstrapDiscard {
            // The control session (launch-sim-control.md §5.2).
            let s = DeviceSession(layout: device, host: system.hostTask, makeFileSystem: { config.makeRootFileSystem() })
            logger.onControlChannel = { [weak s] channel in s?.channelArrived(channel) }
            logger.beforeServicePortHandoff = { [weak s] port in s?.servicePortCreated(port) }
            // Host services (stage 7): com.apple.IOSurface.Remote (iosurface-remote.md).
            if !config.options.debugNoHostServices {
                do {
                    let service = try IOSurfaceHostService(host: system.hostTask, log: { stderrLine("ycode-simd: " + $0) })
                    service.start()
                    s.hostServices.append((IOSurfaceHostService.serviceName, service.servicePort))
                    ioSurfaceService = service
                } catch {
                    stderrLine("ycode-simd: warning: cannot start the IOSurface service: \(error)")
                }
                // Viewer input (hid-input.md §7): with the HID bundle only.
                hidService = startHIDService(config: config, session: s, host: system.hostTask)
                // The Metal host service (stage8-contract.md §5.2): only with a
                // usable GPU back end. Without one no Metal name is offered, and
                // the runtime renders on the CPU (headless-rendering.md).
                if !config.options.debugNoMetal {
                    // The back end's own messages go to stderr; the shader
                    // translator is --metal-translator, else $YCODE_AIRC,
                    // next to ycode-simd, or on $PATH.
                    var backendOptions = VulkanMetalBackend.Options()
                    backendOptions.log = { stderrLine("ycode-simd: metal backend: " + $0) }
                    // Guest memory may be imported with slack only inside the
                    // shared object arena (stage8-contract.md §15.6).
                    backendOptions.importSlackWindow = SharedObjectArena.shared.map { (UInt(bitPattern: $0.base), UInt($0.size)) }
                    // A pool of translator processes, started now (a single
                    // process serialized every translation: at a restore or an
                    // app's first frames the render server's command buffers
                    // waited seconds for their pipelines; stage8-contract.md §14).
                    let translator: (any ShaderTranslator)? = config.options.metalTranslator.map {
                        let pool = AircTranslatorPool(executable: URL(fileURLWithPath: $0), count: backendOptions.translatorProcesses)
                        if ProcessInfo.processInfo.environment["YCODE_AIRC_PRESTART"] != "0" { pool.prestart() }
                        return pool
                    }
                    let backend = VulkanMetalBackend(translator: translator, options: backendOptions)
                    if backend.isAvailable {
                        // CPU access to a surface waits for GPU writes reported scheduled early.
                        if backend.options.earlyScheduled {
                            ioSurfaceService?.gpuWriteWait = { [weak backend] id in backend?.waitForSurfaceWrites(id) }
                        }
                        MetalCommandDecoder.anomalyLog = { stderrLine("ycode-simd: " + $0) }
                        do {
                            let metal = try MetalHostService(host: system.hostTask, backend: backend,
                                                             memory: HostMemoryEntryResolver(host: system.hostTask),
                                                             surfaces: ioSurfaceService.map { IOSurfacePortResolver(service: $0) },
                                                             log: { stderrLine("ycode-simd: " + $0) })
                            metal.start()
                            s.hostServices.append((MetalHostService.serviceNames[0], metal.servicePort))
                            metalService = metal
                            stderrLine("ycode-simd: Metal host service: \(MetalHostService.serviceNames[0]) on Vulkan")
                        } catch {
                            stderrLine("ycode-simd: warning: cannot start the Metal host service: \(error)")
                        }
                    } else {
                        stderrLine("ycode-simd: Metal host service: no Vulkan device; no Metal name offered")
                    }
                }
            }
            // The camera endpoint (camera.md "Ycode implementation"): last, when
            // the device's camera is on.
            if !config.options.debugNoHostServices { config.camera?.start(host: system.hostTask, surfaces: ioSurfaceService, session: s) }
            session = s
        }
        do { try logger.start() } catch { die("cannot start the host bootstrap service: \(error)", status: 1) }
        bootstrapLogger = logger
    }

    // SNAPSHOT (agent SNAP, snapshot.md §2.6, §9): the device session's
    // control channel and session port, and the Metal clients, are saved as
    // host-service records; after a restore the session is adopted again.
    if let snap = SnapshotSupport.shared {
        snap.stopHooks = (appPID: { [weak session] in session?.launchedAppPID },
                          appStepsRunning: { [weak session] in session?.appStepsRunning ?? false },
                          endSession: { [weak session] in session?.end() })
        snap.hostServiceState = { [weak session, weak metalService, weak hidService] in
            var out: [SnapshotFields] = []
            // Viewer input (hid-input.md §7 item 6): the bundle's registration.
            if let client = hidService?.snapshotClient {
                var g = SnapshotFields()
                g.string(ST_HostService.name, "hid")
                g.u64(ST_HostService.hidClient, UInt64(client))
                out.append(g)
            }
            if let st = session?.snapshotState {
                var g = SnapshotFields()
                g.string(ST_HostService.name, "device-session")
                g.u64(ST_HostService.channel, UInt64(st.channel))
                g.u64(ST_HostService.session, UInt64(st.session))
                out.append(g)
            }
            if let store = DefaultHostServices.scDynamicStore {
                var g = SnapshotFields()
                g.string(ST_HostService.name, "scdynamicstore")
                g.list(ST_HostService.sessions, store.snapshotSessions.map { s in
                    var e = SnapshotFields()
                    e.u64(1, UInt64(s.session))
                    e.u64s(2, s.notify.map(UInt64.init))
                    return e
                })
                out.append(g)
            }
            if let metal = metalService {
                var g = SnapshotFields()
                g.string(ST_HostService.name, "metal")
                g.u64s(ST_HostService.pids, metal.clientPIDs().map { UInt64(max(0, $0)) })
                out.append(g)
            }
            // File-event streams (fsevents-host.md, "Ycode implementation").
            if let events = DefaultHostServices.fsEvents {
                var g = SnapshotFields()
                g.string(ST_HostService.name, "fsevents")
                g.list(ST_HostService.sessions, events.snapshotStreams.map(FSEventsSnapshot.fields))
                out.append(g)
            }
            return out
        }
        // IOSurface and Metal (§8 option 2): read with the guest quiesced and
        // every service idle (no message in hand, no command buffer in flight).
        // `YCODE_SNAPSHOT_GPU=0`: not saved (a restore then has to restart the
        // Metal clients, YCODE_RESTORE_KILL=auto).
        let saveGPU = getenv("YCODE_SNAPSHOT_GPU").map { String(cString: $0) != "0" } ?? true
        let hostTask = system.hostTask
        snap.quiescedServiceState = { [weak ioSurfaceService, weak metalService] in
            let inHand = hostTask.messagesInHandLocked
            if inHand > 0 { return .failure(SnapshotError("\(inHand) host-service messages in hand")) }
            var out: [SnapshotFields] = []
            // Audio (audio-host.md, "Ycode implementation"): objects, clients, running IO.
            if let audio = DefaultHostServices.audio {
                guard let st = audio.trySnapshotState() else { return .failure(SnapshotError("audio service busy")) }
                var g = SnapshotFields()
                g.string(ST_HostService.name, "audio")
                g.nested(ST_HostService.state, st)
                out.append(g)
            }
            guard saveGPU else { return .success(out) }
            if let reason = metalService?.snapshotBusyReason { return .failure(SnapshotError(reason)) }
            if let io = ioSurfaceService {
                guard let st = io.trySnapshotState() else { return .failure(SnapshotError("IOSurface service busy")) }
                var g = SnapshotFields()
                g.string(ST_HostService.name, "iosurface")
                g.nested(ST_HostService.state, st)
                out.append(g)
            }
            if let metal = metalService {
                guard let st = metal.trySnapshotState() else { return .failure(SnapshotError("Metal service busy")) }
                var g = SnapshotFields()
                g.string(ST_HostService.name, "metal-objects")
                g.nested(ST_HostService.state, st)
                out.append(g)
            }
            return .success(out)
        }
        let replayGPU = getenv("YCODE_RESTORE_GPU").map { String(cString: $0) != "0" } ?? true
        snap.restoreHostServices = { [weak session, weak ioSurfaceService, weak metalService, weak hidService] records in
            for r in records where r.string(ST_HostService.name) == "hid" {
                let client = r.u32(ST_HostService.hidClient)
                guard let hid = hidService, MachPortName.isValid(client) else { continue }
                hid.restoreRegistration(client: client)
            }
            if hidService != nil, !records.contains(where: { $0.string(ST_HostService.name) == "hid" }) {
                snapLog("restore: no HID registration in the snapshot; the device takes input only after its HID bundle registers")
            }
            if replayGPU {
                for r in records where r.string(ST_HostService.name) == "iosurface" {
                    guard let io = ioSurfaceService, let st = r.nested(ST_HostService.state) else { continue }
                    do {
                        let n = try io.restoreState(st)
                        snapLog("restore: IOSurface: \(n) surfaces")
                    } catch {
                        snapLog("restore: IOSurface state not restored: \(error)")
                    }
                }
                for r in records where r.string(ST_HostService.name) == "metal-objects" {
                    guard let metal = metalService, let st = r.nested(ST_HostService.state) else { continue }
                    let began = monotonicNanoseconds()
                    let rep = metal.restoreState(st)
                    snapLog("restore: Metal: \(rep.processes) processes, \(rep.objects) objects and \(rep.ghosts) kept recipes "
                        + "made again in \((monotonicNanoseconds() - began) / 1_000_000) ms (\(rep.failures) failed); contents: textures "
                        + "\(rep.textureBytes >> 10) KiB, buffers \(rep.bufferBytes >> 10) KiB, \(rep.contentsSkipped) skipped; "
                        + "\(rep.addressesChanged) buffer GPU addresses and \(rep.samplerIDsChanged) sampler IDs changed")
                    for line in rep.lines { snapLog("restore: " + line) }
                }
            }
            for r in records where r.string(ST_HostService.name) == "audio" {
                guard let audio = DefaultHostServices.audio, let st = r.nested(ST_HostService.state) else { continue }
                do {
                    let n = try audio.restoreState(st)
                    snapLog("restore: audio: \(n) running IO contexts (resumed once the guest clock is set)")
                } catch {
                    snapLog("restore: audio state not restored: \(error)")
                }
            }
            for r in records where r.string(ST_HostService.name) == "scdynamicstore" {
                let list = r.list(ST_HostService.sessions).map { e in (session: e.u32(1), notify: e.u64s(2).map { UInt32(truncatingIfNeeded: $0) }) }
                DefaultHostServices.scDynamicStore?.restoreSessions(list)
                snapLog("restore: SCDynamicStore: \(list.count) sessions")
            }
            for r in records where r.string(ST_HostService.name) == "fsevents" {
                let list = r.list(ST_HostService.sessions).map(FSEventsSnapshot.record)
                DefaultHostServices.fsEvents?.restoreStreams(list)
                snapLog("restore: file events: \(list.count) streams")
            }
            for r in records where r.string(ST_HostService.name) == "device-session" {
                session?.reattach(channel: r.u32(ST_HostService.channel), session: r.u32(ST_HostService.session))
            }
        }
    }

    // Diagnostics: `YCODE_FRAME_PROFILE_BOOT` opens a frame-profile window
    // before the root process exists (FrameProfile.swift; boot-profile.md §8).
    FrameProfile.shared?.prepareBoot(launcher: launcher, statePath: config.device?.framebufferStatePath, surfaces: ioSurfaceService)
    // The A/B line at the home screen (scheduling-policy.md §7.5): the kernel
    // lock's hold so far and the scheduling counters.
    HomeWatch.atHome = { [weak system] in
        guard let system else { return "" }
        let (held, count) = system.lock.withLock { (system.lock.totalHeldNanoseconds, system.lock.acquisitions) }
        return "kernel lock held \(held / 1_000_000) ms (\(count) acquisitions)"
            + (SchedPolicy.holdEnabled || SchedPolicy.qosEnabled ? "; sched: " + system.schedReport + "; " + HostSched.report : "")
    }
    HomeWatch.startIfRequested(statePath: config.device?.framebufferStatePath, surfaces: ioSurfaceService)
    let rootKernel: DarwinKernel
    do {
        // Device mode (stage4c-contract.md §8.3): launchd_sim needs the pid of
        // a child of its own in XPC_SIMULATOR_HOLDING_TANK_HACK; the process
        // layer makes an already-exited one (bootstrap-wire.md §5.4).
        // SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §7):
        // YCODE_RESTORE_DIR restores a snapshot instead of spawning the root.
        if let restored = try SnapshotSupport.shared?.restoreIfRequested(system: system, launcher: launcher, config: config) {
            rootKernel = restored
        } else {
            rootKernel = try system.spawnInitialProcess(config.rootRequest, fileSystem: config.makeRootFileSystem(),
                                                        exitedChildEnvironmentKey: config.device != nil ? holdingTankKey : nil)
        }
    } catch {
        let detail = launcher.lastLaunchFailure ?? "\(config.execPath): \(error)"
        die("cannot start the root process: \(detail)", status: (error as? DarwinErrnoError) != nil ? 66 : 1)
    }
    _ = rootKernel
    let started = monotonicMilliseconds()
    // SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §9): the
    // YCODE_SNAPSHOT_AT_MS / _WHEN_FILE / _CENSUS triggers.
    SnapshotSupport.shared?.rootStarted(system: system, launcher: launcher, config: config)
    // Diagnostics (agent SP-SNAP): `YCODE_THREAD_REPORT_AT_S=<s>[,<s>…]` writes
    // where every thread of every live process waits, that many seconds
    // after the root process started, without ending the run.
    let threadReport: @Sendable (String) -> Void = { [weak system] title in
        guard let system else { return }
        stderrLine("ycode-simd: thread report \(title):")
        for p in system.allProcesses {
            guard let k = p.kernel else { continue }
            let lines = k.lock.withLock { k.blockedThreadReport() }
            if lines.isEmpty { continue }
            stderrLine("ycode-simd: threads of pid \(p.pid) (\((p.executablePath as NSString).lastPathComponent)):")
            for line in lines { stderrLine("  " + line) }
        }
    }
    if let spec = getenv("YCODE_THREAD_REPORT_AT_S").map({ String(cString: $0) }) {
        let times = spec.split(separator: ",").compactMap { UInt64($0) }.sorted()
        Thread.detachNewThread {
            let start = monotonicMilliseconds()
            for t in times {
                while monotonicMilliseconds() - start < t * 1000 { usleep(200_000) }
                threadReport("at \(t) s")
            }
        }
    }
    // SIGUSR1: the same report now, without ending the run (the warm-boot
    // launcher asks for one before it kills a restore that failed,
    // snapshot.md §12.5).
    signal(SIGUSR1, SIG_IGN)
    threadReportSignalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
    threadReportSignalSource?.setEventHandler {
        threadReport("on SIGUSR1, \((monotonicMilliseconds() - started) / 1000) s after the root started")
    }
    threadReportSignalSource?.resume()
    // Diagnostics: `YCODE_TRAP_PROFILE=<path>` (per-trap kernel-lock profile,
    // rewritten every `YCODE_TRAP_PROFILE_INTERVAL` s and at the end).
    TrapProfile.shared?.extraReport = { [weak system] in
        let split = system?.lock.splitReport ?? ""
        return (ImageBuildProfile.shared?.report ?? "") + (split.isEmpty ? "" : "\n" + split)
    }
    if TrapProfile.shared != nil {
        TrapProfile.threadUsage = {
            let u = hostThreadUsage()
            return .init(faults: u.faults, voluntarySwitches: u.voluntarySwitches, involuntarySwitches: u.involuntarySwitches)
        }
        TrapProfile.currentThreadID = { ckvmThreadID() }
        // `YCODE_TRAP_PROFILE_SAMPLE_US=<us>` (default 2000; 0 = off): the lock-holder sampler.
        let sampleUS = getenv("YCODE_TRAP_PROFILE_SAMPLE_US").flatMap { UInt32(String(cString: $0)) } ?? 2000
        if sampleUS > 0 { TrapProfile.shared?.startHolderSampler(lock: system.lock, every: sampleUS) }
        #if os(Linux) && arch(arm64)
        if let path = getenv("YCODE_TRAP_PROFILE").map({ String(cString: $0) }) {
            LockStackSampler.startIfRequested(lock: system.lock, profilePath: path, portLock: system.mach.portLock)
        }
        #endif
    }
    TrapProfile.shared?.startPeriodicDump()
    BootProfile.shared?.launcherForReport = launcher
    BootProfile.shared?.startSampler(launcher: launcher, lock: system.lock)
    BootProfile.shared?.startPCSampler(launcher: launcher)
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

    // A foldable's hinge (FoldControl.swift; foldable.md §8): with the HID
    // service. Every cold boot starts closed; a restore keeps the saved fold.
    var fold: FoldController?
    if let device = config.device, let second = device.deviceType.secondDisplay, let hid = hidService {
        fold = FoldController(hid: hid, second: second, statePath: device.memoryFile("fold.state").host,
                              restoring: device.restoring, log: { stderrLine("ycode-simd: " + $0) })
        fold?.innerPublished = device.deviceType.publishedSecondDisplay != nil
    }
    // A panel's picture (`--screenshot`, the control socket): "LCD",
    // "LCD-1" or "active" (the panel shown), turned upright (D4).
    nonisolated(unsafe) let panelCapture: (String, String) -> String = { [weak ioSurfaceService, weak fold] name, path in
        guard let device = config.device, let service = ioSurfaceService else { return "no display service" }
        let panels = device.deviceType.panels
        let records = panels.map { FrameRecordReader(path: device.framebufferStatePath, slot: $0.slot).read() }
        let panel: PanelInfo
        if name == "active" {
            panel = activePanel(panels, model: fold?.state, records: records, black: records.map { service.presentedFrameIsBlack($0) })
        } else if let p = panels.first(where: { $0.name == name }) {
            panel = p
        } else {
            return "no display \(name) (this device has \(panels.map(\.name).joined(separator: ", ")))"
        }
        let c = ScreenCapture(statePath: device.framebufferStatePath, service: service, slot: panel.slot,
                              rotation: PanelPicture.uprightRotation(mountRotation: panel.mountRotation), displayName: panel.name)
        return c.capture(to: path)
    }
    var control: DeviceControlServer?
    if let device = config.device {
        let server = DeviceControlServer(path: DeviceLayout.controlSocketPath(dev: device.dev), fold: fold,
                                         summary: { [weak fold, weak ioSurfaceService] in
                                             guard let fold else { return "\(device.deviceType.name): does not fold" }
                                             let panels = device.deviceType.panels
                                             let records = panels.map { FrameRecordReader(path: device.framebufferStatePath, slot: $0.slot).read() }
                                             let black = records.map { ioSurfaceService?.presentedFrameIsBlack($0) }
                                             let shown = activePanel(panels, model: fold.state, records: records, black: black)
                                             return fold.state.summary + "; showing \(shown.name)"
                                                 + (fold.sweepTarget.map { "; sweeping to \($0)°" } ?? "")
                                                 + "; backlight " + zip(panels, records).map { "\($0.name) \($1?.backlight.map(String.init) ?? "-")" }.joined(separator: ", ")
                                                 + "; frames " + zip(panels, black).map { "\($0.name) \($1.map { $0 ? "black" : "lit" } ?? "-")" }.joined(separator: ", ")
                                         },
                                         capture: panelCapture)
        // The settings features (SimSettings.swift): the channel to the guest
        // agent and its commands on the control socket.
        let files = DeviceSettingsFiles(dev: device.dev, guestData: device.guestData)
        let settings = SimSettingsController(files: files, runtimeRoot: config.root, log: { stderrLine("ycode-simd: " + $0) })
        settings.onAudio = { s in DefaultHostServices.audio?.setOutput(volume: Float(s.volume) / 100, muted: s.output == .none) }
        settings.onAudio?(files.audio())
        HostStreamSockets.serve(paths: SettingsChannel.guestPaths, with: settings)
        if device.settingsAgent != nil {
            stderrLine("ycode-simd: settings: agent \(device.settingsAgentHostPath) (log \(device.settingsAgentLogPath))")
        }
        server.moreCommands = { words in
            guard let verb = words.first, SimSettingsCommand.verbs.contains(verb) else { return nil }
            return settings.handle(words)
        }
        if server.start() { control = server } else { stderrLine("ycode-simd: warning: no control socket at \(server.path)") }
    }

    // Screenshots at fixed times (a background thread) and at the end.
    let screenshotDisplay = config.options.screenshotDisplay ?? "active"
    if config.device != nil, ioSurfaceService != nil, let path = config.options.screenshotPath {
        for seconds in config.options.screenshotTimes.sorted() {
            let at = (path as NSString).deletingPathExtension + "-\(seconds)s.png"
            Thread.detachNewThread {
                Thread.sleep(until: Date(timeIntervalSinceNow: 0).addingTimeInterval(
                    max(0, Double(seconds) - Double(monotonicMilliseconds() - started) / 1000)))
                stderrLine("ycode-simd: screenshot at \(seconds) s: " + panelCapture(screenshotDisplay, at))
            }
        }
    }
    // After a restore the display shows the restored frame before any guest
    // thread runs; the first frame the guest presents afterwards is the
    // display's own sign of life (snapshot.md §12.5). A foldable's frame may
    // come on either built-in panel: a device saved open draws on the inner
    // panel only (foldable.md §10.4).
    if let device = config.device, SnapshotSupport.shared?.settings.restoreDirectory != nil {
        let statePath = device.framebufferStatePath
        let slots = device.deviceType.panels.map(\.slot)
        Thread.detachNewThread {
            let readers = slots.map { FrameRecordReader(path: statePath, slot: $0) }
            let first = readers.map { $0.read() }
            for _ in 0..<1200 {
                usleep(250_000)
                for (i, reader) in readers.enumerated() {
                    guard let now = reader.read(), now != first[i] else { continue }
                    stderrLine("ycode-simd: snapshot: restore: first new frame (frame \(first[i].map { String($0.frame) } ?? "none") -> "
                        + "\(now.frame)\(slots.count > 1 ? " on display slot \(slots[i])" : "")) \(monotonicMilliseconds() - started) ms after the root started")
                    return
                }
            }
            stderrLine("ycode-simd: snapshot: restore: no new frame in 300 s (frame \(first.first.flatMap { $0.map { String($0.frame) } } ?? "none"))")
        }
    }

    // Diagnostics: `YCODE_FRAME_PROFILE=<path>` (FrameProfile.swift; frame-profile.md).
    FrameProfile.shared?.start(launcher: launcher, statePath: config.device?.framebufferStatePath)

    // The live display and viewer input (DisplayServer.swift; display-stream.md).
    // Guest mach time now (display timing traces): the system counter at the guest timebase.
    let guestClock: () -> UInt64? = { [weak launcher] in
        guard let c = launcher?.snapshotSystemClock else { return nil }
        let scale = GuestTimebase.ClockScale(from: c.frequency, to: GuestTimebase.frequency(hostFrequency: c.frequency))
        return scale.apply(c.guestCounter)
    }
    let display = startDisplayServer(config: config, surfaces: ioSurfaceService, session: session, hid: hidService, fold: fold,
                                     started: started, guestClock: guestClock)
    display?.commands = { [weak control] line in control?.handle(line) ?? "error: no control commands for this device" }
    // The audio service's host times are guest mach time (audio-host.md §10).
    DefaultHostServices.audio?.setGuestClock { [weak launcher] in
        guard let c = launcher?.snapshotSystemClock else { return (MachTimebase.now(), MachTimebase.frequency) }
        let hz = GuestTimebase.frequency(hostFrequency: c.frequency)
        return (GuestTimebase.ClockScale(from: c.frequency, to: hz).apply(c.guestCounter), hz)
    }

    // The camera's frame times are guest mach time too.
    config.camera?.setGuestClock { [weak launcher] in
        guard let c = launcher?.snapshotSystemClock else { return (MachTimebase.now(), MachTimebase.frequency) }
        let hz = GuestTimebase.frequency(hostFrequency: c.frequency)
        return (GuestTimebase.ClockScale(from: c.frequency, to: hz).apply(c.guestCounter), hz)
    }
    if let camera = config.camera, camera.optIn.isOn {
        deviceCameraControl = { [weak session] words in camera.handle(words, session: session) }
    }
    var result = launcher.superviseRoot(timeoutMilliseconds: config.timeout)
    config.camera?.stop()
    DefaultHostServices.audio?.finishCapture()
    display?.stop(message: "the device run ended")
    if config.device != nil, ioSurfaceService != nil, let path = config.options.screenshotPath {
        stderrLine("ycode-simd: screenshot: " + panelCapture(screenshotDisplay, path))
    }
    control?.stop()
    config.device?.finishMemoryDirectory()
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
        // The IDE's warm boot (snapshot.md §12): the end of the run's time
        // is a stop like any other; with YCODE_SNAPSHOT_STOP_DIR the device
        // is saved and the host process exits here.
        _ = SnapshotSupport.shared?.stopAndSave(reason: "the run's time limit (--timeout-ms)")
        if let session, session.isBound, !config.options.debugNoSessionEnd {
            // The clean end: destroy the session port; launchd_sim shuts the
            // guest down and exits 0 (launch-sim-control.md §3.1). (The
            // watchdog report stops every vCPU, so it comes only if this
            // fails; --debug-no-session-end keeps the guest as it was.)
            session.end()
            let shutdown = launcher.superviseRoot(timeoutMilliseconds: 15_000)
            if shutdown.watchdog {
                result.message += "; the session was ended, but launchd_sim did not exit within 15 s"
                if config.trace || config.options.debugThreadReport { watchdogReport = launcher.watchdogReport() }
            } else {
                result = (shutdown.status,
                          "device run ended after \(config.timeout) ms (--timeout-ms); session ended, launchd_sim (pid \(rootPID)) "
                            + "shut down: \(shutdown.message)", false)
            }
        } else if config.trace || config.options.debugThreadReport {
            watchdogReport = launcher.watchdogReport()
        }
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
    TrapProfile.shared?.dump()
    BootProfile.shared?.writeReport(records: launcher.records)

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
    if !quietSummary, SchedPolicy.holdEnabled || SchedPolicy.qosEnabled {
        stderrLine("ycode-simd: sched: " + system.schedReport + "; " + HostSched.report)
    }
    if !quietSummary {
        stderrLine("ycode-simd: host: \(HostStats.current())" + (stillAlive > 0 ? "; \(stillAlive) images not torn down" : ""))
    }
    // The GPU back end ends in order before exit() (stage8-contract.md §12):
    // exit() runs the driver's own teardown, and a back-end thread still
    // inside the driver then crashes the host (SIGSEGV, "device lost").
    if let metalService {
        let t0 = monotonicMilliseconds()
        let drained = metalService.shutdown()
        if !quietSummary {
            stderrLine("ycode-simd: Metal host service: shut down in \(monotonicMilliseconds() - t0) ms"
                + (drained ? "" : " (a connection was still busy)"))
        }
    }
    ioSurfaceService?.stop()
    if let bootstrapLogger {
        bootstrapLogger.stop()
        if stillAlive == 0 { system.hostTask.shutdown() }
    }
    if let session, !quietSummary {
        for line in session.resultLines { stderrLine("ycode-simd: one-shot " + line) }
    }
    if let device = config.device, device.launchBundleID != nil, !quietSummary {
        for path in [device.appStdoutHostPath, device.appStderrHostPath] {
            guard let data = FileManager.default.contents(atPath: path) else {
                stderrLine("ycode-simd: app output: no file \(path)")
                continue
            }
            stderrLine("ycode-simd: app output (\(path), \(data.count) bytes)" + (data.isEmpty ? "" : ":\n" + String(decoding: data, as: UTF8.self)))
        }
    }
    if let device = config.device, !quietSummary {
        let log = device.tmpHostPath + "/launchd.log"
        let size = try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int
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
    // cpu-features.md §4.1: the guest's CPU features, before the first VM.
    CPUFeatureSetup.install()
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
