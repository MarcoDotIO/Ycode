// EKAlarm and EKStructuredLocation (interface.md §3.5).

import Foundation
#if canImport(CoreLocation)
import CoreLocation
#else
/// Minimal stand-in for Core Location's coordinate on platforms without it.
/// (A shared open Core Location package may replace it later.)
public struct CLLocationCoordinate2D: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init() { latitude = 0; longitude = 0 }
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Minimal stand-in for Core Location's `CLLocation` (coordinate only).
public class CLLocation: NSObject {
    public let coordinate: CLLocationCoordinate2D
    public init(latitude: Double, longitude: Double) {
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
#endif

struct LocationValue: Hashable {
    var title: String?
    var latitude: Double?
    var longitude: Double?
    var radius: Double
}

public class EKStructuredLocation: EKObject, NSCopying {
    public var title: String?
    public var geoLocation: CLLocation?
    /// Radius in meters (0 = system default).
    public var radius: Double = 0

    public override init() { super.init() }

    public convenience init(title: String) {
        self.init()
        self.title = title
    }

    var value: LocationValue {
        LocationValue(title: title, latitude: geoLocation?.coordinate.latitude,
                      longitude: geoLocation?.coordinate.longitude, radius: radius)
    }

    convenience init(value v: LocationValue) {
        self.init()
        title = v.title
        if let la = v.latitude, let lo = v.longitude { geoLocation = CLLocation(latitude: la, longitude: lo) }
        radius = v.radius
    }

    public func copy(with zone: NSZone? = nil) -> Any { EKStructuredLocation(value: value) }
}

struct AlarmValue: Hashable {
    var relativeOffset: Double
    var absoluteDate: Date?
    var location: LocationValue?
    var proximity: Int

    /// Read-back order: location alarms, relative alarms, absolute alarms,
    /// each by value (interface.md §3.5).
    static func readBackOrder(_ a: AlarmValue, _ b: AlarmValue) -> Bool {
        func kind(_ v: AlarmValue) -> Int { v.location != nil ? 0 : (v.absoluteDate == nil ? 1 : 2) }
        if kind(a) != kind(b) { return kind(a) < kind(b) }
        if let x = a.absoluteDate, let y = b.absoluteDate, x != y { return x < y }
        return a.relativeOffset < b.relativeOffset
    }
}

public class EKAlarm: EKObject, NSCopying {
    private var _relativeOffset: TimeInterval = 0
    private var _absoluteDate: Date?

    /// Seconds relative to the item's start (negative = before). Setting it
    /// clears `absoluteDate`.
    public var relativeOffset: TimeInterval {
        get { _relativeOffset }
        set { _relativeOffset = newValue; _absoluteDate = nil }
    }

    /// Setting a date makes the alarm absolute and sets `relativeOffset` to 0.
    public var absoluteDate: Date? {
        get { _absoluteDate }
        set { _absoluteDate = newValue; if newValue != nil { _relativeOffset = 0 } }
    }

    public var structuredLocation: EKStructuredLocation?
    public var proximity: EKAlarmProximity = .none

    public override init() { super.init() }

    public convenience init(relativeOffset offset: TimeInterval) {
        self.init()
        relativeOffset = offset
    }

    public convenience init(absoluteDate date: Date) {
        self.init()
        absoluteDate = date
    }

    var value: AlarmValue {
        AlarmValue(relativeOffset: _relativeOffset, absoluteDate: _absoluteDate,
                   location: structuredLocation?.value, proximity: proximity.rawValue)
    }

    convenience init(value v: AlarmValue) {
        self.init()
        _relativeOffset = v.relativeOffset
        _absoluteDate = v.absoluteDate
        structuredLocation = v.location.map { EKStructuredLocation(value: $0) }
        proximity = EKAlarmProximity(rawValue: v.proximity) ?? .none
    }

    public func copy(with zone: NSZone? = nil) -> Any { EKAlarm(value: value) }
}
