import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The direct hand-off of a workloop sync wake (`YCODE_SYNC_HANDOFF`,
/// boot-profile.md §16): the waker pins the woken host thread to its CPU
/// before the signal, and every pin is undone once the wait returns; plain
/// wakes never pin; no wakeup is lost.
extension KernelSwitchSuites {
@Suite(.serialized) struct SyncHandoffTests {
    final class Calls: @unchecked Sendable {
        let mutex = NSLock()
        var pins: [Int32] = []
        var restores: [Int32] = []
        func record(_ tid: Int32, _ cpu: Int32?) {
            mutex.lock()
            if cpu == nil { restores.append(tid) } else { pins.append(tid) }
            mutex.unlock()
        }
    }

    final class Shared: @unchecked Sendable {
        let lock = KernelLock()
        let queue = WaitQueue()
        var woken = 0
        /// The host thread ids of this test's own waiters: other suites run
        /// in the same process and their hand-off wakes reach the hook too.
        var waiterTIDs: Set<Int32> = []
    }

    func spawn(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread { body(); done.signal() }.start()
        return done
    }

    func waitForWaiters(_ s: Shared, _ n: Int) {
        let deadline = Date().addingTimeInterval(5)
        while s.lock.withLock({ s.queue.count }) < n && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }

    @Test(arguments: [false, true]) func everyPinIsUndoneAndNoWakeIsLost(deferred: Bool) {
        let calls = Calls()
        let savedDeferred = KernelLock.wakeAfterUnlock
        KernelLock.wakeAfterUnlock = deferred
        SyncHandoff.pinHook = { calls.record($0, $1) }
        defer {
            SyncHandoff.pinHook = nil
            KernelLock.wakeAfterUnlock = savedDeferred
        }
        let s = Shared()
        let rounds = 200
        for _ in 0..<rounds {
            let w = spawn {
                let tid = SyncHandoff.currentTID()
                s.lock.withLock {
                    s.waiterTIDs.insert(tid)
                    if s.queue.wait(on: s.lock, deadline: nil) == .woken { s.woken += 1 }
                }
            }
            waitForWaiters(s, 1)
            s.lock.withLock { _ = s.queue.wakeAllHandingOff() }
            #expect(w.wait(timeout: .now() + 10) == .success)
        }
        #expect(s.woken == rounds)
        calls.mutex.lock()
        defer { calls.mutex.unlock() }
        // A pin either happened before the wait returned (the waiter undid
        // it) or after (the waker undid it): pins and restores pair up. A
        // waker that finds the wait already returned skips its pin (with a
        // wake delivered after the unlock the waiter can get there first),
        // so a round has at most one pin, not exactly one.
        let pins = calls.pins.filter(s.waiterTIDs.contains)
        let restores = calls.restores.filter(s.waiterTIDs.contains)
        #expect(pins.count <= rounds && pins.count > 0)
        #expect(restores.count == pins.count)
        #expect(Set(pins) == Set(restores))
    }

    @Test func plainWakesDoNotPin() {
        let calls = Calls()
        SyncHandoff.pinHook = { calls.record($0, $1) }
        defer { SyncHandoff.pinHook = nil }
        let s = Shared()
        let waiters = (0..<4).map { _ in spawn { s.lock.withLock { _ = s.queue.wait(on: s.lock, deadline: nil) } } }
        waitForWaiters(s, 4)
        s.lock.withLock { _ = s.queue.wakeAll() }
        for w in waiters { #expect(w.wait(timeout: .now() + 10) == .success) }
        calls.mutex.lock()
        defer { calls.mutex.unlock() }
        #expect(calls.pins.isEmpty && calls.restores.isEmpty)
    }

    @Test func aLatePinIsUndoneByTheWaker() {
        let calls = Calls()
        SyncHandoff.pinHook = { calls.record($0, $1) }
        defer { SyncHandoff.pinHook = nil }
        // The waiter's wait returned before its waker pinned it.
        let state = Atomic<Int>(0)
        SyncHandoff.waitReturned(tid: 42, state: state)
        SyncHandoff.pin(tid: 42, state: state)
        #expect(calls.mutex.withLock { calls.pins.isEmpty && calls.restores.isEmpty })   // state 2: nothing to pin
        // A pin before the wait returns: the waiter undoes it.
        let raced = Atomic<Int>(0)
        SyncHandoff.pin(tid: 43, state: raced)
        #expect(calls.mutex.withLock { calls.pins == [43] && calls.restores.isEmpty })
        #expect(raced.load(ordering: .relaxed) == SyncHandoff.pinned)
        SyncHandoff.waitReturned(tid: 43, state: raced)
        #expect(calls.mutex.withLock { calls.restores == [43] })
    }
}
}
