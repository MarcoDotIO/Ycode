// EKSource and EKCalendar (interface.md §2.2–§2.3).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An RGB color in the device RGB space; Ycode's portable form of a
/// calendar color (on Apple platforms `cgColor` mirrors it).
public struct YcodeRGBColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    var text: String { "\(red),\(green),\(blue)" }
    init?(text: String) {
        let p = text.split(separator: ",").compactMap { Double($0) }
        guard p.count == 3 else { return nil }
        self.init(red: p[0], green: p[1], blue: p[2])
    }
}

struct SourceRow: Hashable {
    var id: String
    var title: String
    var type: Int
}

struct CalendarRow: Hashable {
    var id: String
    var sourceID: String?
    var title: String
    var type: Int
    var entityMask: UInt
    var color: YcodeRGBColor?
    var allowsModifications: Bool
    var immutable: Bool
    var subscribed: Bool
}

public class EKSource: EKObject {
    let store: EKEventStore
    let row: SourceRow

    init(store: EKEventStore, row: SourceRow) {
        self.store = store
        self.row = row
    }

    public var sourceIdentifier: String { row.id }
    public var sourceType: EKSourceType { EKSourceType(rawValue: row.type) ?? .local }
    public var title: String { row.title }
    public var isDelegate: Bool { false }

    public func calendars(for entityType: EKEntityType) -> Set<EKCalendar> {
        Set(store.calendars(for: entityType).filter { $0.fields.sourceID == row.id })
    }

    @available(*, deprecated, message: "Use calendars(for:)")
    public var calendars: Set<EKCalendar> { calendars(for: .event) }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EKSource else { return false }
        return o.row.id == row.id && o.store === store
    }

    public override var hash: Int { row.id.hashValue }
}

public class EKCalendar: EKObject {
    let store: EKEventStore
    var fields: CalendarRow
    var saved: CalendarRow?

    init(store: EKEventStore, row: CalendarRow, saved: Bool) {
        self.store = store
        self.fields = row
        self.saved = saved ? row : nil
    }

    /// A new, unsaved calendar or reminder list (type local, no source, no
    /// color until saved).
    public convenience init(for entityType: EKEntityType, eventStore: EKEventStore) {
        let row = CalendarRow(id: UUID().uuidString, sourceID: nil, title: "", type: EKCalendarType.local.rawValue,
                              entityMask: entityType == .event ? EKEntityMask.event.rawValue : EKEntityMask.reminder.rawValue,
                              color: nil, allowsModifications: true, immutable: false, subscribed: false)
        self.init(store: eventStore, row: row, saved: false)
    }

    @available(*, deprecated, message: "Use init(for:eventStore:)")
    public convenience init(eventStore: EKEventStore) {
        self.init(for: .event, eventStore: eventStore)
    }

    public var calendarIdentifier: String { fields.id }

    public var title: String {
        get { fields.title }
        set { fields.title = newValue }
    }

    public var type: EKCalendarType { EKCalendarType(rawValue: fields.type) ?? .local }

    public var source: EKSource! {
        get { fields.sourceID.flatMap { store.source(withIdentifier: $0) } }
        set { fields.sourceID = newValue?.sourceIdentifier }
    }

    public var allowsContentModifications: Bool { fields.allowsModifications }
    public var isSubscribed: Bool { fields.subscribed }
    public var isImmutable: Bool { fields.immutable }
    public var supportedEventAvailabilities: EKCalendarEventAvailabilityMask { [] }
    public var allowedEntityTypes: EKEntityMask { EKEntityMask(rawValue: fields.entityMask) }

    /// The calendar color as RGB components (nil on a new calendar until saved).
    public var ycodeColor: YcodeRGBColor? {
        get { fields.color }
        set { fields.color = newValue }
    }

    #if canImport(CoreGraphics)
    public var cgColor: CGColor! {
        get {
            guard let c = fields.color else { return nil }
            return CGColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        }
        set {
            guard let c = newValue, let comps = c.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
                  comps.count >= 3 else { fields.color = nil; return }
            fields.color = YcodeRGBColor(red: Double(comps[0]), green: Double(comps[1]), blue: Double(comps[2]))
        }
    }
    #endif

    public override var hasChanges: Bool { saved == nil || saved != fields }
    public override var isNew: Bool { saved == nil }
    public override func rollback() { if let s = saved { fields = s } }
    public override func reset() { rollback(); _ = refresh() }

    @discardableResult
    public override func refresh() -> Bool {
        guard let row = store.calendarRow(fields.id) else { return false }
        if !hasChanges { fields = row; saved = row }
        return true
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? EKCalendar else { return false }
        return o === self || (o.fields.id == fields.id && o.store === store && !isNew)
    }

    public override var hash: Int { fields.id.hashValue }

    public override var description: String {
        "EKCalendar <\(objectAddress)> {title = \(fields.title); type = \(type); allowsModify = \(allowsContentModifications)}"
    }
}
