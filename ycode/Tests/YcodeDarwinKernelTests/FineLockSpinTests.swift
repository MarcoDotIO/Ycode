import Foundation
import Testing
@testable import YcodeDarwinKernel

/// `YCODE_FINE_LOCK_SPIN_US` (`boot-profile.md` §27.2): a thread that finds a
/// fine lock taken watches it for a bounded time before it sleeps. Mutual
/// exclusion holds, short holds are taken while spinning, and a long hold
/// still ends in a sleep.
extension KernelSwitchSuites {
@Suite(.serialized) struct FineLockSpinTests {
    final class Shared: @unchecked Sendable {
        let root = KernelLock(ipcLocks: true)
        let fine: KernelLock
        var counter = 0
        var inside = 0
        var overlaps = 0
        init() { fine = KernelLock(fineLockOf: root, level: 2, name: "test port lock") }
    }

    func with(_ microseconds: UInt64, _ body: () -> Void) {
        let saved = KernelLock.fineSpinNanoseconds
        KernelLock.fineSpinNanoseconds = microseconds * 1000
        defer { KernelLock.fineSpinNanoseconds = saved }
        body()
    }

    @Test func spinningKeepsMutualExclusion() {
        with(50) {
            let s = Shared()
            let spins0 = KernelLock.spinAcquisitions.load(ordering: .relaxed)
            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                Thread {
                    for _ in 0..<5000 {
                        s.fine.withLock {
                            s.inside += 1
                            if s.inside != 1 { s.overlaps += 1 }
                            s.counter += 1
                            s.inside -= 1
                        }
                    }
                    group.leave()
                }.start()
            }
            #expect(group.wait(timeout: .now() + 60) == .success)
            #expect(s.counter == 40_000)
            #expect(s.overlaps == 0)
            // Some contended acquisitions were won by the spin.
            #expect(KernelLock.spinAcquisitions.load(ordering: .relaxed) > spins0)
        }
    }

    @Test func aLongHoldEndsTheSpinInASleep() {
        with(20) {
            let s = Shared()
            let failures0 = KernelLock.spinFailures.load(ordering: .relaxed)
            let held = DispatchSemaphore(value: 0)
            let holder = DispatchSemaphore(value: 0)
            Thread {
                s.fine.withLock {
                    held.signal()
                    Thread.sleep(forTimeInterval: 0.05)  // 50 ms: far past the spin
                    s.counter += 1
                }
                holder.signal()
            }.start()
            held.wait()
            s.fine.withLock { s.counter += 1 }
            #expect(holder.wait(timeout: .now() + 10) == .success)
            #expect(s.counter == 2)
            #expect(KernelLock.spinFailures.load(ordering: .relaxed) > failures0)
        }
    }
}
}
