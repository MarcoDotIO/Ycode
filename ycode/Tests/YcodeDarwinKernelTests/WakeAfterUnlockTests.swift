import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `YCODE_WAKE_AFTER_UNLOCK` (thread-latency.md §4): wakeups made under the
/// kernel lock are delivered after it is released; none is lost, also with
/// many wakers and waiters, timeouts, and a waker that waits itself.
@Suite(.serialized) struct WakeAfterUnlockTests {
    final class Shared: @unchecked Sendable {
        let lock = KernelLock()
        let ping = WaitQueue()
        let pong = WaitQueue()
        var turn = 0
        var woken = 0
    }

    func spawn(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread { body(); done.signal() }.start()
        return done
    }

    @Test(arguments: [false, true]) func pingPongLosesNoWakeup(deferred: Bool) {
        let saved = KernelLock.wakeAfterUnlock
        KernelLock.wakeAfterUnlock = deferred
        defer { KernelLock.wakeAfterUnlock = saved }
        let s = Shared()
        let rounds = 2000
        // Each side waits for its turn, then hands it over and wakes the
        // other side while still holding the lock; the hand-over that
        // follows a wake makes the waker sleep in the same hold.
        let a = spawn {
            for _ in 0..<rounds {
                s.lock.withLock {
                    while s.turn != 0 { _ = s.ping.wait(on: s.lock, deadline: nil) }
                    s.turn = 1
                    s.pong.wakeAll()
                }
            }
        }
        let b = spawn {
            for _ in 0..<rounds {
                s.lock.withLock {
                    while s.turn != 1 { _ = s.pong.wait(on: s.lock, deadline: nil) }
                    s.turn = 0
                    s.woken += 1
                    s.ping.wakeAll()
                }
            }
        }
        #expect(a.wait(timeout: .now() + 30) == .success)
        #expect(b.wait(timeout: .now() + 30) == .success)
        #expect(s.woken == rounds)
    }

    @Test func manyWaitersAllWokenAndTimeoutsStillWork() {
        let saved = KernelLock.wakeAfterUnlock
        KernelLock.wakeAfterUnlock = true
        defer { KernelLock.wakeAfterUnlock = saved }
        let s = Shared()
        let waiters = (0..<16).map { _ in
            spawn { s.lock.withLock { if s.ping.wait(on: s.lock, deadline: nil) == .woken { s.woken += 1 } } }
        }
        let deadline = Date().addingTimeInterval(5)
        while s.lock.withLock({ s.ping.count }) < 16 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        s.lock.withLock { s.ping.wakeAll() }
        for w in waiters { #expect(w.wait(timeout: .now() + 10) == .success) }
        #expect(s.woken == 16)
        let r = s.lock.withLock { s.pong.wait(on: s.lock, deadline: KernelClock.deadline(afterNanoseconds: 5_000_000)) }
        #expect(r == .timedOut)
    }
}
