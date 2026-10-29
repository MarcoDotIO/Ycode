// ycode-simd: the frame profile (diagnostics, off by default;
// specs/simulator/frame-profile.md).
//
// `YCODE_FRAME_PROFILE=<path>` turns it on. Nothing is recorded until a
// window is opened: creating the file `<path>.go` (its content: the window
// length in seconds, default 10) opens one; the poller (every 100 ms)
// deletes the file. While the window is open:
//   - every trap of every guest thread is recorded (enter, exit), every
//     wait-queue sleep (block, unblock) and every wakeup (who woke whom),
//     with CLOCK_MONOTONIC times, into a preallocated array
//     (`YCODE_FRAME_PROFILE_EVENTS`, default 4 Mi events of 32 bytes; when it
//     is full, recording stops and the summary says so);
//   - the frame record is polled every 1 ms (presents, with their counter).
// When the window closes: `<path>.<n>.trace` (the events, binary),
// `<path>.<n>.names` (pid → program, guest thread → kind) and
// `<path>.<n>.summary` (per program: host CPU split, run-queue wait,
// context switches, KVM exits, faults, time in KVM_RUN and in trap handlers
// over the window, and frames presented). `scripts/ycode-frame-profile`
// turns them into the per-frame timeline.
//
// Boot windows (frame-profile.md §9, boot-profile.md §8):
// `YCODE_FRAME_PROFILE_BOOT=<max s>` opens window 1 before the root process
// is spawned and closes it `YCODE_FRAME_PROFILE_BOOT_TAIL` seconds (default
// 3) after the home screen is first seen (two lit checks of the presented
// surface in a row), or at the maximum. Every window also records thread
// starts (who asked for them), image launches, contended kernel-lock
// acquisitions and the surface checks, so `scripts/ycode-frame-profile
// --boot` / `--launch` can walk a critical path across process starts.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import Synchronization
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeHostServices
import YcodeHypervisor

/// One trace event (32 bytes, little-endian on disk in this layout).
struct FrameEvent {
    var time: UInt64
    var arg: UInt64
    var pid: Int32
    var tid: UInt32
    var trap: Int32
    var kind: UInt8
    var threadKind: UInt8
    var pad: UInt16 = 0
}

enum FrameEventKind {
    static let trapEnter: UInt8 = 1
    static let trapExit: UInt8 = 2
    static let block: UInt8 = 3
    static let unblock: UInt8 = 4
    /// pid/tid: the waker (pid 0: a host thread, tid its Linux tid);
    /// arg: the wakee (pid << 32 | guest thread id; 0 for a service waiter).
    static let wake: UInt8 = 5
    /// arg: the frame record's counter; trap: the surface id.
    static let present: UInt8 = 6
    /// pid: the image; arg: ns after the deadline; trap: 0 Mach timer, 1 EVFILT_TIMER.
    static let timerFired: UInt8 = 7
    /// A guest thread start was asked for. pid/tid: the requester (pid 0: a
    /// host thread, tid its Linux tid); arg: the new thread (pid << 32 | guest
    /// thread id); trap: 1 for an image's main thread, else 0.
    static let startRequest: UInt8 = 8
    /// An image was registered (spawn, exec, the root). pid/tid: the
    /// requester (as above); arg: the image's pid << 32 | 1 when it was
    /// launched suspended (a start hold, START_SUSPENDED); trap: the image's
    /// serial (the `.names` file names it).
    static let imageLaunch: UInt8 = 9
    /// A contended kernel-lock acquisition. pid/tid: the waiter (pid 0: a
    /// host thread); arg: ns waited; trap: the lock level (0 L0, 1 an event
    /// lock, 2 the port lock).
    static let lockWait: UInt8 = 10
    /// A check of the presented surface. arg: dark share (per mille, samples
    /// darker than 24) << 32 | mean brightness × 100; trap: the frame counter
    /// (low 32 bits); tid: the surface id.
    static let screenCheck: UInt8 = 11
    /// A vCPU host thread's scheduler counters (every
    /// `YCODE_FRAME_PROFILE_SCHED_MS`). pid: the image; tid: the Linux tid;
    /// arg: run-queue wait ns (cumulative); trap: CPU µs (cumulative, mod 2^32).
    static let schedSample: UInt8 = 12
    /// A guest thread trapped on a host thread other than the one it last
    /// used. pid/tid: the guest thread; arg: the Linux tid.
    static let bind: UInt8 = 13
}

final class FrameProfile: @unchecked Sendable {
    static let shared: FrameProfile? = {
        guard let raw = getenv("YCODE_FRAME_PROFILE"), raw.pointee != 0 else { return nil }
        return FrameProfile(path: String(cString: raw))
    }()

    /// True while a window is open (read on every trap).
    static let active = Atomic<Bool>(false)

    let path: String
    let capacity: Int
    private let events: UnsafeMutablePointer<FrameEvent>
    private let next = Atomic<Int>(0)
    private var windowNumber = 0
    private var statePath: String?
    private weak var launcher: VMMLauncher?
    private weak var surfaces: IOSurfaceHostService?
    /// One window at a time (the boot window, then `.go` windows). A
    /// semaphore: the boot window is taken on the starting thread and given
    /// back by the thread that records it.
    private let windowLock = DispatchSemaphore(value: 1)
    /// Image launches in the current window: (time, pid, serial, program).
    private let launchNames = Mutex<[(UInt64, Int32, Int, String)]>([])
    /// Host threads seen as wakers or requesters: Linux tid → name.
    private let hostNames = Mutex<[UInt32: String]>([:])
    /// When the process started (monotonic ns, from /proc/self/stat).
    private let processStartNs: UInt64 = FrameProfile.processStartMonotonic()

    /// The calling host thread's Linux tid, cached (+1; 0 = not read yet).
    private static let tidKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    @inline(__always) static func hostTID() -> Int32 {
        let cached = UInt(bitPattern: pthread_getspecific(tidKey))
        if cached != 0 { return Int32(truncatingIfNeeded: cached - 1) }
        let tid = Int32(truncatingIfNeeded: ckvmThreadID())
        pthread_setspecific(tidKey, UnsafeRawPointer(bitPattern: UInt(tid) + 1))
        return tid
    }

    /// The calling host thread's guest thread while it handles a trap
    /// (pid << 32 | guest thread id); 0 otherwise.
    private static let currentKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    init(path: String) {
        self.path = path
        capacity = getenv("YCODE_FRAME_PROFILE_EVENTS").flatMap { Int(String(cString: $0)) }.map { max(1024, $0) } ?? (4 << 20)
        events = .allocate(capacity: capacity)
    }

    /// Before the root process is spawned: with `YCODE_FRAME_PROFILE_BOOT`
    /// opens the boot window now (it covers the whole boot).
    func prepareBoot(launcher: VMMLauncher, statePath: String?, surfaces: IOSurfaceHostService?) {
        self.launcher = launcher
        self.statePath = statePath
        self.surfaces = surfaces
        VCPUPool.profiling = true
        _ = Self.currentKey
        guard let raw = getenv("YCODE_FRAME_PROFILE_BOOT"), let seconds = Double(String(cString: raw)), seconds > 0 else { return }
        let tail = getenv("YCODE_FRAME_PROFILE_BOOT_TAIL").flatMap { Double(String(cString: $0)) } ?? 3
        windowLock.wait()  // taken here, so the window is open before the root spawns
        let opened = openWindow(seconds: min(seconds, 900))
        let thread = Thread { [self] in
            runWindow(opened, homeTail: tail)
            windowLock.signal()
        }
        thread.name = "ycode frame profile boot"
        thread.start()
    }

    /// Starts the control poller. Call once the launcher exists.
    func start(launcher: VMMLauncher, statePath: String?) {
        self.launcher = launcher
        self.statePath = statePath
        VCPUPool.profiling = true
        _ = Self.currentKey
        let thread = Thread { [self] in pollControl() }
        thread.name = "ycode frame profile"
        thread.start()
        stderrLine("ycode-simd: frame profile: on (touch \(path).go to record a window)")
    }

    // MARK: Recording

    @inline(__always) private func record(_ e: FrameEvent) {
        let i = next.add(1, ordering: .relaxed).oldValue
        guard i < capacity else { return }
        events[i] = e
    }

    @inline(__always) private static func packed(_ pid: Int32, _ tid: UInt64) -> UInt64 {
        UInt64(UInt32(bitPattern: pid)) << 32 | (tid & 0xFFFF_FFFF)
    }

    /// The thread's id in the trace: its guest thread id (low 24 bits) and
    /// its image's tag (`ThreadContext.traceTag`, high 8 bits).
    @inline(__always) static func traceID(_ c: ThreadContext) -> UInt64 {
        UInt64(c.traceTag & 0xFF) << 24 | (c.threadID & 0xFF_FFFF)
    }

    private static func threadKind(_ c: ThreadContext?) -> UInt8 {
        switch c?.kind {
        case .main?: return 1
        case .pthread?: return 2
        case .workqueue?: return 3
        case nil: return 0
        }
    }

    /// A trap arrives (the VMM's trap handler, before any lock).
    /// arg: for mach_msg2 (−47) the message id (x4 >> 32) << 32 | the low
    /// 32 bits of the options (x1); otherwise x0.
    func trapEnter(pid: Int32, context: ThreadContext, number: Int32, frame: TrapFrame) {
        pthread_setspecific(Self.currentKey, UnsafeRawPointer(bitPattern: UInt(Self.packed(pid, Self.traceID(context)))))
        let host = Self.hostTID()
        if context.traceHostTID != host {
            context.traceHostTID = host
            record(FrameEvent(time: monotonicNanoseconds(), arg: UInt64(UInt32(bitPattern: host)), pid: pid,
                              tid: UInt32(truncatingIfNeeded: Self.traceID(context)), trap: 0, kind: FrameEventKind.bind, threadKind: 0))
        }
        let arg = number == -47 ? (frame.x[4] & 0xFFFF_FFFF_0000_0000) | (frame.x[1] & 0xFFFF_FFFF) : frame.x[0]
        record(FrameEvent(time: monotonicNanoseconds(), arg: arg, pid: pid, tid: UInt32(truncatingIfNeeded: Self.traceID(context)),
                          trap: number, kind: FrameEventKind.trapEnter, threadKind: Self.threadKind(context)))
    }

    /// The trap returns. arg: x0 (bit 63 set when the carry flag reports an error).
    func trapExit(pid: Int32, context: ThreadContext, number: Int32, frame: TrapFrame) {
        pthread_setspecific(Self.currentKey, nil)
        record(FrameEvent(time: monotonicNanoseconds(), arg: frame.carry ? (1 << 63) | frame.x[0] : frame.x[0], pid: pid,
                          tid: UInt32(truncatingIfNeeded: Self.traceID(context)), trap: number, kind: FrameEventKind.trapExit,
                          threadKind: Self.threadKind(context)))
    }

    private func noteWake(_ wakee: ThreadContext?) {
        let me = UInt64(UInt(bitPattern: pthread_getspecific(Self.currentKey)))
        let pid: Int32, tid: UInt32
        if me != 0 {
            pid = Int32(bitPattern: UInt32(me >> 32)); tid = UInt32(truncatingIfNeeded: me)
        } else {
            pid = 0; tid = UInt32(truncatingIfNeeded: ckvmThreadID())
            noteHostThread(tid)
        }
        let target = wakee.map { Self.packed($0.kernel?.pid ?? -1, Self.traceID($0)) } ?? 0
        record(FrameEvent(time: monotonicNanoseconds(), arg: target, pid: pid, tid: tid, trap: 0,
                          kind: FrameEventKind.wake, threadKind: Self.threadKind(wakee)))
    }

    /// The calling thread as a requester: (pid, guest thread id) inside a
    /// trap, else (0, Linux tid).
    private func requester() -> (Int32, UInt32) {
        let me = UInt64(UInt(bitPattern: pthread_getspecific(Self.currentKey)))
        if me != 0 { return (Int32(bitPattern: UInt32(me >> 32)), UInt32(truncatingIfNeeded: me)) }
        let tid = UInt32(truncatingIfNeeded: ckvmThreadID())
        noteHostThread(tid)
        return (0, tid)
    }

    /// Names a host thread the first time it shows up (its name now: a
    /// service thread may end before the window closes).
    private func noteHostThread(_ tid: UInt32) {
        if hostNames.withLock({ $0[tid] != nil }) { return }
        let comm = Self.readSmall("/proc/self/task/\(tid)/comm")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        hostNames.withLock { $0[tid] = comm }
    }

    /// A guest thread start was asked for (ImageLauncher: the main thread of
    /// an image, `startThread` for pthreads and workqueue threads).
    func startRequested(pid: Int32, context: ThreadContext, mainThread: Bool, serial: Int = 0) {
        let (rp, rt) = requester()
        // A main thread tags its image (serial, low 8 bits; never 0 in a
        // window); other threads take their main thread's tag.
        context.traceTag = mainThread ? UInt32(truncatingIfNeeded: serial) & 0xFF | (serial & 0xFF == 0 ? 1 : 0)
            : context.kernel?.mainThread.traceTag ?? 0
        record(FrameEvent(time: monotonicNanoseconds(), arg: Self.packed(pid, Self.traceID(context)), pid: rp, tid: rt,
                          trap: mainThread ? 1 : 0, kind: FrameEventKind.startRequest, threadKind: Self.threadKind(context)))
    }

    /// An image was registered (before its main thread is started).
    func imageLaunched(pid: Int32, serial: Int, executable: String, suspended: Bool) {
        let (rp, rt) = requester()
        let now = monotonicNanoseconds()
        launchNames.withLock { $0.append((now, pid, serial, (executable as NSString).lastPathComponent)) }
        record(FrameEvent(time: now, arg: UInt64(UInt32(bitPattern: pid)) << 32 | (suspended ? 1 : 0), pid: rp, tid: rt,
                          trap: Int32(truncatingIfNeeded: serial), kind: FrameEventKind.imageLaunch, threadKind: 0))
    }

    /// A contended kernel-lock acquisition (KernelTrace.lockWaited).
    private func noteLockWait(level: Int32, waited: UInt64) {
        let (rp, rt) = requester()
        record(FrameEvent(time: monotonicNanoseconds(), arg: waited, pid: rp, tid: rt, trap: level,
                          kind: FrameEventKind.lockWait, threadKind: 0))
    }

    private func noteBlocking(_ context: ThreadContext, _ sleeping: Bool) {
        record(FrameEvent(time: monotonicNanoseconds(), arg: 0, pid: context.kernel?.pid ?? -1,
                          tid: UInt32(truncatingIfNeeded: Self.traceID(context)), trap: 0,
                          kind: sleeping ? FrameEventKind.block : FrameEventKind.unblock, threadKind: Self.threadKind(context)))
    }

    /// The process's start (field 22 of /proc/self/stat, clock ticks since
    /// boot) as CLOCK_MONOTONIC ns (CLOCK_BOOTTIME minus the time since the
    /// start; the two clocks differ only by suspend time).
    static func processStartMonotonic() -> UInt64 {
        guard let stat = readSmall("/proc/self/stat"), let close = stat.lastIndex(of: ")") else { return monotonicNanoseconds() }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        // fields[0] is field 3 (the state), so field 22 is fields[19].
        guard fields.count > 19, let ticks = UInt64(fields[19]) else { return monotonicNanoseconds() }
        var bt = timespec()
        clock_gettime(CLOCK_BOOTTIME, &bt)
        let mono = monotonicNanoseconds()
        let boot = UInt64(bt.tv_sec) * 1_000_000_000 + UInt64(bt.tv_nsec)
        let startBoot = ticks * 1_000_000_000 / max(1, hostClockTicks)
        return mono &- (boot &- min(boot, startBoot))
    }

    // MARK: Windows

    private struct ImageCounters {
        var name = ""
        var userTicks: UInt64 = 0, systemTicks: UInt64 = 0, guestTicks: UInt64 = 0
        var minorFaults: UInt64 = 0, cpuNs: UInt64 = 0, runQueueNs: UInt64 = 0, timeslices: UInt64 = 0
        var voluntary: UInt64 = 0, involuntary: UInt64 = 0
        var runNs: UInt64 = 0, handlerNs: UInt64 = 0, exits: UInt64 = 0, threads = 0
    }

    /// Per-pid counters of the live images now (sums over their vCPU threads).
    private func imageCounters() -> [Int32: ImageCounters] {
        var out: [Int32: ImageCounters] = [:]
        guard let launcher else { return out }
        for image in launcher.snapshotLiveImages {
            var c = ImageCounters()
            c.name = (image.record.executable as NSString).lastPathComponent
            for w in image.pool.snapshotWorkers.workers {
                let tid = Int(w.hostTID.load(ordering: .relaxed))
                guard tid != 0 else { continue }
                c.threads += 1
                c.runNs &+= w.runNanoseconds
                c.handlerNs &+= w.handlerNanoseconds
                c.exits &+= UInt64(w.vcpu.exitCount)
                if let s = hostTaskStats(tid) {
                    c.userTicks &+= s[0]; c.systemTicks &+= s[1]; c.guestTicks &+= s[2]
                    c.minorFaults &+= s[3]; c.cpuNs &+= s[5]; c.runQueueNs &+= s[6]
                }
                c.timeslices &+= Self.schedTimeslices(tid)
                let (v, n) = Self.contextSwitches(tid)
                c.voluntary &+= v; c.involuntary &+= n
            }
            out[image.pid] = c
        }
        return out
    }

    private static func readSmall(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 2047) }
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : nil
    }

    /// The third schedstat field: timeslices run (≈ times scheduled in).
    private static func schedTimeslices(_ tid: Int) -> UInt64 {
        guard let s = readSmall("/proc/self/task/\(tid)/schedstat") else { return 0 }
        let f = s.split(separator: " ")
        return f.count >= 3 ? UInt64(f[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
    }

    private static func contextSwitches(_ tid: Int) -> (UInt64, UInt64) {
        guard let s = readSmall("/proc/self/task/\(tid)/status") else { return (0, 0) }
        var v: UInt64 = 0, n: UInt64 = 0
        for line in s.split(separator: "\n") {
            if line.hasPrefix("voluntary_ctxt_switches:") { v = UInt64(line.split(separator: "\t").last ?? "") ?? 0 }
            if line.hasPrefix("nonvoluntary_ctxt_switches:") { n = UInt64(line.split(separator: "\t").last ?? "") ?? 0 }
        }
        return (v, n)
    }

    /// The trap profile's three tables (empty without `YCODE_TRAP_PROFILE`).
    private static func lockTables() -> [[Int64: TrapProfile.Row]] {
        [TrapProfile.shared, TrapProfile.eventLocks, TrapProfile.portLock].map { $0?.snapshotRows() ?? [:] }
    }

    /// Per trap number over the window: traps, acquisitions, hold and wait
    /// (ms, and per present), contended share; the 25 rows with the most wait + hold.
    private static func lockDiff(_ name: String, _ a: [Int64: TrapProfile.Row], _ b: [Int64: TrapProfile.Row],
                                 presents: Int) -> String {
        var rows: [(Int64, TrapProfile.Row)] = []
        for (k, r) in b {
            let o = a[k] ?? TrapProfile.Row()
            var d = TrapProfile.Row()
            d.count = r.count &- o.count; d.acquisitions = r.acquisitions &- o.acquisitions
            d.holdNanoseconds = r.holdNanoseconds &- o.holdNanoseconds; d.waitNanoseconds = r.waitNanoseconds &- o.waitNanoseconds
            d.waits = r.waits &- o.waits; d.contended = r.contended &- o.contended
            // swiftlint:disable:next empty_count - a counter, not a collection
            if d.acquisitions > 0 || d.count > 0 { rows.append((k, d)) }
        }
        rows.sort { $0.1.holdNanoseconds &+ $0.1.waitNanoseconds > $1.1.holdNanoseconds &+ $1.1.waitNanoseconds }
        let held = rows.reduce(UInt64(0)) { $0 &+ $1.1.holdNanoseconds }
        let n = Double(max(1, presents))
        var out = "\n# \(name) over the window: held \(String(format: "%.1f", Double(held) / 1e6)) ms\n"
            + "trap,traps,acquisitions,hold_ms,wait_ms,hold_ms_per_present,wait_ms_per_present,contended_pct,wait_us_per_acq\n"
        for (k, d) in rows.prefix(25) {
            let key = k == Int64.min ? "service" : k == Int64.min + 1 ? "other" : String(k)
            out += "\(key),\(d.count),\(d.acquisitions),"
                + String(format: "%.1f,%.1f,%.2f,%.2f,%.0f,%.0f", Double(d.holdNanoseconds) / 1e6, Double(d.waitNanoseconds) / 1e6,
                         Double(d.holdNanoseconds) / 1e6 / n, Double(d.waitNanoseconds) / 1e6 / n,
                         100 * Double(d.contended) / Double(max(1, d.waits)), Double(d.waitNanoseconds) / 1e3 / Double(max(1, d.waits))) + "\n"
        }
        return out
    }

    private func pollControl() {
        let go = path + ".go"
        while true {
            usleep(100_000)
            guard access(go, F_OK) == 0 else { continue }
            let seconds = (try? String(contentsOfFile: go, encoding: .utf8)).flatMap {
                Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? 10
            unlink(go)
            windowLock.wait()
            runWindow(openWindow(seconds: max(0.5, min(seconds, 120))), homeTail: nil)
            windowLock.signal()
        }
    }

    /// A window just opened: its number, counters at the start, length.
    private struct OpenWindow {
        var number: Int
        var before: [Int32: ImageCounters]
        var locks0: [[Int64: TrapProfile.Row]]
        var load0: String
        var startNs: UInt64
        var seconds: Double
    }

    private func openWindow(seconds: Double) -> OpenWindow {
        windowNumber += 1
        let n = windowNumber
        let before = imageCounters()
        let locks0 = Self.lockTables()
        let load0 = Self.readSmall("/proc/loadavg")?.split(separator: " ").prefix(3).joined(separator: " ") ?? "?"
        next.store(0, ordering: .relaxed)
        launchNames.withLock { $0.removeAll() }
        KernelTrace.wake = { [unowned self] in noteWake($0) }
        KernelTrace.blocking = { [unowned self] in noteBlocking($0, $1) }
        KernelTrace.timerFired = { [unowned self] pid, late, kind in
            record(FrameEvent(time: monotonicNanoseconds(), arg: late, pid: pid, tid: UInt32(truncatingIfNeeded: ckvmThreadID()), trap: kind,
                              kind: FrameEventKind.timerFired, threadKind: 0))
        }
        KernelTrace.lockWaited = { [unowned self] level, waited in noteLockWait(level: level, waited: waited) }
        let startNs = monotonicNanoseconds()
        Self.active.store(true, ordering: .releasing)
        stderrLine("ycode-simd: frame profile: window \(n) open for \(seconds) s")
        startSchedSampler()
        return OpenWindow(number: n, before: before, locks0: locks0, load0: load0, startNs: startNs, seconds: seconds)
    }

    /// While a window is open: every `YCODE_FRAME_PROFILE_SCHED_MS` (default
    /// 200; 0 = off) the CPU and run-queue counters of every vCPU host thread
    /// of every live image (the analysis splits guest-code time into guest
    /// CPU and waiting for a host CPU).
    private func startSchedSampler() {
        let ms = getenv("YCODE_FRAME_PROFILE_SCHED_MS").flatMap { UInt32(String(cString: $0)) } ?? 200
        guard ms > 0 else { return }
        let thread = Thread { [self] in
            while Self.active.load(ordering: .acquiring) {
                guard let launcher else { break }
                for image in launcher.snapshotLiveImages {
                    for tid in image.pool.hostThreadIDs {
                        guard let st = hostTaskStats(tid) else { continue }
                        record(FrameEvent(time: monotonicNanoseconds(), arg: st[6], pid: image.pid, tid: UInt32(truncatingIfNeeded: tid),
                                          trap: Int32(truncatingIfNeeded: st[5] / 1000), kind: FrameEventKind.schedSample, threadKind: 0))
                    }
                }
                usleep(ms * 1000)
            }
        }
        thread.name = "ycode frame profile sched"
        thread.start()
    }

    /// The presented surface: share of 70 × 102 point samples darker than 24
    /// (per mille) and the mean brightness × 100 (the launcher's home-screen
    /// test, ycode-sim.sh: lit when fewer than 900 ‰ are dark). Nil when the
    /// surface is not readable.
    private func checkSurface(_ id: UInt32) -> (dark: UInt64, mean: UInt64)? {
        guard let surfaces else { return nil }
        return Self.checkSurface(id, surfaces: surfaces)
    }

    static func checkSurface(_ id: UInt32, surfaces: IOSurfaceHostService) -> (dark: UInt64, mean: UInt64)? {
        guard let s = surfaces.surface(id: id), s.bytesPerElement == 4, s.width > 0, s.height > 0,
              s.bytesPerRow >= s.width * 4, UInt64(s.bytesPerRow * s.height) <= s.memory.size else { return nil }
        let base = s.memory.host.assumingMemoryBound(to: UInt8.self)
        var dark = 0, sum = 0
        let cols = 70, rows = 102
        for r in 0..<rows {
            let y = (2 * r + 1) * s.height / (2 * rows)
            for c in 0..<cols {
                let x = (2 * c + 1) * s.width / (2 * cols)
                let p = base + y * s.bytesPerRow + x * 4  // BGRA
                let l = (299 * Int(p[2]) + 587 * Int(p[1]) + 114 * Int(p[0])) / 1000
                sum += l
                if l < 24 { dark += 1 }
            }
        }
        let n = cols * rows
        return (UInt64(dark * 1000 / n), UInt64(sum * 100 / n))
    }

    private func runWindow(_ w: OpenWindow, homeTail: Double?) {
        let n = w.number, before = w.before, locks0 = w.locks0, load0 = w.load0, startNs = w.startNs, seconds = w.seconds
        // Presents: the frame record, every 1 ms. A new present is checked
        // at most every 50 ms (and at once after a lit check, until the home
        // screen is seen): the analysis finds the home screen by it.
        let reader = statePath.map { FrameRecordReader(path: $0) }
        var last = reader?.read()
        var presents = 0
        var endNs = startNs &+ UInt64(seconds * 1e9)
        var lastCheck: UInt64 = 0
        var litChecks = 0
        var homeNs: UInt64 = 0, firstLitNs: UInt64 = 0
        while monotonicNanoseconds() < endNs {
            usleep(1000)
            guard let r = reader?.read(), r != last else { continue }
            last = r
            presents += 1
            let now = monotonicNanoseconds()
            record(FrameEvent(time: now, arg: r.frame, pid: 0, tid: 0, trap: Int32(bitPattern: r.surface),
                              kind: FrameEventKind.present, threadKind: 0))
            guard surfaces != nil, now &- lastCheck >= 50_000_000 || (homeNs == 0 && litChecks == 1) else { continue }
            lastCheck = now
            guard let c = checkSurface(r.surface) else { continue }
            record(FrameEvent(time: monotonicNanoseconds(), arg: c.dark << 32 | c.mean, pid: 0, tid: r.surface,
                              trap: Int32(truncatingIfNeeded: r.frame), kind: FrameEventKind.screenCheck, threadKind: 0))
            litChecks = c.dark < 900 ? litChecks + 1 : 0
            if litChecks == 1 { firstLitNs = now }
            if homeNs == 0, litChecks >= 2 {
                homeNs = firstLitNs
                stderrLine("ycode-simd: frame profile: home screen seen \(String(format: "%.2f", Double(homeNs &- min(homeNs, processStartNs)) / 1e9)) s "
                    + "after ycode-simd started (window \(n))")
                if let homeTail { endNs = min(endNs, now &+ UInt64(homeTail * 1e9)) }
            }
        }
        Self.active.store(false, ordering: .releasing)
        KernelTrace.wake = nil
        KernelTrace.blocking = nil
        KernelTrace.timerFired = nil
        KernelTrace.lockWaited = nil
        let stopNs = monotonicNanoseconds()
        // Let in-flight recorders finish their store.
        usleep(20_000)
        let after = imageCounters()
        let locks1 = Self.lockTables()
        let count = min(next.load(ordering: .relaxed), capacity)
        let full = next.load(ordering: .relaxed) > capacity

        let base = "\(path).\(n)"
        if let f = fopen(base + ".trace", "w") {
            fwrite(events, MemoryLayout<FrameEvent>.stride, count, f)
            fclose(f)
        }
        var names = "# pid program\n"
        for (pid, c) in after.sorted(by: { $0.key < $1.key }) { names += "\(pid) \(c.name)\n" }
        for (pid, c) in before where after[pid] == nil { names += "\(pid) \(c.name)\n" }
        // Host threads that woke guest threads (services, timers): their names.
        var hostTIDs = Set<UInt32>()
        var timerTIDs = Set<UInt32>()
        for i in 0..<count {
            if events[i].kind == FrameEventKind.wake && events[i].pid == 0 { hostTIDs.insert(events[i].tid) }
            if events[i].kind == FrameEventKind.timerFired { timerTIDs.insert(events[i].tid) }
        }
        let known = hostNames.withLock { $0 }
        for tid in known.keys { hostTIDs.insert(tid) }
        for tid in hostTIDs.sorted() {
            // A thread that fired timers is a kernel timer thread (its name is the process's).
            let comm = timerTIDs.contains(tid) ? "kernel-timers"
                : known[tid] ?? Self.readSmall("/proc/self/task/\(tid)/comm")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            names += "host \(tid) \(comm)\n"
        }
        // Every image launched in the window (pid, serial, time, program):
        // an exec gives a pid a new program.
        for (t, pid, serial, program) in launchNames.withLock({ $0 }) {
            names += "image \(pid) \(serial) \(t) \(program)\n"
        }
        names += "start \(startNs) \(processStartNs) \(homeNs)\n"
        try? names.write(toFile: base + ".names", atomically: true, encoding: .utf8)

        let wall = Double(stopNs &- startNs) / 1e9
        let ticks = Double(hostClockTicks)
        let load1 = Self.readSmall("/proc/loadavg")?.split(separator: " ").prefix(3).joined(separator: " ") ?? "?"
        var out = "# frame profile window \(n): \(String(format: "%.3f", wall)) s, \(presents) presents"
            + " (\(String(format: "%.1f", Double(presents) / wall)) /s), \(count) events\(full ? " (FULL: raise YCODE_FRAME_PROFILE_EVENTS)" : "")"
            + ", host load \(load0) -> \(load1)"
            + ", opened \(String(format: "%.3f", Double(startNs &- min(startNs, processStartNs)) / 1e9)) s after ycode-simd started"
            + (homeNs != 0 ? ", home screen at \(String(format: "%.3f", Double(homeNs &- min(homeNs, processStartNs)) / 1e9)) s" : "") + "\n"
        if let arena = SharedObjectArena.shared { out += "# \(arena.recycleSummary) (since start)\n" }
        out += "# BSD fast paths: \(DarwinKernel.bsdFastServed.load(ordering: .relaxed)) served, "
            + "\(DarwinKernel.bsdFastDeclined.load(ordering: .relaxed)) declined; proc_info dirty control without L0: "
            + "\(DarwinKernel.dirtyControlFast.load(ordering: .relaxed)) (since start)\n"
        out += "# per program over the window (cores = seconds per second of wall time; ms_per_present = ms of that per present)\n"
        out += "pid,program,threads,cpu_cores,guest_cores,hostsys_cores,vmm_cores,runqueue_cores,kvm_run_cores,handler_cores,"
            + "exits,timeslices,vol_switches,invol_switches,minflt,cpu_ms_per_present,runqueue_ms_per_present\n"
        var rows: [(Int32, ImageCounters, ImageCounters)] = []
        for (pid, a) in after { rows.append((pid, a, before[pid] ?? ImageCounters())) }
        rows.sort { ($0.1.cpuNs &- $0.2.cpuNs) > ($1.1.cpuNs &- $1.2.cpuNs) }
        for (pid, a, b) in rows {
            let cpu = Double(a.cpuNs &- min(a.cpuNs, b.cpuNs)) / 1e9
            let guest = Double(a.guestTicks &- min(a.guestTicks, b.guestTicks)) / ticks
            let sys = Double(a.systemTicks &- min(a.systemTicks, b.systemTicks)) / ticks
            let user = Double(a.userTicks &- min(a.userTicks, b.userTicks)) / ticks
            let rq = Double(a.runQueueNs &- min(a.runQueueNs, b.runQueueNs)) / 1e9
            guard cpu > 0 || rq > 0 else { continue }
            let perPresent = presents > 0 ? 1000 / Double(presents) : 0
            out += "\(pid),\(a.name),\(a.threads)," + [cpu, guest, sys, max(0, user - guest), rq,
                Double(a.runNs &- min(a.runNs, b.runNs)) / 1e9, Double(a.handlerNs &- min(a.handlerNs, b.handlerNs)) / 1e9]
                .map { String(format: "%.3f", $0 / wall) }.joined(separator: ",")
                + ",\(a.exits &- min(a.exits, b.exits)),\(a.timeslices &- min(a.timeslices, b.timeslices)),"
                + "\(a.voluntary &- min(a.voluntary, b.voluntary)),\(a.involuntary &- min(a.involuntary, b.involuntary)),"
                + "\(a.minorFaults &- min(a.minorFaults, b.minorFaults)),"
                + String(format: "%.2f,%.2f", cpu * perPresent, rq * perPresent) + "\n"
        }
        for (i, name) in ["kernel lock L0", "event locks L_P", "port lock G"].enumerated() where !locks1[i].isEmpty {
            out += Self.lockDiff(name, locks0[i], locks1[i], presents: presents)
        }
        try? out.write(toFile: base + ".summary", atomically: true, encoding: .utf8)
        stderrLine("ycode-simd: frame profile: window \(n) closed: \(presents) presents in \(String(format: "%.2f", wall)) s, "
            + "\(count) events\(full ? " (event array full)" : ""); \(base).{trace,names,summary}")
    }
}

/// `YCODE_HOME_WATCH=1` (diagnostics, boot-profile.md §8): watches the
/// frame record from before the root spawn and logs when the home screen is
/// first seen (two lit checks of the presented surface in a row, as the
/// frame profile's boot window), to the nearest ~50 ms, without recording
/// anything else: the timing instrument for A/B boots.
enum HomeWatch {
    /// Counters logged with the home line (set by the host before the boot).
    nonisolated(unsafe) static var atHome: (() -> String)?
    static func startIfRequested(statePath: String?, surfaces: IOSurfaceHostService?) {
        guard getenv("YCODE_HOME_WATCH").map({ String(cString: $0) == "1" }) ?? false,
              let statePath, let surfaces else { return }
        let processStart = FrameProfile.processStartMonotonic()
        let thread = Thread {
            let reader = FrameRecordReader(path: statePath)
            var last = reader.read()
            var lit = 0, firstLit: UInt64 = 0, lastCheck: UInt64 = 0
            let deadline = monotonicNanoseconds() &+ 1_800_000_000_000
            while monotonicNanoseconds() < deadline {
                usleep(1000)
                guard let r = reader.read(), r != last else { continue }
                last = r
                let now = monotonicNanoseconds()
                guard now &- lastCheck >= 50_000_000 || lit == 1 else { continue }
                lastCheck = now
                guard let c = FrameProfile.checkSurface(r.surface, surfaces: surfaces) else { continue }
                if c.dark < 900 {
                    lit += 1
                    if lit == 1 { firstLit = now }
                } else {
                    lit = 0
                }
                if lit >= 2 {
                    stderrLine("ycode-simd: home watch: home screen seen \(String(format: "%.2f", Double(firstLit &- min(firstLit, processStart)) / 1e9)) s "
                        + "after ycode-simd started (frame \(r.frame), dark \(c.dark) per mille, mean \(Double(c.mean) / 100))")
                    if let atHome { stderrLine("ycode-simd: home watch: at home: " + atHome()) }
                    return
                }
            }
        }
        thread.name = "ycode home watch"
        thread.start()
    }
}
#endif
