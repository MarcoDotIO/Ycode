import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The scheduling policy (`specs/simulator/scheduling-policy.md`): classes,
/// the start hold, importance, the kernel lock's admission gate, inheritance.
/// Serialized: the switches are process-wide.
@Suite(.serialized) struct SchedPolicyTests {
    /// Runs `body` with the given switches, restoring them afterwards.
    func with(hold: Bool = false, qos: Bool = false, bounds: [UInt64]? = nil, holdMax: UInt64? = nil,
              quiet: UInt64? = nil, _ body: () throws -> Void) rethrows {
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
            let window = SchedPolicy.holdWindowNanoseconds
            SchedPolicy.holdWindowNanoseconds = 100_000_000
            defer { SchedPolicy.holdWindowNanoseconds = window }
            let env = try ProcEnv()
            let (_, _, _) = env.spawn(from: env.rootKernel, flags: 0, apptype: 0x600)
            let deadline = Date().addingTimeInterval(5)
            while env.launcher.launches.last!.image.resumed == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            #expect(env.launcher.launches.last!.image.resumed == 1)
            #expect(env.system.schedStats.releasedQuiet == 1)
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
