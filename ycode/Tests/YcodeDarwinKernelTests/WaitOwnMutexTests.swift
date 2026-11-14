import Foundation
import Testing
@testable import YcodeDarwinKernel

/// `YCODE_WAIT_OWN_MUTEX` (`mach-ipc-locking.md` §4.4, `boot-profile.md` §27):
/// a waiter on a fine lock's queue sleeps on a mutex of its own. No wakeup is
/// lost, with the hand-over in one hold, many waiters, timeouts, and wakes
/// that race the waiter going to sleep; L0 queues are unchanged.
extension KernelSwitchSuites {
@Suite(.serialized) struct WaitOwnMutexTests {
    final class Shared: @unchecked Sendable {
        let root = KernelLock(ipcLocks: true)
        let fine: KernelLock
        let ping = WaitQueue()
        let pong = WaitQueue()
        var turn = 0
        var woken = 0
        var timedOut = 0
        init() { fine = KernelLock(fineLockOf: root, level: 1, name: "test event lock") }
    }

    func spawn(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread { body(); done.signal() }.start()
        return done
    }

    func with(_ on: Bool, _ body: () -> Void) {
        let saved = WaitQueue.Waiter.ownMutexEnabled
        WaitQueue.Waiter.ownMutexEnabled = on
        defer { WaitQueue.Waiter.ownMutexEnabled = saved }
        body()
    }

    @Test(arguments: [false, true]) func pingPongOnAFineLockLosesNoWakeup(own: Bool) {
        with(own) {
            let s = Shared()
            let rounds = 3000
            let a = spawn {
                for _ in 0..<rounds {
                    s.fine.withLock {
                        while s.turn != 0 { _ = s.ping.wait(on: s.fine, deadline: nil) }
                        s.turn = 1
                        s.pong.wakeAll()
                    }
                }
            }
            let b = spawn {
                for _ in 0..<rounds {
                    s.fine.withLock {
                        while s.turn != 1 { _ = s.pong.wait(on: s.fine, deadline: nil) }
                        s.turn = 0
                        s.woken += 1
                        s.ping.wakeAll()
                    }
                }
            }
            #expect(a.wait(timeout: .now() + 60) == .success)
            #expect(b.wait(timeout: .now() + 60) == .success)
            #expect(s.woken == rounds)
        }
    }

    @Test func manyWaitersWokenOnceAndTimeoutsReturn() {
        with(true) {
            let s = Shared()
            let waiters = (0..<24).map { _ in
                spawn { s.fine.withLock { if s.ping.wait(on: s.fine, deadline: nil) == .woken { s.woken += 1 } } }
            }
            let deadline = Date().addingTimeInterval(10)
            while s.fine.withLock({ s.ping.count }) < 24 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            // Wake them in two batches: a limited wake takes exactly that many.
            let queued = s.fine.withLock { s.ping.count }
            let first = s.fine.withLock { s.ping.wake(count: 10) }
            let rest = s.fine.withLock { s.ping.wakeAll() }
            #expect(queued == 24 && first == 10 && rest == 14, "queued \(queued), woken \(first) then \(rest)")
            for w in waiters { #expect(w.wait(timeout: .now() + 10) == .success) }
            #expect(s.woken == 24)
            let r = s.fine.withLock { s.pong.wait(on: s.fine, deadline: KernelClock.deadline(afterNanoseconds: 5_000_000)) }
            #expect(r == .timedOut)
            #expect(s.fine.withLock { s.pong.count } == 0)
        }
    }

    @Test func wakesRacingTheSleepAreNotLost() {
        with(true) {
            let s = Shared()
            let rounds = 2000
            // The waiter's deadline is short, so some wakes land just after a
            // timeout began and some just before the sleep: each round ends
            // either woken or timed out, never stuck, and a woken result is
            // never reported twice.
            let waiter = spawn {
                for _ in 0..<rounds {
                    let r = s.fine.withLock { s.ping.wait(on: s.fine, deadline: KernelClock.deadline(afterNanoseconds: 20_000)) }
                    if r == .woken { s.woken += 1 } else { s.timedOut += 1 }
                }
            }
            let waker = spawn {
                for _ in 0..<(rounds * 4) {
                    s.fine.withLock { _ = s.ping.wakeAll() }
                }
            }
            #expect(waiter.wait(timeout: .now() + 60) == .success)
            #expect(waker.wait(timeout: .now() + 60) == .success)
            #expect(s.woken + s.timedOut == rounds)
            #expect(s.fine.withLock { s.ping.count } == 0)
        }
    }

    @Test func kernelLockQueuesKeepTheirMutex() {
        with(true) {
            let s = Shared()
            let root = s.root
            let q = s.ping
            let done = spawn { root.withLock { if q.wait(on: root, deadline: KernelClock.deadline(afterNanoseconds: 5_000_000_000)) == .woken { s.woken = 1 } } }
            let deadline = Date().addingTimeInterval(5)
            while root.withLock({ q.count }) < 1 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            root.withLock { _ = q.wakeAll() }
            #expect(done.wait(timeout: .now() + 10) == .success)
            #expect(s.woken == 1)
        }
    }
}
}
