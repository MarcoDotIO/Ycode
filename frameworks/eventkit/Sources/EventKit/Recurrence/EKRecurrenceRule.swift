// EKRecurrenceRule, EKRecurrenceEnd, EKRecurrenceDayOfWeek (recurrence.md §1–§3).

import Foundation

/// Raises the equivalent of Apple's NSInvalidArgumentException: Swift cannot
/// throw Objective-C exceptions portably, so the process stops with the same
/// reason text (recurrence.md §2, errors.md §3).
func invalidArgument(_ reason: String) -> Never {
    fatalError("NSInvalidArgumentException: \(reason)")
}

public class EKRecurrenceDayOfWeek: NSObject, NSCopying {
    public let dayOfTheWeek: EKWeekday
    public let weekNumber: Int

    public init(dayOfTheWeek: EKWeekday, weekNumber: Int) {
        self.dayOfTheWeek = dayOfTheWeek
        self.weekNumber = weekNumber
    }

    public convenience init(_ dayOfTheWeek: EKWeekday) {
        self.init(dayOfTheWeek: dayOfTheWeek, weekNumber: 0)
    }

    public convenience init(_ dayOfTheWeek: EKWeekday, weekNumber: Int) {
        self.init(dayOfTheWeek: dayOfTheWeek, weekNumber: weekNumber)
    }

    /// Entry point for raw day numbers (text parsing, bridged callers):
    /// outside 1…7 raises "Invalid day number". Week numbers are not checked.
    static func make(rawDay: Int, weekNumber: Int) -> EKRecurrenceDayOfWeek {
        guard let day = EKWeekday(rawValue: rawDay) else { invalidArgument("Invalid day number") }
        return EKRecurrenceDayOfWeek(dayOfTheWeek: day, weekNumber: weekNumber)
    }

    public func copy(with zone: NSZone? = nil) -> Any { self }

    var token: String {
        (weekNumber != 0 ? String(weekNumber) : "") + RRuleText.dayCode(dayOfTheWeek.rawValue)
    }

    public override var description: String { "EKRecurrenceDayOfWeek <\(addr)> { \(token) }" }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EKRecurrenceDayOfWeek else { return false }
        return o.dayOfTheWeek == dayOfTheWeek && o.weekNumber == weekNumber
    }

    public override var hash: Int { dayOfTheWeek.rawValue &* 131 &+ weekNumber }

    private var addr: String { "0x" + String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 16) }
}

public class EKRecurrenceEnd: NSObject, NSCopying {
    public let endDate: Date?
    public let occurrenceCount: Int

    public init(end endDate: Date) {
        self.endDate = endDate
        self.occurrenceCount = 0
    }

    public init(occurrenceCount: Int) {
        if occurrenceCount == 0 { invalidArgument("occurrenceCount == 0") }
        self.endDate = nil
        self.occurrenceCount = occurrenceCount
    }

    public func copy(with zone: NSZone? = nil) -> Any { self }

    var token: String {
        if let d = endDate { return "UNTIL=" + utcStamp(d) }
        return "COUNT=\(occurrenceCount)"
    }

    public override var description: String { "EKRecurrenceEnd <\(addr)> { \(token) }" }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EKRecurrenceEnd else { return false }
        return o.endDate == endDate && o.occurrenceCount == occurrenceCount
    }

    public override var hash: Int { occurrenceCount &+ (endDate?.hashValue ?? 0) }

    private var addr: String { "0x" + String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 16) }
}

public class EKRecurrenceRule: EKObject, NSCopying {
    public let frequency: EKRecurrenceFrequency
    public let interval: Int
    /// Reported as 2 (Monday) on new rules (recurrence.md §1).
    public internal(set) var firstDayOfTheWeek: Int
    public let daysOfTheWeek: [EKRecurrenceDayOfWeek]?
    public let daysOfTheMonth: [NSNumber]?
    public let monthsOfTheYear: [NSNumber]?
    public let weeksOfTheYear: [NSNumber]?
    public let daysOfTheYear: [NSNumber]?
    public let setPositions: [NSNumber]?
    public var recurrenceEnd: EKRecurrenceEnd?
    public var calendarIdentifier: String { "gregorian" }

    public convenience init(recurrenceWith type: EKRecurrenceFrequency, interval: Int, end: EKRecurrenceEnd?) {
        self.init(recurrenceWith: type, interval: interval, daysOfTheWeek: nil, daysOfTheMonth: nil,
                  monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }

    public init(recurrenceWith type: EKRecurrenceFrequency, interval: Int,
                daysOfTheWeek: [EKRecurrenceDayOfWeek]?, daysOfTheMonth: [NSNumber]?,
                monthsOfTheYear: [NSNumber]?, weeksOfTheYear: [NSNumber]?,
                daysOfTheYear: [NSNumber]?, setPositions: [NSNumber]?, end: EKRecurrenceEnd?) {
        if interval <= 0 { invalidArgument("Interval must be greater than 0") }
        self.frequency = type
        self.interval = interval
        self.firstDayOfTheWeek = 2
        func clean<T>(_ a: [T]?) -> [T]? { (a?.isEmpty ?? true) ? nil : a }
        self.daysOfTheWeek = clean(daysOfTheWeek)
        self.daysOfTheMonth = clean(daysOfTheMonth)
        self.monthsOfTheYear = clean(monthsOfTheYear)
        self.weeksOfTheYear = clean(weeksOfTheYear)
        self.daysOfTheYear = clean(daysOfTheYear)
        self.setPositions = clean(setPositions)
        self.recurrenceEnd = end
        super.init()
    }

    convenience init(spec s: RuleSpec) {
        func nums(_ a: [Int]) -> [NSNumber]? { a.isEmpty ? nil : a.map { NSNumber(value: $0) } }
        let end: EKRecurrenceEnd? = s.until.map { EKRecurrenceEnd(end: $0) }
            ?? s.count.map { EKRecurrenceEnd(occurrenceCount: $0) }
        self.init(recurrenceWith: s.frequency, interval: s.interval,
                  daysOfTheWeek: s.byDay.isEmpty ? nil : s.byDay.map { EKRecurrenceDayOfWeek.make(rawDay: $0.weekday, weekNumber: $0.ordinal) },
                  daysOfTheMonth: nums(s.byMonthDay), monthsOfTheYear: nums(s.byMonth),
                  weeksOfTheYear: nums(s.byWeekNo), daysOfTheYear: nums(s.byYearDay),
                  setPositions: nums(s.bySetPos), end: end)
        self.firstDayOfTheWeek = s.weekStart
    }

    /// The rule as the engine's value type.
    var spec: RuleSpec {
        func ints(_ a: [NSNumber]?) -> [Int] { (a ?? []).map { $0.intValue } }
        var s = RuleSpec(frequency: frequency)
        s.interval = interval
        if let e = recurrenceEnd {
            if let d = e.endDate { s.until = d } else { s.count = e.occurrenceCount }
        }
        s.byDay = (daysOfTheWeek ?? []).map { WeekdayNum(weekday: $0.dayOfTheWeek.rawValue, ordinal: $0.weekNumber) }
        s.byMonthDay = ints(daysOfTheMonth)
        s.byMonth = ints(monthsOfTheYear)
        s.byWeekNo = ints(weeksOfTheYear)
        s.byYearDay = ints(daysOfTheYear)
        s.bySetPos = ints(setPositions)
        s.weekStart = firstDayOfTheWeek
        return s
    }

    /// The RFC 5545 value in EventKit's part order (recurrence.md §3).
    var rruleText: String { RRuleText.format(spec) }

    public func copy(with zone: NSZone? = nil) -> Any {
        let r = EKRecurrenceRule(spec: spec)
        return r
    }

    public override var description: String { "EKRecurrenceRule <\(objectAddress)> RRULE \(rruleText)" }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EKRecurrenceRule else { return false }
        return o.spec == spec
    }

    public override var hash: Int { spec.hashValue }
}

/// RRULE text form and parsing.
enum RRuleText {
    static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    static func dayCode(_ weekday: Int) -> String { (1...7).contains(weekday) ? codes[weekday - 1] : "??" }

    static func format(_ s: RuleSpec) -> String {
        let freq = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"][s.frequency.rawValue]
        var parts = ["FREQ=\(freq)", "INTERVAL=\(s.interval)"]
        if let c = s.count { parts.append("COUNT=\(c)") }
        if let u = s.until { parts.append("UNTIL=\(utcStamp(u))") }
        func join(_ a: [Int]) -> String { a.map(String.init).joined(separator: ",") }
        // Part order as observed in the golden rows of recurrence.md §3
        // (BYMONTH and BYWEEKNO before BYDAY; BYSETPOS after the day parts).
        if !s.byMonth.isEmpty { parts.append("BYMONTH=" + join(s.byMonth)) }
        if !s.byWeekNo.isEmpty { parts.append("BYWEEKNO=" + join(s.byWeekNo)) }
        if !s.byYearDay.isEmpty { parts.append("BYYEARDAY=" + join(s.byYearDay)) }
        if !s.byMonthDay.isEmpty { parts.append("BYMONTHDAY=" + join(s.byMonthDay)) }
        if !s.byDay.isEmpty {
            parts.append("BYDAY=" + s.byDay.map { ($0.ordinal != 0 ? String($0.ordinal) : "") + dayCode($0.weekday) }
                .joined(separator: ","))
        }
        if !s.bySetPos.isEmpty { parts.append("BYSETPOS=" + join(s.bySetPos)) }
        // WKST is printed for weekly rules with an interval above 1 (§3).
        if s.frequency == .weekly && s.interval > 1 { parts.append("WKST=" + dayCode(s.weekStart)) }
        return parts.joined(separator: ";")
    }

    static func parse(_ text: String) -> RuleSpec? {
        var spec: RuleSpec?
        var fields: [String: String] = [:]
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            fields[kv[0].uppercased()] = kv[1]
        }
        switch fields["FREQ"] {
        case "DAILY": spec = RuleSpec(frequency: .daily)
        case "WEEKLY": spec = RuleSpec(frequency: .weekly)
        case "MONTHLY": spec = RuleSpec(frequency: .monthly)
        case "YEARLY": spec = RuleSpec(frequency: .yearly)
        default: return nil
        }
        guard var s = spec else { return nil }
        func ints(_ k: String) -> [Int] { (fields[k] ?? "").split(separator: ",").compactMap { Int($0) } }
        s.interval = Int(fields["INTERVAL"] ?? "1") ?? 1
        if let c = fields["COUNT"] { s.count = Int(c) }
        if let u = fields["UNTIL"] { s.until = parseUTCStamp(u) }
        s.byDay = (fields["BYDAY"] ?? "").split(separator: ",").compactMap { tok -> WeekdayNum? in
            let t = String(tok)
            guard t.count >= 2, let idx = codes.firstIndex(of: String(t.suffix(2))) else { return nil }
            let n = t.dropLast(2)
            return WeekdayNum(weekday: idx + 1, ordinal: n.isEmpty ? 0 : (Int(n) ?? 0))
        }
        s.byMonthDay = ints("BYMONTHDAY")
        s.byMonth = ints("BYMONTH")
        s.byWeekNo = ints("BYWEEKNO")
        s.byYearDay = ints("BYYEARDAY")
        s.bySetPos = ints("BYSETPOS")
        if let w = fields["WKST"], let idx = codes.firstIndex(of: w) { s.weekStart = idx + 1 }
        return s
    }
}
