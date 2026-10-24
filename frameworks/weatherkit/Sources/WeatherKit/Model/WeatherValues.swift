// Weather values: api.md §3.2–§3.6, archive keys codable.md §3.
//
// Stored properties carry the archive key names, so the synthesized Codable
// conformance writes exactly the keys of codable.md; optional properties are
// the "opt" keys (decodeIfPresent / omitted when nil). Non-public keys are
// internal properties: decoded, preserved and written back.
import Foundation

/// Non-public past/next amounts of `CurrentWeather` (codable.md §3).
struct PeriodAmounts: Codable, Equatable, Sendable {
    var pastHour: Measurement<UnitLength>
    var pastSixHours: Measurement<UnitLength>
    var pastTwentyFourHours: Measurement<UnitLength>
    var nextHour: Measurement<UnitLength>
    var nextSixHours: Measurement<UnitLength>
    var nextTwentyFourHours: Measurement<UnitLength>

    static let zero: PeriodAmounts = {
        let zero = Measurement(value: 0, unit: UnitLength.millimeters)
        return PeriodAmounts(
            pastHour: zero, pastSixHours: zero, pastTwentyFourHours: zero,
            nextHour: zero, nextSixHours: zero, nextTwentyFourHours: zero)
    }()
}

extension SnowfallAmount {
    static let zero: SnowfallAmount = {
        let zero = Measurement(value: 0, unit: UnitLength.millimeters)
        return SnowfallAmount(
            amount: zero, maximum: zero, minimum: zero, amountLiquidEquivalent: zero,
            maximumLiquidEquivalent: zero, minimumLiquidEquivalent: zero)
    }()
}

extension PrecipitationAmountByType {
    static let zero: PrecipitationAmountByType = {
        let zero = Measurement(value: 0, unit: UnitLength.millimeters)
        return PrecipitationAmountByType(
            hail: zero, mixed: zero, rainfall: zero, sleet: zero, precipitation: zero, snowfallAmount: .zero)
    }()
}

/// Conditions now.
public struct CurrentWeather: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var cloudCover: Double
    public internal(set) var cloudCoverByAltitude: CloudCoverByAltitude
    var cloudCoverLow: Double
    var cloudCoverMid: Double
    var cloudCoverHigh: Double
    public internal(set) var condition: WeatherCondition
    /// SF Symbols name for the condition.
    public internal(set) var symbolName: String
    public internal(set) var dewPoint: Measurement<UnitTemperature>
    public internal(set) var humidity: Double
    /// Depth of precipitation per unit of time.
    public internal(set) var precipitationIntensity: Measurement<UnitSpeed>
    var apparentPrecipitationIntensity: PrecipitationIntensityValue
    public internal(set) var pressure: Measurement<UnitPressure>
    public internal(set) var pressureTrend: PressureTrend
    public internal(set) var isDaylight: Bool
    public internal(set) var temperature: Measurement<UnitTemperature>
    /// Feels-like temperature.
    public internal(set) var apparentTemperature: Measurement<UnitTemperature>
    public internal(set) var uvIndex: UVIndex
    public internal(set) var visibility: Measurement<UnitLength>
    public internal(set) var wind: Wind
    public internal(set) var metadata: WeatherMetadata
    var highTemperature: Measurement<UnitTemperature>?
    var lowTemperature: Measurement<UnitTemperature>?
    var rainfallAmount: PeriodAmounts
    var snowfallAmount: PeriodAmounts
    var pastHourPrecipitationAmountByType: PrecipitationAmountByType
    var pastSixHoursPrecipitationAmountByType: PrecipitationAmountByType
    var pastTwentyFourHoursPrecipitationAmountByType: PrecipitationAmountByType
    var nextHourPrecipitationAmountByType: PrecipitationAmountByType
    var nextSixHoursPrecipitationAmountByType: PrecipitationAmountByType
    var nextTwentyFourHoursPrecipitationAmountByType: PrecipitationAmountByType
}

/// One minute of the next-hour forecast.
public struct MinuteWeather: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var precipitation: Precipitation
    public internal(set) var precipitationChance: Double
    public internal(set) var precipitationIntensity: Measurement<UnitSpeed>
    var apparentPrecipitationIntensity: PrecipitationIntensityValue
}

/// One hour of the hourly forecast.
public struct HourWeather: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var cloudCover: Double
    public internal(set) var cloudCoverByAltitude: CloudCoverByAltitude
    var cloudCoverLow: Double
    var cloudCoverMid: Double
    var cloudCoverHigh: Double
    public internal(set) var condition: WeatherCondition
    public internal(set) var symbolName: String
    public internal(set) var dewPoint: Measurement<UnitTemperature>
    public internal(set) var humidity: Double
    public internal(set) var isDaylight: Bool
    public internal(set) var precipitation: Precipitation
    public internal(set) var precipitationAmount: Measurement<UnitLength>
    public internal(set) var precipitationChance: Double
    public internal(set) var snowfallAmount: Measurement<UnitLength>
    public internal(set) var pressure: Measurement<UnitPressure>
    public internal(set) var pressureTrend: PressureTrend
    public internal(set) var temperature: Measurement<UnitTemperature>
    public internal(set) var apparentTemperature: Measurement<UnitTemperature>
    public internal(set) var uvIndex: UVIndex
    public internal(set) var visibility: Measurement<UnitLength>
    public internal(set) var wind: Wind
    var apparentPrecipitationIntensity: PrecipitationIntensityValue
}

/// One day of the daily forecast.
public struct DayWeather: Codable, Equatable, Sendable {
    public internal(set) var date: Date
    public internal(set) var condition: WeatherCondition
    public internal(set) var symbolName: String
    public internal(set) var highTemperature: Measurement<UnitTemperature>
    public internal(set) var lowTemperature: Measurement<UnitTemperature>
    public internal(set) var highTemperatureTime: Date?
    public internal(set) var lowTemperatureTime: Date?
    public internal(set) var maximumHumidity: Double
    public internal(set) var minimumHumidity: Double
    var humidityMax: Double
    var humidityMin: Double
    public internal(set) var precipitation: Precipitation
    public internal(set) var precipitationChance: Double
    public internal(set) var precipitationAmountByType: PrecipitationAmountByType
    var storedRainfallAmount: Measurement<UnitLength>
    var storedSnowfallAmount: Measurement<UnitLength>
    public internal(set) var sun: SunEvents
    public internal(set) var moon: MoonEvents
    /// The day's maximum.
    public internal(set) var uvIndex: UVIndex
    public internal(set) var wind: Wind
    /// Metres.
    public internal(set) var maximumVisibility: Double
    /// Metres.
    public internal(set) var minimumVisibility: Double
    var visibilityMax: Double
    var visibilityMin: Double
    public internal(set) var highWindSpeed: Measurement<UnitSpeed>?
    var windSpeedAvg: Measurement<UnitSpeed>
    var windSpeedMax: Measurement<UnitSpeed>
    var windGustSpeedMax: Measurement<UnitSpeed>
    public internal(set) var daytimeForecast: DayPartForecast
    public internal(set) var overnightForecast: DayPartForecast
    public internal(set) var restOfDayForecast: DayPartForecast?

    enum CodingKeys: String, CodingKey {
        case date, condition, symbolName, highTemperature, lowTemperature, highTemperatureTime,
            lowTemperatureTime, maximumHumidity, minimumHumidity, humidityMax, humidityMin,
            precipitation, precipitationChance, precipitationAmountByType
        case storedRainfallAmount = "rainfallAmount"
        case storedSnowfallAmount = "snowfallAmount"
        case sun, moon, uvIndex, wind, maximumVisibility, minimumVisibility, visibilityMax,
            visibilityMin, highWindSpeed, windSpeedAvg, windSpeedMax, windGustSpeedMax,
            daytimeForecast, overnightForecast, restOfDayForecast
    }

    /// Total precipitation of the day.
    @available(*, deprecated, message: "Use precipitationAmountByType.precipitation")
    public var precipitationAmount: Measurement<UnitLength> { precipitationAmountByType.precipitation }

    /// Snowfall of the day.
    @available(*, deprecated, message: "Use precipitationAmountByType.snowfallAmount")
    public var snowfallAmount: Measurement<UnitLength> { storedSnowfallAmount }

    /// Rainfall of the day.
    @available(*, deprecated, message: "Use precipitationAmountByType.rainfall")
    public var rainfallAmount: Measurement<UnitLength> { storedRainfallAmount }
}

/// A part of a day (daytime, overnight, rest of day).
public struct DayPartForecast: Codable, Equatable, Sendable {
    var forecastStart: Date
    var forecastEnd: Date
    public internal(set) var cloudCover: Double
    public internal(set) var cloudCoverByAltitude: CloudCoverByAltitude
    public internal(set) var condition: WeatherCondition
    public internal(set) var highTemperature: Measurement<UnitTemperature>
    public internal(set) var lowTemperature: Measurement<UnitTemperature>
    var humidity: Double
    public internal(set) var maximumHumidity: Double
    public internal(set) var minimumHumidity: Double
    var isDaylight: Bool
    public internal(set) var maximumVisibility: Measurement<UnitLength>
    public internal(set) var minimumVisibility: Measurement<UnitLength>
    var maximumUVIndex: UVIndex
    var minimumUVIndex: UVIndex
    public internal(set) var precipitation: Precipitation
    public internal(set) var precipitationAmountByType: PrecipitationAmountByType
    public internal(set) var precipitationChance: Double
    var precipitationIntensityMax: PrecipitationIntensityValue
    var perceivedPrecipitationIntensityMax: PrecipitationIntensityValue
    public internal(set) var wind: Wind
    public internal(set) var highWindSpeed: Measurement<UnitSpeed>
}

/// A weather alert issued for the location.
public struct WeatherAlert: Codable, Equatable, Sendable {
    /// Page with the full alert; apps must link it (behavior.md §7).
    public internal(set) var detailsURL: URL
    /// Issuing agency, to be shown in full.
    public internal(set) var source: String
    /// Headline.
    public internal(set) var summary: String
    /// Affected area name.
    public internal(set) var region: String?
    public internal(set) var severity: WeatherSeverity
    public internal(set) var metadata: WeatherMetadata
    var id: UUID
    /// String enum; `normal` is one accepted value. Kept as text.
    var importance: String
    var alertDescription: String
    var details: String?
    var date: Date
    var issuedDate: Date
    var onsetTime: Date?
    var endDate: Date?
    var expirationDate: Date

    enum CodingKeys: String, CodingKey {
        case detailsURL, source, summary, region, severity, metadata, id, importance
        case alertDescription = "description"
        case details, date, issuedDate, onsetTime, endDate, expirationDate
    }
}
