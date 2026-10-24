// WeatherAttribution (api.md §4), WeatherMetadata (api.md §3.1) and their
// archive forms (codable.md §2).
import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Branding and legal attribution of the data provider. Apps that display
/// the data must show the mark and link the legal page (behavior.md §7).
///
/// Archive: `{"storage": {serviceName, legalPageURL, squareMarkURL,
/// combinedMarkLightURL, combinedMarkDarkURL, logoURL?, sourceURL?}}`.
/// `legalAttributionText` is not part of the archive.
public struct WeatherAttribution: Codable, Equatable, Sendable {
    struct Storage: Codable, Equatable, Sendable {
        var serviceName: String
        var legalPageURL: URL
        var squareMarkURL: URL
        var combinedMarkLightURL: URL
        var combinedMarkDarkURL: URL
        /// Non-public, preserved.
        var logoURL: URL?
        /// Non-public, preserved.
        var sourceURL: URL?
    }

    var storage: Storage
    /// Plain-text source list when the provider supplies one; not archived.
    var legalText: String? = nil

    enum CodingKeys: String, CodingKey {
        case storage
    }

    package init(
        serviceName: String, legalPageURL: URL, squareMarkURL: URL, combinedMarkLightURL: URL,
        combinedMarkDarkURL: URL, legalAttributionText: String? = nil, logoURL: URL? = nil, sourceURL: URL? = nil
    ) {
        self.storage = Storage(
            serviceName: serviceName, legalPageURL: legalPageURL, squareMarkURL: squareMarkURL,
            combinedMarkLightURL: combinedMarkLightURL, combinedMarkDarkURL: combinedMarkDarkURL,
            logoURL: logoURL, sourceURL: sourceURL)
        self.legalText = legalAttributionText
    }

    /// Provider name ("Apple Weather" for Apple's service; the backend's name here).
    public var serviceName: String { storage.serviceName }
    /// Page listing the data sources.
    public var legalPageURL: URL { storage.legalPageURL }
    /// Square logo.
    public var squareMarkURL: URL { storage.squareMarkURL }
    /// Combined mark for light backgrounds.
    public var combinedMarkLightURL: URL { storage.combinedMarkLightURL }
    /// Combined mark for dark backgrounds.
    public var combinedMarkDarkURL: URL { storage.combinedMarkDarkURL }

    /// The source list as plain text, for places that cannot show a link.
    /// When the provider gave no text (for example after decoding an
    /// archive, which does not carry it), Ycode returns the service name and
    /// the legal page address on two lines.
    public var legalAttributionText: String {
        if let legalText, !legalText.isEmpty { return legalText }
        return "\(storage.serviceName)\n\(storage.legalPageURL.absoluteString)"
    }

    /// Equality compares the archived content only.
    public static func == (lhs: WeatherAttribution, rhs: WeatherAttribution) -> Bool {
        lhs.storage == rhs.storage
    }
}

/// When a product was produced, when it expires and which coordinate it is for.
///
/// Archive: `{date, expirationDate, latitude, longitude, attribution?}`;
/// `location` is rebuilt from the coordinate.
public struct WeatherMetadata: Codable, Equatable, Sendable {
    /// When the data was produced.
    public internal(set) var date: Date
    /// When the data should be refreshed.
    public internal(set) var expirationDate: Date
    var latitude: Double
    var longitude: Double
    /// Preserved when present.
    var attribution: WeatherAttribution?

    package init(date: Date, expirationDate: Date, latitude: Double, longitude: Double, attribution: WeatherAttribution? = nil) {
        self.date = date
        self.expirationDate = expirationDate
        self.latitude = latitude
        self.longitude = longitude
        self.attribution = attribution
    }

    /// The coordinate the data is for.
    public var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}
