import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `KernelLock` and `WaitQueue` with real host threads (stage4a-contract.md §2, §8).
@Suite(.serialized) struct KernelSyncTests {
    final class Shared: @unchecked Sendable {
        let lock = KernelLock()
        let queue = WaitQueue()
        var counter = 0
        var results: [WaitResult] = []
    }

    func spawn(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread { body(); done.signal() }.start()
        return done
    }

    @Test func lockIsMutualExclusionAndReentrant() {
        let s = Shared()
        let threads = (0..<8).map { _ in
            spawn { for _ in 0..<2000 { s.lock.withLock { s.lock.withLock { s.counter += 1 } } } }
        }
        for t in threads { #expect(t.wait(timeout: .now() + 10) == .success) }
        #expect(s.counter == 16000)
        #expect(!s.lock.isHeldByCurrentThread)
        s.lock.withLock { #expect(s.lock.isHeldByCurrentThread) }
    }

    @Test func waitReleasesTheLockAndWakeCountsWaiters() {
        let s = Shared()
        let waiters = (0..<4).map { _ in
            spawn { s.lock.withLock { let r = s.queue.wait(on: s.lock, deadline: nil); s.results.append(r) } }
        }
        // All four can be waiting at once only if wait releases the lock.
        let deadline = Date().addingTimeInterval(5)
        while s.lock.withLock({ s.queue.count }) < 4 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        #expect(s.lock.withLock { s.queue.count } == 4)
        #expect(s.lock.withLock { s.queue.wake(count: 3) } == 3)
        Thread.sleep(forTimeInterval: 0.02)
        #expect(s.lock.withLock { s.queue.count } == 1)
        #expect(s.lock.withLock { s.queue.wake(count: 5) } == 1)
        for w in waiters { #expect(w.wait(timeout: .now() + 5) == .success) }
        #expect(s.results == [.woken, .woken, .woken, .woken])
        #expect(s.lock.withLock { s.queue.wake(count: 1) } == 0)
    }

    @Test func deadlinesTimeOut() {
        let s = Shared()
        let start = KernelClock.now()
        let r = s.lock.withLock { s.queue.wait(on: s.lock, deadline: KernelClock.deadline(afterNanoseconds: 20_000_000)) }
        let elapsed = KernelClock.now() - start
        #expect(r == .timedOut)
        #expect(elapsed >= 19_000_000 && elapsed < 2_000_000_000)
        // A past deadline returns at once.
        #expect(s.lock.withLock { s.queue.wait(on: s.lock, deadline: 1) } == .timedOut)
        #expect(s.lock.withLock { s.queue.isEmpty })
    }

    @Test func noLostWakeupsUnderRaces() {
        // Producer/consumer through a counter: every consumed item was produced,
        // and nobody sleeps forever.
        let s = Shared()
        let consumers = (0..<4).map { _ in
            spawn {
                for _ in 0..<500 {
                    s.lock.withLock {
                        while s.counter == 0 { _ = s.queue.wait(on: s.lock, deadline: nil) }
                        s.counter -= 1
                    }
                }
            }
        }
        let producers = (0..<4).map { _ in
            spawn { for _ in 0..<500 { s.lock.withLock { s.counter += 1; s.queue.wake(count: 1) } } }
        }
        for t in producers + consumers { #expect(t.wait(timeout: .now() + 20) == .success) }
        #expect(s.counter == 0)
    }

    @Test func beforeSleepingRunsAfterQueueing() {
        let s = Shared()
        // The waiter wakes itself from beforeSleeping: no lost wake.
        let r = s.lock.withLock {
            s.queue.wait(on: s.lock, deadline: nil, tag: 7, beforeSleeping: { s.queue.wake(count: 1) })
        }
        #expect(r == .woken)
    }

    @Test func wakeByTagAndContext() {
        let s = Shared()
        let a = ThreadContext(threadID: 10, portName: 0x1003, vcpuIndex: 1, kind: .pthread)
        let b = ThreadContext(threadID: 11, portName: 0x1103, vcpuIndex: 2, kind: .pthread)
        let ta = spawn { s.lock.withLock(context: a) { s.results.append(s.queue.wait(on: s.lock, deadline: nil, tag: 1, beforeSleeping: nil)) } }
        let tb = spawn { s.lock.withLock(context: b) { _ = s.queue.wait(on: s.lock, deadline: nil, tag: 2, beforeSleeping: nil) } }
        let end = Date().addingTimeInterval(5)
        while s.lock.withLock({ s.queue.count }) < 2 && Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        s.lock.withLock {
            #expect(a.blockedInKernel && b.blockedInKernel)
            #expect(s.queue.contains(b))
            #expect(s.queue.wake { _, tag in tag == 2 } == 1)
        }
        #expect(tb.wait(timeout: .now() + 5) == .success)
        s.lock.withLock {
            #expect(!b.blockedInKernel)
            #expect(s.queue.wake { c, _ in c === a } == 1)
        }
        #expect(ta.wait(timeout: .now() + 5) == .success)
        #expect(s.results == [.woken])
    }

    @Test func interruptAndTerminate() {
        let s = Shared()
        let a = ThreadContext(threadID: 10, portName: 0x1003, vcpuIndex: 1, kind: .pthread)
        let ta = spawn { s.lock.withLock(context: a) { s.results.append(s.queue.wait(on: s.lock, deadline: nil)) } }
        let other = WaitQueue()
        let tb = spawn { s.lock.withLock { s.results.append(other.wait(on: s.lock, deadline: nil)) } }
        let end = Date().addingTimeInterval(5)
        while s.lock.withLock({ s.queue.count + other.count }) < 2 && Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        #expect(s.lock.withLock { s.lock.interrupt(a) })
        #expect(ta.wait(timeout: .now() + 5) == .success)
        s.lock.withLock { s.lock.terminate() }
        #expect(tb.wait(timeout: .now() + 5) == .success)
        #expect(s.results == [.interrupted, .interrupted])
        // After terminate every wait ends at once.
        #expect(s.lock.withLock { s.queue.wait(on: s.lock, deadline: nil) } == .interrupted)
    }

    @Test func lockKeepsTheCurrentContextAcrossWaits() {
        let s = Shared()
        let a = ThreadContext(threadID: 10, portName: 0x1003, vcpuIndex: 1, kind: .pthread)
        let seen = T2Box<Bool>()
        let t = spawn {
            s.lock.withLock(context: a) {
                _ = s.queue.wait(on: s.lock, deadline: KernelClock.deadline(afterNanoseconds: 30_000_000))
                seen.value = s.lock.currentContext === a
            }
        }
        // Another context takes the lock while `a` sleeps.
        Thread.sleep(forTimeInterval: 0.01)
        s.lock.withLock(context: ThreadContext(threadID: 11, portName: 0x1103, vcpuIndex: 2, kind: .pthread)) {
            #expect(s.lock.currentContext?.threadID == 11)
        }
        #expect(t.wait(timeout: .now() + 5) == .success)
        #expect(seen.value == true)
    }
}
