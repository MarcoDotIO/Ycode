// ycode-simd: the kernel's `ProcessLauncher` (stage 4b,
// specs/simulator/stage4b-contract.md §3.3, §3.4, §7). Every image of every
// guest process gets its own KVM VM, physical backing, page tables, vCPU
// pool, thread host, and image map, all in this one host process. The
// launcher keeps the live images, collects the ones whose vCPU threads have
// all returned, and tears their VMs down (`ExecHost.swift` drives it).

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import Synchronization
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor
import YcodeMachO

/// The root process's pid (stage4b-contract.md §2 item 7).
let rootPID: Int32 = VMLayout.guestPID

/// Darwin errno values the launcher reports that the shared table may lack.
enum LaunchErrno {
    static let ENOENT: Int32 = 2
    static let ENOEXEC: Int32 = 8
    static let ENOMEM: Int32 = 12
    static let EACCES: Int32 = 13
    static let EBADARCH: Int32 = 86
}

/// Host-wide counters for the leak check (`--repeat`).
final class VMCounters: @unchecked Sendable {
    static let shared = VMCounters()
    private let lock = HostMutex(name: "VM counters")
    private var created = 0
    private var destroyed = 0
    func vmCreated() { lock.withLock { created += 1 } }
    func vmDestroyed() { lock.withLock { destroyed += 1 } }
    var snapshot: (created: Int, destroyed: Int) { lock.withLock { (created, destroyed) } }
}

/// Diagnostics (with `YCODE_TRAP_PROFILE`): where building an image's VM
/// spends its time (spawn and exec run it under the kernel lock).
final class ImageBuildProfile: @unchecked Sendable {
    static let shared: ImageBuildProfile? = TrapProfile.shared == nil ? nil : ImageBuildProfile()
    static let phases = ["VM", "load", "setup", "vCPU 0", "clock", "wire"]
    private let lock = HostMutex()
    private var builds = 0
    private var totals = [UInt64](repeating: 0, count: phases.count)

    /// Times the phases of one build (`mark` after each).
    struct Timer {
        var last = monotonicNanoseconds()
        var spans: [UInt64] = []
        mutating func mark() {
            let now = monotonicNanoseconds()
            spans.append(now &- last)
            last = now
        }
    }

    func record(_ timer: Timer) {
        lock.withLock {
            builds += 1
            for (i, ns) in timer.spans.enumerated() where i < totals.count { totals[i] &+= ns }
        }
    }

    var report: String {
        lock.withLock {
            let all = totals.reduce(0, &+)
            let parts = zip(Self.phases, totals).map { "\($0) \($1 / 1_000_000) ms (\(builds == 0 ? 0 : $1 / UInt64(builds) / 1000) us)" }
            let deferred = VCPUPool.deferredCreations.load(ordering: .relaxed)
            let deferredNs = VCPUPool.deferredCreationNanoseconds.load(ordering: .relaxed)
            return "Image builds \(builds), \(all / 1_000_000) ms in all: " + parts.joined(separator: ", ")
                + "; vCPUs created off the kernel lock \(deferred) (avg \(deferred == 0 ? 0 : deferredNs / deferred / 1000) us)"
                + "; all vCPU creations: KVM_CREATE_VCPU \(VCPUPool.deferredCreateVCPUNanoseconds.load(ordering: .relaxed) / 1_000_000) ms, "
                + "VCPU_INIT+map \(VCPUPool.deferredInitNanoseconds.load(ordering: .relaxed) / 1_000_000) ms; "
                + "off-lock host threads \(VCPUPool.deferredThreadNanoseconds.load(ordering: .relaxed) / 1_000_000) ms"
        }
    }
}

/// Empty VMs (a `ProcessBuilder`: KVM VM, memslots, EL1 tables) built
/// without the kernel lock by the thread that is about to make a spawn or
/// exec trap, so the image build that trap runs under the kernel lock
/// takes a ready VM instead of creating one there (KVM_CREATE_VM and the
/// memslot additions: about 19 ms each in a profiled boot, ~6 % of the
/// lock's hold time). At most `limit` wait; a spawn that fails before its
/// image is built leaves its VM for the next one. Traced images build
/// their own (the builder's log is fixed at creation).
/// `YCODE_VM_PREBUILD=0` turns it off (A/B).
final class PrebuiltVMs: @unchecked Sendable {
    static let enabled = getenv("YCODE_VM_PREBUILD").map { String(cString: $0) != "0" } ?? true
    /// `YCODE_VM_PREBUILD_ASYNC` (default on, `=0` off; boot-profile.md
    /// §7.3, C22): one background thread keeps `asyncLimit` VMs ready, so a
    /// spawn or exec trap takes one instead of building it on the trapping
    /// thread. A trap that finds none ready still builds its own (off the
    /// kernel lock, as before).
    static let async = enabled && (getenv("YCODE_VM_PREBUILD_ASYNC").map { String(cString: $0) != "0" } ?? true)
    static let limit = 2
    static let asyncLimit = getenv("YCODE_VM_PREBUILD_READY").flatMap { Int(String(cString: $0)) }.map { max(1, min(16, $0)) } ?? 4
    /// `YCODE_VCPU_PREBUILT` (default on, `=0` off): the image's first
    /// vCPUs (`YCODE_VCPU_PRECREATE`, vCPU 0 among them) are made with the
    /// prebuilt VM, off the kernel lock (thread-latency.md §3.1); off: at
    /// image build, under the lock.
    static let precreateVCPUs = getenv("YCODE_VCPU_PREBUILT").map { String(cString: $0) != "0" } ?? true

    /// Builds one VM (and, with `precreateVCPUs`, its first vCPUs). No lock held.
    static func build() -> ProcessBuilder? {
        let builder = try? ProcessBuilder(log: nil)
        if precreateVCPUs { builder?.vm.makeSpareVCPUs(count: VirtualMachine.precreateCount) }
        return builder
    }
    private let lock = HostMutex(name: "prebuilt VMs")
    private let wanted = HostCondition()
    private var ready: [ProcessBuilder] = []
    /// Builds in progress (counted toward `limit`).
    private var building = 0
    private var builderStarted = false

    /// Builds one VM unless `limit` are ready or being built. Call with no
    /// lock held. With the background builder: nothing when one is ready.
    func prepare() {
        guard Self.enabled else { return }
        if Self.async {
            startBuilder()
            let start: Bool = lock.withLock {
                if !ready.isEmpty { return false }
                building += 1
                return true
            }
            guard start else { return }
            // None ready: build one here, as without the builder.
            let builder = Self.build()
            lock.withLock {
                building -= 1
                if let builder { ready.append(builder) }
            }
            return
        }
        let start: Bool = lock.withLock {
            guard ready.count + building < Self.limit else { return false }
            building += 1
            return true
        }
        guard start else { return }
        let builder = Self.build()
        lock.withLock {
            building -= 1
            if let builder { ready.append(builder) }
        }
    }

    /// Starts the background builder once (with `async`).
    func startBuilder() {
        guard Self.async else { return }
        let start: Bool = lock.withLock {
            if builderStarted { return false }
            builderStarted = true
            return true
        }
        guard start else { return }
        let thread = Thread { [self] in builderLoop() }
        thread.name = "ycode VM prebuild"
        thread.start()
    }

    /// A ready VM, or nil (the caller builds one).
    func take() -> ProcessBuilder? {
        lock.withLock {
            let b = ready.popLast()
            if Self.async { wanted.signal() }
            return b
        }
    }

    /// The background builder: tops the ready list up to `asyncLimit`.
    private func builderLoop() {
        while true {
            lock.lock()
            while ready.count >= Self.asyncLimit { wanted.wait(lock, milliseconds: 1000) }
            lock.unlock()
            guard let builder = Self.build() else { usleep(100_000); continue }
            lock.withLock { ready.append(builder) }
        }
    }
}

/// The trap-log prefix of the trap a host thread is handling (one host
/// thread runs one vCPU of one image, so one key serves every image).
let trapPrefix = PerThreadString()

/// Diagnostics: `YCODE_DEBUG_NO_VM_CLOSE=1` keeps every ended image's VM open.
nonisolated(unsafe) var keptVMsForDebugging: [VirtualMachine]? =
    getenv("YCODE_DEBUG_NO_VM_CLOSE").map { String(cString: $0) == "1" } ?? false ? [] : nil
let keptVMsLock = NSLock()

/// What the summary keeps about one image after its VM is gone.
final class ImageRecord: @unchecked Sendable {
    /// 1 for the first image of the run, then in launch order.
    let serial: Int
    let pid: Int32
    let executable: String
    /// How the image ended (nil while it runs).
    var end: VCPUPool.Termination?
    /// The VMM's summary of the image, fixed at teardown.
    var finalSummary: String?
    /// Unimplemented traps and host-library functions the image hit (counts).
    var finalUnimplemented: String?
    var tornDown = false
    /// The live image until teardown.
    var image: GuestImageInstance?
    /// Boot profile (`YCODE_BOOT_PROFILE`, BootProfile.swift): the parent
    /// pid at launch and the image's milestones (monotonic ns; 0 = not yet).
    var ppid: Int32 = 0
    var launchNs: UInt64 = 0
    var builtNs: UInt64 = 0
    var milestoneNs: UInt64 = 0
    var endNs: UInt64 = 0
    var tornDownNs: UInt64 = 0
    /// Fixed at teardown: the vCPU threads' host counters, the image's
    /// kernel-lock time, first guest entry, traps.
    var hostStats: VCPUPool.HostStats?
    var lockHeldNs: UInt64 = 0
    var lockWaitNs: UInt64 = 0
    var lockAcquisitions: UInt64 = 0
    var firstRunNs: UInt64 = 0
    var traps = 0
    var taskLocalTraps = 0
    var vcpus = 0
    /// At the milestone: traps, lock wait and hold, the main thread's CPU.
    var milestoneTraps = 0
    var milestoneLockWaitNs: UInt64 = 0
    var milestoneLockHeldNs: UInt64 = 0
    var milestoneCPUNs: UInt64 = 0
    var milestoneGuestTicks: UInt64 = 0
    var milestoneSystemTicks: UInt64 = 0
    var milestoneRunNs: UInt64 = 0
    var milestoneHandlerNs: UInt64 = 0
    var milestoneTopTraps = ""

    init(serial: Int, pid: Int32, executable: String) {
        self.serial = serial
        self.pid = pid
        self.executable = executable
    }

    var endDescription: String {
        guard let end else { return "running" }
        switch end.kind {
        case .terminated: return end.message.hasPrefix("guest exited") ? "exit \(end.status)" : "ended with status \(end.status)"
        case .ended: return end.message
        case .stopped: return "stopped"
        }
    }
}

/// The handle P keeps for a launched image (weak: P's records never keep a VM alive).
final class LaunchHandle: LaunchedImage {
    weak var image: GuestImageInstance?
    init(_ image: GuestImageInstance) { self.image = image }
    func resume() { image?.resumeSuspended() }
}

/// The VMM's `ProcessLauncher`: builds one VM per image.
final class VMMLauncher: ProcessLauncher, @unchecked Sendable {
    let config: ExecConfiguration
    private let lock = HostMutex(name: "VMM launcher")
    private let changed = HostCondition()
    private var live: [GuestImageInstance] = []
    private var finishedImages: [GuestImageInstance] = []
    private(set) var records: [ImageRecord] = []
    /// Wait statuses from `DarwinSystem.processExited`.
    private var waitStatuses: [Int32: Int32] = [:]
    private var rootExitSeen: UInt64?
    private var abortRequest: (status: Int32, message: String)?
    private var serial = 0
    /// Set once a second image exists: every trace line then carries `[pid N]`.
    let multiImage = Atomic<Bool>(false)
    /// The system clock: the first VM's counter offset (host − guest) and
    /// the host counter at its start. Later VMs are aligned to it.
    private var systemCounterOffset: UInt64?
    private var systemBootHostCounter: UInt64 = 0
    private var systemCounterFrequency: UInt64 = 0

    /// The system clock in counter units (`snapshot.md` §5): the guest
    /// counter now (host counter − system offset), the boot counter, and the
    /// counter frequency; nil before the first VM.
    var snapshotSystemClock: (guestCounter: UInt64, bootCounter: UInt64, frequency: UInt64)? {
        lock.withLock {
            guard let offset = systemCounterOffset else { return nil }
            return (Hypervisor.hostCounter() &- offset, systemBootHostCounter &- offset, systemCounterFrequency)
        }
    }
    /// The last launch failure's detail (for the root's error message).
    private(set) var lastLaunchFailure: String?
    /// VMs built ahead, off the kernel lock, for spawn and exec.
    let prebuilt = PrebuiltVMs()

    init(config: ExecConfiguration) {
        self.config = config
        if !config.trace { prebuilt.startBuilder() }
    }

    /// "[pid N] " once several images exist.
    func tag(_ pid: Int32) -> String { multiImage.load(ordering: .relaxed) ? "[pid \(pid)] " : "" }

    // MARK: ProcessLauncher

    func launch(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> any LaunchedImage {
        let image = try build(request, kernel: kernel)
        return try register(image, startSuspended: request.startSuspended)
    }

    /// A built image (`prepare`).
    final class Prepared: PreparedImage {
        let image: GuestImageInstance
        init(_ image: GuestImageInstance) { self.image = image }
    }

    /// Builds the image without registering it: safe without the kernel
    /// lock (the new kernel is not visible to other threads yet;
    /// bsd-locking.md §7).
    func prepare(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> (any PreparedImage)? {
        Prepared(try build(request, kernel: kernel))
    }

    func activate(_ prepared: any PreparedImage, startSuspended: Bool) throws -> any LaunchedImage {
        try register((prepared as! Prepared).image, startSuspended: startSuspended)
    }

    func discard(_ prepared: any PreparedImage) {
        (prepared as! Prepared).image.abandon()
    }

    private func noteFailure(_ text: String) -> String {
        lock.withLock { lastLaunchFailure = text }
        return text
    }

    private func build(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> GuestImageInstance {
        let number: Int = lock.withLock {
            serial += 1
            if serial > 1 { multiImage.store(true, ordering: .relaxed) }
            return serial
        }
        do {
            return try GuestImageInstance(launcher: self, serial: number, request: request, kernel: kernel)
        } catch let error as DarwinErrnoError {
            let text = noteFailure("\(request.executablePath): \(error)")
            if config.trace || number == 1 { stderrLine("ycode-simd: \(tag(kernel.pid))cannot launch \(text)") }
            throw error
        } catch {
            let text = noteFailure("\(request.executablePath): \(error)")
            stderrLine("ycode-simd: \(tag(kernel.pid))cannot build a VM for \(text)")
            throw DarwinErrnoError(LaunchErrno.ENOMEM)
        }
    }

    /// Registers a built image and starts its main thread. Kernel lock held.
    private func register(_ image: GuestImageInstance, startSuspended: Bool) throws -> any LaunchedImage {
        let kernel = image.kernel
        if BootProfile.shared != nil { image.record.ppid = kernel.system.process(pid: kernel.pid)?.ppid ?? 0 }
        lock.withLock {
            live.append(image)
            records.append(image.record)
        }
        // Frame profile: who launched the image (FrameProfile.swift).
        if FrameProfile.active.load(ordering: .relaxed), let fp = FrameProfile.shared {
            fp.imageLaunched(pid: kernel.pid, serial: image.record.serial, executable: image.record.executable, suspended: startSuspended)
        }
        if !startSuspended {
            do {
                try image.startMainThread()
            } catch {
                let text = noteFailure("\(image.record.executable): \(error)")
                stderrLine("ycode-simd: \(tag(kernel.pid))cannot start \(text)")
                image.abandon()
                lock.withLock {
                    live.removeAll { $0 === image }
                    finishedImages.removeAll { $0 === image }
                    records.removeAll { $0 === image.record }
                }
                throw DarwinErrnoError(LaunchErrno.ENOMEM)
            }
        }
        return LaunchHandle(image)
    }

    /// SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §3.1, §5): the
    /// live images, and the restore's system clock (the guest counter
    /// continues at the snapshot's value; set before the first VM is built).
    var snapshotLiveImages: [GuestImageInstance] { lock.withLock { live } }
    func snapshotPresetSystemClock(offset: UInt64, bootHostCounter: UInt64) {
        lock.withLock {
            systemCounterOffset = offset
            systemBootHostCounter = bootHostCounter
        }
    }

    /// The counter offset and boot counter a new VM uses (the first VM sets
    /// the system's). Called while building an image.
    func systemClock(for vcpu: VCPU, frequency: UInt64, log: (String) -> Void) throws -> (offset: UInt64, bootCounter: UInt64) {
        try systemClock(for: vcpu, vm: nil, frequency: frequency, log: log).clock
    }

    /// As above; with `vm` and `YCODE_FAST_TRAPS=1` the VM gets the system's
    /// offset VM-wide (KVM_ARM_SET_COUNTER_OFFSET, fast-traps.md §3.1) and
    /// `direct` says that every vCPU of it reads the kernel's clock in place.
    /// Call before any vCPU of the VM runs.
    func systemClock(for vcpu: VCPU, vm: VirtualMachine?, frequency: UInt64, log: (String) -> Void) throws
        -> (clock: (offset: UInt64, bootCounter: UInt64), direct: Bool) {
        let own = try vcpu.counterOffset()
        lock.withLock { systemCounterFrequency = frequency }
        if FastTraps.enabled, let vm, vm.supportsCounterOffset {
            let system: UInt64 = lock.withLock {
                if systemCounterOffset == nil {
                    systemCounterOffset = own
                    systemBootHostCounter = Hypervisor.hostCounter()
                }
                return systemCounterOffset!
            }
            do {
                try vm.setCounterOffset(system)
                let boot = lock.withLock { systemBootHostCounter } &- system
                return ((system, boot), true)
            } catch {
                log("cannot set the VM-wide counter offset: \(error)")
            }
        }
        let system: UInt64? = lock.withLock {
            if systemCounterOffset == nil {
                systemCounterOffset = own
                systemBootHostCounter = Hypervisor.hostCounter()
            }
            return systemCounterOffset
        }
        var offset = own
        if let system, system != own {
            // Give this VM the system's mach_absolute_time base.
            do {
                try vcpu.setVirtualCounter(Hypervisor.hostCounter() &- system)
                offset = try vcpu.counterOffset()
            } catch {
                log("cannot align the guest counter: \(error)")
            }
            let drift = Int64(bitPattern: offset &- system)
            if drift.magnitude > frequency / 1000 {
                log("warning: guest counter differs from the system's by \(drift) ticks")
            }
        }
        let boot = lock.withLock { systemBootHostCounter } &- offset
        return ((offset, boot), false)
    }

    // MARK: Events from images and the kernel

    /// A thread ended the image (it is stopping now). Any host thread.
    func imageEnded(_ image: GuestImageInstance, _ end: VCPUPool.Termination) {
        lock.withLock {
            if image.record.end == nil || image.record.end!.kind == .stopped { image.record.end = end }
            if BootProfile.shared != nil, image.record.endNs == 0 { image.record.endNs = monotonicNanoseconds() }
            changed.broadcast()
        }
    }

    /// Every vCPU thread of the image returned (`VCPUPool.onFinished`).
    func imageFinished(_ image: GuestImageInstance) {
        lock.withLock {
            finishedImages.append(image)
            changed.broadcast()
        }
    }

    /// `DarwinSystem.processExited` (the kernel lock is held).
    func processExited(pid: Int32, status: Int32) {
        lock.withLock {
            waitStatuses[pid] = status
            if pid == rootPID, rootExitSeen == nil { rootExitSeen = monotonicMilliseconds() }
            changed.broadcast()
        }
        if config.trace { stderrLine("ycode-simd: \(tag(pid))process \(pid) exited (wait status \(hex(UInt64(UInt32(bitPattern: status)))))") }
    }

    /// Ends the whole host (debug exits 72/73).
    func abortHost(status: Int32, message: String) {
        lock.withLock {
            if abortRequest == nil { abortRequest = (status, message) }
            changed.broadcast()
        }
    }

    // MARK: Supervision

    /// Waits for the root process to end, tearing down finished images on
    /// the way. Returns the host's exit status and a message.
    func superviseRoot(timeoutMilliseconds: UInt64) -> (status: Int32, message: String, watchdog: Bool) {
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        while true {
            lock.lock()
            while finishedImages.isEmpty && abortRequest == nil && rootResultLocked(final: false) == nil
                    && monotonicMilliseconds() < deadline {
                // Wake at least every 100 ms (the grace period after processExited).
                changed.wait(lock, milliseconds: min(100, max(1, deadline &- monotonicMilliseconds())))
            }
            let batch = finishedImages
            finishedImages.removeAll()
            let abort = abortRequest
            lock.unlock()
            for image in batch { tearDown(image) }
            if let abort { return (abort.status, abort.message, false) }
            if let result = lock.withLock({ rootResultLocked(final: false) }) { return (result.status, result.message, false) }
            if monotonicMilliseconds() >= deadline {
                if let result = lock.withLock({ rootResultLocked(final: true) }) { return (result.status, result.message, false) }
                return (71, "watchdog: guest still running after \(timeoutMilliseconds) ms", true)
            }
        }
    }

    /// The root's result once known. The image's own end (exit status,
    /// fatal 70/134, VMM 71) wins; a wait status alone decides after a grace
    /// period (the root was killed, or its image is still stopping).
    private func rootResultLocked(final: Bool) -> (status: Int32, message: String)? {
        if let record = records.last(where: { $0.pid == rootPID && $0.end?.kind == .terminated }), let end = record.end {
            return (end.status, end.message)
        }
        guard let status = waitStatuses[rootPID] else { return nil }
        let graceOver = final || (rootExitSeen.map { monotonicMilliseconds() >= $0 + 500 } ?? true)
        guard graceOver else { return nil }
        return (Self.hostStatus(waitStatus: status), "process \(rootPID) ended: \(Self.describe(waitStatus: status))")
    }

    static func hostStatus(waitStatus w: Int32) -> Int32 {
        let low = w & 0x7F
        if low == 0 { return (w >> 8) & 0xFF }
        return 128 + low
    }

    static func describe(waitStatus w: Int32) -> String {
        let low = w & 0x7F
        if low == 0 { return "exit \((w >> 8) & 0xFF)" }
        if low == 0x7F { return "stopped by signal \((w >> 8) & 0xFF)" }
        return "signal \(low)" + (w & 0x80 != 0 ? " (core)" : "")
    }

    func waitStatus(of pid: Int32) -> Int32? { lock.withLock { waitStatuses[pid] } }

    /// Stops every live image and tears down those whose threads return
    /// within `milliseconds`. Returns the images still alive.
    @discardableResult
    func stopAll(milliseconds: UInt64) -> Int {
        let images = lock.withLock { live }
        for image in images {
            // The process layer ends the process (its blocked threads wake);
            // the kicks end the vCPUs running guest code.
            image.kernel.lock.withLock {
                if !image.kernel.isTerminating { image.kernel.postSignal(9) }
            }
            image.pool.requestStop("stopped at host exit")
        }
        let deadline = monotonicMilliseconds() + milliseconds
        for image in images {
            let now = monotonicMilliseconds()
            // Every host thread returned (joinThreads in tearDown also waits
            // for the last one to leave onFinished).
            if image.pool.waitUntilFinished(milliseconds: deadline > now ? deadline - now : 0) { tearDown(image) }
        }
        lock.withLock { finishedImages.removeAll { $0.record.tornDown } }
        return lock.withLock { live.count }
    }

    /// Tears down finished images until none is live or the deadline
    /// passes (the debug extra images). Returns the images still live.
    func superviseAll(deadline: UInt64) -> Int {
        while true {
            lock.lock()
            while finishedImages.isEmpty && !live.isEmpty && monotonicMilliseconds() < deadline {
                changed.wait(lock, milliseconds: 100)
            }
            let batch = finishedImages
            finishedImages.removeAll()
            lock.unlock()
            for image in batch { tearDown(image) }
            let remaining = liveCount
            if remaining == 0 || monotonicMilliseconds() >= deadline { return remaining }
        }
    }

    /// The watchdog: where every vCPU of every live image is.
    /// Diagnostics: vCPUs that have been inside one trap handler for `ms`
    /// or more (kind 0 = SVC, otherwise a fault; ESR; the thread's state).
    func longHandlerReport(ms: UInt64) -> [String] {
        let images = lock.withLock { live }
        var lines: [String] = []
        for image in images {
            for w in image.pool.longHandlers(atLeast: ms) {
                let ctx = w.context as? ThreadContext
                let since = monotonicMilliseconds() &- w.handlerSince.load(ordering: .relaxed)
                var text = "\(tag(image.pid))vCPU \(w.index) (host tid \(w.hostTID.load(ordering: .relaxed))) in a handler for \(since) ms: kind \(w.lastTrapKind.load(ordering: .relaxed)) "
                    + "x16 \(Int64(bitPattern: w.lastTrapX16.load(ordering: .relaxed))) ESR \(hex(w.lastTrapESR.load(ordering: .relaxed))) "
                    + "ELR \(hex(w.lastTrapELR.load(ordering: .relaxed)))"
                if let ctx {
                    text += "; thread \(ctx.threadID) arriving \(ctx.arrivingTrap.map { String(Int64(bitPattern: $0)) } ?? "-") "
                        + "in kernel \(ctx.trapInProgress.map { String(Int64(bitPattern: $0.x16)) } ?? "-") blocked \(ctx.blockedInKernel)"
                }
                lines.append(text)
            }
        }
        return lines
    }

    /// Diagnostics: vCPUs in guest code with no exit for `ms` (kicked to
    /// sample; a kicked vCPU that keeps running exits at once, so a vCPU
    /// listed again with the same sample count is not taking the kick).
    func longGuestRunReport(ms: UInt64) -> [String] {
        let images = lock.withLock { live }
        var lines: [String] = []
        for image in images {
            for w in image.pool.longGuestRuns(atLeast: ms) {
                let ctx = w.context as? ThreadContext
                lines.append("\(tag(image.pid))vCPU \(w.index) (thread \(ctx.map { String($0.threadID) } ?? "?")) no VM exit for "
                    + "\(monotonicMilliseconds() &- w.lastExitMs.load(ordering: .relaxed)) ms; sample #\(w.sampleCount.load(ordering: .relaxed)): "
                    + "pc \(hex(w.samplePC.load(ordering: .relaxed))) = \(image.describeAddress(w.samplePC.load(ordering: .relaxed))) "
                    + "pstate \(hex(w.samplePSTATE.load(ordering: .relaxed))) ELR_EL1 \(hex(w.sampleELR1.load(ordering: .relaxed))) "
                    + "ESR_EL1 \(hex(w.sampleESR1.load(ordering: .relaxed)))")
            }
        }
        return lines
    }

    /// Diagnostics: the root process's vCPUs.
    func rootWorkerStates() -> [String] {
        let images = lock.withLock { live }
        return images.filter { $0.pid == rootPID }.flatMap { $0.pool.workerStates() }
    }

    func watchdogReport() -> String {
        let images = lock.withLock { live }
        return images.map { image in
            "  \(tag(image.pid))\(image.record.executable):\n" + image.pool.stopAll(milliseconds: 500)
        }.joined(separator: "\n")
    }

    /// Joins the image's threads and destroys its VM.
    private func tearDown(_ image: GuestImageInstance) {
        guard !image.record.tornDown else { return }
        image.pool.joinThreads()
        if BootProfile.shared != nil { image.captureProfile() }
        image.record.finalSummary = image.summary(locked: true)
        image.record.finalUnimplemented = image.unimplementedSummary()
        image.destroy()
        lock.withLock {
            image.record.tornDown = true
            image.record.image = nil
            if image.record.end == nil { image.record.end = image.pool.currentTermination }
            live.removeAll { $0 === image }
        }
        if config.trace { stderrLine("ycode-simd: \(tag(image.pid))image \(image.record.serial) torn down (\(image.record.endDescription))") }
    }

    var liveCount: Int { lock.withLock { live.count } }
}

/// One image (one VM) of a guest process.
final class GuestImageInstance: @unchecked Sendable {
    /// Strong, like the pool's closures below: an image whose threads never
    /// return (stuck in the kernel) leaks instead of crashing. The cycles
    /// end at teardown (`VCPUPool.joinThreads`, removal from `live`).
    let launcher: VMMLauncher
    let record: ImageRecord
    let kernel: DarwinKernel
    let pid: Int32
    let vm: VirtualMachine
    let space: GuestAddressSpace
    let pool: VCPUPool
    let images: ImageMap
    let fileSystem: DarwinFileSystem
    private let options: Options
    private let trace: Bool
    private var mainState: VCPUStartState?
    private var destroyed = false

    // Bookkeeping guarded by the kernel lock.
    private var milestoneReached = false
    /// Boot profile: traps before the milestone by number (faults: -1000).
    private var preMilestoneTraps: [Int64: Int] = [:]
    private var tracker = CacheMappingTracker()
    /// Lock-free: counted on every trap, from any vCPU thread.
    private let trapCountAtomic = Atomic<Int>(0)
    /// Traps answered without the kernel lock (`handleTaskLocal`).
    let taskLocalTrapCount = Atomic<Int>(0)
    /// Mirrors `milestoneReached` for the unlocked fast path.
    private let milestoneDone = Atomic<Bool>(false)
    private var trapCounts: [String: Int] = [:]
    /// True once a kernel outcome ended the image (exit, fatal, exec).
    private let endedByKernel = Atomic<Bool>(false)
    /// True once one thread printed the image's fatal report: a process ends
    /// with one report, its first faulting thread's (`service-fidelity.md` §3).
    private let fatalReported = Atomic<Bool>(false)

    /// VMM log line (with the pid tag once several images exist).
    func say(_ text: String) { stderrLine("ycode-simd: " + launcher.tag(pid) + text) }

    init(launcher: VMMLauncher, serial: Int, request: ProcessImageRequest, kernel: DarwinKernel) throws {
        let config = launcher.config
        self.launcher = launcher
        self.kernel = kernel
        self.pid = kernel.pid
        self.options = config.options
        // `--trace-pid N`: this process only (unimplemented calls then
        // behave as with --keep-going).
        let trace = config.trace || config.options.tracePIDs.contains(kernel.pid)
            || config.options.traceNames.contains((request.executablePath as NSString).lastPathComponent)
        self.trace = trace
        self.fileSystem = kernel.fileSystem
        let execPath = request.executablePath
        if !TrapProfile.programFilter.isEmpty {
            kernel.trapProfileSelected = TrapProfile.programFilter.contains((execPath as NSString).lastPathComponent)
        }
        let verbose = trace || (serial == 1 && !config.quietRuns)
        record = ImageRecord(serial: serial, pid: kernel.pid, executable: execPath)
        if BootProfile.shared != nil {
            // (`ppid` is set when the image is registered, under the kernel lock.)
            record.launchNs = monotonicNanoseconds()
        }
        let pid = kernel.pid
        func say(_ text: String) { stderrLine("ycode-simd: " + launcher.tag(pid) + text) }

        // The executable must be an arm64 iOS-simulator Mach-O executable.
        try Self.checkExecutable(hostPath: request.hostExecutablePath)

        var buildTimer = ImageBuildProfile.shared.map { _ in ImageBuildProfile.Timer() }
        let builder = try (trace ? nil : launcher.prebuilt.take()) ?? ProcessBuilder(log: trace ? { say($0) } : nil)
        buildTimer?.mark()
        VMCounters.shared.vmCreated()
        vm = builder.vm
        space = builder.space
        var poolForCleanup: VCPUPool?
        do {
            let vm = builder.vm, space = builder.space
            if verbose {
                say("KVM memslots available: \(vm.maxMemorySlots); RAM \(VMLayout.stage3RAMSize >> 20) MiB; anonymous pool \(VMLayout.anonymousPoolSize >> 30) GiB at \(hex(VMLayout.anonymousPoolGPA))")
            }
            try vm.write(gpa: VMLayout.shimGPA, bytes: config.shim)

            let main = try builder.loadMainExecutable(path: execPath, hostPath: request.hostExecutablePath)
            let sim = try builder.loadDyldSim(path: config.dyldSimPath, guestPath: config.dyldSimPath, base: VMLayout.dyldSimBaseVA)
            buildTimer?.mark()
            guard let prepareEntry = sim.entry else { throw LoaderError.message("dyld_sim entry not found") }
            if verbose {
                say("main \(execPath) at \(hex(main.machHeader)); dyld_sim at \(hex(sim.machHeader)) slide \(hex(sim.slide)) entry \(hex(prepareEntry))")
            }

            // Main stack and the kernel argument block (darwin-process-start.md §1.3).
            _ = try space.mapAnonymous(at: VMLayout.userStackBase, size: VMLayout.userStackSize, protection: .readWrite, hint: nil)
            let apple = AppleStrings(executablePath: execPath)
            let arguments = KernelArgumentBlock(userStack: VMLayout.userStackTop, argv: request.argv, envp: request.envp,
                                                apple: apple.strings + request.apple, machHeader: main.machHeader)
            try builder.poke(arguments.stackPointer, arguments.bytes)

            // The Ycode host page (§5): code RX, helpers RO, data RW.
            let hostBase = VMLayout.hostPageVA
            try space.mapPermanentAnonymous(at: hostBase + VMLayout.hostPageCodeOffset, size: VMLayout.hostPageCodeSize, protection: .readExecute)
            try space.mapPermanentAnonymous(at: hostBase + VMLayout.hostPageRODataOffset, size: VMLayout.hostPageRODataSize, protection: .read)
            try space.mapPermanentAnonymous(at: hostBase + VMLayout.hostPageRWDataOffset, size: VMLayout.hostPageRWDataSize, protection: .readWrite)
            try builder.poke(hostBase, config.stubs)
            let storage = DyldImageInfoStorage(base: HostPageLayout.imageInfoStorage,
                                               images: [.init(loadAddress: main.machHeader, path: execPath)])
            guard UInt64(storage.bytes.count) <= HostPageLayout.imageInfoStorageSize else { throw LoaderError.message("image info storage overflows") }
            try builder.poke(storage.infoArrayAddress, storage.bytes)
            let infos = DyldAllImageInfos.initial(infoArray: storage.infoArrayAddress, notification: hostBase + hostPageRetStubOffset,
                                                  simMH: sim.machHeader)
            try builder.poke(HostPageLayout.allImageInfos, infos.encoded())
            let launch = LaunchBlock(prepareEntry: prepareEntry, arguments: arguments, mainMH: main.machHeader,
                                     simMH: sim.machHeader, simSlide: sim.slide)
            try builder.poke(HostPageLayout.launchBlock, launch.encoded())

            // Commpage (§6): RO page and RW-data page, both EL0 read-only.
            let commpage = CommpageBuilder()
            try space.mapPermanentAnonymous(at: VMLayout.readOnlyCommpageVA, size: pageSize, protection: .read)
            try space.mapPermanentAnonymous(at: VMLayout.commpageVA, size: pageSize, protection: .read)
            try builder.poke(VMLayout.readOnlyCommpageVA, commpage.roPage())
            try builder.poke(VMLayout.commpageVA, commpage.rwPage())

            if config.trace {
                for region in space.regions { say("region \(region)") }
                say("argument block at \(hex(arguments.stackPointer)) (argc \(arguments.argc)); \(vm.memorySlotCount) memslots")
            }

            // The main thread's pthread/TSD block (host-libraries.md §8.3).
            let threadBlock = MainThreadBlock(address: Stage3Layout.mainThreadPage, threadID: 1, threadPort: WellKnownPort.thread,
                                              stackTop: VMLayout.userStackTop, stackSize: VMLayout.userStackSize,
                                              qos: DarwinKernel.mainThreadQoS, ptrMunge: apple.ptrMunge)
            _ = try space.mapAnonymous(at: Stage3Layout.mainThreadPage, size: Stage3Layout.mainThreadPageSize,
                                       protection: .readWrite, hint: nil)
            try builder.poke(threadBlock.address, threadBlock.bytes)
            if verbose { say("main-thread block at \(hex(threadBlock.address)); TPIDRRO_EL0 = \(hex(threadBlock.tsdBase))") }

            // Boot info template, the vCPU pool, and vCPU 0 (stage4a-contract.md §2, §4).
            buildTimer?.mark()
            let doorbell = FastTraps.doorbellAddress(for: vm, log: { say($0) })
            let pool = try VCPUPool(vm: vm, bootTemplate: BootInfo(ttbr0EL1: space.pageTables.rootGPA, el0EntryPC: 0,
                                                                   doorbellAddress: doorbell),
                                    maxExitsPerVCPU: config.maxExits)
            poolForCleanup = pool
            if config.trace { pool.log = { say($0) } }
            let vcpu0 = try pool.createWorker().vcpu
            buildTimer?.mark()
            let (frequency, frequencySource) = vcpu0.counterFrequency()
            let (clock, directClock) = try launcher.systemClock(for: vcpu0, vm: vm, frequency: frequency, log: { say($0) })
            buildTimer?.mark()
            if verbose {
                say("CNTFRQ_EL0 = \(frequency) Hz (\(frequencySource)); KVM_CAP_MAX_VCPUS \(vm.maxVCPUs), "
                    + "KVM_CAP_NR_VCPUS \(vm.recommendedVCPUs); vCPU pool capacity \(pool.capacity)")
            }
            if config.trace {
                let guestMMFR2 = (try? vcpu0.get(SystemRegister.idAA64MMFR2EL1)) ?? 0
                say("ID_AA64MMFR2_EL1.FWB host \((Hypervisor.hostIDAA64MMFR2() >> 40) & 0xF) guest \((guestMMFR2 >> 40) & 0xF)"
                    + " (boot info and frames are also cleaned to PoC before a vCPU's first run)")
            }
            self.pool = pool
            // A thread ended and its vCPU is free: workqueue requests that
            // waited for a vCPU may start now.
            pool.onParked = { [weak kernel = self.kernel] in kernel?.retryPendingWorkqueue() }

            // Image attribution.
            let images = ImageMap(cache: config.cacheIndex)
            images.fixed = [
                main.image,
                sim.image,
                GuestImage(name: "ycode host page", start: hostBase, end: hostBase + VMLayout.hostPageSize, base: hostBase),
                GuestImage(name: "ycode main-thread block", start: Stage3Layout.mainThreadPage,
                           end: Stage3Layout.mainThreadPage + Stage3Layout.mainThreadPageSize, base: threadBlock.address),
            ]
            images.space = space
            images.hostLibraryPaths = config.hostLibraryPaths
            self.images = images

            // Wire the kernel (§3.3). Its log carries the trap's prefix.
            let offset = clock.offset
            kernel.log = { [weak launcher] line in
                if trace { stderrLine((launcher?.tag(pid) ?? "") + trapPrefix.value + line) }
            }
            // Without a trace the kernel formats no trap text at all.
            kernel.tracing = trace
            // Guest mach time: the aligned counter, scaled to the guest
            // timebase (24 MHz unless YCODE_GUEST_TIMEBASE=host) with the
            // fixed-point scale the guest library also uses in place
            // (fast-traps.md §3.2).
            let guestHz = GuestTimebase.frequency(hostFrequency: frequency)
            let clockScale = GuestTimebase.ClockScale(from: frequency, to: guestHz)
            if clockScale == .identity {
                kernel.counter = { Hypervisor.hostCounter() &- offset }
            } else {
                kernel.counter = { clockScale.apply(Hypervisor.hostCounter() &- offset) }
            }
            kernel.counterFrequency = guestHz
            kernel.timeOfDayPublisher = try FastTraps.configureCommpage(
                space: space, vm: vm, directClock: directClock, counter: kernel.counter, frequency: guestHz,
                clockScale: clockScale, wallClock: kernel.wallClock)
            kernel.bootCounter = clockScale.apply(clock.bootCounter)
            kernel.allImageInfosAddress = HostPageLayout.allImageInfos
            kernel.mainStackTop = VMLayout.userStackTop
            kernel.threadHost = PoolThreadHost(pool: pool)
            // getrusage(RUSAGE_SELF): the image's host threads' CPU, split
            // into user and system by their tick counts.
            kernel.processCPUTimes = { [weak pool] in
                guard let pool else { return (0, 0) }
                var total: UInt64 = 0, userTicks: UInt64 = 0, systemTicks: UInt64 = 0
                for tid in pool.hostThreadIDs {
                    guard let s = hostTaskStats(tid) else { continue }
                    userTicks &+= s[0]
                    systemTicks &+= s[1]
                    total &+= s[5]
                }
                let ticks = userTicks &+ systemTicks
                let system = ticks == 0 ? 0 : UInt64(Double(total) * Double(systemTicks) / Double(ticks))
                return (total &- system, system)
            }
            kernel.executableUUID = uuidBytes(main.uuid)

            mainState = VCPUStartState(pc: VMLayout.hostPageEntryVA, sp: arguments.stackPointer, tpidrro: threadBlock.tsdBase)
            if var timer = buildTimer {
                timer.mark()
                ImageBuildProfile.shared?.record(timer)
            }
        } catch {
            poolForCleanup?.shutdown()
            builder.vm.close()
            VMCounters.shared.vmDestroyed()
            if let error = error as? DarwinErrnoError { throw error }
            throw error
        }
        record.image = self
        if BootProfile.shared != nil { record.builtNs = monotonicNanoseconds() }

        // Pool callbacks (cleared by `VCPUPool.joinThreads` at teardown).
        let shimCount = config.shim.count
        let lock = kernel.lock
        let space = self.space
        pool.preBootCleanRanges = {
            // Before a fresh vCPU's first run (MMU off, non-cacheable reads):
            // the shim image and the tables in use, read under the kernel lock.
            lock.withLock { [(VMLayout.shimGPA, shimCount),
                             (stage4TableArenaGPA, space.pageTables.tableCount * Int(VMLayout.pageSize))] }
        }
        let kernel = self.kernel
        pool.shouldStop = { kernel.isTerminating }
        pool.trapHandler = { worker, frame in self.handleTrap(worker, &frame) }
        pool.exitHandler = { worker, exit in
            dumpVCPU(worker.vcpu)
            if self.pid != rootPID { self.say("unexpected VM exit on vCPU \(worker.index): \(exit)") }
            return .terminate(status: 71, message: "unexpected VM exit on vCPU \(worker.index): \(exit)")
        }
        pool.onEnd = { end in self.launcher.imageEnded(self, end) }
        pool.onFinished = { self.finished() }
        if BootProfile.pcHz > 0 {
            // The PC samples' call chains (frame pointers; at most 8 frames,
            // each 16 bytes of guest stack read through the address space).
            pool.sampleStackReader = { [weak space] fp in
                guard let space else { return [] }
                var out: [UInt64] = []
                var frame = fp
                for _ in 0..<8 {
                    guard frame != 0, frame & 7 == 0,
                          let raw = try? space.read(va: frame, count: 16, checkingEL0Access: true) else { break }
                    func word(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[o + $1]) << (8 * UInt64($1)) } }
                    out.append(word(8))
                    let next = word(0)
                    guard next > frame else { break }
                    frame = next
                }
                return out
            }
        }
        // SNAPSHOT hook (agent SNAP, specs/simulator/snapshot.md §3.1, §7
        // step 9): the quiesce gates and the restore hook wrap the pool's
        // callbacks before any thread runs. Nil (nothing done) unless a
        // YCODE_SNAPSHOT_* or YCODE_RESTORE_DIR variable is set.
        SnapshotSupport.shared?.attach(self)
    }

    /// The main thread on vCPU 0 (§6 initial state, with host-libraries.md
    /// §8.3's TPIDRRO_EL0).
    func startMainThread() throws {
        guard let state = mainState else { return }
        mainState = nil
        if FrameProfile.active.load(ordering: .relaxed), let fp = FrameProfile.shared {
            fp.startRequested(pid: pid, context: kernel.mainThread, mainThread: true, serial: record.serial)
        }
        guard let index = try pool.start(state, context: kernel.mainThread) else {
            throw KVMError("vCPU pool", detail: "vCPU 0 is unavailable")
        }
        kernel.mainThread.vcpuIndex = index
    }

    /// SNAPSHOT hook (snapshot.md §3.2 `unstarted`): the main thread's start
    /// state while the image was launched suspended and not resumed (a
    /// start hold), and its replacement after a restore. Kernel lock held.
    var snapshotMainState: VCPUStartState? {
        get { mainState }
        set { mainState = newValue }
    }

    /// `LaunchedImage.resume` for an image launched suspended.
    func resumeSuspended() {
        do { try startMainThread() } catch {
            say("cannot start the main thread: \(error)")
            pool.terminate(status: 1, message: "cannot start the main thread: \(error)", vcpuIndex: nil)
        }
    }

    /// Gives up on an image that never ran (launch failed after the build).
    func abandon() {
        pool.shutdown()
        destroy()
    }

    /// Destroys the VM (its threads are joined). Under the kernel lock, so
    /// no kernel code is touching this image's memory meanwhile.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        kernel.lock.withLock {
            if let host = kernel.threadHost as? PoolThreadHost, host.pool === pool { kernel.threadHost = nil }
            // Drop the address space's file references (their host fds)
            // even if a kernel object keeps the space itself alive.
            space.discardAll()
        }
        // KVM teardown (2–70 ms) needs no kernel state: outside the lock.
        // Diagnostics (`YCODE_DEBUG_NO_VM_CLOSE=1`): keep the VM (leaks it).
        if keptVMsForDebugging == nil { vm.close() } else { keptVMsLock.withLock { keptVMsForDebugging!.append(vm) } }
        VMCounters.shared.vmDestroyed()
    }

    /// The last vCPU thread returned.
    private func finished() {
        let end = pool.currentTermination
        // An image the VMM ended (unexpected exit, host failure) without the
        // kernel knowing: the process dies with SIGKILL (stage 4b, P).
        if !endedByKernel.load(ordering: .relaxed), end?.kind == .terminated, pid != rootPID {
            kernel.lock.withLock {
                if !kernel.isTerminating { kernel.postSignal(9) }
            }
        }
        launcher.imageFinished(self)
    }

    static func checkExecutable(hostPath: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory) else {
            throw DarwinErrnoError(LaunchErrno.ENOENT)
        }
        if isDirectory.boolValue { throw DarwinErrnoError(LaunchErrno.EACCES) }
        guard access(hostPath, R_OK) == 0 else { throw DarwinErrnoError(LaunchErrno.EACCES) }
        guard let fat = try? MachOFile(contentsOf: URL(fileURLWithPath: hostPath)) else {
            throw DarwinErrnoError(LaunchErrno.ENOEXEC)
        }
        guard let slice = fat.slices.first(where: { $0.cpuType == MachO.cpuTypeARM64 && $0.cpuSubtype & 0x00FF_FFFF == 0 })
                ?? fat.slices.first(where: { $0.cpuType == MachO.cpuTypeARM64 }) else {
            throw DarwinErrnoError(LaunchErrno.EBADARCH)
        }
        guard let image = try? MachOImage(fat.reader, at: slice.offset), image.fileType == .executable else {
            throw DarwinErrnoError(LaunchErrno.ENOEXEC)
        }
        if let platform = image.buildVersion?.platform, platform != .iOSSimulator {
            throw DarwinErrnoError(LaunchErrno.EBADARCH)
        }
    }

    // MARK: Traps

    /// An address attributed to an image (diagnostics; takes the kernel lock).
    func describeAddress(_ address: UInt64) -> String {
        kernel.lock.withLock { images.describe(address) }
    }

    func faultReport(_ frame: TrapFrame) -> String {
        kernel.lock.withLock {
            var lines = ["  ELR \(hex(frame.elr)) = \(images.describe(frame.elr))"]
            if frame.trapKind != .svc {
                lines.append("  FAR \(hex(frame.far)) = \(images.describe(frame.far)); region: \(space.region(containing: frame.far)?.description ?? "unmapped")")
            }
            lines.append("  LR  \(hex(frame.x[30])) = \(images.describe(frame.x[30]))")
            // A BRK (an abort in guest code): libmalloc leaves its message
            // in x1, libdispatch and launchd_sim in x0.
            if frame.syndrome.exceptionClass == .brk {
                for r in [0, 1] {
                    if let text = guestCString(frame.x[r]) { lines.append("  x\(r) -> \"\(text)\"") }
                }
                lines += crashAnnotations()
            } else if frame.trapKind != .svc {
                // Any other fault: the registers that point at text (format
                // strings, names) say what the code was working on.
                for r in 0..<29 where frame.x[r] >= 0x1_0000 {
                    if let text = guestCString(frame.x[r]) { lines.append("  x\(r) -> \"\(text)\"") }
                }
            }
            // x16/x17: the last stub call's target (a NULL from a library
            // function is often what the faulting code then used).
            for r in [16, 17] where images.attribute(frame.x[r]) != nil {
                lines.append("  x\(r) \(hex(frame.x[r])) = \(images.describe(frame.x[r]))")
            }
            if let code = try? space.read(va: frame.elr & ~3, count: 4, checkingEL0Access: false) {
                lines.append("  instruction word at ELR: \(code.reversed().map { String(format: "%02x", $0) }.joined())")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The CrashReporter annotations that cache libraries filled in
    /// (`struct crashreporter_annotations_t` in each `__crash_info` section:
    /// u64 version, then the pointers message, signature_string, backtrace,
    /// message2, then thread, dialog_mode, abort_cause; Libc
    /// `CrashReporterClient.h`, level 1). Lock held.
    private func crashAnnotations() -> [String] {
        var lines: [String] = []
        for info in launcher.config.cacheIndex.crashInfoSections() where info.size >= 40 {
            let va = info.address &+ images.cacheDelta
            guard let raw = try? space.read(va: va, count: Int(min(info.size, 64)), checkingEL0Access: false) else { continue }
            func word(_ i: Int) -> UInt64 {
                guard (i + 1) * 8 <= raw.count else { return 0 }
                return (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[i * 8 + $1]) << (8 * UInt64($1)) }
            }
            let name = (info.image as NSString).lastPathComponent
            for (index, field) in [(1, "message"), (2, "signature"), (4, "message2")] {
                let pointer = word(index)
                guard pointer != 0 else { continue }
                lines.append("  crash annotation \(name) \(field): " + (guestCString(pointer).map { "\"\($0)\"" } ?? hex(pointer)))
            }
            if word(7) != 0 { lines.append("  crash annotation \(name) abort_cause: \(hex(word(7)))") }
        }
        return lines
    }

    /// The printable C string at a guest address (EL0-readable memory, at
    /// most 256 bytes), or nil. Lock held.
    private func guestCString(_ va: UInt64) -> String? {
        // Only EL0 (TTBR0) addresses: below 2^48. Anything else (an errno
        // in x0, a kernel pointer, a tagged value) is not a string.
        let limit: UInt64 = 1 << 48
        guard va >= 0x1000, va < limit else { return nil }
        var bytes: [UInt8] = []
        var address = va
        while bytes.count < 1024, address < limit {
            // Page by page, so a string near the end of a mapping still reads.
            // No overflow: address < 2^48, so the page end fits.
            let pageEnd = min((address | (VMLayout.pageSize - 1)) &+ 1, limit)
            let count = min(Int(pageEnd - address), 1024 - bytes.count)
            guard let chunk = try? space.read(va: address, count: count, checkingEL0Access: true) else { break }
            if let nul = chunk.firstIndex(of: 0) {
                bytes += chunk[..<nul]
                break
            }
            bytes += chunk
            address &+= UInt64(count)
        }
        // Printable ASCII, tabs, newlines, and UTF-8 (Swift fatal-error
        // messages carry curly quotes).
        guard bytes.count >= 2, bytes.allSatisfy({ (0x20..<0x7F).contains($0) || $0 == 0x0A || $0 == 0x09 || $0 >= 0x80 }),
              let text = String(validating: bytes, as: UTF8.self) else { return nil }
        return text.replacingOccurrences(of: "\n", with: "\\n")
    }

    /// dyld_sim's mmap of a shared-cache file (§1 item 1): records where
    /// each expected mapping went (`pending` is the mmap as it arrived,
    /// `frame` its result). Takes the kernel lock only for a cache file.
    private func noteCacheMapping(_ pending: CacheMappingTracker.Pending?, _ frame: TrapFrame, context: ThreadContext,
                                  verbose: Bool) {
        let images = self.images
        if let p = pending, let path = p.path, !frame.carry, frame.x[0] == p.address,
           p.flags & 0x10 != 0, (path as NSString).lastPathComponent.hasPrefix("dyld_sim_shared_cache_") {
            var mappingNotes: [String] = []
            kernel.lock.withLock(context: context) {
                if tracker.expected.isEmpty { tracker.expected = images.cacheMappings() }
                let name = (path as NSString).lastPathComponent
                if let index = tracker.expected.firstIndex(where: {
                    ($0.file as NSString).lastPathComponent == name && $0.mapping.fileOffset == p.offset && $0.mapping.size == p.size
                }) {
                    let header = tracker.expected[index].mapping.address
                    tracker.seen[index] = p.address
                    if index == 0 { images.cacheDelta = p.address &- header }
                    if verbose {
                        mappingNotes.append("ycode-simd: " + launcher.tag(pid) + "shared-cache mapping \(index + 1)/\(tracker.expected.count) \(name) @\(hex(p.offset)) size \(hex(p.size)) mapped at \(hex(p.address)) (header address \(hex(header))\(p.address == header ? ", exact" : ""))")
                    }
                }
            }
            for line in mappingNotes { stderrLine(line) }
        }
    }

    private func handleTrap(_ worker: VCPUPool.Worker, _ frame: inout TrapFrame) -> VCPUPool.Disposition {
        let context = (worker.context as? ThreadContext) ?? kernel.mainThread
        context.hostCPUBaseNanoseconds = worker.threadCPUBaseNanoseconds
        // Diagnostics: the trap as it arrives, before any lock.
        context.arrivingTrap = frame.x[16]
        defer { context.arrivingTrap = nil }
        // Frame profile (FrameProfile.swift): trap enter and exit while a window is open.
        if FrameProfile.active.load(ordering: .relaxed), let fp = FrameProfile.shared {
            let number: Int32 = frame.trapKind == .svc ? Int32(truncatingIfNeeded: frame.x[16]) : -1000
            fp.trapEnter(pid: pid, context: context, number: number, frame: frame)
            defer { fp.trapExit(pid: pid, context: context, number: number, frame: frame) }
            return handleTrapBody(worker, &frame, context: context)
        }
        return handleTrapBody(worker, &frame, context: context)
    }

    private func handleTrapBody(_ worker: VCPUPool.Worker, _ frame: inout TrapFrame, context: ThreadContext) -> VCPUPool.Disposition {
        let kernel = self.kernel, images = self.images, space = self.space
        let threadTag = context.threadID == 1 ? "" : "t\(context.threadID) "
        let verbose = trace || (record.serial == 1 && !launcher.config.quietRuns)
        // Boot profile: the trap's cost (`YCODE_BOOT_PROFILE_TRAPS=1`).
        let costOn = BootProfile.trapCosts
        let costNumber: Int64 = frame.trapKind == .svc ? Int64(Int32(truncatingIfNeeded: frame.x[16])) : -1000
        let costPre = costOn && !milestoneDone.load(ordering: .relaxed)
        let costTimes = costOn ? hostThreadTimes() : (userMicros: UInt64(0), systemMicros: UInt64(0), minorFaults: UInt64(0))
        let costNs: UInt64 = costOn ? monotonicNanoseconds() : 0
        defer {
            if costOn {
                BootProfile.shared?.recordTrapCost(number: costNumber, preMilestone: costPre,
                                                   wallNs: monotonicNanoseconds() &- costNs, start: costTimes)
            }
        }

        // Before the trap: attribution, the milestone (host-libraries.md
        // §8.1, printed once: the first trap from a cache libsystem_* image,
        // the cache libSystem.B, or one of Ycode's host libraries), and
        // dyld_sim's mmap of the shared cache (§1 item 1). This bookkeeping
        // runs inside the trap's own kernel-lock acquisition (`beforeTrap`),
        // and only for a trap that needs it: tracing, the milestone still
        // pending, or an mmap (the cache mapping tracker reads the fd
        // table). Every trap takes the kernel lock once here.
        let isSVC = frame.trapKind == .svc
        let x16 = UInt32(truncatingIfNeeded: frame.x[16])
        var pendingResult: CacheMappingTracker.Pending?
        let count = trapCountAtomic.add(1, ordering: .relaxed).newValue
        // Task-local traps (boot-profile.md §3.6): no kernel lock. Before the
        // libSystem milestone only for traps that are not the milestone
        // itself (the locked prologue records it).
        if DarwinKernel.taskLocalTrapsEnabled, !trace, isSVC, DarwinKernel.isTaskLocalTrap(Int32(bitPattern: x16)),
           milestoneDone.load(ordering: .relaxed) || images.libSystemAttribution(frame.elr) == nil {
            let entryX0 = frame.x[0], entryX1 = frame.x[1], fullX16 = frame.x[16]
            context.trapInProgress = (fullX16, Array(frame.x[0..<8]))
            let outcome = kernel.handleTaskLocal(&frame, context: context, memory: space)
            context.trapInProgress = nil
            if outcome != nil {
                // (handleTaskLocal only ever answers .resume.)
                taskLocalTrapCount.wrappingAdd(1, ordering: .relaxed)
                context.trapCount += 1
                if context.recentTraps.count == 16 { context.recentTraps.removeFirst() }
                context.recentTraps.append((fullX16, entryX0, entryX1, frame.carry ? (1 << 63) | frame.x[0] : frame.x[0]))
                return .resume
            }
        }
        // BSD descriptor and lookup traps without L0 (bsd-locking.md), under
        // the task-local traps' milestone rule.
        if !trace, isSVC, DarwinKernel.bsdFastTrapsEnabled, DarwinKernel.isBSDFastTrap(Int32(bitPattern: x16)),
           milestoneDone.load(ordering: .relaxed) || images.libSystemAttribution(frame.elr) == nil {
            let entryX0 = frame.x[0], entryX1 = frame.x[1], fullX16 = frame.x[16]
            // mmap: the shared-cache mapping record, as the locked prologue
            // makes it (the descriptor table needs no kernel lock).
            let mmapPending: CacheMappingTracker.Pending? = x16 == 197
                ? .init(address: frame.x[0], size: frame.x[1], flags: frame.x[3], fd: Int32(truncatingIfNeeded: frame.x[4]),
                        offset: frame.x[5], path: try? fileSystem.path(for: Int32(truncatingIfNeeded: frame.x[4])))
                : nil
            context.trapInProgress = (fullX16, Array(frame.x[0..<8]))
            let outcome = kernel.handleBSDFast(&frame, context: context, memory: space)
            context.trapInProgress = nil
            if outcome != nil {
                if mmapPending != nil { noteCacheMapping(mmapPending, frame, context: context, verbose: verbose) }
                // (handleBSDFast only ever answers .resume.)
                context.trapCount += 1
                if context.recentTraps.count == 16 { context.recentTraps.removeFirst() }
                context.recentTraps.append((fullX16, entryX0, entryX1, frame.carry ? (1 << 63) | frame.x[0] : frame.x[0]))
                return .resume
            }
        }
        // IPC fast paths (mach-ipc-locking.md §4.3): no kernel lock, after
        // the libSystem milestone (the locked prologue records it).
        if !trace, isSVC, kernel.hasIPCFastPaths, DarwinKernel.isIPCFastTrap(Int32(bitPattern: x16)),
           milestoneDone.load(ordering: .relaxed) {
            let entryX0 = frame.x[0], entryX1 = frame.x[1], fullX16 = frame.x[16]
            context.trapInProgress = (fullX16, Array(frame.x[0..<8]))
            let outcome = kernel.handleIPCFast(&frame, context: context, memory: space)
            context.trapInProgress = nil
            if let outcome {
                context.trapCount += 1
                if context.recentTraps.count == 16 { context.recentTraps.removeFirst() }
                context.recentTraps.append((fullX16, entryX0, entryX1, frame.carry ? (1 << 63) | frame.x[0] : frame.x[0]))
                return .resume  // (handleIPCFast only ever answers .resume)
            }
        }
        // Relaxed is enough: `milestoneReached` itself is read and written
        // under the kernel lock; this mirror only lets later traps skip the
        // prologue once it is true.
        let needsPrologue = trace || !milestoneDone.load(ordering: .relaxed) || (isSVC && x16 == 197)
        // Output is collected under the lock and written after it.
        var notes: [String] = []
        // The trap as it arrived (the kernel may rewrite the frame, e.g. for
        // signal delivery): fault reports describe this one.
        let arrivedFrame = frame
        // posix_spawn, execve, __mac_execve: build the new image's VM now,
        // before the trap takes the kernel lock (`PrebuiltVMs`).
        if isSVC, x16 == 244 || x16 == 59 || x16 == 380, !trace {
            // Boot profile: the inline build counts as pseudo-trap 100000.
            let t0 = costOn ? hostThreadTimes() : (userMicros: UInt64(0), systemMicros: UInt64(0), minorFaults: UInt64(0))
            let n0: UInt64 = costOn ? monotonicNanoseconds() : 0
            launcher.prebuilt.prepare()
            if costOn {
                BootProfile.shared?.recordTrapCost(number: 100_000, preMilestone: false, wallNs: monotonicNanoseconds() &- n0, start: t0)
            }
        }
        context.trapInProgress = (frame.x[16], Array(frame.x[0..<8]))
        let entryX0 = frame.x[0], entryX1 = frame.x[1]
        let outcome = kernel.handle(&frame, context: context, memory: space) { entry in
            // Non-escaping: the captured locals stay on the stack.
            guard needsPrologue else { return }
            if BootProfile.shared != nil, !milestoneReached {
                preMilestoneTraps[isSVC ? Int64(Int32(truncatingIfNeeded: x16)) : -1000, default: 0] += 1
            }
            // The full attribution only when tracing; the milestone needs
            // only the libSystem images (the full cache index takes seconds
            // to build the first time).
            let attribution = trace ? images.attribute(entry.elr) : nil
            if !milestoneReached, let (image, offset) = images.libSystemAttribution(entry.elr) {
                milestoneReached = true
                milestoneDone.store(true, ordering: .relaxed)
                if BootProfile.shared != nil { noteMilestone(worker) }
                if verbose {
                    notes.append(launcher.tag(pid) + "milestone: libSystem initializer reached (\(image.name) + \(hex(offset)); "
                        + "LR \(hex(entry.x[30])) = \(images.describeIfCheap(entry.x[30])))")
                }
            }
            if trace {
                let place = attribution.map { "\($0.image.name.split(separator: "/").last.map(String.init) ?? $0.image.name)+\(hex($0.offset))" } ?? hex(entry.elr)
                trapPrefix.value = "[\(count)] \(threadTag)\(place): "
            }
            if trace, isSVC, x16 == 374 || x16 == 375 {
                // kevent_qos / kevent_id: show each change.
                dumpKevents(space, list: entry.x[1], count: Int(entry.x[2]), label: "change")
            }
            guard isSVC, x16 == 197 else { return }
            let fd = Int32(truncatingIfNeeded: entry.x[4])
            pendingResult = .init(address: entry.x[0], size: entry.x[1], flags: entry.x[3], fd: fd,
                                  offset: entry.x[5], path: try? fileSystem.path(for: fd))
        }
        for note in notes { stderrLine(note) }
        let pending = pendingResult
        context.trapInProgress = nil
        // The trap ring (fault reports, the blocked-thread report): every
        // trap, with its result (bit 63: carry, an errno).
        context.trapCount += 1
        if context.recentTraps.count == 16 { context.recentTraps.removeFirst() }
        context.recentTraps.append((arrivedFrame.x[16], entryX0, entryX1, frame.carry ? (1 << 63) | frame.x[0] : frame.x[0]))
        if trace, isSVC, x16 == 368, outcome == .resume, frame.x[16] == 0, frame.x[5] > 0, frame.x[5] < 64, frame.x[3] != 0 {
            // A workqueue thread restarted with events (x3 = list, x5 = count).
            kernel.lock.withLock { dumpKevents(space, list: frame.x[3], count: Int(frame.x[5]), label: "event") }
        }

        noteCacheMapping(pending, frame, context: context, verbose: verbose)

        switch outcome {
        case .resume:
            return .resume
        case .threadExit:
            if trace { say("\(context) ended; vCPU \(worker.index) parked") }
            return .park
        case let .exit(status):
            return end(.terminated, status: status, message: "guest exited with status \(status)", worker: worker)
        case .imageReplaced:
            // Exec: the new image already runs under this pid; this VM goes quietly.
            if trace { say("image \(record.serial) replaced by exec") }
            return end(.ended, status: 0, message: "replaced by exec", worker: worker)
        case let .fatal(status, message):
            // The faulting thread's frame (another thread may report the end).
            let reportFrame = kernel.lock.withLock { kernel.faultFrame } ?? arrivedFrame
            var text = ""
            if DarwinKernel.isCachePatchPlaceholderFault(reportFrame) {
                text += "\(DarwinKernel.cachePatchPlaceholderMessage): ELR \(hex(reportFrame.elr)) = "
                    + "\(describeAddress(reportFrame.elr)); LR \(hex(reportFrame.x[30])) = \(describeAddress(reportFrame.x[30]))\n"
            }
            text += "fatal guest condition in \((record.executable as NSString).lastPathComponent) on \(context), vCPU \(worker.index) (exit \(status)):\n\(message)\n\(faultReport(reportFrame))"
            if !context.recentTraps.isEmpty {
                text += "\n  last traps of this thread: " + context.recentTraps.map(DarwinKernel.ringEntry).joined(separator: " ")
            }
            // abort(): the reason is in the libraries' crash annotations.
            if status == DarwinKernel.abortExitStatus, reportFrame.syndrome.exceptionClass != .brk {
                let notes = kernel.lock.withLock { crashAnnotations() }
                if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
            }
            // A child's fault or abort is worth a line; a default-action
            // signal (128 + n, e.g. kill) is ordinary process life. The
            // other threads of the dying process take the same outcome at
            // their next trap; only the first one reports (as a Darwin crash
            // report names one crashed thread).
            let first = fatalReported.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
            if first, pid != rootPID, trace || status == DarwinKernel.exceptionExitStatus || status == DarwinKernel.abortExitStatus {
                say(text)
            } else if !first, trace {
                say("\(context) ends with the process (fatal condition already reported)")
            }
            return end(.terminated, status: status, message: text, worker: worker)
        case let .unimplemented(description):
            // Counted by call (the text up to its argument list).
            kernel.lock.withLock { trapCounts[String(description.prefix { $0 != "(" }), default: 0] += 1 }
            if launcher.config.trace && !options.keepGoing {
                let message = "first unimplemented trap (\(context)): \(description)\n\(frame)\n\(faultReport(frame))"
                launcher.abortHost(status: DarwinKernel.unimplementedExitStatus, message: launcher.tag(pid) + message)
                return .terminate(status: DarwinKernel.unimplementedExitStatus, message: message)
            }
            return .resume
        case let .unimplementedLibraryFunction(name) where options.libfuncReturns[name] != nil:
            // Debug aid: finish the call here (x0 = value, return to the caller).
            let value = options.libfuncReturns[name]!
            say("unimplemented libfunc \(name) (LR \(hex(frame.x[30])) = \(describeAddress(frame.x[30]))) "
                + "[--libfunc-return: x0 = \(hex(value))]")
            frame.x[0] = value
            frame.elr = frame.x[30]
            return .resume
        case let .unimplementedLibraryFunction(name):
            // Every call is counted; the line is printed for the first three
            // calls of each function and then for every hundredth (a boot
            // repeats some of them thousands of times).
            let seen = kernel.lock.withLock { () -> Int in
                trapCounts["libfunc " + name, default: 0] += 1
                return trapCounts["libfunc " + name] ?? 0
            }
            if seen <= 3 || seen % 100 == 0 {
                say("unimplemented libfunc \(name) (LR \(hex(frame.x[30])) = \(describeAddress(frame.x[30])))"
                    + (seen > 3 ? " [call \(seen)]" : ""))
            }
            if launcher.config.trace && !options.keepGoing {
                let message = "first unimplemented host-library function (\(context)): \(name)\n\(frame)\n\(faultReport(frame))"
                launcher.abortHost(status: DarwinKernel.unimplementedLibraryFunctionExitStatus, message: launcher.tag(pid) + message)
                return .terminate(status: DarwinKernel.unimplementedLibraryFunctionExitStatus, message: message)
            }
            return .resume
        }
    }

    /// A kernel outcome ends the image: record it and stop every vCPU.
    private func end(_ kind: VCPUPool.Termination.Kind, status: Int32, message: String,
                     worker: VCPUPool.Worker) -> VCPUPool.Disposition {
        endedByKernel.store(true, ordering: .relaxed)
        return kind == .ended ? .end(message: message) : .terminate(status: status, message: message)
    }

    // MARK: Summary

    /// The stage-3/4a summary line. `locked: false` after the watchdog (a
    /// thread may hold the kernel lock forever).
    func summary(locked: Bool) -> String {
        let exits = pool.exitCount
        let traps = trapCountAtomic.load(ordering: .relaxed)
        guard locked else { return "\(traps) traps, \(exits) VM exits, \(pool.vcpuCount) vCPUs (peak \(pool.peakThreads) threads)" }
        return kernel.lock.withLock {
            let expected = tracker.expected.count
            let exact = tracker.seen.filter { tracker.expected[$0.key].mapping.address == $0.value }.count
            // The lock counters belong to the system (every process shares the lock).
            let locks = "; kernel lock \(kernel.lock.acquisitions) acquisitions, "
                + "\(kernel.lock.totalHeldNanoseconds / 1_000_000) ms held"
            return "\(traps) traps, \(exits) VM exits, \(pool.vcpuCount) vCPUs (peak \(pool.peakThreads) threads); "
                + "shared-cache mappings mapped: \(tracker.seen.count)/\(expected)"
                + " (\(exact) at the header address); milestone \(milestoneReached ? "reached" : "not reached")" + locks
        }
    }

    /// Unimplemented traps and functions seen (trace mode).
    func unimplementedSummary() -> String? {
        let counts = kernel.lock.withLock { trapCounts }
        guard !counts.isEmpty else { return nil }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
    }

    var trapTotal: Int { trapCountAtomic.load(ordering: .relaxed) }

    /// Boot profile: the image (name) and offset of a guest PC, without the
    /// kernel lock (the PC sampler; host libraries, whose lookup needs the
    /// address space, are reported together as "other").
    func attributeForProfile(_ pc: UInt64) -> (String, UInt64) {
        if let image = images.fixed.first(where: { pc >= $0.start && pc < $0.end }) {
            return ((image.name as NSString).lastPathComponent, pc &- image.base)
        }
        if pc >= VMLayout.sharedRegionBase, pc < VMLayout.sharedRegionEnd, let list = images.cache.cacheImagesIfReady() {
            let header = pc &- images.cacheDelta
            var low = 0, high = list.count
            while low < high {
                let mid = (low + high) / 2
                if list[mid].start <= header { low = mid + 1 } else { high = mid }
            }
            if low > 0, header < list[low - 1].end {
                return ((list[low - 1].name as NSString).lastPathComponent, header &- list[low - 1].base)
            }
            return ("shared cache (no image)", 0)
        }
        if pc >= 0xFFFF_0000_0000_0000 { return ("EL1 shim", 0) }
        return ("other (host library, JIT, stub)", pc & ~0xFFFF)
    }

    /// Boot profile: the milestone's time, and this image's traps, lock
    /// wait and its (main) thread's CPU so far. Kernel lock held.
    private func noteMilestone(_ worker: VCPUPool.Worker) {
        record.milestoneNs = monotonicNanoseconds()
        record.milestoneTraps = trapCountAtomic.load(ordering: .relaxed)
        record.milestoneLockWaitNs = kernel.profileLockWaitNanoseconds
        record.milestoneLockHeldNs = kernel.profileLockHeldNanoseconds
        record.milestoneRunNs = worker.runNanoseconds
        record.milestoneHandlerNs = worker.handlerNanoseconds
        record.milestoneTopTraps = preMilestoneTraps.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        if let s = hostTaskStats(ckvmThreadID()) {
            record.milestoneCPUNs = s[5]
            record.milestoneGuestTicks = s[2]
            record.milestoneSystemTicks = s[1]
        }
    }

    /// Boot profile: fixes the image's counters in its record (teardown,
    /// after every vCPU thread returned).
    func captureProfile() {
        record.hostStats = pool.hostStats
        record.firstRunNs = pool.firstRunNanoseconds.load(ordering: .relaxed)
        record.traps = trapTotal
        record.taskLocalTraps = taskLocalTrapCount.load(ordering: .relaxed)
        record.vcpus = pool.vcpuCount
        kernel.lock.withLock {
            record.lockHeldNs = kernel.profileLockHeldNanoseconds
            record.lockWaitNs = kernel.profileLockWaitNanoseconds
            record.lockAcquisitions = kernel.profileLockAcquisitions
        }
        record.tornDownNs = monotonicNanoseconds()
    }
}

/// The kernel's `ThreadHost`: new Darwin threads go to the image's vCPU pool.
final class PoolThreadHost: ThreadHost {
    struct Exhausted: Error, CustomStringConvertible {
        var capacity: Int
        var description: String { "the vCPU pool is exhausted (\(capacity) vCPUs)" }
    }
    /// Weak: a kernel that outlives its image never keeps the pool alive.
    weak var pool: VCPUPool?
    init(pool: VCPUPool) { self.pool = pool }

    /// Set while a snapshot restore builds its processes and starts the
    /// restored threads (snapshot.md §7 steps 4–9): the kernel starts no new
    /// thread then. A message a host service delivers in that window (a
    /// reply to a request the snapshot left queued) would otherwise make the
    /// receiving process's workqueue start a new worker for each request it
    /// sees while its restored workers are not running yet; those workers
    /// wait at the start gate, and the next requests start more, until the
    /// process's pool is full and its restored threads find no vCPU (§12.4).
    /// Requests stay pending and are handed out at step 10.
    static let restoring = Atomic<Bool>(false)

    var canStartThread: Bool { !Self.restoring.load(ordering: .acquiring) && (pool?.hasRoom ?? false) }

    func startThread(_ start: ThreadStartState, context: ThreadContext) throws -> Int {
        guard let pool, !Self.restoring.load(ordering: .acquiring) else { throw Exhausted(capacity: 0) }
        let state = VCPUStartState(pc: start.pc, sp: start.sp, registers: start.x, tpidrro: start.tpidrro, tpidr: start.tpidr)
        if FrameProfile.active.load(ordering: .relaxed), let fp = FrameProfile.shared {
            fp.startRequested(pid: context.kernel?.pid ?? -1, context: context, mainThread: false)
        }
        guard let index = try pool.start(state, context: context) else { throw Exhausted(capacity: pool.capacity) }
        context.vcpuIndex = index
        return index
    }

    /// Stage 4b §3.4: kick every vCPU of this image out of the guest; the
    /// image ends (its vCPU threads return, then the VM is destroyed).
    func stopAllThreads() {
        pool?.requestStop("stopped by the kernel")
    }
}
#endif
