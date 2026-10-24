import Foundation
import YcodeDarwinABI

// Shared machinery of the stage-4b descriptor objects (pipes and AF_UNIX
// sockets, `specs/simulator/stage4b-contract.md` §6): the wait queue and
// readiness observers of one object, the identity of the process that used
// it, and a byte queue. Owner: agent F.

typealias Code = DarwinErrnoCode

/// A Darwin errno as a thrown error.
func fail(_ errno: Int32) -> DarwinErrnoError { DarwinErrnoError(errno) }

/// The wait queue and the readiness observers of one kernel object. Every
/// call is made with the kernel lock held.
final class ObjectSignals {
    /// Threads blocked on the object (readers, writers, acceptors). Every
    /// state change wakes all of them; each re-checks its own condition.
    let waiters = WaitQueue()
    private var observers: [Int: () -> Void] = [:]
    private var nextToken = 1

    func addObserver(_ observer: @escaping () -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: Int) { observers[token] = nil }

    /// The object's state changed: wake the blocked threads and tell the
    /// observers (kevent) that readiness may have changed.
    func fire() {
        waiters.wakeAll()
        for token in observers.keys.sorted() {
            observers[token]?()
        }
    }
}

/// The process that made or last used a socket (`LOCAL_PEERPID`,
/// `LOCAL_PEERCRED`, `LOCAL_PEERTOKEN`; `processes.md` §5.6): its pid and pid
/// version at that moment, its credentials, and its kernel (weak).
struct DescriptorUser {
    var pid: Int32
    var pidVersion: UInt32
    var uid: UInt32
    var gid: UInt32
    weak var kernel: DarwinKernel?

    /// `struct xucred` (76 bytes, `processes.md` §5.1): version 0, uid, one
    /// group (the gid).
    var xucred: [UInt8] {
        var b = [UInt8](repeating: 0, count: 76)
        b.putLE(UInt32(0), at: 0)
        b.putLE(uid, at: 4)
        b.putLE(Int16(1), at: 8)
        b.putLE(gid, at: 12)
        return b
    }
}

extension DarwinKernel {
    /// This image as a socket user, now.
    var descriptorUser: DescriptorUser {
        DescriptorUser(pid: pid, pidVersion: pidVersion, uid: DarwinFileSystem.guestUID,
                       gid: DarwinFileSystem.guestGID, kernel: self)
    }

    /// The 32-byte audit token of this image (`processes.md` §4.5): auid,
    /// euid, egid, ruid, rgid, pid, asid, pid version. The audit session id
    /// is 0, as in the Mach trailers Ycode sends today.
    // CONTRACT-REQUEST(M/P): one shared audit-token builder (with the asid
    // the system picks) for trailers, task_info, and LOCAL_PEERTOKEN.
    var descriptorAuditToken: [UInt8] {
        let uid = DarwinFileSystem.guestUID, gid = DarwinFileSystem.guestGID
        var b: [UInt8] = []
        for v in [uid, uid, gid, uid, gid, UInt32(bitPattern: pid), 0, pidVersion] { b.appendLE(v) }
        return b
    }

    /// Blocks the calling thread on `signals` until the object changes,
    /// `deadline` (absolute host ns) passes, or the thread is interrupted.
    /// Returns false on timeout; throws EINTR when interrupted.
    func waitOnObject(_ signals: ObjectSignals, deadline: UInt64?) throws -> Bool {
        switch signals.waiters.wait(on: lock, deadline: deadline) {
        case .woken: return true
        case .timedOut: return false
        case .interrupted: throw fail(Code.EINTR)
        }
    }
}

/// A FIFO of bytes with cheap removal at the front.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append<C: Collection>(contentsOf bytes: C) where C.Element == UInt8 {
        storage.append(contentsOf: bytes)
    }

    /// The first `n` bytes (fewer if the queue is shorter), not removed.
    func peek(_ n: Int) -> [UInt8] {
        Array(storage[head..<(head + min(n, count))])
    }

    /// Removes and returns the first `n` bytes (fewer if shorter).
    mutating func take(_ n: Int) -> [UInt8] {
        let out = peek(n)
        head += out.count
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 4096 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return out
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}

/// Inode numbers for pipes and sockets (`fstat` `st_ino`): unique per object
/// while the VMM runs.
enum DescriptorInodes {
    private static let mutex = RecursiveMutex(name: "descriptor inodes")
    nonisolated(unsafe) private static var next: UInt64 = 0x7964_0000_0000_0001

    static func make() -> UInt64 {
        mutex.lock()
        defer { mutex.unlock() }
        let v = next
        next += 1
        return v
    }
}

/// The calendar time for `st_atime` and friends.
func descriptorNow() -> DarwinTimespec {
    let t = Date().timeIntervalSince1970
    let s = t.rounded(.down)
    return DarwinTimespec(sec: Int64(s), nsec: Int64((t - s) * 1e9))
}

/// SIGPIPE (`processes.md` conventions).
let descriptorSIGPIPE: Int32 = 13
