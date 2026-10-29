import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Held while a test changes the process-wide scheduling switches, and by
/// tests of other suites whose paths read them (the ulock fast path declines
/// while `SchedPolicy.qosEnabled`).
let schedSwitchesTestLock = NSRecursiveLock()

/// The scheduling policy (`specs/simulator/scheduling-policy.md`): classes,
/// the start hold, importance, the kernel lock's admission gate, inheritance.
/// Serialized: the switches are process-wide.
@Suite(.serialized) struct SchedPolicyTests {
    /// Runs `body` with the given switches, restoring them afterwards.
    func with(hold: Bool = false, qos: Bool = false, bounds: [UInt64]? = nil, holdMax: UInt64? = nil,
              quiet: UInt64? = nil, _ body: () throws -> Void) rethrows {
        schedSwitchesTestLock.lock()
        defer { schedSwitchesTestLock.unlock() }
        let saved = (SchedPolicy.holdEnabled, SchedPolicy.qosEnabled, SchedPolicy.admissionBoundNanoseconds,
                     SchedPolicy.holdMaxNanoseconds, SchedPolicy.holdQuietNanoseconds, SchedPolicy.admissionEnabled)
        SchedPolicy.holdEnabled = hold
        SchedPolicy.qosEnabled = qos
        SchedPolicy.admissionEnabled = true
        if let bounds { SchedPolicy.admissionBoundNanoseconds = bounds }
        if let holdMax { SchedPolicy.holdMaxNanoseconds = holdMax }
        if let quiet { SchedPolicy.holdQuietNanoseconds = quiet }
        defer {
            (SchedPolicy.holdEnabled, SchedPolicy.qosEnabled, SchedPolicy.admissionBoundNanoseconds,
             SchedPolicy.holdMaxNanoseconds, SchedPolicy.holdQuietNanoseconds, SchedPolicy.admissionEnabled) = saved
        }
        try body()
    }

    // MARK: Classes (§4.4)

    @Test func classFromInputs() {
        #expect(SchedInputs(baseQoS: 0).schedClass == SchedClass.default)
        #expect(SchedInputs(baseQoS: 4).schedClass == SchedClass.default)
        #expect(SchedInputs(baseQoS: 6).schedClass == SchedClass.interactive)
        #expect(SchedInputs(baseQoS: 5).schedClass == SchedClass.interactive)
        #expect(SchedInputs(baseQoS: 3).schedClass == SchedClass.utility)
        #expect(SchedInputs(baseQoS: 2).schedClass == SchedClass.background)
        #expect(SchedInputs(baseQoS: 1).schedClass == SchedClass.background)
        // Overrides raise; a clamp caps; darwin-bg forces background; a push wins over all.
        #expect(SchedInputs(baseQoS: 3, overrideQoS: 6).schedClass == SchedClass.interactive)
        #expect(SchedInputs(baseQoS: 6, clampQoS: 3).schedClass == SchedClass.utility)
        #expect(SchedInputs(baseQoS: 0, clampQoS: 2).schedClass == SchedClass.background)
        #expect(SchedInputs(baseQoS: 6, darwinBG: true).schedClass == SchedClass.background)
        #expect(SchedInputs(baseQoS: 2, darwinBG: true, push: SchedClass.interactive).schedClass == SchedClass.interactive)
    }

    @Test func primordialQoSPerProcessType() {
        #expect(ProcessTypeCode.primordialQoS(0x100) == 6)
        #expect(ProcessTypeCode.primordialQoS(0x300) == 4)
        #expect(ProcessTypeCode.primordialQoS(0x400) == 4)
        #expect(ProcessTypeCode.primordialQoS(0x600) == 4)
        #expect(ProcessTypeCode.primordialQoS(0x500) == 2)
        #expect(ProcessTypeCode.primordialQoS(0) == 0)
    }

    // MARK: Start hold and importance (§4.2, §4.3)

    /// A port in the root's space, with its object.
    func port(_ env: ProcEnv) -> IPCPort {
        let ipc = env.rootKernel.machIPC as! MachIPC
        return env.system.lock.withLock {
            let (kr, name) = ipc.portAllocate(right: MachPortRight.receive)
            precondition(kr == 0)
            let p = ipc.entries[ipc.lookup(name)!].port!
            // As launchd makes its service ports.
            p.importanceDonation = true
            p.tempOwner = true
            return p
        }
    }

    func message(importance: Bool) -> KMessage {
        var m = KMessage(complex: false, destination: .null, destinationType: 0, reply: .null, replyType: 0, id: 7)
        m.importance = importance
        return m
    }

    @Test func adaptiveJobIsHeldUntilAMessageBoostsIt() throws {
        try with(hold: true, holdMax: 60_000_000_000, quiet: 60_000_000_000) {
            let env = try ProcEnv()
            let (_, e, pid) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x600)
            #expect(e == 0)
            let launch = env.launcher.launches.last!
            #expect(launch.request.startSuspended)
            let child = env.system.process(pid: pid)!
            #expect(env.system.lock.withLock { child.holdStart != nil && child.state == .running })
            #expect(launch.image.resumed == 0)
            // A message without importance does nothing; one with importance on a watch port releases it.
            let p = port(env)
            let ipc = env.rootKernel.machIPC as! MachIPC
            env.system.lock.withLock {
                ipc.bindImportanceWatchPorts([p], to: child)
                ipc.enqueue(message(importance: false), on: p)
            }
            #expect(launch.image.resumed == 0)
            env.system.lock.withLock { ipc.enqueue(message(importance: true), on: p) }
            #expect(launch.image.resumed == 1)
            #expect(env.system.lock.withLock { child.holdStart == nil && child.importanceBoosts == 1 && !child.isDarwinBG })
            #expect(env.system.schedStats.releasedByBoost == 1)
            // The boost ends when the message leaves the queue (received by a non-receiver).
            env.system.lock.withLock {
                _ = ipc.dequeue(p)
                _ = ipc.dequeue(p)
            }
            #expect(env.system.lock.withLock { child.importanceBoosts == 0 && child.isDarwinBG })
            #expect(launch.image.resumed == 1)
        }
    }

    @Test func importanceQueuedBeforeSpawnStartsTheJobBoosted() throws {
        try with(hold: true, holdMax: 60_000_000_000, quiet: 60_000_000_000) {
            let env = try ProcEnv()
            let p = port(env)
            let ipc = env.rootKernel.machIPC as! MachIPC
            env.system.lock.withLock { ipc.enqueue(message(importance: true), on: p) }
            // The root (no type) is not a receiver: nothing is credited yet.
            #expect(env.system.lock.withLock { p.importanceCount == 1 && p.creditedProcess == nil })
            let (_, e, pid) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x600)
            #expect(e == 0)
            let child = env.system.process(pid: pid)!
            // Bind as the spawn would have (the helper passes no port actions): it is boosted, the hold ends.
            env.system.lock.withLock { ipc.bindImportanceWatchPorts([p], to: child) }
            #expect(env.system.lock.withLock { child.importanceBoosts == 1 && child.holdStart == nil })
            #expect(env.launcher.launches.last!.image.resumed == 1)
        }
    }

    @Test func onlyImportanceReceivingPortsGetImportance() throws {
        try with(hold: true) {
            let env = try ProcEnv()
            let p = port(env)
            let ipc = env.rootKernel.machIPC as! MachIPC
            env.system.lock.withLock {
                var m = KMessage(complex: false, destination: .send(p), destinationType: 17, reply: .null, replyType: 0, id: 1)
                ipc.annotateForScheduling(&m, options: MachMsgOption.sendMsg)
                #expect(m.importance)  // the root (no type) donates; the port accepts importance
                m.importance = false
                ipc.annotateForScheduling(&m, options: MachMsgOption.sendMsg | MachMsgOption.sendNoImportance)
                #expect(!m.importance)
                p.importanceDonation = false
                ipc.annotateForScheduling(&m, options: MachMsgOption.sendMsg)
                #expect(!m.importance)
            }
        }
    }

    @Test func standardAndUntypedJobsAreNotHeld() throws {
        try with(hold: true) {
            let env = try ProcEnv()
            for type: UInt32 in [0, 0x300, 0x400, 0x100] {
                let (_, e, pid) = env.spawn(from: env.rootKernel, flags: 0, apptype: type)
                #expect(e == 0)
                #expect(!env.launcher.launches.last!.request.startSuspended)
                #expect(env.system.lock.withLock { env.system.process(pid: pid)!.holdStart == nil })
            }
        }
    }

    @Test func backgroundJobIsNotBoostedButReleasedByTheBound() throws {
        try with(hold: true, holdMax: 100_000_000, quiet: 60_000_000_000) {
            let env = try ProcEnv()
            let (_, _, pid) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x500)
            let child = env.system.process(pid: pid)!
            let p = port(env)
            let ipc = env.rootKernel.machIPC as! MachIPC
            env.system.lock.withLock {
                ipc.bindImportanceWatchPorts([p], to: child)
                ipc.enqueue(message(importance: true), on: p)
            }
            // A background daemon takes no watch ports and no boost: it stays darwin-bg and held.
            #expect(env.system.lock.withLock { child.holdStart != nil && child.importanceBoosts == 0 })
            let deadline = Date().addingTimeInterval(5)
            while env.launcher.launches.last!.image.resumed == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(env.launcher.launches.last!.image.resumed == 1)
            #expect(env.system.lock.withLock { child.isDarwinBG })
        }
    }

    @Test func quietSystemReleasesHolds() throws {
        try with(hold: true, holdMax: 60_000_000_000, quiet: 30_000_000) {
            let window = SchedPolicy.holdWindowNanoseconds, cpu = SchedPolicy.holdCPUFraction
            SchedPolicy.holdWindowNanoseconds = 100_000_000
            // The test process's CPU use depends on the suites running beside it.
            SchedPolicy.holdCPUFraction = 0
            defer { (SchedPolicy.holdWindowNanoseconds, SchedPolicy.holdCPUFraction) = (window, cpu) }
            let env = try ProcEnv()
            let (_, _, _) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x600)
            let deadline = Date().addingTimeInterval(5)
            while env.launcher.launches.last!.image.resumed == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(env.launcher.launches.last!.image.resumed == 1)
            #expect(env.system.schedStats.releasedQuiet == 1)
        }
    }

    /// §4.2: while the host process keeps the CPUs busy the system is not
    /// quiet, however idle the kernel lock is; once the CPU test passes,
    /// the hold ends.
    @Test func busyHostCPUKeepsHolds() throws {
        try with(hold: true, holdMax: 60_000_000_000, quiet: 30_000_000) {
            let window = SchedPolicy.holdWindowNanoseconds, cpu = SchedPolicy.holdCPUFraction
            SchedPolicy.holdWindowNanoseconds = 100_000_000
            // Any CPU use at all counts as busy: a spinning thread keeps it so.
            SchedPolicy.holdCPUFraction = 1e-9
            defer { (SchedPolicy.holdWindowNanoseconds, SchedPolicy.holdCPUFraction) = (window, cpu) }
            let stop = Atomic<Bool>(false)
            let spinner = spawn { while !stop.load(ordering: .relaxed) {} }
            let env = try ProcEnv()
            let (_, _, _) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x600)
            Thread.sleep(forTimeInterval: 0.5)
            #expect(env.launcher.launches.last!.image.resumed == 0)
            #expect(env.system.lock.withLock { env.system.schedStats.releasedQuiet } == 0)
            stop.store(true, ordering: .relaxed)
            #expect(spinner.wait(timeout: .now() + 5) == .success)
            SchedPolicy.holdCPUFraction = 0
            let deadline = Date().addingTimeInterval(5)
            while env.launcher.launches.last!.image.resumed == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(env.launcher.launches.last!.image.resumed == 1)
            #expect(env.system.lock.withLock { env.system.schedStats.releasedQuiet } == 1)
        }
    }

    @Test func heldJobThatExitsIsNotStarted() throws {
        try with(hold: true, holdMax: 60_000_000_000, quiet: 60_000_000_000) {
            let env = try ProcEnv()
            let (_, _, pid) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x600)
            #expect(env.bsd(env.rootKernel, 37, [UInt64(pid), 9]) == 0)  // kill(pid, SIGKILL)
            let deadline = Date().addingTimeInterval(5)
            while env.system.lock.withLock({ !env.system.heldProcesses.isEmpty }) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(env.system.lock.withLock { env.system.heldProcesses.isEmpty })
            #expect(env.launcher.launches.last!.image.resumed == 0)
        }
    }

    // MARK: Lock admission (§4.5)

    final class Order: @unchecked Sendable {
        let lock: KernelLock = {
            let l = KernelLock()
            l.admission = SchedPolicy.qosEnabled
            return l
        }()
        var order: [String] = []
        var counter = 0
    }

    func context(_ cls: Int, _ id: UInt64 = 9) -> ThreadContext {
        let c = ThreadContext(threadID: id, portName: 0x1003, vcpuIndex: 0, kind: .pthread)
        c.schedClassStore.store(cls, ordering: .relaxed)
        return c
    }

    func spawn(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread { body(); done.signal() }.start()
        return done
    }

    @Test func higherClassWaiterGoesFirst() {
        with(qos: true, bounds: [5_000_000_000, 5_000_000_000, 5_000_000_000]) {
            for _ in 0..<5 {
                let s = Order()
                let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let holder = spawn { s.lock.withLock { held.signal(); release.wait() } }
                held.wait()
                let high = context(SchedClass.interactive, 2), low = context(SchedClass.background, 3)
                let h = spawn { s.lock.withLock(context: high) { s.order.append("ui") } }
                // The high thread must be blocked on the mutex before the low one arrives.
                let deadline = Date().addingTimeInterval(5)
                while s.lock.higherContending(SchedClass.background) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                let l = spawn { s.lock.withLock(context: low) { s.order.append("bg") } }
                Thread.sleep(forTimeInterval: 0.02)
                release.signal()
                for t in [holder, h, l] { #expect(t.wait(timeout: .now() + 10) == .success) }
                #expect(s.order == ["ui", "bg"])
            }
        }
    }

    @Test func lowClassWaitsOnlyUpToItsBound() {
        with(qos: true, bounds: [30_000_000, 30_000_000, 30_000_000]) {
            let s = Order()
            let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let holder = spawn { s.lock.withLock { held.signal(); release.wait() } }
            held.wait()
            let high = context(SchedClass.interactive, 2), low = context(SchedClass.background, 3)
            let h = spawn { s.lock.withLock(context: high) { s.order.append("ui") } }
            let deadline = Date().addingTimeInterval(5)
            while s.lock.higherContending(SchedClass.background) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            let l = spawn { s.lock.withLock(context: low) { s.order.append("bg") } }
            // After its bound the low thread competes for the mutex itself.
            let deadline2 = Date().addingTimeInterval(5)
            while s.lock.contendingCount(SchedClass.background) == 0 && Date() < deadline2 { Thread.sleep(forTimeInterval: 0.001) }
            #expect(s.lock.contendingCount(SchedClass.background) == 1)
            #expect(s.lock.admissionReport.contains("1 at the bound"))
            release.signal()
            for t in [holder, h, l] { #expect(t.wait(timeout: .now() + 10) == .success) }
            #expect(s.order.count == 2)
        }
    }

    @Test func mixedClassesNeverDeadlockOrLoseMutualExclusion() {
        with(qos: true, bounds: [2_000_000, 1_000_000, 500_000]) {
            let s = Order()
            let threads = (0..<16).map { i in
                spawn {
                    let ctx = context(i % SchedClass.count, UInt64(10 + i))
                    for n in 0..<1500 {
                        // Some threads change class as they go (overrides, boosts).
                        if n % 100 == 0 { ctx.schedClassStore.store((i + n / 100) % SchedClass.count, ordering: .relaxed) }
                        s.lock.withLock(context: ctx) { s.counter += 1 }
                    }
                }
            }
            for t in threads { #expect(t.wait(timeout: .now() + 60) == .success) }
            #expect(s.counter == 16 * 1500)
            #expect(s.lock.higherContending(-1) == 0)
        }
    }

    /// §4.7 (holders): a thread that waits for a kernel lock longer than the
    /// promotion delay, held by a holder of a lower applied class, raises the
    /// holder's host thread to its own class; the holder keeps the raised
    /// class as its applied one when it lets go, so its next `apply` moves
    /// it back (here with no demotion delay). A waiter of a class the holder
    /// already has does not move it.
    @Test func lockHolderIsRaisedToItsWaitersClassAndMovedBack() {
        with(qos: true) {
            let moves = Mutex<[(tid: Int32, cls: Int)]>([])
            let savedTID = HostSched.threadID
            let nextTID = Atomic<Int>(5000)
            HostSched.threadID = { nextTID.wrappingAdd(1, ordering: .relaxed).newValue }
            HostSched.moveHook = { tid, cls in moves.withLock { $0.append((tid, cls)) } }
            let savedDelays = (HostSched.demoteDelayNanoseconds, KernelLock.promotionDelayNanoseconds)
            HostSched.demoteDelayNanoseconds = 0
            KernelLock.promotionDelayNanoseconds = 2_000_000
            defer {
                HostSched.moveHook = nil
                HostSched.threadID = savedTID
                (HostSched.demoteDelayNanoseconds, KernelLock.promotionDelayNanoseconds) = savedDelays
            }
            let promotionsBefore = HostSched.promotions.load(ordering: .relaxed)
            for (holderClass, waiterClass) in [(SchedClass.background, SchedClass.interactive),
                                               (SchedClass.default, SchedClass.default)] {
                moves.withLock { $0.removeAll() }
                let lock = KernelLock()
                lock.admission = false
                let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let holderTID = Mutex<Int32>(0), appliedAfter = Mutex<Int>(-2)
                let holder = spawn {
                    HostSched.apply(holderClass)
                    holderTID.withLock { $0 = HostSched.currentTID() ?? 0 }
                    lock.withLock(context: self.context(holderClass)) {
                        held.signal()
                        release.wait()
                    }
                    appliedAfter.withLock { $0 = HostSched.appliedClass() }
                    HostSched.apply(holderClass)
                }
                held.wait()
                let waiter = spawn { lock.withLock(context: self.context(waiterClass, 10)) {} }
                let tid = holderTID.withLock { $0 }
                let deadline = Date().addingTimeInterval(waiterClass > holderClass ? 5 : 0.2)
                while Date() < deadline, !moves.withLock({ $0.contains { $0.tid == tid && $0.cls == waiterClass } }) {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                release.signal()
                #expect(holder.wait(timeout: .now() + 10) == .success)
                #expect(waiter.wait(timeout: .now() + 10) == .success)
                let holderMoves = moves.withLock { $0.filter { $0.tid == tid }.map(\.cls) }
                if waiterClass > holderClass {
                    // Applied, raised by the waiter, moved back after the release.
                    #expect(holderMoves == [holderClass, waiterClass, holderClass])
                    #expect(appliedAfter.withLock { $0 } == waiterClass)
                } else {
                    #expect(holderMoves == [holderClass])
                    #expect(appliedAfter.withLock { $0 } == holderClass)
                }
            }
            #expect(HostSched.promotions.load(ordering: .relaxed) - promotionsBefore == 1)
        }
    }

    /// §4.7: a rise of the class is applied at once; a fall only once the
    /// lower class has lasted the demotion delay (a fall that is undone in
    /// time costs no move).
    @Test func demotionWaitsForTheDelay() {
        with(qos: true) {
            let moves = Mutex<[Int]>([])
            let savedTID = HostSched.threadID
            HostSched.threadID = { 7777 }
            HostSched.moveHook = { _, cls in moves.withLock { $0.append(cls) } }
            let saved = HostSched.demoteDelayNanoseconds
            HostSched.demoteDelayNanoseconds = 30_000_000
            defer { HostSched.moveHook = nil; HostSched.threadID = savedTID; HostSched.demoteDelayNanoseconds = saved }
            let done = spawn {
                HostSched.apply(SchedClass.interactive)
                HostSched.apply(SchedClass.background)  // put off
                HostSched.apply(SchedClass.interactive)  // undone: no move
                HostSched.apply(SchedClass.utility)  // put off
                Thread.sleep(forTimeInterval: 0.05)
                HostSched.apply(SchedClass.utility)  // the delay passed
                HostSched.apply(SchedClass.default)  // a rise: at once
            }
            #expect(done.wait(timeout: .now() + 10) == .success)
            #expect(moves.withLock { $0 } == [SchedClass.interactive, SchedClass.utility, SchedClass.default])
        }
    }

    /// §4.6 (send push): a sender blocked on a full queue raises the image
    /// that receives the port to its class until it stops waiting.
    @Test func blockedSenderPushesOntoTheReceivingImage() throws {
        try with(qos: true) {
            let w = SplitWorld()
            let rx = try w.add(pid: 200)
            let port = w.allocate(rx)
            #expect(w.system.lock.withLock { rx.ipc.portSetAttributes(port, flavor: 1, info: [1]) } == 0)
            let tx = try w.add(pid: 300)
            let name = w.give(port, from: rx, to: tx, disposition: MachMsgType.makeSend)
            let ctx = w.thread(tx)
            ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
            #expect(rx.kernel.sendPushClass == -1)
            let first = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: 1)
            #expect(w.machMsg(tx, ctx, first.bytes, at: SplitWorld.scratch + 0x1000, fast: true).0 == 0)
            let blocked = spawnThread {
                let m = TestMessage(remote: name, remoteDisposition: MachMsgType.copySend, id: 2)
                return Int(w.machMsg(tx, ctx, m.bytes, at: SplitWorld.scratch + 0x2000, fast: true).0)
            }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, rx.kernel.sendPushClass != SchedClass.interactive { Thread.sleep(forTimeInterval: 0.005) }
            #expect(rx.kernel.sendPushClass == SchedClass.interactive)
            #expect(tx.kernel.sendPushClass == -1)
            let rctx = w.thread(rx)
            let (code, r) = w.machMsg(rx, rctx, nil, at: SplitWorld.scratch + 0x8000, rcvName: port, rcvTimeoutMs: 5000, fast: true)
            #expect(code == 0 && r.id == 1)
            #expect(blocked() == 0)
            #expect(rx.kernel.sendPushClass == -1)
        }
    }

    @Test func gateIsOffWithoutTheSwitch() {
        with(qos: false) {
            let s = Order()
            let threads = (0..<8).map { i in
                spawn { for _ in 0..<1000 { s.lock.withLock(context: context(i % 4)) { s.counter += 1 } } }
            }
            for t in threads { #expect(t.wait(timeout: .now() + 30) == .success) }
            #expect(s.counter == 8000)
            #expect(s.lock.admissionReport.hasPrefix("lock admission: 0 gate waits"))
        }
    }
}
