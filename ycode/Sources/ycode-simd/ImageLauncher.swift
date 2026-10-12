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
    private let lock = HostMutex()
    private var created = 0
    private var destroyed = 0
    func vmCreated() { lock.withLock { created += 1 } }
    func vmDestroyed() { lock.withLock { destroyed += 1 } }
    var snapshot: (created: Int, destroyed: Int) { lock.withLock { (created, destroyed) } }
}

/// The trap-log prefix of the trap a host thread is handling (one host
/// thread runs one vCPU of one image, so one key serves every image).
let trapPrefix = PerThreadString()

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
    var tornDown = false
    /// The live image until teardown.
    var image: GuestImageInstance?

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
    private let lock = HostMutex()
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
    /// The last launch failure's detail (for the root's error message).
    private(set) var lastLaunchFailure: String?

    init(config: ExecConfiguration) { self.config = config }

    /// "[pid N] " once several images exist.
    func tag(_ pid: Int32) -> String { multiImage.load(ordering: .relaxed) ? "[pid \(pid)] " : "" }

    // MARK: ProcessLauncher

    func launch(_ request: ProcessImageRequest, kernel: DarwinKernel) throws -> any LaunchedImage {
        let number: Int = lock.withLock {
            serial += 1
            if serial > 1 { multiImage.store(true, ordering: .relaxed) }
            return serial
        }
        let image: GuestImageInstance
        do {
            image = try GuestImageInstance(launcher: self, serial: number, request: request, kernel: kernel)
        } catch let error as DarwinErrnoError {
            lastLaunchFailure = "\(request.executablePath): \(error)"
            if config.trace || number == 1 { stderrLine("ycode-simd: \(tag(kernel.pid))cannot launch \(lastLaunchFailure!)") }
            throw error
        } catch {
            lastLaunchFailure = "\(request.executablePath): \(error)"
            stderrLine("ycode-simd: \(tag(kernel.pid))cannot build a VM for \(lastLaunchFailure!)")
            throw DarwinErrnoError(LaunchErrno.ENOMEM)
        }
        lock.withLock {
            live.append(image)
            records.append(image.record)
        }
        if !request.startSuspended {
            do {
                try image.startMainThread()
            } catch {
                lastLaunchFailure = "\(request.executablePath): \(error)"
                stderrLine("ycode-simd: \(tag(kernel.pid))cannot start \(lastLaunchFailure!)")
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

    /// The counter offset and boot counter a new VM uses (the first VM sets
    /// the system's). Called while building an image.
    func systemClock(for vcpu: VCPU, frequency: UInt64, log: (String) -> Void) throws -> (offset: UInt64, bootCounter: UInt64) {
        let own = try vcpu.counterOffset()
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
        return (offset, boot)
    }

    // MARK: Events from images and the kernel

    /// A thread ended the image (it is stopping now). Any host thread.
    func imageEnded(_ image: GuestImageInstance, _ end: VCPUPool.Termination) {
        lock.withLock {
            if image.record.end == nil || image.record.end!.kind == .stopped { image.record.end = end }
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
        image.record.finalSummary = image.summary(locked: true)
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
    private var tracker = CacheMappingTracker()
    private var trapCount = 0
    private var trapCounts: [String: Int] = [:]
    /// True once a kernel outcome ended the image (exit, fatal, exec).
    private let endedByKernel = Atomic<Bool>(false)

    /// VMM log line (with the pid tag once several images exist).
    func say(_ text: String) { stderrLine("ycode-simd: " + launcher.tag(pid) + text) }

    init(launcher: VMMLauncher, serial: Int, request: ProcessImageRequest, kernel: DarwinKernel) throws {
        let config = launcher.config
        self.launcher = launcher
        self.kernel = kernel
        self.pid = kernel.pid
        self.options = config.options
        self.trace = config.trace
        self.fileSystem = kernel.fileSystem
        let execPath = request.executablePath
        let trace = config.trace
        let verbose = trace || (serial == 1 && !config.quietRuns)
        record = ImageRecord(serial: serial, pid: kernel.pid, executable: execPath)
        let pid = kernel.pid
        func say(_ text: String) { stderrLine("ycode-simd: " + launcher.tag(pid) + text) }

        // The executable must be an arm64 iOS-simulator Mach-O executable.
        try Self.checkExecutable(hostPath: request.hostExecutablePath)

        let builder = try ProcessBuilder(log: trace ? { say($0) } : nil)
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
            let pool = try VCPUPool(vm: vm, bootTemplate: BootInfo(ttbr0EL1: space.pageTables.rootGPA, el0EntryPC: 0),
                                    maxExitsPerVCPU: config.maxExits)
            poolForCleanup = pool
            if config.trace { pool.log = { say($0) } }
            let vcpu0 = try pool.createWorker().vcpu
            let (frequency, frequencySource) = vcpu0.counterFrequency()
            let clock = try launcher.systemClock(for: vcpu0, frequency: frequency, log: { say($0) })
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
            kernel.counter = { Hypervisor.hostCounter() &- offset }
            kernel.counterFrequency = frequency
            kernel.bootCounter = clock.bootCounter
            kernel.allImageInfosAddress = HostPageLayout.allImageInfos
            kernel.mainStackTop = VMLayout.userStackTop
            kernel.threadHost = PoolThreadHost(pool: pool)

            mainState = VCPUStartState(pc: VMLayout.hostPageEntryVA, sp: arguments.stackPointer, tpidrro: threadBlock.tsdBase)
        } catch {
            poolForCleanup?.shutdown()
            builder.vm.close()
            VMCounters.shared.vmDestroyed()
            if let error = error as? DarwinErrnoError { throw error }
            throw error
        }
        record.image = self

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
    }

    /// The main thread on vCPU 0 (§6 initial state, with host-libraries.md
    /// §8.3's TPIDRRO_EL0).
    func startMainThread() throws {
        guard let state = mainState else { return }
        mainState = nil
        guard let worker = try pool.start(state, context: kernel.mainThread) else {
            throw KVMError("vCPU pool", detail: "vCPU 0 is unavailable")
        }
        kernel.mainThread.vcpuIndex = worker.index
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
            for region in space.regions where !region.permanent {
                try? space.unmap(va: region.va, size: region.size)
            }
            vm.close()
        }
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
        while bytes.count < 256, address < limit {
            // Page by page, so a string near the end of a mapping still reads.
            // No overflow: address < 2^48, so the page end fits.
            let pageEnd = min((address | (VMLayout.pageSize - 1)) &+ 1, limit)
            let count = min(Int(pageEnd - address), 256 - bytes.count)
            guard let chunk = try? space.read(va: address, count: count, checkingEL0Access: true) else { break }
            if let nul = chunk.firstIndex(of: 0) {
                bytes += chunk[..<nul]
                break
            }
            bytes += chunk
            address &+= UInt64(count)
        }
        guard bytes.count >= 2, bytes.allSatisfy({ (0x20..<0x7F).contains($0) || $0 == 0x0A || $0 == 0x09 }) else { return nil }
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")
    }

    private func handleTrap(_ worker: VCPUPool.Worker, _ frame: inout TrapFrame) -> VCPUPool.Disposition {
        let kernel = self.kernel, images = self.images, space = self.space
        let context = (worker.context as? ThreadContext) ?? kernel.mainThread
        let threadTag = context.threadID == 1 ? "" : "t\(context.threadID) "
        let verbose = trace || (record.serial == 1 && !launcher.config.quietRuns)

        // Before the trap: attribution, the milestone (host-libraries.md
        // §8.1, printed once: the first trap from a cache libsystem_* image,
        // the cache libSystem.B, or one of Ycode's host libraries), and
        // dyld_sim's mmap of the shared cache (§1 item 1).
        let isSVC = frame.trapKind == .svc
        let x16 = UInt32(truncatingIfNeeded: frame.x[16])
        let pending: CacheMappingTracker.Pending? = kernel.lock.withLock(context: context) {
            trapCount += 1
            let attribution = (trace || !milestoneReached) ? images.attribute(frame.elr) : nil
            if !milestoneReached, let (image, offset) = attribution,
               image.name.hasPrefix("/usr/lib/system/libsystem_") || image.name == "/usr/lib/libSystem.B.dylib" {
                milestoneReached = true
                if verbose {
                    stderrLine(launcher.tag(pid) + "milestone: libSystem initializer reached (\(image.name) + \(hex(offset)); "
                        + "LR \(hex(frame.x[30])) = \(images.describe(frame.x[30])))")
                }
            }
            if trace {
                let place = attribution.map { "\($0.image.name.split(separator: "/").last.map(String.init) ?? $0.image.name)+\(hex($0.offset))" } ?? hex(frame.elr)
                trapPrefix.value = "[\(trapCount)] \(threadTag)\(place): "
            }
            if trace, isSVC, x16 == 374 || x16 == 375 {
                // kevent_qos / kevent_id: show each change.
                dumpKevents(space, list: frame.x[1], count: Int(frame.x[2]), label: "change")
            }
            guard isSVC, x16 == 197 else { return nil }
            let fd = Int32(truncatingIfNeeded: frame.x[4])
            return .init(address: frame.x[0], size: frame.x[1], flags: frame.x[3], fd: fd,
                         offset: frame.x[5], path: try? fileSystem.path(for: fd))
        }

        // The trap as it arrived (the kernel may rewrite the frame, e.g. for
        // signal delivery): fault reports describe this one.
        let arrivedFrame = frame
        let outcome = kernel.handle(&frame, context: context, memory: space)
        if trace, isSVC, x16 == 368, outcome == .resume, frame.x[16] == 0, frame.x[5] > 0, frame.x[5] < 64, frame.x[3] != 0 {
            // A workqueue thread restarted with events (x3 = list, x5 = count).
            kernel.lock.withLock { dumpKevents(space, list: frame.x[3], count: Int(frame.x[5]), label: "event") }
        }

        if let p = pending, let path = p.path, !frame.carry, frame.x[0] == p.address,
           p.flags & 0x10 != 0, (path as NSString).lastPathComponent.hasPrefix("dyld_sim_shared_cache_") {
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
                        say("shared-cache mapping \(index + 1)/\(tracker.expected.count) \(name) @\(hex(p.offset)) size \(hex(p.size)) mapped at \(hex(p.address)) (header address \(hex(header))\(p.address == header ? ", exact" : ""))")
                    }
                }
            }
        }

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
                    + "\(images.describe(reportFrame.elr)); LR \(hex(reportFrame.x[30])) = \(images.describe(reportFrame.x[30]))\n"
            }
            text += "fatal guest condition on \(context), vCPU \(worker.index) (exit \(status)):\n\(message)\n\(faultReport(reportFrame))"
            // abort(): the reason is in the libraries' crash annotations.
            if status == DarwinKernel.abortExitStatus, reportFrame.syndrome.exceptionClass != .brk {
                let notes = kernel.lock.withLock { crashAnnotations() }
                if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
            }
            // A child's fault or abort is worth a line; a default-action
            // signal (128 + n, e.g. kill) is ordinary process life.
            if pid != rootPID, trace || status == DarwinKernel.exceptionExitStatus || status == DarwinKernel.abortExitStatus {
                say(text)
            }
            return end(.terminated, status: status, message: text, worker: worker)
        case let .unimplemented(description):
            kernel.lock.withLock { trapCounts[description, default: 0] += 1 }
            if trace && !options.keepGoing {
                let message = "first unimplemented trap (\(context)): \(description)\n\(frame)\n\(faultReport(frame))"
                launcher.abortHost(status: DarwinKernel.unimplementedExitStatus, message: launcher.tag(pid) + message)
                return .terminate(status: DarwinKernel.unimplementedExitStatus, message: message)
            }
            return .resume
        case let .unimplementedLibraryFunction(name) where options.libfuncReturns[name] != nil:
            // Debug aid: finish the call here (x0 = value, return to the caller).
            let value = options.libfuncReturns[name]!
            say("unimplemented libfunc \(name) (LR \(hex(frame.x[30])) = \(images.describe(frame.x[30]))) "
                + "[--libfunc-return: x0 = \(hex(value))]")
            frame.x[0] = value
            frame.elr = frame.x[30]
            return .resume
        case let .unimplementedLibraryFunction(name):
            kernel.lock.withLock { trapCounts["libfunc " + name, default: 0] += 1 }
            say("unimplemented libfunc \(name) (LR \(hex(frame.x[30])) = \(images.describe(frame.x[30])))")
            if trace && !options.keepGoing {
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
        guard locked else { return "\(trapCount) traps, \(exits) VM exits, \(pool.vcpuCount) vCPUs (peak \(pool.peakThreads) threads)" }
        return kernel.lock.withLock {
            let expected = tracker.expected.count
            let exact = tracker.seen.filter { tracker.expected[$0.key].mapping.address == $0.value }.count
            return "\(trapCount) traps, \(exits) VM exits, \(pool.vcpuCount) vCPUs (peak \(pool.peakThreads) threads); "
                + "shared-cache mappings mapped: \(tracker.seen.count)/\(expected)"
                + " (\(exact) at the header address); milestone \(milestoneReached ? "reached" : "not reached")"
        }
    }

    /// Unimplemented traps and functions seen (trace mode).
    func unimplementedSummary() -> String? {
        let counts = kernel.lock.withLock { trapCounts }
        guard !counts.isEmpty else { return nil }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
    }

    var trapTotal: Int { kernel.lock.withLock { trapCount } }
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

    func startThread(_ start: ThreadStartState, context: ThreadContext) throws -> Int {
        guard let pool else { throw Exhausted(capacity: 0) }
        let state = VCPUStartState(pc: start.pc, sp: start.sp, registers: start.x, tpidrro: start.tpidrro, tpidr: start.tpidr)
        guard let worker = try pool.start(state, context: context) else { throw Exhausted(capacity: pool.capacity) }
        context.vcpuIndex = worker.index
        return worker.index
    }

    /// Stage 4b §3.4: kick every vCPU of this image out of the guest; the
    /// image ends (its vCPU threads return, then the VM is destroyed).
    func stopAllThreads() {
        pool?.requestStop("stopped by the kernel")
    }
}
#endif
