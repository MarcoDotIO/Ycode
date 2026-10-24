// Snapshot and restore of a running simulator, VMM side
// (specs/simulator/snapshot.md §3, §6, §7, §9). Default off: nothing here
// runs unless a YCODE_SNAPSHOT_* or YCODE_RESTORE_DIR variable is set.
//
// - The gates (§3.1): every image's trap handler and run check are wrapped
//   when the image is built (`attach`); while a snapshot is pausing, a
//   thread that reaches a trap or is kicked out of guest code at EL0 parks
//   there with its frame and FP/SIMD state.
// - The quiesce loop kicks running vCPUs and classifies every thread under
//   the kernel lock until everything is settled, then captures the kernel
//   records and the guest memory with the lock held, and resumes.
// - The restore (§7) rebuilds the processes, launches their images
//   suspended, replays the memory, restores the kernel objects, and starts
//   every thread at an `svc` whose first trap the restore hook replaces with
//   the recorded frame.

#if os(Linux) && arch(arm64)
import CKVM
import Foundation
import Glibc
import Synchronization
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHypervisor

/// The settings, from the environment.
struct SnapshotSettings {
    var directory: String?
    var atMilliseconds: [UInt64] = []
    var whenFile: String?
    var delayMilliseconds: UInt64 = 300
    var exitAfter = false
    var census = false
    var restoreDirectory: String?
    var deadlineMilliseconds: UInt64 = 5000
    /// `YCODE_RESTORE_MEASURE=1`: restore images, memory and objects as far
    /// as they go (shared regions skipped), print the timings, start nothing, exit.
    var measureRestore = false
    /// `YCODE_RESTORE_LAZY=1` (§6.3): page files are mapped as guest memory
    /// (private, copy-on-write) instead of being read up front.
    var lazyRestore = false
    /// `YCODE_RESTORE_PREFETCH=1` (with lazy restore): a background thread
    /// asks the host to read the page files ahead (POSIX_FADV_WILLNEED).
    var prefetch = false
    /// `YCODE_SNAPSHOT_HOLD_APPS=<s>` (device mode, with
    /// `YCODE_SNAPSHOT_WHEN_FILE`): the `--install-app` / `--launch` steps
    /// wait until that snapshot is written or has failed, at most `s`
    /// seconds, so the snapshot shows the home screen without the app (the
    /// IDE's warm boot, specs/ide/run.md).
    var holdAppsSeconds: Int?
    /// `YCODE_SNAPSHOT_STOP_DIR=<dir>` (device mode, §12 "Stop snapshot"):
    /// when the run is stopped (SIGTERM, SIGINT, SIGHUP, or `--timeout-ms`)
    /// the launched app is killed, the device settles for
    /// `YCODE_SNAPSHOT_STOP_SETTLE_MS` (default 2000), and a snapshot is
    /// written to `dir`; the host process then exits without running another
    /// guest instruction, so the device directory stays exactly as the
    /// snapshot recorded it (a restore in place, §2.7).
    var stopDirectory: String?
    var stopSettleMilliseconds: UInt64 = 2000
    /// `YCODE_SNAPSHOT_STOP_REQUIRES=<file>`: a stop is saved only when the
    /// file exists (the launcher creates it once the device has settled at
    /// its home screen, §12.4); otherwise the guest shuts down cleanly.
    var stopRequiresFile: String?

    static func fromEnvironment() -> SnapshotSettings? {
        func env(_ k: String) -> String? { getenv(k).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }
        var s = SnapshotSettings()
        s.directory = env("YCODE_SNAPSHOT_DIR")
        s.atMilliseconds = (env("YCODE_SNAPSHOT_AT_MS") ?? "").split(separator: ",").compactMap { UInt64($0) }
        s.whenFile = env("YCODE_SNAPSHOT_WHEN_FILE")
        if let d = env("YCODE_SNAPSHOT_DELAY_MS").flatMap(UInt64.init) { s.delayMilliseconds = d }
        s.exitAfter = env("YCODE_SNAPSHOT_EXIT") == "1"
        s.census = env("YCODE_SNAPSHOT_CENSUS") == "1"
        s.restoreDirectory = env("YCODE_RESTORE_DIR")
        s.measureRestore = env("YCODE_RESTORE_MEASURE") == "1"
        s.lazyRestore = env("YCODE_RESTORE_LAZY") == "1"
        s.prefetch = env("YCODE_RESTORE_PREFETCH") == "1"
        s.holdAppsSeconds = env("YCODE_SNAPSHOT_HOLD_APPS").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        if let d = env("YCODE_SNAPSHOT_DEADLINE_MS").flatMap(UInt64.init) { s.deadlineMilliseconds = d }
        s.stopDirectory = env("YCODE_SNAPSHOT_STOP_DIR")
        if let d = env("YCODE_SNAPSHOT_STOP_SETTLE_MS").flatMap(UInt64.init) { s.stopSettleMilliseconds = min(d, 60_000) }
        s.stopRequiresFile = env("YCODE_SNAPSHOT_STOP_REQUIRES")
        let active = s.directory != nil || s.census || s.restoreDirectory != nil || s.stopDirectory != nil
        return active ? s : nil
    }
}

func snapLog(_ text: String) { stderrLine("ycode-simd: snapshot: " + text) }

/// The stop trigger's signal (§12): set by the handler, read by a thread.
enum StopSignal {
    static let received = Atomic<Int32>(0)
}
private func snapshotStopSignalHandler(_ sig: Int32) { StopSignal.received.store(sig, ordering: .relaxed) }

/// Host ranges a lazy restore mapped from page files (§6.3). A later
/// snapshot counts their pages as resident and dirty whatever `mincore` and
/// the page map say: an untouched page there is a page-file page, not a
/// zero page or a page of the original file.
final class SnapshotOverlays: @unchecked Sendable {
    static let shared = SnapshotOverlays()
    private let lock = HostMutex(name: "snapshot overlays")
    private var ranges: [(start: UInt, end: UInt)] = []
    private var sorted = true

    func add(_ host: UnsafeRawPointer, _ size: Int) {
        let start = UInt(bitPattern: host)
        lock.withLock {
            if let last = ranges.last, last.end == start {
                ranges[ranges.count - 1].end = start + UInt(size)
                return
            }
            if let last = ranges.last, last.start > start { sorted = false }
            ranges.append((start, start + UInt(size)))
        }
    }

    var isEmpty: Bool { lock.withLock { ranges.isEmpty } }

    func contains(_ p: UnsafeRawPointer) -> Bool {
        let a = UInt(bitPattern: p)
        return lock.withLock {
            if ranges.isEmpty { return false }
            if !sorted {
                ranges.sort { $0.start < $1.start }
                sorted = true
            }
            var lo = 0, hi = ranges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ranges[mid].start <= a { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 && a < ranges[lo - 1].end
        }
    }
}

/// Lazy-restore counters (§6.3).
struct LazyRestoreStats {
    var overlayPages = 0
    var overlayRuns = 0
    /// Restore timing (ns): region replay (incl. shared-object fills), shared-object fills, page files.
    var regionNanoseconds: UInt64 = 0
    var sharedNanoseconds: UInt64 = 0
    var pageNanoseconds: UInt64 = 0
    mutating func add(pages: Int) {
        overlayPages += pages
        overlayRuns += 1
    }
    mutating func merge(_ o: LazyRestoreStats) {
        overlayPages += o.overlayPages
        overlayRuns += o.overlayRuns
        regionNanoseconds += o.regionNanoseconds
        pageNanoseconds += o.pageNanoseconds
    }
}

final class SnapshotSupport: @unchecked Sendable {
    static let shared: SnapshotSupport? = SnapshotSettings.fromEnvironment().map(SnapshotSupport.init)
    /// After a restore: the seconds between the snapshot's creation and the
    /// restore (the calendar's jump for the guest, §5); nil before.
    nonisolated(unsafe) var restoreCalendarGapSeconds: Int64?

    let settings: SnapshotSettings
    /// True while a snapshot is pausing the guest (the gates park threads).
    private let pausing = Atomic<Bool>(false)
    /// True while restored threads still wait for their first trap.
    private let restoring = Atomic<Bool>(false)
    /// The file-triggered snapshot has been written or has failed
    /// (`YCODE_SNAPSHOT_HOLD_APPS`).
    private let appsReleased = Atomic<Bool>(false)
    private let gateLock = HostMutex()
    /// One snapshot at a time (the file trigger, the timed ones, the stop one).
    private let snapshotLock = HostMutex(name: "snapshot")
    private let gateCondition = HostCondition()
    /// Parked threads by `ObjectIdentifier` of their context (gate lock).
    private var parked: [ObjectIdentifier: (state: SnapshotParkedThread, worker: VCPUPool.Worker)] = [:]
    /// Restored threads waiting for their first trap (gate lock), and the
    /// pool each was started on (a thread whose process ends before its
    /// first trap never takes its plan: `dropEndedRestores`).
    private var pendingRestores: [ObjectIdentifier: KernelSnapshotRestore.ThreadPlan] = [:]
    private var pendingRestorePools: [ObjectIdentifier: VCPUPool] = [:]
    /// §7 step 9: restored threads wait at their first trap until every
    /// restored thread has its vCPU and the restore is complete.
    /// `YCODE_RESTORE_NO_BARRIER=1` (diagnostics, the old behavior): no wait,
    /// and a thread whose process ended fails the restore.
    private let startGate = SnapshotRestoreStartGate()
    static let noRestoreBarrier = getenv("YCODE_RESTORE_NO_BARRIER").map { String(cString: $0) == "1" } ?? false
    private var started = false
    /// Lazy restore (§6.3): what was mapped instead of copied.
    private var lazyStats = LazyRestoreStats()

    init(_ settings: SnapshotSettings) { self.settings = settings }

    // MARK: Host services (§2.6, §9)

    /// The host services' own state, as optional `hostService` records
    /// (tag 1: the service name). Called before the quiesce, with no lock
    /// held, so a service's lock is never taken under the kernel lock.
    var hostServiceState: (() -> [SnapshotFields])?
    /// After a restore, before any thread starts: the recorded
    /// `hostService` records, for the services to take their state back.
    var restoreHostServices: (([SnapshotFieldReader]) -> Void)?
    /// Services whose state must be read with the guest quiesced (IOSurface,
    /// Metal): called with the kernel lock held once every thread is settled.
    /// Returns the records, or a reason to try again.
    var quiescedServiceState: (() -> Result<[SnapshotFields], SnapshotError>)?

    // MARK: Gates

    /// Wraps the pool callbacks of a new image (before any of its threads runs).
    func attach(_ image: GuestImageInstance) {
        let pool = image.pool
        let trap = pool.trapHandler
        pool.trapHandler = { [self] worker, frame in
            if restoring.load(ordering: .acquiring), let context = worker.context as? ThreadContext,
               let plan = takeRestore(context) {
                if !Self.noRestoreBarrier { startGate.waitForRelease() }
                if plan.fp.count == Int(CKVM_FP_STATE_SIZE) {
                    _ = plan.fp.withUnsafeBufferPointer { ckvm_set_fp_state(worker.vcpu.fd, $0.baseAddress) }
                }
                frame = plan.frame
                frame.flushTLB = true
                if plan.kind == .resume { return .resume }
            }
            if pausing.load(ordering: .acquiring) { park(worker, kind: .pendingTrap, frame: frame) }
            return trap(worker, &frame)
        }
        let stop = pool.shouldStop
        pool.shouldStop = { [self] in
            if pausing.load(ordering: .acquiring) { runGate(pool) }
            return stop()
        }
    }

    private func takeRestore(_ context: ThreadContext) -> KernelSnapshotRestore.ThreadPlan? {
        gateLock.withLock {
            let plan = pendingRestores.removeValue(forKey: ObjectIdentifier(context))
            pendingRestorePools[ObjectIdentifier(context)] = nil
            if pendingRestores.isEmpty { restoring.store(false, ordering: .releasing) }
            return plan
        }
    }

    /// Forgets the restored threads whose process ended before their first
    /// trap (their pool ended), so the first-trap check stops costing a
    /// lock on every trap. Returns how many are still pending.
    @discardableResult
    private func dropEndedRestores() -> Int {
        gateLock.withLock {
            for (key, pool) in pendingRestorePools where pool.isEnding {
                pendingRestorePools[key] = nil
                pendingRestores[key] = nil
            }
            if pendingRestores.isEmpty { restoring.store(false, ordering: .releasing) }
            return pendingRestores.count
        }
    }

    /// The run gate: a vCPU that stopped at EL0 (a kick) parks with its registers.
    private func runGate(_ pool: VCPUPool) {
        let tid = UInt64(ckvm_gettid())
        guard let worker = pool.snapshotWorkers.workers.first(where: { $0.hostTID.load(ordering: .relaxed) == tid }),
              worker.context is ThreadContext else { return }
        let vcpu = worker.vcpu
        guard let pstate = try? vcpu.get(.pstate), pstate & 0xF == 0 else { return }  // EL1: run on
        var frame = TrapFrame()
        for n in 0..<TrapFrame.registerCount { frame.x[n] = (try? vcpu.get(.x(n))) ?? 0 }
        frame.spEL0 = (try? vcpu.get(.spEL0)) ?? 0
        frame.elr = (try? vcpu.get(.pc)) ?? 0
        frame.spsr = pstate
        frame.tpidrro = (try? vcpu.get(SystemRegister.tpidrroEL0)) ?? 0
        frame.tpidr = (try? vcpu.get(SystemRegister.tpidrEL0)) ?? 0
        frame.kind = TrapFrame.Kind.svc.rawValue
        park(worker, kind: .resume, frame: frame)
    }

    /// Parks the calling vCPU thread until the snapshot ends.
    private func park(_ worker: VCPUPool.Worker, kind: SnapshotThreadKind, frame: TrapFrame) {
        guard let context = worker.context as? ThreadContext else { return }
        var fp = [UInt8](repeating: 0, count: Int(CKVM_FP_STATE_SIZE))
        let rc = fp.withUnsafeMutableBufferPointer { ckvm_get_fp_state(worker.vcpu.fd, $0.baseAddress) }
        if rc != 0 { fp = [] }
        let key = ObjectIdentifier(context)
        gateLock.lock()
        parked[key] = (SnapshotParkedThread(kind: kind, frame: frame, fp: fp), worker)
        while pausing.load(ordering: .acquiring) { gateCondition.wait(gateLock) }
        parked[key] = nil
        gateLock.unlock()
    }

    // MARK: Triggers

    /// The root process runs: start the triggers.
    func rootStarted(system: DarwinSystem, launcher: VMMLauncher, config: ExecConfiguration) {
        guard !started else { return }
        started = true
        let s = settings
        if s.stopDirectory != nil, config.device != nil { installStopTrigger(system: system, launcher: launcher, config: config) }
        if s.directory == nil, !s.census, let file = s.whenFile, s.holdAppsSeconds != nil, s.restoreDirectory == nil {
            // The app steps wait for the settled home screen without a
            // snapshot being taken then (the launcher's cold boot, §12).
            Thread.detachNewThread { [self] in
                while access(file, F_OK) != 0 { usleep(20_000) }
                usleep(UInt32(min(s.delayMilliseconds, 60_000) * 1000))
                appsReleased.store(true, ordering: .releasing)
            }
            return
        }
        guard s.directory != nil || s.census else { return }
        let start = monotonicMilliseconds()
        Thread.detachNewThread { [self] in
            var times = s.atMilliseconds.sorted()
            if times.isEmpty && s.whenFile == nil { times = [] }
            if let file = s.whenFile {
                while access(file, F_OK) != 0 { usleep(20_000) }
                usleep(UInt32(min(s.delayMilliseconds, 60_000) * 1000))
                snapshot(system: system, launcher: launcher, config: config, label: "file")
                appsReleased.store(true, ordering: .releasing)
            }
            for t in times {
                let now = monotonicMilliseconds() - start
                if t > now { usleep(UInt32(min(t - now, 4_000_000) * 1000)) }
                while monotonicMilliseconds() - start < t { usleep(10_000) }
                snapshot(system: system, launcher: launcher, config: config, label: "\(t) ms")
            }
        }
    }

    /// `YCODE_SNAPSHOT_HOLD_APPS`: called by the device session before its
    /// app steps; returns once the file-triggered snapshot is done (written
    /// or failed), after the hold's limit, or when the run ends.
    func holdAppsUntilSnapshot(isEnding: () -> Bool) {
        guard let limit = settings.holdAppsSeconds, settings.whenFile != nil,
              settings.directory != nil || settings.stopDirectory != nil, settings.restoreDirectory == nil else { return }
        snapLog(settings.directory != nil ? "app steps wait for the home-screen snapshot (at most \(limit) s)"
                : "app steps wait for the settled home screen (at most \(limit) s)")
        let began = monotonicMilliseconds(), deadline = began + UInt64(limit) * 1000
        while !appsReleased.load(ordering: .acquiring), monotonicMilliseconds() < deadline, !isEnding() { usleep(100_000) }
        let waited = (monotonicMilliseconds() - began) / 1000
        snapLog(appsReleased.load(ordering: .acquiring)
                ? (settings.directory != nil ? "app steps continue after the snapshot (held \(waited) s)"
                   : "app steps continue after the settled home screen (held \(waited) s)")
                : "app steps continue without the snapshot (held \(waited) s)")
    }

    // MARK: Stop snapshot (§12)

    /// Set by the device wiring: the pid of the app the session launched
    /// (nil: none or not yet), whether the app steps are still running, and
    /// the clean end of the session (launchd_sim shuts the guest down).
    var stopHooks: (appPID: () -> Int32?, appStepsRunning: () -> Bool, endSession: () -> Void)?
    private var stopContext: (system: DarwinSystem, launcher: VMMLauncher, config: ExecConfiguration)?
    private let stopTaken = Atomic<Bool>(false)
    /// Called once when a stop signal arrives, before the save (the display
    /// server tells its viewer that the device is stopping).
    var beforeStop: (() -> Void)?

    /// Whether SIGTERM, SIGINT and SIGHUP end the run with a stop snapshot
    /// (device mode with `YCODE_SNAPSHOT_STOP_DIR`); other signal handling
    /// (the display server's) then defers to it.
    var handlesStopSignals: Bool { settings.stopDirectory != nil }

    /// SIGTERM, SIGINT and SIGHUP end the run with a stop snapshot.
    private func installStopTrigger(system: DarwinSystem, launcher: VMMLauncher, config: ExecConfiguration) {
        gateLock.withLock { stopContext = (system, launcher, config) }
        for sig in [SIGTERM, SIGINT, SIGHUP] { _ = signal(sig, snapshotStopSignalHandler) }
        Thread.detachNewThread { [self] in
            while StopSignal.received.load(ordering: .relaxed) == 0 { usleep(50_000) }
            let sig = StopSignal.received.load(ordering: .relaxed)
            beforeStop?()
            if !stopAndSave(reason: "signal \(sig)") {
                // No snapshot: the guest shuts down cleanly (the session
                // ends) and the run ends as after its time limit; a guest
                // that does not stop within 30 s ends with the host process.
                stopHooks?.endSession()
                sleep(30)
                snapLog("stop: the guest did not shut down within 30 s; exiting")
                Glibc._exit(1)
            }
        }
    }

    /// The stop snapshot: kills the launched app (the reference IDE's Stop
    /// ends the app, the device keeps running), lets the device settle,
    /// writes the snapshot to `YCODE_SNAPSHOT_STOP_DIR` and exits the host
    /// process (status 0) without running another guest instruction.
    /// Returns false (nothing written, the run goes on) when no stop
    /// snapshot is configured, one was already tried, the app steps are
    /// still running (an install half done is not a state to keep), or the
    /// snapshot failed.
    func stopAndSave(reason: String) -> Bool {
        guard let dir = settings.stopDirectory, let ctx = gateLock.withLock({ stopContext }),
              !stopTaken.exchange(true, ordering: .acquiringAndReleasing) else { return false }
        if let file = settings.stopRequiresFile, access(file, F_OK) != 0 {
            snapLog("stop: \(reason): the device has not settled at its home screen yet; no stop snapshot")
            return false
        }
        snapLog("stop: \(reason): stopping the app and saving the device")
        if stopHooks?.appStepsRunning() ?? false {
            snapLog("stop: the app steps are still running; no stop snapshot")
            return false
        }
        if let pid = stopHooks?.appPID(), let k = ctx.system.kernel(forPID: pid) {
            k.lock.withLock { if !k.isTerminating { k.postSignal(9) } }
            let began = monotonicMilliseconds()
            while ctx.system.process(pid: pid) != nil, monotonicMilliseconds() - began < 10_000 { usleep(20_000) }
            snapLog("stop: app pid \(pid) killed; " + (ctx.system.process(pid: pid) == nil
                ? "reaped after \(monotonicMilliseconds() - began) ms" : "not reaped after 10 s"))
        }
        usleep(UInt32(settings.stopSettleMilliseconds * 1000))
        // Exits after a written snapshot, with the guest still parked. The
        // descriptors named in YCODE_SNAPSHOT_STOP_CLOSE_FDS (the launcher's
        // device lock and boot slot) are closed first, so the next run is
        // not held up while the host process's VMs are torn down (about
        // 14 s on the Thor).
        let fds = (getenv("YCODE_SNAPSHOT_STOP_CLOSE_FDS").map { String(cString: $0) } ?? "").split(separator: ",").compactMap { Int32($0) }
        _ = snapshot(system: ctx.system, launcher: ctx.launcher, config: ctx.config, label: "stop", directory: dir, exit: true,
                     beforeExit: { for fd in fds where fd > 2 { close(fd) } })
        snapLog("stop: no stop snapshot")
        return false
    }

    // MARK: Snapshot

    struct MemoryCapture {
        var regions: [SnapshotFields] = []
        var pages: [(va: UInt64, host: UnsafeRawPointer)] = []
        var anonymousResident = 0, anonymousZero = 0, fileDirty = 0, readOnlyFilePages = 0, sharedPages = 0
        var unsupported: [String] = []
    }

    /// Quiesces, captures, writes (unless census), resumes or exits.
    /// `directory`: where to write (default `YCODE_SNAPSHOT_DIR`); `exit`:
    /// end the host process after a written snapshot (default
    /// `YCODE_SNAPSHOT_EXIT`). Returns true when the snapshot was written
    /// (or counted, for a census).
    @discardableResult
    func snapshot(system: DarwinSystem, launcher: VMMLauncher, config: ExecConfiguration, label: String,
                  directory: String? = nil, exit: Bool? = nil, beforeExit: (() -> Void)? = nil) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let directory = directory ?? settings.directory
        let exitAfter = exit ?? settings.exitAfter
        var written = false
        let began = monotonicNanoseconds()
        let serviceRecords = settings.census ? [] : (hostServiceState?() ?? [])
        pausing.store(true, ordering: .releasing)
        defer {
            gateLock.withLock {
                pausing.store(false, ordering: .releasing)
                gateCondition.broadcast()
            }
        }
        let deadline = monotonicMilliseconds() + settings.deadlineMilliseconds
        var attempts = 0
        var lastReport: [String] = []
        while true {
            attempts += 1
            let images = launcher.snapshotLiveImages
            kick(images)
            // With the lock split, fast IPC paths do not take L0: every fine
            // lock is held too while the system is classified and captured.
            let done: Bool = system.lock.withLock { system.lock.withAllFineLocks {
                let pending = images.reduce(0) { $0 + $1.pool.snapshotWorkers.pendingCreations }
                let parkedNow: [ObjectIdentifier: (state: SnapshotParkedThread, worker: VCPUPool.Worker)] = gateLock.withLock { parked }
                let unstarted = Set(images.filter { $0.snapshotMainState != nil }.map { ObjectIdentifier($0.kernel.mainThread) })
                let classification = KernelSnapshotQuiesce.classify(system: system, kernels: images.map(\.kernel),
                                                                    parked: Set(parkedNow.keys), unstarted: unstarted)
                if pending > 0 || !classification.settled {
                    lastReport = (pending > 0 ? ["\(pending) vCPU creations pending"] : []) + classification.refused
                        + classification.unsettled
                    return false
                }
                var services = serviceRecords
                if !settings.census, let quiescedState = quiescedServiceState {
                    switch quiescedState() {
                    case let .success(records): services += records
                    case let .failure(e):
                        lastReport = ["host services: " + e.message]
                        return false
                    }
                }
                let quiesced = monotonicNanoseconds()
                written = capture(system: system, images: images, parked: parkedNow, classification: classification,
                                  config: config, label: label, directory: directory, began: began, quiesced: quiesced,
                                  attempts: attempts, serviceRecords: services, sysClock: launcher.snapshotSystemClock)
                return true
            } }
            if done {
                // The memory directory's files (frame record), with the guest still parked.
                if written, !settings.census { config.device?.saveMemoryDirectory() }
                break
            }
            if monotonicMilliseconds() >= deadline {
                snapLog("\(label): not settled after \(settings.deadlineMilliseconds) ms (\(attempts) attempts); "
                    + "\(lastReport.count) threads in the way, by reason:")
                var reasons: [String: Int] = [:]
                for line in lastReport {
                    let reason = line.range(of: ": ").map { String(line[$0.upperBound...]) } ?? line
                    reasons[reason, default: 0] += 1
                }
                for (reason, n) in reasons.sorted(by: { $0.value > $1.value }).prefix(30) { snapLog("  \(n) x \(reason)") }
                for line in lastReport.prefix(8) { snapLog("  e.g. " + line) }
                return false
            }
            usleep(1000)
        }
        if exitAfter, !settings.census, written {
            // No guest instruction runs after the capture: the threads stay
            // parked (the pause ends only when this function returns), so
            // the device directory stays as the snapshot saw it.
            snapLog("exiting after the snapshot")
            config.device?.finishMemoryDirectory()
            beforeExit?()
            Glibc._exit(0)
        }
        return written || settings.census
    }

    /// Kicks every worker that runs guest code (not parked, not in a handler).
    private func kick(_ images: [GuestImageInstance]) {
        let parkedWorkers: Set<ObjectIdentifier> = gateLock.withLock { Set(parked.values.map { ObjectIdentifier($0.worker) }) }
        for image in images {
            for w in image.pool.snapshotWorkers.workers where w.context != nil && !w.inHandler.load(ordering: .relaxed)
                && !parkedWorkers.contains(ObjectIdentifier(w)) {
                let tid = w.hostTID.load(ordering: .relaxed)
                if tid != 0 { _ = ckvm_kick_tid(Int(tid), VCPUPool.kickSignal) }
            }
        }
    }

    /// The capture, with the kernel lock held and every thread settled.
    private func capture(system: DarwinSystem, images: [GuestImageInstance],
                         parked: [ObjectIdentifier: (state: SnapshotParkedThread, worker: VCPUPool.Worker)],
                         classification: SnapshotClassification, config: ExecConfiguration, label: String,
                         directory: String?, began: UInt64, quiesced: UInt64, attempts: Int, serviceRecords: [SnapshotFields],
                         sysClock: (guestCounter: UInt64, bootCounter: UInt64, frequency: UInt64)?) -> Bool {
        let inputs = images.map { image in
            SnapshotImageInput(kernel: image.kernel, parked: parked.mapValues(\.state), fpState: { context in
                guard let w = image.pool.snapshotWorkers.workers.first(where: { $0.context === context }) else { return nil }
                var fp = [UInt8](repeating: 0, count: Int(CKVM_FP_STATE_SIZE))
                let rc = fp.withUnsafeMutableBufferPointer { ckvm_get_fp_state(w.vcpu.fd, $0.baseAddress) }
                return rc == 0 ? fp : nil
            }, mainStart: image.snapshotMainState.map {
                SnapshotMainStart(pc: $0.pc, sp: $0.sp, registers: $0.registers, tpidrro: $0.tpidrro, tpidr: $0.tpidr)
            })
        }
        let kernel0 = images.first?.kernel
        let capture = KernelSnapshotCapture(system: system, classification: classification)
        // §5: the clock record is in counter units (not mach units: with the
        // 24 MHz guest timebase mach time is the counter scaled).
        capture.capture(images: inputs, guestCounter: sysClock?.guestCounter ?? kernel0?.counter() ?? 0,
                        frequency: sysClock?.frequency ?? kernel0?.counterFrequency ?? 0,
                        bootCounter: sysClock?.bootCounter ?? kernel0?.bootCounter ?? 0)
        let kernelDone = monotonicNanoseconds()

        // Guest memory.
        var memory: [(image: GuestImageInstance, id: UInt64, capture: MemoryCapture)] = []
        var unsupported = capture.unsupported
        for image in images {
            let id = capture.imageID(of: image.kernel)
            let m = captureMemory(image, imageID: id, capture: capture)
            for u in m.unsupported { unsupported[u, default: 0] += 1 }
            memory.append((image, id, m))
        }
        // Shared memory objects: their resident non-zero pages, by offset.
        var sharedPages: [(id: UInt64, pages: [(va: UInt64, host: UnsafeRawPointer)])] = []
        for (id, object) in capture.sharedObjects where capture.savesPages(object) {
            sharedPages.append((id, residentPages(UnsafeRawPointer(object.host), size: object.size, base: 0)))
        }
        let memoryDone = monotonicNanoseconds()
        var records = capture.records
        for (_, _, m) in memory {
            for (i, r) in m.regions.enumerated() {
                records.append(SnapshotRecord(kind: .region, id: UInt64(10_000_000 + records.count + i), fields: r))
            }
        }
        for (i, r) in serviceRecords.enumerated() {
            records.append(SnapshotRecord(kind: .hostService, id: UInt64(9_000_000 + i), fields: r))
        }

        // Report.
        let pages = memory.reduce(0) { $0 + $1.capture.pages.count } + sharedPages.reduce(0) { $0 + $1.pages.count }
        let pageBytes = UInt64(pages) * UInt64(SnapshotPageFile.pageSize)
        snapLog("\(label): quiesced in \((quiesced - began) / 1_000_000) ms (\(attempts) attempts); kernel records "
            + "\((kernelDone - quiesced) / 1_000_000) ms, memory scan \((memoryDone - kernelDone) / 1_000_000) ms")
        snapLog("\(label): threads: " + classification.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        // Diagnostics (§12.5): replies that only a host service or a kernel
        // object can still send when the guest runs again.
        let orphanWaits = images.flatMap { $0.kernel.snapshotReplyWaitsWithoutGuestHolder() }
        for line in orphanWaits.prefix(20) { snapLog("\(label): " + line) }
        let lostRequests = images.compactMap { image -> String? in
            let n = image.kernel.snapshotLostWorkloopRequestCount
            return n > 0 ? "pid \(image.kernel.pid) \(n)" : nil
        }
        if !lostRequests.isEmpty {
            snapLog("\(label): workloops marked as requested that no queue holds (the guest has them already): "
                + lostRequests.joined(separator: ", "))
        }
        snapLog("\(label): objects: " + capture.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let anon = memory.reduce(0) { $0 + $1.capture.anonymousResident }
        let zero = memory.reduce(0) { $0 + $1.capture.anonymousZero }
        let fileDirty = memory.reduce(0) { $0 + $1.capture.fileDirty }
        let ro = memory.reduce(0) { $0 + $1.capture.readOnlyFilePages }
        let shared = memory.reduce(0) { $0 + $1.capture.sharedPages }
        let regions = memory.reduce(0) { $0 + $1.capture.regions.count }
        snapLog("\(label): memory: \(images.count) images, \(regions) regions; pages to save \(pages) (\(pageBytes >> 20) MiB): "
            + "anonymous resident \(anon) (+\(zero) zero), file copy-on-write \(fileDirty); not saved: read-only file \(ro), shared \(shared)")
        for (image, _, m) in memory.sorted(by: { $0.capture.pages.count > $1.capture.pages.count }).prefix(12) {
            snapLog("\(label):   pid \(image.pid) \((image.record.executable as NSString).lastPathComponent): "
                + "\((m.pages.count * SnapshotPageFile.pageSize) >> 20) MiB in \(m.regions.count) regions")
        }
        if !unsupported.isEmpty {
            snapLog("\(label): not restorable yet: " + unsupported.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        guard !settings.census, let directory else { return false }
        if !unsupported.isEmpty {
            snapLog("\(label): writing anyway (the restore will refuse the unsupported kinds)")
        }

        // Files.
        let timed = settings.atMilliseconds.count > 1 && directory == settings.directory && label.hasSuffix(" ms")
        let dir = directory + (timed ? "/" + label.replacingOccurrences(of: " ", with: "") : "")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var bytes: UInt64 = 0
            for (id, pages) in sharedPages {
                bytes += try writePages(pages, to: dir + "/shm-\(id).ypages")
            }
            for (_, id, m) in memory {
                bytes += try writePages(m.pages, to: dir + "/pages-\(id).ypages")
            }
            let manifest = SnapshotManifest.encode(records)
            try Data(manifest).write(to: URL(fileURLWithPath: dir + "/" + SnapshotManifest.fileName))
            bytes += UInt64(manifest.count)
            // The device directory is part of the state (files the guest
            // wrote, and guest paths name its host path). Its path and the
            // inode number of every file as the guest sees it are always
            // recorded, so a restore in place or from a copy keeps them
            // (§2.7); with YCODE_SNAPSHOT_COPY_DEVICE=1 it is also copied
            // while the guest is paused.
            if let device = config.device {
                try Data((device.dev + "\n").utf8).write(to: URL(fileURLWithPath: dir + "/device-path"))
                try Self.writeDeviceInodes(device.dev, to: dir + "/device-inodes")
            }
            if let device = config.device, getenv("YCODE_SNAPSHOT_COPY_DEVICE").map({ String(cString: $0) == "1" }) ?? false {
                let copyStart = monotonicNanoseconds()
                let cp = Process()
                cp.executableURL = URL(fileURLWithPath: "/bin/cp")
                cp.arguments = ["-a", device.dev, dir + "/device"]
                try cp.run()
                cp.waitUntilExit()
                snapLog("\(label): copied the device directory in \((monotonicNanoseconds() - copyStart) / 1_000_000) ms (cp status \(cp.terminationStatus))")
            }
            let written = monotonicNanoseconds()
            snapLog("\(label): wrote \(dir): manifest \(manifest.count / 1024) KiB (\(records.count) records), "
                + "\(bytes >> 20) MiB in all, in \((written - memoryDone) / 1_000_000) ms; total pause \((written - began) / 1_000_000) ms")
            return true
        } catch {
            snapLog("\(label): cannot write \(dir): \(error)")
            return false
        }
    }

    // MARK: Memory

    private func captureMemory(_ image: GuestImageInstance, imageID: UInt64, capture: KernelSnapshotCapture) -> MemoryCapture {
        var m = MemoryCapture()
        let space = image.space, vm = image.vm
        let page = UInt64(SnapshotPageFile.pageSize)
        let hostPage = UInt64(ckvm_host_page_size())
        let perPage = Int(page / hostPage)
        let roWindow = KVMPhysicalBacking.defaultReadOnlyFileWindowGPA
        for r in space.regions {
            typealias R = ST_Region
            var g = SnapshotFields()
            g.ref(R.image, imageID)
            g.u64(R.va, r.va)
            g.u64(R.size, r.size)
            g.u64(R.protection, UInt64(r.protection.rawValue))
            g.bool(R.permanent, r.permanent)
            let pageCount = Int(r.size / page)
            switch r.backing {
            case .unbacked:
                // A lazy anonymous mapping's untouched part: zeros, no pages
                // (app-launch.md §3.2); its touched blocks are regions of their own.
                g.u64(R.kind, 1)
            case let .anonymous(gpa):
                g.u64(R.kind, 1)
                guard let host = try? vm.hostPointer(gpa: gpa, count: Int(r.size)) else {
                    m.unsupported.append("anonymous region outside a memslot")
                    break
                }
                var vec = [UInt8](repeating: 0, count: pageCount * perPage)
                let rc = vec.withUnsafeMutableBufferPointer { ckvm_mincore(host, Int(r.size), $0.baseAddress) }
                for i in 0..<pageCount {
                    let resident = rc != 0 || (0..<perPage).contains { vec[i * perPage + $0] & 1 != 0 }
                        || SnapshotOverlays.shared.contains(host + i * Int(page))
                    guard resident else { continue }
                    let p = UnsafeRawPointer(host + i * Int(page))
                    if isZero(p, Int(page)) { m.anonymousZero += 1; continue }
                    m.anonymousResident += 1
                    m.pages.append((r.va + UInt64(i) * page, p))
                }
            case let .file(path, offset, gpa):
                let file = space.file(at: r.va)
                var st = stat()
                if let file, fstat(file.hostFD, &st) == 0, st.st_nlink == 0,
                   let host = try? vm.hostPointer(gpa: gpa, count: Int(r.size)) {
                    // The file is gone (unlinked while mapped): the mapping's
                    // contents are saved and it comes back as anonymous memory.
                    g.u64(R.kind, 1)
                    for i in 0..<pageCount {
                        let p = UnsafeRawPointer(host + i * Int(page))
                        if isZero(p, Int(page)) { continue }
                        m.fileDirty += 1
                        m.pages.append((r.va + UInt64(i) * page, p))
                    }
                    m.regions.append(g)
                    continue
                }
                g.u64(R.kind, 2)
                g.string(R.guestPath, path)
                g.u64(R.offset, offset)
                g.string(R.hostPath, file?.hostPath ?? path)
                if gpa >= roWindow {
                    m.readOnlyFilePages += pageCount
                    break
                }
                guard let slot = vm.memorySlot(containing: gpa),
                      let host = try? vm.hostPointer(gpa: gpa, count: Int(r.size)) else {
                    m.unsupported.append("file region outside a memslot")
                    break
                }
                if slot.kind == .file {
                    var map = [UInt64](repeating: 0, count: pageCount * perPage)
                    let n = map.withUnsafeMutableBufferPointer { ckvm_pagemap(host, pageCount * perPage, $0.baseAddress) }
                    for i in 0..<pageCount {
                        let dirty = n < pageCount * perPage || (0..<perPage).contains {
                            let e = map[i * perPage + $0]
                            return e & (1 << 63) != 0 && e & (1 << 61) == 0
                        } || SnapshotOverlays.shared.contains(host + i * Int(page))
                        guard dirty else { continue }
                        m.fileDirty += 1
                        m.pages.append((r.va + UInt64(i) * page, UnsafeRawPointer(host + i * Int(page))))
                    }
                } else {
                    // A copy in pool memory: pages that differ from the file.
                    for i in 0..<pageCount {
                        let p = UnsafeRawPointer(host + i * Int(page))
                        let bytes = (try? file?.read(count: Int(page), offset: offset + UInt64(i) * page)) ?? nil
                        let same = bytes.map { b in
                            b.withUnsafeBytes { memcmp(p, $0.baseAddress!, b.count) == 0 } && isZero(p + b.count, Int(page) - b.count)
                        } ?? false
                        if same { continue }
                        m.fileDirty += 1
                        m.pages.append((r.va + UInt64(i) * page, p))
                    }
                }
            case let .shared(_, offset, _):
                g.u64(R.kind, 3)
                g.u64(R.offset, offset)
                m.sharedPages += pageCount
                if let object = space.sharedObject(at: r.va) {
                    g.ref(R.shared, capture.sharedObjectID(object))
                } else {
                    m.unsupported.append("shared region without an object")
                }
            }
            m.regions.append(g)
        }
        m.pages.sort { $0.va < $1.va }
        return m
    }

    /// The resident, non-zero 16 KiB pages of host memory [host, host+size),
    /// addressed from `base`.
    private func residentPages(_ host: UnsafeRawPointer, size: UInt64, base: UInt64) -> [(va: UInt64, host: UnsafeRawPointer)] {
        let page = SnapshotPageFile.pageSize
        let perPage = page / Int(ckvm_host_page_size())
        let count = Int(size) / page
        var vec = [UInt8](repeating: 0, count: count * perPage)
        let rc = vec.withUnsafeMutableBufferPointer { ckvm_mincore(host, Int(size), $0.baseAddress) }
        var out: [(va: UInt64, host: UnsafeRawPointer)] = []
        for i in 0..<count {
            guard rc != 0 || (0..<perPage).contains(where: { vec[i * perPage + $0] & 1 != 0 }) else { continue }
            let p = host + i * page
            if isZero(p, page) { continue }
            out.append((base + UInt64(i * page), p))
        }
        return out
    }

    private func isZero(_ p: UnsafeRawPointer, _ count: Int) -> Bool {
        guard count > 0 else { return true }
        let words = count / 8
        let w = p.assumingMemoryBound(to: UInt64.self)
        for i in 0..<words where w[i] != 0 { return false }
        for i in words * 8..<count where p.load(fromByteOffset: i, as: UInt8.self) != 0 { return false }
        return true
    }

    private func writePages(_ pages: [(va: UInt64, host: UnsafeRawPointer)], to path: String) throws -> UInt64 {
        let extents = SnapshotPageFile.extents(of: pages.map(\.va))
        let (header, _) = SnapshotPageFile.header(for: extents)
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw SnapshotError("open \(path): errno \(errno)") }
        defer { close(fd) }
        func put(_ p: UnsafeRawPointer, _ n: Int) throws {
            var done = 0
            while done < n {
                let w = write(fd, p + done, n - done)
                if w < 0 { if errno == EINTR { continue }; throw SnapshotError("write \(path): errno \(errno)") }
                done += w
            }
        }
        try header.withUnsafeBytes { try put($0.baseAddress!, header.count) }
        for p in pages { try put(p.host, SnapshotPageFile.pageSize) }
        return UInt64(header.count) + UInt64(pages.count) * UInt64(SnapshotPageFile.pageSize)
    }

    // MARK: Restore

    /// `YCODE_RESTORE_DIR`: restores the snapshot instead of spawning the
    /// root process. Returns the root kernel, or nil when no restore was asked.
    func restoreIfRequested(system: DarwinSystem, launcher: VMMLauncher, config: ExecConfiguration) throws -> DarwinKernel? {
        guard let dir = settings.restoreDirectory else { return nil }
        let began = monotonicNanoseconds()
        // No new guest thread starts until the restored ones have their vCPUs (§12.4).
        PoolThreadHost.restoring.store(true, ordering: .releasing)
        defer { PoolThreadHost.restoring.store(false, ordering: .releasing) }
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + SnapshotManifest.fileName))
        let (created, records) = try SnapshotManifest.decode([UInt8](manifestData))
        // §5, §12.5: how far the calendar moved while the snapshot sat on disk.
        restoreCalendarGapSeconds = max(0, Int64(Date().timeIntervalSince1970) - Int64(bitPattern: created))
        if let device = config.device, FileManager.default.fileExists(atPath: dir + "/device-inodes") {
            let n = Self.installDeviceInodes(device.dev, from: dir + "/device-inodes")
            snapLog("restore: \(n) device files keep their recorded inode numbers")
        }
        let restore = try KernelSnapshotRestore(records: records, system: system)
        // §5: the guest counter continues at the snapshot's value.
        let offset = Hypervisor.hostCounter() &- restore.clock.guestCounter
        launcher.snapshotPresetSystemClock(offset: offset, bootHostCounter: restore.clock.bootCounter &+ offset)

        let plans = try restore.makeProcesses(makeFileSystem: { config.makeRootFileSystem() })
        var images: [ObjectIdentifier: GuestImageInstance] = [:]
        var imageByRecord: [UInt64: GuestImageInstance] = [:]
        for plan in plans {
            var request = ProcessImageRequest(executablePath: plan.executablePath, hostExecutablePath: plan.hostExecutablePath,
                                              argv: [plan.executablePath], envp: [])
            request.startSuspended = true
            let handle = try system.lock.withLock { try launcher.launch(request, kernel: plan.kernel) }
            restore.setLaunchedImage(handle, for: plan.kernel)
            guard let image = (handle as? LaunchHandle)?.image else { throw SnapshotError("pid \(plan.pid): no image") }
            images[ObjectIdentifier(plan.kernel)] = image
            imageByRecord[plan.recordID] = image
        }
        let launched = monotonicNanoseconds()

        // Memory (§7 step 5).
        var pageCount = 0
        let regionRecords = records.filter { $0.knownKind == .region }
        var regionsByImage: [UInt64: [SnapshotFieldReader]] = [:]
        for r in regionRecords {
            let g = try r.fields()
            regionsByImage[g.ref(ST_Region.image), default: []].append(g)
        }
        var skippedShared = 0
        // Every shared memory object first (made once, filled once; the
        // images then only map them), then the images' memory, one image
        // after the other (`YCODE_RESTORE_PARALLEL=1`: in parallel; slower on
        // the Thor, where the host mappings serialize on the process's
        // memory-map lock: 6.7 s against 4.0 s).
        let shmStart = monotonicNanoseconds()
        var filledShared = Set<UInt64>()
        for id in restore.sharedObjectRecords {
            filledShared.insert(id)
            do {
                let object = try restore.sharedObject(forRecord: id)
                try fillPages(object, from: dir + "/shm-\(id).ypages")
            } catch {
                guard settings.measureRestore || KernelSnapshotRestore.lenient else { throw error }
                snapLog("restore: shared memory \(id): \(error)")
            }
        }
        lazyStats.sharedNanoseconds = monotonicNanoseconds() - shmStart
        let work = imageByRecord.sorted { $0.key < $1.key }
        let parallel = getenv("YCODE_RESTORE_PARALLEL").map { String(cString: $0) == "1" } ?? false
        // (Each image is restored by one thread; the shared state is behind `results.lock`.)
        final class Results: @unchecked Sendable {
            let lock = HostMutex(name: "restore results")
            var pages = 0, skipped = 0, stats = LazyRestoreStats(), error: Error?
            let job: (Int) -> (pages: Int, skipped: Int, stats: LazyRestoreStats)?
            init(job: @escaping (Int) -> (pages: Int, skipped: Int, stats: LazyRestoreStats)?) { self.job = job }
        }
        var jobError: Error?
        let errorLock = HostMutex(name: "restore error")
        let results = Results { [self] i in
            let (recordID, image) = work[i]
            var stats = LazyRestoreStats(), skipped = 0, filled = filledShared
            do {
                let n = try restoreMemory(image, regions: regionsByImage[recordID] ?? [], pageFile: dir + "/pages-\(recordID).ypages",
                                          skippedShared: &skipped, restore: restore, shmDirectory: dir, filledShared: &filled,
                                          stats: &stats)
                return (n, skipped, stats)
            } catch {
                errorLock.withLock { if jobError == nil { jobError = error } }
                return nil
            }
        }
        let run: @Sendable (Int) -> Void = { i in
            guard let r = results.job(i) else { return }
            results.lock.withLock {
                results.pages += r.pages
                results.skipped += r.skipped
                results.stats.merge(r.stats)
            }
        }
        if parallel {
            DispatchQueue.concurrentPerform(iterations: work.count, execute: run)
        } else {
            for i in work.indices { run(i) }
        }
        if let jobError { throw jobError }
        pageCount += results.pages
        skippedShared += results.skipped
        lazyStats.merge(results.stats)
        let memoryDone = monotonicNanoseconds()
        snapLog("restore: memory: \((memoryDone - launched) / 1_000_000) ms (\(parallel ? "parallel" : "serial")); shared objects "
            + "\(lazyStats.sharedNanoseconds / 1_000_000) ms, then per image (summed): regions \(lazyStats.regionNanoseconds / 1_000_000) ms, "
            + "page files \(lazyStats.pageNanoseconds / 1_000_000) ms")
        if settings.lazyRestore {
            snapLog("restore: lazy: \(lazyStats.overlayPages) pages (\((lazyStats.overlayPages * SnapshotPageFile.pageSize) >> 20) MiB) "
                + "mapped from the page files in \(lazyStats.overlayRuns) runs; \(pageCount - lazyStats.overlayPages) pages copied")
            if settings.prefetch {
                let files = imageByRecord.keys.sorted().map { dir + "/pages-\($0).ypages" }
                Thread.detachNewThread {
                    let began = monotonicNanoseconds()
                    var bytes: UInt64 = 0
                    for path in files {
                        let fd = open(path, O_RDONLY | O_CLOEXEC)
                        guard fd >= 0 else { continue }
                        var st = stat()
                        if fstat(fd, &st) == 0 {
                            _ = ckvm_prefetch_file(fd, 0, UInt64(st.st_size))
                            bytes += UInt64(st.st_size)
                        }
                        close(fd)
                    }
                    snapLog("restore: prefetch of \(files.count) page files (\(bytes >> 20) MiB) requested in "
                        + "\((monotonicNanoseconds() - began) / 1_000_000) ms")
                }
            }
        }

        if settings.measureRestore {
            snapLog("measure: \(plans.count) images in \((launched - began) / 1_000_000) ms, memory \(pageCount) pages "
                + "(\((pageCount * SnapshotPageFile.pageSize) >> 20) MiB) in \((memoryDone - launched) / 1_000_000) ms; skipped \(skippedShared) shared regions")
            do {
                let t = try restore.restoreObjects(memory: { images[ObjectIdentifier($0)]?.space })
                snapLog("measure: objects in \((monotonicNanoseconds() - memoryDone) / 1_000_000) ms, \(t.count) threads")
            } catch {
                snapLog("measure: objects failed after \((monotonicNanoseconds() - memoryDone) / 1_000_000) ms: \(error)")
            }
            Glibc._exit(0)
        }

        // Kernel objects (§7 steps 6–7).
        let threads = try restore.restoreObjects(memory: { images[ObjectIdentifier($0)]?.space })
        for w in restore.warnings.prefix(20) { snapLog("restore warning: " + w) }
        if restore.warnings.count > 20 { snapLog("restore: \(restore.warnings.count) warnings in all") }
        let objectsDone = monotonicNanoseconds()

        // Main threads that had not started (start holds, §3.2): they start
        // from the recorded state when the image is resumed.
        system.lock.withLock {
            // Every other image's main thread ran before the snapshot: its
            // state comes back with the thread records, never from the build.
            for image in images.values { image.snapshotMainState = nil }
            for (kernel, s) in restore.unstartedMains {
                images[ObjectIdentifier(kernel)]?.snapshotMainState = VCPUStartState(pc: s.pc, sp: s.sp, registers: s.registers,
                                                                                    tpidrro: s.tpidrro, tpidr: s.tpidr)
            }
        }

        // Host services take their state back before any guest thread runs (§7 step 8).
        let serviceRecords = try records.filter { $0.kind == SnapshotRecordKind.hostService.rawValue }.map { try $0.fields() }
        restoreHostServices?(serviceRecords)
        let servicesDone = monotonicNanoseconds()

        // Threads (§7 step 9).
        guard let stub = Self.svcStubAddress(config.stubs) else { throw SnapshotError("no svc in the host page") }
        // Every thread gets its vCPU first; none runs before the restore is
        // complete (the start gate, released at the end): a thread that ran
        // at once could end its process while that process's other threads
        // were still being started (the "no vCPU for thread N" failures of §12).
        let startable = threads.filter { images[ObjectIdentifier($0.kernel)] != nil }
        gateLock.withLock {
            for t in startable {
                pendingRestores[ObjectIdentifier(t.context)] = t
                pendingRestorePools[ObjectIdentifier(t.context)] = images[ObjectIdentifier(t.kernel)]!.pool
            }
            if !pendingRestores.isEmpty { restoring.store(true, ordering: .releasing) }
        }
        // Diagnostics: threads that restart at a trap which can end their
        // process (exit, kill, __pthread_kill, terminate/abort_with_payload):
        // without the gate, the first of them to run could end its process
        // while its other threads were still waiting for a start.
        let endingTraps: Set<UInt64> = [1, 37, 328, 520, 521]
        let ending = startable.filter { t in
            guard t.kind == .pendingTrap else { return false }
            let n = t.frame.x[16] == 0 ? t.frame.x[0] & 0xFFFF : t.frame.x[16]
            return endingTraps.contains(n)
        }
        if !ending.isEmpty {
            snapLog("restore: \(ending.count) threads restart at a trap that can end their process: "
                + ending.prefix(8).map { "pid \($0.kernel.pid) thread \($0.context.threadID) trap \($0.frame.x[16] == 0 ? $0.frame.x[0] & 0xFFFF : $0.frame.x[16])" }
                    .joined(separator: ", "))
        }
        var restoredPerProcess: [Int32: Int] = [:]
        for t in startable { restoredPerProcess[t.kernel.pid, default: 0] += 1 }
        let starts = try SnapshotRestoreStartGate.startAll(startable, start: { t in
            try images[ObjectIdentifier(t.kernel)]!.pool.start(VCPUStartState(pc: stub, sp: 0), context: t.context)
        }, processEnded: { t in
            !Self.noRestoreBarrier && images[ObjectIdentifier(t.kernel)]!.pool.isEnding
        }, describe: { t in
            let pool = images[ObjectIdentifier(t.kernel)]!.pool
            let end = pool.currentTermination.map { " (pool ended: \($0.kind) \($0.status) \($0.message))" } ?? ""
            // Which vCPUs hold a thread that is not one of the restored ones.
            let restoredIDs = Set(startable.filter { $0.kernel === t.kernel }.map { ObjectIdentifier($0.context) })
            let d = pool.debugState
            let foreign = d.contexts.compactMap { c -> String? in
                guard let c else { return "none" }
                if restoredIDs.contains(ObjectIdentifier(c)) { return nil }
                return (c as? ThreadContext).map { "thread \($0.threadID)" } ?? "other"
            }
            return "pid \(t.kernel.pid): no vCPU for thread \(t.context.threadID): \(restoredPerProcess[t.kernel.pid] ?? 0) "
                + "restored threads, pool \(pool.vcpuCount) of \(pool.capacity) vCPUs, \(pool.parkedCount) parked\(end); "
                + "creating \(d.creating), warming \(d.warming), next index \(d.nextIndex), active \(d.active); "
                + "vCPUs not holding a restored thread of this process: \(foreign.isEmpty ? "none" : foreign.joined(separator: ", "))"
        })
        for (t, index) in starts.started { t.context.vcpuIndex = index }
        if !starts.skipped.isEmpty {
            let pids = Set(starts.skipped.map(\.kernel.pid)).sorted()
            snapLog("restore: \(starts.skipped.count) threads not started: their process ended during the restore (pids \(pids))")
            dropEndedRestores()
        }
        // §8 option 1: processes named in YCODE_RESTORE_KILL (the GPU and
        // IOSurface clients, whose host-service state is not restored) are
        // killed at once; launchd_sim sees them exit and relaunches the jobs.
        // The entry `auto` names the processes the snapshot recorded as Metal
        // clients (the `metal` host-service record).
        let killNames = Set((getenv("YCODE_RESTORE_KILL").map { String(cString: $0) } ?? "").split(separator: ",").map(String.init))
        let gpuClients = Set(serviceRecords.filter { $0.string(ST_HostService.name) == "metal" }
            .flatMap { $0.u64s(ST_HostService.pids) }.map { Int32(truncatingIfNeeded: $0) })
        if !killNames.isEmpty {
            for plan in plans {
                let name = (plan.executablePath as NSString).lastPathComponent
                // An entry *text* matches every name that contains text.
                let match = killNames.contains(name) || killNames.contains("*") || killNames.contains { k in
                    k.count > 2 && k.hasPrefix("*") && k.hasSuffix("*") && name.contains(k.dropFirst().dropLast())
                } || (killNames.contains("auto") && gpuClients.contains(plan.pid))
                guard match else { continue }
                plan.kernel.lock.withLock { plan.kernel.postSignal(9) }
                snapLog("restore: killed pid \(plan.pid) \(name) (YCODE_RESTORE_KILL)")
            }
        }
        restore.restoreStartHolds()
        // §5: the calendar moved on while the snapshot sat on disk. Every
        // image's commpage wall-clock snapshot is taken again (the restored
        // one pairs the capture's mach time with the capture's calendar
        // time), so the guest's first reads give the time of now.
        system.lock.withLock {
            for plan in plans {
                guard let publish = plan.kernel.timeOfDayPublisher else { continue }
                let w = plan.kernel.wallClock()
                publish(plan.kernel.counter(), w.seconds, w.nanoseconds)
            }
        }
        if restore.wallClockTimers > 0 {
            snapLog("restore: \(restore.wallClockTimers) calendar-time timers set from the wall clock")
        }
        if restore.readOnlyReopens > 0 {
            snapLog("restore: \(restore.readOnlyReopens) files opened read-write again although their mode is read-only now")
        }
        // Thread requests the restored knotes call for (§7 step 10), and
        // those that arrived during the restore and were kept pending.
        PoolThreadHost.restoring.store(false, ordering: .releasing)
        let requeued = system.lock.withLock { plans.reduce(0) { $0 + $1.kernel.snapshotReissueThreadRequests() } }
        if requeued > 0 { snapLog("restore: \(requeued) workloop thread requests that no queue held were issued again") }
        if !restore.unstartedMains.isEmpty || restore.heldProcessCount > 0 {
            snapLog("restore: \(restore.unstartedMains.count) images not started yet, \(restore.heldProcessCount) start holds held again")
        }
        // §7 step 9: the restored threads run from here on.
        startGate.release()
        if !Self.noRestoreBarrier {
            // Threads whose process ends before their first trap never take
            // their plan: forget them once their pool has ended.
            Thread.detachNewThread { [self] in
                for _ in 0..<600 {
                    if dropEndedRestores() == 0 { break }
                    usleep(1_000_000)
                }
            }
        }
        let done = monotonicNanoseconds()
        snapLog("restored \(dir): \(plans.count) images, \(threads.count) threads, \(pageCount) pages "
            + "(\((pageCount * SnapshotPageFile.pageSize) >> 20) MiB) in \((done - began) / 1_000_000) ms "
            + "(images \((launched - began) / 1_000_000) ms, memory \((memoryDone - launched) / 1_000_000) ms, "
            + "objects \((objectsDone - memoryDone) / 1_000_000) ms, host services \((servicesDone - objectsDone) / 1_000_000) ms)")
        for t in threads where !t.note.isEmpty || t.kind != .blocked {
            if config.trace { snapLog("  pid \(t.kernel.pid) thread \(t.context.threadID): \(t.kind) \(t.note)") }
        }
        guard let root = system.kernel(forPID: VMLayout.guestPID) ?? plans.first?.kernel else {
            throw SnapshotError("the snapshot has no live process")
        }
        return root
    }

    /// `device-inodes`: one entry per file below `root`, "<inode>\t<relative
    /// path>\0", the inode as the guest sees it.
    static func writeDeviceInodes(_ root: String, to path: String) throws {
        var out = [UInt8]()
        out.reserveCapacity(1 << 20)
        guard let walk = FileManager.default.enumerator(atPath: root) else { throw SnapshotError("cannot list \(root)") }
        while let rel = walk.nextObject() as? String {
            var st = stat()
            guard lstat(root + "/" + rel, &st) == 0 else { continue }
            let ino = DarwinInodeMap.guestInode(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))
            out += Array("\(ino)\t".utf8) + Array(rel.utf8) + [0]
        }
        try Data(out).write(to: URL(fileURLWithPath: path))
    }

    /// Restore from a copy of the device directory: maps every file's new
    /// host inode to the recorded one (§2.7). Returns the number of files
    /// whose inode differs.
    static func installDeviceInodes(_ root: String, from path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path) else { return 0 }
        var entries: [(dev: UInt64, hostIno: UInt64, guestIno: UInt64)] = []
        for entry in data.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9),
                  let ino = UInt64(String(decoding: entry[entry.startIndex..<tab], as: UTF8.self)) else { continue }
            let rel = String(decoding: entry[(tab + 1)...], as: UTF8.self)
            var st = stat()
            guard lstat(root + "/" + rel, &st) == 0, UInt64(st.st_ino) != ino else { continue }
            entries.append((UInt64(st.st_dev), UInt64(st.st_ino), ino))
        }
        DarwinInodeMap.install(entries)
        return entries.count
    }

    /// A page file's extents and data offset.
    static func readPageFileHeader(_ path: String) throws -> ([SnapshotPageFile.Extent], UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw SnapshotError("cannot open \(path)") }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 32))
        guard head.count == 32 else { throw SnapshotError("\(path): truncated header") }
        let dataOffset = head[24..<32].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        try handle.seek(toOffset: 0)
        return try SnapshotPageFile.parseHeader([UInt8](handle.readData(ofLength: Int(dataOffset))))
    }

    /// Copies a page file into a shared memory object (offsets as addresses).
    private func fillPages(_ object: SharedMemoryObject, from path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let (extents, dataOffset) = try Self.readPageFileHeader(path)
        try handle.seek(toOffset: dataOffset)
        for e in extents {
            let n = Int(e.pageCount) * SnapshotPageFile.pageSize
            guard e.address + UInt64(n) <= object.size else { throw SnapshotError("\(path): extent outside the object") }
            let data = handle.readData(ofLength: n)
            guard data.count == n else { throw SnapshotError("\(path): truncated") }
            data.withUnsafeBytes { _ = memcpy(object.host + Int(e.address), $0.baseAddress!, n) }
        }
    }

    /// The address of the first `svc #0x80` in the host page's code.
    static func svcStubAddress(_ stubs: [UInt8]) -> UInt64? {
        let svc: UInt32 = 0xD400_1001
        var i = 0
        while i + 4 <= min(stubs.count, Int(VMLayout.hostPageCodeSize)) {
            let w = UInt32(stubs[i]) | UInt32(stubs[i + 1]) << 8 | UInt32(stubs[i + 2]) << 16 | UInt32(stubs[i + 3]) << 24
            if w == svc { return VMLayout.hostPageVA + VMLayout.hostPageCodeOffset + UInt64(i) }
            i += 4
        }
        return nil
    }

    private func restoreMemory(_ image: GuestImageInstance, regions: [SnapshotFieldReader], pageFile: String,
                               skippedShared: inout Int, restore: KernelSnapshotRestore, shmDirectory: String,
                               filledShared: inout Set<UInt64>, stats: inout LazyRestoreStats) throws -> Int {
        let space = image.space
        typealias R = ST_Region
        // The fresh image's own mappings go (the permanent ones stay).
        let t0 = monotonicNanoseconds()
        for r in space.regions where !r.permanent { try space.unmap(va: r.va, size: r.size) }
        var files: [String: GuestFile] = [:]
        for g in regions.sorted(by: { $0.u64(R.va) < $1.u64(R.va) }) {
            let va = g.u64(R.va), size = g.u64(R.size)
            let protection = VMProtection(rawValue: g.u32(R.protection))
            if g.bool(R.permanent) {
                guard space.region(containing: va) != nil else { throw SnapshotError("permanent region \(hex(va)) missing") }
                continue
            }
            do {
            switch g.u64(R.kind) {
            case 1:
                _ = try space.mapAnonymous(at: va, size: size, protection: protection, hint: nil)
            case 2:
                let hostPath = g.string(R.hostPath) ?? "", guestPath = g.string(R.guestPath) ?? hostPath
                let file: GuestFile
                if let f = files[hostPath] { file = f } else {
                    do {
                        file = try GuestFile.openReadOnly(hostPath: hostPath, guestPath: guestPath)
                    } catch {
                        throw SnapshotError("\(guestPath): cannot map again: \(error)")
                    }
                    files[hostPath] = file
                }
                _ = try space.mapFile(file, offset: g.u64(R.offset), at: va, size: size, protection: protection, hint: nil)
            case 3 where g.has(R.shared):
                let id = g.ref(R.shared)
                let object = try restore.sharedObject(forRecord: id)
                if !filledShared.contains(id) {
                    filledShared.insert(id)
                    let f0 = monotonicNanoseconds()
                    try fillPages(object, from: shmDirectory + "/shm-\(id).ypages")
                    stats.sharedNanoseconds += monotonicNanoseconds() - f0
                }
                _ = try space.mapShared(object, offset: g.u64(R.offset), at: va, size: size, protection: protection, hint: nil)
            default:
                if settings.measureRestore {
                    skippedShared += 1
                    _ = try space.mapAnonymous(at: va, size: size, protection: protection, hint: nil)
                    continue
                }
                throw SnapshotError("region \(hex(va)): shared memory is not restorable yet")
            }
            } catch {
                guard settings.measureRestore || KernelSnapshotRestore.lenient else { throw error }
                skippedShared += 1
                if skippedShared <= 5 { snapLog("measure: pid \(image.pid) region \(hex(va)): \(error)") }
                _ = try? space.mapAnonymous(at: va, size: size, protection: protection, hint: nil)
            }
        }
        // The saved pages: straight into the host memory behind each page,
        // except pages of the shared read-only file window (the address
        // space moves those to a private copy first). Lazy restore (§6.3):
        // runs of pages in the anonymous pool or in a private file mapping
        // are mapped from the page file instead (private, copy-on-write),
        // and read when the guest first touches them.
        let t1 = monotonicNanoseconds()
        stats.regionNanoseconds += t1 - t0
        defer { stats.pageNanoseconds += monotonicNanoseconds() - t1 }
        let (extents, dataOffset) = try Self.readPageFileHeader(pageFile)
        let fd = open(pageFile, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SnapshotError("cannot open \(pageFile)") }
        defer { close(fd) }
        let page = SnapshotPageFile.pageSize
        let roWindow = KVMPhysicalBacking.defaultReadOnlyFileWindowGPA
        var count = 0
        var fileOffset = off_t(dataOffset)
        var buffer = [UInt8](repeating: 0, count: page)
        let backing = space.backing as? KVMPhysicalBacking
        for e in extents {
            var i = 0
            while i < Int(e.pageCount) {
                let va = e.address + UInt64(i * page)
                if settings.lazyRestore, let r = space.region(containing: va), r.gpa < roWindow {
                    let gpa = r.gpa + (va - r.va)
                    let n = min(Int(e.pageCount) - i, Int((r.end - va) / UInt64(page)))
                    if let slot = image.vm.memorySlot(containing: gpa), slot.kind == .anonymousPool || slot.kind == .file,
                       slot.contains(gpa: gpa, count: n * page),
                       let host = try? image.vm.writableHostPointer(gpa: gpa, count: n * page),
                       ckvm_map_overlay(host, n * page, fd, UInt64(fileOffset)) == 0 {
                        if slot.kind == .anonymousPool { backing?.hasOverlays = true }
                        SnapshotOverlays.shared.add(UnsafeRawPointer(host), n * page)
                        stats.add(pages: n)
                        fileOffset += off_t(n * page)
                        count += n
                        i += n
                        continue
                    }
                }
                defer { i += 1 }
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, page, fileOffset) }
                guard n == page else { throw SnapshotError("\(pageFile): truncated") }
                fileOffset += off_t(page)
                if let r = space.region(containing: va), r.gpa < roWindow,
                   let host = try? image.vm.writableHostPointer(gpa: r.gpa + (va - r.va), count: page) {
                    _ = buffer.withUnsafeBytes { memcpy(host, $0.baseAddress!, page) }
                } else {
                    try space.write(va: va, bytes: buffer, checkingEL0Access: false)
                }
                count += 1
            }
        }
        return count
    }
}

/// The host-service record's tags (§9): `device-session` has the control
/// channel and the session port (host-task names); `metal` has the client pids.
enum ST_HostService {
    static let name: UInt16 = 1, channel: UInt16 = 2, session: UInt16 = 3, pids: UInt16 = 4
    /// `scdynamicstore`: the open sessions (nested: 1 session port, 2 notify rights).
    static let sessions: UInt16 = 5
    /// `iosurface`, `metal`: the service's own state (nested payload, the service's tags).
    static let state: UInt16 = 6
    /// `hid`: the host-task name of the send right to the guest HID bundle's
    /// port (hid-input.md §7 item 6); absent while no bundle has registered.
    static let hidClient: UInt16 = 7
}

/// The region record's tags (the kernel module keeps the others).
enum ST_Region {
    static let image: UInt16 = 1, va: UInt16 = 2, size: UInt16 = 3, protection: UInt16 = 4, kind: UInt16 = 5
    static let guestPath: UInt16 = 6, hostPath: UInt16 = 7, offset: UInt16 = 8, shared: UInt16 = 9, permanent: UInt16 = 10
}
#endif
