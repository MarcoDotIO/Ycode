// C-EK-REC: rule model, validation and text form (recurrence.md §1–§3).

import Foundation
import Testing
@testable import EventKit

@Suite("recurrence.md §2–§3: rules, validation, text form")
struct RecurrenceRuleTests {
    func stderrText(_ r: ExitTest.Result?) -> String {
        String(decoding: r?.standardErrorContent ?? [], as: UTF8.self)
    }

    func text(_ r: EKRecurrenceRule) -> String {
        let d = r.description
        #expect(d.hasPrefix("EKRecurrenceRule <0x"))
        return String(d[d.range(of: "RRULE ")!.upperBound...])
    }

    func days(_ d: [EKWeekday], week: Int = 0) -> [EKRecurrenceDayOfWeek] {
        d.map { EKRecurrenceDayOfWeek($0, weekNumber: week) }
    }

    func n(_ a: [Int]) -> [NSNumber] { a.map { NSNumber(value: $0) } }

    @Test("§3 text forms of the built rules")
    func textForms() {
        typealias R = EKRecurrenceRule
        #expect(text(R(recurrenceWith: .daily, interval: 1, end: nil)) == "FREQ=DAILY;INTERVAL=1")
        #expect(text(R(recurrenceWith: .daily, interval: 2, end: EKRecurrenceEnd(occurrenceCount: 5)))
                == "FREQ=DAILY;INTERVAL=2;COUNT=5")
        #expect(text(R(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(end: date("2026-12-31 23:59"))))
                == "FREQ=WEEKLY;INTERVAL=1;UNTIL=20261231T235900Z")
        #expect(text(R(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days([.monday, .wednesday, .friday]),
                       daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                       setPositions: nil, end: nil)) == "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR")
        #expect(text(R(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: n([1, 15, -1]),
                       monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
                == "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=1,15,-1")
        #expect(text(R(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: days([.friday], week: -1), daysOfTheMonth: nil,
                       monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
                == "FREQ=MONTHLY;INTERVAL=1;BYDAY=-1FR")
        #expect(text(R(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: days([.tuesday], week: 2), daysOfTheMonth: nil,
                       monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
                == "FREQ=MONTHLY;INTERVAL=1;BYDAY=2TU")
        #expect(text(R(recurrenceWith: .monthly, interval: 1,
                       daysOfTheWeek: days([.monday, .tuesday, .wednesday, .thursday, .friday]), daysOfTheMonth: nil,
                       monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: n([-2]), end: nil))
                == "FREQ=MONTHLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2")
        #expect(text(R(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: nil,
                       monthsOfTheYear: n([3, 9]), weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
                == "FREQ=YEARLY;INTERVAL=1;BYMONTH=3,9")
        #expect(text(R(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: days([.monday]), daysOfTheMonth: nil,
                       monthsOfTheYear: nil, weeksOfTheYear: n([20]), daysOfTheYear: nil, setPositions: nil, end: nil))
                == "FREQ=YEARLY;INTERVAL=1;BYWEEKNO=20;BYDAY=MO")
        #expect(text(R(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: nil,
                       monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: n([100, -1]), setPositions: nil, end: nil))
                == "FREQ=YEARLY;INTERVAL=1;BYYEARDAY=100,-1")
        #expect(text(R(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: days([.thursday], week: 4), daysOfTheMonth: nil,
                       monthsOfTheYear: n([11]), weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
                == "FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYDAY=4TH")
    }

    @Test("§3 weekly interval 2 TU,TH count 6 prints WKST=MO after save")
    func weeklyWKST() throws {
        let t = TestStore()
        let e = makeEvent(t.store, "wkst", start: ny("2026-10-01 11:00"))
        e.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, daysOfTheWeek: days([.tuesday, .thursday]),
                                             daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                             setPositions: nil, end: EKRecurrenceEnd(occurrenceCount: 6)))
        try t.store.save(e, span: .thisEvent)
        let back = try #require(t.another().event(withIdentifier: e.eventIdentifier!))
        #expect(text(back.recurrenceRules![0]) == "FREQ=WEEKLY;INTERVAL=2;COUNT=6;BYDAY=TU,TH;WKST=MO")
    }

    @Test("§1 new rules report firstDayOfTheWeek 2 and the gregorian calendar")
    func defaults() {
        let r = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        #expect(r.firstDayOfTheWeek == 2)
        #expect(r.calendarIdentifier == "gregorian")
        #expect(r.recurrenceEnd == nil)
        #expect(r.daysOfTheWeek == nil)
    }

    @Test("§3 day-of-week and end descriptions")
    func descriptions() {
        let d = EKRecurrenceDayOfWeek(.sunday, weekNumber: -1)
        #expect(d.description.hasPrefix("EKRecurrenceDayOfWeek <0x"))
        #expect(d.description.hasSuffix("> { -1SU }"))
        let end = EKRecurrenceEnd(end: date("2026-12-31 23:59"))
        #expect(end.description.hasSuffix("> { UNTIL=20261231T235900Z }"))
        #expect(end.occurrenceCount == 0)
        #expect(EKRecurrenceEnd(occurrenceCount: 3).endDate == nil)
    }

    @Test("§2 odd inputs are accepted and kept in the text form")
    func acceptedOddInputs() {
        let w60 = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: days([.sunday], week: 60),
                                   daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                   setPositions: nil, end: nil)
        #expect(text(w60).contains("BYDAY=60SU"))
        let dailyByDay = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, daysOfTheWeek: days([.monday]),
                                          daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                          setPositions: nil, end: nil)
        #expect(text(dailyByDay) == "FREQ=DAILY;INTERVAL=1;BYDAY=MO")
        let weeklyMonthDay = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: nil,
                                              daysOfTheMonth: n([32]), monthsOfTheYear: n([13]), weeksOfTheYear: nil,
                                              daysOfTheYear: nil, setPositions: n([0]), end: nil)
        #expect(text(weeklyMonthDay) == "FREQ=WEEKLY;INTERVAL=1;BYMONTH=13;BYMONTHDAY=32;BYSETPOS=0")
        let monthlyWeekNo = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: nil,
                                             monthsOfTheYear: nil, weeksOfTheYear: n([3]), daysOfTheYear: nil,
                                             setPositions: nil, end: nil)
        #expect(text(monthlyWeekNo) == "FREQ=MONTHLY;INTERVAL=1;BYWEEKNO=3")
        let weekly2MO = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days([.monday], week: 2),
                                         daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
                                         setPositions: nil, end: nil)
        #expect(text(weekly2MO) == "FREQ=WEEKLY;INTERVAL=1;BYDAY=2MO")
    }

    @Test("§2 interval 0 raises \"Interval must be greater than 0\"")
    func intervalZero() async {
        let r = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = EKRecurrenceRule(recurrenceWith: .daily, interval: 0, end: nil)
        }
        let err = stderrText(r)
        #expect(err.contains("Interval must be greater than 0"))
    }

    @Test("§2 negative interval raises the same exception")
    func intervalNegative() async {
        let r = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = EKRecurrenceRule(recurrenceWith: .weekly, interval: -3, end: nil)
        }
        let err = stderrText(r)
        #expect(err.contains("Interval must be greater than 0"))
    }

    @Test("§2 occurrence count 0 raises \"occurrenceCount == 0\"")
    func countZero() async {
        let r = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = EKRecurrenceEnd(occurrenceCount: 0)
        }
        let err = stderrText(r)
        #expect(err.contains("occurrenceCount == 0"))
    }

    @Test("§2 weekday 9 raises \"Invalid day number\"")
    func invalidDay() async {
        let r = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = EKRecurrenceDayOfWeek.make(rawDay: 9, weekNumber: 0)
        }
        let err = stderrText(r)
        #expect(err.contains("Invalid day number"))
    }

    @Test("RRULE text round-trips through the parser")
    func roundTrip() {
        for s in ["FREQ=DAILY;INTERVAL=2;COUNT=5", "FREQ=WEEKLY;INTERVAL=1;UNTIL=20261231T235900Z",
                  "FREQ=MONTHLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2",
                  "FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYDAY=4TH",
                  "FREQ=WEEKLY;INTERVAL=2;COUNT=6;BYDAY=TU,TH;WKST=MO",
                  "FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=28,29,30,31;BYSETPOS=-1"] {
            #expect(RRuleText.format(RRuleText.parse(s)!) == s)
        }
    }
}
