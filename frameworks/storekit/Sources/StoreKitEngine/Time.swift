// The store's clock and the subscription time rates (testing-session.md §2.1, §3).
import Foundation
import StoreKitConfiguration

/// Milliseconds since 1970: the unit of every date in the store and its payloads (formats.md §2.2).
public typealias StoreMilliseconds = Int64

extension Date {
    /// Milliseconds since 1970, rounded to the nearest millisecond.
    public var storeMilliseconds: StoreMilliseconds { StoreMilliseconds((timeIntervalSince1970 * 1000).rounded()) }

    public init(storeMilliseconds ms: StoreMilliseconds) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}

/// The source of "now" for the store. Tests inject a `ManualClock`.
public protocol StoreClock: Sendable {
    func now() -> Date
}

/// The wall clock.
public struct SystemClock: StoreClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A clock that moves only when told to.
public final class ManualClock: StoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) { current = start }

    public func now() -> Date { lock.withLock { current } }

    public func set(_ date: Date) { lock.withLock { current = date } }

    public func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    public func advance(milliseconds: StoreMilliseconds) {
        lock.withLock { current = Date(storeMilliseconds: current.storeMilliseconds + milliseconds) }
    }
}

/// `SKTestSession.TimeRate` raw values (testing-session.md §2.1).
public enum TimeRate: Int, Codable, Sendable, CaseIterable {
    case realTime = 0
    // Deprecated "x is one day" rates (iOS 14.0–15.2).
    case oneHourIsOneDay = 1
    case thirtyMinutesIsOneDay = 2
    case fiveMinutesIsOneDay = 3
    case oneMinuteIsOneDay = 4
    case thirtySecondsIsOneDay = 5
    case oneSecondIsOneDay = 6
    // A one-month period lasts the named time; other periods scale proportionally.
    case monthlyRenewalEveryHour = 10
    case monthlyRenewalEveryThirtyMinutes = 11
    case monthlyRenewalEveryFifteenMinutes = 12
    case monthlyRenewalEveryFiveMinutes = 13
    case monthlyRenewalEveryThirtySeconds = 15
    // Every period (week, month, year, offer periods) lasts the named time.
    case oneRenewalEveryFifteenMinutes = 1000
    case oneRenewalEveryFiveMinutes = 1001
    case oneRenewalEveryMinute = 1002
    case oneRenewalEveryThirtySeconds = 1003
    case oneRenewalEveryTenSeconds = 1004
    case oneRenewalEveryTwoSeconds = 1005

    /// For the 1000 series: the fixed length of every period.
    var fixedPeriodMilliseconds: StoreMilliseconds? {
        switch self {
        case .oneRenewalEveryFifteenMinutes: return 900_000
        case .oneRenewalEveryFiveMinutes: return 300_000
        case .oneRenewalEveryMinute: return 60_000
        case .oneRenewalEveryThirtySeconds: return 30_000
        case .oneRenewalEveryTenSeconds: return 10_000
        case .oneRenewalEveryTwoSeconds: return 2_000
        default: return nil
        }
    }

    /// For the 10 series: the length of a one-month period.
    var monthMilliseconds: StoreMilliseconds? {
        switch self {
        case .monthlyRenewalEveryHour: return 3_600_000
        case .monthlyRenewalEveryThirtyMinutes: return 1_800_000
        case .monthlyRenewalEveryFifteenMinutes: return 900_000
        case .monthlyRenewalEveryFiveMinutes: return 300_000
        case .monthlyRenewalEveryThirtySeconds: return 30_000
        default: return nil
        }
    }

    /// For the deprecated series: the length of one day.
    var dayMilliseconds: StoreMilliseconds? {
        switch self {
        case .oneHourIsOneDay: return 3_600_000
        case .thirtyMinutesIsOneDay: return 1_800_000
        case .fiveMinutesIsOneDay: return 300_000
        case .oneMinuteIsOneDay: return 60_000
        case .thirtySecondsIsOneDay: return 30_000
        case .oneSecondIsOneDay: return 1_000
        default: return nil
        }
    }

    /// The end of `count` periods of `duration` starting at `start`.
    ///
    /// - Real time: calendar arithmetic in the device time zone (a month
    ///   across the end of daylight saving time is 31 days plus one hour).
    /// - 1000 series: every period lasts the named time.
    /// - 10 series: one month lasts the named time; a year is 12 months, a
    ///   week 7/30 of a month, a day 1/30 (README spec question 4).
    /// - Deprecated series: one day lasts the named time; a week is 7 days, a
    ///   month 30, a year 365.
    public func end(of duration: SubscriptionDuration, count: Int = 1, from start: StoreMilliseconds, calendar: Calendar)
        -> StoreMilliseconds
    {
        let n = max(1, count)
        if let fixed = fixedPeriodMilliseconds { return start + fixed * StoreMilliseconds(n) }
        if let month = monthMilliseconds {
            let v = StoreMilliseconds(duration.value * n)
            switch duration.unit {
            case .year: return start + month * 12 * v
            case .month: return start + month * v
            case .week: return start + month * 7 * v / 30
            case .day: return start + month * v / 30
            }
        }
        if let day = dayMilliseconds {
            let v = StoreMilliseconds(duration.value * n)
            switch duration.unit {
            case .year: return start + day * 365 * v
            case .month: return start + day * 30 * v
            case .week: return start + day * 7 * v
            case .day: return start + day * v
            }
        }
        let component: Calendar.Component
        var value = duration.value * n
        switch duration.unit {
        case .day: component = .day
        case .week: component = .day; value *= 7
        case .month: component = .month
        case .year: component = .year
        }
        let date = calendar.date(byAdding: component, value: value, to: Date(storeMilliseconds: start))!
        return max(start + 1, date.storeMilliseconds)
    }
}
