import Foundation
import Testing
@testable import YcodeDarwinKernel

// The restore's thread starts (specs/simulator/snapshot.md §7 step 9, §12):
// every restored thread gets its vCPU before any of them runs. The vCPU pool
// is modelled: a start fails once the process has ended (the pool's
// `isEnding`) or its vCPUs are used up; a started thread runs on its own host
// thread, and one restored at an `exit` trap ends its process when it runs.

@Suite struct SnapshotRestoreStartTests {
    final class FakeProcess: @unchecked Sendable {
        let pid: Int32
        let capacity: Int
        private let lock = NSLock()
        private var _ended = false
        private var _used = 0
        private(set) var ranBeforeRelease = 0
        init(pid: Int32, capacity: Int = 64) {
            self.pid = pid
            self.capacity = capacity
        }
        var ended: Bool { lock.withLock { _ended } }
        func end() { lock.withLock { _ended = true } }
        /// The pool's start: nil when the process ended or no vCPU is left.
        func reserve() -> Int? {
            lock.withLock {
                guard !_ended, _used < capacity else { return nil }
                _used += 1
                return _used - 1
            }
        }
    }

    struct FakeThread: Sendable {
        let process: FakeProcess
        let id: Int
        /// Restored at its process's `exit` trap: it ends the process when it runs.
        let exits: Bool
    }

    /// Starts `t` on its own host thread: with a gate it waits there first
    /// (the restore hook); without one it runs at once, as the restore did
    /// before the gate. Running an exiting thread ends its process.
    static func start(_ t: FakeThread, gate: SnapshotRestoreStartGate?, ran: DispatchGroup) -> Int? {
        guard let index = t.process.reserve() else { return nil }
        ran.enter()
        let run: @Sendable () -> Void = {
            if t.exits { t.process.end() }
            ran.leave()
        }
        if let gate {
            Thread.detachNewThread {
                gate.waitForRelease()
                run()
            }
        } else {
            run()
        }
        return index
    }

    /// Process 7's first thread was caught at its `exit` trap; its other
    /// two threads come after it in the start order.
    static func scenario() -> (FakeProcess, FakeProcess, [FakeThread]) {
        let p1 = FakeProcess(pid: 1), p7 = FakeProcess(pid: 7)
        let threads = [FakeThread(process: p1, id: 1, exits: false), FakeThread(process: p7, id: 2, exits: true),
                       FakeThread(process: p7, id: 3, exits: false), FakeThread(process: p7, id: 4, exits: false),
                       FakeThread(process: p1, id: 5, exits: false)]
        return (p1, p7, threads)
    }

    @Test func withoutTheGateAnExitingThreadFailsTheRestore() {
        // The §12 failure, made deterministic: the thread runs before its
        // siblings are started, and the next start finds the pool ended.
        let (_, _, threads) = Self.scenario()
        let ran = DispatchGroup()
        #expect(throws: SnapshotError.self) {
            _ = try SnapshotRestoreStartGate.startAll(threads, start: { Self.start($0, gate: nil, ran: ran) },
                                                      processEnded: { _ in false },
                                                      describe: { "pid \($0.process.pid): no vCPU for thread \($0.id)" })
        }
    }

    @Test func withTheGateEveryThreadGetsAVCPUBeforeAnyRuns() throws {
        let (p1, p7, threads) = Self.scenario()
        let gate = SnapshotRestoreStartGate()
        let ran = DispatchGroup()
        let starts = try SnapshotRestoreStartGate.startAll(threads, start: { Self.start($0, gate: gate, ran: ran) },
                                                           processEnded: { $0.process.ended },
                                                           describe: { "pid \($0.process.pid): no vCPU for thread \($0.id)" })
        #expect(starts.started.map(\.thread.id) == [1, 2, 3, 4, 5])
        #expect(starts.skipped.isEmpty)
        #expect(!p7.ended)  // nothing ran yet
        gate.release()
        #expect(ran.wait(timeout: .now() + 5) == .success)
        #expect(p7.ended && !p1.ended)
        #expect(gate.isReleased)
    }

    @Test func threadsOfAProcessThatEndedAreSkipped() throws {
        let (_, p7, threads) = Self.scenario()
        p7.end()  // e.g. killed before its threads were started
        let gate = SnapshotRestoreStartGate()
        let ran = DispatchGroup()
        let starts = try SnapshotRestoreStartGate.startAll(threads, start: { Self.start($0, gate: gate, ran: ran) },
                                                           processEnded: { $0.process.ended },
                                                           describe: { "pid \($0.process.pid): no vCPU for thread \($0.id)" })
        gate.release()
        #expect(starts.started.map(\.thread.id) == [1, 5])
        #expect(starts.skipped.map(\.id) == [2, 3, 4])
        #expect(ran.wait(timeout: .now() + 5) == .success)
    }

    @Test func aPoolTooSmallForALiveProcessStillFails() {
        let p = FakeProcess(pid: 9, capacity: 2)
        let threads = (1...3).map { FakeThread(process: p, id: $0, exits: false) }
        let gate = SnapshotRestoreStartGate()
        defer { gate.release() }
        let ran = DispatchGroup()
        do {
            _ = try SnapshotRestoreStartGate.startAll(threads, start: { Self.start($0, gate: gate, ran: ran) },
                                                      processEnded: { $0.process.ended },
                                                      describe: { "pid \($0.process.pid): no vCPU for thread \($0.id)" })
            Issue.record("expected a failure")
        } catch let e as SnapshotError {
            #expect(e.message == "pid 9: no vCPU for thread 3")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

// A host file renamed while open is captured under its current name
// (snapshot.md §12.3: atomic saves, "x.tmp" renamed to "x" before close).
@Suite struct SnapshotRenamedFileTests {
    @Test func guestPathFollowsTheRename() {
        typealias C = KernelSnapshotCapture
        // Guest path = host path (the device directory).
        #expect(C.guestPath(of: "/dev/data/a/x", renamedFrom: "/dev/data/a/x.tmp", guestPath: "/dev/data/a/x.tmp") == "/dev/data/a/x")
        // A prefix that maps /private/tmp to DEV/data/tmp.
        #expect(C.guestPath(of: "/dev/data/tmp/sub/y", renamedFrom: "/dev/data/tmp/sub/y.tmp", guestPath: "/private/tmp/sub/y.tmp")
                == "/private/tmp/sub/y")
        // Moved out of the mapped directory: the guest path stays.
        #expect(C.guestPath(of: "/elsewhere/y", renamedFrom: "/dev/data/tmp/y.tmp", guestPath: "/private/tmp/y.tmp")
                == "/private/tmp/y.tmp")
    }

    @Test func currentHostPathFollowsARename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-snap-rename-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("x.tmp").path, new = dir.appendingPathComponent("x").path
        #expect(FileManager.default.createFile(atPath: old, contents: Data("hello".utf8)))
        let fd = open(old, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(rename(old, new) == 0)
        #if os(Linux)
        #expect(KernelSnapshotCapture.currentHostPath(fd) == new)
        #else
        #expect(KernelSnapshotCapture.currentHostPath(fd) == nil)
        #endif
        #expect(unlink(new) == 0)
        #expect(KernelSnapshotCapture.currentHostPath(fd) == nil)
    }
}
