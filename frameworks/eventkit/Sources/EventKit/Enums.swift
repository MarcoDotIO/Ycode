// Enumerations and string constants of EventKit (specs/frameworks/eventkit/identifiers.md).
// Case names follow the Swift spelling of the interop names; raw values are the spec's.

import Foundation

public enum EKEntityType: UInt, Sendable {
    case event = 0
    case reminder = 1
}

public struct EKEntityMask: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let event = EKEntityMask(rawValue: 1)
    public static let reminder = EKEntityMask(rawValue: 2)
}

public enum EKAuthorizationStatus: Int, Sendable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case fullAccess = 3
    case writeOnly = 4

    /// Deprecated alias of `fullAccess` (same raw value 3).
    @available(*, deprecated, renamed: "fullAccess")
    public static var authorized: EKAuthorizationStatus { .fullAccess }
}

public struct EKCalendarEventAvailabilityMask: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let none: EKCalendarEventAvailabilityMask = []
    public static let busy = EKCalendarEventAvailabilityMask(rawValue: 1)
    public static let free = EKCalendarEventAvailabilityMask(rawValue: 2)
    public static let tentative = EKCalendarEventAvailabilityMask(rawValue: 4)
    public static let unavailable = EKCalendarEventAvailabilityMask(rawValue: 8)
}

public enum EKCalendarType: Int, Sendable {
    case local = 0
    case calDAV = 1
    case exchange = 2
    case subscription = 3
    case birthday = 4
}

public enum EKSourceType: Int, Sendable {
    case local = 0
    case exchange = 1
    case calDAV = 2
    case mobileMe = 3
    case subscribed = 4
    case birthdays = 5
}

public enum EKSpan: Int, Sendable {
    case thisEvent = 0
    case futureEvents = 1
}

public enum EKRecurrenceFrequency: Int, Sendable {
    case daily = 0
    case weekly = 1
    case monthly = 2
    case yearly = 3
}

public enum EKWeekday: Int, Sendable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
}

@available(*, deprecated, renamed: "EKWeekday.sunday") public let EKSunday = EKWeekday.sunday
@available(*, deprecated, renamed: "EKWeekday.monday") public let EKMonday = EKWeekday.monday
@available(*, deprecated, renamed: "EKWeekday.tuesday") public let EKTuesday = EKWeekday.tuesday
@available(*, deprecated, renamed: "EKWeekday.wednesday") public let EKWednesday = EKWeekday.wednesday
@available(*, deprecated, renamed: "EKWeekday.thursday") public let EKThursday = EKWeekday.thursday
@available(*, deprecated, renamed: "EKWeekday.friday") public let EKFriday = EKWeekday.friday
@available(*, deprecated, renamed: "EKWeekday.saturday") public let EKSaturday = EKWeekday.saturday

public enum EKEventAvailability: Int, Sendable {
    case notSupported = -1
    case busy = 0
    case free = 1
    case tentative = 2
    case unavailable = 3
}

public enum EKEventStatus: Int, Sendable {
    case none = 0
    case confirmed = 1
    case tentative = 2
    case canceled = 3
}

public enum EKAlarmProximity: Int, Sendable {
    case none = 0
    case enter = 1
    case leave = 2
}

public enum EKAlarmType: Int, Sendable {
    case display = 0
    case audio = 1
    case procedure = 2
    case email = 3
}

public enum EKParticipantRole: Int, Sendable {
    case unknown = 0
    case required = 1
    case optional = 2
    case chair = 3
    case nonParticipant = 4
}

public enum EKParticipantScheduleStatus: Int, Sendable {
    case none = 0
    case pending = 1
    case sent = 2
    case delivered = 3
    case recipientNotRecognized = 4
    case noPrivileges = 5
    case deliveryFailed = 6
    case cannotDeliver = 7
    case recipientNotAllowed = 8
}

public enum EKParticipantStatus: Int, Sendable {
    case unknown = 0
    case pending = 1
    case accepted = 2
    case declined = 3
    case tentative = 4
    case delegated = 5
    case completed = 6
    case inProcess = 7
}

public enum EKParticipantType: Int, Sendable {
    case unknown = 0
    case person = 1
    case room = 2
    case resource = 3
    case group = 4
}

public enum EKReminderPriority: UInt, Sendable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9
}

/// `EKErrorDomain` (identifiers.md, string constants).
public let EKErrorDomain = "EKErrorDomain"

extension Notification.Name {
    /// `EKEventStoreChangedNotification`; the string value equals the name
    /// (identifiers.md). Posted on the main queue with the store as object.
    public static let EKEventStoreChanged = Notification.Name("EKEventStoreChangedNotification")
}

/// User-info keys of the change notification (interface.md §5). They are
/// observations, not SDK declarations; Ycode fills them with its own values.
enum ChangeKeys {
    static let changeType = "EKEventStoreChangeTypeUserInfoKey"
    static let calendarDataChanged = "EKEventStoreCalendarDataChangedUserInfoKey"
    static let remindersDataChanged = "EKEventStoreRemindersDataChangedUserInfoKey"
    static let changedObjectIDs = "EKEventStoreChangedObjectIDsUserInfoKey"
}
