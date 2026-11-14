import Foundation
import Synchronization

// Fine-lock stalls by holder (`YCODE_LOCK_STALL_STATS=1`, diagnostics only;
// `specs/simulator/boot-profile.md` §27.2).
//
// A fine lock (an image's event lock, the port lock G) is a host mutex. On
// xnu the matching locks are spinlocks held with preemption disabled, so a
// holder always finishes its hold; a Ycode holder is an ordinary host thread
// that the host can deschedule mid-hold, and every waiter then waits until
// it runs again. This records, for every contended fine-lock acquisition
// that waited `YCODE_LOCK_STALL_MIN_US` (default 200, the holder promotion's
// delay) or more, who held the lock when the wait began: a thread of the
// waiter's own image, a thread of another image (the EVFILT_MACHPORT hook a
// sender runs under the receiver's event lock), posted work run without a
// guest context, or a host service thread; and that holder's applied host
// class. The `sched:` report lists the largest groups by the waiting image.

public enum LockStallStats {
    /// `YCODE_LOCK_STALL_STATS=1`: on.
    nonisolated(unsafe) public static var enabled = getenv("YCODE_LOCK_STALL_STATS").map { String(cString: $0) == "1" } ?? false
    /// The shortest wait counted (ns).
    nonisolated(unsafe) static var minimumNanoseconds =
        UInt64(getenv("YCODE_LOCK_STALL_MIN_US").flatMap { Double(String(cString: $0)) } ?? 200) * 1000

    /// The holder's kind, relative to the waiter.
    enum Holder: Int { case none = 0, ownImage, otherImage, posted, hostThread }
    static let holderNames = ["none", "own image", "other image", "posted work", "host thread"]

    struct Key: Hashable {
        let level: Int
        let waiter: String
        let holder: Holder
        let holderClass: Int
    }

    /// Waits and their time per key; only waits past the minimum reach it.
    static let table = Mutex<[Key: (count: Int, ns: UInt64)]>([:])
    static let stalls = Atomic<Int>(0)
    static let stallNanoseconds = Atomic<UInt64>(0)

    /// The holder word a lock publishes at each acquisition (when on): bits
    /// 0–3 the holder's applied host class + 1, bit 4 posted work, bit 5 a
    /// guest context, bits 8–63 the holder image's identity (0: none).
    @inline(__always) static func word(context: ThreadContext?, posted: Bool) -> UInt64 {
        let applied = UInt64(max(-1, min(SchedClass.interactive, HostSched.appliedClass())) + 1)
        guard let context, let kernel = context.kernel else { return applied | (posted ? 0x10 : 0) }
        return applied | 0x20 | UInt64(UInt(bitPattern: ObjectIdentifier(kernel).hashValue)) << 8
    }

    /// A contended acquisition by `context` waited `ns` with `word` published
    /// by the holder when the wait began.
    static func note(level: Int, context: ThreadContext?, word: UInt64, ns: UInt64) {
        guard ns >= minimumNanoseconds else { return }
        stalls.wrappingAdd(1, ordering: .relaxed)
        stallNanoseconds.wrappingAdd(ns, ordering: .relaxed)
        let holder: Holder
        if word == 0 {
            holder = .none
        } else if word & 0x20 != 0 {
            let mine = context?.kernel.map { UInt64(UInt(bitPattern: ObjectIdentifier($0).hashValue)) << 8 } ?? 0
            holder = (word & ~UInt64(0xFF)) == mine ? .ownImage : .otherImage
        } else {
            holder = word & 0x10 != 0 ? .posted : .hostThread
        }
        let name = context?.kernel?.schedProcessCache?.name ?? (context == nil ? "host" : "?")
        let key = Key(level: level, waiter: name, holder: holder, holderClass: Int(word & 0xF) - 1)
        table.withLock { t in
            let old = t[key] ?? (0, 0)
            t[key] = (old.count + 1, old.ns &+ ns)
        }
    }

    /// The calling host thread's CPU time (ns).
    static func threadCPU() -> UInt64 {
        var ts = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0 else { return 0 }
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// Long holds (past the minimum): where the time went while the lock
    /// was held, by lock level, holder image and trap: the holder running
    /// (its CPU time), waiting for another kernel lock, or neither (off a
    /// host CPU: preempted, or in a futex outside the lock waits).
    struct HoldKey: Hashable {
        let level: Int
        let holder: String
        let trap: Int64
    }
    static let holds = Mutex<[HoldKey: (count: Int, wall: UInt64, cpu: UInt64, nested: UInt64)]>([:])

    static func noteHold(level: Int, context: ThreadContext?, held: UInt64, cpu: UInt64, nested: UInt64) {
        let key = HoldKey(level: level, holder: context?.kernel?.schedProcessCache?.name ?? (context == nil ? "no context" : "?"),
                          trap: context?.trapInProgress.map { Int64(bitPattern: $0.x16) } ?? Int64.min)
        holds.withLock { t in
            let old = t[key] ?? (0, 0, 0, 0)
            t[key] = (old.count + 1, old.wall &+ held, old.cpu &+ min(cpu, held), old.nested &+ min(nested, held))
        }
    }

    /// The report's part ("" when off): the total and the largest groups.
    public static var report: String {
        guard enabled else { return "" }
        let rows = table.withLock { $0.sorted { $0.value.ns > $1.value.ns } }.prefix(14)
        let level = ["L0", "event lock", "port lock"]
        return "; fine-lock stalls ≥ \(minimumNanoseconds / 1000) µs \(stalls.load(ordering: .relaxed)), "
            + "\(stallNanoseconds.load(ordering: .relaxed) / 1_000_000) ms ("
            + rows.map { k, v in
                "\(k.level < level.count ? level[k.level] : "L\(k.level)") of \(k.waiter) held by \(holderNames[k.holder.rawValue]) "
                    + "\(k.holderClass >= 0 ? SchedClass.name(k.holderClass) : "-"): \(v.count), \(v.ns / 1_000_000) ms"
            }.joined(separator: "; ") + ")" + holdReport
    }

    static var holdReport: String {
        let all = holds.withLock { $0 }
        let rows = all.sorted { $0.value.wall > $1.value.wall }.prefix(14)
        let level = ["L0", "event lock", "port lock"]
        var byLevel = [Int: (count: Int, wall: UInt64, cpu: UInt64, nested: UInt64)]()
        for (k, v) in all {
            let o = byLevel[k.level] ?? (0, 0, 0, 0)
            byLevel[k.level] = (o.count + v.count, o.wall &+ v.wall, o.cpu &+ v.cpu, o.nested &+ v.nested)
        }
        let levels = byLevel.sorted { $0.key < $1.key }.map { l, v in
            "\(l < level.count ? level[l] : "L\(l)") \(v.count), \(v.wall / 1_000_000), \(v.cpu / 1_000_000), \(v.nested / 1_000_000)"
        }.joined(separator: "; ")
        return portLockTotals + "; long holds by level (count; wall, of it CPU, nested lock waits, ms): \(levels)"
            + "; long holds (\(minimumNanoseconds / 1000) µs or more; wall, of it CPU, nested lock waits, ms): "
            + rows.map { k, v in
                "\(k.level < level.count ? level[k.level] : "L\(k.level)") by \(k.holder) in \(k.trap == Int64.min ? "-" : String(k.trap)): "
                    + "\(v.count), \(v.wall / 1_000_000), \(v.cpu / 1_000_000), \(v.nested / 1_000_000)"
            }.joined(separator: "; ")
    }
}
