import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Threads, ulock, and Mach semaphores with several threads
/// (stage4a-contract.md §5; threads-and-events.md §1, §4.1, §4.3).
@Suite(.serialized) struct ThreadSyncTests {
    static let noErrno: UInt64 = 0x0100_0000
    func errno(_ v: UInt64) -> Int64 { -Int64(bitPattern: v) }

    // MARK: bsdthread_create / thread_selfid

    @Test func createSetsTheExactRegisterState() throws {
        let t = try T2Env()
        let region = t.map(0x2_0000)
        let pthread = region + 0x1_0000, stack = region + 0x1_0000
        let flags: UInt64 = 0x0100_0000 | 0x2000_0000  // CUSTOM | SUSPENDED
        let (o, f) = t.svc(360, [0x5000, 0x6000, stack, pthread, flags])
        #expect(o == .resume && !f.carry && f.x[0] == pthread)
        // Suspended: nothing started yet.
        #expect(t.host.starts.isEmpty)
        let ctx = try #require(t.kernel.liveThreads.first { $0.kind == .pthread })
        #expect(ctx.portName & 3 == 3 && ctx.portName != 0x203)
        #expect(t.u64(pthread + 224 + 24) == UInt64(ctx.portName))  // TSD slot 3
        #expect(t.kernel.resumeSuspendedThread(port: ctx.portName))
        let s = try #require(t.host.starts.first)
        #expect(s.context === ctx)
        #expect(s.state.pc == T2Env.threadStart && s.state.sp == stack && s.state.tpidrro == pthread + 224)
        #expect(Array(s.state.x[0..<6]) == [pthread, UInt64(ctx.portName), 0x5000, 0x6000, stack, 0x1100_0000])
        #expect(s.state.x[6...].allSatisfy { $0 == 0 } && s.state.tpidr == 0)
        let frame = s.state.frame
        #expect(frame.elr == T2Env.threadStart && frame.spEL0 == stack && frame.spsr == 0)
        // thread_selfid: unique per thread, main = 1.
        #expect(t.x0(372) == 1)
        #expect(t.x0(372, context: ctx) == ctx.threadID && ctx.threadID > 1)
        let (other, _) = t.createThread()
        #expect(other.threadID != ctx.threadID && other.portName != ctx.portName)
        #expect(t.kernel.thread(port: other.portName) === other)
    }

    @Test func createErrors() throws {
        let unregistered = try T2Env(register: false)
        let (_, a) = unregistered.svc(360, [0x5000, 0, Env.scratch + 0x8000, Env.scratch + 0x8000, 0x0100_0000])
        #expect(a.carry && a.x[0] == 22)
        let t = try T2Env()
        let region = t.map(0x2_0000)
        let p = region + 0x1_0000
        #expect(t.svc(360, [0x5000, 0, p, p, 0]).1.x[0] == 22)  // no PTHREAD_START_CUSTOM
        #expect(t.svc(360, [0x5000, 0, p, p, 0x0900_0000]).1.x[0] == 22)  // QOSCLASS without a QoS
        #expect(!t.svc(360, [0x5000, 0, p, p, 0x0900_00FF | 0x1000]).1.carry)  // QOSCLASS utility
        // Pool exhausted: EAGAIN, nothing left behind.
        t.host.limit = t.host.starts.count
        let before = t.kernel.liveThreads.count
        let (_, e) = t.svc(360, [0x5000, 0, p, p, 0x0100_0000])
        #expect(e.carry && e.x[0] == 35)
        #expect(t.kernel.liveThreads.count == before)
        // No thread host at all.
        t.kernel.threadHost = nil
        #expect(t.svc(360, [0x5000, 0, p, p, 0x0100_0000]).1.x[0] == 35)
    }

    // MARK: bsdthread_terminate

    @Test func terminateFreesTheStackAndThePort() throws {
        let t = try T2Env()
        let (ctx, _) = t.createThread()
        let stack = t.map(0x8000)
        #expect(t.isMapped(stack))
        let (o, _) = t.svc(361, [stack, 0x8000, UInt64(ctx.portName), 0], context: ctx)
        #expect(o == .threadExit)
        #expect(!t.isMapped(stack))
        #expect(t.kernel.thread(port: ctx.portName) == nil && !ctx.isAlive)
        #expect(t.svc(328, [UInt64(ctx.portName), 0]).1.x[0] == 3)  // __pthread_kill: ESRCH
    }

    @Test func joinGateWakesTheJoinerAfterTheThreadIsGone() throws {
        let t = try T2Env()
        let (ctx, _) = t.createThread()
        let gate = Env.scratch + 0x100
        t.put32(ctx.portName, at: gate)
        // The joiner waits with UL_UNFAIR_LOCK on the gate whose value is a
        // live thread's port: no EOWNERDEAD, it blocks.
        let join = t.spawn { t.svc(515, [2 | Self.noErrno, gate, UInt64(ctx.portName), 0]).1.x[0] }
        #expect(t.eventually { t.blocked(t.main) })
        let (o, _) = t.svc(361, [0, 0, UInt64(ctx.portName), gate], context: ctx)
        #expect(o == .threadExit)
        #expect(join() == 0)
        #expect(t.u32(gate) == ctx.portName & ~3)
        // The gate value changed: a late joiner returns at once.
        #expect(t.x0(515, [2 | Self.noErrno, gate, UInt64(ctx.portName), 0]) == 0)
    }

    @Test func semaphoreFormSignalsAtExit() throws {
        let t = try T2Env()
        t.svc(0x7963_2003, [0x103, Env.scratch, 0, 0])
        let sem = t.u32(Env.scratch)
        let (ctx, _) = t.createThread()
        #expect(t.svc(361, [0, 0, UInt64(ctx.portName), UInt64(sem)], context: ctx).0 == .threadExit)
        #expect(t.kernel.semaphore(named: sem)?.count == 1)
    }

    @Test func mainThreadExitDoesNotEndTheProcess() throws {
        let t = try T2Env()
        let (ctx, _) = t.createThread()
        let mainStack = t.map(0x1_0000)
        #expect(t.svc(361, [mainStack, 0x1_0000, 0x203, 0]).0 == .threadExit)
        // The main stack stays reserved (PROT_NONE), not unmapped.
        #expect(t.isMapped(mainStack))
        #expect(t.kernel.lock.withLock { t.space.region(containing: mainStack)?.protection } == [])
        // The last thread's exit ends the process with status 0.
        #expect(t.svc(361, [0, 0, UInt64(ctx.portName), 0], context: ctx).0 == .exit(status: 0))
    }

    @Test func pthreadKillToAnotherThreadIsDropped() throws {
        let t = try T2Env()
        let (ctx, _) = t.createThread()
        let (o, f) = t.svc(328, [UInt64(ctx.portName), 15])
        #expect(o == .resume && !f.carry)
        #expect(t.env.sink.lines.contains { $0.contains("no cross-thread signal delivery") })
        #expect(t.svc(328, [0x9993, 15]).1.x[0] == 3)
    }

    // MARK: ulock

    @Test func waitAndWakeAcrossThreads() throws {
        let t = try T2Env()
        let w = Env.scratch + 0x200
        t.put32(0, at: w)
        let threads = (0..<3).map { _ in t.createThread().0 }
        let waits = threads.map { c in t.spawn { t.svc(515, [1 | Self.noErrno, w, 0, 0], context: c).1.x[0] } }
        #expect(t.eventually { threads.allSatisfy { t.blocked($0) } })
        // Wake one: it reports the 2 still waiting.
        #expect(t.x0(516, [1 | Self.noErrno, w, 0]) == 0)
        let firstDone = t.eventually { threads.filter { t.blocked($0) }.count == 2 }
        #expect(firstDone)
        // Wake all.
        #expect(t.x0(516, [1 | 0x100 | Self.noErrno, w, 0]) == 0)
        let results = waits.compactMap { $0() }
        #expect(results.count == 3)
        #expect(results.sorted() == [0, 0, 2])
        // Nobody waits now.
        #expect(errno(t.x0(516, [1 | Self.noErrno, w, 0])) == 2)
    }

    @Test func pingPongLosesNoWakeups() throws {
        let t = try T2Env()
        let w = Env.scratch + 0x300
        t.put32(0, at: w)
        let (other, _) = t.createThread()
        let rounds: UInt32 = 300
        @Sendable func waitFor(_ want: UInt32, _ c: ThreadContext) {
            while true {
                let v = t.u32(w)
                if v == want { return }
                _ = t.svc(515, [1 | Self.noErrno, w, UInt64(v), 0], context: c)
            }
        }
        let peer = t.spawn { () -> Bool in
            for i in 0..<rounds {
                waitFor(2 * i + 1, other)
                t.put32(2 * i + 2, at: w)
                t.svc(516, [1 | 0x100 | Self.noErrno, w, 0], context: other)
            }
            return true
        }
        for i in 0..<rounds {
            t.put32(2 * i + 1, at: w)
            t.svc(516, [1 | 0x100 | Self.noErrno, w, 0])
            waitFor(2 * i + 2, t.main)
        }
        #expect(peer() == true)
        #expect(t.u32(w) == 2 * rounds)
    }

    @Test func timeoutsAndErrors() throws {
        let t = try T2Env()
        let w = Env.scratch + 0x400
        t.put64(0, at: w)
        // µs and ns timeouts, and a mach-time deadline.
        #expect(errno(t.x0(515, [1 | Self.noErrno, w, 0, 2000])) == 60)
        #expect(errno(t.x0(544, [5 | Self.noErrno, w, 0, 2_000_000, 0])) == 60)
        let soon = MachTimebase.now() + MachTimebase.ticks(fromNanoseconds: 2_000_000)
        #expect(errno(t.x0(544, [1 | 0x0200_0000 | Self.noErrno, w, 0, soon, 0])) == 60)
        // Without ULF_NO_ERRNO: carry and errno.
        let (_, f) = t.svc(515, [1, w, 0, 1000])
        #expect(f.carry && f.x[0] == 60)
        // EINVAL: bad opcode, bad flags, address 0, misaligned.
        #expect(errno(t.x0(515, [4 | Self.noErrno, w, 0, 1])) == 22)
        #expect(errno(t.x0(515, [1 | 0x100 | Self.noErrno, w, 0, 1])) == 22)
        #expect(errno(t.x0(515, [1 | Self.noErrno, 0, 0, 1])) == 22)
        #expect(errno(t.x0(515, [5 | Self.noErrno, w + 4, 0, 1])) == 22)
        #expect(errno(t.x0(516, [1 | 0x200 | 0x100 | Self.noErrno, w, 0])) == 22)  // WAKE_THREAD + WAKE_ALL
        #expect(errno(t.x0(516, [2 | 0x200 | Self.noErrno, w, 0])) == 22)  // WAKE_THREAD + UNFAIR_LOCK
        #expect(errno(t.x0(516, [1 | 0x400 | Self.noErrno, w, 0])) == 22)  // ALLOW_NON_OWNER without UNFAIR_LOCK
        // Unfair lock: no owner thread → EOWNERDEAD; MACH_PORT_DEAD → waits; self → EDEADLK.
        t.put32(0x1234_5670, at: w)
        #expect(errno(t.x0(515, [2 | Self.noErrno, w, 0x1234_5670, 1000])) == 105)
        t.put32(0xFFFF_FFFC, at: w)
        #expect(errno(t.x0(515, [2 | Self.noErrno, w, 0xFFFF_FFFC, 1000])) == 60)
        t.put32(0x200, at: w)
        #expect(errno(t.x0(515, [2 | Self.noErrno, w, 0x200, 1000])) == 11)
        // Value changed: success at once.
        #expect(t.x0(515, [1 | Self.noErrno, w, 9, 0]) == 0)
    }

    @Test func opcodeMismatchWakeThreadAndOwnerRule() throws {
        let t = try T2Env()
        let w = Env.scratch + 0x500
        t.put64(0, at: w)
        let (a, _) = t.createThread()
        let (b, _) = t.createThread()
        let wa = t.spawn { t.svc(515, [1 | Self.noErrno, w, 0, 0], context: a).1.x[0] }
        #expect(t.eventually { t.blocked(a) })
        #expect(errno(t.x0(515, [5 | Self.noErrno, w, 0, 1000])) == 33)  // EDOM
        #expect(errno(t.x0(516, [5 | Self.noErrno, w, 0])) == 33)
        // WAKE_THREAD: b is not waiting → EALREADY; self → ESRCH; a → woken.
        #expect(errno(t.x0(516, [1 | 0x200 | Self.noErrno, w, UInt64(b.portName)])) == 37)
        #expect(errno(t.x0(516, [1 | 0x200 | Self.noErrno, w, 0x203])) == 3)
        #expect(t.x0(516, [1 | 0x200 | Self.noErrno, w, UInt64(a.portName)]) == 0)
        #expect(wa() == 0)

        // Unfair lock owned by a: b waits; a non-owner wake is a no-op.
        let lockWord = Env.scratch + 0x600
        t.put32(a.portName | 1, at: lockWord)
        let wb = t.spawn { t.svc(515, [2 | Self.noErrno, lockWord, UInt64(a.portName | 1), 0], context: b).1.x[0] }
        #expect(t.eventually { t.blocked(b) })
        #expect(t.x0(516, [2 | Self.noErrno, lockWord, 0]) == 0)
        Thread.sleep(forTimeInterval: 0.02)
        #expect(t.blocked(b))
        // The owner's wake hands it over.
        #expect(t.x0(516, [2 | Self.noErrno, lockWord, 0], context: a) == 0)
        #expect(wb() == 0)
        // ALLOW_NON_OWNER wakes from anyone.
        let wb2 = t.spawn { t.svc(515, [2 | Self.noErrno, lockWord, UInt64(a.portName | 1), 0], context: b).1.x[0] }
        #expect(t.eventually { t.blocked(b) })
        #expect(t.x0(516, [2 | 0x400 | Self.noErrno, lockWord, 0]) == 0)
        #expect(wb2() == 0)
    }

    // MARK: Mach semaphores

    func semaphore(_ t: T2Env, _ value: UInt64 = 0, at slot: UInt64 = 0) -> UInt64 {
        t.svc(0x7963_2003, [0x103, Env.scratch + 0x700 + slot, 0, value])
        return UInt64(t.u32(Env.scratch + 0x700 + slot))
    }

    @Test func semaphoreWaitBlocksUntilSignalled() throws {
        let t = try T2Env()
        let s = semaphore(t)
        let (a, _) = t.createThread()
        let (b, _) = t.createThread()
        let wa = t.spawn { t.x0(t.mach(-36), [s], context: a) }
        let wb = t.spawn { t.x0(t.mach(-36), [s], context: b) }
        #expect(t.eventually { t.blocked(a) && t.blocked(b) })
        // signal_thread picks b; a stays blocked.
        #expect(t.x0(t.mach(-35), [s, UInt64(b.portName)]) == 0)
        #expect(wb() == 0)
        #expect(t.blocked(a))
        #expect(t.x0(t.mach(-35), [s, UInt64(b.portName)]) == 24)  // not waiting
        #expect(t.x0(t.mach(-35), [s, 0x9993]) == 4)  // not a thread
        #expect(t.x0(t.mach(-33), [s]) == 0)
        #expect(wa() == 0)
        #expect(t.kernel.semaphore(named: UInt32(s))?.count == 0)
    }

    @Test func semaphoreSignalAllDestroyAndTimedWait() throws {
        let t = try T2Env()
        let s = semaphore(t)
        let threads = (0..<3).map { _ in t.createThread().0 }
        let waits = threads.map { c in t.spawn { t.x0(t.mach(-36), [s], context: c) } }
        #expect(t.eventually { threads.allSatisfy { t.blocked($0) } })
        #expect(t.x0(t.mach(-34), [s]) == 0)
        #expect(waits.compactMap { $0() } == [0, 0, 0])
        #expect(t.kernel.semaphore(named: UInt32(s))?.count == 0)
        // Timed wait: times out; a signal from another thread ends it early.
        #expect(t.x0(t.mach(-38), [s, 0, 3_000_000]) == 49)
        let tw = t.spawn { t.x0(t.mach(-38), [s, 5, 0], context: threads[0]) }
        #expect(t.eventually { t.blocked(threads[0]) })
        #expect(t.x0(t.mach(-33), [s]) == 0)
        #expect(tw() == 0)
        // Destroy wakes waiters with KERN_TERMINATED.
        let wd = t.spawn { t.x0(t.mach(-36), [s], context: threads[1]) }
        #expect(t.eventually { t.blocked(threads[1]) })
        #expect(t.x0(0x7963_2004, [0x103, s]) == 0)
        #expect(wd() == 37)
    }

    @Test func waitSignalIsAtomic() throws {
        let t = try T2Env()
        let w = semaphore(t, 0, at: 0), s = semaphore(t, 0, at: 4)
        let (a, _) = t.createThread()
        // a waits on w and signals s; main waits on s, then signals w.
        let wa = t.spawn { t.x0(t.mach(-37), [w, s], context: a) }
        #expect(t.x0(t.mach(-36), [s]) == 0)
        #expect(t.x0(t.mach(-33), [w]) == 0)
        #expect(wa() == 0)
        // Timed form with a poll timeout.
        #expect(t.x0(t.mach(-39), [w, s, 0, 0]) == 49)
        #expect(t.kernel.semaphore(named: UInt32(s))?.count == 1)
    }

    @Test func semwaitSignalAndThreadSwitch() throws {
        let t = try T2Env()
        let s = semaphore(t)
        let (a, _) = t.createThread()
        let wa = t.spawn { t.svc(334, [s, 0, 0, 0, 0, 0], context: a).1 }
        #expect(t.eventually { t.blocked(a) })
        t.svc(t.mach(-33), [s])
        let f = try #require(wa())
        #expect(!f.carry && f.x[0] == 0)
        // Untimed sleep with no semaphore ends on process exit.
        #expect(t.x0(t.mach(-61), [0, 0, 0]) == 0)
        #expect(t.x0(t.mach(-61), [0, 2, 1]) == 0)  // SWITCH_OPTION_WAIT 1 ms
        #expect(t.x0(t.mach(-59), [0, 0]) == 0)
        let sleeper = t.spawn { t.svc(334, [0, 0, 0, 0, 0, 0], context: a).0 }
        #expect(t.eventually { t.blocked(a) })
        t.svc(1, [7])  // exit(7) from main: the sleeper wakes with the exit
        #expect(sleeper() == .exit(status: 7))
    }
}
