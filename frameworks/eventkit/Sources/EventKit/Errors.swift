// EKErrorDomain errors (specs/frameworks/eventkit/errors.md). The codes are the
// contract; the English messages are Ycode's own wording.

import Foundation

public struct EKError: Error, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case eventNotMutable = 0
        case noCalendar = 1
        case noStartDate = 2
        case noEndDate = 3
        case datesInverted = 4
        case internalFailure = 5
        case calendarReadOnly = 6
        case durationGreaterThanRecurrence = 7
        case alarmGreaterThanRecurrence = 8
        case startDateTooFarInFuture = 9
        case startDateCollidesWithOtherOccurrence = 10
        case objectBelongsToDifferentStore = 11
        case invitesCannotBeMoved = 12
        case invalidSpan = 13
        case calendarHasNoSource = 14
        case calendarSourceCannotBeModified = 15
        case calendarIsImmutable = 16
        case sourceDoesNotAllowCalendarAddDelete = 17
        case recurringReminderRequiresDueDate = 18
        case structuredLocationsNotSupported = 19
        case reminderLocationsNotSupported = 20
        case alarmProximityNotSupported = 21
        case calendarDoesNotAllowEvents = 22
        case calendarDoesNotAllowReminders = 23
        case sourceDoesNotAllowReminders = 24
        case sourceDoesNotAllowEvents = 25
        case priorityIsInvalid = 26
        case invalidEntityType = 27
        case procedureAlarmsNotMutable = 28
        case eventStoreNotAuthorized = 29
        case osNotSupported = 30
        case invalidInviteReplyCalendar = 31
        case notificationsCollectionFlagNotSet = 32
        case sourceMismatch = 33
        case notificationCollectionMismatch = 34
        case notificationSavedWithoutCollection = 35
        case reminderAlarmContainsEmailOrUrl = 36
        case last = 37
    }

    public let code: Code

    public init(_ code: Code) { self.code = code }

    public static var errorDomain: String { EKErrorDomain }

    public static var eventNotMutable: Code { .eventNotMutable }
    public static var noCalendar: Code { .noCalendar }
    public static var noStartDate: Code { .noStartDate }
    public static var noEndDate: Code { .noEndDate }
    public static var datesInverted: Code { .datesInverted }
    public static var internalFailure: Code { .internalFailure }
    public static var calendarReadOnly: Code { .calendarReadOnly }
    public static var objectBelongsToDifferentStore: Code { .objectBelongsToDifferentStore }
    public static var calendarHasNoSource: Code { .calendarHasNoSource }
    public static var calendarIsImmutable: Code { .calendarIsImmutable }
    public static var sourceDoesNotAllowCalendarAddDelete: Code { .sourceDoesNotAllowCalendarAddDelete }
    public static var recurringReminderRequiresDueDate: Code { .recurringReminderRequiresDueDate }
    public static var calendarDoesNotAllowEvents: Code { .calendarDoesNotAllowEvents }
    public static var calendarDoesNotAllowReminders: Code { .calendarDoesNotAllowReminders }
    public static var priorityIsInvalid: Code { .priorityIsInvalid }
    public static var eventStoreNotAuthorized: Code { .eventStoreNotAuthorized }

    /// Ycode's English message for a code.
    static func message(for code: Code) -> String {
        switch code {
        case .eventNotMutable: return "This event cannot be changed."
        case .noCalendar: return "The item has no calendar."
        case .noStartDate: return "The event has no start date."
        case .noEndDate: return "The event has no end date."
        case .datesInverted: return "The event ends before it starts."
        case .internalFailure: return "The calendar database reported an internal failure."
        case .calendarReadOnly: return "This calendar is read-only."
        case .durationGreaterThanRecurrence: return "The event lasts longer than its repeat interval."
        case .alarmGreaterThanRecurrence: return "The alarm is earlier than the previous occurrence."
        case .startDateTooFarInFuture: return "The start date is too far in the future."
        case .startDateCollidesWithOtherOccurrence: return "The start date collides with another occurrence."
        case .objectBelongsToDifferentStore: return "The item belongs to a different event store."
        case .invitesCannotBeMoved: return "Invitations cannot be moved to another calendar."
        case .invalidSpan: return "The span is not valid."
        case .calendarHasNoSource: return "The calendar has no source."
        case .calendarSourceCannotBeModified: return "The calendar's source cannot be changed."
        case .calendarIsImmutable: return "This calendar cannot be changed."
        case .sourceDoesNotAllowCalendarAddDelete: return "This account does not let calendars be added or removed."
        case .recurringReminderRequiresDueDate: return "A recurring reminder needs a due date."
        case .structuredLocationsNotSupported: return "This calendar does not support structured locations."
        case .reminderLocationsNotSupported: return "This list does not support location reminders."
        case .alarmProximityNotSupported: return "This calendar does not support location alarms."
        case .calendarDoesNotAllowEvents: return "Events cannot be added to this calendar."
        case .calendarDoesNotAllowReminders: return "Reminders cannot be added to this calendar."
        case .sourceDoesNotAllowReminders: return "This account does not support reminders."
        case .sourceDoesNotAllowEvents: return "This account does not support events."
        case .priorityIsInvalid: return "The priority must be in the range 0 to 9."
        case .invalidEntityType: return "The entity type is not valid."
        case .procedureAlarmsNotMutable: return "Procedure alarms cannot be changed."
        case .eventStoreNotAuthorized: return "The app has no access to the calendar database."
        case .osNotSupported: return "This operation is not supported on this system."
        case .invalidInviteReplyCalendar: return "The calendar for invitation replies is not valid."
        case .notificationsCollectionFlagNotSet: return "The notification collection flag is not set."
        case .sourceMismatch: return "The sources do not match."
        case .notificationCollectionMismatch: return "The notification collections do not match."
        case .notificationSavedWithoutCollection: return "A notification was saved without a collection."
        case .reminderAlarmContainsEmailOrUrl: return "A reminder alarm cannot contain an email address or URL."
        case .last: return "Unknown calendar error."
        }
    }
}

/// Pattern matching in `catch EKError.noCalendar { … }`.
public func ~= (code: EKError.Code, error: any Error) -> Bool {
    guard let error = error as? EKError else { return false }
    return error.code == code
}

extension EKError: CustomNSError {
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: EKError.message(for: code)]
    }
}

extension EKError: LocalizedError {
    public var errorDescription: String? { EKError.message(for: code) }
}
