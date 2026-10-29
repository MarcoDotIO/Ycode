import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// A guest thread running guest code on a stand-in vCPU: it counts, and
/// checks its run gate before every step as the vCPU pool does before each
/// guest entry (`threads-and-events.md` §1.6), parking there with registers
/// whose PC tells how far it got.
final class SpinningThread: @unchecked Sendable {
    let ctx: ThreadContext
    let counter = Atomic<UInt64>(0)
    private let stop = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    /// The registers it continues with after a park that changed them.
    let changed = T2Box<TrapFrame>()

    static let x19: UInt64 = 0x1919_1919
    static let sp: UInt64 = 0x7FFF_0100
    static let pcBase: UInt64 = 0x1_0000_0000

    init(_ ctx: ThreadContext) {
        self.ctx = ctx
        ctx.gate.attached.store(true, ordering: .releasing)
        let thread = Thread { [self] in
            var regs = TrapFrame()
            regs.x[19] = Self.x19
            regs.x[29] = Self.sp + 0x40
            regs.x[30] = 0x2000
            regs.spEL0 = Self.sp
            regs.spsr = 0x2000_0000
            while !stop.load(ordering: .relaxed) {
                if ctx.gate.needsAttention, ctx.gate.isClosed {
                    regs.elr = Self.pcBase + counter.load(ordering: .relaxed)
                    if let c = ctx.gate.park(regs, at: .guest) {
                        regs.takeUserState(of: c)
                        changed.value = regs
                    }
                }
                counter.wrappingAdd(1, ordering: .relaxed)
            }
            ctx.gate.attached.store(false, ordering: .releasing)
            done.signal()
        }
        thread.start()
    }

    /// Ends the loop (the gate must be open) and waits for it.
    func finish() -> Bool {
        stop.store(true, ordering: .relaxed)
        return done.wait(timeout: .now() + 10) == .success
    }
}

@Suite struct ThreadSuspendTests {
    static let suspend: UInt64 = 0x7963_0020
    static let resume: UInt64 = 0x7963_0021
    static let abort: UInt64 = 0x7963_0022
    static let setState: UInt64 = 0x7963_0023
    static let taskSuspend: UInt64 = 0x7963_0024
    static let taskResume: UInt64 = 0x7963_0025
    static let getState: UInt64 = 0x7963_2011
    static let taskSelf: UInt64 = 0x103

    static let stateVA = Env.scratch + 0x2000
    static let countVA = Env.scratch + 0x2800

    /// thread_get_state(ARM_THREAD_STATE64) of `target` as the main
    /// thread: the code, and x0…x28, fp, lr, sp, pc, cpsr on success.
    func getState(_ t: T2Env, _ target: ThreadContext, as caller: ThreadContext? = nil) -> (UInt64, [UInt64]) {
        t.put32(68, at: Self.countVA)
        let code = t.x0(Self.getState, [UInt64(target.portName), 6, Self.stateVA, Self.countVA], context: caller)
        guard code == 0 else { return (code, []) }
        let raw = t.read(Self.stateVA, 34 * 8)
        return (code, (0..<34).map { raw.readLE(UInt64.self, at: 8 * $0) })
    }

    /// A trap of `ctx` whose frame carries recognizable callee-saved
    /// registers, then the gate check the vCPU pool makes after a trap.
    func trapThenGate(_ t: T2Env, _ ctx: ThreadContext, _ x16: UInt64, _ args: [UInt64]) -> TrapFrame {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = x16
        for (i, v) in args.enumerated() { f.x[i] = v }
        f.x[19] = 0xB10C_1919
        f.x[29] = 0x7000_0040
        f.x[30] = 0x4440
        f.spEL0 = 0x7000_0000
        f.elr = 0x4444
        _ = t.kernel.handleTrying(&f, context: ctx, memory: t.space)
        if ctx.gate.isClosed, let c = ctx.gate.park(f, at: .afterTrap) { f.takeUserState(of: c) }
        return f
    }

    @Test func countsAndResumeAtZero() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let port = UInt64(b.portName)
        // Not on a vCPU: stopped at once.
        #expect(t.x0(Self.suspend, [port]) == 0)
        #expect(b.gate.isClosed)
        #expect(t.x0(Self.suspend, [port]) == 0)
        #expect(t.kernel.lock.withLock { b.suspendCount } == 2)
        #expect(t.x0(Self.resume, [port]) == 0)
        #expect(b.gate.isClosed)
        #expect(t.x0(Self.resume, [port]) == 0)
        #expect(!b.gate.isClosed)
        #expect(t.x0(Self.resume, [port]) == 5)        // KERN_FAILURE: count 0
        #expect(t.x0(Self.suspend, [0x9993]) == 0x1000_0003)  // no right: MACH_SEND_INVALID_DEST
        #expect(t.x0(Self.suspend, [Self.taskSelf]) == 4)     // not a thread: KERN_INVALID_ARGUMENT
        #expect(t.host.kicks.contains { $0 === b })
    }

    @Test func aThreadMaySuspendItself() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let main = t.main
        // Returns at once; the thread stops when it would return to user code.
        #expect(t.x0(Self.suspend, [UInt64(main.portName)]) == 0)
        #expect(main.gate.isClosed)
        #expect(t.x0(Self.resume, [UInt64(main.portName)], context: b) == 0)
        #expect(!main.gate.isClosed)
    }

    @Test func aRunningThreadIsStoppedBeforeSuspendReturns() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let spin = SpinningThread(b)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > 1000 })
        #expect(t.x0(Self.suspend, [UInt64(b.portName)]) == 0)
        // Parked when suspend returned: the counter stands still.
        #expect(b.gate.parked != nil)
        let at = spin.counter.load(ordering: .relaxed)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(spin.counter.load(ordering: .relaxed) == at)
        // Its registers where it stopped.
        let (code, s) = getState(t, b)
        #expect(code == 0)
        if code == 0 {
            #expect(s[19] == SpinningThread.x19)
            #expect(s[31] == SpinningThread.sp)          // sp
            #expect(s[32] == SpinningThread.pcBase + at)  // pc
        }
        // thread_info: STOPPED, suspend count 1.
        #expect(t.x0(Self.resume, [UInt64(b.portName)]) == 0)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > at + 1000 })
        // Running and not suspended: no state (libobjc's rule).
        #expect(getState(t, b).0 == 5)
        #expect(spin.finish())
    }

    @Test func aThreadBlockedInTheKernelCountsAsSuspended() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        b.gate.attached.store(true, ordering: .releasing)
        t.svc(0x7963_2003, [Self.taskSelf, Env.scratch + 0x700, 0, 0])
        let sem = UInt64(t.u32(Env.scratch + 0x700))
        let wait = t.spawn { self.trapThenGate(t, b, t.mach(-36), [sem]) }
        #expect(t.eventually { t.blocked(b) })
        // Returns while b stays blocked; its state is its registers at the trap.
        #expect(t.x0(Self.suspend, [UInt64(b.portName)]) == 0)
        var (code, s) = getState(t, b)
        #expect(code == 0)
        if code == 0 {
            #expect(s[16] == t.mach(-36))
            #expect(s[19] == 0xB10C_1919)
            #expect(s[29] == 0x7000_0040 && s[30] == 0x4440)
            #expect(s[31] == 0x7000_0000 && s[32] == 0x4444)
        }
        // Woken while suspended: the call completes, then the thread parks
        // before it would return to user code.
        #expect(t.x0(t.mach(-33), [sem]) == 0)
        #expect(t.eventually { b.gate.parked?.at == .afterTrap })
        (code, s) = getState(t, b)
        #expect(code == 0 && s[0] == 0 && s[19] == 0xB10C_1919 && s[32] == 0x4444)
        #expect(t.x0(Self.resume, [UInt64(b.portName)]) == 0)
        let f = wait()
        #expect(f?.x[0] == 0)
        #expect(!b.gate.isClosed)
    }

    @Test func setStateOnASuspendedThread() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let spin = SpinningThread(b)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > 100 })
        #expect(t.x0(Self.suspend, [UInt64(b.portName)]) == 0)
        // ARM_THREAD_STATE64: x19 and pc changed.
        let (code, s) = getState(t, b)
        #expect(code == 0)
        var words = s
        words[19] = 0x5555
        words[32] = 0xABC0
        var bytes: [UInt8] = []
        for w in words.prefix(33) { bytes.appendLE(w) }
        bytes.appendLE(UInt32(truncatingIfNeeded: words[33]))
        bytes.appendLE(UInt32(0))
        t.put(bytes, at: Self.stateVA)
        #expect(t.x0(Self.setState, [UInt64(b.portName), 6, Self.stateVA, 68]) == 0)
        #expect(t.x0(Self.setState, [UInt64(b.portName), 6, Self.stateVA, 60]) == 4)   // wrong count
        #expect(t.x0(Self.setState, [UInt64(b.portName), 99, Self.stateVA, 68]) == 4)  // unknown flavor
        #expect(t.x0(Self.setState, [UInt64(b.portName), 7, Self.stateVA, 4]) == 0)    // exception state: no effect
        let (_, after) = getState(t, b)
        #expect(after.count == 34 && after[19] == 0x5555 && after[32] == 0xABC0)
        #expect(t.x0(Self.resume, [UInt64(b.portName)]) == 0)
        #expect(t.eventually { spin.changed.value != nil })
        #expect(spin.changed.value?.x[19] == 0x5555)
        #expect(spin.finish())
    }

    @Test func setStateOfARunningThreadHoldsItBriefly() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let spin = SpinningThread(b)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > 100 })
        var bytes: [UInt8] = []
        for r in 0..<33 { bytes.appendLE(r == 19 ? UInt64(0x7777) : r == 31 ? SpinningThread.sp : 0) }
        bytes.appendLE(UInt32(0)); bytes.appendLE(UInt32(0))
        t.put(bytes, at: Self.stateVA)
        #expect(t.x0(Self.setState, [UInt64(b.portName), 6, Self.stateVA, 68]) == 0)
        #expect(t.eventually { spin.changed.value?.x[19] == 0x7777 })
        #expect(!b.gate.isClosed)
        #expect(spin.finish())
    }

    @Test func taskSuspendStopsEveryThread() throws {
        let t = try T2Env()
        let (a, _) = t.createThread()
        let (b, _) = t.createThread()
        let spins = [SpinningThread(a), SpinningThread(b)]
        #expect(t.eventually { spins.allSatisfy { $0.counter.load(ordering: .relaxed) > 100 } })
        #expect(t.x0(Self.taskResume, [Self.taskSelf]) == 5)   // not suspended
        #expect(t.x0(Self.taskSuspend, [Self.taskSelf]) == 0)
        #expect(a.gate.parked != nil && b.gate.parked != nil)
        // The caller's own thread is suspended too (it stops on its return).
        #expect(t.main.gate.isClosed)
        let counts = spins.map { $0.counter.load(ordering: .relaxed) }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(spins.map { $0.counter.load(ordering: .relaxed) } == counts)
        // A thread's own count and the task's: both must reach zero.
        #expect(t.x0(Self.suspend, [UInt64(a.portName)]) == 0)
        #expect(t.x0(Self.taskSuspend, [Self.taskSelf]) == 0)
        #expect(t.x0(Self.taskResume, [Self.taskSelf]) == 0)
        #expect(t.x0(Self.taskResume, [Self.taskSelf]) == 0)
        #expect(t.eventually { spins[1].counter.load(ordering: .relaxed) > counts[1] + 100 })
        #expect(a.gate.isClosed && !b.gate.isClosed && !t.main.gate.isClosed)
        // A thread made while the task is suspended starts suspended.
        #expect(t.x0(Self.taskSuspend, [Self.taskSelf]) == 0)
        let (c, _) = t.createThread()
        #expect(c.gate.isClosed)
        #expect(t.x0(Self.taskResume, [Self.taskSelf]) == 0)
        #expect(!c.gate.isClosed)
        #expect(t.x0(Self.resume, [UInt64(a.portName)]) == 0)
        #expect(t.eventually { spins[0].counter.load(ordering: .relaxed) > counts[0] + 100 })
        #expect(spins.allSatisfy { $0.finish() })
    }

    @Test func startSuspendedThreadStartsAtResume() throws {
        let t = try T2Env()
        let region = t.map(0x2_0000)
        let flags: UInt64 = 0x0100_0000 | 0x2000_0000   // PTHREAD_START_CUSTOM | SUSPENDED
        let before = t.host.starts.count
        let (_, f) = t.svc(360, [0x5000, 0x6000, region + 0x1_0000, region + 0x1_0000, flags])
        #expect(!f.carry)
        #expect(t.host.starts.count == before)
        let ctx = try #require(t.kernel.lock.withLock { t.kernel.threadsByPort.values.first { $0.suspendedStart != nil } })
        #expect(t.kernel.lock.withLock { ctx.suspendCount } == 1)
        // Its start state is its thread state.
        let (code, s) = getState(t, ctx)
        #expect(code == 0 && s[2] == 0x5000)
        #expect(t.x0(Self.resume, [UInt64(ctx.portName)]) == 0)
        #expect(t.host.starts.count == before + 1)
        #expect(t.x0(Self.resume, [UInt64(ctx.portName)]) == 5)
    }

    @Test func abortEndsAKernelWait() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        t.svc(0x7963_2003, [Self.taskSelf, Env.scratch + 0x700, 0, 0])
        let sem = UInt64(t.u32(Env.scratch + 0x700))
        let wait = t.spawn { t.x0(t.mach(-36), [sem], context: b) }
        #expect(t.eventually { t.blocked(b) })
        #expect(t.x0(Self.abort, [UInt64(b.portName)]) == 0)
        let r = wait()
        #expect(r == 14)   // KERN_ABORTED: the wait ended without a signal
        #expect(t.x0(Self.abort, [UInt64(b.portName), 1]) == 0)   // abort_safely of a thread not waiting
    }
}
