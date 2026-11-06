import Foundation
import Synchronization

/// Diagnostics (`YCODE_DEBUG_FULL_QUEUES=1`, `boot-profile.md` §12): the
/// first send that blocks on each full port queue prints the receiving
/// process, the port's `qlimit`, its queued messages and the sender; at the
/// home screen (`summary`) the blocked sends per receiving process. Called
/// with the port lock held, before the sender waits.
public enum FullQueueReport {
    static let enabled = getenv("YCODE_DEBUG_FULL_QUEUES").map { String(cString: $0) == "1" } ?? false
    /// Ports already reported (by serial), and blocked sends by receiver.
    static let state = Mutex<(seen: Set<UInt64>, blocked: [String: Int])>((seen: [], blocked: [:]))

    static func blocked(_ p: IPCPort, sender: MachIPC, id: Int32) {
        let receiver = MachTrafficStats.name(p.receiver)
        let first = state.withLock { s -> Bool in
            s.blocked[receiver, default: 0] += 1
            return s.seen.insert(p.serial).inserted
        }
        guard first else { return }
        FileHandle.standardError.write(Data(("ycode-full-queue: \(MachTrafficStats.name(sender)) blocks sending id "
            + "\(String(format: "0x%x", id)) to \(receiver): qlimit \(p.qlimit), queued \(p.messages.count), "
            + "occupied \(p.occupiedSlots)\n").utf8))
    }

    /// One line: blocked sends by receiving process, most first (nil when off).
    public static var summary: String? {
        guard enabled else { return nil }
        let top = state.withLock { $0.blocked }.sorted { $0.value > $1.value }.prefix(12)
        return "blocked sends by receiver: " + top.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}
