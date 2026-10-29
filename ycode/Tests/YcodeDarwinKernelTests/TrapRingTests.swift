import Foundation
import Synchronization
import Testing
@testable import YcodeDarwinKernel

/// The per-thread trap ring that the blocked-thread report reads
/// (`YCODE_THREAD_REPORT_AT_S`, SIGUSR1) while the thread's own host thread
/// keeps recording traps, also on the paths that take no kernel lock.
@Suite struct TrapRingTests {
    @Test func keepsTheLastSixteenOldestFirst() {
        let ring = TrapRing()
        #expect(ring.entries.isEmpty)
        for i in 0..<5 { ring.record(UInt64(i), 0, 0, 0) }
        #expect(ring.entries.map(\.0) == [0, 1, 2, 3, 4])
        for i in 5..<40 { ring.record(UInt64(i), UInt64(i) * 2, UInt64(i) * 3, UInt64(i) * 4) }
        let e = ring.entries
        #expect(e.map(\.0) == Array(24..<40).map(UInt64.init))
        #expect(e.allSatisfy { $0.1 == $0.0 * 2 && $0.2 == $0.0 * 3 && $0.3 == $0.0 * 4 })
    }

    /// One writer records as fast as it can while readers take reports over
    /// and over (the second scheduled report of a long boot crashed when the
    /// ring was an array shifted by `removeFirst` under a reader's `map`).
    @Test func readsWhileTheOwnerRecords() {
        let ring = TrapRing()
        let stop = Atomic<Bool>(false)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var i: UInt64 = 0
            while !stop.load(ordering: .relaxed) {
                ring.record(i, i, i, i)
                i &+= 1
            }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(1)
        var reads = 0
        while Date() < deadline {
            let e = ring.entries
            #expect(e.count <= TrapRing.capacity)
            reads += 1
        }
        stop.store(true, ordering: .relaxed)
        done.wait()
        #expect(reads > 0)
        #expect(ring.entries.count == TrapRing.capacity)
    }
}
