// WeatherError: api.md §5, behavior.md §4.
//
// Bridges to NSError with domain `WeatherKit.WeatherError` and codes 0
// (`permissionDenied`) and 1 (`unknown`) through Swift's default error
// bridging (the module and type names give the domain, the case order the
// code). The phrases are Ycode's own wording.
import Foundation

/// Errors the weather service reports.
public enum WeatherError: LocalizedError, Sendable {
    /// The request was not authorized: revoked key, malformed token, or an
    /// operation the caller may not perform.
    case permissionDenied
    /// Any other service failure.
    case unknown

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Weather data access was denied."
        case .unknown: return "An unknown weather service error occurred."
        }
    }

    public var failureReason: String? {
        switch self {
        case .permissionDenied:
            return "The weather service did not accept the request: the key may be revoked, the token malformed, or the operation not allowed."
        case .unknown:
            return nil
        }
    }

    public var helpAnchor: String? { nil }

    public var recoverySuggestion: String? { nil }
}

/// Units Ycode's model uses (api.md §6: the REST API's metric units).
enum WeatherUnits {
    /// Millimetres per hour, for precipitation intensities.
    static var millimetersPerHour: UnitSpeed {
        UnitSpeed(symbol: "mm/h", converter: UnitConverterLinear(coefficient: 0.001 / 3600))
    }
}
