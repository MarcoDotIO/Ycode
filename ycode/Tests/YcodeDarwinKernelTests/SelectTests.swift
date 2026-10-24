import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// select (BSD 93 / 407) and pselect (394 / 395): `Select.swift`,
// `specs/simulator/select.md`. Adapted from the speed analyst S's prototype
// tests.

@Suite(.serialized) struct SelectTests {
    static let readSet = DEnv.scratch + 0x6000
    static let writeSet = DEnv.scratch + 0x6100
    static let exceptSet = DEnv.scratch + 0x6200
    static let timeval = DEnv.scratch + 0x6300
    static let maskVA = DEnv.scratch + 0x6400

    func setBits(_ e: DEnv, at va: UInt64, _ fds: [Int32], words: Int = 2) {
        var w = [UInt32](repeating: 0, count: words)
        for fd in fds { w[Int(fd) / 32] |= 1 << UInt32(fd % 32) }
        var b: [UInt8] = []
        for v in w { b.appendLE(v) }
        e.put(b, at: va)
    }

    func bits(_ e: DEnv, at va: UInt64) -> UInt32 { e.u32(va) }

    /// A `struct timeval` (select).
    func timeout(_ e: DEnv, seconds: Int64, micros: Int32) -> UInt64 {
        var b: [UInt8] = []
        b.appendLE(seconds)
        b.appendLE(micros)
        b.appendLE(Int32(0))
        e.put(b, at: Self.timeval)
        return Self.timeval
    }

    /// A `struct timespec` (pselect).
    func timespec(_ e: DEnv, seconds: Int64, nanos: Int64) -> UInt64 {
        var b: [UInt8] = []
        b.appendLE(seconds)
        b.appendLE(nanos)
        e.put(b, at: Self.timeval)
        return Self.timeval
    }

    @Test func sleepsForTheTimeoutWithNoDescriptors() throws {
        let e = try DEnv()
        let start = Date()
        let r = e.call(93, [0, 0, 0, 0, timeout(e, seconds: 0, micros: 50_000)])
        #expect(r.value == 0)
        #expect(Date().timeIntervalSince(start) >= 0.045)
        // select_nocancel is the same call.
        #expect(e.call(407, [0, 0, 0, 0, timeout(e, seconds: 0, micros: 1000)]).value == 0)
        // pselect and pselect_nocancel take a timespec.
        let p0 = Date()
        #expect(e.call(394, [0, 0, 0, 0, timespec(e, seconds: 0, nanos: 30_000_000), 0]).value == 0)
        #expect(Date().timeIntervalSince(p0) >= 0.025)
        #expect(e.call(395, [0, 0, 0, 0, timespec(e, seconds: 0, nanos: 0), 0]).value == 0)
    }

    @Test func pipeReadinessAndWriteBack() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        // Nothing to read, poll: 0 and the read set cleared; the write end is writable.
        setBits(e, at: Self.readSet, [r])
        setBits(e, at: Self.writeSet, [w])
        setBits(e, at: Self.exceptSet, [r, w])
        let poll = timeout(e, seconds: 0, micros: 0)
        #expect(e.call(93, [UInt64(w) + 1, Self.readSet, Self.writeSet, Self.exceptSet, poll]).value == 1)
        #expect(bits(e, at: Self.readSet) == 0)
        #expect(bits(e, at: Self.writeSet) == 1 << UInt32(w))
        #expect(bits(e, at: Self.exceptSet) == 0)
        // Data: readable.
        #expect(e.write(w, "x").value == 1)
        setBits(e, at: Self.readSet, [r])
        #expect(e.call(93, [UInt64(r) + 1, Self.readSet, 0, 0, poll]).value == 1)
        #expect(bits(e, at: Self.readSet) == 1 << UInt32(r))
        // Bits at or past nd are not looked at.
        setBits(e, at: Self.readSet, [r])
        #expect(e.call(93, [UInt64(r), Self.readSet, 0, 0, poll]).value == 0)
        // The same descriptor in both sets counts twice.
        setBits(e, at: Self.readSet, [r])
        setBits(e, at: Self.writeSet, [w, r])
        #expect(e.call(93, [UInt64(w) + 1, Self.readSet, Self.writeSet, 0, poll]).value == 2)
        // The read end of a pipe is not writable.
        #expect(bits(e, at: Self.writeSet) == 1 << UInt32(w))
    }

    @Test func onlyTheWordsBelowNDAreWritten() throws {
        let e = try DEnv()
        let (r, _) = e.pipe()
        // Word 1 (descriptors 32…63) is past nd: it keeps its bits.
        setBits(e, at: Self.readSet, [r, 40])
        #expect(e.call(93, [UInt64(r) + 1, Self.readSet, 0, 0, timeout(e, seconds: 0, micros: 0)]).value == 0)
        #expect(bits(e, at: Self.readSet) == 0)
        #expect(bits(e, at: Self.readSet + 4) == 1 << 8)
    }

    @Test func badDescriptorAndBadTimeout() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        e.call(6, [UInt64(w)])
        setBits(e, at: Self.readSet, [r, w])
        let poll = timeout(e, seconds: 0, micros: 0)
        // w (4) is past the highest open descriptor (r, 3): its bit is
        // ignored; r is at end of file, which is ready.
        #expect(r == 3 && w == 4)
        #expect(e.call(93, [UInt64(w) + 1, Self.readSet, 0, 0, poll]).value == 1)
        #expect(e.call(93, [UInt64(r) + 1, 0, 0, 0, timeout(e, seconds: 0, micros: 1_000_000)]).errno == 22)
        #expect(e.call(93, [UInt64(r) + 1, 0, 0, 0, timeout(e, seconds: -1, micros: 0)]).errno == 22)
        #expect(e.call(93, [UInt64(r) + 1, 0, 0, 0, timeout(e, seconds: 100_000_001, micros: 0)]).errno == 22)
        #expect(e.call(93, [UInt64(bitPattern: -1), 0, 0, 0, poll]).errno == 22)
        #expect(e.call(394, [0, 0, 0, 0, timespec(e, seconds: 0, nanos: 1_000_000_000), 0]).errno == 22)
        // A closed descriptor below an open one: EBADF.
        let (r2, w2) = e.pipe()
        e.call(6, [UInt64(r2)])
        setBits(e, at: Self.readSet, [r2])
        #expect(e.call(93, [UInt64(w2) + 1, Self.readSet, 0, 0, timeout(e, seconds: 0, micros: 0)]).errno == 9)
    }

    @Test func blockedSelectIsWokenByAWrite() throws {
        let e = try DEnv()
        let (r, w) = e.pipe()
        setBits(e, at: Self.readSet, [r])
        let waiter = HostThread { e.call(93, [UInt64(r) + 1, Self.readSet, 0, 0, 0]) }
        Thread.sleep(forTimeInterval: 0.15)
        #expect(waiter.result == nil)  // still blocked
        #expect(e.write(w, "wake").value == 4)
        let got = try #require(waiter.wait())
        #expect(got.value == 1)
        #expect(bits(e, at: Self.readSet) == 1 << UInt32(r))
    }

    @Test func blockedSelectTimesOutAndClearsTheSets() throws {
        let e = try DEnv()
        let (r, _) = e.pipe()
        setBits(e, at: Self.readSet, [r])
        let start = Date()
        #expect(e.call(93, [UInt64(r) + 1, Self.readSet, 0, 0, timeout(e, seconds: 0, micros: 40_000)]).value == 0)
        #expect(Date().timeIntervalSince(start) >= 0.035)
        #expect(bits(e, at: Self.readSet) == 0)
    }

    @Test func blockedSelectIsInterrupted() throws {
        let e = try DEnv()
        let (r, _) = e.pipe()
        setBits(e, at: Self.readSet, [r])
        let waiter = HostThread { e.call(93, [UInt64(r) + 1, Self.readSet, 0, 0, 0]) }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(waiter.result == nil)
        #expect(e.kernel.lock.withLock { e.kernel.lock.interrupt(e.kernel.mainThread) })
        let got = try #require(waiter.wait())
        #expect(got.errno == 4)  // EINTR
        // The set is not written on EINTR.
        #expect(bits(e, at: Self.readSet) == 1 << UInt32(r))
    }

    @Test func hostFilesAreAlwaysReady() throws {
        let e = try DEnv()
        let path = e.writable + "/f"
        e.putString(path, at: DEnv.scratch + 0x7000)
        let fd = try #require(e.call(5, [DEnv.scratch + 0x7000, 0x202, 0o644]).value)  // O_RDWR | O_CREAT
        setBits(e, at: Self.readSet, [Int32(fd)])
        setBits(e, at: Self.writeSet, [Int32(fd)])
        #expect(e.call(93, [fd + 1, Self.readSet, Self.writeSet, 0, 0]).value == 2)
    }

    @Test func pselectRestoresTheSignalMask() throws {
        let e = try DEnv()
        e.put([0xFF, 0, 0, 0], at: Self.maskVA)
        #expect(e.call(394, [0, 0, 0, 0, timespec(e, seconds: 0, nanos: 1_000_000), Self.maskVA]).value == 0)
        #expect(e.kernel.extended.signalMask == 0)
    }
}
