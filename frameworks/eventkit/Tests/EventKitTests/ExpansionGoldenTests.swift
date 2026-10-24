// C-EK-REC: golden expansions R1–R15 (recurrence.md §5.1), through the
// store (save, then fetch from a second store instance), reader in New York.

import Foundation
import Testing
@testable import EventKit

@Suite("recurrence.md §5.1 golden expansions")
struct ExpansionGoldenTests {
    func wd(_ d: [EKWeekday], _ week: Int = 0) -> [EKRecurrenceDayOfWeek] { d.map { EKRecurrenceDayOfWeek($0, weekNumber: week) } }
    func n(_ a: [Int]) -> [NSNumber] { a.map { NSNumber(value: $0) } }
    func count(_ c: Int) -> EKRecurrenceEnd { EKRecurrenceEnd(occurrenceCount: c) }

    func rule(_ f: EKRecurrenceFrequency, interval: Int = 1, days: [EKRecurrenceDayOfWeek]? = nil, monthDays: [Int]? = nil,
              months: [Int]? = nil, weeks: [Int]? = nil, yearDays: [Int]? = nil, setPos: [Int]? = nil,
              end: EKRecurrenceEnd?) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: f, interval: interval, daysOfTheWeek: days, daysOfTheMonth: monthDays.map(n),
                         monthsOfTheYear: months.map(n), weeksOfTheYear: weeks.map(n), daysOfTheYear: yearDays.map(n),
                         setPositions: setPos.map(n), end: end)
    }

    /// Saves an event with the rules and returns the UTC starts of its
    /// occurrences read through a fresh store.
    func expand(start: Date, minutes: Double = 60, zone: TimeZone? = newYork, allDay: Bool = false,
                rules: [EKRecurrenceRule], from: Date = date("2026-01-01"), to: Date = date("2029-12-31")) throws -> [String] {
        let t = TestStore()
        let e = makeEvent(t.store, "golden", start: start, minutes: minutes, zone: zone)
        e.isAllDay = allDay
        for r in rules { e.addRecurrenceRule(r) }
        try t.store.save(e, span: .thisEvent)
        let reader = t.another()
        return occurrences(reader, "golden", from: from, to: to).map { utcText($0.startDate) }
    }

    @Test("R1 weekly MO,WE,FR count 10 across the DST change")
    func r1() throws {
        let got = try expand(start: ny("2026-10-26 08:30"), minutes: 30,
                             rules: [rule(.weekly, days: wd([.monday, .wednesday, .friday]), end: count(10))])
        #expect(got == ["2026-10-26 12:30", "2026-10-28 12:30", "2026-10-30 12:30", "2026-11-02 13:30", "2026-11-04 13:30",
                        "2026-11-06 13:30", "2026-11-09 13:30", "2026-11-11 13:30", "2026-11-13 13:30", "2026-11-16 13:30"])
    }

    @Test("R2 daily interval 2 until 10-20 07:00 local (UNTIL inclusive)")
    func r2() throws {
        let got = try expand(start: ny("2026-10-10 07:00"),
                             rules: [rule(.daily, interval: 2, end: EKRecurrenceEnd(end: ny("2026-10-20 07:00")))])
        #expect(got == ["2026-10-10 11:00", "2026-10-12 11:00", "2026-10-14 11:00", "2026-10-16 11:00",
                        "2026-10-18 11:00", "2026-10-20 11:00"])
    }

    @Test("R3 plain monthly from the 31st count 6 (last day of shorter months)")
    func r3() throws {
        let got = try expand(start: ny("2026-10-31 12:00"), rules: [rule(.monthly, end: count(6))])
        #expect(got == ["2026-10-31 16:00", "2026-11-30 17:00", "2026-12-31 17:00", "2027-01-31 17:00",
                        "2027-02-28 17:00", "2027-03-31 16:00"])
    }

    @Test("R3b monthly BYMONTHDAY=31 count 6 skips short months")
    func r3b() throws {
        let got = try expand(start: ny("2026-10-31 12:00"), rules: [rule(.monthly, monthDays: [31], end: count(6))])
        let localNY = ["2026-10-31", "2026-12-31", "2027-01-31", "2027-03-31", "2027-05-31", "2027-07-31"].map {
            utcText(ny("\($0) 12:00"))
        }
        #expect(got == localNY)
    }

    @Test("R4 monthly last Friday count 5")
    func r4() throws {
        let got = try expand(start: ny("2026-10-30 17:00"), rules: [rule(.monthly, days: wd([.friday], -1), end: count(5))])
        #expect(got == ["2026-10-30 21:00", "2026-11-27 22:00", "2026-12-25 22:00", "2027-01-29 22:00", "2027-02-26 22:00"])
    }

    @Test("R5 monthly weekdays BYSETPOS=-2 count 4")
    func r5() throws {
        let got = try expand(start: ny("2026-10-29 10:00"),
                             rules: [rule(.monthly, days: wd([.monday, .tuesday, .wednesday, .thursday, .friday]),
                                          setPos: [-2], end: count(4))])
        #expect(got == ["2026-10-29 14:00", "2026-11-27 15:00", "2026-12-30 15:00", "2027-01-28 15:00"])
    }

    @Test("R6 plain yearly from February 29 count 3")
    func r6() throws {
        let got = try expand(start: ny("2028-02-29 09:00"), rules: [rule(.yearly, end: count(3))],
                             from: date("2028-01-01"), to: date("2031-12-31"))
        #expect(got == ["2028-02-29 14:00", "2029-02-28 14:00", "2030-02-28 14:00"])
    }

    @Test("R7 yearly 4th Thursday of November count 3")
    func r7() throws {
        let got = try expand(start: ny("2026-11-26 15:00"),
                             rules: [rule(.yearly, days: wd([.thursday], 4), months: [11], end: count(3))])
        #expect(got == ["2026-11-26 20:00", "2027-11-25 20:00", "2028-11-23 20:00"])
    }

    @Test("R8 weekly interval 2 TU,TH count 6 (start counts, WKST=MO)")
    func r8() throws {
        let got = try expand(start: ny("2026-10-01 11:00"),
                             rules: [rule(.weekly, interval: 2, days: wd([.tuesday, .thursday]), end: count(6))])
        #expect(got == ["2026-10-01 15:00", "2026-10-13 15:00", "2026-10-15 15:00", "2026-10-27 15:00",
                        "2026-10-29 15:00", "2026-11-10 16:00"])
    }

    /// The reference returned only the first occurrence (§5 item 7). The spec
    /// tells Ycode to implement RFC 5545 until C-REC-Q1 is settled, so this
    /// test checks the RFC result: Monday of ISO week 20 each year.
    @Test("R9 yearly BYWEEKNO=20;BYDAY=MO count 3 (RFC behavior; quirk is C-REC-Q1)")
    func r9() throws {
        let got = try expand(start: ny("2027-05-17 09:00"),
                             rules: [rule(.yearly, days: wd([.monday]), weeks: [20], end: count(3))],
                             from: date("2027-01-01"), to: date("2030-09-01"))
        #expect(got.first == "2027-05-17 13:00")
        #expect(got == ["2027-05-17 13:00", "2028-05-15 13:00", "2029-05-14 13:00"])
    }

    @Test("R10 yearly BYYEARDAY=100 count 3")
    func r10() throws {
        let got = try expand(start: ny("2027-04-10 09:00"), rules: [rule(.yearly, yearDays: [100], end: count(3))],
                             from: date("2027-01-01"), to: date("2030-12-31"))
        #expect(got == ["2027-04-10 13:00", "2028-04-09 13:00", "2029-04-10 13:00"])
    }

    @Test("R11 floating daily count 3 read in New York")
    func r11() throws {
        let got = try expand(start: ny("2026-10-31 22:00"), zone: nil, rules: [rule(.daily, end: count(3))])
        #expect(got == ["2026-11-01 02:00", "2026-11-02 03:00", "2026-11-03 03:00"])
    }

    @Test("R12 all-day yearly count 3 at local midnight")
    func r12() throws {
        let got = try expand(start: ny("2026-12-25 00:00"), minutes: 0, allDay: true, rules: [rule(.yearly, end: count(3))])
        #expect(got == ["2026-12-25 05:00", "2027-12-25 05:00", "2028-12-25 05:00"])
    }

    @Test("R13 union of weekly count 2 and daily count 2")
    func r13() throws {
        let got = try expand(start: ny("2026-11-02 09:00"),
                             rules: [rule(.weekly, end: count(2)), rule(.daily, end: count(2))])
        #expect(got == ["2026-11-02 14:00", "2026-11-03 14:00", "2026-11-09 14:00"])
    }

    @Test("R14 start counts as the first occurrence (weekly WE from a Monday)")
    func r14() throws {
        let got = try expand(start: ny("2026-11-02 12:00"), rules: [rule(.weekly, days: wd([.wednesday]), end: count(3))])
        #expect(got == ["2026-11-02 17:00", "2026-11-04 17:00", "2026-11-11 17:00"])
    }

    @Test("R15 UNTIL before the start: no occurrences at all")
    func r15() throws {
        let got = try expand(start: ny("2026-11-03 12:00"),
                             rules: [rule(.daily, end: EKRecurrenceEnd(end: ny("2026-11-01 00:00")))])
        #expect(got.isEmpty)
    }

    @Test("§5 item 6: the item reports both rules")
    func bothRules() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "two", start: ny("2026-11-02 09:00"))
        e.addRecurrenceRule(rule(.weekly, end: count(2)))
        e.addRecurrenceRule(rule(.daily, end: count(2)))
        try t.store.save(e, span: .thisEvent)
        #expect(t.another().event(withIdentifier: e.eventIdentifier!)?.recurrenceRules?.count == 2)
    }
}

@Suite("recurrence.md §4: normalization on save")
struct NormalizationTests {
    func savedRuleText(start: Date, _ rule: EKRecurrenceRule) throws -> String {
        let t = TestStore()
        let e = makeEvent(t.store, "norm", start: start)
        e.addRecurrenceRule(rule)
        try t.store.save(e, span: .thisEvent)
        let back = try #require(t.another().event(withIdentifier: e.eventIdentifier!))
        return back.recurrenceRules![0].rruleText
    }

    @Test("item 1: plain monthly from the 31st reads back as BYMONTHDAY=28,29,30,31;BYSETPOS=-1")
    func monthly31() throws {
        #expect(try savedRuleText(start: ny("2026-10-31 12:00"),
                                  EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil))
                == "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=28,29,30,31;BYSETPOS=-1")
    }

    @Test("item 1: explicit BYMONTHDAY=31 is kept")
    func explicit31() throws {
        let r = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: [NSNumber(value: 31)],
                                 monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        #expect(try savedRuleText(start: ny("2026-10-31 12:00"), r) == "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=31")
    }

    @Test("item 2: plain yearly from February 29 reads back as BYMONTHDAY=28,29;BYSETPOS=-1")
    func feb29() throws {
        #expect(try savedRuleText(start: ny("2028-02-29 09:00"),
                                  EKRecurrenceRule(recurrenceWith: .yearly, interval: 1,
                                                   end: EKRecurrenceEnd(occurrenceCount: 3)))
                == "FREQ=YEARLY;INTERVAL=1;COUNT=3;BYMONTHDAY=28,29;BYSETPOS=-1")
    }

    @Test("item 3: other rules read back unchanged, including COUNT")
    func unchanged() throws {
        #expect(try savedRuleText(start: ny("2026-10-15 12:00"),
                                  EKRecurrenceRule(recurrenceWith: .monthly, interval: 1,
                                                   end: EKRecurrenceEnd(occurrenceCount: 4)))
                == "FREQ=MONTHLY;INTERVAL=1;COUNT=4")
    }
}

@Suite("Expander (RFC 5545) unit checks")
struct ExpanderUnitTests {
    @Test("ISO week starts (WKST=MO)")
    func isoWeeks() {
        let weeks = Expander.weekStarts(2028, wkst: 2)
        #expect(LocalDateTime(dayNumber: weeks[0], hour: 0, minute: 0, second: 0).description == "20280103T000000")
        #expect(weeks.count == 52)
        #expect(Expander.weekStarts(2026, wkst: 2).count == 53)
    }

    @Test("civil calendar round trip and weekday")
    func civil() {
        for d in stride(from: -800_000, through: 800_000, by: 997) {
            let c = Civil.civil(d)
            #expect(Civil.dayNumber(c.year, c.month, c.day) == d)
        }
        #expect(Civil.weekday(Civil.dayNumber(2026, 10, 26)) == 2) // Monday
    }

    @Test("DST: wall-clock gap moves forward, overlap takes the earlier instant")
    func dst() {
        let gap = LocalDateTime(year: 2027, month: 3, day: 14, hour: 2, minute: 30).date(in: newYork)
        #expect(utcText(gap) == "2027-03-14 07:30")
        let overlap = LocalDateTime(year: 2026, month: 11, day: 1, hour: 1, minute: 30).date(in: newYork)
        #expect(utcText(overlap) == "2026-11-01 05:30")
    }
}
