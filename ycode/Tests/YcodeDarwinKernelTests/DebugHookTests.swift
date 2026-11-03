import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// The kernel's debug hooks (specs/simulator/debug-stub.md §5, §6): a
// debugger takes breakpoints, steps and faults; every thread stops with the
// one that trapped; holds are apart from Mach suspension; resume, step and
// detach.

/// A debugger that records what it was told and answers with `decision`.
final class RecordingDebugger: KernelDebugger, @unchecked Sendable {
    private let lock = NSLock()
    private var stops: [(UInt64, KernelDebugStop)] = []
    var decision = KernelDebugDecision.stop

    func kernelDebugException(_ kernel: DarwinKernel, thread: ThreadContext, stop: KernelDebugStop) -> KernelDebugDecision {
        lock.lock()
        defer { lock.unlock() }
        stops.append((thread.threadID, stop))
        return decision
    }

    var reported: [(UInt64, KernelDebugStop)] {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }
}

@Suite struct DebugHookTests {
    /// A synchronous exception of `ctx` with exception class `ec`.
    func exception(_ t: T2Env, _ ctx: ThreadContext, ec: UInt8, iss: UInt32 = 0, pc: UInt64, far: UInt64 = 0) -> (DarwinKernel.Outcome, TrapFrame) {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.el0Synchronous.rawValue
        f.esr = ExceptionSyndrome(ec: ec, iss: iss).raw
        f.elr = pc
        f.far = far
        f.x[0] = 0xA0
        f.spEL0 = 0x7000_0000
        let o = t.kernel.handleTrying(&f, context: ctx, memory: t.space)
        return (o, f)
    }

    @Test func aBreakpointStopsEveryThread() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let spin = SpinningThread(b)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > 1000 })
        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        #expect(!t.kernel.debugAttach(RecordingDebugger()))   // one debugger per image
        // Attaching holds every thread: the spinning one parks.
        #expect(t.eventually { t.kernel.debugAllStopped() })
        #expect(b.gate.parked != nil)
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        #expect(!b.gate.isClosed)
        let at = spin.counter.load(ordering: .relaxed)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > at + 1000 })

        // brk #0xf000 on the main thread: taken, the trap resumes (the
        // thread parks at its gate after it), and every thread is held.
        let (o, f) = exception(t, t.main, ec: 0x3C, iss: 0xF000, pc: 0x1_0000_4008)
        #expect(o == .resume)
        #expect(f.elr == 0x1_0000_4008)
        #expect(d.reported.count == 1)
        #expect(d.reported.first?.0 == t.main.threadID)
        #expect(d.reported.first?.1 == KernelDebugStop(kind: .breakpoint(immediate: 0xF000), pc: 0x1_0000_4008))
        #expect(t.kernel.debugStopOf(t.main)?.kind == .breakpoint(immediate: 0xF000))
        #expect(t.main.gate.isClosed && b.gate.isClosed)
        #expect(t.eventually { b.gate.parked != nil })
        // Holds are not Mach suspension.
        #expect(t.kernel.lock.withLock { b.suspendCount } == 0)

        // Step the main thread: its gate opens with a step request; b stays held.
        t.kernel.debugResume([t.main.threadID: .step], others: .stay)
        #expect(!t.main.gate.isClosed)
        #expect(t.main.gate.takeStepRequest())
        #expect(!t.main.gate.takeStepRequest())
        #expect(b.gate.isClosed)
        #expect(t.kernel.debugStopOf(t.main) == nil)

        // The step ends with a software-step exception: a trace stop.
        let (o2, _) = exception(t, t.main, ec: 0x32, pc: 0x1_0000_400C)
        #expect(o2 == .resume)
        #expect(t.kernel.debugStopOf(t.main)?.kind == .step)

        t.kernel.debugDetach()
        #expect(!t.main.gate.isClosed && !b.gate.isClosed)
        #expect(spin.finish())
    }

    @Test func registersOfAStoppedThread() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        let spin = SpinningThread(b)
        #expect(t.eventually { spin.counter.load(ordering: .relaxed) > 100 })
        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        #expect(t.eventually { t.kernel.debugAllStopped() })
        var regs = try #require(t.kernel.debugRegisters(b))
        #expect(regs.x[19] == SpinningThread.x19)
        #expect(regs.spEL0 == SpinningThread.sp)
        regs.x[19] = 0x5151
        regs.elr = 0x1_2345_6780
        #expect(t.kernel.debugSetRegisters(b, regs))
        #expect(t.kernel.debugRegisters(b)?.x[19] == 0x5151)
        #expect(t.kernel.debugThreads.map(\.threadID) == [t.main.threadID, b.threadID])
        t.kernel.debugDetach()
        // The thread continued with the new registers.
        #expect(t.eventually { spin.changed.value?.x[19] == 0x5151 })
        #expect(spin.changed.value?.elr == 0x1_2345_6780)
        #expect(spin.finish())
    }

    @Test func faultsStopAndThenTakeTheirCourse() throws {
        let t = try T2Env()
        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        // A data abort (translation fault, level 3) at an unmapped address.
        let (o, _) = exception(t, t.main, ec: 0x24, iss: 0x07, pc: 0x1_0000_4010, far: 0x10)
        #expect(o == .resume)
        guard case let .fault(signal, text)? = t.kernel.debugStopOf(t.main)?.kind else {
            Issue.record("no fault stop")
            return
        }
        #expect(signal == DarwinKernel.Signal.sigsegv)
        #expect(text.hasPrefix("SIGSEGV"))
        #expect(text.contains("0x10"))
        // Resumed with its signal: the same fault is fatal.
        t.kernel.debugResume([t.main.threadID: .run(deliverSignal: true)], others: .stay)
        let (o2, _) = exception(t, t.main, ec: 0x24, iss: 0x07, pc: 0x1_0000_4010, far: 0x10)
        if case .fatal = o2 {} else { Issue.record("expected the fault to end the image, got \(o2)") }
        #expect(d.reported.count == 1)
    }

    @Test func declinedAndRetriedExceptions() throws {
        let t = try T2Env()
        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        d.decision = .retry
        let (o, _) = exception(t, t.main, ec: 0x3C, iss: 0xF000, pc: 0x1_0000_4000)
        #expect(o == .resume)
        #expect(!t.main.gate.isClosed)          // nothing stopped
        #expect(t.kernel.debugStopOf(t.main) == nil)
        d.decision = .decline
        let (o2, _) = exception(t, t.main, ec: 0x3C, iss: 1, pc: 0x1_0000_4000)
        if case .fatal = o2 {} else { Issue.record("a declined brk ends the image, got \(o2)") }
    }

    @Test func aStepTrapWithoutADebuggerIsIgnored() throws {
        let t = try T2Env()
        let (o, _) = exception(t, t.main, ec: 0x32, pc: 0x1_0000_4000)
        #expect(o == .resume)
    }

    @Test func threadsMadeDuringAStopStartHeld() throws {
        let t = try T2Env()
        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        let (b, _) = t.createThread()
        #expect(b.gate.isClosed)
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        #expect(!b.gate.isClosed)
        let (c, _) = t.createThread()
        #expect(!c.gate.isClosed)
        t.kernel.debugStopAll()
        #expect(b.gate.isClosed && c.gate.isClosed)
        // Mach suspension and the hold add up: resuming the hold leaves a
        // suspended thread suspended.
        #expect(t.x0(ThreadSuspendTests.suspend, [UInt64(c.portName)]) == 0)
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        #expect(!b.gate.isClosed)
        #expect(c.gate.isClosed)
        #expect(t.x0(ThreadSuspendTests.resume, [UInt64(c.portName)]) == 0)
        #expect(!c.gate.isClosed)
        t.kernel.debugDetach()
    }

    @Test func flushRequestsReachEveryThread() throws {
        let t = try T2Env()
        let (b, _) = t.createThread()
        t.kernel.debugRequestFlush()
        #expect(t.main.gate.takeFlushRequest() && b.gate.takeFlushRequest())
        #expect(!b.gate.takeFlushRequest())
    }

    @Test func aWatchpointStopsWithItsAddress() throws {
        let t = try T2Env()
        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        // EC 0x34 (watchpoint from a lower EL), ISS.WnR set: a store.
        let (o, f) = exception(t, t.main, ec: 0x34, iss: 1 << 6, pc: 0x1_0000_4020, far: 0x16_fdff_f8a4)
        #expect(o == .resume)
        #expect(f.elr == 0x1_0000_4020)   // the access has not happened: the instruction runs again
        #expect(t.kernel.debugStopOf(t.main)?.kind == .watchpoint(address: 0x16_fdff_f8a4, write: true))
        let (_, _) = exception(t, t.main, ec: 0x34, iss: 0, pc: 0x1_0000_4024, far: 0x1000)
        #expect(d.reported.last?.1.kind == .watchpoint(address: 0x1000, write: false))
        t.kernel.debugDetach()
        // Without a debugger a left-over watchpoint trap is ignored.
        let (o3, _) = exception(t, t.main, ec: 0x34, iss: 0, pc: 0x1_0000_4024, far: 0x1000)
        #expect(o3 == .resume)
    }

    @Test func imageListChangesGoOnToTheNotificationFunction() throws {
        let t = try T2Env()
        let infos = Env.scratch + 0x8000
        t.kernel.allImageInfosAddress = infos
        t.put64(0x3_1000_0F00, at: infos + 16)                  // notification: the host page's `ret`
        t.put64(0x1_8000_0000, at: Env.scratch + 0x100)         // mach_header* addrs[2]
        t.put64(0x1_8001_0000, at: Env.scratch + 0x108)
        t.put64(Env.scratch + 0x300, at: Env.scratch + 0x200)   // const char* paths[2]
        t.put64(Env.scratch + 0x310, at: Env.scratch + 0x208)
        let sp = Env.scratch + 0xE000
        func notify(unloading: UInt64) -> TrapFrame {
            var f = TrapFrame()
            f.kind = TrapFrame.Kind.svc.rawValue
            f.x[16] = UInt64(DarwinKernel.Private.notifyImageListChanges)
            f.x[0] = unloading
            f.x[1] = 2
            f.x[2] = Env.scratch + 0x100
            f.x[3] = Env.scratch + 0x200
            f.x[30] = 0x2_0000_5000
            f.spEL0 = sp
            f.elr = 0x3_1000_0104
            _ = t.kernel.handleTrying(&f, context: t.main, memory: t.space)
            return f
        }
        // No debugger: the helper just returns.
        #expect(notify(unloading: 0).elr == 0x3_1000_0104)

        let d = RecordingDebugger()
        #expect(t.kernel.debugAttach(d))
        t.kernel.debugResume([:], others: .run(deliverSignal: false))
        let f = notify(unloading: 0)
        // notification(mode 0 adding, 2, dyld_image_info[2]), returning to the caller.
        #expect(f.elr == 0x3_1000_0F00)
        #expect(f.x[0] == 0 && f.x[1] == 2)
        #expect(f.x[30] == 0x2_0000_5000 && f.spEL0 == sp)
        let array = f.x[2]
        #expect(array & 0xF == 0 && array + 48 <= sp - 128)
        var expected: [UInt8] = []
        for v: UInt64 in [0x1_8000_0000, Env.scratch + 0x300, 0, 0x1_8001_0000, Env.scratch + 0x310, 0] { expected.appendLE(v) }
        #expect(t.read(array, 48) == expected)
        #expect(notify(unloading: 1).x[0] == 1)   // dyld_notify_removing

        // "main called": libdyld's state becomes "program running".
        #expect(!t.kernel.debugDyldMainCalled)
        t.svc(UInt64(DarwinKernel.Private.notifyMainCalled))
        #expect(t.kernel.debugDyldMainCalled)
        t.kernel.debugDetach()
    }
}
