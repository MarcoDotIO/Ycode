// Change notifications (interface.md §5): one EKEventStoreChangedNotification
// per committed change, posted on the main queue to every store instance on
// the same database, whether the commit came from this process or another.
//
// In-process commits are fanned out directly. Commits by other processes are
// found through the change journal: a poller per database reads the newest
// journal sequence and posts one notification per foreign commit.

import Foundation

final class ChangeHub: @unchecked Sendable {
    static let shared = ChangeHub()
    /// Identifies this process's journal rows.
    static let processToken = UUID().uuidString
    static let pollInterval: DispatchTimeInterval = .milliseconds(200)

    private final class WeakStore {
        weak var store: EKEventStore?
        init(_ s: EKEventStore) { store = s }
    }

    private final class Entry {
        var stores: [WeakStore] = []
        var lastSeq: Int64 = 0
        var timer: DispatchSourceTimer?
        var reader: SQLiteConnection?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let pollQueue = DispatchQueue(label: "org.ycode.eventkit.change-poll")

    func register(_ store: EKEventStore, path: String, currentSeq: Int64) {
        lock.lock(); defer { lock.unlock() }
        let e = entries[path] ?? Entry()
        if entries[path] == nil {
            e.lastSeq = currentSeq
            entries[path] = e
        }
        e.stores.removeAll { $0.store == nil }
        e.stores.append(WeakStore(store))
        if e.timer == nil { startPolling(path, e) }
    }

    func unregister(path: String) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path] else { return }
        e.stores.removeAll { $0.store == nil }
    }

    /// A commit by a store of this process.
    func didCommit(path: String, seq: Int64, userInfo: [String: Any]) {
        lock.lock()
        // The poller skips this process's journal rows by writer token, so
        // lastSeq is left to it (a foreign commit with a lower sequence must
        // still be seen).
        let e = entries[path]
        let targets = e?.stores.compactMap(\.store) ?? []
        lock.unlock()
        post(to: targets, userInfo: userInfo)
    }

    private func post(to stores: [EKEventStore], userInfo: [String: Any]) {
        let boxes = stores.map(WeakStore.init)
        nonisolated(unsafe) let info = userInfo
        DispatchQueue.main.async {
            for b in boxes {
                guard let s = b.store else { continue }
                NotificationCenter.default.post(name: .EKEventStoreChanged, object: s, userInfo: info)
            }
        }
    }

    // MARK: Cross-process polling

    private func startPolling(_ path: String, _ e: Entry) {
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + ChangeHub.pollInterval, repeating: ChangeHub.pollInterval)
        t.setEventHandler { [weak self] in self?.poll(path) }
        e.timer = t
        t.resume()
    }

    private func poll(_ path: String) {
        lock.lock()
        guard let e = entries[path] else { lock.unlock(); return }
        e.stores.removeAll { $0.store == nil }
        if e.stores.isEmpty {
            e.timer?.cancel()
            e.timer = nil
            e.reader = nil
            entries[path] = nil
            lock.unlock()
            return
        }
        if e.reader == nil { e.reader = try? SQLiteConnection(path: path, readOnly: true) }
        let reader = e.reader
        let since = e.lastSeq
        lock.unlock()

        guard let reader,
              let rows = try? reader.run("SELECT seq, writer, entity_mask, object_ids FROM journal WHERE seq > ? ORDER BY seq",
                                         [.int(since)]), !rows.isEmpty else { return }
        lock.lock()
        var foreign: [[String: Any]] = []
        for r in rows {
            let seq = Int64(r[0].int ?? 0)
            guard seq > e.lastSeq else { continue }
            e.lastSeq = seq
            if r[1].text != ChangeHub.processToken {
                let mask = UInt(r[2].int ?? 0)
                let ids = (r[3].text ?? "").split(separator: ",").map(String.init)
                foreign.append(ChangeHub.userInfo(mask: mask, ids: ids))
            }
        }
        let targets = e.stores.compactMap(\.store)
        lock.unlock()
        for info in foreign { post(to: targets, userInfo: info) }
    }

    static func userInfo(mask: UInt, ids: [String]) -> [String: Any] {
        [
            ChangeKeys.changeType: 1,
            ChangeKeys.calendarDataChanged: mask & EKEntityMask.event.rawValue != 0,
            ChangeKeys.remindersDataChanged: mask & EKEntityMask.reminder.rawValue != 0,
            ChangeKeys.changedObjectIDs: ids,
        ]
    }
}
