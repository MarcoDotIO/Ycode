import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The background band (`YCODE_BG_BAND`, scheduling-policy.md §4.9,
/// boot-profile.md §20): a thread of class bg goes on after a trap only
/// while fewer than `cpus` guest threads are runnable; it waits, oldest
/// first, until one blocks, its class rises, or the bound ends the wait.
///
/// The tests call the band directly and leave its switch off, so that the
/// hooks of other suites' kernels (which run in parallel in this process)
/// never count their threads here.
extension KernelSwitchSuites {
@Suite(.serialized) struct BackgroundBandTests {
    /// Runs `body` with `cpus` places and the given bound, restoring both.
    func with(cpus: Int, backgroundCPUs: Int = Int.max, boundMs: UInt64 = 10_000, _ body: () throws -> Void) rethrows {
        let saved = (BackgroundBand.cpus, BackgroundBand.maxWaitNanoseconds, BackgroundBand.pollNanoseconds)
        let savedBackground = BackgroundBand.backgroundCPUs
        BackgroundBand.backgroundCPUs = backgroundCPUs
        defer { BackgroundBand.backgroundCPUs = savedBackground }
        BackgroundBand.cpus = cpus
        BackgroundBand.maxWaitNanoseconds = boundMs * 1_000_000
        BackgroundBand.pollNanoseconds = 20_000_000
        defer {
            (BackgroundBand.cpus, BackgroundBand.maxWaitNanoseconds, BackgroundBand.pollNanoseconds) = saved
        }
        #expect(BackgroundBand.total(BackgroundBand.runnable.load(ordering: .relaxed)) == 0)
        try body()
        #expect(BackgroundBand.total(BackgroundBand.runnable.load(ordering: .relaxed)) == 0)
        #expect(BackgroundBand.waiterCount.load(ordering: .relaxed) == 0)
    }

    let kernel = DarwinKernel(fileSystem: DarwinFileSystem(prefixes: [], console: { _, _ in }), pid: 100)

    func context(_ cls: Int, _ id: UInt64) -> ThreadContext {
        let c = ThreadContext(threadID: id, portName: 0x1003, vcpuIndex: 0, kind: .pthread)
        c.schedClassStore.store(cls, ordering: .relaxed)
        c.kernel = kernel
        return c
    }

    /// Carries a thread context and its kernel into a host thread (test only).
    final class Pair: @unchecked Sendable {
        let ctx: ThreadContext, kernel: DarwinKernel
        init(_ ctx: ThreadContext, _ kernel: DarwinKernel) { self.ctx = ctx; self.kernel = kernel }
    }

    /// A host thread that ends a trap as `ctx` (counted, or waiting at the
    /// gate), reports it went on, and stops being runnable when `release`
    /// is signalled.
    final class Runner: @unchecked Sendable {
        let wentOn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let wentOnAt = Atomic<UInt64>(0)

        init(_ ctx: ThreadContext, kernel: DarwinKernel) {
            let pair = Pair(ctx, kernel)
            Thread { [self] in
                BackgroundBand.afterTrap(pair.ctx, kernel: pair.kernel)
                wentOnAt.store(KernelClock.now(), ordering: .relaxed)
                wentOn.signal()
                release.wait()
                BackgroundBand.stopped()
                done.signal()
            }.start()
        }

        func finish() {
            release.signal()
            #expect(done.wait(timeout: .now() + 10) == .success)
        }
    }

    func waitForWaiters(_ n: Int) {
        let deadline = Date().addingTimeInterval(5)
        while BackgroundBand.waiterCount.load(ordering: .relaxed) < n && Date() < deadline { usleep(1000) }
    }

    @Test func aBackgroundThreadWaitsWhileTheCPUsAreFull() {
        with(cpus: 2) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            let b = Runner(context(SchedClass.interactive, 2), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(b.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [0, 0, 1, 1])
            let bg = Runner(context(SchedClass.background, 3), kernel: kernel)
            waitForWaiters(1)
            #expect(bg.wentOn.wait(timeout: .now() + 0.2) == .timedOut)
            // One of the two blocks: the background thread takes its place.
            a.finish()
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [1, 0, 0, 1])
            b.finish()
            bg.finish()
        }
    }

    /// `YCODE_BG_BAND_EASE_MS`: a place freed by a thread that blocks goes
    /// to a waiter only once the CPUs have not been full for the window.
    @Test func withAnEaseWindowAFreedPlaceWaitsForTheBurstToEase() {
        with(cpus: 2) {
            let saved = BackgroundBand.easeNanoseconds
            BackgroundBand.easeNanoseconds = 300_000_000
            defer { BackgroundBand.easeNanoseconds = saved }
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            let b = Runner(context(SchedClass.interactive, 2), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(b.wentOn.wait(timeout: .now() + 5) == .success)
            let bg = Runner(context(SchedClass.background, 3), kernel: kernel)
            waitForWaiters(1)
            let freed = KernelClock.now()
            a.finish()
            // Not at once: the CPUs were full a moment ago.
            #expect(bg.wentOn.wait(timeout: .now() + 0.15) == .timedOut)
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(bg.wentOnAt.load(ordering: .relaxed) &- freed >= 250_000_000)
            b.finish()
            bg.finish()
        }
    }

    @Test func aBackgroundThreadGoesOnWhenACPUIsFree() {
        with(cpus: 2) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            let bg = Runner(context(SchedClass.background, 2), kernel: kernel)
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [1, 0, 1, 0])
            a.finish()
            bg.finish()
        }
    }

    @Test func backgroundThreadsRunOnTheirOwnCPUsOnly() {
        with(cpus: 4, backgroundCPUs: 1) {
            let first = Runner(context(SchedClass.background, 1), kernel: kernel)
            #expect(first.wentOn.wait(timeout: .now() + 5) == .success)
            let second = Runner(context(SchedClass.background, 2), kernel: kernel)
            waitForWaiters(1)
            #expect(second.wentOn.wait(timeout: .now() + 0.2) == .timedOut)
            first.finish()
            #expect(second.wentOn.wait(timeout: .now() + 5) == .success)
            second.finish()
        }
    }

    @Test func waitersGoOnOldestFirst() {
        with(cpus: 1) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            let first = Runner(context(SchedClass.background, 2), kernel: kernel)
            waitForWaiters(1)
            let second = Runner(context(SchedClass.background, 3), kernel: kernel)
            waitForWaiters(2)
            a.finish()
            #expect(first.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(second.wentOn.wait(timeout: .now() + 0.2) == .timedOut)
            first.finish()
            #expect(second.wentOn.wait(timeout: .now() + 5) == .success)
            second.finish()
        }
    }

    @Test func aRaisedThreadLeavesTheGate() {
        with(cpus: 1) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            let ctx = context(SchedClass.background, 2)
            let bg = Runner(ctx, kernel: kernel)
            waitForWaiters(1)
            let raisedBefore = BackgroundBand.Stats.raised.load(ordering: .relaxed)
            // An inheritance push or a boost raised its class: it goes on at its new class.
            ctx.schedClassStore.store(SchedClass.utility, ordering: .relaxed)
            BackgroundBand.poke(ctx)
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.Stats.raised.load(ordering: .relaxed) == raisedBefore + 1)
            #expect(BackgroundBand.runnableByClass == [0, 1, 1, 0])
            a.finish()
            bg.finish()
        }
    }

    /// A synchronous request queued for the waiter's image (the sync-wait
    /// push, scheduling-policy.md §4.10) raises its host class: it goes on.
    @Test func aSyncWaitPushOnTheImageLetsItsWaitersGo() {
        with(cpus: 1) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            let bg = Runner(context(SchedClass.background, 2), kernel: kernel)
            waitForWaiters(1)
            #expect(bg.wentOn.wait(timeout: .now() + 0.2) == .timedOut)
            kernel.syncPushCounts.wrappingAdd(KernelLock.unit(SchedClass.default), ordering: .relaxed)
            defer { kernel.syncPushCounts.wrappingSubtract(KernelLock.unit(SchedClass.default), ordering: .relaxed) }
            BackgroundBand.poke(kernel: kernel)
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [0, 0, 2, 0])
            a.finish()
            bg.finish()
        }
    }

    @Test func theBoundEndsAWait() {
        with(cpus: 1, boundMs: 100) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            let start = KernelClock.now()
            let bg = Runner(context(SchedClass.background, 2), kernel: kernel)
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            let waited = bg.wentOnAt.load(ordering: .relaxed) &- start
            #expect(waited >= 100_000_000)
            a.finish()
            bg.finish()
        }
    }

    @Test func aBackgroundThreadIsPreemptedAtItsTrapEnd() {
        with(cpus: 1) {
            // The background thread runs alone, then a default thread takes
            // the only CPU: at its next trap end the background thread waits.
            let ctx = context(SchedClass.background, 1)
            let ran = DispatchSemaphore(value: 0), next = DispatchSemaphore(value: 0)
            let wentOnAgain = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
            let pair = Pair(ctx, kernel)
            Thread {
                BackgroundBand.afterTrap(pair.ctx, kernel: pair.kernel)
                ran.signal()
                next.wait()
                BackgroundBand.afterTrap(pair.ctx, kernel: pair.kernel)
                wentOnAgain.signal()
                finish.wait()
                BackgroundBand.stopped()
                wentOnAgain.signal()
            }.start()
            #expect(ran.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [1, 0, 0, 0])
            // A default thread becomes runnable while the CPU is taken (it is
            // not gated), then the background thread ends a trap.
            let a = Runner(context(SchedClass.default, 2), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            next.signal()
            waitForWaiters(1)
            #expect(wentOnAgain.wait(timeout: .now() + 0.2) == .timedOut)
            a.finish()
            #expect(wentOnAgain.wait(timeout: .now() + 5) == .success)
            finish.signal()
            #expect(wentOnAgain.wait(timeout: .now() + 5) == .success)
        }
    }

    @Test func aClassChangeMovesTheCount() {
        with(cpus: 4) {
            let ctx = context(SchedClass.utility, 1)
            let step = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            let pair = Pair(ctx, kernel)
            Thread {
                BackgroundBand.afterTrap(pair.ctx, kernel: pair.kernel)
                step.signal()
                go.wait()
                pair.ctx.schedClassStore.store(SchedClass.interactive, ordering: .relaxed)
                BackgroundBand.afterTrap(pair.ctx, kernel: pair.kernel)
                step.signal()
                go.wait()
                // Blocking in the kernel twice in a row counts once.
                BackgroundBand.stopped()
                BackgroundBand.stopped()
                step.signal()
            }.start()
            #expect(step.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [0, 1, 0, 0])
            go.signal()
            #expect(step.wait(timeout: .now() + 5) == .success)
            #expect(BackgroundBand.runnableByClass == [0, 0, 0, 1])
            go.signal()
            #expect(step.wait(timeout: .now() + 5) == .success)
        }
    }

    @Test func anEndingImageReleasesItsWaiters() {
        with(cpus: 1) {
            let a = Runner(context(SchedClass.default, 1), kernel: kernel)
            #expect(a.wentOn.wait(timeout: .now() + 5) == .success)
            let other = DarwinKernel(fileSystem: DarwinFileSystem(prefixes: [], console: { _, _ in }), pid: 101)
            let ctx = ThreadContext(threadID: 2, portName: 0x1003, vcpuIndex: 0, kind: .pthread)
            ctx.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            ctx.kernel = other
            let bg = Runner(ctx, kernel: other)
            waitForWaiters(1)
            other.lock.withLock { other.endImage(.exit(status: 0)) }
            BackgroundBand.poke(kernel: other)
            #expect(bg.wentOn.wait(timeout: .now() + 5) == .success)
            a.finish()
            bg.finish()
        }
    }
}
}
