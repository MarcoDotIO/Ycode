// C-ENUM (plan.md §2): raw values, descriptions, accessibility descriptions,
// symbol names, abbreviations and UV ranges against api.md §3.8 and the
// English output of behavior.md §6.
import Foundation
import Testing
@testable import WeatherKit

@Suite("C-ENUM: enumerations (api.md §3.8, behavior.md §6)")
struct EnumTests {
    @Test("api.md §3.8: WeatherCondition has the 34 cases; behavior.md §6 labels")
    func weatherCondition() {
        let expected: [(WeatherCondition, String)] = [
            (.blizzard, "Blizzard"), (.blowingDust, "Dust"), (.blowingSnow, "Blowing Snow"), (.breezy, "Breezy"),
            (.clear, "Clear"), (.cloudy, "Cloudy"), (.drizzle, "Drizzle"), (.flurries, "Flurries"), (.foggy, "Fog"),
            (.freezingDrizzle, "Freezing Drizzle"), (.freezingRain, "Freezing Rain"), (.frigid, "Cold"),
            (.hail, "Hail"), (.haze, "Haze"), (.heavyRain, "Heavy Rain"), (.heavySnow, "Heavy Snow"), (.hot, "Hot"),
            (.hurricane, "Hurricane"), (.isolatedThunderstorms, "Isolated Thunderstorms"),
            (.mostlyClear, "Mostly Clear"), (.mostlyCloudy, "Mostly Cloudy"), (.partlyCloudy, "Partly Cloudy"),
            (.rain, "Rain"), (.scatteredThunderstorms, "Scattered Thunderstorms"), (.sleet, "Sleet"),
            (.smoky, "Smoke"), (.snow, "Snow"), (.strongStorms, "Severe Thunderstorm"), (.sunFlurries, "Sun Flurries"),
            (.sunShowers, "Sun Showers"), (.thunderstorms, "Thunderstorm"), (.tropicalStorm, "Tropical Storm"),
            (.windy, "Windy"), (.wintryMix, "Wintry Mix"),
        ]
        #expect(WeatherCondition.allCases.count == 34)
        #expect(WeatherCondition.allCases == expected.map(\.0))
        for (condition, label) in expected {
            #expect(condition.description == label)
            #expect(condition.accessibilityDescription == label.lowercased())
            #expect(WeatherCondition(rawValue: condition.rawValue) == condition)
        }
        #expect(WeatherCondition.allCases.map(\.rawValue) == [
            "blizzard", "blowingDust", "blowingSnow", "breezy", "clear", "cloudy", "drizzle", "flurries", "foggy",
            "freezingDrizzle", "freezingRain", "frigid", "hail", "haze", "heavyRain", "heavySnow", "hot", "hurricane",
            "isolatedThunderstorms", "mostlyClear", "mostlyCloudy", "partlyCloudy", "rain", "scatteredThunderstorms",
            "sleet", "smoky", "snow", "strongStorms", "sunFlurries", "sunShowers", "thunderstorms", "tropicalStorm",
            "windy", "wintryMix",
        ])
    }

    @Test("behavior.md §6: Precipitation is lower case, mixed reads 'wintry mix', none is empty")
    func precipitation() {
        let expected: [(Precipitation, String)] = [
            (.none, ""), (.hail, "hail"), (.mixed, "wintry mix"), (.rain, "rain"), (.sleet, "sleet"), (.snow, "snow"),
        ]
        #expect(Precipitation.allCases == expected.map(\.0))
        for (value, label) in expected {
            #expect(value.description == label)
            #expect(value.accessibilityDescription == label)
        }
        #expect(Precipitation.allCases.map(\.rawValue) == ["none", "hail", "mixed", "rain", "sleet", "snow"])
    }

    @Test("behavior.md §6: PressureTrend labels")
    func pressureTrend() {
        #expect(PressureTrend.allCases.map(\.rawValue) == ["rising", "falling", "steady"])
        #expect(PressureTrend.allCases.map(\.description) == ["Rising", "Falling", "Steady"])
        #expect(PressureTrend.allCases.map(\.accessibilityDescription) == ["Rising", "Falling", "Steady"])
    }

    @Test("behavior.md §6: WeatherSeverity labels are the case names")
    func severity() {
        #expect(WeatherSeverity.allCases.map(\.rawValue) == ["minor", "moderate", "severe", "extreme", "unknown"])
        for severity in WeatherSeverity.allCases {
            #expect(severity.description == severity.rawValue)
            #expect(severity.accessibilityDescription == severity.rawValue)
        }
    }

    @Test("behavior.md §6: MoonPhase labels and moonphase.* symbol names")
    func moonPhase() {
        let expected: [(MoonPhase, String, String)] = [
            (.new, "New Moon", "moonphase.new.moon"),
            (.waxingCrescent, "Waxing Crescent", "moonphase.waxing.crescent"),
            (.firstQuarter, "First Quarter", "moonphase.first.quarter"),
            (.waxingGibbous, "Waxing Gibbous", "moonphase.waxing.gibbous"),
            (.full, "Full Moon", "moonphase.full.moon"),
            (.waningGibbous, "Waning Gibbous", "moonphase.waning.gibbous"),
            (.lastQuarter, "Last Quarter", "moonphase.last.quarter"),
            (.waningCrescent, "Waning Crescent", "moonphase.waning.crescent"),
        ]
        #expect(MoonPhase.allCases == expected.map(\.0))
        for (phase, label, symbol) in expected {
            #expect(phase.description == label)
            #expect(phase.accessibilityDescription == label)
            #expect(phase.symbolName == symbol)
        }
    }

    @Test("behavior.md §6: Wind.CompassDirection labels and abbreviations")
    func compass() {
        let expected: [(Wind.CompassDirection, String, String)] = [
            (.north, "North", "N"), (.northNortheast, "North Northeast", "NNE"), (.northeast, "Northeast", "NE"),
            (.eastNortheast, "East Northeast", "ENE"), (.east, "East", "E"), (.eastSoutheast, "East Southeast", "ESE"),
            (.southeast, "Southeast", "SE"), (.southSoutheast, "South Southeast", "SSE"), (.south, "South", "S"),
            (.southSouthwest, "South Southwest", "SSW"), (.southwest, "Southwest", "SW"),
            (.westSouthwest, "West Southwest", "WSW"), (.west, "West", "W"), (.westNorthwest, "West Northwest", "WNW"),
            (.northwest, "Northwest", "NW"), (.northNorthwest, "North Northwest", "NNW"),
        ]
        #expect(Wind.CompassDirection.allCases == expected.map(\.0))
        for (direction, label, abbreviation) in expected {
            #expect(direction.description == label)
            #expect(direction.accessibilityDescription == label)
            #expect(direction.abbreviation == abbreviation)
        }
    }

    @Test("design.md §5: 16 compass sectors of 22.5° centred on north")
    func compassSectors() {
        #expect(Wind.CompassDirection.from(degrees: 0) == .north)
        #expect(Wind.CompassDirection.from(degrees: 11.24) == .north)
        #expect(Wind.CompassDirection.from(degrees: 11.25) == .northNortheast)
        #expect(Wind.CompassDirection.from(degrees: 90) == .east)
        #expect(Wind.CompassDirection.from(degrees: 348.75) == .north)
        #expect(Wind.CompassDirection.from(degrees: 348.74) == .northNorthwest)
        #expect(Wind.CompassDirection.from(degrees: -90) == .west)
        #expect(Wind.CompassDirection.from(degrees: 720 + 180) == .south)
    }

    @Test("api.md §3.8: UV exposure categories, ranges, order and labels")
    func uvCategories() {
        let expected: [(UVIndex.ExposureCategory, ClosedRange<Int>, String)] = [
            (.low, 0...2, "Low"), (.moderate, 3...5, "Moderate"), (.high, 6...7, "High"),
            (.veryHigh, 8...10, "Very High"), (.extreme, 11...Int.max, "Extreme"),
        ]
        #expect(UVIndex.ExposureCategory.allCases == expected.map(\.0))
        for (category, range, label) in expected {
            #expect(category.rangeValue == range)
            #expect(category.description == label)
        }
        #expect(UVIndex.ExposureCategory.low < .moderate)
        #expect(UVIndex.ExposureCategory.veryHigh < .extreme)
        #expect(!(UVIndex.ExposureCategory.extreme < .high))
        #expect(UVIndex.ExposureCategory.allCases.sorted() == UVIndex.ExposureCategory.allCases)
        #expect(UVIndex(value: 7).category == .high)
        #expect(UVIndex(value: 11).category == .extreme)
    }

    @Test("api.md §3.1: AvailabilityKind raw values")
    func availabilityKind() {
        let values: [WeatherAvailability.AvailabilityKind] = [.available, .temporarilyUnavailable, .unsupported, .unknown]
        #expect(values.map(\.rawValue) == ["available", "temporarilyUnavailable", "unsupported", "unknown"])
    }

    @Test("api.md §3.10: change directions, deviations and baseline kinds")
    func payloadFreeEnums() throws {
        let directions: [WeatherChange.Direction] = [.increase, .decrease, .steady]
        let deviations: [Deviation] = [.muchHigher, .higher, .normal, .lower, .muchLower]
        #expect(String(decoding: try encode(directions), as: UTF8.self) == #"[{"increase":{}},{"decrease":{}},{"steady":{}}]"#)
        #expect(String(decoding: try encode(deviations), as: UTF8.self)
            == #"[{"muchHigher":{}},{"higher":{}},{"normal":{}},{"lower":{}},{"muchLower":{}}]"#)
        #expect(String(decoding: try encode([TrendBaseline<UnitTemperature>.Kind.mean]), as: UTF8.self) == #"[{"mean":{}}]"#)
    }
}
