// A minimal Core Location for platforms that do not have one (Linux).
//
// Scope: only the location value types the WeatherKit API takes and returns
// (`specs/frameworks/weatherkit/api.md`, `location.md` §1 for the CLLocation
// members). No location manager, authorization, geocoding or updates: those
// belong to the future Core Location spec. Names are interop identifiers;
// everything else here is Ycode's own.
//
// On Apple platforms this module is not built (see Package.swift) and the
// system CoreLocation is used instead.
#if !canImport(Darwin)
import Foundation

/// Latitude or longitude in degrees (WGS 84).
public typealias CLLocationDegrees = Double
/// Distance in metres.
public typealias CLLocationDistance = Double
/// Accuracy radius in metres; negative means invalid.
public typealias CLLocationAccuracy = Double
/// Speed in metres per second; negative means invalid.
public typealias CLLocationSpeed = Double
/// Speed accuracy in metres per second; negative means invalid.
public typealias CLLocationSpeedAccuracy = Double
/// Direction in degrees clockwise from true north; negative means invalid.
public typealias CLLocationDirection = Double
/// Direction accuracy in degrees; negative means invalid.
public typealias CLLocationDirectionAccuracy = Double

/// A latitude/longitude pair.
public struct CLLocationCoordinate2D: Sendable {
    public var latitude: CLLocationDegrees
    public var longitude: CLLocationDegrees

    public init() {
        self.latitude = 0
        self.longitude = 0
    }

    public init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Builds a coordinate.
public func CLLocationCoordinate2DMake(_ latitude: CLLocationDegrees, _ longitude: CLLocationDegrees) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

/// True when latitude is within −90…90 and longitude within −180…180.
public func CLLocationCoordinate2DIsValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
    (-90.0...90.0).contains(coordinate.latitude) && (-180.0...180.0).contains(coordinate.longitude)
}

/// A coordinate that is never valid.
public let kCLLocationCoordinate2DInvalid = CLLocationCoordinate2D(latitude: -180, longitude: -180)

/// "No distance filter" for location updates.
public let kCLDistanceFilterNone: CLLocationDistance = -1

/// "Best available" accuracy request.
public let kCLLocationAccuracyBest: CLLocationAccuracy = -1

/// The building floor a location is on.
open class CLFloor: NSObject, @unchecked Sendable {
    /// Floor number relative to the ground floor (0).
    public let level: Int

    init(level: Int) {
        self.level = level
        super.init()
    }
}

/// Where a location came from.
open class CLLocationSourceInformation: NSObject, @unchecked Sendable {
    public let isSimulatedBySoftware: Bool
    public let isProducedByAccessory: Bool

    public init(softwareSimulationState isSoftware: Bool, hardwareAccessoryState isAccessory: Bool) {
        self.isSimulatedBySoftware = isSoftware
        self.isProducedByAccessory = isAccessory
        super.init()
    }
}

/// A geographic fix: coordinate, altitude, accuracies, motion and time.
/// Immutable after creation.
open class CLLocation: NSObject, @unchecked Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let altitude: CLLocationDistance
    public let ellipsoidalAltitude: CLLocationDistance
    public let horizontalAccuracy: CLLocationAccuracy
    public let verticalAccuracy: CLLocationAccuracy
    public let course: CLLocationDirection
    public let courseAccuracy: CLLocationDirectionAccuracy
    public let speed: CLLocationSpeed
    public let speedAccuracy: CLLocationSpeedAccuracy
    public let timestamp: Date
    public let floor: CLFloor?
    public let sourceInformation: CLLocationSourceInformation?

    /// A location at a coordinate. Ycode defaults: altitude 0, horizontal
    /// accuracy 0, every other accuracy and the motion values −1 (invalid),
    /// timestamp now.
    public convenience init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
        self.init(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: 0, verticalAccuracy: -1,
            course: -1, courseAccuracy: -1, speed: -1, speedAccuracy: -1,
            timestamp: Date(), sourceInfo: nil)
    }

    public convenience init(
        coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance,
        horizontalAccuracy hAccuracy: CLLocationAccuracy, verticalAccuracy vAccuracy: CLLocationAccuracy,
        timestamp: Date
    ) {
        self.init(
            coordinate: coordinate, altitude: altitude, horizontalAccuracy: hAccuracy,
            verticalAccuracy: vAccuracy, course: -1, courseAccuracy: -1, speed: -1,
            speedAccuracy: -1, timestamp: timestamp, sourceInfo: nil)
    }

    public convenience init(
        coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance,
        horizontalAccuracy hAccuracy: CLLocationAccuracy, verticalAccuracy vAccuracy: CLLocationAccuracy,
        course: CLLocationDirection, speed: CLLocationSpeed, timestamp: Date
    ) {
        self.init(
            coordinate: coordinate, altitude: altitude, horizontalAccuracy: hAccuracy,
            verticalAccuracy: vAccuracy, course: course, courseAccuracy: -1, speed: speed,
            speedAccuracy: -1, timestamp: timestamp, sourceInfo: nil)
    }

    public convenience init(
        coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance,
        horizontalAccuracy hAccuracy: CLLocationAccuracy, verticalAccuracy vAccuracy: CLLocationAccuracy,
        course: CLLocationDirection, courseAccuracy: CLLocationDirectionAccuracy,
        speed: CLLocationSpeed, speedAccuracy: CLLocationSpeedAccuracy, timestamp: Date
    ) {
        self.init(
            coordinate: coordinate, altitude: altitude, horizontalAccuracy: hAccuracy,
            verticalAccuracy: vAccuracy, course: course, courseAccuracy: courseAccuracy, speed: speed,
            speedAccuracy: speedAccuracy, timestamp: timestamp, sourceInfo: nil)
    }

    public init(
        coordinate: CLLocationCoordinate2D, altitude: CLLocationDistance,
        horizontalAccuracy hAccuracy: CLLocationAccuracy, verticalAccuracy vAccuracy: CLLocationAccuracy,
        course: CLLocationDirection, courseAccuracy: CLLocationDirectionAccuracy,
        speed: CLLocationSpeed, speedAccuracy: CLLocationSpeedAccuracy, timestamp: Date,
        sourceInfo: CLLocationSourceInformation?
    ) {
        self.coordinate = coordinate
        self.altitude = altitude
        self.ellipsoidalAltitude = altitude
        self.horizontalAccuracy = hAccuracy
        self.verticalAccuracy = vAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.timestamp = timestamp
        self.floor = nil
        self.sourceInformation = sourceInfo
        super.init()
    }

    /// Great-circle distance in metres to another location (haversine on a
    /// sphere of the mean Earth radius; altitude is ignored). This is
    /// Ycode's approximation, accurate to about 0.5 %.
    open func distance(from location: CLLocation) -> CLLocationDistance {
        let radius = 6_371_008.8
        let toRadians = Double.pi / 180
        let phi1 = coordinate.latitude * toRadians
        let phi2 = location.coordinate.latitude * toRadians
        let dPhi = phi2 - phi1
        let dLambda = (location.coordinate.longitude - coordinate.longitude) * toRadians
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    open override var description: String {
        "<\(coordinate.latitude),\(coordinate.longitude)> +/- \(horizontalAccuracy)m @ \(timestamp)"
    }
}
#endif
