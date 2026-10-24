// C-EK-REC: editing recurring events (recurrence.md §6, §4 items 4–5).

import Foundation
import Testing
@testable import EventKit

@Suite("recurrence.md §6: editing recurring events")
struct EditingTests {
    /// R1's series: weekly MO,WE,FR from Mon 2026-10-26 08:30 New York, count 10.
    func r1Series(_ t: TestStore, title: String = "series") throws -> EKEvent {
        let e = makeEvent(t.store, title, start: ny("2026-10-26 08:30"), minutes: 30)
        e.addRecurrenceRule(EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [.monday, .wednesday, .friday].map { EKRecurrenceDayOfWeek($0) },
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
            end: EKRecurrenceEnd(occurrenceCount: 10)))
        try t.store.save(e, span: .thisEvent)
        return e
    }

    @Test("occurrences are distinct objects sharing the master's eventIdentifier")
    func occurrenceObjects() throws {
        let t = TestStore()
        let master = try r1Series(t)
        let occ = occurrences(t.store, "series")
        #expect(occ.count == 10)
        #expect(Set(occ.map { ObjectIdentifier($0) }).count == 10)
        #expect(occ.allSatisfy { $0.eventIdentifier == master.eventIdentifier && !$0.isDetached })
        #expect(occ.map { utcText($0.occurrenceDate) } == occ.map { utcText($0.startDate) })
    }

    @Test("detach: change one occurrence with this-event span; identifiers get /RID=815056200")
    func detach() throws {
        let t = TestStore()
        let master = try r1Series(t)
        let third = try #require(occurrences(t.store, "series").first { utcText($0.startDate) == "2026-10-30 12:30" })
        let oldItemID = third.calendarItemIdentifier
        third.title = "moved"
        third.endDate = third.endDate.addingTimeInterval(90 * 60)
        try t.store.save(third, span: .thisEvent)
        #expect(third.isDetached)
        #expect(third.recurrenceRules == nil)
        #expect(utcText(third.occurrenceDate) == "2026-10-30 12:30")
        #expect(third.eventIdentifier == master.eventIdentifier! + "/RID=815056200")
        #expect(third.calendarItemExternalIdentifier.hasSuffix("/RID=815056200"))
        #expect(third.calendarItemIdentifier != oldItemID)
        #expect(Int(date("2026-10-30 12:30").timeIntervalSinceReferenceDate) == 815056200)

        let again = occurrences(t.another(), "series") + occurrences(t.another(), "moved")
        #expect(again.count == 10)
        let moved = try #require(again.first { $0.title == "moved" })
        #expect(moved.isDetached)
        #expect(moved.endDate.timeIntervalSince(moved.startDate) == 120 * 60)
        #expect(t.store.event(withIdentifier: master.eventIdentifier! + "/RID=815056200")?.title == "moved")
    }

    @Test("remove one occurrence with this-event span")
    func removeOne() throws {
        let t = TestStore()
        _ = try r1Series(t)
        let fourth = try #require(occurrences(t.store, "series").first { utcText($0.startDate) == "2026-11-02 13:30" })
        try t.store.remove(fourth, span: .thisEvent)
        let left = occurrences(t.another(), "series").map { utcText($0.startDate) }
        #expect(left.count == 9)
        #expect(!left.contains("2026-11-02 13:30"))
    }

    @Test("moving an occurrence onto the next one is accepted; both are returned")
    func collision() throws {
        let t = TestStore()
        _ = try r1Series(t)
        let second = try #require(occurrences(t.store, "series").first { utcText($0.startDate) == "2026-10-28 12:30" })
        second.startDate = date("2026-10-30 12:30")
        second.endDate = date("2026-10-30 13:00")
        try t.store.save(second, span: .thisEvent)
        let at = occurrences(t.another(), "series").filter { utcText($0.startDate) == "2026-10-30 12:30" }
        #expect(at.count == 2)
    }

    @Test("split: change occurrence 7 with future span → COUNT=6 and a new master with COUNT=4")
    func split() throws {
        let t = TestStore()
        let master = try r1Series(t)
        // An exception before the split stays with the original.
        let second = try #require(occurrences(t.store, "series").first { utcText($0.startDate) == "2026-10-28 12:30" })
        second.title = "series" // unchanged title, new notes
        second.notes = "detached before split"
        try t.store.save(second, span: .thisEvent)

        let seventh = try #require(occurrences(t.store, "series").first { utcText($0.startDate) == "2026-11-09 13:30" })
        seventh.title = "series-b"
        try t.store.save(seventh, span: .futureEvents)
        #expect(seventh.eventIdentifier != master.eventIdentifier)
        #expect(seventh.recurrenceRules?.first?.rruleText == "FREQ=WEEKLY;INTERVAL=1;COUNT=4;BYDAY=MO,WE,FR")

        let reader = t.another()
        let original = try #require(reader.event(withIdentifier: master.eventIdentifier!))
        #expect(original.recurrenceRules?.first?.rruleText == "FREQ=WEEKLY;INTERVAL=1;COUNT=6;BYDAY=MO,WE,FR")
        let a = occurrences(reader, "series")
        let b = occurrences(reader, "series-b")
        #expect(a.count == 6)
        #expect(b.map { utcText($0.startDate) } == ["2026-11-09 13:30", "2026-11-11 13:30", "2026-11-13 13:30", "2026-11-16 13:30"])
        #expect(a.contains { $0.isDetached && $0.notes == "detached before split" })
    }

    @Test("removing the rule from the master with future span leaves a single event")
    func ruleRemoval() throws {
        let t = TestStore()
        let master = try r1Series(t)
        let m = try #require(t.store.event(withIdentifier: master.eventIdentifier!))
        m.recurrenceRules = nil
        try t.store.save(m, span: .futureEvents)
        #expect(occurrences(t.another(), "series").count == 1)
    }

    @Test("future delete of occurrence 3 → UNTIL=20261013T035959Z (§4 item 5)")
    func futureDelete() throws {
        let t = TestStore()
        // R2's series: daily, interval 2, from Sat 2026-10-10 07:00 New York.
        let e = makeEvent(t.store, "every-other", start: ny("2026-10-10 07:00"))
        e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 2,
                                             end: EKRecurrenceEnd(end: ny("2026-10-20 07:00"))))
        try t.store.save(e, span: .thisEvent)
        let third = try #require(occurrences(t.store, "every-other").first { utcText($0.startDate) == "2026-10-14 11:00" })
        try t.store.remove(third, span: .futureEvents)
        let reader = t.another()
        #expect(occurrences(reader, "every-other").map { utcText($0.startDate) } == ["2026-10-10 11:00", "2026-10-12 11:00"])
        #expect(reader.event(withIdentifier: e.eventIdentifier!)?.recurrenceRules?.first?.rruleText
                == "FREQ=DAILY;INTERVAL=2;UNTIL=20261013T035959Z")
    }

    @Test("future span on the first occurrence edits the whole series")
    func firstOccurrenceFuture() throws {
        let t = TestStore()
        _ = try r1Series(t)
        let first = try #require(occurrences(t.store, "series").first)
        first.title = "renamed"
        try t.store.save(first, span: .futureEvents)
        #expect(occurrences(t.another(), "renamed").count == 10)
        #expect(occurrences(t.another(), "series").isEmpty)
    }

    @Test("future delete from the first occurrence removes the series")
    func futureDeleteAll() throws {
        let t = TestStore()
        _ = try r1Series(t)
        let first = try #require(occurrences(t.store, "series").first)
        try t.store.remove(first, span: .futureEvents)
        #expect(occurrences(t.another(), "series").isEmpty)
    }
}
