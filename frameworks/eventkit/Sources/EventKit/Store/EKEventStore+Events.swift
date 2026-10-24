// Events: validation, all-day and floating storage, rule normalization,
// occurrence expansion, detached occurrences, splits and future deletes
// (interface.md §3, recurrence.md §4–§6).

import Foundation

extension EKEventStore {
    // MARK: Public API

    public func save(_ event: EKEvent, span: EKSpan) throws {
        try save(event, span: span, commit: true)
    }

    public func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try saveEvent(event, span: span, commit: commit)
    }

    public func remove(_ event: EKEvent, span: EKSpan) throws {
        try remove(event, span: span, commit: true)
    }

    public func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try removeEvent(event, span: span, commit: commit)
    }

    public func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        EKEventPredicate(start: startDate, end: endDate, calendarIDs: calendars?.map(\.calendarIdentifier), zone: readerZone)
    }

    /// Occurrences overlapping the predicate's window (unordered).
    public func events(matching predicate: NSPredicate) -> [EKEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let p = predicate as? EKEventPredicate else { return [] }
        return fetchEvents(p)
    }

    public func enumerateEvents(matching predicate: NSPredicate, using block: EKEventSearchCallback) {
        let all = events(matching: predicate)
        var stop: ObjCBool = false
        for e in all {
            block(e, &stop)
            if stop.boolValue { break }
        }
    }

    // MARK: Helpers

    var zoneOfRow: (ItemRow) -> TimeZone {
        { [readerZone] row in row.tz.flatMap { TimeZone(identifier: $0) } ?? readerZone }
    }

    func stored(_ date: Date, floating: Bool) -> StoredTime {
        floating ? .wallClock(LocalDateTime(date: date, zone: readerZone)) : .instant(date)
    }

    /// The window end after the four-year cap (interface.md §3.6).
    func cappedEnd(_ p: EKEventPredicate) -> Date {
        let zone = readerZone
        var l = LocalDateTime(date: p.start, zone: zone)
        l.year += 4
        if l.month == 2 && l.day == 29 && !Civil.isLeap(l.year) { l.day = 28 }
        return min(p.end, l.date(in: zone))
    }

    /// EventKit's normalizations on save (recurrence.md §4 items 1–2).
    static func normalize(_ r: RuleSpec, start: LocalDateTime) -> RuleSpec {
        var r = r
        guard !r.hasByParts else { return r }
        if r.frequency == .monthly && start.day >= 29 {
            r.byMonthDay = Array(28...start.day)
            r.bySetPos = [-1]
        } else if r.frequency == .yearly && start.month == 2 && start.day == 29 {
            r.byMonthDay = [28, 29]
            r.bySetPos = [-1]
        }
        return r
    }

    private func sourceID(ofCalendar id: String) -> String? { db?.calendar(id)?.sourceID }

    // MARK: Save

    private struct PreparedEvent {
        var calendarID: String
        var fields: EventFields
        var tz: TimeZone?
        var rules: [RuleSpec]
    }

    private func prepare(_ e: EKEvent) throws -> PreparedEvent {
        guard e.store === self else { throw EKError(.objectBelongsToDifferentStore) }
        guard eventsFull || eventsWriteOnly else { throw EKError(.noCalendar) }
        guard let cal = e.calendarObject else { throw EKError(.noCalendar) }
        var calID = cal.calendarIdentifier
        if calID == FixedIDs.virtualCalendar {
            guard let real = db?.meta("default_event_calendar") else { throw EKError(.noCalendar) }
            calID = real
        }
        guard let calRow = db?.calendar(calID) else { throw EKError(.noCalendar) }
        guard calRow.entityMask & EKEntityMask.event.rawValue != 0 else { throw EKError(.calendarDoesNotAllowEvents) }
        guard calRow.allowsModifications else { throw EKError(.calendarReadOnly) }
        guard let start = e.event.start else { throw EKError(.noStartDate) }
        guard let end = e.event.end else { throw EKError(.noEndDate) }
        guard end >= start else { throw EKError(.datesInverted) }
        var fields = e.event
        var tz = e.common.timeZone
        if fields.allDay {
            // interface.md §3.3: 00:00:00 of the start day to 23:59:59 of the
            // day of (end − 1 s), not earlier than the start day; floating.
            let zone = readerZone
            let first = LocalDateTime(date: start, zone: zone).startOfDay
            var last = LocalDateTime(date: end.addingTimeInterval(-1), zone: zone).startOfDay
            if last < first { last = first }
            last.hour = 23; last.minute = 59; last.second = 59
            fields.start = first.date(in: zone)
            fields.end = last.date(in: zone)
            tz = nil
        }
        let localStart = LocalDateTime(date: fields.start!, zone: tz ?? readerZone)
        let rules = e.ruleObjects.map { EKEventStore.normalize($0.spec, start: localStart) }
        return PreparedEvent(calendarID: calID, fields: fields, tz: tz, rules: rules)
    }

    private func makeRow(_ e: EKEvent, _ p: PreparedEvent, id: String) -> ItemRow {
        var row = ItemRow(id: id, kind: 0, calendarID: p.calendarID)
        let floating = p.tz == nil
        row.title = e.common.title
        row.location = e.common.location
        row.notes = e.common.notes
        row.url = e.common.url?.absoluteString
        row.tz = p.tz?.identifier
        row.allDay = p.fields.allDay
        row.start = stored(p.fields.start!, floating: floating)
        row.end = stored(p.fields.end!, floating: floating)
        row.availability = p.fields.availability
        row.status = e.eventStatus.rawValue
        row.structuredLocation = p.fields.structuredLocation
        row.rules = p.rules.map(RRuleText.format)
        row.alarms = e.alarmObjects.map(\.value).sorted(by: AlarmValue.readBackOrder)
        let now = Date().timeIntervalSince1970
        row.created = e.created?.timeIntervalSince1970 ?? now
        row.modified = now
        return row
    }

    /// Applies the stored result to the object the app holds.
    private func adopt(_ e: EKEvent, row: ItemRow) {
        e.itemID = row.id
        e.externalID = row.externalID
        e.storedEventID = row.eventID
        e.common.timeZone = row.tz.flatMap { TimeZone(identifier: $0) }
        e.common.calendarID = e.calendarObject?.calendarIdentifier
        let zone = readerZone
        e.event.start = row.start?.date(readerZone: zone)
        e.event.end = row.end?.date(readerZone: zone)
        e.ruleObjects = row.rules.compactMap(RRuleText.parse).map { EKRecurrenceRule(spec: $0) }
        e.masterID = row.masterID
        e.detached = row.masterID != nil
        e.originalStart = row.original?.date(readerZone: zone)
        e.isOccurrence = false
        e.created = Date(timeIntervalSince1970: row.created)
        e.modified = Date(timeIntervalSince1970: row.modified)
        e.generation = generation
        e.markSaved()
    }

    private func saveEvent(_ e: EKEvent, span: EKSpan, commit: Bool) throws {
        let p = try prepare(e)
        guard let db else { throw EKError(.internalFailure) }

        if e.isOccurrence || (e.detached && span == .futureEvents) {
            guard let masterID = e.isOccurrence ? e.itemID : e.masterID, let master = db.item(masterID),
                  let original = e.originalStart else { throw EKError(.internalFailure) }
            let masterStart = master.start!.date(readerZone: zoneOfRow(master))
            if span == .futureEvents {
                if original == masterStart {
                    var row = makeRow(e, p, id: master.id)
                    try updateSeries(master: master, with: &row, commit: commit)
                    adopt(e, row: row)
                } else {
                    let row = try split(master: master, at: original, with: e, p, commit: commit)
                    adopt(e, row: row)
                }
            } else {
                if !e.hasChanges { return }
                let row = try detach(master: master, at: original, with: e, p, commit: commit)
                adopt(e, row: row)
            }
            return
        }

        if let existing = db.item(e.itemID), e.persisted {
            var row = makeRow(e, p, id: existing.id)
            row.eventID = existing.eventID
            row.externalID = existing.externalID
            row.created = existing.created
            row.masterID = existing.masterID
            row.original = existing.original
            if existing.masterID != nil {
                row.rules = []
                try write(mask: EKEntityMask.event.rawValue, commit: commit) {
                    try db.upsertItem(row)
                    return [row.id]
                }
            } else {
                try updateSeries(master: existing, with: &row, commit: commit)
            }
            adopt(e, row: row)
        } else {
            // A new event (or one whose row is gone): a new master row.
            var row = makeRow(e, p, id: e.itemID)
            let ext = UUID().uuidString
            row.externalID = ext
            row.eventID = "\(sourceID(ofCalendar: p.calendarID) ?? "local"):\(ext)"
            row.created = Date().timeIntervalSince1970
            try write(mask: EKEntityMask.event.rawValue, commit: commit) {
                try db.upsertItem(row)
                return [row.id]
            }
            adopt(e, row: row)
        }
    }

    /// Writes a master's new values, keeping its exceptions (shifted when the
    /// start moved) or dropping them when it no longer recurs.
    private func updateSeries(master: ItemRow, with row: inout ItemRow, commit: Bool) throws {
        guard let db else { throw EKError(.internalFailure) }
        row.eventID = master.eventID
        row.externalID = master.externalID
        row.created = master.created
        let zone = zoneOfRow(master)
        let oldStart = master.start!.date(readerZone: zone)
        let newStart = row.start!.date(readerZone: zoneOfRow(row))
        let delta = newStart.timeIntervalSince(oldStart)
        let detached = db.items(where: "master_id=?", [.text(master.id)])
        if row.rules.isEmpty {
            row.exdates = []
        } else {
            row.exdates = master.exdates.map { shift($0, by: delta, zone: zone) }
        }
        let finalRow = row
        try write(mask: EKEntityMask.event.rawValue, commit: commit) {
            try db.upsertItem(finalRow)
            for var d in detached {
                if finalRow.rules.isEmpty {
                    try db.deleteItemRow(d.id)
                } else if delta != 0, let o = d.original {
                    d.original = shift(o, by: delta, zone: zone)
                    try db.upsertItem(d)
                }
            }
            return [finalRow.id]
        }
    }

    private func shift(_ t: StoredTime, by delta: TimeInterval, zone: TimeZone) -> StoredTime {
        if delta == 0 { return t }
        if let u = t.utc { return StoredTime(utc: u + delta, local: nil) }
        return .wallClock(t.local!.addingSeconds(Int64(delta)))
    }

    /// recurrence.md §6: a changed occurrence saved for this event only.
    private func detach(master: ItemRow, at original: Date, with e: EKEvent, _ p: PreparedEvent, commit: Bool) throws -> ItemRow {
        guard let db else { throw EKError(.internalFailure) }
        let rid = Int(original.timeIntervalSinceReferenceDate.rounded(.down))
        var row = makeRow(e, p, id: UUID().uuidString)
        row.rules = []
        row.masterID = master.id
        row.original = stored(original, floating: master.tz == nil)
        row.eventID = (master.eventID ?? master.id) + "/RID=\(rid)"
        row.externalID = (master.externalID ?? master.id) + "/RID=\(rid)"
        row.created = Date().timeIntervalSince1970
        let finalRow = row
        try write(mask: EKEntityMask.event.rawValue, commit: commit) {
            try db.upsertItem(finalRow)
            return [finalRow.id, master.id]
        }
        return row
    }

    /// The occurrence starts of a stored master (wall-clock, in its zone).
    private func occurrences(of master: ItemRow, through limit: LocalDateTime) -> [LocalDateTime] {
        let zone = zoneOfRow(master)
        let start = LocalDateTime(date: master.start!.date(readerZone: zone), zone: zone)
        let rules = master.rules.compactMap(RRuleText.parse)
        return Expander.expand(rules, start: start, zone: zone, through: limit)
    }

    private func endOfDay(_ l: LocalDateTime, zone: TimeZone) -> Date {
        LocalDateTime(year: l.year, month: l.month, day: l.day, hour: 23, minute: 59, second: 59).date(in: zone)
    }

    /// recurrence.md §6: "this and future" changes split the series at
    /// `original`: the master keeps the earlier occurrences, a new master
    /// starts with the changed occurrence.
    private func split(master: ItemRow, at original: Date, with e: EKEvent, _ p: PreparedEvent, commit: Bool) throws -> ItemRow {
        guard let db else { throw EKError(.internalFailure) }
        let zone = zoneOfRow(master)
        let masterStart = LocalDateTime(date: master.start!.date(readerZone: zone), zone: zone)
        let cut = LocalDateTime(date: original, zone: zone).addingSeconds(-1)
        let before = occurrences(of: master, through: cut)
        let untilDate = endOfDay(before.last ?? masterStart, zone: zone)
        var keep: [RuleSpec] = []
        var carry: [RuleSpec] = []
        for r in master.rules.compactMap(RRuleText.parse) {
            var a = r, b = r
            if let c = r.count {
                let n = Expander.expand(r, start: masterStart, zone: zone, through: cut).count
                a.count = n
                b.count = max(c - n, 1)
            } else {
                a.until = untilDate
            }
            keep.append(a)
            carry.append(b)
        }
        // The new series: the occurrence's values; its rules continue the
        // remaining count unless the app changed them.
        let masterRules = master.rules.compactMap(RRuleText.parse)
        let objectRules = e.ruleObjects.map(\.spec)
        let newStartLocal = LocalDateTime(date: p.fields.start!, zone: p.tz ?? readerZone)
        let newRules = (objectRules == masterRules ? carry : objectRules).map {
            EKEventStore.normalize($0, start: newStartLocal)
        }
        var newRow = makeRow(e, PreparedEvent(calendarID: p.calendarID, fields: p.fields, tz: p.tz, rules: newRules),
                             id: UUID().uuidString)
        let ext = UUID().uuidString
        newRow.externalID = ext
        newRow.eventID = "\(sourceID(ofCalendar: p.calendarID) ?? "local"):\(ext)"
        newRow.created = Date().timeIntervalSince1970
        let delta = p.fields.start!.timeIntervalSince(original)
        var oldRow = master
        oldRow.rules = keep.map(RRuleText.format)
        oldRow.modified = Date().timeIntervalSince1970
        oldRow.exdates = master.exdates.filter { $0.date(readerZone: zone) < original }
        newRow.exdates = master.exdates.filter { $0.date(readerZone: zone) >= original }.map { shift($0, by: delta, zone: zone) }
        let detached = db.items(where: "master_id=?", [.text(master.id)])
        let finalOld = oldRow, finalNew = newRow
        try write(mask: EKEntityMask.event.rawValue, commit: commit) {
            try db.upsertItem(finalOld)
            try db.upsertItem(finalNew)
            for var d in detached {
                guard let o = d.original, o.date(readerZone: zone) >= original else { continue }
                let moved = shift(o, by: delta, zone: zone)
                let rid = Int(moved.date(readerZone: zone).timeIntervalSinceReferenceDate.rounded(.down))
                d.masterID = finalNew.id
                d.original = moved
                d.eventID = (finalNew.eventID ?? finalNew.id) + "/RID=\(rid)"
                d.externalID = ext + "/RID=\(rid)"
                try db.upsertItem(d)
            }
            return [finalOld.id, finalNew.id]
        }
        return newRow
    }

    // MARK: Remove

    private func removeEvent(_ e: EKEvent, span: EKSpan, commit: Bool) throws {
        guard e.store === self else { throw EKError(.objectBelongsToDifferentStore) }
        guard eventsFull || eventsWriteOnly else { throw EKError(.noCalendar) }
        guard e.persisted, let db else { return }
        if e.isOccurrence || e.detached {
            guard let masterID = e.isOccurrence ? e.itemID : e.masterID, let master = db.item(masterID),
                  let original = e.originalStart else {
                // The master is gone; remove a lone detached row if any.
                if e.detached, db.item(e.itemID) != nil {
                    try write(mask: EKEntityMask.event.rawValue, commit: commit) {
                        try db.deleteItemRow(e.itemID)
                        return [e.itemID]
                    }
                }
                return
            }
            if span == .futureEvents {
                try removeFuture(master: master, from: original, commit: commit)
            } else {
                try removeOne(master: master, at: original, detachedID: e.detached ? e.itemID : nil, commit: commit)
            }
            return
        }
        guard let row = db.item(e.itemID) else { return } // already removed: success
        if !row.rules.isEmpty && span != .futureEvents {
            // The master object stands for the first occurrence.
            try removeOne(master: row, at: row.start!.date(readerZone: zoneOfRow(row)), detachedID: nil, commit: commit)
            return
        }
        try write(mask: EKEntityMask.event.rawValue, commit: commit) {
            try db.deleteItemRow(row.id)
            return [row.id]
        }
    }

    /// recurrence.md §6: removing one occurrence adds an exception date.
    private func removeOne(master: ItemRow, at original: Date, detachedID: String?, commit: Bool) throws {
        guard let db else { throw EKError(.internalFailure) }
        var m = master
        m.exdates.append(stored(original, floating: master.tz == nil))
        m.modified = Date().timeIntervalSince1970
        let finalRow = m
        try write(mask: EKEntityMask.event.rawValue, commit: commit) {
            if let d = detachedID { try db.deleteItemRow(d) }
            try db.upsertItem(finalRow)
            return [finalRow.id] + (detachedID.map { [$0] } ?? [])
        }
    }

    /// recurrence.md §4 item 5: "this and future" removal ends the rules with
    /// UNTIL = the last second (in the event's zone) of the day of the last
    /// remaining occurrence, written in UTC.
    private func removeFuture(master: ItemRow, from original: Date, commit: Bool) throws {
        guard let db else { throw EKError(.internalFailure) }
        let zone = zoneOfRow(master)
        let masterStart = master.start!.date(readerZone: zone)
        if original <= masterStart {
            try write(mask: EKEntityMask.event.rawValue, commit: commit) {
                try db.deleteItemRow(master.id)
                return [master.id]
            }
            return
        }
        let cut = LocalDateTime(date: original, zone: zone).addingSeconds(-1)
        let before = occurrences(of: master, through: cut)
        let until = endOfDay(before.last ?? LocalDateTime(date: masterStart, zone: zone), zone: zone)
        var m = master
        m.rules = master.rules.compactMap(RRuleText.parse).map { r -> RuleSpec in
            var r = r
            r.count = nil
            r.until = until
            return r
        }.map(RRuleText.format)
        m.exdates = master.exdates.filter { $0.date(readerZone: zone) < original }
        m.modified = Date().timeIntervalSince1970
        let detached = db.items(where: "master_id=?", [.text(master.id)])
        let finalRow = m
        try write(mask: EKEntityMask.event.rawValue, commit: commit) {
            try db.upsertItem(finalRow)
            var ids = [finalRow.id]
            for d in detached where (d.original?.date(readerZone: zone) ?? .distantPast) >= original {
                try db.deleteItemRow(d.id)
                ids.append(d.id)
            }
            return ids
        }
    }

    // MARK: Fetch

    private func fetchEvents(_ p: EKEventPredicate) -> [EKEvent] {
        guard eventsFull, let db else { return [] }
        let winStart = p.start
        let winEnd = cappedEnd(p)
        if winEnd < winStart { return [] }
        let calIDs = p.calendarIDs ?? calendars(for: .event).map(\.calendarIdentifier)
        if calIDs.isEmpty { return [] }
        let placeholders = Array(repeating: "?", count: calIDs.count).joined(separator: ",")
        let rows = db.items(where: "kind=0 AND calendar_id IN (\(placeholders))", calIDs.map { .text($0) })
        // Window rule: overlaps [start, end), inclusive at the window start.
        func overlaps(_ s: Date, _ e: Date) -> Bool { e >= winStart && s < winEnd }

        var detachedOriginals: [String: Set<Double>] = [:]
        for r in rows where r.masterID != nil {
            if let o = r.original, let m = r.masterID {
                let zone = r.tz.flatMap { TimeZone(identifier: $0) } ?? readerZone
                detachedOriginals[m, default: []].insert(o.date(readerZone: zone).timeIntervalSince1970.rounded())
            }
        }
        // Detached occurrences of masters in other calendars still hide their
        // original slot.
        let masterIDs = rows.filter { $0.masterID == nil && !$0.rules.isEmpty }.map(\.id)
        if !masterIDs.isEmpty {
            let ph = Array(repeating: "?", count: masterIDs.count).joined(separator: ",")
            for r in db.items(where: "master_id IN (\(ph))", masterIDs.map { .text($0) }) {
                if let o = r.original, let m = r.masterID {
                    detachedOriginals[m, default: []].insert(o.date(readerZone: zoneOfRow(r)).timeIntervalSince1970.rounded())
                }
            }
        }

        var out: [EKEvent] = []
        for row in rows {
            guard let s0 = row.start, let e0 = row.end else { continue }
            let zone = zoneOfRow(row)
            let start = s0.date(readerZone: zone)
            let end = e0.date(readerZone: zone)
            if row.masterID != nil || row.rules.isEmpty {
                if overlaps(start, end) { out.append(makeEvent(row)) }
                continue
            }
            let floating = row.tz == nil
            let startLocal = LocalDateTime(date: start, zone: zone)
            let durationLocal = LocalDateTime(date: end, zone: zone).naiveSeconds - startLocal.naiveSeconds
            let duration = end.timeIntervalSince(start)
            let limit = LocalDateTime(date: winEnd, zone: zone).addingDays(2)
            let excluded = Set(row.exdates.map { $0.date(readerZone: zone).timeIntervalSince1970.rounded() })
                .union(detachedOriginals[row.id] ?? [])
            var template: EKEvent?
            for occ in Expander.expand(row.rules.compactMap(RRuleText.parse), start: startLocal, zone: zone, through: limit) {
                let os = occ.date(in: zone)
                if excluded.contains(os.timeIntervalSince1970.rounded()) { continue }
                let oe = floating ? occ.addingSeconds(durationLocal).date(in: zone) : os.addingTimeInterval(duration)
                guard overlaps(os, oe) else { continue }
                let base = template ?? makeEvent(row)
                template = base
                let o = EKEvent(store: self)
                o.itemID = base.itemID
                o.externalID = base.externalID
                o.storedEventID = base.storedEventID
                o.persisted = true
                o.generation = generation
                o.apply(base.snapshot())
                o.calendarObject = base.calendarObject
                o.created = base.created
                o.modified = base.modified
                o.event.start = os
                o.event.end = oe
                o.originalStart = os
                o.isOccurrence = true
                o.saved = o.snapshot()
                out.append(o)
            }
        }
        return out
    }
}
