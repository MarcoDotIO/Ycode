// The JSON objects of the WeatherKit REST API v1 (rest-api.md §4). Field
// names are interop identifiers; documented required fields are
// non-optional, documented optional fields optional.
import Foundation

enum REST {
    struct Metadata: Decodable {
        var expireTime: Date
        var latitude: Double
        var longitude: Double
        var readTime: Date
        var version: Int?
        var attributionURL: String?
        var language: String?
        var providerLogo: String?
        var providerName: String?
        var reportedTime: Date?
        var temporarilyUnavailable: Bool?
        var units: String?
    }

    struct Weather: Decodable {
        var currentWeather: CurrentWeather?
        var forecastDaily: DailyForecast?
        var forecastHourly: HourlyForecast?
        var forecastNextHour: NextHourForecast?
        var weatherAlerts: WeatherAlertCollection?
    }

    struct CurrentWeather: Decodable {
        var name: String?
        var metadata: Metadata
        var asOf: Date
        var cloudCover: Double?
        var conditionCode: String
        var daylight: Bool?
        var humidity: Double
        var precipitationIntensity: Double
        var pressure: Double
        var pressureTrend: String
        var temperature: Double
        var temperatureApparent: Double
        var temperatureDewPoint: Double
        var uvIndex: Int
        var visibility: Double
        var windDirection: Double?
        var windGust: Double?
        var windSpeed: Double
    }

    struct HourlyForecast: Decodable {
        var name: String?
        var metadata: Metadata
        var hours: [HourWeatherConditions]
    }

    struct HourWeatherConditions: Decodable {
        var cloudCover: Double
        var conditionCode: String
        var daylight: Bool?
        var forecastStart: Date
        var humidity: Double
        var precipitationAmount: Double?
        var precipitationChance: Double
        var precipitationType: String
        var pressure: Double
        var pressureTrend: String?
        var snowfallIntensity: Double?
        var temperature: Double
        var temperatureApparent: Double
        var temperatureDewPoint: Double?
        var uvIndex: Int
        var visibility: Double
        var windDirection: Double?
        var windGust: Double?
        var windSpeed: Double
    }

    struct DailyForecast: Decodable {
        var name: String?
        var metadata: Metadata
        var days: [DayWeatherConditions]
        var learnMoreURL: String?
    }

    struct DayWeatherConditions: Decodable {
        var conditionCode: String
        var daytimeForecast: DayPartForecast?
        var forecastEnd: Date
        var forecastStart: Date
        var maxUvIndex: Int
        var moonPhase: String
        var moonrise: Date?
        var moonset: Date?
        var overnightForecast: DayPartForecast?
        var precipitationAmount: Double
        var precipitationChance: Double
        var precipitationType: String
        var snowfallAmount: Double
        var solarMidnight: Date?
        var solarNoon: Date?
        var sunrise: Date?
        var sunriseAstronomical: Date?
        var sunriseCivil: Date?
        var sunriseNautical: Date?
        var sunset: Date?
        var sunsetAstronomical: Date?
        var sunsetCivil: Date?
        var sunsetNautical: Date?
        var temperatureMax: Double
        var temperatureMin: Double
    }

    struct DayPartForecast: Decodable {
        var cloudCover: Double
        var conditionCode: String
        var forecastEnd: Date
        var forecastStart: Date
        var humidity: Double
        var precipitationAmount: Double
        var precipitationChance: Double
        var precipitationType: String
        var snowfallAmount: Double
        var windDirection: Double?
        var windSpeed: Double
    }

    struct NextHourForecast: Decodable {
        var name: String?
        var metadata: Metadata
        var forecastEnd: Date?
        var forecastStart: Date?
        var minutes: [ForecastMinute]
        var summary: [ForecastPeriodSummary]
    }

    struct ForecastMinute: Decodable {
        var precipitationChance: Double
        var precipitationIntensity: Double
        var startTime: Date
    }

    struct ForecastPeriodSummary: Decodable {
        var condition: String
        var endTime: Date?
        var precipitationChance: Double
        var precipitationIntensity: Double
        var startTime: Date
    }

    struct WeatherAlertCollection: Decodable {
        var name: String?
        var metadata: Metadata
        var alerts: [WeatherAlertSummary]
        var detailsUrl: String?
    }

    struct WeatherAlertSummary: Decodable {
        var areaId: String?
        var areaName: String?
        var certainty: String
        var countryCode: String
        var description: String
        var detailsUrl: String?
        var effectiveTime: Date
        var eventEndTime: Date?
        var eventOnsetTime: Date?
        var expireTime: Date
        var id: UUID
        var issuedTime: Date
        var responses: [String]
        var severity: String
        var source: String
        var urgency: String?
    }

    struct Attribution: Decodable {
        var serviceName: String?
        var logoLight1x: String?
        var logoLight2x: String?
        var logoLight3x: String?
        var logoDark1x: String?
        var logoDark2x: String?
        var logoDark3x: String?
        var logoSquare1x: String?
        var logoSquare2x: String?
        var logoSquare3x: String?

        enum CodingKeys: String, CodingKey {
            case serviceName
            case logoLight1x = "logoLight@1x"
            case logoLight2x = "logoLight@2x"
            case logoLight3x = "logoLight@3x"
            case logoDark1x = "logoDark@1x"
            case logoDark2x = "logoDark@2x"
            case logoDark3x = "logoDark@3x"
            case logoSquare1x = "logoSquare@1x"
            case logoSquare2x = "logoSquare@2x"
            case logoSquare3x = "logoSquare@3x"
        }
    }

    /// ISO 8601 date-times, with or without fractional seconds.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 date: \(text)")
        }
        return decoder
    }
}
