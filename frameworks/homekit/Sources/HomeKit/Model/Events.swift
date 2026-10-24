// Trigger events and number ranges (object-model.md §9,
// simulator-baseline.md §7: copy/mutableCopy classes, fresh identifiers,
// identity equality, `isSupported(forHome:)`).

import Foundation
#if canImport(CoreLocation)
// Re-exported so `CLRegion` is visible to `import HomeKit` code, as with the
// system framework's module.
@_exported import CoreLocation
#else
/// Minimal Core Location types for platforms without it (Ycode shim:
/// coordinates and circular regions only).
public typealias CLLocationDegrees = Double
public typealias CLLocationDistance = Double

public struct CLLocationCoordinate2D: Hashable, Sendable {
    public var latitude: CLLocationDegrees
    public var longitude: CLLocationDegrees
    public init() { latitude = 0; longitude = 0 }
    public init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

open class CLRegion: NSObject, @unchecked Sendable {
    public let identifier: String
    public var notifyOnEntry = true
    public var notifyOnExit = true
    init(identifier: String) { self.identifier = identifier }
}

open class CLCircularRegion: CLRegion, @unchecked Sendable {
    public let center: CLLocationCoordinate2D
    public let radius: CLLocationDistance
    public init(center: CLLocationCoordinate2D, radius: CLLocationDistance, identifier: String) {
        self.center = center
        self.radius = radius
        super.init(identifier: identifier)
    }
}
#endif

/// A fresh event identifier. Observed identifiers carry version nibble 5
/// (simulator-baseline.md §7); Ycode draws random bits and sets that nibble
/// and the RFC 4122 variant.
func freshEventIdentifier() -> UUID {
    var u = UUID().uuid
    u.6 = (u.6 & 0x0F) | 0x50
    u.8 = (u.8 & 0x3F) | 0x80
    return UUID(uuid: u)
}

// MARK: - Base

/// Abstract event. Equality is identity (two events with equal content are
/// not equal); `copy()` gives the immutable class, `mutableCopy()` the
/// `HMMutable…` class, both with a new identifier.
open class HMEvent: NSObject, NSCopying, NSMutableCopying, @unchecked Sendable {
    public let uniqueIdentifier: UUID

    override init() {
        uniqueIdentifier = freshEventIdentifier()
        super.init()
    }

    init(id: UUID) {
        uniqueIdentifier = id
        super.init()
    }

    /// Whether the home's hub can run this kind of event: false without a
    /// home (except location events), true when the hub is connected.
    open class func isSupported(forHome home: HMHome?) -> Bool {
        guard let home else { return false }
        return home.homeHubState == .connected
    }

    open func copy(with zone: NSZone? = nil) -> Any { HMEvent() }
    open func mutableCopy(with zone: NSZone? = nil) -> Any { HMEvent() }

    func record() -> YcodeEventRecord? { nil }

    static func make(_ r: YcodeEventRecord, home: HMHome) -> HMEvent? {
        switch r.kind {
        case .characteristic(let cid, let value):
            guard let c = home.characteristic(cid) else { return nil }
            switch value {
            case .string?: return HMCharacteristicEvent<NSString>(id: r.id, characteristic: c, value: value)
            case .data?: return HMCharacteristicEvent<NSData>(id: r.id, characteristic: c, value: value)
            default: return HMCharacteristicEvent<NSNumber>(id: r.id, characteristic: c, value: value)
            }
        case .thresholdRange(let cid, let lo, let hi):
            guard let c = home.characteristic(cid) else { return nil }
            return HMCharacteristicThresholdRangeEvent(id: r.id, characteristic: c,
                                                       thresholdRange: HMNumberRange(lo.map(NSNumber.init(value:)), hi.map(NSNumber.init(value:))))
        case .location(let region):
            let reg = region.map { rr -> CLRegion in
                let c = CLCircularRegion(center: CLLocationCoordinate2D(latitude: rr.latitude, longitude: rr.longitude),
                                         radius: rr.radius, identifier: rr.identifier)
                c.notifyOnEntry = rr.notifyOnEntry
                c.notifyOnExit = rr.notifyOnExit
                return c
            }
            return HMLocationEvent(id: r.id, region: reg)
        case .presence(let type, let user):
            return HMPresenceEvent(id: r.id, presenceEventType: HMPresenceEventType(rawValue: type) ?? .everyEntry,
                                   presenceUserType: HMPresenceEventUserType(rawValue: user) ?? .currentUser)
        case .calendar(let comps):
            return HMCalendarEvent(id: r.id, fire: comps)
        case .significantTime(let event, let offset):
            return HMSignificantTimeEvent(id: r.id, significantEvent: HMSignificantEvent(rawValue: event), offset: offset)
        case .duration(let d):
            return HMDurationEvent(id: r.id, duration: d)
        }
    }
}

// MARK: - Characteristic events

/// Fires when a characteristic changes (to `triggerValue`, if given).
open class HMCharacteristicEvent<TriggerValueType: NSCopying>: HMEvent, @unchecked Sendable {
    public internal(set) var characteristic: HMCharacteristic
    public internal(set) var triggerValue: TriggerValueType?
    /// Stored form of a value received from the store for another client's event.
    var storedValue: YcodeHomeValue?

    public init(characteristic: HMCharacteristic, triggerValue: TriggerValueType?) {
        self.characteristic = characteristic
        self.triggerValue = triggerValue
        super.init()
    }

    init(id: UUID, characteristic: HMCharacteristic, value: YcodeHomeValue?) {
        self.characteristic = characteristic
        self.storedValue = value
        self.triggerValue = value?.apiValue as? TriggerValueType
        super.init(id: id)
    }

    open override func copy(with zone: NSZone? = nil) -> Any {
        HMCharacteristicEvent(characteristic: characteristic, triggerValue: triggerValue)
    }

    open override func mutableCopy(with zone: NSZone? = nil) -> Any {
        HMMutableCharacteristicEvent(characteristic: characteristic, triggerValue: triggerValue)
    }

    override func record() -> YcodeEventRecord? {
        let v = triggerValue.flatMap { YcodeHomeValue(any: $0) } ?? storedValue
        return YcodeEventRecord(id: uniqueIdentifier, kind: .characteristic(characteristicID: characteristic.uniqueIdentifier,
                                                                            triggerValue: v))
    }
}

open class HMMutableCharacteristicEvent<TriggerValueType: NSCopying>: HMCharacteristicEvent<TriggerValueType>, @unchecked Sendable {
    open override var characteristic: HMCharacteristic {
        get { super.characteristic }
        set { super.characteristic = newValue }
    }
    open override var triggerValue: TriggerValueType? {
        get { super.triggerValue }
        set { super.triggerValue = newValue }
    }
}

/// Fires when a numeric characteristic enters a range.
open class HMCharacteristicThresholdRangeEvent: HMEvent, @unchecked Sendable {
    public internal(set) var characteristic: HMCharacteristic
    public internal(set) var thresholdRange: HMNumberRange

    public init(characteristic: HMCharacteristic, thresholdRange: HMNumberRange) {
        self.characteristic = characteristic
        self.thresholdRange = thresholdRange
        super.init()
    }

    init(id: UUID, characteristic: HMCharacteristic, thresholdRange: HMNumberRange) {
        self.characteristic = characteristic
        self.thresholdRange = thresholdRange
        super.init(id: id)
    }

    open override func copy(with zone: NSZone? = nil) -> Any {
        HMCharacteristicThresholdRangeEvent(characteristic: characteristic, thresholdRange: thresholdRange)
    }

    open override func mutableCopy(with zone: NSZone? = nil) -> Any {
        HMMutableCharacteristicThresholdRangeEvent(characteristic: characteristic, thresholdRange: thresholdRange)
    }

    override func record() -> YcodeEventRecord? {
        YcodeEventRecord(id: uniqueIdentifier, kind: .thresholdRange(
            characteristicID: characteristic.uniqueIdentifier,
            minimum: thresholdRange.minValue?.doubleValue, maximum: thresholdRange.maxValue?.doubleValue))
    }
}

open class HMMutableCharacteristicThresholdRangeEvent: HMCharacteristicThresholdRangeEvent, @unchecked Sendable {
    open override var characteristic: HMCharacteristic {
        get { super.characteristic }
        set { super.characteristic = newValue }
    }
    open override var thresholdRange: HMNumberRange {
        get { super.thresholdRange }
        set { super.thresholdRange = newValue }
    }
}

// MARK: - Location and presence

/// Fires on entering or leaving a region. Supported without a home.
open class HMLocationEvent: HMEvent, @unchecked Sendable {
    public internal(set) var region: CLRegion?

    public init(region: CLRegion) {
        self.region = region
        super.init()
    }

    init(id: UUID, region: CLRegion?) {
        self.region = region
        super.init(id: id)
    }

    init(copying region: CLRegion?) {
        self.region = region
        super.init()
    }

    open override class func isSupported(forHome home: HMHome?) -> Bool {
        guard let home else { return true }
        return home.homeHubState == .connected
    }

    open override func copy(with zone: NSZone? = nil) -> Any { HMLocationEvent(copying: region) }
    open override func mutableCopy(with zone: NSZone? = nil) -> Any { HMMutableLocationEvent(copying: region) }

    override func record() -> YcodeEventRecord? {
        var rr: YcodeRegionRecord?
        if let c = region as? CLCircularRegion {
            rr = YcodeRegionRecord(identifier: c.identifier, latitude: c.center.latitude, longitude: c.center.longitude,
                                   radius: c.radius, notifyOnEntry: c.notifyOnEntry, notifyOnExit: c.notifyOnExit)
        } else if let r = region {
            rr = YcodeRegionRecord(identifier: r.identifier, latitude: 0, longitude: 0, radius: 0,
                                   notifyOnEntry: r.notifyOnEntry, notifyOnExit: r.notifyOnExit)
        }
        return YcodeEventRecord(id: uniqueIdentifier, kind: .location(rr))
    }
}

open class HMMutableLocationEvent: HMLocationEvent, @unchecked Sendable {
    open override var region: CLRegion? {
        get { super.region }
        set { super.region = newValue }
    }
}

/// Fires when users arrive or leave (object-model.md §9 values).
open class HMPresenceEvent: HMEvent, @unchecked Sendable {
    public internal(set) var presenceEventType: HMPresenceEventType
    public internal(set) var presenceUserType: HMPresenceEventUserType

    public init(presenceEventType: HMPresenceEventType, presenceUserType: HMPresenceEventUserType) {
        self.presenceEventType = presenceEventType
        self.presenceUserType = presenceUserType
        super.init()
    }

    init(id: UUID, presenceEventType: HMPresenceEventType, presenceUserType: HMPresenceEventUserType) {
        self.presenceEventType = presenceEventType
        self.presenceUserType = presenceUserType
        super.init(id: id)
    }

    open override func copy(with zone: NSZone? = nil) -> Any {
        HMPresenceEvent(presenceEventType: presenceEventType, presenceUserType: presenceUserType)
    }

    open override func mutableCopy(with zone: NSZone? = nil) -> Any {
        HMMutablePresenceEvent(presenceEventType: presenceEventType, presenceUserType: presenceUserType)
    }

    override func record() -> YcodeEventRecord? {
        YcodeEventRecord(id: uniqueIdentifier, kind: .presence(type: presenceEventType.rawValue, userType: presenceUserType.rawValue))
    }
}

open class HMMutablePresenceEvent: HMPresenceEvent, @unchecked Sendable {
    open override var presenceEventType: HMPresenceEventType {
        get { super.presenceEventType }
        set { super.presenceEventType = newValue }
    }
    open override var presenceUserType: HMPresenceEventUserType {
        get { super.presenceUserType }
        set { super.presenceUserType = newValue }
    }
}

// MARK: - Time events

/// Abstract base of time events (iOS 11).
open class HMTimeEvent: HMEvent, @unchecked Sendable {}

/// Fires at matching date components.
open class HMCalendarEvent: HMTimeEvent, @unchecked Sendable {
    public internal(set) var fireDateComponents: DateComponents

    public init(fire fireDateComponents: DateComponents) {
        self.fireDateComponents = fireDateComponents
        super.init()
    }

    init(id: UUID, fire: DateComponents) {
        fireDateComponents = fire
        super.init(id: id)
    }

    open override func copy(with zone: NSZone? = nil) -> Any { HMCalendarEvent(fire: fireDateComponents) }
    open override func mutableCopy(with zone: NSZone? = nil) -> Any { HMMutableCalendarEvent(fire: fireDateComponents) }

    override func record() -> YcodeEventRecord? { YcodeEventRecord(id: uniqueIdentifier, kind: .calendar(fireDateComponents)) }
}

open class HMMutableCalendarEvent: HMCalendarEvent, @unchecked Sendable {
    open override var fireDateComponents: DateComponents {
        get { super.fireDateComponents }
        set { super.fireDateComponents = newValue }
    }
}

/// Fires at sunrise or sunset plus an offset.
open class HMSignificantTimeEvent: HMTimeEvent, @unchecked Sendable {
    public internal(set) var significantEvent: HMSignificantEvent
    public internal(set) var offset: DateComponents?

    public init(significantEvent: HMSignificantEvent, offset: DateComponents?) {
        self.significantEvent = significantEvent
        self.offset = offset
        super.init()
    }

    init(id: UUID, significantEvent: HMSignificantEvent, offset: DateComponents?) {
        self.significantEvent = significantEvent
        self.offset = offset
        super.init(id: id)
    }

    open override func copy(with zone: NSZone? = nil) -> Any {
        HMSignificantTimeEvent(significantEvent: significantEvent, offset: offset)
    }

    open override func mutableCopy(with zone: NSZone? = nil) -> Any {
        HMMutableSignificantTimeEvent(significantEvent: significantEvent, offset: offset)
    }

    override func record() -> YcodeEventRecord? {
        YcodeEventRecord(id: uniqueIdentifier, kind: .significantTime(event: significantEvent.rawValue, offset: offset))
    }
}

open class HMMutableSignificantTimeEvent: HMSignificantTimeEvent, @unchecked Sendable {
    open override var significantEvent: HMSignificantEvent {
        get { super.significantEvent }
        set { super.significantEvent = newValue }
    }
    open override var offset: DateComponents? {
        get { super.offset }
        set { super.offset = newValue }
    }
}

/// End event: a duration after the trigger fired.
open class HMDurationEvent: HMTimeEvent, @unchecked Sendable {
    public internal(set) var duration: TimeInterval

    public init(duration: TimeInterval) {
        self.duration = duration
        super.init()
    }

    init(id: UUID, duration: TimeInterval) {
        self.duration = duration
        super.init(id: id)
    }

    open override func copy(with zone: NSZone? = nil) -> Any { HMDurationEvent(duration: duration) }
    open override func mutableCopy(with zone: NSZone? = nil) -> Any { HMMutableDurationEvent(duration: duration) }

    override func record() -> YcodeEventRecord? { YcodeEventRecord(id: uniqueIdentifier, kind: .duration(duration)) }
}

open class HMMutableDurationEvent: HMDurationEvent, @unchecked Sendable {
    open override var duration: TimeInterval {
        get { super.duration }
        set { super.duration = newValue }
    }
}

// MARK: - Number range (iOS 11)

/// Min-only, max-only or both; value equality; min > max is accepted
/// (simulator-baseline.md §7).
open class HMNumberRange: NSObject, @unchecked Sendable {
    public let minValue: NSNumber?
    public let maxValue: NSNumber?

    init(_ minValue: NSNumber?, _ maxValue: NSNumber?) {
        self.minValue = minValue
        self.maxValue = maxValue
    }

    public convenience init(minValue: NSNumber, maxValue: NSNumber) { self.init(minValue, maxValue) }
    public convenience init(minValue: NSNumber) { self.init(minValue, nil) }
    public convenience init(maxValue: NSNumber) { self.init(nil, maxValue) }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? HMNumberRange else { return false }
        return o.minValue?.doubleValue == minValue?.doubleValue && o.maxValue?.doubleValue == maxValue?.doubleValue
    }

    open override var hash: Int {
        var h = Hasher()
        h.combine(minValue?.doubleValue)
        h.combine(maxValue?.doubleValue)
        return h.finalize()
    }
}
