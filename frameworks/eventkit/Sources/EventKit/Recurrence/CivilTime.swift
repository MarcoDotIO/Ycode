// Wall-clock (civil) date arithmetic in the proleptic Gregorian calendar,
// independent of Foundation's Calendar so that the recurrence engine is
// deterministic and fast. Day numbers count days from 1970-01-01.

import Foundation

enum Civil {
    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeap(y) ? 29 : 28
        }
    }

    static func daysInYear(_ y: Int) -> Int { isLeap(y) ? 366 : 365 }

    /// Days since 1970-01-01 for a civil date (algorithm from the public
    /// "days from civil" derivation; valid for all years).
    static func dayNumber(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Weekday of a day number: 1 = Sunday … 7 = Saturday (EKWeekday raw values).
    static func weekday(_ day: Int) -> Int {
        // 1970-01-01 was a Thursday (5).
        let r = (day + 4) % 7
        return (r < 0 ? r + 7 : r) + 1
    }
}

/// A wall-clock date and time without a zone.
struct LocalDateTime: Hashable, Comparable, CustomStringConvertible {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int

    init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute; self.second = second
    }

    init(dayNumber: Int, hour: Int, minute: Int, second: Int) {
        let c = Civil.civil(dayNumber)
        self.init(year: c.year, month: c.month, day: c.day, hour: hour, minute: minute, second: second)
    }

    init(naiveSeconds s: Int64) {
        var days = s / 86400
        var rem = s % 86400
        if rem < 0 { rem += 86400; days -= 1 }
        self.init(dayNumber: Int(days), hour: Int(rem / 3600), minute: Int(rem % 3600 / 60), second: Int(rem % 60))
    }

    /// The wall-clock reading of `date` in `zone` (fractions of a second dropped).
    init(date: Date, zone: TimeZone) {
        let t = date.timeIntervalSince1970.rounded(.down)
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: t))
        self.init(naiveSeconds: Int64(t) + Int64(offset))
    }

    var dayNumber: Int { Civil.dayNumber(year, month, day) }
    var weekday: Int { Civil.weekday(dayNumber) }
    var secondsOfDay: Int { hour * 3600 + minute * 60 + second }
    var naiveSeconds: Int64 { Int64(dayNumber) * 86400 + Int64(secondsOfDay) }

    func addingDays(_ n: Int) -> LocalDateTime {
        LocalDateTime(dayNumber: dayNumber + n, hour: hour, minute: minute, second: second)
    }

    func addingSeconds(_ n: Int64) -> LocalDateTime { LocalDateTime(naiveSeconds: naiveSeconds + n) }

    var startOfDay: LocalDateTime { LocalDateTime(year: year, month: month, day: day) }

    /// The instant at which `zone` shows this wall-clock time. In a
    /// daylight-saving overlap the earlier instant is used; in a gap the time
    /// is read with the offset in force before the transition (so it moves
    /// forward by the size of the gap).
    func date(in zone: TimeZone) -> Date {
        let naive = naiveSeconds
        func local(_ t: Int64) -> Int64 {
            t + Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))))
        }
        var candidates: [Int64] = []
        let guess = naive - Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(naive))))
        for probe in [guess - 10800, guess, guess + 10800] {
            let off = Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(probe))))
            let t = naive - off
            if local(t) == naive, !candidates.contains(t) { candidates.append(t) }
        }
        if let earliest = candidates.min() {
            return Date(timeIntervalSince1970: TimeInterval(earliest))
        }
        let before = Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(guess - 10800))))
        return Date(timeIntervalSince1970: TimeInterval(naive - before))
    }

    static func < (a: LocalDateTime, b: LocalDateTime) -> Bool { a.naiveSeconds < b.naiveSeconds }

    /// `YYYYMMDDTHHMMSS` (RFC 5545 local DATE-TIME form).
    var description: String {
        String(format: "%04d%02d%02dT%02d%02d%02d", year, month, day, hour, minute, second)
    }

    init?(text: String) {
        let s = Array(text.utf8)
        guard s.count == 15, s[8] == UInt8(ascii: "T") else { return nil }
        func num(_ r: Range<Int>) -> Int? { Int(String(decoding: s[r], as: UTF8.self)) }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8),
              let h = num(9..<11), let mi = num(11..<13), let se = num(13..<15) else { return nil }
        self.init(year: y, month: mo, day: d, hour: h, minute: mi, second: se)
    }
}

extension TimeZone {
    static let utc = TimeZone(identifier: "UTC")!
}

/// RFC 5545 UTC DATE-TIME text (`YYYYMMDDTHHMMSSZ`, second precision).
func utcStamp(_ date: Date) -> String {
    LocalDateTime(date: date, zone: .utc).description + "Z"
}

func parseUTCStamp(_ text: String) -> Date? {
    guard text.hasSuffix("Z"), let l = LocalDateTime(text: String(text.dropLast())) else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(l.naiveSeconds))
}
