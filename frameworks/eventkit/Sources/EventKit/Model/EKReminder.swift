// EKReminder (reminders.md §1).

import Foundation

public class EKReminder: EKCalendarItem {
    var reminder = ReminderFields()

    public init(eventStore: EKEventStore) {
        super.init(store: eventStore)
    }

    override init(store: EKEventStore) {
        super.init(store: store)
    }

    public var startDateComponents: DateComponents? {
        get { reminder.start }
        set { reminder.start = newValue }
    }

    public var dueDateComponents: DateComponents? {
        get { reminder.due }
        set { reminder.due = newValue }
    }

    /// Setting YES stamps `completionDate` with the current time; NO clears it.
    public var isCompleted: Bool {
        get { reminder.completed }
        set {
            reminder.completed = newValue
            reminder.completionDate = newValue ? (reminder.completionDate ?? Date()) : nil
        }
    }

    /// Setting nil marks the reminder incomplete; a date marks it completed.
    public var completionDate: Date? {
        get { reminder.completionDate }
        set {
            reminder.completionDate = newValue
            reminder.completed = newValue != nil
        }
    }

    /// 0 none, 1…4 high, 5 medium, 6…9 low. Out-of-range values are kept
    /// here and rejected at save (code 26).
    public var priority: Int {
        get { reminder.priority }
        set { reminder.priority = newValue }
    }

    override func snapshot() -> ItemSnapshot {
        var s = super.snapshot()
        s.reminder = reminder
        return s
    }

    override func apply(_ s: ItemSnapshot) {
        super.apply(s)
        if let r = s.reminder { reminder = r }
    }

    public override var description: String {
        "EKReminder <\(objectAddress)> {title = \(common.title); dueDate = \(String(describing: reminder.due)); completed = \(reminder.completed ? 1 : 0); priority = \(reminder.priority)}"
    }
}
