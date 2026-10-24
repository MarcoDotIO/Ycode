import Foundation
import YcodeDarwinABI

// select (BSD 93) and pselect (BSD 394), with their `_nocancel` forms (407,
// 395; `BSD.nocancelAliases` maps them). The semantics are in
// `specs/simulator/select.md`: descriptor bitmaps of `nd` bits in 32-bit
// words, read/write readiness over Ycode's descriptor objects, no
// exceptional conditions, a timeout (NULL waits, zero polls), EBADF for a set
// bit naming a closed descriptor, EINTR when the thread is interrupted.
//
// A select that finds nothing ready blocks on a private `WaitQueue` with
// the kernel lock released. It registers a readiness observer on every
// watched descriptor object (the mechanism kevent's EVFILT_READ/WRITE knotes
// use), so a state change wakes it; it then scans again.
//
// Before this, select was unimplemented: a guest that sleeps with
// `select(nd, sets, &timeout)` got ENOSYS at once and spun (SpringBoard:
// ~764k calls per boot, 21 s of kernel-lock hold). The first version of
// this file was the speed analyst S's prototype (candidate C4).

enum SelectBSD {
    static let select = 93
    static let pselect = 394
    /// `__DARWIN_NFDBITS`: bits per `fd_mask` word (`sys/_types/_fd_def.h`).
    static let wordBits = 32
    /// The largest `tv_sec` a timeout may have (select(2): "too large").
    static let maxSeconds: Int64 = 100_000_000
    /// The three sets, in argument order.
    static let readKind = 0, writeKind = 1, exceptKind = 2
}

/// Diagnostics for select (`YCODE_DEBUG_SELECT_STATS=1`): per image, how
/// select is called and how its waits end. Printed every `reportEvery` calls.
struct SelectStats {
    static let enabled = getenv("YCODE_DEBUG_SELECT_STATS").map { String(cString: $0) == "1" } ?? false
    static let reportEvery: UInt64 = 5000

    var calls: UInt64 = 0
    /// nd == 0 or no set given: a pure sleep.
    var sleeps: UInt64 = 0
    /// A zero timeout.
    var polls: UInt64 = 0
    /// NULL timeout (wait forever).
    var forever: UInt64 = 0
    var readyAtOnce: UInt64 = 0
    var blocked: UInt64 = 0
    var wakeups: UInt64 = 0
    /// Wakeups after which nothing was ready (the wait went on).
    var emptyWakeups: UInt64 = 0
    var timeouts: UInt64 = 0
    var interrupted: UInt64 = 0
    var errors: UInt64 = 0
    var waitedNs: UInt64 = 0
    /// Timeout histogram: 0, <1 ms, <10 ms, <100 ms, <1 s, longer, NULL.
    var timeoutHistogram: [UInt64] = [0, 0, 0, 0, 0, 0, 0]
    var maxND: Int32 = 0
}

extension DarwinKernel {
    /// select (93) and pselect (394).
    func selectCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let isPselect = n == SelectBSD.pselect
        let requested = Int32(truncatingIfNeeded: a[0])
        call.set("\(isPselect ? "pselect" : "select")(nd=\(requested), in=\(hx(a[1])), ou=\(hx(a[2])), ex=\(hx(a[3])), "
            + "\(isPselect ? "ts" : "tv")=\(hx(a[4]))\(isPselect ? ", mask=\(hx(a[5]))" : ""))")
        let stats = SelectStats.enabled
        if stats { extended.selectStats.calls += 1 }
        defer { if stats { reportSelectStatsIfDue() } }
        do {
            return try selectBody(isPselect, requested, a, &call, mem)
        } catch {
            if stats { extended.selectStats.errors += 1 }
            throw error
        }
    }

    private func selectBody(_ isPselect: Bool, _ requested: Int32, _ a: [UInt64], _ call: inout CallText,
                            _ mem: any KernelGuestMemory) throws -> BSDResult {
        let stats = SelectStats.enabled
        guard requested >= 0 else { throw Failure(errno: Errno.EINVAL) }

        // The timeout: nil = wait forever; 0 = poll.
        var timeoutNs: UInt64?
        if a[4] != 0 {
            let t = try mem.read(va: a[4], count: 16)
            let seconds = t.readLE(Int64.self, at: 0)
            // select: `struct timeval` (tv_usec is an int32 at +8);
            // pselect: `struct timespec` (tv_nsec is an int64 at +8).
            let sub = isPselect ? t.readLE(Int64.self, at: 8) : Int64(t.readLE(Int32.self, at: 8))
            let limit: Int64 = isPselect ? 1_000_000_000 : 1_000_000
            guard seconds >= 0, seconds <= SelectBSD.maxSeconds, sub >= 0, sub < limit else {
                throw Failure(errno: Errno.EINVAL)
            }
            timeoutNs = UInt64(seconds) * 1_000_000_000 + UInt64(sub) * (isPselect ? 1 : 1000)
        }
        let pointers = [a[1], a[2], a[3]]
        if stats {
            if requested == 0 || pointers.allSatisfy({ $0 == 0 }) { extended.selectStats.sleeps += 1 }
            extended.selectStats.maxND = max(extended.selectStats.maxND, requested)
            let bucket: Int
            switch timeoutNs {
            case nil: bucket = 6; extended.selectStats.forever += 1
            case 0: bucket = 0; extended.selectStats.polls += 1
            case let ns?: bucket = ns < 1_000_000 ? 1 : ns < 10_000_000 ? 2 : ns < 100_000_000 ? 3 : ns < 1_000_000_000 ? 4 : 5
            }
            extended.selectStats.timeoutHistogram[bucket] += 1
        }

        // pselect's mask replaces the signal mask for the call.
        var savedMask: UInt32?
        if isPselect, a[5] != 0 {
            let mask = try mem.read(va: a[5], count: 4).readLE(UInt32.self, at: 0)
            savedMask = extended.signalMask
            extended.signalMask = mask & ~SignalConstant.unblockable
        }
        defer { if let savedMask { extended.signalMask = savedMask } }

        // As xnu clamps `nd` to the size of its descriptor table, Ycode
        // clamps it to the highest open descriptor + 1: set bits past it are
        // ignored, and only `howmany(nd, 32)` words of each set are read and
        // written back.
        var nd = requested
        if nd > 0, pointers.contains(where: { $0 != 0 }) {
            nd = min(nd, (fileSystem.openDescriptors.last ?? -1) + 1)
        }
        let words = (Int(nd) + SelectBSD.wordBits - 1) / SelectBSD.wordBits
        var given: [[UInt32]] = [[], [], []]
        for k in 0..<3 where pointers[k] != 0 && words > 0 {
            let raw = try mem.read(va: pointers[k], count: words * 4)
            given[k] = (0..<words).map { raw.readLE(UInt32.self, at: $0 * 4) }
        }

        // The descriptors asked about (a set bit for one that is not open is EBADF).
        var watched = try selectWatchedDescriptors(given, nd: nd)
        let deadline = timeoutNs.map { KernelClock.deadline(afterNanoseconds: $0) }

        var result = selectScan(given, watched)
        if result.count > 0 || timeoutNs == 0 {
            if stats, result.count > 0 { extended.selectStats.readyAtOnce += 1 }
            return try selectFinish(result, pointers, &call, mem)
        }
        if isPselect, extended.pendingSignals & ~extended.signalMask != 0 { throw Failure(errno: Self.EINTR) }

        // Wait for a readiness change, the deadline, or an interruption. The
        // observers run with the kernel lock held, and this thread holds it
        // from the scan above until `wait` queues it, so no change is missed.
        let queue = WaitQueue()
        var tokens: [(KernelDescriptorObject, Int)] = []
        var seen = Set<ObjectIdentifier>()
        for w in watched {
            guard let o = w.object as? KernelDescriptorObject, seen.insert(ObjectIdentifier(o)).inserted else { continue }
            tokens.append((o, o.addReadinessObserver { queue.wakeAll() }))
        }
        defer { for (o, token) in tokens { o.removeReadinessObserver(token) } }
        if stats { extended.selectStats.blocked += 1 }
        let waitStart = stats ? KernelClock.now() : 0
        defer { if stats { extended.selectStats.waitedNs &+= KernelClock.now() &- waitStart } }
        while true {
            switch queue.wait(on: lock, deadline: deadline) {
            case .interrupted:
                if stats { extended.selectStats.interrupted += 1 }
                call += " [interrupted]"
                throw Failure(errno: Self.EINTR)
            case .timedOut:
                if stats { extended.selectStats.timeouts += 1 }
                result = (0, given.map { [UInt32](repeating: 0, count: $0.count) })
                return try selectFinish(result, pointers, &call, mem)
            case .woken:
                if stats { extended.selectStats.wakeups += 1 }
                // A descriptor closed meanwhile is EBADF, as on the first scan.
                watched = try selectWatchedDescriptors(given, nd: nd)
                result = selectScan(given, watched)
                if result.count > 0 { return try selectFinish(result, pointers, &call, mem) }
                if stats { extended.selectStats.emptyWakeups += 1 }
            }
        }
    }

    /// One descriptor named in the sets.
    struct SelectWatched {
        var fd: Int32
        /// nil: a host file or the console (always ready).
        var object: DarwinDescriptorObject?
    }

    /// The open descriptors named by set bits below `nd`, ascending; EBADF
    /// when one is not open.
    private func selectWatchedDescriptors(_ given: [[UInt32]], nd: Int32) throws -> [SelectWatched] {
        var union: [UInt32] = []
        for set in given where !set.isEmpty {
            if union.isEmpty { union = set } else { for w in set.indices { union[w] |= set[w] } }
        }
        var out: [SelectWatched] = []
        for (w, word) in union.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                let bit = bits.trailingZeroBitCount
                bits &= bits - 1
                let fd = Int32(w * SelectBSD.wordBits + bit)
                guard fd < nd else { break }
                // nil object: a host file or the console; a throw: not open.
                let object: DarwinDescriptorObject?
                do { object = try fileSystem.object(for: fd) } catch { throw Failure(errno: Errno.EBADF) }
                out.append(SelectWatched(fd: fd, object: object))
            }
        }
        return out
    }

    /// Which of the asked-for descriptors are ready: the output sets (same
    /// word counts as the input) and the number of bits set in them.
    private func selectScan(_ given: [[UInt32]], _ watched: [SelectWatched]) -> (count: Int, sets: [[UInt32]]) {
        var out: [[UInt32]] = given.map { [UInt32](repeating: 0, count: $0.count) }
        var count = 0
        for w in watched {
            let word = Int(w.fd) / SelectBSD.wordBits
            let bit = UInt32(1) << UInt32(Int(w.fd) % SelectBSD.wordBits)
            for kind in [SelectBSD.readKind, SelectBSD.writeKind] where word < given[kind].count && given[kind][word] & bit != 0 {
                if Self.selectReady(w.object, write: kind == SelectBSD.writeKind) {
                    out[kind][word] |= bit
                    count += 1
                }
            }
            // No descriptor has an exceptional condition (no out-of-band data).
        }
        return (count, out)
    }

    /// Readiness of one descriptor: a host file or the console is always
    /// ready; a pipe, socket or kqueue by its state (end of file and a
    /// vanished peer count as ready, so the next call does not block); any
    /// other object is never ready.
    static func selectReady(_ object: DarwinDescriptorObject?, write: Bool) -> Bool {
        guard let object else { return true }
        guard let o = object as? KernelDescriptorObject else { return false }
        let r = write ? o.writeReadiness() : o.readReadiness()
        return r.ready || r.eof
    }

    /// Writes the result sets back (every set given) and returns the count.
    private func selectFinish(_ result: (count: Int, sets: [[UInt32]]), _ pointers: [UInt64], _ call: inout CallText,
                              _ mem: any KernelGuestMemory) throws -> BSDResult {
        for k in 0..<3 where pointers[k] != 0 {
            let set = result.sets[k]
            guard !set.isEmpty else { continue }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(set.count * 4)
            for v in set { bytes.appendLE(v) }
            try mem.write(va: pointers[k], bytes: bytes)
        }
        call += " [\(result.count) ready]"
        return .value(UInt64(result.count))
    }

    private func reportSelectStatsIfDue() {
        let s = extended.selectStats
        guard s.calls % SelectStats.reportEvery == 0 else { return }
        let name = processRecord?.comm ?? "?"
        let h = s.timeoutHistogram.map(String.init).joined(separator: "/")
        let line = "ycode-select-stats: pid \(pid) (\(name)): \(s.calls) calls, sleeps \(s.sleeps), polls \(s.polls), "
            + "forever \(s.forever), ready at once \(s.readyAtOnce), blocked \(s.blocked) (waited \(s.waitedNs / 1_000_000) ms), "
            + "wakeups \(s.wakeups) (empty \(s.emptyWakeups)), timeouts \(s.timeouts), interrupted \(s.interrupted), "
            + "errors \(s.errors), max nd \(s.maxND), timeout 0/<1ms/<10ms/<100ms/<1s/more/NULL \(h)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
