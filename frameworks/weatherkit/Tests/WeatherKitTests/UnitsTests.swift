// Units (api.md §6): values arrive in the REST API's metric units, as
// Foundation Measurements that convert correctly.
import Foundation
import Testing
@testable import WeatherKit

@Suite("Units (api.md §6)")
struct UnitsTests {
    @Test("api.md §6: °C, km/h, degrees, mbar, m, mm and mm/h")
    func metricUnits() throws {
        let weather = try fixtureWeather()
        let current = weather.currentWeather
        #expect(current.temperature.unit.symbol == "°C")
        #expect(current.dewPoint.unit.symbol == "°C")
        #expect(current.wind.speed.unit.symbol == "km/h")
        #expect(current.wind.direction.unit.symbol == "°")
        #expect(current.pressure.unit.symbol == "mbar")
        #expect(current.visibility.unit.symbol == "m")
        #expect(current.precipitationIntensity.unit.symbol == "mm/h")
        let hour = try #require(weather.hourlyForecast.first)
        #expect(hour.precipitationAmount.unit.symbol == "mm")
        #expect(weather.minuteForecast?.first?.precipitationIntensity.unit.symbol == "mm/h")
    }

    @Test("api.md §6: decoded units convert like Foundation's own")
    func conversions() throws {
        let weather = try fixtureWeather()
        let temperature = weather.currentWeather.temperature
        let fahrenheit = temperature.converted(to: .fahrenheit).value
        #expect(abs(fahrenheit - (temperature.value * 9 / 5 + 32)) < 1e-9)
        let speed = weather.currentWeather.wind.speed
        #expect(abs(speed.converted(to: .metersPerSecond).value - speed.value / 3.6) < 1e-3)
        #expect(speed == Measurement(value: speed.value, unit: UnitSpeed.kilometersPerHour))
        let snowy = try #require(weather.minuteForecast?.first { $0.precipitation == .snow })
        // 0.4 mm/h in metres per second.
        #expect(abs(snowy.precipitationIntensity.converted(to: .metersPerSecond).value - 0.4 / 3_600_000) < 1e-15)
        let ycodeUnit = Measurement(value: 0.4, unit: WeatherUnits.millimetersPerHour)
        #expect(ycodeUnit == snowy.precipitationIntensity)
        #expect(try jsonObject(ycodeUnit)["unit"] as? NSDictionary
            == (try jsonObject(snowy.precipitationIntensity)["unit"] as? NSDictionary))
    }
}
