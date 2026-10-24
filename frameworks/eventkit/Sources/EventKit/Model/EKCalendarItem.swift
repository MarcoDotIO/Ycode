// EKCalendarItem: the common part of events and reminders (interface.md §1,
// §2.4). Model objects are local snapshots with change tracking: the values
// last read from or written to the store are kept, `hasChanges` compares
// against them and `rollback` restores them.

import Foundation

struct CommonFields: Hashable {
    var title: String = ""
    var location: String?
    var notes: String?
    var url: URL?
    var timeZone: TimeZone?
    var calendarID: String?
}

struct EventFields: Hashable {
    var start: Date?
    var end: Date?
    var allDay = false
    var availability = EKEventAvailability.notSupported.rawValue
    var structuredLocation: LocationValue?
}

struct ReminderFields: Hashable {
    var start: DateComponents?
    var due: DateComponents?
    var completed = false
    var completionDate: Date?
    var priority = 0
}

struct ItemSnapshot: Hashable {
    var common: CommonFields
    var alarms: [AlarmValue]
    var rules: [RuleSpec]
    var event: EventFields?
    var reminder: ReminderFields?
}

public class EKCalendarItem: EKObject {
    let store: EKEventStore
    /// `calendarItemIdentifier`; replaced when an occurrence is detached.
    var itemID: String
    /// UUID part of the external identifier, assigned on the first save.
    var externalID: String?
    /// Persistent event identifier (`<source>:<UUID>[/RID=n]`), events only.
    var storedEventID: String?
    var persisted = false
    var generation: Int
    var common = CommonFields()
    var calendarObject: EKCalendar?
    var alarmObjects: [EKAlarm] = []
    var ruleObjects: [EKRecurrenceRule] = []
    var saved: ItemSnapshot?
    var created: Date?
    var modified: Date?
    var legacyUUID = UUID().uuidString

    init(store: EKEventStore) {
        self.store = store
        self.itemID = UUID().uuidString
        self.generation = store.generation
        super.init()
        common.timeZone = nil
    }

    // MARK: Identifiers

    public var calendarItemIdentifier: String { itemID }

    public var calendarItemExternalIdentifier: String! {
        guard persisted, let ext = externalID else { return itemID }
        return ext
    }

    @available(*, deprecated, message: "Use calendarItemIdentifier")
    public var uuid: String { legacyUUID }

    // MARK: Properties

    public var calendar: EKCalendar! {
        get { calendarObject }
        set {
            calendarObject = newValue
            common.calendarID = newValue?.calendarIdentifier
            calendarDidChange()
        }
    }

    func calendarDidChange() {}

    public var title: String! {
        get { common.title }
        set { common.title = newValue ?? "" }
    }

    public var location: String? {
        get { common.location }
        set { common.location = newValue; locationTextDidChange() }
    }

    func locationTextDidChange() {}

    public var notes: String? {
        get { common.notes }
        set { common.notes = newValue }
    }

    public var url: URL? {
        get { common.url }
        set { common.url = newValue }
    }

    public var timeZone: TimeZone? {
        get { common.timeZone }
        set { common.timeZone = newValue }
    }

    public var creationDate: Date? { created }
    public var lastModifiedDate: Date? { modified }

    public var hasNotes: Bool { !(common.notes ?? "").isEmpty }
    public var hasAttendees: Bool { false }
    public var attendees: [EKParticipant]? { nil }

    public var alarms: [EKAlarm]? {
        get { alarmObjects.isEmpty ? nil : alarmObjects }
        set { alarmObjects = newValue ?? [] }
    }

    public var hasAlarms: Bool { !alarmObjects.isEmpty }

    public func addAlarm(_ alarm: EKAlarm) { alarmObjects.append(alarm) }

    public func removeAlarm(_ alarm: EKAlarm) {
        if let i = alarmObjects.firstIndex(where: { $0 === alarm }) { alarmObjects.remove(at: i) }
    }

    public var recurrenceRules: [EKRecurrenceRule]? {
        get { ruleObjects.isEmpty ? nil : ruleObjects }
        set { ruleObjects = newValue ?? [] }
    }

    public var hasRecurrenceRules: Bool { !ruleObjects.isEmpty }

    public func addRecurrenceRule(_ rule: EKRecurrenceRule) { ruleObjects.append(rule) }

    public func removeRecurrenceRule(_ rule: EKRecurrenceRule) {
        if let i = ruleObjects.firstIndex(where: { $0 === rule }) { ruleObjects.remove(at: i) }
    }

    // MARK: Change tracking

    func snapshot() -> ItemSnapshot {
        ItemSnapshot(common: common, alarms: alarmObjects.map(\.value), rules: ruleObjects.map(\.spec),
                     event: nil, reminder: nil)
    }

    /// Restores values from a snapshot (subclasses add their own part).
    func apply(_ s: ItemSnapshot) {
        common = s.common
        alarmObjects = s.alarms.map { EKAlarm(value: $0) }
        ruleObjects = s.rules.map { EKRecurrenceRule(spec: $0) }
        if let id = s.common.calendarID {
            if calendarObject?.calendarIdentifier != id { calendarObject = store.calendarObject(id) }
        } else {
            calendarObject = nil
        }
    }

    func markSaved() {
        saved = snapshot()
        persisted = true
    }

    /// Valid while the store has not been reset since the object was made.
    var isValid: Bool { generation == store.generation }

    public override var hasChanges: Bool { saved == nil || saved != snapshot() }
    public override var isNew: Bool { !persisted }

    public override func rollback() {
        if let s = saved { apply(s) }
    }

    public override func reset() {
        rollback()
        _ = refresh()
    }

    @discardableResult
    public override func refresh() -> Bool {
        guard persisted, isValid else { return false }
        return store.refreshItem(self)
    }
}
