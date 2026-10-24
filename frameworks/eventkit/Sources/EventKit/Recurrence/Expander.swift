// Ycode's RFC 5545 RRULE expander (written from the RFC, recurrence.md §5).
//
// The engine works on wall-clock values (LocalDateTime) and converts to
// instants only to test UNTIL and for the caller's window. Every rule is
// expanded period by period (day, week, month or year, stepped by INTERVAL);
// inside a period the BY parts expand or limit the candidate days as RFC 5545
// §3.3.10 tabulates, BYSETPOS selects from the sorted set, and the series
// start always counts as the first occurrence.

import Foundation

struct WeekdayNum: Hashable {
    var weekday: Int   // 1 = Sunday … 7 = Saturday
    var ordinal: Int   // 0 = every; ±n = n-th from start / end of the period
}

struct RuleSpec: Hashable {
    var frequency: EKRecurrenceFrequency
    var interval: Int = 1
    var count: Int? = nil
    var until: Date? = nil
    var byDay: [WeekdayNum] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var byWeekNo: [Int] = []
    var byYearDay: [Int] = []
    var bySetPos: [Int] = []
    var weekStart: Int = 2 // Monday

    var hasByParts: Bool {
        !(byDay.isEmpty && byMonthDay.isEmpty && byMonth.isEmpty && byWeekNo.isEmpty
          && byYearDay.isEmpty && bySetPos.isEmpty)
    }
}

enum Expander {
    /// Occurrence start times of one rule, ascending, starting with `start`,
    /// honouring COUNT and UNTIL, and stopping after `limit`.
    /// `zone` converts wall-clock values to instants for the UNTIL test.
    static func expand(_ rule: RuleSpec, start: LocalDateTime, zone: TimeZone,
                       through limit: LocalDateTime) -> [LocalDateTime] {
        if let until = rule.until, start.date(in: zone) > until { return [] } // §5 item 5
        var out: [LocalDateTime] = [start]
        if let c = rule.count, c <= 1 { return out }
        if start > limit { return out }
        let interval = max(rule.interval, 1)
        let startDay = start.dayNumber
        let limitDay = limit.dayNumber
        var period = 0
        let maxPeriods = 400_000
        while period < maxPeriods {
            defer { period += 1 }
            guard let (firstDay, days) = candidates(rule, start: start, period: period * interval) else { break }
            if firstDay > limitDay { break }
            var set = days.sorted()
            if !rule.bySetPos.isEmpty { set = select(set, rule.bySetPos) }
            for day in set where day >= startDay {
                let occ = LocalDateTime(dayNumber: day, hour: start.hour, minute: start.minute, second: start.second)
                if occ <= start { continue }
                if occ > limit { return out }
                if let until = rule.until, occ.date(in: zone) > until { return out }
                out.append(occ)
                if let c = rule.count, out.count >= c { return out }
            }
        }
        return out
    }

    /// Union of several rules (§5 item 6), duplicates removed, ascending.
    static func expand(_ rules: [RuleSpec], start: LocalDateTime, zone: TimeZone,
                       through limit: LocalDateTime) -> [LocalDateTime] {
        if rules.count == 1 { return expand(rules[0], start: start, zone: zone, through: limit) }
        var all = Set<LocalDateTime>()
        for r in rules { all.formUnion(expand(r, start: start, zone: zone, through: limit)) }
        return all.sorted()
    }

    // MARK: - Periods

    /// The candidate days (day numbers, unsorted, unique) of period `index`
    /// (already multiplied by INTERVAL), plus the first day of the period.
    private static func candidates(_ r: RuleSpec, start: LocalDateTime, period index: Int) -> (Int, [Int])? {
        switch r.frequency {
        case .daily:
            let day = start.dayNumber + index
            return (day, matchesLimits(day, r, monthDay: true, yearDay: true, weekday: true, month: true) ? [day] : [])
        case .weekly:
            let wkst = r.weekStart
            let d0 = start.dayNumber
            let weekBegin = d0 - ((Civil.weekday(d0) - wkst + 7) % 7) + 7 * index
            var days: [Int] = []
            let weekdays = r.byDay.isEmpty ? [start.weekday] : r.byDay.map(\.weekday)
            for off in 0..<7 {
                let d = weekBegin + off
                if weekdays.contains(Civil.weekday(d)),
                   matchesLimits(d, r, monthDay: false, yearDay: false, weekday: false, month: true) {
                    days.append(d)
                }
            }
            return (weekBegin, days)
        case .monthly:
            let monthIndex = start.year * 12 + (start.month - 1) + index
            let y = monthIndex >= 0 ? monthIndex / 12 : (monthIndex - 11) / 12
            let m = monthIndex - y * 12 + 1
            let first = Civil.dayNumber(y, m, 1)
            if !r.byMonth.isEmpty && !r.byMonth.contains(m) { return (first, []) }
            return (first, monthDays(r, y, m, defaultDay: start.day))
        case .yearly:
            let y = start.year + index
            let first = Civil.dayNumber(y, 1, 1)
            return (first, yearDays(r, y, start: start))
        }
    }

    /// Days of month (y, m) for a monthly rule, or for one month of a yearly
    /// rule with BYMONTH. BYMONTHDAY expands; BYDAY expands (ordinals count
    /// within the month) or limits when BYMONTHDAY is present.
    private static func monthDays(_ r: RuleSpec, _ y: Int, _ m: Int, defaultDay: Int) -> [Int] {
        let first = Civil.dayNumber(y, m, 1)
        let len = Civil.daysInMonth(y, m)
        var days: [Int] = []
        if !r.byMonthDay.isEmpty {
            for md in r.byMonthDay {
                guard let dom = resolve(md, length: len) else { continue }
                let d = first + dom - 1
                if !r.byDay.isEmpty && !r.byDay.contains(where: { $0.weekday == Civil.weekday(d) }) { continue }
                days.append(d)
            }
        } else if !r.byDay.isEmpty {
            days = expandWeekdays(r.byDay, from: first, length: len)
        } else {
            if defaultDay <= len { days = [first + defaultDay - 1] }
        }
        if !r.byYearDay.isEmpty {
            days = days.filter { matchesYearDay($0, r.byYearDay) }
        }
        return unique(days)
    }

    private static func yearDays(_ r: RuleSpec, _ y: Int, start: LocalDateTime) -> [Int] {
        let first = Civil.dayNumber(y, 1, 1)
        let len = Civil.daysInYear(y)
        var days: [Int] = []
        if !r.byWeekNo.isEmpty {
            let weeks = weekStarts(y, wkst: r.weekStart)
            let weekdays = r.byDay.isEmpty ? [start.weekday] : r.byDay.map(\.weekday)
            for wn in r.byWeekNo {
                let idx: Int
                if wn > 0 { idx = wn - 1 } else if wn < 0 { idx = weeks.count + wn } else { continue }
                guard idx >= 0, idx < weeks.count else { continue }
                for off in 0..<7 {
                    let d = weeks[idx] + off
                    guard d >= first, d < first + len else { continue }
                    if weekdays.contains(Civil.weekday(d)) { days.append(d) }
                }
            }
            days = days.filter { matchesLimits($0, r, monthDay: true, yearDay: true, weekday: false, month: true) }
        } else if !r.byYearDay.isEmpty {
            for yd in r.byYearDay {
                guard let n = resolve(yd, length: len) else { continue }
                days.append(first + n - 1)
            }
            days = days.filter { matchesLimits($0, r, monthDay: true, yearDay: false, weekday: true, month: true) }
        } else if !r.byMonth.isEmpty {
            for m in r.byMonth.sorted() where (1...12).contains(m) {
                days += monthDays(r, y, m, defaultDay: start.day)
            }
        } else if !r.byMonthDay.isEmpty {
            // EventKit reads a yearly rule whose only day part is BYMONTHDAY
            // in the month of the series start (recurrence.md §4 item 2).
            days = monthDays(r, y, start.month, defaultDay: start.day)
        } else if !r.byDay.isEmpty {
            days = expandWeekdays(r.byDay, from: first, length: len)
        } else {
            if start.day <= Civil.daysInMonth(y, start.month) {
                days = [Civil.dayNumber(y, start.month, start.day)]
            }
        }
        return unique(days)
    }

    // MARK: - Helpers

    /// Starts (day numbers) of the weeks of year `y` numbered per RFC 5545:
    /// week 1 is the first week (starting on `wkst`) with at least four days
    /// in the year, i.e. the week that contains January 4.
    static func weekStarts(_ y: Int, wkst: Int) -> [Int] {
        func week1(_ year: Int) -> Int {
            let jan4 = Civil.dayNumber(year, 1, 4)
            return jan4 - ((Civil.weekday(jan4) - wkst + 7) % 7)
        }
        let a = week1(y), b = week1(y + 1)
        return stride(from: a, to: b, by: 7).map { $0 }
    }

    private static func expandWeekdays(_ list: [WeekdayNum], from first: Int, length: Int) -> [Int] {
        var days: [Int] = []
        for wd in list {
            let firstMatch = first + ((wd.weekday - Civil.weekday(first) + 7) % 7)
            var all: [Int] = []
            var d = firstMatch
            while d < first + length { all.append(d); d += 7 }
            if wd.ordinal == 0 {
                days += all
            } else if wd.ordinal > 0 {
                if wd.ordinal <= all.count { days.append(all[wd.ordinal - 1]) }
            } else {
                if -wd.ordinal <= all.count { days.append(all[all.count + wd.ordinal]) }
            }
        }
        return days
    }

    private static func resolve(_ n: Int, length: Int) -> Int? {
        if n > 0 && n <= length { return n }
        if n < 0 && -n <= length { return length + n + 1 }
        return nil
    }

    private static func matchesYearDay(_ day: Int, _ list: [Int]) -> Bool {
        let c = Civil.civil(day)
        let n = day - Civil.dayNumber(c.year, 1, 1) + 1
        let len = Civil.daysInYear(c.year)
        return list.contains { resolve($0, length: len) == n }
    }

    private static func matchesLimits(_ day: Int, _ r: RuleSpec, monthDay: Bool, yearDay: Bool,
                                      weekday: Bool, month: Bool) -> Bool {
        let c = Civil.civil(day)
        if month && !r.byMonth.isEmpty && !r.byMonth.contains(c.month) { return false }
        if monthDay && !r.byMonthDay.isEmpty {
            let len = Civil.daysInMonth(c.year, c.month)
            if !r.byMonthDay.contains(where: { resolve($0, length: len) == c.day }) { return false }
        }
        if yearDay && !r.byYearDay.isEmpty && !matchesYearDay(day, r.byYearDay) { return false }
        if weekday && !r.byDay.isEmpty && !r.byDay.contains(where: { $0.weekday == Civil.weekday(day) }) { return false }
        return true
    }

    private static func select(_ sorted: [Int], _ positions: [Int]) -> [Int] {
        var picked = Set<Int>()
        for p in positions {
            if p > 0 && p <= sorted.count { picked.insert(sorted[p - 1]) }
            if p < 0 && -p <= sorted.count { picked.insert(sorted[sorted.count + p]) }
        }
        return picked.sorted()
    }

    private static func unique(_ days: [Int]) -> [Int] { Array(Set(days)) }
}
