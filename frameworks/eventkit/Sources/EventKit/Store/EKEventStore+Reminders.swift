// Reminders: save rules, asynchronous fetch with cancel, the three
// predicates, recurring completion (reminders.md).

import Foundation

extension EKEventStore {
    // MARK: Predicates

    public func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate {
        EKReminderPredicate(kind: .all, calendarIDs: calendars?.map(\.calendarIdentifier))
    }

    public func predicateForIncompleteReminders(withDueDateStarting startDate: Date?, ending endDate: Date?,
                                                calendars: [EKCalendar]?) -> NSPredicate {
        EKReminderPredicate(kind: .incomplete(start: startDate, end: endDate), calendarIDs: calendars?.map(\.calendarIdentifier))
    }

    public func predicateForCompletedReminders(withCompletionDateStarting startDate: Date?, ending endDate: Date?,
                                               calendars: [EKCalendar]?) -> NSPredicate {
        EKReminderPredicate(kind: .completed(start: startDate, end: endDate), calendarIDs: calendars?.map(\.calendarIdentifier))
    }

    // MARK: Fetch

    /// Starts an asynchronous fetch; the completion runs on a private queue
    /// with an array (empty without access). Returns an identifier for
    /// `cancelFetchRequest(_:)`; a cancelled fetch never completes.
    @discardableResult
    public func fetchReminders(matching predicate: NSPredicate,
                               completion: @escaping ([EKReminder]?) -> Void) -> Any {
        let request = EKReminderFetchRequest()
        nonisolated(unsafe) let predicate = predicate
        searchQueue.async { [self] in
            if request.isCancelled { return }
            let result = reminders(matching: predicate)
            if request.isCancelled { return }
            completion(result)
        }
        return request
    }

    public func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder]? {
        await withCheckedContinuation { (c: CheckedContinuation<[EKReminder]?, Never>) in
            fetchReminders(matching: predicate) { c.resume(returning: $0) }
        }
    }

    public func cancelFetchRequest(_ fetchIdentifier: Any) {
        (fetchIdentifier as? EKReminderFetchRequest)?.cancel()
    }

    /// The instant of a reminder's due date. A date-only due date is read as
    /// midnight UTC (reminders.md §4, inference flagged as C-REM-Q1).
    func dueInstant(_ c: DateComponents, reminderZone: TimeZone?) -> Date? {
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        if c.hour == nil {
            return LocalDateTime(year: y, month: m, day: d).date(in: .utc)
        }
        let zone = c.timeZone ?? reminderZone ?? readerZone
        return LocalDateTime(year: y, month: m, day: d, hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
            .date(in: zone)
    }

    func reminders(matching predicate: NSPredicate) -> [EKReminder] {
        lock.lock(); defer { lock.unlock() }
        guard let p = predicate as? EKReminderPredicate, remindersFull, let db else { return [] }
        let ids = p.calendarIDs ?? calendars(for: .reminder).map(\.calendarIdentifier)
        if ids.isEmpty { return [] }
        let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let all = db.items(where: "kind=1 AND calendar_id IN (\(ph))", ids.map { .text($0) }).map(makeReminder)
        return all.filter { r in
            switch p.kind {
            case .all:
                return true
            case .incomplete(let s, let e):
                if r.reminder.completed { return false }
                if s == nil && e == nil { return true }
                guard let due = r.reminder.due, let at = dueInstant(due, reminderZone: r.common.timeZone) else { return false }
                return (s.map { at >= $0 } ?? true) && (e.map { at < $0 } ?? true)
            case .completed(let s, let e):
                if !r.reminder.completed { return false }
                if s == nil && e == nil { return true }
                guard let at = r.reminder.completionDate else { return false }
                return (s.map { at >= $0 } ?? true) && (e.map { at < $0 } ?? true)
            }
        }
    }

    func makeReminder(_ row: ItemRow) -> EKReminder {
        let r = EKReminder(store: self)
        fillCommon(r, row)
        r.reminder = ReminderFields(start: ComponentsText.decode(row.startComponents), due: ComponentsText.decode(row.due),
                                    completed: row.completed,
                                    completionDate: row.completionDate.map { Date(timeIntervalSince1970: $0) },
                                    priority: row.priority)
        r.saved = r.snapshot()
        return r
    }

    // MARK: Save and remove

    public func save(_ reminder: EKReminder, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard reminder.store === self else { throw EKError(.objectBelongsToDifferentStore) }
        guard remindersFull, let db else { throw EKError(.noCalendar) }
        guard let cal = reminder.calendarObject, let calRow = db.calendar(cal.calendarIdentifier) else {
            throw EKError(.noCalendar)
        }
        guard calRow.entityMask & EKEntityMask.reminder.rawValue != 0 else { throw EKError(.calendarDoesNotAllowReminders) }
        guard calRow.allowsModifications else { throw EKError(.calendarReadOnly) }
        guard (0...9).contains(reminder.reminder.priority) else { throw EKError(.priorityIsInvalid) }
        if !reminder.ruleObjects.isEmpty && reminder.reminder.due == nil {
            throw EKError(.recurringReminderRequiresDueDate)
        }

        var fields = reminder.reminder
        var tz = reminder.common.timeZone ?? fields.due?.timeZone
        fields.due = normalized(fields.due)
        if fields.start == nil, let due = fields.due {
            // The start defaults to the due components, with zero time fields
            // added for a date-only due date (reminders.md §3).
            var s = due
            if s.hour == nil { s.hour = 0; s.minute = 0; s.second = 0 }
            fields.start = s
        } else {
            fields.start = normalized(fields.start)
        }
        if fields.due == nil && fields.start == nil { tz = reminder.common.timeZone }
        var rules = reminder.ruleObjects.map(\.spec)

        // Completing a recurring reminder (reminders.md §5): a completed copy
        // without rules records this occurrence; the reminder moves on.
        var completedCopy: ItemRow?
        if fields.completed, !rules.isEmpty, let due = fields.due,
           let next = nextOccurrence(due: due, rules: rules, zone: tz) {
            var copy = row(for: reminder, fields: fields, tz: tz, rules: [], id: UUID().uuidString)
            copy.externalID = copy.id
            copy.created = Date().timeIntervalSince1970
            completedCopy = copy
            let delta = next.naiveSeconds - local(due).naiveSeconds
            fields.due = moved(due, by: delta)
            fields.start = fields.start.map { moved($0, by: delta) }
            fields.completed = false
            fields.completionDate = nil
            rules = rules.map { r in
                var r = r
                if let c = r.count { r.count = max(c - 1, 1) }
                return r
            }
        }

        let existing = reminder.persisted ? db.item(reminder.itemID) : nil
        var row = row(for: reminder, fields: fields, tz: tz, rules: rules, id: reminder.itemID)
        row.externalID = reminder.itemID
        row.created = existing?.created ?? Date().timeIntervalSince1970
        let finalRow = row, copy = completedCopy
        try write(mask: EKEntityMask.reminder.rawValue, commit: commit) {
            try db.upsertItem(finalRow)
            if let copy { try db.upsertItem(copy) }
            return [finalRow.id] + (copy.map { [$0.id] } ?? [])
        }
        reminder.reminder = fields
        reminder.common.timeZone = tz
        reminder.ruleObjects = rules.map { EKRecurrenceRule(spec: $0) }
        reminder.externalID = finalRow.externalID
        reminder.created = Date(timeIntervalSince1970: finalRow.created)
        reminder.modified = Date(timeIntervalSince1970: finalRow.modified)
        reminder.generation = generation
        reminder.markSaved()
    }

    public func remove(_ reminder: EKReminder, commit: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard reminder.store === self else { throw EKError(.objectBelongsToDifferentStore) }
        guard remindersFull, let db else { throw EKError(.noCalendar) }
        guard reminder.persisted, db.item(reminder.itemID) != nil else { return } // removed already: success
        try write(mask: EKEntityMask.reminder.rawValue, commit: commit) {
            try db.deleteItemRow(reminder.itemID)
            return [reminder.itemID]
        }
    }

    // MARK: Helpers

    private func row(for r: EKReminder, fields: ReminderFields, tz: TimeZone?, rules: [RuleSpec], id: String) -> ItemRow {
        var row = ItemRow(id: id, kind: 1, calendarID: r.calendarObject!.calendarIdentifier)
        row.title = r.common.title
        row.location = r.common.location
        row.notes = r.common.notes
        row.url = r.common.url?.absoluteString
        row.tz = tz?.identifier
        row.due = ComponentsText.encode(fields.due)
        row.startComponents = ComponentsText.encode(fields.start)
        row.completed = fields.completed
        row.completionDate = fields.completionDate?.timeIntervalSince1970
        row.priority = fields.priority
        row.rules = rules.map(RRuleText.format)
        row.alarms = r.alarmObjects.map(\.value).sorted(by: AlarmValue.readBackOrder)
        row.modified = Date().timeIntervalSince1970
        return row
    }

    /// Components as stored: the Gregorian calendar added.
    private func normalized(_ c: DateComponents?) -> DateComponents? {
        guard let c else { return nil }
        return ComponentsText.decode(ComponentsText.encode(c))
    }

    private func local(_ c: DateComponents) -> LocalDateTime {
        LocalDateTime(year: c.year ?? 1, month: c.month ?? 1, day: c.day ?? 1,
                      hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    private func moved(_ c: DateComponents, by delta: Int64) -> DateComponents {
        let l = local(c).addingSeconds(delta)
        var out = c
        out.year = l.year; out.month = l.month; out.day = l.day
        if c.hour != nil { out.hour = l.hour }
        if c.minute != nil { out.minute = l.minute }
        if c.second != nil { out.second = l.second }
        return out
    }

    private func nextOccurrence(due: DateComponents, rules: [RuleSpec], zone: TimeZone?) -> LocalDateTime? {
        let start = local(due)
        let z = due.timeZone ?? zone ?? readerZone
        let occ = Expander.expand(rules, start: start, zone: z, through: start.addingDays(366 * 10))
        return occ.first { $0 > start }
    }
}
