// EKEventStore: sources, calendars, identifiers, save/commit/reset and change
// notifications (interface.md §2, §5, §6; design.md §3–§4).

import Foundation

/// Ycode-specific store settings. `EKEventStore()` uses
/// `EKEventStore.ycodeDefaultConfiguration`; tests and tools create stores
/// with their own configuration through `init(ycodeConfiguration:)`.
public struct YcodeEventStoreConfiguration: Sendable {
    /// The calendar database file (created with the fresh-device content on
    /// first use).
    public var databaseURL: URL
    /// The zone in which floating and all-day values are read; nil means the
    /// process's default time zone at the time of use.
    public var timeZone: TimeZone?
    /// Access level for events and reminders (the authorization broker of
    /// round R5 is not implemented yet; these are the recorded answers).
    public var eventAccess: EKAuthorizationStatus
    public var reminderAccess: EKAuthorizationStatus

    public init(databaseURL: URL = YcodeEventStoreConfiguration.standardDatabaseURL, timeZone: TimeZone? = nil,
                eventAccess: EKAuthorizationStatus = .fullAccess, reminderAccess: EKAuthorizationStatus = .fullAccess) {
        self.databaseURL = databaseURL
        self.timeZone = timeZone
        self.eventAccess = eventAccess
        self.reminderAccess = reminderAccess
    }

    /// `$YCODE_EVENTKIT_DATABASE`, else `<data home>/ycode-eventkit/Calendar.sqlite`
    /// (`$XDG_DATA_HOME` or `~/.local/share` on Linux, Application Support on macOS).
    public static var standardDatabaseURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["YCODE_EVENTKIT_DATABASE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        #if canImport(Darwin)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        #else
        let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        #endif
        return base.appendingPathComponent("ycode-eventkit/Calendar.sqlite")
    }
}

public class EKEventStore: NSObject {
    private static let defaultsLock = NSLock()
    nonisolated(unsafe) private static var _default = YcodeEventStoreConfiguration()

    /// The configuration used by `EKEventStore()` and by
    /// `authorizationStatus(for:)`.
    public static var ycodeDefaultConfiguration: YcodeEventStoreConfiguration {
        get { defaultsLock.lock(); defer { defaultsLock.unlock() }; return _default }
        set { defaultsLock.lock(); _default = newValue; defaultsLock.unlock() }
    }

    let configuration: YcodeEventStoreConfiguration
    let db: CalendarDatabase?
    let path: String
    let lock = NSRecursiveLock()
    private(set) var generation = 0
    private var stagedMask: UInt = 0
    private var stagedIDs: [String] = []
    let delegateSourceIDs: Set<String>?
    /// Reminder searches run here (reminders.md §4).
    let searchQueue = DispatchQueue(label: "org.ycode.eventkit.reminders.search")
    let accessQueue = DispatchQueue(label: "org.ycode.eventkit.access")

    public init(ycodeConfiguration: YcodeEventStoreConfiguration) {
        configuration = ycodeConfiguration
        path = ycodeConfiguration.databaseURL.path
        db = try? CalendarDatabase(path: path)
        delegateSourceIDs = nil
        super.init()
        ChangeHub.shared.register(self, path: path, currentSeq: db?.maxJournalSeq() ?? 0)
    }

    public override convenience init() {
        self.init(ycodeConfiguration: EKEventStore.ycodeDefaultConfiguration)
    }

    /// A store limited to the given sources.
    public init(sources: [EKSource]) {
        let base = sources.first?.store.configuration ?? EKEventStore.ycodeDefaultConfiguration
        configuration = base
        path = base.databaseURL.path
        db = try? CalendarDatabase(path: path)
        delegateSourceIDs = Set(sources.map(\.sourceIdentifier))
        super.init()
        ChangeHub.shared.register(self, path: path, currentSeq: db?.maxJournalSeq() ?? 0)
    }

    deinit { ChangeHub.shared.unregister(path: path) }

    var readerZone: TimeZone { configuration.timeZone ?? NSTimeZone.default }
    var eventsFull: Bool { configuration.eventAccess == .fullAccess }
    var eventsWriteOnly: Bool { configuration.eventAccess == .writeOnly }
    var remindersFull: Bool { configuration.reminderAccess == .fullAccess }

    // MARK: Authorization (recorded answers; the R5 broker is deferred)

    public class func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus {
        let c = ycodeDefaultConfiguration
        return entityType == .event ? c.eventAccess : c.reminderAccess
    }

    private func answer(_ granted: Bool, _ completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        accessQueue.async { completion(granted, nil) }
    }

    public func requestFullAccessToEvents(completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        answer(eventsFull, completion)
    }

    public func requestWriteOnlyAccessToEvents(completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        answer(eventsFull || eventsWriteOnly, completion)
    }

    public func requestFullAccessToReminders(completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        answer(remindersFull, completion)
    }

    @available(*, deprecated, message: "Use requestFullAccessToEvents or requestFullAccessToReminders")
    public func requestAccess(to entityType: EKEntityType, completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        answer(entityType == .event ? eventsFull : remindersFull, completion)
    }

    public func requestFullAccessToEvents() async throws -> Bool { eventsFull }
    public func requestWriteOnlyAccessToEvents() async throws -> Bool { eventsFull || eventsWriteOnly }
    public func requestFullAccessToReminders() async throws -> Bool { remindersFull }

    // MARK: Identity

    /// The database's unique identifier; nil without full event access.
    public var eventStoreIdentifier: String! {
        guard eventsFull else { return nil }
        return db?.meta("unique_id")
    }

    // MARK: Sources

    private var virtualSource: EKSource {
        EKSource(store: self, row: SourceRow(id: FixedIDs.virtualSource, title: "Account", type: EKSourceType.calDAV.rawValue))
    }

    private var localReminderSource: EKSource {
        EKSource(store: self, row: SourceRow(id: FixedIDs.localReminderSource, title: "Local", type: EKSourceType.local.rawValue))
    }

    public var sources: [EKSource] {
        lock.lock(); defer { lock.unlock() }
        var out: [EKSource] = []
        if eventsFull {
            out = (db?.sources() ?? []).map { EKSource(store: self, row: $0) }
        } else if eventsWriteOnly {
            out = [virtualSource]
        }
        if !eventsFull && remindersFull { out.append(localReminderSource) }
        if let only = delegateSourceIDs { out = out.filter { only.contains($0.sourceIdentifier) } }
        return out
    }

    public var delegateSources: [EKSource] { [] }

    public func source(withIdentifier identifier: String) -> EKSource? {
        sources.first { $0.sourceIdentifier == identifier }
    }

    public func refreshSourcesIfNecessary() {}

    // MARK: Calendars

    /// The default reminder list's real source (where "Local" lists live).
    private var reminderHomeSourceID: String? {
        db?.calendar(db?.meta("default_reminder_list") ?? FixedIDs.remindersList)?.sourceID
    }

    /// The row as the current access level presents it.
    private func presented(_ row: CalendarRow) -> CalendarRow {
        var r = row
        if r.entityMask & EKEntityMask.reminder.rawValue != 0 && !eventsFull { r.sourceID = FixedIDs.localReminderSource }
        return r
    }

    private var virtualCalendarRow: CalendarRow {
        CalendarRow(id: FixedIDs.virtualCalendar, sourceID: FixedIDs.virtualSource, title: "Calendar",
                    type: EKCalendarType.calDAV.rawValue, entityMask: EKEntityMask.event.rawValue,
                    color: Colors.virtualCalendar, allowsModifications: true, immutable: true, subscribed: false)
    }

    func calendarRow(_ id: String) -> CalendarRow? {
        lock.lock(); defer { lock.unlock() }
        if id == FixedIDs.virtualCalendar { return eventsWriteOnly ? virtualCalendarRow : nil }
        return db?.calendar(id).map(presented)
    }

    func calendarObject(_ id: String) -> EKCalendar? {
        calendarRow(id).map { EKCalendar(store: self, row: $0, saved: true) }
    }

    public func calendars(for entityType: EKEntityType) -> [EKCalendar] {
        lock.lock(); defer { lock.unlock() }
        var rows: [CalendarRow] = []
        switch entityType {
        case .event:
            if eventsFull {
                rows = (db?.calendars() ?? []).filter { $0.entityMask & EKEntityMask.event.rawValue != 0 }
            } else if eventsWriteOnly {
                rows = [virtualCalendarRow]
            }
        case .reminder:
            if remindersFull {
                rows = (db?.calendars() ?? []).filter { $0.entityMask & EKEntityMask.reminder.rawValue != 0 }.map(presented)
            }
        }
        if let only = delegateSourceIDs { rows = rows.filter { only.contains($0.sourceID ?? "") } }
        return rows.map { EKCalendar(store: self, row: $0, saved: true) }
    }

    @available(*, deprecated, message: "Use calendars(for:)")
    public var calendars: [EKCalendar] { calendars(for: .event) }

    public var defaultCalendarForNewEvents: EKCalendar? {
        lock.lock(); defer { lock.unlock() }
        if eventsWriteOnly { return EKCalendar(store: self, row: virtualCalendarRow, saved: true) }
        guard eventsFull, let id = db?.meta("default_event_calendar") else { return nil }
        return calendarObject(id)
    }

    public func defaultCalendarForNewReminders() -> EKCalendar? {
        lock.lock(); defer { lock.unlock() }
        guard remindersFull, let id = db?.meta("default_reminder_list") else { return nil }
        return calendarObject(id)
    }

    public func calendar(withIdentifier identifier: String) -> EKCalendar? {
        lock.lock(); defer { lock.unlock() }
        guard let row = calendarRow(identifier) else { return nil }
        let isReminder = row.entityMask & EKEntityMask.reminder.rawValue != 0
        if isReminder ? !remindersFull : !(eventsFull || (eventsWriteOnly && identifier == FixedIDs.virtualCalendar)) {
            return nil
        }
        return EKCalendar(store: self, row: row, saved: true)
    }

    public func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard calendar.store === self else { throw EKError(.objectBelongsToDifferentStore) }
        let isReminderList = calendar.fields.entityMask & EKEntityMask.reminder.rawValue != 0
        if !isReminderList && eventsWriteOnly { throw EKError(.sourceDoesNotAllowCalendarAddDelete) }
        guard isReminderList ? remindersFull : eventsFull else { throw EKError(.calendarHasNoSource) }
        guard var sourceID = calendar.fields.sourceID else { throw EKError(.calendarHasNoSource) }
        if sourceID == FixedIDs.localReminderSource, let home = reminderHomeSourceID { sourceID = home }
        if sourceID == FixedIDs.virtualSource { throw EKError(.sourceDoesNotAllowCalendarAddDelete) }
        guard let db, let source = db.sources().first(where: { $0.id == sourceID }) else {
            throw EKError(.calendarHasNoSource)
        }
        let existing = db.calendar(calendar.fields.id)
        if existing == nil && (source.type == EKSourceType.birthdays.rawValue || source.type == EKSourceType.subscribed.rawValue) {
            throw EKError(.sourceDoesNotAllowCalendarAddDelete)
        }
        if let e = existing, e.immutable { throw EKError(.calendarIsImmutable) }
        var row = calendar.fields
        row.sourceID = sourceID
        if row.color == nil { row.color = isReminderList ? Colors.newReminderList : Colors.newEventCalendar }
        if existing == nil { row.type = EKCalendarType.local.rawValue }
        try write(mask: isReminderList ? EKEntityMask.reminder.rawValue : EKEntityMask.event.rawValue, commit: commit) {
            try db.upsertCalendar(row)
            return [row.id]
        }
        calendar.fields = presented(row)
        calendar.saved = calendar.fields
    }

    public func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard calendar.store === self else { throw EKError(.objectBelongsToDifferentStore) }
        if calendar.fields.id == FixedIDs.virtualCalendar { throw EKError(.sourceDoesNotAllowCalendarAddDelete) }
        let isReminderList = calendar.fields.entityMask & EKEntityMask.reminder.rawValue != 0
        guard isReminderList ? remindersFull : eventsFull else { throw EKError(.calendarHasNoSource) }
        guard let db, let row = db.calendar(calendar.fields.id) else { return }
        let sourceType = db.sources().first { $0.id == row.sourceID }?.type
        if row.type == EKCalendarType.birthday.rawValue || sourceType == EKSourceType.birthdays.rawValue
            || row.subscribed {
            throw EKError(.sourceDoesNotAllowCalendarAddDelete)
        }
        try write(mask: row.entityMask, commit: commit) {
            let ids = try db.deleteCalendar(row.id)
            return [row.id] + ids
        }
    }

    // MARK: Item lookups

    public func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
        lock.lock(); defer { lock.unlock() }
        guard let row = db?.item(identifier) else { return nil }
        return makeItem(row)
    }

    public func calendarItems(withExternalIdentifier externalIdentifier: String) -> [EKCalendarItem] {
        lock.lock(); defer { lock.unlock() }
        return (db?.items(where: "external_id=?", [.text(externalIdentifier)]) ?? []).compactMap(makeItem)
    }

    public func event(withIdentifier identifier: String) -> EKEvent? {
        lock.lock(); defer { lock.unlock() }
        guard eventsFull, let row = db?.items(where: "event_id=? AND kind=0", [.text(identifier)]).first else { return nil }
        return makeEvent(row)
    }

    func makeItem(_ row: ItemRow) -> EKCalendarItem? {
        if row.kind == 0 { return eventsFull ? makeEvent(row) : nil }
        return remindersFull ? makeReminder(row) : nil
    }

    func fillCommon(_ item: EKCalendarItem, _ row: ItemRow) {
        item.itemID = row.id
        item.externalID = row.externalID
        item.persisted = true
        item.generation = generation
        item.common = CommonFields(title: row.title, location: row.location, notes: row.notes,
                                   url: row.url.flatMap { URL(string: $0) },
                                   timeZone: row.tz.flatMap { TimeZone(identifier: $0) }, calendarID: row.calendarID)
        item.calendarObject = calendarObject(row.calendarID)
        item.alarmObjects = row.alarms.map { EKAlarm(value: $0) }
        item.ruleObjects = row.rules.compactMap { RRuleText.parse($0) }.map { EKRecurrenceRule(spec: $0) }
        item.created = Date(timeIntervalSince1970: row.created)
        item.modified = Date(timeIntervalSince1970: row.modified)
    }

    func makeEvent(_ row: ItemRow) -> EKEvent {
        let e = EKEvent(store: self)
        fillCommon(e, row)
        e.storedEventID = row.eventID
        let zone = readerZone
        e.event = EventFields(start: row.start?.date(readerZone: zone), end: row.end?.date(readerZone: zone),
                              allDay: row.allDay, availability: row.availability,
                              structuredLocation: row.structuredLocation)
        e.eventStatus = EKEventStatus(rawValue: row.status) ?? .none
        e.masterID = row.masterID
        e.detached = row.masterID != nil
        e.originalStart = row.original?.date(readerZone: zone)
        e.saved = e.snapshot()
        return e
    }

    func refreshItem(_ item: EKCalendarItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let row = db?.item(item.itemID) else { return false }
        if item.hasChanges { return true }
        if let e = item as? EKEvent, e.isOccurrence { return true }
        guard let fresh = makeItem(row) else { return false }
        item.apply(fresh.snapshot())
        item.saved = item.snapshot()
        return true
    }

    // MARK: Commit, reset

    /// Runs a write inside the store's transaction (opened on first use and
    /// kept open while changes are staged with commit NO).
    func write(mask: UInt, commit: Bool, _ body: () throws -> [String]) throws {
        guard let db else { throw EKError(.internalFailure) }
        let conn = db.conn
        let opened = !conn.inTransaction
        do {
            if opened { try conn.exec("BEGIN IMMEDIATE") }
            try conn.exec("SAVEPOINT ek_op")
        } catch {
            throw EKError(.internalFailure)
        }
        do {
            let ids = try body()
            try conn.exec("RELEASE ek_op")
            stagedMask |= mask
            stagedIDs += ids
        } catch {
            try? conn.exec("ROLLBACK TO ek_op")
            try? conn.exec("RELEASE ek_op")
            if opened { try? conn.exec("ROLLBACK") }
            throw (error as? EKError) ?? EKError(.internalFailure)
        }
        if commit { try commitLocked() }
    }

    private func commitLocked() throws {
        guard let db, db.conn.inTransaction else { return }
        let mask = stagedMask, ids = stagedIDs
        do {
            let seq = try db.appendJournal(writer: ChangeHub.processToken, mask: mask, objectIDs: ids)
            try db.conn.exec("COMMIT")
            stagedMask = 0
            stagedIDs = []
            ChangeHub.shared.didCommit(path: path, seq: seq, userInfo: ChangeHub.userInfo(mask: mask, ids: ids))
        } catch {
            throw EKError(.internalFailure)
        }
    }

    /// Writes every change staged with commit NO; one notification.
    public func commit() throws {
        lock.lock(); defer { lock.unlock() }
        try commitLocked()
    }

    /// Discards staged changes; objects obtained before become invalid
    /// (their `eventIdentifier` reads nil).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        if let db, db.conn.inTransaction { try? db.conn.exec("ROLLBACK") }
        stagedMask = 0
        stagedIDs = []
        generation += 1
    }
}
