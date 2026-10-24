// C-EK-REM (plan.md §3.3; reminders.md §1–§6, recurrence.md §7).

import Foundation
import Testing
@testable import EventKit
#if canImport(CoreLocation)
import CoreLocation
#endif

@Suite("reminders.md: reminders")
struct ReminderTests {
    func components(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = nil, _ mi: Int? = nil, zone: TimeZone? = nil) -> DateComponents {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.hour = h; c.minute = mi
        c.timeZone = zone
        return c
    }

    func daily(count: Int) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: count))
    }

    func fetch(_ s: EKEventStore, _ p: NSPredicate) async -> [EKReminder] {
        await s.fetchReminders(matching: p) ?? []
    }

    @Test("§1 defaults and completion coupling")
    func defaults() {
        let t = TestStore()
        let r = EKReminder(eventStore: t.store)
        #expect(r.title == "" && r.startDateComponents == nil && r.dueDateComponents == nil)
        #expect(!r.isCompleted && r.completionDate == nil && r.priority == 0)
        #expect(r.timeZone == nil && r.calendar == nil)
        r.isCompleted = true
        #expect(r.completionDate != nil)
        #expect(abs(r.completionDate!.timeIntervalSinceNow) < 5)
        r.completionDate = nil
        #expect(!r.isCompleted)
        r.priority = 10 // accepted by the setter
        #expect(r.priority == 10)
        #expect(EKReminderPriority.high.rawValue == 1 && EKReminderPriority.medium.rawValue == 5
                && EKReminderPriority.low.rawValue == 9)
    }

    /// The probe's list of §3: seven successful saves, the failures of the
    /// table, one notification per commit (list creation + 7 saves = 8).
    @Test("§3 save table, §4 fetch results (7 / 1 / 6 / 1 / 1), §5 recurring completion, §6 notifications")
    func probeList() async throws {
        let t = TestStore()
        let s = t.store
        let counter = NotificationCounter(s)
        let list = EKCalendar(for: .reminder, eventStore: s)
        list.title = "Probe list"
        list.source = s.defaultCalendarForNewReminders()!.source
        try s.saveCalendar(list, commit: true)

        func new(_ title: String) -> EKReminder {
            let r = EKReminder(eventStore: s)
            r.title = title
            r.calendar = list
            return r
        }

        // 1. due date only.
        let dateOnly = new("due date only")
        dateOnly.dueDateComponents = components(2026, 10, 20)
        try s.save(dateOnly, commit: true)
        #expect(dateOnly.dueDateComponents?.calendar?.identifier == .gregorian)
        #expect(dateOnly.dueDateComponents?.hour == nil)
        let start1 = try #require(dateOnly.startDateComponents)
        #expect([start1.year, start1.month, start1.day, start1.hour, start1.minute, start1.second] == [2026, 10, 20, 0, 0, 0])

        // 2. due 10-21 09:30 and start 08:00 New York, one −600 s alarm.
        let timed = new("due 10-21 09:30")
        timed.dueDateComponents = components(2026, 10, 21, 9, 30, zone: newYork)
        timed.startDateComponents = components(2026, 10, 21, 8, 0, zone: newYork)
        timed.addAlarm(EKAlarm(relativeOffset: -600))
        try s.save(timed, commit: true)
        #expect(timed.timeZone == newYork)
        #expect(timed.alarms?.count == 1)
        #expect(timed.startDateComponents?.hour == 8)

        // 3. floating due 10-02 12:00, completed 10-03 12:00Z.
        let done = new("completed")
        done.dueDateComponents = components(2026, 10, 2, 12, 0)
        done.completionDate = date("2026-10-03 12:00")
        try s.save(done, commit: true)
        #expect(done.isCompleted)
        #expect(done.startDateComponents?.day == 2 && done.startDateComponents?.hour == 12)

        // 4. no dates, priority high.
        let high = new("priority high")
        high.priority = Int(EKReminderPriority.high.rawValue)
        try s.save(high, commit: true)
        #expect(high.priority == 1)

        // 5. due 10-22 07:00 New York, daily count 3.
        let recurring = new("daily")
        recurring.dueDateComponents = components(2026, 10, 22, 7, 0, zone: newYork)
        recurring.addRecurrenceRule(daily(count: 3))
        try s.save(recurring, commit: true)
        #expect(recurring.startDateComponents?.day == 22 && recurring.startDateComponents?.hour == 7)

        // Failures post no notification.
        let noDue = new("recurring without due")
        noDue.addRecurrenceRule(daily(count: 2))
        expectCode(.recurringReminderRequiresDueDate) { try s.save(noDue, commit: true) }
        let p12 = new("priority 12")
        p12.priority = 12
        expectCode(.priorityIsInvalid) { try s.save(p12, commit: true) }
        let noList = new("no list")
        noList.calendar = nil
        expectCode(.noCalendar) { try s.save(noList, commit: true) }
        let wrongCal = new("event calendar")
        wrongCal.calendar = s.defaultCalendarForNewEvents
        expectCode(.calendarDoesNotAllowReminders) { try s.save(wrongCal, commit: true) }

        // 6. location alarm (leave, radius 100 m) without dates.
        let geo = new("location alarm")
        let alarm = EKAlarm()
        let place = EKStructuredLocation(title: "Home")
        place.geoLocation = CLLocation(latitude: 41.08, longitude: -81.51)
        place.radius = 100
        alarm.structuredLocation = place
        alarm.proximity = .leave
        geo.addAlarm(alarm)
        try s.save(geo, commit: true)
        #expect(geo.alarms?.count == 1)

        // 7. the priority-12 reminder corrected (our reconstruction of the
        // probe's seventh successful save).
        p12.priority = 9
        try s.save(p12, commit: true)

        await counter.settle()
        #expect(counter.count == 8)
        #expect(counter.offMain == 0)

        // §4 fetch results.
        #expect(await fetch(s, s.predicateForReminders(in: [list])).count == 7)
        let window = await fetch(s, s.predicateForIncompleteReminders(withDueDateStarting: ny("2026-10-20 00:00"),
                                                                        ending: ny("2026-10-22 00:00"), calendars: [list]))
        #expect(window.map(\.title) == ["due 10-21 09:30"])
        #expect(await fetch(s, s.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])).count == 6)
        #expect(await fetch(s, s.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil,
                                                                calendars: [list])).map(\.title) == ["completed"])
        #expect(await fetch(s, s.predicateForCompletedReminders(withCompletionDateStarting: date("2026-10-03 00:00"),
                                                                ending: date("2026-10-04 00:00"), calendars: [list])).count == 1)

        // §5 completing the recurring reminder.
        let itemID = recurring.calendarItemIdentifier
        recurring.isCompleted = true
        try s.save(recurring, commit: true)
        #expect(recurring.calendarItemIdentifier == itemID)
        #expect(!recurring.isCompleted)
        #expect(recurring.dueDateComponents?.day == 23 && recurring.dueDateComponents?.hour == 7)
        #expect(recurring.recurrenceRules?.first?.rruleText == "FREQ=DAILY;INTERVAL=1;COUNT=2")
        let all = await fetch(t.another(), t.another().predicateForReminders(in: [list]))
        #expect(all.count == 8)
        let copy = try #require(all.first { $0.title == "daily" && $0.isCompleted })
        #expect(copy.dueDateComponents?.day == 22 && copy.dueDateComponents?.hour == 7)
        #expect(copy.recurrenceRules == nil)
        #expect(copy.calendarItemIdentifier != itemID)
        let moved = try #require(all.first { $0.calendarItemIdentifier == itemID })
        #expect(moved.dueDateComponents?.day == 23 && !moved.isCompleted)
    }

    @Test("§3 removing a reminder twice succeeds both times")
    func removeTwice() throws {
        let t = TestStore()
        let r = EKReminder(eventStore: t.store)
        r.title = "gone"
        r.calendar = t.store.defaultCalendarForNewReminders()
        try t.store.save(r, commit: true)
        try t.store.remove(r, commit: true)
        try t.store.remove(r, commit: true)
        #expect(t.another().calendarItem(withIdentifier: r.calendarItemIdentifier) == nil)
    }

    @Test("§2.4 reminder identifiers: external identifier is the calendarItemIdentifier; lookup returns EKReminder")
    func identifiers() throws {
        let t = TestStore()
        let r = EKReminder(eventStore: t.store)
        r.title = "lookup"
        r.calendar = t.store.defaultCalendarForNewReminders()
        try t.store.save(r, commit: true)
        #expect(r.calendarItemExternalIdentifier == r.calendarItemIdentifier)
        #expect(t.another().calendarItem(withIdentifier: r.calendarItemIdentifier) is EKReminder)
        #expect(t.another(events: .fullAccess, reminders: .denied).calendarItem(withIdentifier: r.calendarItemIdentifier) == nil)
    }

    @Test("§4 a cancelled fetch never completes; a normal fetch completes off the caller's queue")
    func cancel() async throws {
        let t = TestStore()
        let s = t.store
        let flag = NotificationCounterFlag()
        s.searchQueue.suspend()
        let id = s.fetchReminders(matching: s.predicateForReminders(in: nil)) { _ in flag.set() }
        s.cancelFetchRequest(id)
        s.searchQueue.resume()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!flag.isSet)

        let normal = await s.fetchReminders(matching: s.predicateForReminders(in: nil))
        #expect(normal != nil)
        #expect(s.predicateForReminders(in: nil).description == "ReminderPredicate")
    }
}

final class NotificationCounterFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
