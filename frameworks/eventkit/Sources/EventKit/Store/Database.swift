// Ycode's calendar database: our own SQLite schema (design.md §4), not
// Apple's. Timed values are stored as UTC instants plus a zone name; all-day
// and floating values as wall-clock text plus no zone.

import Foundation

enum FixedIDs {
    /// Birthdays source "Other" (interface.md §2.2).
    static let birthdaySource = "______NativeStorePersistentID_______"
    /// The "Reminders" list, the same on every device (reminders.md §2).
    static let remindersList = "3C8C2A71-84BF-4C87-8EFD-BB4827650D15"
    /// Source "Local" shown with reminders-only access.
    static let localReminderSource = "3B242529-8F5D-47A1-9351-444101218C30"
    /// Write-only virtual view (interface.md §2.3).
    static let virtualSource = "VIRTUAL_APP_SOURCE_UUID"
    static let virtualCalendar = "VIRTUAL_APP_CALENDAR_UUID"
}

enum Colors {
    static let defaultCalendar = YcodeRGBColor(red: 0.0, green: 0.5333, blue: 1.0)
    static let birthdays = YcodeRGBColor(red: 0.5098, green: 0.5843, blue: 0.6863)
    static let remindersList = YcodeRGBColor(red: 0.0, green: 0.4784, blue: 1.0)
    static let newEventCalendar = YcodeRGBColor(red: 0.7961, green: 0.1882, blue: 0.8784)
    static let newReminderList = YcodeRGBColor(red: 0.0, green: 0.4784, blue: 1.0)
    static let virtualCalendar = YcodeRGBColor(red: 1.0, green: 0.2196, blue: 0.2353)
}

/// A stored time: a UTC instant (timed) or a wall-clock value (floating).
struct StoredTime: Hashable {
    var utc: Double?
    var local: LocalDateTime?

    static func instant(_ d: Date) -> StoredTime { StoredTime(utc: d.timeIntervalSince1970, local: nil) }
    static func wallClock(_ l: LocalDateTime) -> StoredTime { StoredTime(utc: nil, local: l) }

    func date(readerZone: TimeZone) -> Date {
        if let u = utc { return Date(timeIntervalSince1970: u) }
        return local!.date(in: readerZone)
    }
}

struct ItemRow: Hashable {
    var id: String
    var kind: Int                    // 0 event, 1 reminder
    var calendarID: String
    var eventID: String?
    var externalID: String?
    var masterID: String?
    var title = ""
    var location: String?
    var notes: String?
    var url: String?
    var tz: String?
    var allDay = false
    var start: StoredTime?
    var end: StoredTime?
    var original: StoredTime?
    var availability = -1
    var status = 0
    var structuredLocation: LocationValue?
    var created: Double = 0
    var modified: Double = 0
    var due: String?
    var startComponents: String?
    var completed = false
    var completionDate: Double?
    var priority = 0
    var rules: [String] = []
    var exdates: [StoredTime] = []
    var alarms: [AlarmValue] = []
}

final class CalendarDatabase {
    let conn: SQLiteConnection

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        conn = try SQLiteConnection(path: path)
        try conn.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=OFF;")
        try createSchema()
    }

    private func createSchema() throws {
        try conn.exec("""
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS source(id TEXT PRIMARY KEY, title TEXT, type INTEGER, ord INTEGER);
        CREATE TABLE IF NOT EXISTS calendar(id TEXT PRIMARY KEY, source_id TEXT, title TEXT, type INTEGER,
            entity_mask INTEGER, color TEXT, allows_modifications INTEGER, immutable INTEGER, subscribed INTEGER, ord INTEGER);
        CREATE TABLE IF NOT EXISTS item(id TEXT PRIMARY KEY, kind INTEGER, calendar_id TEXT, event_id TEXT,
            external_id TEXT, master_id TEXT, title TEXT, location TEXT, notes TEXT, url TEXT, tz TEXT,
            all_day INTEGER, start_utc REAL, start_local TEXT, end_utc REAL, end_local TEXT,
            original_utc REAL, original_local TEXT, availability INTEGER, status INTEGER,
            loc_title TEXT, loc_lat REAL, loc_lon REAL, loc_radius REAL, created REAL, modified REAL,
            due TEXT, start_components TEXT, completed INTEGER, completion_date REAL, priority INTEGER);
        CREATE INDEX IF NOT EXISTS item_calendar ON item(calendar_id, kind);
        CREATE INDEX IF NOT EXISTS item_event_id ON item(event_id);
        CREATE INDEX IF NOT EXISTS item_external ON item(external_id);
        CREATE INDEX IF NOT EXISTS item_master ON item(master_id);
        CREATE TABLE IF NOT EXISTS rule(item_id TEXT, ord INTEGER, rrule TEXT);
        CREATE INDEX IF NOT EXISTS rule_item ON rule(item_id);
        CREATE TABLE IF NOT EXISTS exception_date(item_id TEXT, utc REAL, local TEXT);
        CREATE INDEX IF NOT EXISTS exdate_item ON exception_date(item_id);
        CREATE TABLE IF NOT EXISTS alarm(item_id TEXT, ord INTEGER, relative REAL, absolute REAL, proximity INTEGER,
            loc_title TEXT, loc_lat REAL, loc_lon REAL, loc_radius REAL);
        CREATE INDEX IF NOT EXISTS alarm_item ON alarm(item_id);
        CREATE TABLE IF NOT EXISTS journal(seq INTEGER PRIMARY KEY AUTOINCREMENT, writer TEXT, at REAL,
            entity_mask INTEGER, object_ids TEXT);
        COMMIT;
        """)
        if meta("unique_id") == nil { try seedFreshDevice() }
    }

    /// The fresh-device state (simulator-baseline.md §2): sources Default and
    /// Other, calendars Calendar and Birthdays, the list Reminders.
    private func seedFreshDevice() throws {
        try conn.exec("BEGIN IMMEDIATE")
        do {
            if meta("unique_id") == nil {
                let defaultSource = UUID().uuidString
                let calendarID = UUID().uuidString
                try conn.run("INSERT INTO source VALUES(?,?,?,?)", [.text(defaultSource), .text("Default"), .int(0), .int(0)])
                try conn.run("INSERT INTO source VALUES(?,?,?,?)", [.text(FixedIDs.birthdaySource), .text("Other"), .int(5), .int(1)])
                try upsertCalendar(CalendarRow(id: calendarID, sourceID: defaultSource, title: "Calendar", type: 0,
                                               entityMask: 1, color: Colors.defaultCalendar, allowsModifications: true,
                                               immutable: false, subscribed: false), order: 0)
                try upsertCalendar(CalendarRow(id: UUID().uuidString, sourceID: FixedIDs.birthdaySource, title: "Birthdays",
                                               type: 4, entityMask: 1, color: Colors.birthdays, allowsModifications: false,
                                               immutable: true, subscribed: false), order: 1)
                try upsertCalendar(CalendarRow(id: FixedIDs.remindersList, sourceID: defaultSource, title: "Reminders", type: 0,
                                               entityMask: 2, color: Colors.remindersList, allowsModifications: true,
                                               immutable: false, subscribed: false), order: 2)
                try setMeta("default_event_calendar", calendarID)
                try setMeta("default_reminder_list", FixedIDs.remindersList)
                try setMeta("schema", "1")
                try setMeta("unique_id", UUID().uuidString)
            }
            try conn.exec("COMMIT")
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Meta

    func meta(_ key: String) -> String? {
        (try? conn.run("SELECT value FROM meta WHERE key=?", [.text(key)]))?.first?.first?.text
    }

    func setMeta(_ key: String, _ value: String) throws {
        try conn.run("INSERT OR REPLACE INTO meta VALUES(?,?)", [.text(key), .text(value)])
    }

    // MARK: Sources and calendars

    func sources() -> [SourceRow] {
        let rows = (try? conn.run("SELECT id, title, type FROM source ORDER BY ord, title")) ?? []
        return rows.map { SourceRow(id: $0[0].text ?? "", title: $0[1].text ?? "", type: $0[2].int ?? 0) }
    }

    func calendars() -> [CalendarRow] {
        let rows = (try? conn.run("""
            SELECT id, source_id, title, type, entity_mask, color, allows_modifications, immutable, subscribed
            FROM calendar ORDER BY ord, title
            """)) ?? []
        return rows.map(calendarRow)
    }

    func calendar(_ id: String) -> CalendarRow? {
        let rows = (try? conn.run("""
            SELECT id, source_id, title, type, entity_mask, color, allows_modifications, immutable, subscribed
            FROM calendar WHERE id=?
            """, [.text(id)])) ?? []
        return rows.first.map(calendarRow)
    }

    private func calendarRow(_ r: [SQLValue]) -> CalendarRow {
        CalendarRow(id: r[0].text ?? "", sourceID: r[1].text, title: r[2].text ?? "", type: r[3].int ?? 0,
                    entityMask: UInt(r[4].int ?? 1), color: r[5].text.flatMap(YcodeRGBColor.init(text:)),
                    allowsModifications: r[6].bool, immutable: r[7].bool, subscribed: r[8].bool)
    }

    func upsertCalendar(_ c: CalendarRow, order: Int? = nil) throws {
        let nextOrd = try conn.run("SELECT COALESCE(MAX(ord),0)+1 FROM calendar").first?.first?.int ?? 0
        let ord = order ?? nextOrd
        let existingOrd = try conn.run("SELECT ord FROM calendar WHERE id=?", [.text(c.id)]).first?.first?.int
        try conn.run("INSERT OR REPLACE INTO calendar VALUES(?,?,?,?,?,?,?,?,?,?)", [
            .text(c.id), c.sourceID.sql, .text(c.title), .int(Int64(c.type)), .int(Int64(c.entityMask)),
            c.color.map { .text($0.text) } ?? .null, .int(c.allowsModifications ? 1 : 0),
            .int(c.immutable ? 1 : 0), .int(c.subscribed ? 1 : 0), .int(Int64(existingOrd ?? ord)),
        ])
    }

    /// Deletes a calendar and its items; returns the removed item identifiers.
    func deleteCalendar(_ id: String) throws -> [String] {
        let ids = try conn.run("SELECT id FROM item WHERE calendar_id=?", [.text(id)]).compactMap { $0.first?.text }
        for i in ids { try deleteItemRow(i) }
        try conn.run("DELETE FROM calendar WHERE id=?", [.text(id)])
        return ids
    }

    // MARK: Items

    private static let itemColumns = """
        id, kind, calendar_id, event_id, external_id, master_id, title, location, notes, url, tz, all_day,
        start_utc, start_local, end_utc, end_local, original_utc, original_local, availability, status,
        loc_title, loc_lat, loc_lon, loc_radius, created, modified, due, start_components, completed,
        completion_date, priority
        """

    func item(_ id: String) -> ItemRow? {
        items(where: "id=?", [.text(id)]).first
    }

    func items(where clause: String, _ args: [SQLValue]) -> [ItemRow] {
        let rows = (try? conn.run("SELECT \(CalendarDatabase.itemColumns) FROM item WHERE \(clause)", args)) ?? []
        return rows.map(loadItem)
    }

    private func loadItem(_ r: [SQLValue]) -> ItemRow {
        func time(_ u: SQLValue, _ l: SQLValue) -> StoredTime? {
            if let x = u.double { return StoredTime(utc: x, local: nil) }
            if let t = l.text, let ldt = LocalDateTime(text: t) { return .wallClock(ldt) }
            return nil
        }
        var row = ItemRow(id: r[0].text ?? "", kind: r[1].int ?? 0, calendarID: r[2].text ?? "")
        row.eventID = r[3].text
        row.externalID = r[4].text
        row.masterID = r[5].text
        row.title = r[6].text ?? ""
        row.location = r[7].text
        row.notes = r[8].text
        row.url = r[9].text
        row.tz = r[10].text
        row.allDay = r[11].bool
        row.start = time(r[12], r[13])
        row.end = time(r[14], r[15])
        row.original = time(r[16], r[17])
        row.availability = r[18].int ?? -1
        row.status = r[19].int ?? 0
        if r[20] != .null || r[21] != .null {
            row.structuredLocation = LocationValue(title: r[20].text, latitude: r[21].double, longitude: r[22].double,
                                                   radius: r[23].double ?? 0)
        }
        row.created = r[24].double ?? 0
        row.modified = r[25].double ?? 0
        row.due = r[26].text
        row.startComponents = r[27].text
        row.completed = r[28].bool
        row.completionDate = r[29].double
        row.priority = r[30].int ?? 0
        let id = SQLValue.text(row.id)
        row.rules = ((try? conn.run("SELECT rrule FROM rule WHERE item_id=? ORDER BY ord", [id])) ?? []).compactMap { $0[0].text }
        row.exdates = ((try? conn.run("SELECT utc, local FROM exception_date WHERE item_id=?", [id])) ?? []).compactMap {
            time($0[0], $0[1])
        }
        row.alarms = ((try? conn.run("""
            SELECT relative, absolute, proximity, loc_title, loc_lat, loc_lon, loc_radius FROM alarm WHERE item_id=? ORDER BY ord
            """, [id])) ?? []).map { a in
            var loc: LocationValue?
            if a[3] != .null || a[4] != .null {
                loc = LocationValue(title: a[3].text, latitude: a[4].double, longitude: a[5].double, radius: a[6].double ?? 0)
            }
            return AlarmValue(relativeOffset: a[0].double ?? 0, absoluteDate: a[1].double.map { Date(timeIntervalSince1970: $0) },
                              location: loc, proximity: a[2].int ?? 0)
        }
        return row
    }

    func upsertItem(_ row: ItemRow) throws {
        func utc(_ t: StoredTime?) -> SQLValue { t?.utc.sql ?? .null }
        func local(_ t: StoredTime?) -> SQLValue { t?.local.map { .text($0.description) } ?? .null }
        let loc = row.structuredLocation
        try conn.run("INSERT OR REPLACE INTO item(\(CalendarDatabase.itemColumns)) VALUES(\(Array(repeating: "?", count: 31).joined(separator: ",")))", [
            .text(row.id), .int(Int64(row.kind)), .text(row.calendarID), row.eventID.sql, row.externalID.sql,
            row.masterID.sql, .text(row.title), row.location.sql, row.notes.sql, row.url.sql, row.tz.sql,
            .int(row.allDay ? 1 : 0), utc(row.start), local(row.start), utc(row.end), local(row.end),
            utc(row.original), local(row.original), .int(Int64(row.availability)), .int(Int64(row.status)),
            loc?.title.sql ?? .null, loc?.latitude.sql ?? .null, loc?.longitude.sql ?? .null,
            loc.map { .double($0.radius) } ?? .null, .double(row.created), .double(row.modified),
            row.due.sql, row.startComponents.sql, .int(row.completed ? 1 : 0), row.completionDate.sql,
            .int(Int64(row.priority)),
        ])
        let id = SQLValue.text(row.id)
        try conn.run("DELETE FROM rule WHERE item_id=?", [id])
        for (i, r) in row.rules.enumerated() {
            try conn.run("INSERT INTO rule VALUES(?,?,?)", [id, .int(Int64(i)), .text(r)])
        }
        try conn.run("DELETE FROM exception_date WHERE item_id=?", [id])
        for x in row.exdates {
            try conn.run("INSERT INTO exception_date VALUES(?,?,?)", [id, utc(x), local(x)])
        }
        try conn.run("DELETE FROM alarm WHERE item_id=?", [id])
        for (i, a) in row.alarms.enumerated() {
            try conn.run("INSERT INTO alarm VALUES(?,?,?,?,?,?,?,?,?)", [
                id, .int(Int64(i)), .double(a.relativeOffset), a.absoluteDate.map { .double($0.timeIntervalSince1970) } ?? .null,
                .int(Int64(a.proximity)), a.location?.title.sql ?? .null, a.location?.latitude.sql ?? .null,
                a.location?.longitude.sql ?? .null, a.location.map { .double($0.radius) } ?? .null,
            ])
        }
    }

    /// Deletes an item, its children rows and its detached occurrences.
    func deleteItemRow(_ id: String) throws {
        let detached = try conn.run("SELECT id FROM item WHERE master_id=?", [.text(id)]).compactMap { $0.first?.text }
        for d in detached { try deleteItemRow(d) }
        for t in ["rule", "exception_date", "alarm"] {
            try conn.run("DELETE FROM \(t) WHERE item_id=?", [.text(id)])
        }
        try conn.run("DELETE FROM item WHERE id=?", [.text(id)])
    }

    // MARK: Change journal

    func appendJournal(writer: String, mask: UInt, objectIDs: [String]) throws -> Int64 {
        try conn.run("INSERT INTO journal(writer, at, entity_mask, object_ids) VALUES(?,?,?,?)", [
            .text(writer), .double(Date().timeIntervalSince1970), .int(Int64(mask)),
            .text(objectIDs.joined(separator: ",")),
        ])
        let seq = conn.lastInsertRowID
        try conn.run("DELETE FROM journal WHERE seq < ?", [.int(seq - 1000)])
        return seq
    }

    func maxJournalSeq() -> Int64 {
        Int64((try? conn.run("SELECT COALESCE(MAX(seq),0) FROM journal"))?.first?.first?.int ?? 0)
    }
}

// MARK: - Date components text

/// `key=value;…` text of the date components a reminder stores.
enum ComponentsText {
    static func encode(_ c: DateComponents?) -> String? {
        guard let c else { return nil }
        var parts: [String] = []
        if let v = c.year { parts.append("y=\(v)") }
        if let v = c.month { parts.append("mo=\(v)") }
        if let v = c.day { parts.append("d=\(v)") }
        if let v = c.hour { parts.append("h=\(v)") }
        if let v = c.minute { parts.append("mi=\(v)") }
        if let v = c.second { parts.append("s=\(v)") }
        if let z = c.timeZone { parts.append("tz=\(z.identifier)") }
        return parts.joined(separator: ";")
    }

    static func decode(_ text: String?) -> DateComponents? {
        guard let text else { return nil }
        var c = DateComponents()
        c.calendar = gregorian()
        for p in text.split(separator: ";") {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "y": c.year = Int(kv[1])
            case "mo": c.month = Int(kv[1])
            case "d": c.day = Int(kv[1])
            case "h": c.hour = Int(kv[1])
            case "mi": c.minute = Int(kv[1])
            case "s": c.second = Int(kv[1])
            case "tz": c.timeZone = TimeZone(identifier: kv[1])
            default: break
            }
        }
        return c
    }

    static func gregorian() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .utc
        return cal
    }
}
