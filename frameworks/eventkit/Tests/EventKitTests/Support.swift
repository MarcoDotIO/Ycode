// Shared helpers. All data here is made up; no real calendars are read.

import Foundation
import Testing
@testable import EventKit

let newYork = TimeZone(identifier: "America/New_York")!
let tokyo = TimeZone(identifier: "Asia/Tokyo")!
let berlin = TimeZone(identifier: "Europe/Berlin")!

/// A store on a fresh database in its own temporary directory.
final class TestStore {
    let dir: URL
    let url: URL
    let store: EKEventStore

    init(zone: TimeZone = newYork, events: EKAuthorizationStatus = .fullAccess,
         reminders: EKAuthorizationStatus = .fullAccess) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-ek-\(UUID().uuidString)")
        url = dir.appendingPathComponent("Calendar.sqlite")
        store = EKEventStore(ycodeConfiguration: YcodeEventStoreConfiguration(
            databaseURL: url, timeZone: zone, eventAccess: events, reminderAccess: reminders))
    }

    /// Another store instance on the same database.
    func another(zone: TimeZone = newYork, events: EKAuthorizationStatus = .fullAccess,
                 reminders: EKAuthorizationStatus = .fullAccess) -> EKEventStore {
        EKEventStore(ycodeConfiguration: YcodeEventStoreConfiguration(
            databaseURL: url, timeZone: zone, eventAccess: events, reminderAccess: reminders))
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// `"2026-10-26 12:30"` (optionally with seconds) read in `zone`.
func date(_ text: String, _ zone: TimeZone = .utc) -> Date {
    let p = text.split(whereSeparator: { " -:T".contains($0) }).compactMap { Int($0) }
    return LocalDateTime(year: p[0], month: p[1], day: p[2], hour: p.count > 3 ? p[3] : 0,
                         minute: p.count > 4 ? p[4] : 0, second: p.count > 5 ? p[5] : 0).date(in: zone)
}

func ny(_ text: String) -> Date { date(text, newYork) }

/// `"MM-dd HH:mm"` style UTC rendering used to compare with golden tables.
func utcText(_ d: Date) -> String {
    let l = LocalDateTime(date: d, zone: .utc)
    return String(format: "%04d-%02d-%02d %02d:%02d", l.year, l.month, l.day, l.hour, l.minute)
}

func localText(_ d: Date, _ zone: TimeZone) -> String {
    let l = LocalDateTime(date: d, zone: zone)
    return String(format: "%04d-%02d-%02d %02d:%02d:%02d", l.year, l.month, l.day, l.hour, l.minute, l.second)
}

/// A new event in the default calendar.
func makeEvent(_ store: EKEventStore, _ title: String, start: Date, minutes: Double = 60,
               zone: TimeZone? = newYork) -> EKEvent {
    let e = EKEvent(eventStore: store)
    e.title = title
    e.startDate = start
    e.endDate = start.addingTimeInterval(minutes * 60)
    e.timeZone = zone
    e.calendar = store.defaultCalendarForNewEvents
    return e
}

/// Occurrences of the events titled `title`, sorted by start.
func occurrences(_ store: EKEventStore, _ title: String, from: Date = date("2026-01-01"),
                 to: Date = date("2029-12-31")) -> [EKEvent] {
    let p = store.predicateForEvents(withStart: from, end: to, calendars: nil)
    return store.events(matching: p).filter { $0.title == title }.sorted { $0.startDate < $1.startDate }
}

func expectCode(_ code: EKError.Code, _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try body()
        Issue.record("expected EKError code \(code.rawValue), got success", sourceLocation: sourceLocation)
    } catch let e as EKError {
        #expect(e.code == code, sourceLocation: sourceLocation)
        let ns = e as NSError
        #expect(ns.domain == "EKErrorDomain", sourceLocation: sourceLocation)
        #expect(ns.code == code.rawValue, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

private let mainKey = DispatchSpecificKey<Bool>()
private let mainKeyOnce: Void = { DispatchQueue.main.setSpecific(key: mainKey, value: true) }()

/// Counts EKEventStoreChanged notifications for one store and checks that
/// each arrives on the main queue.
final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _offMain = 0
    private var _lastInfo: [AnyHashable: Any]?
    private var token: NSObjectProtocol?

    init(_ store: EKEventStore) {
        _ = mainKeyOnce
        token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] n in
            guard let self else { return }
            self.lock.lock()
            self._count += 1
            if DispatchQueue.getSpecific(key: mainKey) != true { self._offMain += 1 }
            self._lastInfo = n.userInfo
            self.lock.unlock()
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var offMain: Int { lock.lock(); defer { lock.unlock() }; return _offMain }
    var lastInfo: [AnyHashable: Any]? { lock.lock(); defer { lock.unlock() }; return _lastInfo }

    /// Lets queued main-queue deliveries run (and, with `wait`, the
    /// cross-process poller fire).
    func settle(wait seconds: Double = 0) async {
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }
}
