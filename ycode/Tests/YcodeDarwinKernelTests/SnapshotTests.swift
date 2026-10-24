import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// Snapshot records (specs/simulator/snapshot.md §6) and a kernel-object
// round trip without a VM: capture a process with a queued Mach message and a
// pipe holding bytes, restore it into a new system, and use both.

@Suite struct SnapshotFormatTests {
    @Test func fieldsRoundTrip() throws {
        var inner = SnapshotFields()
        inner.u64(1, 7)
        inner.string(2, "inner")
        var f = SnapshotFields()
        f.u64(1, 0xDEAD_BEEF_0000_0001)
        f.i64(2, -42)
        f.bytes(3, [1, 2, 3])
        f.string(4, "héllo")
        f.u64s(5, [9, 8, 7])
        f.ref(6, 123)
        f.nested(7, inner)
        f.list(8, [inner, inner])
        f.bool(9, true)
        let r = try SnapshotFieldReader(f.bytes)
        #expect(r.u64(1) == 0xDEAD_BEEF_0000_0001)
        #expect(r.i64(2) == -42)
        #expect(r.bytes(3) == [1, 2, 3])
        #expect(r.string(4) == "héllo")
        #expect(r.u64s(5) == [9, 8, 7])
        #expect(r.ref(6) == 123)
        #expect(r.nested(7)?.string(2) == "inner")
        #expect(r.list(8).count == 2 && r.list(8)[1].u64(1) == 7)
        #expect(r.bool(9))
        #expect(!r.has(99) && r.u64(99, default: 5) == 5)
    }

    @Test func manifestRoundTripAndErrors() throws {
        var f = SnapshotFields()
        f.string(1, "x")
        let records = [SnapshotRecord(kind: .system, id: 1, fields: f),
                       SnapshotRecord(kind: 0x8123, version: 3, id: 9, payload: [])]
        let bytes = SnapshotManifest.encode(records, createdAt: 77)
        let (created, back) = try SnapshotManifest.decode(bytes)
        #expect(created == 77)
        #expect(back.count == 2 && back[0].knownKind == .system && back[1].kind == 0x8123 && back[1].version == 3)
        #expect(throws: SnapshotError.self) { try SnapshotManifest.decode(Array(bytes.dropLast())) }
        var bad = bytes
        bad[0] = 0
        #expect(throws: SnapshotError.self) { try SnapshotManifest.decode(bad) }
    }

    @Test func hostServiceRecordsAreOptional() throws {
        var f = SnapshotFields()
        f.string(1, "device-session")
        f.u64(2, 0x1203)
        let record = SnapshotRecord(kind: .hostService, id: 9_000_000, fields: f)
        #expect(record.kind & 0x8000 != 0)
        let (_, back) = try SnapshotManifest.decode(SnapshotManifest.encode([record], createdAt: 1))
        #expect(back.first?.knownKind == .hostService)
        #expect(try back.first?.fields().string(1) == "device-session")
    }

    @Test func pageExtentsAndHeader() throws {
        let p = UInt64(SnapshotPageFile.pageSize)
        let extents = SnapshotPageFile.extents(of: [0x1000_0000, 0x1000_0000 + p, 0x1000_0000 + 3 * p, 0x2000_0000])
        #expect(extents == [.init(address: 0x1000_0000, pageCount: 2), .init(address: 0x1000_0000 + 3 * p, pageCount: 1),
                            .init(address: 0x2000_0000, pageCount: 1)])
        let (header, dataOffset) = SnapshotPageFile.header(for: extents)
        #expect(dataOffset % p == 0 && header.count == Int(dataOffset))
        let (parsed, offset) = try SnapshotPageFile.parseHeader(header)
        #expect(parsed == extents && offset == dataOffset)
    }
}

@Suite(.serialized) struct SnapshotKernelRoundTripTests {
    @Test func queuedMessageAndPipeSurviveARestore() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let s = ProcEnv.scratch
        // A receive right with a send right, and one message queued on it.
        let (_, allocated) = e.svc(k, UInt64(bitPattern: -16), [0x103, 1, s + 0x100])
        #expect(allocated.x[0] == 0)
        let name = e.read(k, s + 0x100, 4).readLE(UInt32.self, at: 0)
        e.svc(k, UInt64(bitPattern: -21), [0x103, UInt64(name), UInt64(name), 20])
        var msg: [UInt8] = []
        msg.appendLE(UInt32(19))  // COPY_SEND
        msg.appendLE(UInt32(28))
        msg.appendLE(name)
        msg.appendLE(UInt32(0))
        msg.appendLE(UInt32(0))
        msg.appendLE(Int32(77))
        msg.appendLE(UInt32(1234))
        e.put(k, msg, at: s + 0x1000)
        let (_, sent) = e.svc(k, UInt64(bitPattern: -31), [s + 0x1000, 1, 28, 0, 0, 0, 0])
        #expect(sent.x[0] == 0)
        // A pipe with five bytes in it.
        let (_, piped) = e.svc(k, 42)
        let (rfd, wfd) = (piped.x[0], piped.x[1])
        e.put(k, Array("hello".utf8), at: s + 0x2000)
        #expect(e.bsd(k, 4, [wfd, s + 0x2000, 5]) == 5)

        // Capture.
        let records: [SnapshotRecord] = e.system.lock.withLock {
            let capture = KernelSnapshotCapture(system: e.system, classification: SnapshotClassification())
            capture.capture(images: [SnapshotImageInput(kernel: k, parked: [:], fpState: { _ in nil })],
                            guestCounter: 1000, frequency: 24_000_000, bootCounter: 10)
            #expect(capture.counts["message"] == 1 && capture.counts["pipe"] == 1)
            return capture.records
        }
        let (_, decoded) = try SnapshotManifest.decode(SnapshotManifest.encode(records))

        // Restore into a new system.
        let system = DarwinSystem()
        let launcher = FakeLauncher()
        system.launcher = launcher
        let restore = try KernelSnapshotRestore(records: decoded, system: system)
        #expect(restore.clock.guestCounter == 1000 && restore.clock.bootCounter == 10)
        let plans = try restore.makeProcesses {
            DarwinFileSystem(prefixes: [.init(guestPath: e.root, hostPath: e.root, writable: true)], console: { _, _ in })
        }
        #expect(plans.count == 1 && plans[0].pid == 100)
        let k2 = plans[0].kernel
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: s, size: ProcEnv.scratchSize, protection: .readWrite, hint: nil)
        _ = try restore.restoreObjects { _ in space }
        #expect(system.kernel(forPID: 100) === k2)

        func svc(_ x16: Int64, _ args: [UInt64]) -> TrapFrame {
            var f = TrapFrame()
            f.kind = TrapFrame.Kind.svc.rawValue
            f.x[16] = UInt64(bitPattern: x16)
            for (i, v) in args.enumerated() { f.x[i] = v }
            _ = k2.handle(&f, context: k2.mainThread, memory: space)
            return f
        }
        // The message is still queued under the same name.
        let received = svc(-31, [s + 0x3000, 2 | 0x100, 0, 64, UInt64(name), 0, 0])
        #expect(received.x[0] == 0)
        let body = try system.lock.withLock { try space.read(va: s + 0x3000, count: 28) }
        #expect(body.readLE(Int32.self, at: 20) == 77 && body.readLE(UInt32.self, at: 24) == 1234)
        // The pipe still holds its bytes, on the same descriptor.
        let read = svc(3, [rfd, s + 0x4000, 16])
        #expect(!read.carry && read.x[0] == 5)
        let text = try system.lock.withLock { try space.read(va: s + 0x4000, count: 5) }
        #expect(String(decoding: text, as: UTF8.self) == "hello")
        system.terminateAllProcesses()
    }

    /// snapshot.md §12.5: with the lock split, the host services' threads
    /// use Mach state under the port lock and deliver to guest kqueues
    /// under the event locks, not under L0. The restore rebuilds that state
    /// holding all of them (it held L0 alone, and a host service's loop
    /// raced the rebuild), and re-issues thread requests under the event lock.
    @Test func restoreHoldsTheFineLocksWhileItRebuildsObjects() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let records: [SnapshotRecord] = e.system.lock.withLock {
            let capture = KernelSnapshotCapture(system: e.system, classification: SnapshotClassification())
            capture.capture(images: [SnapshotImageInput(kernel: k, parked: [:], fpState: { _ in nil })],
                            guestCounter: 1000, frequency: 24_000_000, bootCounter: 10)
            return capture.records
        }
        let (_, decoded) = try SnapshotManifest.decode(SnapshotManifest.encode(records))
        let system = DarwinSystem(ipcLocks: true)
        system.launcher = FakeLauncher()
        let portLock = try #require(system.mach.portLock)
        let restore = try KernelSnapshotRestore(records: decoded, system: system)
        let plans = try restore.makeProcesses {
            DarwinFileSystem(prefixes: [.init(guestPath: e.root, hostPath: e.root, writable: true)], console: { _, _ in })
        }
        let k2 = plans[0].kernel
        let eventLock = try #require(k2.eventLock)
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: ProcEnv.scratch, size: ProcEnv.scratchSize, protection: .readWrite, hint: nil)
        var held: (l0: Bool, ports: Bool, events: Bool)?
        _ = try restore.restoreObjects { _ in
            held = (system.lock.isHeldByCurrentThread, portLock.isHeldByCurrentThread, eventLock.isHeldByCurrentThread)
            return space
        }
        #expect(held?.l0 == true && held?.ports == true && held?.events == true)
        #expect(!portLock.isHeldByCurrentThread && !eventLock.isHeldByCurrentThread)
        // The thread requests of §7 step 10 are re-issued under the event lock
        // (with YCODE_LOCK_ORDER_CHECK=1 a workqueue change without it stops the process).
        system.lock.withLock { k2.snapshotReissueThreadRequests() }
        system.terminateAllProcesses()
    }

    /// snapshot.md §12.5: a restored EVFILT_READ knote's readiness observer
    /// runs under the descriptor object's lock (L0) and changes the kqueue
    /// and the workqueue: like the registration's observer it must take the
    /// image's event lock (the restore's copy did not, and its unguarded
    /// changes raced the kevent fast paths: lost thread requests, a
    /// corrupted heap).
    @Test func restoredReadinessObserverTakesTheEventLock() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let s = ProcEnv.scratch
        let (_, piped) = e.svc(k, 42)
        let (rfd, wfd) = (piped.x[0], piped.x[1])
        let kq = e.bsd(k, 362)
        #expect(kq >= 0)
        var change: [UInt8] = []
        change.appendLE(rfd)
        change.appendLE(Int16(-1))   // EVFILT_READ
        change.appendLE(UInt16(0x1)) // EV_ADD
        change.appendLE(UInt32(0))
        change.appendLE(Int64(0))
        change.appendLE(UInt64(0))
        e.put(k, change, at: s + 0x1000)
        #expect(e.bsd(k, 363, [UInt64(kq), s + 0x1000, 1, 0, 0, 0]) == 0)
        let records: [SnapshotRecord] = e.system.lock.withLock {
            let capture = KernelSnapshotCapture(system: e.system, classification: SnapshotClassification())
            capture.capture(images: [SnapshotImageInput(kernel: k, parked: [:], fpState: { _ in nil })],
                            guestCounter: 1000, frequency: 24_000_000, bootCounter: 10)
            return capture.records
        }
        let (_, decoded) = try SnapshotManifest.decode(SnapshotManifest.encode(records))
        let system = DarwinSystem(ipcLocks: true)
        system.launcher = FakeLauncher()
        let restore = try KernelSnapshotRestore(records: decoded, system: system)
        let plans = try restore.makeProcesses {
            DarwinFileSystem(prefixes: [.init(guestPath: e.root, hostPath: e.root, writable: true)], console: { _, _ in })
        }
        let k2 = plans[0].kernel
        let eventLock = try #require(k2.eventLock)
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: s, size: ProcEnv.scratchSize, protection: .readWrite, hint: nil)
        _ = try restore.restoreObjects { _ in space }
        let knote = system.lock.withLock {
            k2.withEvents { k2.descriptorKQueue(Int32(kq))?.knotes.first { $0.filter == -1 } }
        }
        #expect(knote != nil)
        // A write makes the pipe readable: the descriptor's observers run
        // under L0, and the knote's observer takes the event lock.
        let before = eventLock.acquisitions
        try system.lock.withLock { try space.write(va: s + 0x2000, bytes: Array("x".utf8)) }
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = 4
        f.x[0] = wfd
        f.x[1] = s + 0x2000
        f.x[2] = 1
        _ = k2.handle(&f, context: k2.mainThread, memory: space)
        #expect(!f.carry && f.x[0] == 1)
        #expect(eventLock.acquisitions > before)
        #expect(knote?.active == true)
        system.terminateAllProcesses()
    }

    /// snapshot.md §12.5: a workloop marked as having a thread request that
    /// no queue holds is never requested again by an activation; the
    /// restore's step 10 requests it afresh.
    @Test func lostWorkloopRequestIsIssuedAgainAfterARestore() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let kq = KQueue(kind: .workloop, workloopID: 0x5151)
        let kn = Knote(KEventRecord(ident: 1, filter: -10, flags: 0x1, fflags: 0, data: 0, qos: 0x1500))
        kn.active = true
        kn.kq = kq
        e.system.lock.withLock { k.withEvents {
            kq.knotes.append(kn)
            k.kevents.workloops[0x5151] = kq
            kq.requested = true
        } }
        #expect(e.system.lock.withLock { k.withEvents { k.lostWorkloopRequests().count } } == 1)
        #expect(e.system.lock.withLock { k.snapshotReissueThreadRequests() } == 1)
        e.system.lock.withLock { k.withEvents {
            #expect(kq.requested && k.workqueue.pendingWorkloops.contains { $0 === kq })
            #expect(k.lostWorkloopRequests().isEmpty)
        } }
    }

    /// snapshot.md §12.5: a file the guest opened read-write and then made
    /// read-only (mode 0400) is opened read-write again by the restore, not
    /// replaced by an empty stand-in; its mode is left as it was.
    @Test func fileMadeReadOnlyAfterItsOpenStaysWritableAcrossARestore() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let s = ProcEnv.scratch
        let path = e.root + "/index"
        e.putString(k, path, at: s + 0x100)
        let fd = e.bsd(k, 5, [s + 0x100, 0x202, 0o600])  // open(O_RDWR | O_CREAT)
        #expect(fd >= 0)
        e.put(k, Array("index".utf8), at: s + 0x200)
        #expect(e.bsd(k, 4, [UInt64(fd), s + 0x200, 5]) == 5)
        #expect(chmod(path, 0o400) == 0)
        let records: [SnapshotRecord] = e.system.lock.withLock {
            let capture = KernelSnapshotCapture(system: e.system, classification: SnapshotClassification())
            capture.capture(images: [SnapshotImageInput(kernel: k, parked: [:], fpState: { _ in nil })],
                            guestCounter: 1000, frequency: 24_000_000, bootCounter: 10)
            return capture.records
        }
        let (_, decoded) = try SnapshotManifest.decode(SnapshotManifest.encode(records))
        let system = DarwinSystem()
        system.launcher = FakeLauncher()
        let restore = try KernelSnapshotRestore(records: decoded, system: system)
        let plans = try restore.makeProcesses {
            DarwinFileSystem(prefixes: [.init(guestPath: e.root, hostPath: e.root, writable: true)], console: { _, _ in })
        }
        let k2 = plans[0].kernel
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: s, size: ProcEnv.scratchSize, protection: .readWrite, hint: nil)
        _ = try restore.restoreObjects { _ in space }
        #expect(restore.readOnlyReopens == 1)
        #expect(!restore.warnings.contains { $0.contains("gone") })
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o400)
        // The restored descriptor still writes to the file itself.
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = 4
        f.x[0] = UInt64(fd)
        f.x[1] = s + 0x200
        f.x[2] = 5
        try system.lock.withLock { try space.write(va: s + 0x200, bytes: Array("INDEX".utf8)) }
        _ = k2.handle(&f, context: k2.mainThread, memory: space)
        #expect(!f.carry && f.x[0] == 5)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "indexINDEX")
        system.terminateAllProcesses()
    }

    /// snapshot.md §5: a calendar-time EVFILT_TIMER (NOTE_ABSOLUTE without
    /// NOTE_MACHTIME) is due by the wall clock after a restore, which moved
    /// on while the snapshot sat on disk; an interval timer keeps the time
    /// it had left (the guest's mach time did not move).
    @Test func calendarTimersFollowTheWallClockAcrossARestore() throws {
        let e = try ProcEnv()
        let k = e.rootKernel!
        let s = ProcEnv.scratch
        let kq = e.bsd(k, 362)
        #expect(kq >= 0)
        let wallNow = k.wallClock().seconds
        func change(_ ident: UInt64, fflags: UInt32, data: Int64) -> [UInt8] {
            var b: [UInt8] = []
            b.appendLE(ident)
            b.appendLE(Int16(-7))      // EVFILT_TIMER
            b.appendLE(UInt16(0x1))    // EV_ADD
            b.appendLE(fflags)
            b.appendLE(data)
            b.appendLE(UInt64(0))
            return b
        }
        // 1: NOTE_ABSOLUTE | NOTE_SECONDS, 30 s of calendar time from now;
        // 2: NOTE_SECONDS, an interval of 30 s.
        e.put(k, change(1, fflags: 0x09, data: wallNow + 30) + change(2, fflags: 0x01, data: 30), at: s + 0x1000)
        #expect(e.bsd(k, 363, [UInt64(kq), s + 0x1000, 2, 0, 0, 0]) == 0)
        let records: [SnapshotRecord] = e.system.lock.withLock {
            let capture = KernelSnapshotCapture(system: e.system, classification: SnapshotClassification())
            capture.capture(images: [SnapshotImageInput(kernel: k, parked: [:], fpState: { _ in nil })],
                            guestCounter: 1000, frequency: 24_000_000, bootCounter: 10)
            return capture.records
        }
        let (_, decoded) = try SnapshotManifest.decode(SnapshotManifest.encode(records))

        let system = DarwinSystem()
        system.launcher = FakeLauncher()
        let restore = try KernelSnapshotRestore(records: decoded, system: system)
        let plans = try restore.makeProcesses {
            DarwinFileSystem(prefixes: [.init(guestPath: e.root, hostPath: e.root, writable: true)], console: { _, _ in })
        }
        let k2 = plans[0].kernel
        // The snapshot sat on disk for a minute.
        k2.wallClock = { (seconds: wallNow + 60, nanoseconds: 0) }
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: s, size: ProcEnv.scratchSize, protection: .readWrite, hint: nil)
        _ = try restore.restoreObjects { _ in space }
        let now = KernelClock.now()
        let knotes: [Knote] = system.lock.withLock {
            k2.withEvents { (k2.descriptorKQueue(Int32(kq))?.knotes ?? []).filter { $0.filter == -7 } }
        }
        let calendar = knotes.first { $0.ident == 1 }, interval = knotes.first { $0.ident == 2 }
        #expect(restore.wallClockTimers == 1)
        // Due at once (a timer thread may already have fired it).
        #expect(calendar.map { kn in kn.active || kn.timerFires > 0 || (kn.timerDeadline.map { $0 <= now } ?? false) } == true)
        #expect(interval?.timerDeadline.map { $0 > now + 20_000_000_000 } == true)
        system.terminateAllProcesses()
    }
}
