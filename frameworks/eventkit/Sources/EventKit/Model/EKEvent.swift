// EKEvent (interface.md §3, recurrence.md §6).

import Foundation

public class EKEvent: EKCalendarItem {
    var event = EventFields()
    /// Master item identifier for an expanded occurrence or a detached one.
    var masterID: String?
    /// Original start of an occurrence (occurrenceDate) when it differs from
    /// the master's own start, or of a detached occurrence.
    var originalStart: Date?
    /// An occurrence produced by expansion (not a stored row of its own).
    var isOccurrence = false
    var detached = false
    var eventStatus = EKEventStatus.none

    public init(eventStore: EKEventStore) {
        super.init(store: eventStore)
        common.timeZone = eventStore.readerZone
    }

    override init(store: EKEventStore) {
        super.init(store: store)
    }

    // MARK: Identifiers

    /// nil until saved, and after the store was reset.
    public var eventIdentifier: String? {
        guard persisted, isValid else { return nil }
        return storedEventID
    }

    // MARK: Properties

    public var isAllDay: Bool {
        get { event.allDay }
        set { event.allDay = newValue }
    }

    public var startDate: Date! {
        get { event.start }
        set { event.start = newValue }
    }

    public var endDate: Date! {
        get { event.end }
        set { event.end = newValue }
    }

    public var structuredLocation: EKStructuredLocation? {
        get { event.structuredLocation.map { EKStructuredLocation(value: $0) } }
        set {
            event.structuredLocation = newValue?.value
            if let t = newValue?.title { common.location = t }
        }
    }

    public var availability: EKEventAvailability {
        get { EKEventAvailability(rawValue: event.availability) ?? .notSupported }
        set { event.availability = newValue.rawValue }
    }

    override func calendarDidChange() {
        if let cal = calendarObject, !cal.supportedEventAvailabilities.isEmpty,
           event.availability == EKEventAvailability.notSupported.rawValue {
            event.availability = EKEventAvailability.busy.rawValue
        }
    }

    public var status: EKEventStatus { eventStatus }
    public var organizer: EKParticipant? { nil }
    public var isDetached: Bool { detached }

    /// Original start of this occurrence; the start for a single event.
    public var occurrenceDate: Date! { originalStart ?? event.start }

    public var birthdayContactIdentifier: String? { nil }

    @available(*, deprecated, message: "Use birthdayContactIdentifier")
    public var birthdayPersonID: Int { -1 }

    public func compareStartDate(with other: EKEvent) -> ComparisonResult {
        guard let a = event.start, let b = other.event.start else { return .orderedSame }
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    // MARK: Change tracking

    override func snapshot() -> ItemSnapshot {
        var s = super.snapshot()
        s.event = event
        return s
    }

    override func apply(_ s: ItemSnapshot) {
        super.apply(s)
        if let e = s.event { event = e }
    }

    public override var description: String {
        let f = ISO8601DateFormatter()
        func d(_ x: Date?) -> String { x.map { f.string(from: $0) } ?? "(null)" }
        return "EKEvent <\(objectAddress)> {title = \(common.title); startDate = \(d(event.start)); endDate = \(d(event.end)); allDay = \(event.allDay ? 1 : 0); recurrence = \(ruleObjects.map(\.rruleText))}"
    }
}
