import Foundation
import Synchronization
import YcodeDarwinABI

// Scheduling policy: launchd process types, darwin-bg, importance boosts,
// the start hold of unboosted background jobs, per-thread effective QoS, and
// the scheduling class that the kernel lock's admission and the host
// mapping use (`specs/simulator/scheduling-policy.md`). Every mutable member
// is changed with the kernel lock held, except `ThreadContext.schedClass`,
// which is an atomic that the lock reads before it is taken.

/// The switches (`scheduling-policy.md` §6). Read from the environment once;
/// tests set them directly.
public enum SchedPolicy {
    static func env(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
    static func flag(_ name: String, _ fallback: Bool) -> Bool {
        guard let v = env(name) else { return fallback }
        return v == "1" || v == "yes" || v == "on"
    }
    static func number(_ name: String, _ fallback: Double) -> Double {
        env(name).flatMap(Double.init) ?? fallback
    }

    /// `YCODE_ADAPTIVE_HOLD`: hold the start of unboosted Adaptive and
    /// Background jobs (§4.2). On by default (§7: better service fidelity,
    /// no slower boot); `YCODE_ADAPTIVE_HOLD=0` turns it off.
    nonisolated(unsafe) public static var holdEnabled = flag("YCODE_ADAPTIVE_HOLD", true)
    /// `YCODE_SCHED_QOS`: per-thread effective QoS, the class-aware kernel
    /// lock admission, inheritance, and (with `YCODE_HOST_SCHED`) the host
    /// mapping (§4.4–§4.7).
    nonisolated(unsafe) public static var qosEnabled = flag("YCODE_SCHED_QOS", false)
    /// `YCODE_LOCK_ADMISSION=1` (with `qosEnabled`): the admission gate of
    /// §4.5. Off by default: measured to stall the boot (§7).
    nonisolated(unsafe) public static var admissionEnabled = flag("YCODE_LOCK_ADMISSION", false)
    /// Importance bookkeeping runs when either switch is on.
    public static var importanceEnabled: Bool { holdEnabled || qosEnabled }

    /// `YCODE_ADAPTIVE_HOLD_DEMAND` (default on): a job whose watch ports
    /// already hold a message at its spawn (an on-demand start: a client
    /// sent to it and waits) is not held, even when the message carries no
    /// importance; `=0` holds it until a boost, quiet or the bound.
    nonisolated(unsafe) public static var holdSkipsDemand = flag("YCODE_ADAPTIVE_HOLD_DEMAND", true)
    /// `YCODE_ADAPTIVE_HOLD_MAX_S` (default 300): the longest start hold.
    nonisolated(unsafe) public static var holdMaxNanoseconds = UInt64(number("YCODE_ADAPTIVE_HOLD_MAX_S", 300) * 1e9)
    /// `YCODE_ADAPTIVE_HOLD_QUIET_MS` (default 250): the system is quiet when
    /// no thread of class ≥ default waited for the kernel lock this long …
    nonisolated(unsafe) public static var holdQuietNanoseconds = UInt64(number("YCODE_ADAPTIVE_HOLD_QUIET_MS", 250) * 1e6)
    /// … and the kernel lock was busy less than `YCODE_ADAPTIVE_HOLD_BUSY_PERCENT`
    /// (default 25) of the last `YCODE_ADAPTIVE_HOLD_WINDOW_MS` (default 2000).
    nonisolated(unsafe) public static var holdBusyFraction = number("YCODE_ADAPTIVE_HOLD_BUSY_PERCENT", 25) / 100
    nonisolated(unsafe) public static var holdWindowNanoseconds = UInt64(number("YCODE_ADAPTIVE_HOLD_WINDOW_MS", 2000) * 1e6)
    /// `YCODE_ADAPTIVE_HOLD_TRACE=1`: one line per second with the quiet inputs.
    nonisolated(unsafe) public static var holdTrace = flag("YCODE_ADAPTIVE_HOLD_TRACE", false)
    /// `YCODE_LOCK_ADMISSION_BOUND_MS="bg,ut,df"` (default "250,150,75"): the
    /// longest a thread of class 0, 1, 2 yields to higher classes before it
    /// competes anyway (the anti-starvation bound).
    nonisolated(unsafe) public static var admissionBoundNanoseconds: [UInt64] = {
        let parts = env("YCODE_LOCK_ADMISSION_BOUND_MS")?.split(separator: ",").compactMap { Double($0) } ?? []
        let defaults: [Double] = [250, 150, 75]
        return (0..<3).map { UInt64((($0 < parts.count) ? parts[$0] : defaults[$0]) * 1e6) }
    }()

    /// True when the lock gate is active.
    static var gateActive: Bool { qosEnabled && admissionEnabled }
}

/// Ycode's scheduling classes (§4.4): what the kernel lock and the host see.
public enum SchedClass {
    public static let background = 0
    public static let utility = 1
    public static let `default` = 2
    public static let interactive = 3
    public static let count = 4

    /// The class of a thread QoS (`threads-and-events.md` §2.4 numbering):
    /// unspecified and legacy → default; maintenance, background →
    /// background; utility → utility; user-initiated, user-interactive (and
    /// above) → interactive.
    public static func of(qos: Int) -> Int {
        switch qos {
        case 1, 2: background
        case 3: utility
        case 5...: interactive
        default: `default`
        }
    }

    public static func name(_ c: Int) -> String {
        ["bg", "ut", "df", "ui"][max(0, min(3, c))]
    }
}

/// `psa_apptype & 0xF00` (`processes.md` §1.6).
public enum ProcessTypeCode {
    public static let appDefault: UInt32 = 0x100
    public static let appNonUI: UInt32 = 0x200
    public static let daemonStandard: UInt32 = 0x300
    public static let daemonInteractive: UInt32 = 0x400
    public static let daemonBackground: UInt32 = 0x500
    public static let daemonAdaptive: UInt32 = 0x600

    /// The main thread's QoS at start (§2.2).
    public static func primordialQoS(_ apptype: UInt32) -> Int {
        switch apptype & 0xF00 {
        case appDefault: 6
        case appNonUI, daemonStandard, daemonInteractive, daemonAdaptive, 0x700: 4
        case daemonBackground: 2
        default: 0
        }
    }

    public static func name(_ apptype: UInt32) -> String {
        switch apptype & 0xF00 {
        case appDefault: "App"
        case appNonUI: "AppNonUI"
        case daemonStandard: "Standard"
        case daemonInteractive: "Interactive"
        case daemonBackground: "Background"
        case daemonAdaptive: "Adaptive"
        case 0: "none"
        default: hx(apptype)
        }
    }
}

/// `setpriority` values (`sys/resource.h`).
enum DarwinPriority {
    static let prioDarwinThread: Int32 = 3
    static let prioDarwinProcess: Int32 = 4
    static let prioDarwinBG: Int32 = 0x1000
}

// MARK: - Process policy

extension DarwinProcess {
    var typeCode: UInt32 { processType & 0xF00 }

    /// Adaptive daemons receive importance (§2.3).
    var isImportanceReceiver: Bool { typeCode == ProcessTypeCode.daemonAdaptive }

    /// Messages from this process carry importance (§2.3): apps, standard
    /// and interactive daemons, processes with no type; a boosted adaptive
    /// daemon passes its boost on; background daemons never donate.
    var isImportanceDonor: Bool {
        switch typeCode {
        case ProcessTypeCode.daemonBackground: false
        case ProcessTypeCode.daemonAdaptive: importanceBoosts > 0
        default: !isDarwinBG
        }
    }

    /// darwin-bg (§2.2): an unboosted adaptive daemon, a background daemon,
    /// a background or maintenance QoS clamp, the darwin-bg role, or
    /// `setpriority(PRIO_DARWIN_PROCESS, PRIO_DARWIN_BG)`.
    var isDarwinBG: Bool {
        if typeCode == ProcessTypeCode.daemonBackground { return true }
        if typeCode == ProcessTypeCode.daemonAdaptive && importanceBoosts == 0 { return true }
        return qosClamp >= 2 || darwinRole == 6 || requestedDarwinBG
    }

    /// The QoS ceiling of the clamp (0 = none): utility 3, background 2,
    /// maintenance 1.
    var clampQoS: Int {
        switch qosClamp {
        case 1: 3
        case 2: 2
        case 3: 1
        default: 0
        }
    }

    /// Adds `delta` importance assertions. Lock held.
    func changeImportance(_ delta: Int, reason: StaticString = "") {
        guard delta != 0 else { return }
        let wasBG = isDarwinBG
        importanceBoosts = max(0, importanceBoosts + delta)
        let release = importanceBoosts > 0 && holdActive.load(ordering: .acquiring)
        let flipped = wasBG != isDarwinBG
        guard release || flipped, let k = kernel else { return }
        // The count changes at once (under G on a fast path); the hold and
        // the classes are process state, done under L0 (`mach-ipc-locking.md` §4.5).
        k.lock.deferIfFast(.kernelLock(k.lock)) { [weak self] in
            guard let self, let k = self.kernel else { return }
            if self.importanceBoosts > 0, self.holdStart != nil { k.system.releaseStartHold(self, reason: "boost") }
            if flipped { k.refreshSchedClasses() }
        }
    }
}

// MARK: - Threads

extension ThreadContext {
    /// The class the kernel lock and the host mapping use (§4.4).
    public var schedClass: Int { schedClassStore.load(ordering: .relaxed) }

    /// The QoS the thread asked for or was given (§4.4 step 1).
    var baseQoS: Int {
        if let w = worker, requestedQoS == 0 { return w.qos >= 7 ? 4 : w.qos }
        return requestedQoS
    }

    /// The highest override (explicit, dispatch).
    var overrideQoS: Int {
        max(dispatchOverrideQoS, maxExplicitOverride)
    }

    /// The highest inheritance push (ulock owner, sync IPC), as a class; −1 none.
    var pushClass: Int {
        max(ipcPushClass, ulockPushes.values.max() ?? -1)
    }
}

/// The pure class computation of §4.4 (tested directly).
public struct SchedInputs: Equatable, Sendable {
    public var baseQoS: Int
    public var overrideQoS: Int = 0
    public var clampQoS: Int = 0
    public var darwinBG: Bool = false
    public var push: Int = -1

    public init(baseQoS: Int, overrideQoS: Int = 0, clampQoS: Int = 0, darwinBG: Bool = false, push: Int = -1) {
        self.baseQoS = baseQoS
        self.overrideQoS = overrideQoS
        self.clampQoS = clampQoS
        self.darwinBG = darwinBG
        self.push = push
    }

    public var schedClass: Int {
        var q = max(baseQoS, overrideQoS)
        if clampQoS > 0 { q = min(q == 0 ? 4 : q, clampQoS) }
        var c = SchedClass.of(qos: q)
        if darwinBG { c = SchedClass.background }
        return max(c, push)
    }
}

extension DarwinKernel {
    /// Recomputes `t`'s class from its inputs. Lock held.
    func refreshSchedClass(_ t: ThreadContext) {
        guard SchedPolicy.qosEnabled else { return }
        // Process and thread inputs are L0 state (`mach-ipc-locking.md` §4.5).
        if lock.callerIsFast {
            lock.deferIfFast(.kernelLock(lock)) { [weak self] in self?.refreshSchedClass(t) }
            return
        }
        let p = schedProcess
        let inputs = SchedInputs(baseQoS: t.baseQoS, overrideQoS: t.overrideQoS, clampQoS: p?.clampQoS ?? 0,
                                 darwinBG: (p?.isDarwinBG ?? false) || t.threadDarwinBG, push: t.pushClass)
        let c = inputs.schedClass
        if t.schedClassStore.exchange(c, ordering: .relaxed) != c {
            system.schedStats.classChanges &+= 1
        }
    }

    /// Recomputes every live thread of this image. Lock held.
    func refreshSchedClasses() {
        guard SchedPolicy.qosEnabled else { return }
        for t in threadsByPort.values { refreshSchedClass(t) }
        refreshSchedClass(mainThread)
    }

    /// The process record of this image (cached; lock held).
    var schedProcess: DarwinProcess? {
        if let p = schedProcessCache, p.kernel === self { return p }
        // The process table is L0 state: without the kernel mutex (the port
        // lock's importance code on a fast path) only the cache is used.
        if eventLock != nil, !lock.isHeldByCurrentThread { return nil }
        let p = system.record(of: self)
        schedProcessCache = p
        return p
    }

    /// Sets the policy of a new image from its spawn attributes (§4.1).
    /// Lock held.
    func applySpawnPolicy(_ attributes: SpawnAttributes, record: DarwinProcess, isExec: Bool) {
        if !isExec || attributes.apptype & 0xF00 != 0 {
            record.processType = attributes.apptype
            record.qosClamp = Int(attributes.qosClamp)
            record.darwinRole = attributes.darwinRole
        }
        schedProcessCache = record
        mainThread.requestedQoS = ProcessTypeCode.primordialQoS(record.processType)
        refreshSchedClass(mainThread)
    }

    /// The end of a servicing episode (§4.3, §4.6): the thread starts its
    /// next receive or returns to the workqueue. Drops the importance it
    /// carried and its sync-IPC push. Lock held.
    func endServicing(_ t: ThreadContext) {
        if let p = t.carriedImportance {
            t.carriedImportance = nil
            p.changeImportance(-1)
        }
        if t.ipcPushClass >= 0 {
            t.ipcPushClass = -1
            refreshSchedClass(t)
        }
    }

    // MARK: ulock inheritance (§4.6)

    /// Pushes the waiters' highest class onto the owner of an unfair lock,
    /// and removes the push from a former owner. Lock held.
    func refreshULockPush(addr: UInt64, queue: ULockQueue) {
        guard SchedPolicy.qosEnabled else { return }
        let waiters = queue.waiters.waitingContexts
        let target = waiters.isEmpty ? nil : queue.owner
        if let old = queue.pushedOwner, old !== target {
            old.ulockPushes[addr] = nil
            old.kernel?.refreshSchedClass(old)
            queue.pushedOwner = nil
        }
        guard let target, target.isAlive else { return }
        let push = waiters.map(\.schedClass).max() ?? -1
        if target.ulockPushes[addr] != push {
            target.ulockPushes[addr] = push
            target.kernel?.refreshSchedClass(target)
        }
        queue.pushedOwner = target
    }
}

// MARK: - Importance on ports (§4.3)

extension MachIPC {
    /// The process a port's queued importance boosts: the holder of its
    /// receive right when that is an importance receiver, else the job it
    /// was given to as a watch port at spawn.
    func importanceTarget(_ p: IPCPort) -> DarwinProcess? {
        if let r = p.receiver?.kernel?.schedProcess, r.isImportanceReceiver, !r.isZombie { return r }
        if let w = p.watchProcess, w.isImportanceReceiver, !w.isZombie, w.kernel != nil { return w }
        return nil
    }

    /// Moves the port's credit to its current target. Lock held.
    func rebalanceImportance(_ p: IPCPort) {
        let target = importanceTarget(p)
        guard target !== p.creditedProcess else { return }
        let old = p.creditedProcess
        p.creditedProcess = target
        if p.importanceCount > 0 {
            old?.changeImportance(-p.importanceCount)
            target?.changeImportance(p.importanceCount)
        }
    }

    /// Marks a user message at send time (§4.3, §4.6). Lock held.
    func annotateForScheduling(_ m: inout KMessage, options: UInt64) {
        let ctx = lock.currentContext
        if SchedPolicy.importanceEnabled, options & MachMsgOption.sendNoImportance == 0,
           let proc = kernel?.schedProcess, proc.isImportanceDonor, let p = m.destination.port, !p.isKernelObject {
            if p.importanceDonation {
                m.importance = true
                kernel?.system.schedStats.importanceMessages &+= 1
            } else {
                kernel?.system.schedStats.refusedByPort &+= 1
            }
        }
        if SchedPolicy.qosEnabled, options & MachMsgOption.rcvMsg != 0, case .sendOnce = m.reply, let ctx {
            m.pushClass = Int8(ctx.schedClass)
        }
    }

    /// An importance message joined `p`'s queue. Lock held.
    func importanceQueued(on p: IPCPort) {
        rebalanceImportance(p)
        p.importanceCount += 1
        p.creditedProcess?.changeImportance(1)
    }

    /// An importance message left `p`'s queue. Lock held.
    func importanceDequeued(from p: IPCPort) {
        guard p.importanceCount > 0 else { return }
        p.importanceCount -= 1
        p.creditedProcess?.changeImportance(-1)
        if p.importanceCount == 0 { p.creditedProcess = nil }
    }

    /// `context` received `m` (§4.3, §4.6): it carries the message's
    /// importance and its sender's class until the end of the episode.
    func receivedForScheduling(_ m: KMessage, by context: ThreadContext?) {
        guard let context, let k = context.kernel else { return }
        if m.importance, let p = k.schedProcess, p.isImportanceReceiver {
            if let old = context.carriedImportance { old.changeImportance(-1) }
            context.carriedImportance = p
            p.changeImportance(1)
        }
        if m.pushClass >= 0, SchedPolicy.qosEnabled {
            context.ipcPushClass = Int(m.pushClass)
            k.lock.deferIfFast(.kernelLock(k.lock)) { [weak k] in k?.refreshSchedClass(context) }
        }
    }

    /// Spawn: binds the child's watch ports and counts the importance
    /// already queued on them (§4.2). Lock held.
    func bindImportanceWatchPorts(_ ports: [IPCPort], to child: DarwinProcess) {
        // Only importance receivers (adaptive daemons) take watch ports.
        guard child.isImportanceReceiver else { return }
        // xnu binds every watch port but counts the importance already queued
        // only on a temporary owner (scheduling-policy.md §2.3).
        for p in ports where p.active {
            guard p.tempOwner else {
                p.watchProcess = child
                continue
            }
            if let old = p.creditedProcess, p.importanceCount > 0 { old.changeImportance(-p.importanceCount) }
            p.creditedProcess = nil
            p.watchProcess = child
            rebalanceImportance(p)
        }
    }
}

// MARK: - The start hold (§4.2)

/// Counters for the exit report.
public struct SchedStats: Sendable {
    public var holds = 0
    public var releasedByBoost = 0
    public var releasedQuiet = 0
    public var releasedTimeout = 0
    public var releasedExit = 0
    /// Holdable spawns not held because a client had already sent to them.
    public var demandStarts = 0
    public var heldNanoseconds: UInt64 = 0
    public var classChanges: UInt64 = 0
    /// Importance diagnostics: ports marked as accepting importance or as
    /// temporary owners, user messages that carried importance, and sends
    /// from a donor to a port that does not accept it.
    public var donationPorts = 0
    public var tempOwnerPorts = 0
    public var importanceMessages: UInt64 = 0
    public var refusedByPort: UInt64 = 0
}

extension DarwinSystem {
    /// Holds `p`'s new image before its first instruction. Lock held.
    func startHold(_ p: DarwinProcess, label: String) {
        p.holdStart = KernelClock.now()
        p.holdLabel = label
        heldProcesses.append(p)
        schedStats.holds += 1
        holdLog?("pid \(p.pid) \(label): start held (\(ProcessTypeCode.name(p.processType)), unboosted)")
        if !holdThreadRunning {
            holdThreadRunning = true
            let t = Thread { [weak self] in self?.holdLoop() }
            t.name = "ycode start hold"
            t.start()
        } else {
            holdWake.wakeAll()
        }
    }

    /// Starts `p`'s held image now. Lock held.
    func releaseStartHold(_ p: DarwinProcess, reason: String) {
        guard let start = p.holdStart else { return }
        p.holdStart = nil
        heldProcesses.removeAll { $0 === p }
        let held = KernelClock.now() &- start
        schedStats.heldNanoseconds &+= held
        switch reason {
        case "boost": schedStats.releasedByBoost += 1
        case "quiet": schedStats.releasedQuiet += 1
        case "timeout": schedStats.releasedTimeout += 1
        default: schedStats.releasedExit += 1
        }
        holdLog?("pid \(p.pid) \(p.holdLabel): start hold released (\(reason)) after \(held / 1_000_000) ms")
        if reason != "exit", p.state != .zombie, !p.exiting { p.image?.resume() }
    }

    /// The hold thread: releases holds when the system is quiet or a hold
    /// reaches its bound (boosts release at once, `changeImportance`).
    private func holdLoop() {
        lock.withLock {
            // (time, lock held total) every pass, for the busy fraction.
            var samples: [(UInt64, UInt64)] = []
            var lastTrace: UInt64 = 0
            while true {
                for p in heldProcesses where p.state == .zombie || p.exiting { releaseStartHold(p, reason: "exit") }
                let now = KernelClock.now()
                samples.append((now, lock.totalHeldNanoseconds))
                // Keep one sample at or beyond the window's start.
                while samples.count > 1, now &- samples[1].0 >= SchedPolicy.holdWindowNanoseconds { samples.removeFirst() }
                let span = now &- samples[0].0
                let busy = span == 0 ? 1 : Double(lock.totalHeldNanoseconds &- samples[0].1) / Double(span)
                // A full window is needed before the system counts as quiet.
                let windowFull = span >= SchedPolicy.holdWindowNanoseconds
                let contentionAge = now &- lock.lastHighContention
                if SchedPolicy.holdTrace, now &- lastTrace >= 1_000_000_000 {
                    lastTrace = now
                    holdLog?("hold inputs: lock busy \(Int(busy * 100))% over \(span / 1_000_000) ms, "
                        + "last contention \(contentionAge / 1_000_000) ms ago, \(heldProcesses.count) held")
                }
                for p in heldProcesses where now &- (p.holdStart ?? now) >= SchedPolicy.holdMaxNanoseconds {
                    releaseStartHold(p, reason: "timeout")
                }
                if windowFull, busy < SchedPolicy.holdBusyFraction, contentionAge >= SchedPolicy.holdQuietNanoseconds {
                    for p in heldProcesses where now &- (p.holdStart ?? now) >= SchedPolicy.holdQuietNanoseconds {
                        releaseStartHold(p, reason: "quiet")
                    }
                }
                if heldProcesses.isEmpty { break }
                _ = holdWake.wait(on: lock, deadline: KernelClock.deadline(afterNanoseconds: 50_000_000))
            }
            holdThreadRunning = false
        }
    }

    /// One line for the exit report.
    public var schedReport: String {
        lock.withLock {
            let s = schedStats
            var line = "start holds \(s.holds) (boost \(s.releasedByBoost), quiet \(s.releasedQuiet), "
                + "timeout \(s.releasedTimeout), exit \(s.releasedExit), still held \(heldProcesses.count); not held on demand \(s.demandStarts)), "
                + "\(s.heldNanoseconds / 1_000_000) ms held in all; class changes \(s.classChanges); "
                + "importance: \(s.donationPorts) receiving ports, \(s.tempOwnerPorts) temporary owners, "
                + "\(s.importanceMessages) messages, \(s.refusedByPort) donor sends to other ports"
            line += "; " + lock.admissionReport
            return line
        }
    }
}
