// C-EK-STORE (plan.md §3.1; interface.md §2–§3, §5; errors.md §2;
// simulator-baseline.md §2).

import Foundation
import Testing
@testable import EventKit
#if canImport(CoreLocation)
import CoreLocation
#endif

@Suite("interface.md §2: sources, calendars, fresh device")
struct FreshDeviceTests {
    @Test("§2.2 fresh device: sources Default + Other, calendars Calendar + Birthdays, list Reminders")
    func freshDevice() throws {
        let t = TestStore()
        let s = t.store
        let sources = s.sources
        #expect(sources.map(\.title) == ["Default", "Other"])
        #expect(sources[0].sourceType == .local)
        #expect(sources[1].sourceType == .birthdays)
        #expect(sources[1].sourceIdentifier == "______NativeStorePersistentID_______")
        #expect(UUID(uuidString: sources[0].sourceIdentifier) != nil)

        let cals = s.calendars(for: .event)
        let calendar = try #require(cals.first { $0.title == "Calendar" })
        let birthdays = try #require(cals.first { $0.title == "Birthdays" })
        #expect(cals.count == 2)
        #expect(calendar.type == .local && calendar.allowsContentModifications && !calendar.isImmutable)
        #expect(calendar.source.sourceIdentifier == sources[0].sourceIdentifier)
        #expect(calendar.ycodeColor == YcodeRGBColor(red: 0.0, green: 0.5333, blue: 1.0))
        #expect(birthdays.type == .birthday && !birthdays.allowsContentModifications && birthdays.isImmutable)
        #expect(birthdays.source.title == "Other")
        #expect(birthdays.ycodeColor == YcodeRGBColor(red: 0.5098, green: 0.5843, blue: 0.6863))
        #expect(calendar.supportedEventAvailabilities == [])
        #expect(!calendar.isSubscribed)
        #expect(calendar.allowedEntityTypes == .event)

        let lists = s.calendars(for: .reminder)
        #expect(lists.map(\.title) == ["Reminders"])
        #expect(lists[0].calendarIdentifier == "3C8C2A71-84BF-4C87-8EFD-BB4827650D15")
        #expect(lists[0].source.title == "Default")
        #expect(lists[0].ycodeColor == YcodeRGBColor(red: 0.0, green: 0.4784, blue: 1.0))
        #expect(lists[0].allowedEntityTypes == .reminder)

        #expect(s.defaultCalendarForNewEvents?.title == "Calendar")
        #expect(s.defaultCalendarForNewReminders()?.title == "Reminders")
        #expect(s.calendar(withIdentifier: "no-such-calendar") == nil)
        #expect(s.source(withIdentifier: "______NativeStorePersistentID_______")?.title == "Other")
    }

    @Test("§2.1 eventStoreIdentifier: shared by stores on one database, nil without full access")
    func storeIdentifier() {
        let t = TestStore()
        let id = t.store.eventStoreIdentifier
        #expect(id != nil)
        #expect(t.another().eventStoreIdentifier == id)
        #expect(t.another(events: .denied).eventStoreIdentifier == nil)
    }

    @Test("§2.2 reminders-only access: one source \"Local\" with the fixed identifier")
    func remindersOnly() throws {
        let t = TestStore()
        let s = t.another(events: .notDetermined, reminders: .fullAccess)
        #expect(s.sources.map(\.title) == ["Local"])
        #expect(s.sources[0].sourceIdentifier == "3B242529-8F5D-47A1-9351-444101218C30")
        #expect(s.sources[0].sourceType == .local)
        let list = try #require(s.calendars(for: .reminder).first)
        #expect(list.source.sourceIdentifier == "3B242529-8F5D-47A1-9351-444101218C30")
        #expect(s.calendars(for: .event).isEmpty)
        #expect(s.defaultCalendarForNewEvents == nil)
    }

    @Test("§2.2 new calendar: local, no source, modifiable, no color until saved; code 14 without source")
    func newCalendar() throws {
        let t = TestStore()
        let s = t.store
        let cal = EKCalendar(for: .event, eventStore: s)
        #expect(cal.type == .local && cal.source == nil && cal.allowsContentModifications)
        #expect(cal.ycodeColor == nil)
        #expect(cal.allowedEntityTypes == .event)
        #expect(!cal.calendarIdentifier.isEmpty)
        cal.title = "Probe"
        expectCode(.calendarHasNoSource) { try s.saveCalendar(cal, commit: true) }
        cal.source = s.defaultCalendarForNewEvents!.source
        try s.saveCalendar(cal, commit: true)
        #expect(cal.ycodeColor == YcodeRGBColor(red: 0.7961, green: 0.1882, blue: 0.8784))
        cal.title = "Probe 2"
        try s.saveCalendar(cal, commit: true)
        #expect(t.another().calendar(withIdentifier: cal.calendarIdentifier)?.title == "Probe 2")

        let e = makeEvent(s, "in probe", start: date("2026-10-20 12:00"))
        e.calendar = cal
        try s.save(e, span: .thisEvent)
        try s.removeCalendar(cal, commit: true)
        #expect(t.another().calendar(withIdentifier: cal.calendarIdentifier) == nil)
        #expect(t.another().event(withIdentifier: e.eventIdentifier!) == nil)
    }

    @Test("§2.2 / errors §2 code 17: the Birthdays calendar cannot be removed")
    func removeBirthdays() throws {
        let t = TestStore()
        let b = try #require(t.store.calendars(for: .event).first { $0.title == "Birthdays" })
        expectCode(.sourceDoesNotAllowCalendarAddDelete) { try t.store.removeCalendar(b, commit: true) }
    }

    @Test("§2.2 new reminder list gets the system blue")
    func newList() throws {
        let t = TestStore()
        let list = EKCalendar(for: .reminder, eventStore: t.store)
        list.title = "Groceries"
        list.source = t.store.defaultCalendarForNewReminders()!.source
        try t.store.saveCalendar(list, commit: true)
        #expect(list.ycodeColor == YcodeRGBColor(red: 0.0, green: 0.4784, blue: 1.0))
        #expect(t.store.calendars(for: .reminder).count == 2)
    }
}

@Suite("interface.md §2.4–§2.5, §3: items, identifiers, saving")
struct EventStoreTests {
    @Test("§3.1 defaults of a new event")
    func newEventDefaults() {
        let t = TestStore()
        let e = EKEvent(eventStore: t.store)
        #expect(e.title == "")
        #expect(e.startDate == nil && e.endDate == nil)
        #expect(e.timeZone == newYork)
        #expect(!e.isAllDay)
        #expect(e.calendar == nil)
        #expect(e.availability == .notSupported)
        #expect(e.status == .none)
        #expect(e.isNew && e.hasChanges)
        #expect(e.eventIdentifier == nil)
        #expect(!e.calendarItemIdentifier.isEmpty)
        #expect(e.calendarItemExternalIdentifier == e.calendarItemIdentifier)
        #expect(e.alarms == nil && !e.hasAlarms)
        #expect(e.recurrenceRules == nil)
    }

    @Test("§2.4 identifier forms and lookups; §2.5 state after save")
    func identifiers() throws {
        let t = TestStore()
        let s = t.store
        let e = makeEvent(s, "ids", start: date("2026-10-20 14:00"))
        try s.save(e, span: .thisEvent)
        let id = try #require(e.eventIdentifier)
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        #expect(parts.count == 2)
        #expect(parts[0] == s.defaultCalendarForNewEvents!.source.sourceIdentifier)
        #expect(UUID(uuidString: parts[1]) != nil)
        #expect(e.calendarItemExternalIdentifier == parts[1])
        #expect(!e.isNew && !e.hasChanges)
        #expect(e.creationDate != nil && e.lastModifiedDate != nil)
        #expect(e.status == .none && e.organizer == nil && !e.hasAttendees)

        let other = t.another()
        #expect(other.event(withIdentifier: id)?.title == "ids")
        #expect(other.event(withIdentifier: "unknown") == nil)
        #expect(other.calendarItem(withIdentifier: e.calendarItemIdentifier) is EKEvent)
        #expect(other.calendarItem(withIdentifier: "unknown") == nil)
        #expect(other.calendarItems(withExternalIdentifier: parts[1]).count == 1)

        // Saving again updates (no duplicate).
        e.title = "ids2"
        try s.save(e, span: .thisEvent)
        #expect(occurrences(other, "ids2").count == 1)
        #expect(occurrences(other, "ids").isEmpty)
        #expect(e.eventIdentifier == id)
    }

    @Test("§2.5 rollback, refresh, reset")
    func rollbackRefreshReset() throws {
        let t = TestStore()
        let s = t.store
        let e = makeEvent(s, "keep", start: date("2026-10-20 14:00"))
        try s.save(e, span: .thisEvent)
        e.title = "changed"
        #expect(e.hasChanges)
        e.rollback()
        #expect(!e.hasChanges)
        #expect(e.title == "keep")
        #expect(e.refresh())

        let id = try #require(e.eventIdentifier)
        let fetched = try #require(s.event(withIdentifier: id))
        s.reset()
        #expect(fetched.eventIdentifier == nil)
        #expect(fetched.title == "keep")
        // Fetched again after the reset, the object is valid.
        #expect(s.event(withIdentifier: id)?.eventIdentifier == id)
    }

    @Test("§3.3 all-day normalization table")
    func allDay() throws {
        let t = TestStore()
        let s = t.store
        let rows: [(String, String, String, String)] = [
            ("2026-10-07 00:00", "2026-10-07 00:00", "2026-10-07 00:00:00", "2026-10-07 23:59:59"),
            ("2026-10-10 00:00", "2026-10-12 00:00", "2026-10-10 00:00:00", "2026-10-11 23:59:59"),
            ("2026-10-13 15:30", "2026-10-13 16:30", "2026-10-13 00:00:00", "2026-10-13 23:59:59"),
        ]
        for (i, r) in rows.enumerated() {
            let e = makeEvent(s, "allday\(i)", start: ny(r.0))
            e.endDate = ny(r.1)
            e.isAllDay = true
            try s.save(e, span: .thisEvent)
            #expect(e.timeZone == nil)
            let back = try #require(t.another().event(withIdentifier: e.eventIdentifier!))
            #expect(localText(back.startDate, newYork) == r.2)
            #expect(localText(back.endDate, newYork) == r.3)
            #expect(back.isAllDay && back.timeZone == nil)
            #expect(back.alarms == nil) // no default alarms
        }
    }

    @Test("§3.2 floating 14:00 reads as 18:00Z (New York), 05:00Z (Tokyo), 12:00Z (Berlin), 14:00Z (UTC)")
    func floating() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "floating", start: ny("2026-10-20 14:00"), zone: nil)
        try t.store.save(e, span: .thisEvent)
        let id = e.eventIdentifier!
        let expected: [(TimeZone, String)] = [(newYork, "2026-10-20 18:00"), (tokyo, "2026-10-20 05:00"),
                                              (berlin, "2026-10-20 12:00"), (.utc, "2026-10-20 14:00")]
        for (zone, want) in expected {
            let back = try #require(t.another(zone: zone).event(withIdentifier: id))
            #expect(utcText(back.startDate) == want)
            #expect(back.timeZone == nil)
        }
    }

    @Test("§3.2 changing the time zone keeps the instants (9:00 New York = 15:00 Berlin)")
    func zoneChange() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "tz", start: ny("2026-10-20 09:00"))
        try t.store.save(e, span: .thisEvent)
        e.timeZone = berlin
        try t.store.save(e, span: .thisEvent)
        let back = try #require(t.another().event(withIdentifier: e.eventIdentifier!))
        #expect(back.startDate == ny("2026-10-20 09:00"))
        #expect(back.timeZone == berlin)
        #expect(localText(back.startDate, berlin) == "2026-10-20 15:00:00")
    }

    @Test("§3.6 window rule: inclusive at the window start, exclusive at the end")
    func windowRule() throws {
        let t = TestStore()
        let s = t.store
        let e = makeEvent(s, "window", start: date("2026-10-20 13:00"))
        try s.save(e, span: .thisEvent)
        let long = makeEvent(s, "long", start: date("2026-10-20 10:00"), minutes: 8 * 60)
        try s.save(long, span: .thisEvent)
        func titles(_ a: String, _ b: String) -> Set<String> {
            Set(s.events(matching: s.predicateForEvents(withStart: date(a), end: date(b), calendars: nil)).map(\.title))
        }
        #expect(titles("2026-10-20 14:00", "2026-10-20 15:00") == ["window", "long"])
        #expect(titles("2026-10-20 12:00", "2026-10-20 13:00") == ["long"])
        let onlyBirthdays = s.calendars(for: .event).filter { $0.title == "Birthdays" }
        #expect(s.events(matching: s.predicateForEvents(withStart: date("2026-10-20"), end: date("2026-10-21"),
                                                        calendars: onlyBirthdays)).isEmpty)
    }

    @Test("§3.6 four-year cap: a ten-year window returns 2028 and 2029 but not 2030-02-28")
    func fourYearCap() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "leap", start: ny("2028-02-29 09:00"))
        e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
        try t.store.save(e, span: .thisEvent)
        let got = occurrences(t.store, "leap", from: date("2026-01-01"), to: date("2036-01-01")).map { utcText($0.startDate) }
        #expect(got == ["2028-02-29 14:00", "2029-02-28 14:00"])
    }

    @Test("§3.6 enumerate yields the same set and honours stop")
    func enumerate() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "enum", start: ny("2026-10-26 08:00"))
        e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5)))
        try t.store.save(e, span: .thisEvent)
        let p = t.store.predicateForEvents(withStart: date("2026-10-01"), end: date("2026-12-01"), calendars: nil)
        var n = 0
        t.store.enumerateEvents(matching: p) { _, _ in n += 1 }
        #expect(n == t.store.events(matching: p).count)
        var m = 0
        t.store.enumerateEvents(matching: p) { _, stop in m += 1; if m == 2 { stop.pointee = true } }
        #expect(m == 2)
    }

    @Test("§3.4 / errors §2: error codes 1, 2, 3, 4, 6, 11, 22")
    func errorCodes() throws {
        let t = TestStore()
        let s = t.store
        let noCal = makeEvent(s, "x", start: date("2026-10-20 12:00"))
        noCal.calendar = nil
        expectCode(.noCalendar) { try s.save(noCal, span: .thisEvent) }
        let noStart = makeEvent(s, "x", start: date("2026-10-20 12:00"))
        noStart.startDate = nil
        expectCode(.noStartDate) { try s.save(noStart, span: .thisEvent) }
        let noEnd = makeEvent(s, "x", start: date("2026-10-20 12:00"))
        noEnd.endDate = nil
        expectCode(.noEndDate) { try s.save(noEnd, span: .thisEvent) }
        let inverted = makeEvent(s, "x", start: date("2026-10-20 12:00"), minutes: -10)
        expectCode(.datesInverted) { try s.save(inverted, span: .thisEvent) }
        let birthday = makeEvent(s, "x", start: date("2026-10-20 12:00"))
        birthday.calendar = s.calendars(for: .event).first { $0.title == "Birthdays" }
        expectCode(.calendarReadOnly) { try s.save(birthday, span: .thisEvent) }
        let foreign = makeEvent(t.another(), "x", start: date("2026-10-20 12:00"))
        expectCode(.objectBelongsToDifferentStore) { try s.save(foreign, span: .thisEvent) }
        let intoList = makeEvent(s, "x", start: date("2026-10-20 12:00"))
        intoList.calendar = s.defaultCalendarForNewReminders()
        expectCode(.calendarDoesNotAllowEvents) { try s.save(intoList, span: .thisEvent) }
        #expect((EKError(.noCalendar) as NSError).localizedDescription.isEmpty == false)
    }

    @Test("§3.4 acceptances: zero duration, year 4100, year 1800")
    func acceptances() throws {
        let t = TestStore()
        let s = t.store
        try s.save(makeEvent(s, "zero", start: date("2026-10-20 12:00"), minutes: 0), span: .thisEvent)
        let future = makeEvent(s, "4100", start: date("4100-01-01 12:00"))
        try s.save(future, span: .thisEvent)
        let past = makeEvent(s, "1800", start: date("1800-01-01 12:00"))
        try s.save(past, span: .thisEvent)
        #expect(utcText(t.another().event(withIdentifier: past.eventIdentifier!)!.startDate) == "1800-01-01 12:00")
        #expect(t.another().event(withIdentifier: future.eventIdentifier!) != nil)
        #expect(occurrences(s, "zero").count == 1)
    }

    @Test("§3.5 alarms: coupling, duplicates kept, read-back order; structured location")
    func alarmsAndLocations() throws {
        let rel = EKAlarm(relativeOffset: -900)
        rel.absoluteDate = date("2026-10-20 10:00")
        #expect(rel.relativeOffset == 0)
        let abs = EKAlarm(absoluteDate: date("2026-10-20 10:00"))
        abs.relativeOffset = -60
        #expect(abs.absoluteDate == nil)

        let t = TestStore()
        let e = makeEvent(t.store, "alarms", start: date("2026-10-20 12:00"))
        e.addAlarm(EKAlarm(absoluteDate: date("2026-10-20 09:00")))
        e.addAlarm(EKAlarm(relativeOffset: -900))
        e.addAlarm(EKAlarm(relativeOffset: -900))
        let geo = EKAlarm()
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 41.15, longitude: -81.34)
        place.radius = 100
        geo.structuredLocation = place
        geo.proximity = .leave
        e.addAlarm(geo)
        e.structuredLocation = place
        #expect(e.location == "Office")
        try t.store.save(e, span: .thisEvent)
        let back = try #require(t.another().event(withIdentifier: e.eventIdentifier!))
        let alarms = try #require(back.alarms)
        #expect(alarms.count == 4)
        #expect(alarms[0].structuredLocation?.title == "Office" && alarms[0].proximity == .leave)
        #expect(alarms[1].relativeOffset == -900 && alarms[2].relativeOffset == -900)
        #expect(alarms[3].absoluteDate == date("2026-10-20 09:00"))
        #expect(back.structuredLocation?.title == "Office")
        #expect(back.structuredLocation?.radius == 100)
        #expect(back.structuredLocation?.geoLocation?.coordinate.latitude == 41.15)
        #expect(back.location == "Office")
    }

    @Test("§2.5 persistence: a later store instance sees committed events")
    func persistence() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "persist", start: date("2026-10-20 12:00"))
        try t.store.save(e, span: .thisEvent)
        let later = t.another()
        #expect(later.event(withIdentifier: e.eventIdentifier!)?.title == "persist")
        try later.remove(later.event(withIdentifier: e.eventIdentifier!)!, span: .thisEvent)
        #expect(t.another().event(withIdentifier: e.eventIdentifier!) == nil)
        // Removing again succeeds.
        try t.store.remove(e, span: .thisEvent)
    }
}

@Suite("interface.md §2.5, §5: batches and change notifications")
struct NotificationTests {
    @Test("batch of 3 with commit NO: visible in the same store, one notification after commit")
    func batch() async throws {
        let t = TestStore()
        let s = t.store
        let counter = NotificationCounter(s)
        for i in 0..<3 {
            try s.save(makeEvent(s, "batch", start: date("2026-10-2\(i) 12:00")), span: .thisEvent, commit: false)
        }
        #expect(occurrences(s, "batch").count == 3)
        #expect(occurrences(t.another(), "batch").isEmpty)
        await counter.settle()
        #expect(counter.count == 0)
        try s.commit()
        await counter.settle()
        #expect(counter.count == 1)
        #expect(counter.offMain == 0)
        #expect(occurrences(t.another(), "batch").count == 3)
        let info = try #require(counter.lastInfo)
        #expect(info["EKEventStoreCalendarDataChangedUserInfoKey"] as? Bool == true)
        #expect((info["EKEventStoreChangedObjectIDsUserInfoKey"] as? [String])?.count == 3)
    }

    @Test("another store's save → one notification; one per commit")
    func otherStore() async throws {
        let t = TestStore()
        let counter = NotificationCounter(t.store)
        let other = t.another()
        try other.save(makeEvent(other, "elsewhere", start: date("2026-10-20 12:00")), span: .thisEvent)
        await counter.settle()
        #expect(counter.count == 1)
        for i in 0..<4 { try t.store.save(makeEvent(t.store, "n\(i)", start: date("2026-10-20 12:00")), span: .thisEvent) }
        await counter.settle(wait: 0.5)
        #expect(counter.count == 5)
        #expect(counter.offMain == 0)
    }

    @Test("reset discards staged changes without a notification")
    func resetStaged() async throws {
        let t = TestStore()
        let counter = NotificationCounter(t.store)
        try t.store.save(makeEvent(t.store, "staged", start: date("2026-10-20 12:00")), span: .thisEvent, commit: false)
        t.store.reset()
        try t.store.commit()
        await counter.settle()
        #expect(counter.count == 0)
        #expect(occurrences(t.another(), "staged").isEmpty)
    }

    @Test("a commit from another process reaches this process's store")
    func crossProcess() async throws {
        let t = TestStore()
        let counter = NotificationCounter(t.store)
        let path = t.url.path
        await #expect(processExitsWith: .success) { [path = path as String] in
            let s = EKEventStore(ycodeConfiguration: YcodeEventStoreConfiguration(
                databaseURL: URL(fileURLWithPath: path), timeZone: TimeZone(identifier: "UTC")))
            let e = EKEvent(eventStore: s)
            e.title = "from child"
            e.startDate = Date(timeIntervalSince1970: 1_792_000_000)
            e.endDate = e.startDate.addingTimeInterval(600)
            e.calendar = s.defaultCalendarForNewEvents
            try s.save(e, span: .thisEvent)
        }
        for _ in 0..<20 where counter.count == 0 { await counter.settle(wait: 0.1) }
        #expect(counter.count == 1)
        #expect(counter.offMain == 0)
        #expect(t.store.events(matching: t.store.predicateForEvents(
            withStart: Date(timeIntervalSince1970: 1_791_000_000), end: Date(timeIntervalSince1970: 1_793_000_000),
            calendars: nil)).map(\.title) == ["from child"])
    }
}

@Suite("authorization.md §4: what each access level sees")
struct AccessLevelTests {
    @Test("no access: nothing visible, save → 1, calendar save → 14, reminders fetch → empty array")
    func noAccess() async throws {
        let t = TestStore(events: .notDetermined, reminders: .notDetermined)
        let s = t.store
        #expect(s.sources.isEmpty)
        #expect(s.calendars(for: .event).isEmpty && s.calendars(for: .reminder).isEmpty)
        #expect(s.defaultCalendarForNewEvents == nil && s.defaultCalendarForNewReminders() == nil)
        #expect(s.eventStoreIdentifier == nil)
        let e = makeEvent(s, "x", start: date("2026-10-20 12:00"))
        expectCode(.noCalendar) { try s.save(e, span: .thisEvent) }
        let cal = EKCalendar(for: .event, eventStore: s)
        expectCode(.calendarHasNoSource) { try s.saveCalendar(cal, commit: true) }
        let result = await s.fetchReminders(matching: s.predicateForReminders(in: nil))
        #expect(result != nil && result!.isEmpty)
        #expect(s.events(matching: s.predicateForEvents(withStart: date("2026-01-01"), end: date("2027-01-01"),
                                                        calendars: nil)).isEmpty)
    }

    @Test("§2.3 write-only: virtual source and calendar; save works, nothing reads back")
    func writeOnly() throws {
        let t = TestStore()
        let full = t.store
        let s = t.another(events: .writeOnly, reminders: .notDetermined)
        #expect(s.sources.map(\.title) == ["Account"])
        #expect(s.sources[0].sourceIdentifier == "VIRTUAL_APP_SOURCE_UUID")
        #expect(s.sources[0].sourceType == .calDAV)
        let cal = try #require(s.defaultCalendarForNewEvents)
        #expect(cal.title == "Calendar" && cal.calendarIdentifier == "VIRTUAL_APP_CALENDAR_UUID")
        #expect(cal.type == .calDAV && cal.isImmutable && cal.allowsContentModifications)
        #expect(cal.ycodeColor == YcodeRGBColor(red: 1.0, green: 0.2196, blue: 0.2353))
        #expect(cal.allowedEntityTypes == .event)
        #expect(s.calendars(for: .event).map(\.calendarIdentifier) == ["VIRTUAL_APP_CALENDAR_UUID"])

        let e = makeEvent(s, "write-only", start: date("2026-10-20 12:00"))
        try s.save(e, span: .thisEvent)
        let id = try #require(e.eventIdentifier)
        #expect(id.hasPrefix(full.defaultCalendarForNewEvents!.source.sourceIdentifier + ":"))
        #expect(s.event(withIdentifier: id) == nil)
        #expect(s.calendarItem(withIdentifier: e.calendarItemIdentifier) == nil)
        #expect(occurrences(s, "write-only").isEmpty)
        #expect(occurrences(full, "write-only").count == 1)
        #expect(full.event(withIdentifier: id)?.calendar.title == "Calendar")

        e.title = "write-only edited"
        try s.save(e, span: .thisEvent)
        #expect(occurrences(full, "write-only edited").count == 1)
        try s.remove(e, span: .thisEvent)
        #expect(full.event(withIdentifier: id) == nil)

        let newCal = EKCalendar(for: .event, eventStore: s)
        newCal.source = s.sources[0]
        expectCode(.sourceDoesNotAllowCalendarAddDelete) { try s.saveCalendar(newCal, commit: true) }
    }

    @Test("authorizationStatus(for:) reports the default configuration's recorded answers")
    func status() async throws {
        #expect([.fullAccess, .writeOnly, .denied, .notDetermined, .restricted].contains(
            EKEventStore.authorizationStatus(for: .event)))
        let t = TestStore(events: .writeOnly, reminders: .denied)
        #expect(try await t.store.requestWriteOnlyAccessToEvents())
        #expect(try await !t.store.requestFullAccessToEvents())
        #expect(try await !t.store.requestFullAccessToReminders())
    }
}
