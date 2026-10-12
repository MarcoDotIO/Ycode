import Foundation
import YcodeDarwinABI

// kevent for stage 4a (`specs/simulator/threads-and-events.md` §3;
// `stage4a-contract.md` §5): `kevent` (363), `kevent64` (369), `kevent_qos`
// (374), `kevent_id` (375), and `kqueue_workloop_ctl` (530). Supported
// filters: EVFILT_USER, EVFILT_TIMER, EVFILT_WORKLOOP (thread request, value
// check, owner, sync wait/wake), and EVFILT_MACHPORT (fires when a message is
// queued). PROC, SIGNAL, READ, WRITE, VNODE and the other known filters are
// registered but never fire; EVFILT_MEMORYSTATUS is refused (ENOTSUP).
//
// There are three kinds of kqueue: kqueue descriptors (only reachable
// through `kevent`/`kevent64`/`kevent_qos` on a known descriptor), the
// process workqueue kqueue (`KEVENT_FLAG_WORKQ`, delivered to workqueue
// threads through per-QoS buckets and the manager bucket), and workloops
// (`kevent_id`, one servicer thread at a time). Delivered knotes of the
// workqueue kqueue and of workloops stay suppressed until their worker
// returns to the kernel.

/// The three user layouts of an event.
enum KEventFormat {
    /// `struct kevent`, 32 bytes.
    case legacy
    /// `struct kevent64_s`, 48 bytes.
    case k64
    /// `struct kevent_qos_s`, 72 bytes.
    case qos

    var size: Int {
        switch self {
        case .legacy: 32
        case .k64: 48
        case .qos: 72
        }
    }
}

/// One event or change, in the widest form.
struct KEventRecord: Equatable {
    var ident: UInt64 = 0
    var filter: Int16 = 0
    var flags: UInt16 = 0
    var fflags: UInt32 = 0
    var data: Int64 = 0
    var udata: UInt64 = 0
    var qos: UInt32 = 0
    var xflags: UInt32 = 0
    var ext: [UInt64] = [0, 0, 0, 0]

    init(ident: UInt64 = 0, filter: Int16 = 0, flags: UInt16 = 0, fflags: UInt32 = 0, data: Int64 = 0,
         udata: UInt64 = 0, qos: UInt32 = 0, ext: [UInt64] = [0, 0, 0, 0]) {
        self.ident = ident
        self.filter = filter
        self.flags = flags
        self.fflags = fflags
        self.data = data
        self.udata = udata
        self.qos = qos
        self.ext = ext + [UInt64](repeating: 0, count: max(0, 4 - ext.count))
    }

    init(decoding b: [UInt8], at o: Int, format: KEventFormat) {
        ident = b.readLE(UInt64.self, at: o)
        filter = b.readLE(Int16.self, at: o + 8)
        flags = b.readLE(UInt16.self, at: o + 10)
        switch format {
        case .legacy:
            fflags = b.readLE(UInt32.self, at: o + 12)
            data = b.readLE(Int64.self, at: o + 16)
            udata = b.readLE(UInt64.self, at: o + 24)
        case .k64:
            fflags = b.readLE(UInt32.self, at: o + 12)
            data = b.readLE(Int64.self, at: o + 16)
            udata = b.readLE(UInt64.self, at: o + 24)
            ext[0] = b.readLE(UInt64.self, at: o + 32)
            ext[1] = b.readLE(UInt64.self, at: o + 40)
        case .qos:
            qos = b.readLE(UInt32.self, at: o + 12)
            udata = b.readLE(UInt64.self, at: o + 16)
            fflags = b.readLE(UInt32.self, at: o + 24)
            xflags = b.readLE(UInt32.self, at: o + 28)
            data = b.readLE(Int64.self, at: o + 32)
            for i in 0..<4 { ext[i] = b.readLE(UInt64.self, at: o + 40 + 8 * i) }
        }
    }

    func encoded(_ format: KEventFormat) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: format.size)
        b.putLE(ident, at: 0)
        b.putLE(filter, at: 8)
        b.putLE(flags, at: 10)
        switch format {
        case .legacy:
            b.putLE(fflags, at: 12)
            b.putLE(data, at: 16)
            b.putLE(udata, at: 24)
        case .k64:
            b.putLE(fflags, at: 12)
            b.putLE(data, at: 16)
            b.putLE(udata, at: 24)
            b.putLE(ext[0], at: 32)
            b.putLE(ext[1], at: 40)
        case .qos:
            b.putLE(qos, at: 12)
            b.putLE(udata, at: 16)
            b.putLE(fflags, at: 24)
            b.putLE(UInt32(0), at: 28)
            b.putLE(data, at: 32)
            for i in 0..<4 { b.putLE(ext[i], at: 40 + 8 * i) }
        }
        return b
    }
}

/// `KEVENT_FLAG_*`.
enum KEventFlag {
    static let immediate: UInt32 = 0x000001
    static let errorEvents: UInt32 = 0x000002
    static let stackData: UInt32 = 0x000008
    static let workq: UInt32 = 0x000020
    static let workloop: UInt32 = 0x000400
    static let parking: UInt32 = 0x000800
    static let dynamicKQMustExist: UInt32 = 0x020000
    static let dynamicKQMustNotExist: UInt32 = 0x040000
    static let userSet: UInt32 = immediate | errorEvents | stackData | workq | workloop | dynamicKQMustExist
        | dynamicKQMustNotExist
}

/// `EV_*`.
enum EV {
    static let add: UInt16 = 0x0001
    static let delete: UInt16 = 0x0002
    static let enable: UInt16 = 0x0004
    static let disable: UInt16 = 0x0008
    static let oneshot: UInt16 = 0x0010
    static let clear: UInt16 = 0x0020
    static let receipt: UInt16 = 0x0040
    static let dispatch: UInt16 = 0x0080
    static let udataSpecific: UInt16 = 0x0100
    static let dispatch2: UInt16 = 0x0180
    static let vanished: UInt16 = 0x0200
    static let sysFlags: UInt16 = 0xF000
    static let error: UInt16 = 0x4000
    static let eof: UInt16 = 0x8000
    /// Bits that describe a change, not the knote.
    static let actionBits: UInt16 = add | delete | enable | disable | receipt
}

/// `EVFILT_*`.
enum EVFilter {
    static let read: Int16 = -1, write: Int16 = -2, aio: Int16 = -3, vnode: Int16 = -4, proc: Int16 = -5,
               signal: Int16 = -6, timer: Int16 = -7, machport: Int16 = -8, fs: Int16 = -9, user: Int16 = -10,
               vm: Int16 = -12, sock: Int16 = -13, memorystatus: Int16 = -14, except: Int16 = -15,
               nwChannel: Int16 = -16, workloop: Int16 = -17, exclaves: Int16 = -18

    static let names: [Int16: String] = [
        -1: "EVFILT_READ", -2: "EVFILT_WRITE", -3: "EVFILT_AIO", -4: "EVFILT_VNODE", -5: "EVFILT_PROC",
        -6: "EVFILT_SIGNAL", -7: "EVFILT_TIMER", -8: "EVFILT_MACHPORT", -9: "EVFILT_FS", -10: "EVFILT_USER",
        -12: "EVFILT_VM", -13: "EVFILT_SOCK", -14: "EVFILT_MEMORYSTATUS", -15: "EVFILT_EXCEPT",
        -16: "EVFILT_NW_CHANNEL", -17: "EVFILT_WORKLOOP", -18: "EVFILT_EXCLAVES_NOTIFICATION",
    ]
}

/// EVFILT_USER `fflags`.
enum NoteUser {
    static let trigger: UInt32 = 0x0100_0000
    static let controlMask: UInt32 = 0xC000_0000
    static let and: UInt32 = 0x4000_0000
    static let or: UInt32 = 0x8000_0000
    static let copy: UInt32 = 0xC000_0000
    static let flagsMask: UInt32 = 0x00FF_FFFF
}

/// EVFILT_TIMER `fflags`.
enum NoteTimer {
    static let seconds: UInt32 = 0x01
    static let useconds: UInt32 = 0x02
    static let nseconds: UInt32 = 0x04
    static let absolute: UInt32 = 0x08
    static let leeway: UInt32 = 0x10
    static let critical: UInt32 = 0x20
    static let background: UInt32 = 0x40
    static let machContinuousTime: UInt32 = 0x80
    static let machTime: UInt32 = 0x100
    static let unitMask: UInt32 = seconds | useconds | nseconds | machTime
}

/// EVFILT_WORKLOOP commands (`fflags`).
enum NoteWorkloop {
    static let threadRequest: UInt32 = 0x01
    static let syncWait: UInt32 = 0x04
    static let syncWake: UInt32 = 0x08
    static let updateQoS: UInt32 = 0x10
    static let endOwnership: UInt32 = 0x20
    static let discoverOwner: UInt32 = 0x80
    static let ignoreESTALE: UInt32 = 0x100
    static let syncIPC: UInt32 = 0x8000_0000
    static let syncMask: UInt32 = syncWait | syncWake | syncIPC
}

/// Mach receive options of EVFILT_MACHPORT.
enum MachRcv {
    static let msg: UInt32 = 0x0000_0002
    static let large: UInt32 = 0x0000_0004
    static let largeIdentity: UInt32 = 0x0000_0008
}

/// A registered event.
final class Knote {
    let ident: UInt64
    let filter: Int16
    var flags: UInt16
    var fflags: UInt32
    var data: Int64
    var udata: UInt64
    var qos: UInt32
    var ext: [UInt64]
    var enabled = true
    var active = false
    var suppressed = false
    var deletePending = false
    /// Re-enabled while delete-pending: delivers one synthetic delete event.
    var syntheticDelete = false
    var dropped = false
    weak var kq: KQueue?
    /// The workqueue kqueue bucket (QoS 1…6, 8 = manager).
    var bucket = 0
    // EVFILT_USER
    var userFlags: UInt32 = 0
    // EVFILT_TIMER (host monotonic ns)
    var timerDeadline: UInt64?
    var timerInterval: UInt64 = 0
    var timerFires: Int64 = 0
    // EVFILT_WORKLOOP sync knotes
    var syncWoken = false
    let syncWaiters = WaitQueue()
    // EVFILT_MACHPORT: the receive right left the space.
    var receiveGone = false
    // EVFILT_PROC (stage 4b): events seen since the last delivery, the
    // exit status, and whether the process exited.
    var procFired: UInt32 = 0
    var procData: Int64 = 0
    var procExited = false
    // EVFILT_SIGNAL: postings since the last delivery.
    var signalCount: Int64 = 0
    // EVFILT_READ / EVFILT_WRITE: the descriptor object and its observer,
    // or (no object) a host file or the console, which is always ready.
    weak var object: (any KernelDescriptorObject)?
    var observerToken: Int?
    var hostDescriptor = false

    init(_ c: KEventRecord) {
        ident = c.ident
        filter = c.filter
        flags = c.flags & ~EV.actionBits
        fflags = c.fflags
        data = c.data
        udata = c.udata
        qos = c.qos
        ext = c.ext
    }

    var udataSpecific: Bool { flags & EV.udataSpecific != 0 }
    var isSyncKnote: Bool { filter == EVFilter.workloop && fflags & NoteWorkloop.syncMask != 0 }
}

/// Per-bucket state of the workqueue kqueue.
struct KQBucket {
    var requested = false
    var boundWorker: ThreadContext?
}

/// A kqueue: a descriptor kqueue, the workqueue kqueue, or a workloop.
final class KQueue {
    enum Kind: Equatable {
        case descriptor(Int32)
        case workq
        case workloop
    }

    let kind: Kind
    var knotes: [Knote] = []
    /// The descriptor object of a `kqueue()` queue (stage 4b).
    weak var object: KQueueObject?
    /// Threads scanning a descriptor kqueue or polling a workloop.
    let waiters = WaitQueue()
    /// A descriptor kqueue's event format, fixed by its first use.
    var legacyFormat: Bool?
    // Workqueue kqueue
    var buckets: [Int: KQBucket] = [:]
    // Workloop
    var workloopID: UInt64 = 0
    var servicer: ThreadContext?
    var owner: ThreadContext?
    var requested = false
    var requestQoS = 4
    var requestOvercommit = false
    var fixedPriority = false
    var createReference = false

    init(kind: Kind, workloopID: UInt64 = 0) {
        self.kind = kind
        self.workloopID = workloopID
    }

    var isDescriptor: Bool {
        if case .descriptor = kind { return true }
        return false
    }

    func find(ident: UInt64, filter: Int16, udata: UInt64?) -> Knote? {
        knotes.first { k in
            k.ident == ident && k.filter == filter
                && (udata == nil ? !k.udataSpecific : (k.udataSpecific && k.udata == udata!))
        }
    }
}

/// The part of a data buffer that EVFILT_MACHPORT receives may use.
struct KEventDataArea {
    var base: UInt64
    var size: UInt64
    /// Carve from the top downward.
    var stackData: Bool
}

/// The kevent engine's state.
struct KEventState {
    var workq: KQueue?
    var workloops: [UInt64: KQueue] = [:]
    var descriptorQueues: [Int32: KQueue] = [:]
    /// Queues made by `kqueue()` (stage 4b), until their last descriptor closes.
    var objectQueues: [ObjectIdentifier: KQueue] = [:]
    /// Armed timers.
    var timers: [ObjectIdentifier: Knote] = [:]
    /// Wakes the timer thread when the earliest deadline changes.
    let timerWake = WaitQueue()
    var timerThreadStarted = false
    var loggedFilters: Set<Int16> = []
}

extension DarwinKernel {
    static let ESTALE: Int32 = 70
    static let EINPROGRESS: Int32 = 36
    static let EXDEV: Int32 = 18
    static let EEXIST: Int32 = 17

    // MARK: Entry points

    /// Makes a descriptor kqueue reachable as `fd` (there is no `kqueue()`
    /// call yet; tests and a later descriptor layer use this).
    func installDescriptorKQueue(_ fd: Int32) {
        kevents.descriptorQueues[fd] = KQueue(kind: .descriptor(fd))
    }

    /// `kevent` (363), `kevent64` (369), `kevent_qos` (374), `kevent_id` (375).
    func keventCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let format: KEventFormat = n == BSD2.kevent ? .legacy : n == BSD2.kevent64 ? .k64 : .qos
        let nchanges = Int32(truncatingIfNeeded: a[2]), nevents = Int32(truncatingIfNeeded: a[4])
        var flags: UInt32 = 0
        var timeoutPointer: UInt64 = 0
        var dataOut: UInt64 = 0, dataAvailable: UInt64 = 0
        switch n {
        case BSD2.kevent:
            timeoutPointer = a[5]
            call = "kevent(\(Int32(truncatingIfNeeded: a[0])), changes=\(hx(a[1])), nchanges=\(nchanges), events=\(hx(a[3])), "
                + "nevents=\(nevents), timeout=\(hx(a[5])))"
        case BSD2.kevent64:
            flags = UInt32(truncatingIfNeeded: a[5])
            timeoutPointer = a[6]
            call = "kevent64(\(Int32(truncatingIfNeeded: a[0])), changes=\(hx(a[1])), nchanges=\(nchanges), events=\(hx(a[3])), "
                + "nevents=\(nevents), flags=\(hx(flags)), timeout=\(hx(a[6])))"
        default:
            dataOut = a[5]
            dataAvailable = a[6]
            flags = UInt32(truncatingIfNeeded: a[7])
            call = "\(n == BSD2.keventQos ? "kevent_qos(\(Int32(truncatingIfNeeded: a[0]))" : "kevent_id(\(hx(a[0]))"), "
                + "changes=\(hx(a[1])), nchanges=\(nchanges), events=\(hx(a[3])), nevents=\(nevents), "
                + "data_out=\(hx(a[5])), data_available=\(hx(a[6])), flags=\(hx(flags)))"
        }
        flags &= KEventFlag.userSet
        guard nchanges >= 0, nevents >= 0 else { throw Failure(errno: Errno.EINVAL) }
        let errorEvents = flags & KEventFlag.errorEvents != 0
        let ctx = current

        // Pick the kqueue.
        let kq: KQueue
        switch n {
        case BSD2.kevent, BSD2.kevent64, BSD2.keventQos:
            if flags & (KEventFlag.workloop | KEventFlag.dynamicKQMustExist | KEventFlag.dynamicKQMustNotExist) != 0 {
                throw Failure(errno: Errno.EINVAL)
            }
            if n == BSD2.keventQos, flags & KEventFlag.workq != 0 {
                if nevents > 0 && !errorEvents { throw Failure(errno: Errno.EINVAL) }
                if kevents.workq == nil { kevents.workq = KQueue(kind: .workq) }
                kq = kevents.workq!
            } else {
                guard let q = descriptorKQueue(Int32(truncatingIfNeeded: a[0])) else { throw Failure(errno: Errno.EBADF) }
                let legacy = n == BSD2.kevent
                if let l = q.legacyFormat, l != legacy { throw Failure(errno: Errno.EINVAL) }
                q.legacyFormat = legacy
                kq = q
            }
        default:
            guard flags & KEventFlag.workloop != 0, flags & KEventFlag.workq == 0 else { throw Failure(errno: Errno.EINVAL) }
            let id = a[0]
            guard id != 0, id != UInt64.max else { throw Failure(errno: Errno.EINVAL) }
            if let wl = kevents.workloops[id] {
                if flags & KEventFlag.dynamicKQMustNotExist != 0 { throw Failure(errno: Self.EEXIST) }
                kq = wl
            } else {
                if flags & KEventFlag.dynamicKQMustExist != 0 { throw Failure(errno: Errno.ENOENT) }
                let wl = KQueue(kind: .workloop, workloopID: id)
                kevents.workloops[id] = wl
                kq = wl
            }
            if nevents > 0 && !errorEvents && kq.servicer !== ctx {
                maybeFreeWorkloop(kq)
                throw Failure(errno: Self.EXDEV)
            }
        }

        var deadline: UInt64?
        if timeoutPointer != 0 {
            let ts = try mem.read(va: timeoutPointer, count: 16)
            let sec = ts.readLE(Int64.self, at: 0), nsec = ts.readLE(Int64.self, at: 8)
            guard sec >= 0, (0..<1_000_000_000).contains(nsec) else { throw Failure(errno: Errno.EINVAL) }
            let ns = sec > Int64(UInt64.max / 2_000_000_000) ? UInt64.max : UInt64(sec) * 1_000_000_000 + UInt64(nsec)
            deadline = KernelClock.deadline(afterNanoseconds: ns)
        }

        let changes = try readKEvents(a[1], count: Int(nchanges), format: format, mem)
        var output: [KEventRecord] = []
        if let e = applyChanges(changes, to: kq, outputCapacity: Int(nevents), output: &output, context: ctx,
                                flags: flags, mem) {
            if kq.kind == .workloop { maybeFreeWorkloop(kq) }
            throw Failure(errno: e)
        }

        // Scan.
        var area = KEventDataArea(base: 0, size: 0, stackData: flags & KEventFlag.stackData != 0)
        var available: UInt64 = 0
        if dataOut != 0, dataAvailable != 0 {
            available = try readU64(dataAvailable, mem)
            area = KEventDataArea(base: dataOut, size: available, stackData: flags & KEventFlag.stackData != 0)
        }
        if !errorEvents, nevents > 0, output.isEmpty {
            while true {
                let found = scanForDelivery(kq, bucket: nil, max: Int(nevents), area: &area, context: ctx, mem)
                if !found.isEmpty {
                    output = found
                    break
                }
                if flags & KEventFlag.immediate != 0 { break }
                if let deadline, deadline <= KernelClock.now() { break }
                let r = kq.waiters.wait(on: lock, deadline: deadline)
                if r == .interrupted { throw Failure(errno: Self.EINTR) }
                if r == .timedOut { break }
            }
        }
        if dataOut != 0, dataAvailable != 0, area.size != available { try writeU64(dataAvailable, area.size, mem) }
        if !output.isEmpty {
            var bytes: [UInt8] = []
            for e in output { bytes += e.encoded(format) }
            try mem.write(va: a[3], bytes: bytes)
        }
        if kq.kind == .workloop { maybeFreeWorkloop(kq) }
        call += " [\(output.count) events\(output.isEmpty ? "" : ": " + output.map(describe).joined(separator: "; "))]"
        return UInt64(output.count)
    }

    func describe(_ e: KEventRecord) -> String {
        let name = EVFilter.names[e.filter] ?? "filter \(e.filter)"
        var s = "\(name) ident=\(hx(e.ident)) flags=\(hx(e.flags)) fflags=\(hx(e.fflags)) data=\(e.data)"
        if e.flags & EV.error != 0 { s += " (\(Errno.name(Int32(truncatingIfNeeded: e.data))))" }
        return s
    }

    func readKEvents(_ va: UInt64, count: Int, format: KEventFormat, _ mem: any KernelGuestMemory) throws -> [KEventRecord] {
        guard count > 0 else { return [] }
        guard count <= 4096 else { throw Failure(errno: Errno.EINVAL) }
        let bytes = try mem.read(va: va, count: count * format.size)
        return (0..<count).map { KEventRecord(decoding: bytes, at: $0 * format.size, format: format) }
    }

    // MARK: Changes

    /// Applies `changes` in order (§3.4). Error and receipt results go to
    /// `output` while it has room; a failed change with no room left ends
    /// the call with that errno (returned).
    func applyChanges(_ changes: [KEventRecord], to kq: KQueue, outputCapacity: Int, output: inout [KEventRecord],
                      context: ThreadContext, flags: UInt32, _ mem: any KernelGuestMemory) -> Int32? {
        for change in changes {
            var c = change
            c.flags &= ~EV.sysFlags
            var result = applyChange(c, to: kq, context: context, flags: flags, changeCount: changes.count,
                                     outputCapacity: outputCapacity, mem)
            if let waiter = result.wait {
                // EVFILT_WORKLOOP sync wait: block until woken or deleted.
                let r = waiter.syncWaiters.wait(on: lock, deadline: nil)
                if r == .interrupted { result.errno = Self.EINTR }
            }
            if result.errno != nil || c.flags & EV.receipt != 0 {
                if output.count < outputCapacity {
                    var e = c
                    e.flags |= EV.error
                    e.data = Int64(result.errno ?? 0)
                    if let loaded = result.loaded { e.ext[3] = loaded }
                    output.append(e)
                } else if let e = result.errno {
                    return e
                }
            }
        }
        return nil
    }

    struct ChangeResult {
        var errno: Int32?
        /// EVFILT_WORKLOOP: the value the debounce check loaded.
        var loaded: UInt64?
        /// EVFILT_WORKLOOP: a sync knote the caller must wait on.
        var wait: Knote?
    }

    private func logFilterOnce(_ filter: Int16, _ text: String) {
        if kevents.loggedFilters.insert(filter).inserted { log("note: \(EVFilter.names[filter] ?? "filter \(filter)"): \(text)") }
    }

    func applyChange(_ c: KEventRecord, to kq: KQueue, context: ThreadContext, flags: UInt32, changeCount: Int,
                     outputCapacity: Int, _ mem: any KernelGuestMemory) -> ChangeResult {
        let filter = c.filter
        guard (-18 ... -1).contains(filter), filter != -11 else { return ChangeResult(errno: Errno.EINVAL) }
        if filter == EVFilter.memorystatus {
            logFilterOnce(filter, "not supported (ENOTSUP)")
            return ChangeResult(errno: Errno.ENOTSUP)
        }
        if filter == EVFilter.workloop {
            guard kq.kind == .workloop else { return ChangeResult(errno: Errno.ENOTSUP) }
            return applyWorkloopChange(c, to: kq, context: context, flags: flags, changeCount: changeCount,
                                       outputCapacity: outputCapacity, mem)
        }
        let existing = kq.find(ident: c.ident, filter: filter, udata: c.flags & EV.udataSpecific != 0 ? c.udata : nil)
        if c.flags & EV.delete != 0 {
            guard let kn = existing else {
                if kq.kind == .workloop && c.flags & EV.add != 0 { return ChangeResult() }
                return ChangeResult(errno: Errno.ENOENT)
            }
            if kn.flags & EV.dispatch2 == EV.dispatch2 && !kn.enabled && c.flags & EV.enable == 0 {
                kn.deletePending = true
                return ChangeResult(errno: Self.EINPROGRESS)
            }
            drop(kn)
            return ChangeResult()
        }
        let kn: Knote
        if c.flags & EV.add != 0 {
            if c.flags & EV.vanished != 0 && c.flags & EV.dispatch2 != EV.dispatch2 { return ChangeResult(errno: Errno.EINVAL) }
            let enabled = c.flags & EV.disable == 0
            if kq.kind == .workloop, enabled, PthreadPriority.qos(c.qos) == nil {
                return ChangeResult(errno: Errno.ERANGE)
            }
            if let existing {
                if let e = touchFilter(existing, c, mem) { return ChangeResult(errno: e) }
                existing.udata = c.udata
                existing.qos = c.qos
                existing.flags = (existing.flags & (EV.clear | EV.oneshot)) | (c.flags & ~EV.actionBits)
                if filter == EVFilter.timer {
                    existing.flags |= EV.clear
                    if existing.fflags & NoteTimer.absolute != 0 { existing.flags |= EV.oneshot }
                }
                kn = existing
            } else {
                let new = Knote(c)
                new.kq = kq
                new.bucket = workqBucket(c.qos)
                if let e = attachFilter(new, c, mem) { return ChangeResult(errno: e) }
                kq.knotes.append(new)
                if new.filter == EVFilter.timer { armTimer(new) }
                kn = new
            }
            if enabled { enable(kn) } else { kn.enabled = false }
        } else {
            // A change without EV_ADD still modifies an existing knote
            // (EVFILT_USER's NOTE_TRIGGER pokes work this way).
            guard let existing else { return ChangeResult(errno: Errno.ENOENT) }
            kn = existing
            if let e = touchFilter(kn, c, mem) { return ChangeResult(errno: e) }
            if c.flags & EV.disable != 0 { kn.enabled = false } else if c.flags & EV.enable != 0 { enable(kn) }
        }
        if kn.active && kn.enabled { activated(kn) }
        return ChangeResult()
    }

    private func enable(_ kn: Knote) {
        if kn.deletePending && !kn.enabled {
            kn.syntheticDelete = true
            kn.active = true
        }
        kn.enabled = true
    }

    /// The workqueue kqueue bucket of a knote QoS: 1…6, or 8 = manager.
    func workqBucket(_ pp: UInt32) -> Int {
        if pp & PthreadPriority.eventManager != 0 { return Self.managerQoS }
        return PthreadPriority.qos(pp) ?? Self.managerQoS
    }

    // MARK: Filters

    private func attachFilter(_ kn: Knote, _ c: KEventRecord, _ mem: any KernelGuestMemory) -> Int32? {
        switch kn.filter {
        case EVFilter.user:
            kn.userFlags = userFlagsOperation(0, c.fflags)
            kn.data = c.data
            kn.active = c.fflags & NoteUser.trigger != 0
            return nil
        case EVFilter.timer:
            return setTimer(kn, c, isNew: true)
        case EVFilter.machport:
            if let ipc = machIPC as? MachIPC {
                switch ipc.receiveTarget(of: UInt32(truncatingIfNeeded: c.ident)) {
                case .none: return Errno.ENOENT
                case .notReceivable, .specialReplyPort: return Errno.ENOTSUP
                case .port, .portSet: break
                }
            }
            kn.active = machPortHasMessage(UInt32(truncatingIfNeeded: c.ident))
            return nil
        case EVFilter.proc where system.record(of: self) != nil:
            return attachProcess(kn, c)
        case EVFilter.signal:
            guard (1...31).contains(c.ident) else { return Errno.EINVAL }
            kn.flags |= EV.clear
            return nil
        case EVFilter.read, EVFilter.write:
            return attachDescriptor(kn, c)
        default:
            logFilterOnce(kn.filter, "registered; it never fires in stage 4a")
            return nil
        }
    }

    private func touchFilter(_ kn: Knote, _ c: KEventRecord, _ mem: any KernelGuestMemory) -> Int32? {
        switch kn.filter {
        case EVFilter.user:
            kn.userFlags = userFlagsOperation(kn.userFlags, c.fflags)
            kn.data = c.data
            if c.fflags & NoteUser.trigger != 0 { kn.active = true }
            return nil
        case EVFilter.timer:
            return setTimer(kn, c, isNew: false)
        case EVFilter.machport:
            if (kn.fflags ^ c.fflags) & MachRcv.msg != 0 { return Errno.EINVAL }
            kn.fflags = c.fflags
            kn.ext = c.ext
            kn.active = machPortHasMessage(UInt32(truncatingIfNeeded: c.ident))
            return nil
        default:
            kn.fflags = c.fflags
            kn.data = c.data
            kn.ext = c.ext
            return nil
        }
    }

    private func userFlagsOperation(_ old: UInt32, _ fflags: UInt32) -> UInt32 {
        let bits = fflags & NoteUser.flagsMask
        switch fflags & NoteUser.controlMask {
        case NoteUser.and: return old & bits
        case NoteUser.or: return old | bits
        case NoteUser.copy: return bits
        default: return old
        }
    }

    private func machPortHasMessage(_ name: UInt32) -> Bool {
        machIPC?.messageQueued(on: name) ?? false
    }

    // MARK: EVFILT_TIMER

    private func setTimer(_ kn: Knote, _ c: KEventRecord, isNew: Bool) -> Int32? {
        let units = c.fflags & NoteTimer.unitMask
        guard units.nonzeroBitCount <= 1 else { return Errno.EINVAL }
        if !isNew, (kn.fflags ^ c.fflags) & NoteTimer.absolute != 0 { return Errno.EINVAL }
        let absolute = c.fflags & NoteTimer.absolute != 0
        // Nanoseconds per unit; machTime is converted separately.
        let perUnit: UInt64 = switch units {
        case NoteTimer.seconds: 1_000_000_000
        case NoteTimer.useconds: 1_000
        case NoteTimer.nseconds: 1
        case NoteTimer.machTime: 0
        default: 1_000_000
        }
        func toNanoseconds(_ v: UInt64) -> UInt64? {
            if units == NoteTimer.machTime { return nanoseconds(ticks: v) }
            let (r, o) = v.multipliedReportingOverflow(by: perUnit)
            return o ? nil : r
        }
        let now = KernelClock.now()
        var deadline: UInt64
        var interval: UInt64 = 0
        if absolute {
            if units == NoteTimer.machTime {
                deadline = hostDeadline(machTicks: UInt64(bitPattern: c.data))
            } else {
                guard let absNs = toNanoseconds(UInt64(max(0, c.data))) else { return Errno.ERANGE }
                let w = wallClock()
                let wallNs = UInt64(max(0, w.seconds)) &* 1_000_000_000 &+ UInt64(max(0, w.nanoseconds))
                deadline = absNs > wallNs ? KernelClock.deadline(afterNanoseconds: absNs - wallNs) : now
            }
        } else if c.data <= 0 {
            deadline = now
        } else {
            guard let ns = toNanoseconds(UInt64(c.data)) else { return Errno.ERANGE }
            interval = ns
            deadline = KernelClock.deadline(afterNanoseconds: ns)
        }
        kn.fflags = c.fflags
        kn.data = c.data
        kn.ext = c.ext
        kn.flags |= EV.clear
        if absolute { kn.flags |= EV.oneshot }
        if c.flags & EV.oneshot != 0 || absolute || c.data <= 0 { interval = 0 }
        kn.timerInterval = interval
        kn.timerFires = 0
        kn.active = false
        kn.timerDeadline = deadline
        if deadline <= now {
            kn.timerFires = 1
            kn.active = true
            if interval > 0 { kn.timerDeadline = deadline + interval } else { kn.timerDeadline = nil }
        }
        if !isNew { armTimer(kn) }
        return nil
    }

    private func armTimer(_ kn: Knote) {
        if kn.timerDeadline == nil {
            kevents.timers[ObjectIdentifier(kn)] = nil
            return
        }
        kevents.timers[ObjectIdentifier(kn)] = kn
        startTimerThreadIfNeeded()
        kevents.timerWake.wakeAll()
    }

    /// Fires every due timer. Returns the earliest remaining deadline.
    func fireDueTimers() -> UInt64? {
        let now = KernelClock.now()
        var next: UInt64?
        for (key, kn) in kevents.timers {
            guard !kn.dropped, let d = kn.timerDeadline else {
                kevents.timers[key] = nil
                continue
            }
            if d <= now {
                if kn.timerInterval > 0 {
                    let n = 1 + (now - d) / kn.timerInterval
                    kn.timerFires += Int64(n)
                    kn.timerDeadline = d &+ n &* kn.timerInterval
                } else {
                    kn.timerFires = 1
                    kn.timerDeadline = nil
                    kevents.timers[key] = nil
                }
                kn.active = true
                activated(kn)
            }
            if let d2 = kn.timerDeadline { next = min(next ?? d2, d2) }
        }
        return next
    }

    /// The timer service thread: fires timers at their deadlines. It holds
    /// the kernel weakly and stops at `terminate()` or when the kernel goes.
    private func startTimerThreadIfNeeded() {
        guard !kevents.timerThreadStarted else { return }
        kevents.timerThreadStarted = true
        let box = TimerThreadBox(kernel: self, lock: lock, wake: kevents.timerWake)
        let thread = Thread { box.run() }
        thread.name = "ycode-kernel-timers"
        thread.start()
    }

    // MARK: EVFILT_WORKLOOP

    private func applyWorkloopChange(_ c: KEventRecord, to wl: KQueue, context: ThreadContext, flags: UInt32,
                                     changeCount: Int, outputCapacity: Int, _ mem: any KernelGuestMemory) -> ChangeResult {
        let cmd = c.fflags
        var result = ChangeResult()
        let existing = wl.find(ident: c.ident, filter: EVFilter.workloop, udata: c.flags & EV.udataSpecific != 0 ? c.udata : nil)
        // Debounce.
        var loaded = c.ext[3]
        if c.ext[1] != 0 {
            guard let v = try? readU64(c.ext[1], mem) else { return ChangeResult(errno: Errno.EFAULT) }
            loaded = v
            result.loaded = v
            if (v & c.ext[2]) != (c.ext[3] & c.ext[2]) {
                if cmd & NoteWorkloop.ignoreESTALE != 0 { return result }
                result.errno = Self.ESTALE
                return result
            }
        }
        // Discover owner (applied after validation).
        var newOwner: ThreadContext?? = nil
        if cmd & NoteWorkloop.discoverOwner != 0 {
            let name = UInt32(truncatingIfNeeded: loaded) & ~3
            if name == 0 {
                newOwner = .some(nil)
            } else {
                guard let t = threadsByPort[name | 3] else { result.errno = Self.EOWNERDEAD; return result }
                newOwner = .some(t)
            }
        }
        func finishOwnership() {
            if let o = newOwner { wl.owner = o }
            if cmd & NoteWorkloop.endOwnership != 0, wl.owner === context { wl.owner = nil }
        }

        if cmd & NoteWorkloop.threadRequest != 0 {
            guard c.ident == wl.workloopID else { result.errno = Errno.EINVAL; return result }
            if c.flags & EV.delete != 0 {
                if let kn = existing { drop(kn) } else if c.flags & EV.add == 0 { result.errno = Errno.ENOENT; return result }
                finishOwnership()
                reevaluateRequests(wl, bucket: nil)
                return result
            }
            let kn: Knote
            if let existing {
                kn = existing
            } else {
                guard c.flags & EV.add != 0 else { result.errno = Errno.ENOENT; return result }
                kn = Knote(c)
            }
            let isNew = !wl.knotes.contains { $0 === kn }
            if isNew || cmd & NoteWorkloop.updateQoS != 0 {
                guard PthreadPriority.qos(c.qos) != nil else { result.errno = Errno.ERANGE; return result }
                kn.qos = c.qos
            }
            if isNew {
                kn.kq = wl
                wl.knotes.append(kn)
            }
            kn.fflags = cmd
            kn.udata = c.udata
            kn.flags |= EV.clear
            if c.flags & EV.disable != 0 { kn.enabled = false } else { kn.enabled = true }
            kn.active = true
            finishOwnership()
            reevaluateRequests(wl, bucket: nil)
            return result
        }

        if cmd & NoteWorkloop.syncMask != 0 {
            if c.flags & EV.delete != 0 {
                guard let kn = existing else {
                    if c.flags & EV.add != 0 { finishOwnership(); reevaluateRequests(wl, bucket: nil); return result }
                    result.errno = Errno.ENOENT
                    return result
                }
                guard kn.isSyncKnote else { result.errno = Errno.EINVAL; return result }
                kn.syncWoken = true
                kn.syncWaiters.wakeAll()
                drop(kn)
                finishOwnership()
                reevaluateRequests(wl, bucket: nil)
                return result
            }
            if cmd & NoteWorkloop.syncWait != 0 && cmd & NoteWorkloop.endOwnership != 0 {
                result.errno = Errno.EINVAL
                return result
            }
            let kn: Knote
            if let existing {
                guard existing.isSyncKnote else { result.errno = Errno.EINVAL; return result }
                if c.flags & EV.enable != 0 { result.errno = Errno.EINVAL; return result }
                if cmd & NoteWorkloop.syncWake != 0 {
                    if existing.syncWoken { result.errno = Self.EALREADY; return result }
                    existing.syncWoken = true
                    existing.syncWaiters.wakeAll()
                }
                existing.fflags |= cmd & NoteWorkloop.syncMask
                kn = existing
            } else {
                guard c.flags & EV.add != 0 else { result.errno = Errno.ENOENT; return result }
                guard c.flags & EV.disable != 0 else { result.errno = Errno.EINVAL; return result }
                kn = Knote(c)
                kn.kq = wl
                kn.enabled = false
                kn.syncWoken = cmd & NoteWorkloop.syncWake != 0
                wl.knotes.append(kn)
            }
            finishOwnership()
            if cmd & NoteWorkloop.syncWait != 0 && !kn.syncWoken {
                guard changeCount == 1, flags & KEventFlag.errorEvents != 0, flags & KEventFlag.workloop != 0,
                      outputCapacity >= 1 else {
                    if existing == nil { drop(kn) }
                    result.errno = Errno.ENOTSUP
                    return result
                }
                result.wait = kn
            }
            reevaluateRequests(wl, bucket: nil)
            return result
        }
        result.errno = Errno.EINVAL
        return result
    }

    // MARK: Activation and delivery

    /// Removes a knote.
    func drop(_ kn: Knote) {
        kn.dropped = true
        kn.active = false
        if let token = kn.observerToken {
            kn.object?.removeReadinessObserver(token)
            kn.observerToken = nil
        }
        kevents.timers[ObjectIdentifier(kn)] = nil
        if kn.isSyncKnote, !kn.syncWaiters.isEmpty {
            kn.syncWoken = true
            kn.syncWaiters.wakeAll()
        }
        guard let kq = kn.kq else { return }
        kq.knotes.removeAll { $0 === kn }
        reevaluateRequests(kq, bucket: kq.kind == .workq ? kn.bucket : nil)
    }

    /// A knote became active: wake a scanner or request a worker.
    func activated(_ kn: Knote) {
        guard let kq = kn.kq, kn.enabled, !kn.suppressed else { return }
        reevaluateRequests(kq, bucket: kq.kind == .workq ? kn.bucket : nil)
    }

    /// Would `scanForDelivery` report this knote now?
    private func deliverable(_ kn: Knote, in kq: KQueue) -> Bool {
        guard !kn.dropped, kn.active, !kn.suppressed, kn.enabled || kn.syntheticDelete else { return false }
        if kn.syntheticDelete { return true }
        switch kn.filter {
        case EVFilter.machport: return kn.receiveGone || machPortHasMessage(UInt32(truncatingIfNeeded: kn.ident))
        case EVFilter.timer: return kn.timerFires > 0
        case EVFilter.workloop: return kn.fflags & NoteWorkloop.threadRequest != 0 && kq.owner == nil
        case EVFilter.user: return true
        case EVFilter.proc: return kn.procFired != 0 || kn.procExited
        case EVFilter.signal: return kn.signalCount > 0
        case EVFilter.read, EVFilter.write: return descriptorState(kn).ready
        default: return false
        }
    }

    /// Issues (or cancels) the thread request of a bucket or workloop, or
    /// wakes the scanners of a descriptor kqueue (K2, §2.9 rule 1).
    func reevaluateRequests(_ kq: KQueue, bucket: Int?) {
        switch kq.kind {
        case .descriptor:
            if kq.knotes.contains(where: { deliverable($0, in: kq) }) {
                kq.waiters.wakeAll()
                kq.object?.notifyObservers()
            }
        case .workq:
            let buckets = bucket.map { [$0] } ?? Array(Set(kq.knotes.map(\.bucket)))
            var pump = false
            for b in buckets {
                var state = kq.buckets[b] ?? KQBucket()
                let has = kq.knotes.contains { $0.bucket == b && deliverable($0, in: kq) }
                if has && !state.requested && state.boundWorker == nil {
                    state.requested = true
                    pump = true
                } else if !has && state.requested {
                    state.requested = false
                }
                kq.buckets[b] = state
            }
            if pump { pumpWorkqueue(nil) }
        case .workloop:
            let active = kq.knotes.filter { deliverable($0, in: kq) }
            if kq.servicer != nil {
                if !active.isEmpty { kq.waiters.wakeAll() }
                return
            }
            if !active.isEmpty && kq.owner == nil {
                kq.requestQoS = active.compactMap { PthreadPriority.qos($0.qos) }.max() ?? 4
                kq.requestOvercommit = active.contains { $0.qos & PthreadPriority.overcommit != 0 }
                if !kq.requested {
                    kq.requested = true
                    workqueue.pendingWorkloops.append(kq)
                    pumpWorkqueue(nil)
                }
            } else if kq.requested {
                kq.requested = false
                workqueue.pendingWorkloops.removeAll { $0 === kq }
            }
            maybeFreeWorkloop(kq)
        }
    }

    /// Frees a workloop nothing refers to any more.
    func maybeFreeWorkloop(_ kq: KQueue) {
        guard kq.kind == .workloop, kq.knotes.isEmpty, kq.servicer == nil, !kq.createReference, !kq.requested,
              kq.waiters.isEmpty, kevents.workloops[kq.workloopID] === kq else { return }
        kevents.workloops[kq.workloopID] = nil
    }

    /// Takes up to `max` deliverable events from `kq` (one bucket of the
    /// workqueue kqueue when `bucket` is set) and applies the after-delivery
    /// rules of §3.5. On the workqueue kqueue and workloops the delivered
    /// knotes stay suppressed until `context` returns to the kernel.
    func scanForDelivery(_ kq: KQueue, bucket: Int?, max: Int, area: inout KEventDataArea, context: ThreadContext,
                         _ mem: any KernelGuestMemory) -> [KEventRecord] {
        var out: [KEventRecord] = []
        for kn in kq.knotes where out.count < max {
            if let bucket, kn.bucket != bucket { continue }
            guard deliverable(kn, in: kq) else {
                if kn.filter == EVFilter.machport && kn.active && !machPortHasMessage(UInt32(truncatingIfNeeded: kn.ident)) {
                    kn.active = false
                }
                continue
            }
            var e = KEventRecord(ident: kn.ident, filter: kn.filter, flags: kn.flags, fflags: 0, data: 0,
                                 udata: kn.udata, qos: kn.qos, ext: kn.ext)
            if kn.syntheticDelete {
                e.flags = (kn.flags & ~EV.actionBits) | EV.delete | EV.dispatch2 | EV.oneshot
                out.append(e)
                drop(kn)
                continue
            }
            switch kn.filter {
            case EVFilter.user:
                e.fflags = kn.userFlags
                e.data = kn.data
            case EVFilter.timer:
                e.fflags = kn.fflags
                e.data = kn.timerFires
                e.ext[0] = 0
            case EVFilter.machport:
                if kn.receiveGone {
                    // The source vanished: EV_VANISHED when asked for, else EV_EOF.
                    if kn.flags & EV.vanished != 0 {
                        e.flags = (kn.flags & ~EV.actionBits) | EV.vanished | EV.dispatch2 | EV.oneshot
                    } else {
                        e.flags |= EV.eof | EV.oneshot
                    }
                    e.data = 0
                    out.append(e)
                    drop(kn)
                    continue
                }
                deliverMachPort(kn, into: &e, area: &area, context: context, mem)
            case EVFilter.workloop:
                e.fflags = kn.fflags
                e.data = 0
            case EVFilter.proc:
                e.fflags = kn.procFired
                e.data = 0
                kn.procFired = 0
                if kn.procExited {
                    if kn.fflags & NoteProc.exitStatus != 0 { e.data = kn.procData }
                    if kn.fflags & NoteProc.reap == 0 {
                        e.flags |= EV.eof | EV.oneshot
                        kn.flags |= EV.oneshot
                    }
                    kn.procExited = false
                }
            case EVFilter.signal:
                e.fflags = kn.fflags
                e.data = kn.signalCount
                kn.signalCount = 0
            case EVFilter.read, EVFilter.write:
                let state = descriptorState(kn)
                e.fflags = 0
                e.data = state.data
                if state.eof { e.flags |= EV.eof }
            default:
                continue
            }
            out.append(e)
            // After delivery.
            if kn.flags & EV.oneshot != 0 {
                if kn.flags & EV.dispatch2 == EV.dispatch2 {
                    kn.enabled = false
                    kn.deletePending = true
                    kn.active = false
                } else {
                    drop(kn)
                    continue
                }
            } else if kn.flags & EV.dispatch != 0 {
                kn.enabled = false
            }
            if kn.flags & EV.clear != 0 {
                kn.active = false
                kn.timerFires = 0
            }
            if !kq.isDescriptor {
                kn.suppressed = true
                context.worker?.delivered.append(kn)
            }
        }
        return out
    }

    private func deliverMachPort(_ kn: Knote, into e: inout KEventRecord, area: inout KEventDataArea,
                                 context: ThreadContext, _ mem: any KernelGuestMemory) {
        let port = UInt32(truncatingIfNeeded: kn.ident)
        e.fflags = 0
        e.data = Int64(port)
        guard kn.fflags & MachRcv.msg != 0, let ipc = machIPC else { return }
        var options = kn.fflags
        var buffer = kn.ext[0], size = kn.ext[1]
        let carving = size == 0
        if carving {
            options |= MachRcv.large | MachRcv.largeIdentity
            buffer = area.base
            size = area.size
        }
        guard let r = ipc.receiveForKevent(port: port, options: options, buffer: buffer, size: size, context: context, memory: mem) else {
            logFilterOnce(EVFilter.machport, "MACH_RCV_MSG delivery is not supported by MachIPC; delivered without a message")
            return
        }
        e.fflags = r.returnCode
        e.data = Int64(bitPattern: r.data)
        e.ext[1] = r.size
        e.ext[2] = r.priorityAndQoS
        e.ext[3] = r.auxiliarySize
        e.ext[0] = buffer
        if carving, r.returnCode == 0 {
            let used = min(r.size + r.auxiliarySize, area.size)
            if area.stackData {
                // Move the message to the top of the area.
                let top = area.base + area.size - used
                if top != buffer, let bytes = try? mem.read(va: buffer, count: Int(used)) { try? mem.write(va: top, bytes: bytes) }
                e.ext[0] = top
                area.size -= used
            } else {
                area.base += used
                area.size -= used
            }
        }
    }

    /// `MachIPC`'s hook: a message was queued on `name` (a port or a set).
    func machPortMessageQueued(_ name: UInt32) {
        let queues = allKQueues
        for kq in queues {
            for kn in kq.knotes where kn.filter == EVFilter.machport && UInt32(truncatingIfNeeded: kn.ident) == name {
                kn.active = true
                activated(kn)
            }
        }
    }

    /// `MachIPC`'s hook: the receive right or port set `name` left the space.
    func machPortReceiveRightGone(_ name: UInt32) {
        let queues = allKQueues
        for kq in queues {
            for kn in kq.knotes where kn.filter == EVFilter.machport && UInt32(truncatingIfNeeded: kn.ident) == name {
                kn.receiveGone = true
                kn.active = true
                activated(kn)
            }
        }
    }

    // MARK: kqueue_workloop_ctl

    func kqueueWorkloopCtl(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let cmd = UInt32(truncatingIfNeeded: a[0])
        call = "kqueue_workloop_ctl(cmd=\(cmd), options=\(hx(a[1])), params=\(hx(a[2])), size=\(a[3]))"
        let size = Int(min(a[3], 36))
        guard size >= 16 else { throw Failure(errno: Errno.EINVAL) }
        var p = try mem.read(va: a[2], count: size)
        p += [UInt8](repeating: 0, count: 36 - size)
        let flags = p.readLE(Int32.self, at: 4)
        let id = p.readLE(UInt64.self, at: 8)
        guard id != 0, id != UInt64.max else { throw Failure(errno: Errno.EINVAL) }
        switch cmd {
        case 1:
            guard flags & 0x1F != 0 else { throw Failure(errno: Errno.EINVAL) }
            if flags & 1 != 0, !(1...63).contains(p.readLE(Int32.self, at: 16)) { throw Failure(errno: Errno.EINVAL) }
            if flags & 4 != 0 {
                guard (1...100).contains(p.readLE(Int32.self, at: 24)), (1...0xFF_FFFF).contains(p.readLE(Int32.self, at: 28)) else {
                    throw Failure(errno: Errno.EINVAL)
                }
            }
            guard kevents.workloops[id] == nil else { throw Failure(errno: Self.EEXIST) }
            let wl = KQueue(kind: .workloop, workloopID: id)
            wl.createReference = true
            wl.fixedPriority = flags & 1 != 0
            kevents.workloops[id] = wl
            call += " [created \(hx(id))]"
            return 0
        case 2:
            guard let wl = kevents.workloops[id], wl.createReference else { throw Failure(errno: Errno.ENOENT) }
            wl.createReference = false
            maybeFreeWorkloop(wl)
            return 0
        default:
            throw Failure(errno: Errno.EINVAL)
        }
    }
}

/// The timer thread's references (the kernel is held weakly).
final class TimerThreadBox: @unchecked Sendable {
    weak var kernel: DarwinKernel?
    let lock: KernelLock
    let wake: WaitQueue

    init(kernel: DarwinKernel, lock: KernelLock, wake: WaitQueue) {
        self.kernel = kernel
        self.lock = lock
        self.wake = wake
    }

    func run() {
        lock.withLock {
            while !lock.isTerminated {
                var next: UInt64?
                do {
                    // Stage 4b: the lock outlives one image; stop with it.
                    guard let k = kernel, !k.isTerminating else { return }
                    next = k.fireDueTimers()
                    k.pumpWorkqueue(nil)
                }
                let cap = KernelClock.deadline(afterNanoseconds: 1_000_000_000)
                _ = wake.wait(on: lock, deadline: min(next ?? cap, cap))
            }
        }
    }
}

// MARK: - Stage 4b: kqueue descriptors, EVFILT_PROC, EVFILT_SIGNAL, EVFILT_READ/WRITE

/// `NOTE_*` of EVFILT_PROC (`processes.md` §2.8).
public enum NoteProc {
    public static let exit: UInt32 = 0x8000_0000
    public static let fork: UInt32 = 0x4000_0000
    public static let exec: UInt32 = 0x2000_0000
    public static let reap: UInt32 = 0x1000_0000
    public static let signal: UInt32 = 0x0800_0000
    public static let exitStatus: UInt32 = 0x0400_0000
    public static let exitDetail: UInt32 = 0x0200_0000
    /// NOTE_TRACK, NOTE_TRACKERR, NOTE_CHILD: refused with ENOTSUP.
    static let tracking: UInt32 = 0x7
}

/// A `kqueue()` descriptor (stage 4b). It belongs to the process that made
/// it (kqueues are not inherited and cannot be sent). It is itself readable
/// (EVFILT_READ on a kqueue fd) while it has deliverable events.
final class KQueueObject: KernelDescriptorObject {
    let queue: KQueue
    weak var kernel: DarwinKernel?
    private var observers: [Int: () -> Void] = [:]
    private var nextToken = 1

    init(queue: KQueue, kernel: DarwinKernel) {
        self.queue = queue
        self.kernel = kernel
    }

    /// `fstat` of a kqueue reports mode 0.
    var fileType: UInt16 { 0 }
    /// Not inherited, not sendable (`processes.md` §1.11, §4.9).
    var isConfined: Bool { true }

    func lastReferenceClosed() {
        kernel?.closeDescriptorKQueue(self)
        observers.removeAll()
    }

    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        let n = kernel?.deliverableCount(queue) ?? 0
        return (n > 0, Int64(n), false)
    }

    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool) { (false, 0, false) }

    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        observers[token] = observer
        return token
    }

    func removeReadinessObserver(_ token: Int) { observers[token] = nil }

    func notifyObservers() {
        for o in observers.values { o() }
    }
}

extension DarwinKernel {
    /// Every kqueue of this image.
    var allKQueues: [KQueue] {
        var queues: [KQueue] = Array(kevents.workloops.values) + Array(kevents.descriptorQueues.values)
            + Array(kevents.objectQueues.values)
        if let w = kevents.workq { queues.append(w) }
        return queues
    }

    /// The descriptor kqueue behind `fd`: a `kqueue()` object of this
    /// process, or one installed with `installDescriptorKQueue`.
    func descriptorKQueue(_ fd: Int32) -> KQueue? {
        if let object = ((try? fileSystem.object(for: fd)) ?? nil) as? KQueueObject, object.kernel === self {
            return object.queue
        }
        return kevents.descriptorQueues[fd]
    }

    /// How many knotes of `kq` a scan would deliver now.
    func deliverableCount(_ kq: KQueue) -> Int {
        kq.knotes.reduce(0) { $0 + (deliverable($1, in: kq) ? 1 : 0) }
    }

    /// `kqueue()` (BSD 362): a new descriptor kqueue.
    func kqueueCall(_ call: inout String) throws -> UInt64 {
        call = "kqueue()"
        let kq = KQueue(kind: .descriptor(-1))
        let object = KQueueObject(queue: kq, kernel: self)
        kq.object = object
        let fd = try fileSystem.installObject(object, statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
        kevents.objectQueues[ObjectIdentifier(kq)] = kq
        call += " [kqueue fd \(fd)]"
        return UInt64(UInt32(bitPattern: fd))
    }

    /// The last descriptor of a `kqueue()` queue closed: its knotes go.
    func closeDescriptorKQueue(_ object: KQueueObject) {
        let kq = object.queue
        for kn in kq.knotes { drop(kn) }
        kq.waiters.wakeAll()
        kevents.objectQueues[ObjectIdentifier(kq)] = nil
    }

    /// The image ends (exit or exec): every knote is dropped, so that no
    /// other process keeps calling into this kernel.
    func tearDownKEvents() {
        for kq in allKQueues {
            for kn in kq.knotes {
                kn.dropped = true
                kn.active = false
                if let token = kn.observerToken {
                    kn.object?.removeReadinessObserver(token)
                    kn.observerToken = nil
                }
                if kn.isSyncKnote { kn.syncWaiters.wakeAll() }
            }
            kq.waiters.wakeAll()
        }
        kevents.timers.removeAll()
    }

    /// `fileSystem.descriptorClosed`: descriptor `fd` closed (by close,
    /// dup2, exec, or exit). Its EVFILT_READ/WRITE/VNODE knotes go, as does
    /// its directory cursor.
    func descriptorWasClosed(_ fd: Int32) {
        lock.withLock {
            extended.directoryCursors[fd] = nil
            guard !isTerminating else { return }
            for kq in allKQueues {
                for kn in kq.knotes where kn.ident == UInt64(UInt32(bitPattern: fd))
                    && (kn.filter == EVFilter.read || kn.filter == EVFilter.write || kn.filter == EVFilter.vnode) {
                    drop(kn)
                }
            }
        }
    }

    // MARK: EVFILT_PROC

    /// Attaches a process watch (`processes.md` §2.8).
    func attachProcess(_ kn: Knote, _ c: KEventRecord) -> Int32? {
        guard c.fflags & NoteProc.tracking == 0 else { return Errno.ENOTSUP }
        guard c.ident <= UInt64(Int32.max), let target = system.processes[Int32(c.ident)], target.state != .zombie else {
            return Errno.ESRCH
        }
        let both = NoteProc.exit | NoteProc.exitStatus
        if c.fflags & both == both, target.ppid != pid, !canSignal(target) { return Self.EACCES }
        kn.flags |= EV.clear
        kn.data = 0
        target.watchers.append(ProcessWatch(knote: kn, kernel: self))
        return nil
    }

    static let EACCES: Int32 = 13

    /// The system posts an event of a watched process to one of our knotes.
    func processEventFired(_ kn: Knote, event: UInt32, data: Int64) {
        guard !kn.dropped else { return }
        var wanted = kn.fflags & event
        if event == NoteProc.exit {
            kn.procExited = true
            if kn.fflags & NoteProc.exitStatus != 0 {
                kn.procData = data
                wanted |= NoteProc.exitStatus
            }
        }
        kn.procFired |= wanted
        if wanted != 0 || event == NoteProc.exit {
            kn.active = true
            activated(kn)
        }
    }

    // MARK: EVFILT_SIGNAL

    /// Counts one process-directed posting of `signal` (even when ignored).
    func countSignalForKEvent(_ signal: Int32) {
        for kq in allKQueues {
            for kn in kq.knotes where kn.filter == EVFilter.signal && kn.ident == UInt64(signal) && !kn.dropped {
                kn.signalCount += 1
                kn.active = true
                activated(kn)
            }
        }
    }

    // MARK: EVFILT_READ / EVFILT_WRITE

    private func attachDescriptor(_ kn: Knote, _ c: KEventRecord) -> Int32? {
        guard c.ident <= UInt64(Int32.max) else { return Errno.EBADF }
        let fd = Int32(c.ident)
        let object: DarwinDescriptorObject?
        do {
            _ = try fileSystem.closeOnExec(fd)  // EBADF for a closed descriptor
            object = try fileSystem.object(for: fd)
        } catch {
            return errno(of: error, default: Errno.EBADF)
        }
        if let o = object as? KernelDescriptorObject {
            kn.object = o
            kn.observerToken = o.addReadinessObserver { [weak self, weak kn] in
                guard let self, let kn, !kn.dropped else { return }
                kn.active = true
                self.activated(kn)
            }
            kn.active = true
        } else if object != nil {
            logFilterOnce(kn.filter, "a descriptor object without readiness never fires")
        } else {
            // A host file or the console: always readable and writable.
            kn.hostDescriptor = true
            kn.active = true
        }
        return nil
    }

    /// The readiness of a descriptor knote now.
    func descriptorState(_ kn: Knote) -> (ready: Bool, data: Int64, eof: Bool) {
        if kn.hostDescriptor {
            if kn.filter == EVFilter.write { return (true, 65536, false) }
            let size = (try? fileSystem.fstat(Int32(truncatingIfNeeded: kn.ident)).size) ?? 0
            return (true, max(0, size), false)
        }
        guard let o = kn.object else { return (false, 0, false) }
        let r = kn.filter == EVFilter.read ? o.readReadiness() : o.writeReadiness()
        return (r.ready || r.eof, r.data, r.eof)
    }
}
