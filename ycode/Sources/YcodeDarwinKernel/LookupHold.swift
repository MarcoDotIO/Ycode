import Foundation
import Synchronization

// Held answers to failed look-ups of named services (`YCODE_LOOKUP_HOLD`,
// off by default; `specs/simulator/boot-profile.md` §18).
//
// launchd_sim answers a bootstrap look-up of a name nobody publishes at once
// with an error (`bootstrap-wire.md` §4.2: `{error: 3}` for an XPC look-up,
// 1102 for a legacy one). On the reference, dasd's first synchronous read of
// a CoreDuet context key, whose service name the simulator does not publish,
// waited 20–71 s before that failure reached it, and dasd's other work (with
// SpringBoard's notification task) waited behind it until after the home
// screen (§17.6, §17.7). Whether that wait is the reference host's load or a
// property of its look-up path is open (§17.9).
//
// This switch reproduces the wait for an experiment: the failure reply to an
// XPC (804) or legacy (207) look-up of a listed name is held by the kernel
// and delivered no earlier than a fixed time after the simulator started; a
// reply that grants the name (a port) and every reply after that time pass at
// once. The guest's launchd_sim is untouched: the kernel notes the request's
// reply port when the request is sent and holds the error reply sent to it.
//
//   YCODE_LOOKUP_HOLD=<name>[,<name>...]  the names (exact match)
//   YCODE_LOOKUP_HOLD_UNTIL=<seconds>     the release time after the start
//                                         of the Mach system (default 40)
//
// Held replies are not part of a snapshot.

enum LookupHold {
    /// The listed names (empty: off).
    nonisolated(unsafe) static var names: [String] = parseNames(getenv("YCODE_LOOKUP_HOLD").map { String(cString: $0) })
    /// The release time in nanoseconds after the Mach system was made.
    nonisolated(unsafe) static var releaseAfter: UInt64 = {
        let s = getenv("YCODE_LOOKUP_HOLD_UNTIL").flatMap { Double(String(cString: $0)) } ?? 40
        return UInt64(max(0, s) * 1_000_000_000)
    }()
    static var enabled: Bool { !names.isEmpty }

    /// Pipe routines of look-ups (`bootstrap-wire.md` §4.2): 207 and 804.
    static let lookUpIDs: Set<Int32> = [0x4000_00CF, 0x4000_0324]
    /// The pipe reply id.
    static let replyID: Int32 = 0x2000_0000

    /// Replies held so far, and look-up requests noted (statistics).
    static let heldCount = Atomic<Int>(0)
    static let notedCount = Atomic<Int>(0)

    static func parseNames(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The listed name a look-up request asks for, if any: the request is
    /// a pipe message of routine 207 or 804 whose body holds the name as a
    /// NUL-terminated string.
    static func listedName(in m: KMessage) -> String? {
        guard lookUpIDs.contains(m.id) else { return nil }
        for name in names where contains(m.inline, Array(name.utf8) + [0]) { return name }
        return nil
    }

    /// True for a pipe reply that carries no port (an `{error}` dictionary).
    static func isFailureReply(_ m: KMessage) -> Bool {
        m.id == replyID && !m.complex && contains(m.inline, Array("error".utf8) + [0])
    }

    static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return true }
            i += 1
        }
        return false
    }
}

/// One held reply.
private struct HeldReply {
    let release: UInt64
    let message: KMessage
    let port: IPCPort
    let space: MachIPC
}

/// The held replies and the host thread that delivers them.
private final class LookupHoldQueue: @unchecked Sendable {
    static let shared = LookupHoldQueue()
    private let condition = NSCondition()
    private var held: [HeldReply] = []
    private var started = false

    func add(_ r: HeldReply) {
        condition.lock()
        held.append(r)
        if !started {
            started = true
            let thread = Thread { [self] in run() }
            thread.name = "ycode-lookup-hold"
            thread.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            var due: [HeldReply] = []
            while due.isEmpty {
                let now = KernelClock.now()
                due = held.filter { $0.release <= now }
                if !due.isEmpty {
                    held.removeAll { $0.release <= now }
                    break
                }
                if let next = held.map(\.release).min() {
                    let seconds = Double(next - now) / 1_000_000_000
                    _ = condition.wait(until: Date(timeIntervalSinceNow: seconds))
                } else {
                    condition.wait()
                }
            }
            condition.unlock()
            for r in due { deliver(r) }
        }
    }

    private func deliver(_ r: HeldReply) {
        let lock = r.space.system.portLock ?? r.space.lock
        lock.withLock {
            if r.port.active {
                r.space.enqueue(r.message, on: r.port)
            } else {
                r.space.destroyMessage(r.message)
            }
        }
    }
}

extension MachIPC {
    /// `deliver`'s hook (port lock held): notes a look-up request of a listed
    /// name, and holds a failure reply to a noted request until the release
    /// time. True when the message was taken (held).
    func lookupHoldIntercept(_ m: KMessage, destination p: IPCPort) -> Bool {
        if LookupHold.listedName(in: m) != nil, let reply = m.reply.port {
            reply.lookupHoldPending = true
            LookupHold.notedCount.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        guard p.lookupHoldPending, case .sendOnce = m.destination, m.id == LookupHold.replyID else { return false }
        p.lookupHoldPending = false
        guard LookupHold.isFailureReply(m) else { return false }
        let release = system.createdAt &+ LookupHold.releaseAfter
        guard KernelClock.now() < release else { return false }
        let held = LookupHold.heldCount.wrappingAdd(1, ordering: .relaxed).newValue
        let wait = Double(release - KernelClock.now()) / 1_000_000_000
        FileHandle.standardError.write(Data("ycode-simd: look-up hold: failure reply #\(held) from pid \(pid) held for \(String(format: "%.1f", wait)) s\n".utf8))
        LookupHoldQueue.shared.add(HeldReply(release: release, message: m, port: p, space: self))
        return true
    }
}
