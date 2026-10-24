#!/usr/bin/env python3
"""Writes the bundled fixture set of ycode-weatherkit.

All values are made up by this script (smooth curves and fixed patterns);
they describe no real place or time. The files follow the Codable archive
format of specs/frameworks/weatherkit/codable.md, with dates as ISO 8601
strings (the fixture backend accepts those and numbers).

Usage (from the package directory):
    python3 -I Scripts/generate-fixtures.py
"""
import json
import math
import os
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Sources", "WeatherKit", "Resources", "Fixtures", "default")

ANCHOR = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
DAY0 = datetime(2026, 1, 15, 0, 0, 0, tzinfo=timezone.utc)
LAT, LON = 41.5, -81.5


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


# Foundation's Measurement archive form: unit symbol and linear converter
# to the dimension's base unit.
def m(value, symbol, coefficient, constant=0):
    return {"value": round(value, 3), "unit": {"symbol": symbol, "converter": {"coefficient": coefficient, "constant": constant}}}


def celsius(v):
    return m(v, "°C", 1, 273.15)


def kmh(v):
    return m(v, "km/h", 0.277778)


def mmh(v):
    return m(v, "mm/h", 2.7777777777777776e-07)


def mbar(v):
    return m(v, "mbar", 100)


def meters(v):
    return m(v, "m", 1)


def mm(v):
    return m(v, "mm", 0.001)


def degrees(v):
    return m(v, "°", 1)


COMPASS = ["north", "northNortheast", "northeast", "eastNortheast", "east", "eastSoutheast", "southeast",
           "southSoutheast", "south", "southSouthwest", "southwest", "westSouthwest", "west", "westNorthwest",
           "northwest", "northNorthwest"]


def compass(deg):
    return COMPASS[int(round((deg % 360) / 22.5)) % 16]


def uv(value):
    for name, low, high in [("low", 0, 2), ("moderate", 3, 5), ("high", 6, 7), ("veryHigh", 8, 10)]:
        if low <= value <= high:
            return {"value": value, "category": name}
    return {"value": value, "category": "extreme"}


def wind(deg, speed, gust):
    w = {"compassDirection": compass(deg), "direction": degrees(deg), "speed": kmh(speed)}
    if gust is not None:
        w["gust"] = kmh(gust)
    return w


def intensity(value):
    category = "none" if value == 0 else ("light" if value < 2.5 else "moderate")
    return {"category": category, "value": value}


def snowfall(amount):
    return {"amount": mm(amount), "maximum": mm(amount * 1.5), "minimum": mm(amount * 0.5),
            "amountLiquidEquivalent": mm(amount / 10), "maximumLiquidEquivalent": mm(amount * 0.15),
            "minimumLiquidEquivalent": mm(amount * 0.05)}


def by_type(rain, snow=0.0):
    return {"hail": mm(0), "mixed": mm(0), "rainfall": mm(rain), "sleet": mm(0),
            "precipitation": mm(rain + snow / 10), "snowfallAmount": snowfall(snow)}


def metadata(date, expires):
    return {"date": iso(date), "expirationDate": iso(expires), "latitude": LAT, "longitude": LON}


def temperature_at(t):
    hours = (t - DAY0).total_seconds() / 3600
    return -2 + 6 * math.sin((hours - 9) / 24 * 2 * math.pi) + 0.2 * (hours / 24)


def is_daylight(t):
    return 8 <= t.hour < 17


def condition_at(t):
    day = (t - DAY0).days
    cycle = ["partlyCloudy", "mostlyCloudy", "snow", "flurries", "cloudy", "mostlyClear", "clear", "rain", "drizzle",
             "breezy"]
    return cycle[day % len(cycle)]


SYMBOLS = {
    ("clear", True): "sun.max", ("clear", False): "moon.stars",
    ("mostlyClear", True): "sun.min", ("mostlyClear", False): "moon",
    ("partlyCloudy", True): "cloud.sun", ("partlyCloudy", False): "cloud.moon",
    ("mostlyCloudy", True): "cloud", ("mostlyCloudy", False): "cloud",
    ("cloudy", True): "cloud", ("cloudy", False): "cloud",
    ("snow", True): "cloud.snow", ("snow", False): "cloud.snow",
    ("flurries", True): "cloud.snow", ("flurries", False): "cloud.snow",
    ("rain", True): "cloud.rain", ("rain", False): "cloud.rain",
    ("drizzle", True): "cloud.drizzle", ("drizzle", False): "cloud.drizzle",
    ("breezy", True): "wind", ("breezy", False): "wind",
}


def precipitation_kind(cond):
    if cond in ("snow", "flurries"):
        return "snow"
    if cond in ("rain", "drizzle"):
        return "rain"
    return "none"


def hour(t):
    cond = condition_at(t)
    day = is_daylight(t)
    temp = temperature_at(t)
    kind = precipitation_kind(cond)
    amount = {"snow": 0.4, "rain": 1.2, "none": 0.0}[kind]
    deg = (200 + 7 * ((t - DAY0).total_seconds() / 3600)) % 360
    cloud = {"clear": 0.05, "mostlyClear": 0.2, "partlyCloudy": 0.45}.get(cond, 0.85)
    return {
        "date": iso(t), "cloudCover": cloud,
        "cloudCoverByAltitude": {"low": round(cloud * 0.6, 3), "medium": round(cloud * 0.3, 3), "high": round(cloud * 0.1, 3)},
        "cloudCoverLow": round(cloud * 0.6, 3), "cloudCoverMid": round(cloud * 0.3, 3), "cloudCoverHigh": round(cloud * 0.1, 3),
        "condition": cond, "symbolName": SYMBOLS[(cond, day)], "dewPoint": celsius(temp - 4), "humidity": 0.72,
        "isDaylight": day, "precipitation": kind, "precipitationAmount": mm(amount if kind == "rain" else amount / 10),
        "precipitationChance": 0.7 if kind != "none" else 0.1, "snowfallAmount": mm(amount * 10 if kind == "snow" else 0),
        "pressure": mbar(1016 - 0.05 * ((t - DAY0).total_seconds() / 3600)), "pressureTrend": "falling",
        "temperature": celsius(temp), "apparentTemperature": celsius(temp - 3), "uvIndex": uv(2 if day else 0),
        "visibility": meters(16000 if kind == "none" else 6000), "wind": wind(deg, 14, 25),
        "apparentPrecipitationIntensity": intensity(amount),
    }


def day_part(start, end, cond, high, low, rain, snow):
    return {
        "forecastStart": iso(start), "forecastEnd": iso(end), "cloudCover": 0.6,
        "cloudCoverByAltitude": {"low": 0.4, "medium": 0.15, "high": 0.05}, "condition": cond,
        "highTemperature": celsius(high), "lowTemperature": celsius(low), "humidity": 0.7,
        "maximumHumidity": 0.85, "minimumHumidity": 0.6, "isDaylight": start.hour == 7,
        "maximumVisibility": meters(16000), "minimumVisibility": meters(5000),
        "maximumUVIndex": uv(2), "minimumUVIndex": uv(0), "precipitation": precipitation_kind(cond),
        "precipitationAmountByType": by_type(rain, snow), "precipitationChance": 0.5 if rain or snow else 0.1,
        "precipitationIntensityMax": intensity(rain), "perceivedPrecipitationIntensityMax": intensity(rain),
        "wind": wind(230, 15, 28), "highWindSpeed": kmh(30),
    }


MOON = ["waningCrescent", "new", "waxingCrescent", "waxingCrescent", "firstQuarter", "waxingGibbous", "waxingGibbous",
        "full", "waningGibbous", "lastQuarter"]


def day(i):
    start = DAY0 + timedelta(days=i)
    cond = condition_at(start)
    temps = [temperature_at(start + timedelta(hours=h)) for h in range(24)]
    high, low = max(temps), min(temps)
    kind = precipitation_kind(cond)
    rain = 3.0 if kind == "rain" else 0.0
    snow = 40.0 if kind == "snow" else 0.0
    d = {
        "date": iso(start), "condition": cond, "symbolName": SYMBOLS[(cond, True)],
        "highTemperature": celsius(high), "lowTemperature": celsius(low),
        "highTemperatureTime": iso(start + timedelta(hours=15)), "lowTemperatureTime": iso(start + timedelta(hours=3)),
        "maximumHumidity": 0.9, "minimumHumidity": 0.55, "humidityMax": 0.9, "humidityMin": 0.55,
        "precipitation": kind, "precipitationChance": 0.6 if kind != "none" else 0.1,
        "precipitationAmountByType": by_type(rain, snow), "rainfallAmount": mm(rain), "snowfallAmount": mm(snow),
        "sun": {
            "astronomicalDawn": iso(start + timedelta(hours=6, minutes=10)),
            "nauticalDawn": iso(start + timedelta(hours=6, minutes=44)),
            "civilDawn": iso(start + timedelta(hours=7, minutes=18)),
            "sunrise": iso(start + timedelta(hours=7, minutes=50)),
            "solarNoon": iso(start + timedelta(hours=12, minutes=26)),
            "sunset": iso(start + timedelta(hours=17, minutes=2)),
            "civilDusk": iso(start + timedelta(hours=17, minutes=34)),
            "nauticalDusk": iso(start + timedelta(hours=18, minutes=8)),
            "astronomicalDusk": iso(start + timedelta(hours=18, minutes=42)),
            "solarMidnight": iso(start + timedelta(hours=24, minutes=26)),
        },
        "moon": {"phase": MOON[i % len(MOON)], "moonrise": iso(start + timedelta(hours=9 + i % 12)),
                 "moonset": iso(start + timedelta(hours=20 + i % 4))},
        "uvIndex": uv(2), "wind": wind(220 + 10 * i, 16, 30),
        "maximumVisibility": 16000.0, "minimumVisibility": 4000.0, "visibilityMax": 16000.0, "visibilityMin": 4000.0,
        "highWindSpeed": kmh(32), "windSpeedAvg": kmh(16), "windSpeedMax": kmh(32), "windGustSpeedMax": kmh(45),
        "daytimeForecast": day_part(start + timedelta(hours=7), start + timedelta(hours=19), cond, high, low + 2, rain / 2, snow / 2),
        "overnightForecast": day_part(start + timedelta(hours=19), start + timedelta(hours=31), cond, high - 2, low, rain / 2, snow / 2),
    }
    if i == 0:
        d["restOfDayForecast"] = day_part(ANCHOR, start + timedelta(hours=24), cond, high, low, rain / 2, snow / 2)
    return d


def current():
    t = ANCHOR
    h = hour(t)
    zero_periods = {k: mm(0.2 * n) for n, k in enumerate(
        ["pastHour", "pastSixHours", "pastTwentyFourHours", "nextHour", "nextSixHours", "nextTwentyFourHours"])}
    return {
        "date": iso(t), "cloudCover": h["cloudCover"], "cloudCoverByAltitude": h["cloudCoverByAltitude"],
        "cloudCoverLow": h["cloudCoverLow"], "cloudCoverMid": h["cloudCoverMid"], "cloudCoverHigh": h["cloudCoverHigh"],
        "condition": h["condition"], "symbolName": h["symbolName"], "dewPoint": h["dewPoint"],
        "humidity": h["humidity"], "precipitationIntensity": mmh(0), "apparentPrecipitationIntensity": intensity(0),
        "pressure": h["pressure"], "pressureTrend": "falling", "isDaylight": True, "temperature": h["temperature"],
        "apparentTemperature": h["apparentTemperature"], "uvIndex": uv(2), "visibility": h["visibility"],
        "wind": h["wind"], "metadata": metadata(t, t + timedelta(minutes=10)),
        "highTemperature": celsius(4.1), "lowTemperature": celsius(-7.9),
        "rainfallAmount": zero_periods, "snowfallAmount": zero_periods,
        "pastHourPrecipitationAmountByType": by_type(0), "pastSixHoursPrecipitationAmountByType": by_type(0.2),
        "pastTwentyFourHoursPrecipitationAmountByType": by_type(0.4, 12),
        "nextHourPrecipitationAmountByType": by_type(0), "nextSixHoursPrecipitationAmountByType": by_type(0, 2),
        "nextTwentyFourHoursPrecipitationAmountByType": by_type(0, 8),
    }


def minutes():
    items = []
    for i in range(60):
        t = ANCHOR + timedelta(minutes=i)
        snowing = 25 <= i < 45
        items.append({"date": iso(t), "precipitation": "snow" if snowing else "none",
                      "precipitationChance": 0.6 if snowing else 0.05,
                      "precipitationIntensity": mmh(0.4 if snowing else 0),
                      "apparentPrecipitationIntensity": intensity(0.4 if snowing else 0)})
    return {
        "forecast": items, "metadata": metadata(ANCHOR, ANCHOR + timedelta(minutes=5)),
        "minuteSummary": "Light snow starting in 25 min.",
        "minuteSummaries": [
            {"date": iso(ANCHOR), "expirationDate": iso(ANCHOR + timedelta(minutes=25)), "precipitation": "none",
             "precipitationChance": 0.05, "precipitationKind": "none"},
            {"date": iso(ANCHOR + timedelta(minutes=25)), "precipitation": "snow", "precipitationChance": 0.6,
             "precipitationKind": "snow", "apparentPrecipitationIntensity": intensity(0.4)},
        ],
        "minuteConditions": [
            {"date": iso(ANCHOR), "expirationDate": iso(ANCHOR + timedelta(minutes=5)),
             "shortDescription": "Snow soon", "longDescription": "Light snow starting in 25 min.",
             "shift": {"date": iso(ANCHOR + timedelta(minutes=25)), "nextDate": iso(ANCHOR + timedelta(minutes=45)),
                       "kind": {"clear": {}}}},
        ],
    }


def alerts():
    return [{
        "summary": "Fixture Winter Weather Advisory", "source": "Ycode Fixture Weather Office",
        "region": "Fixture County", "severity": "moderate",
        "detailsURL": "https://fixtures.invalid/weatherkit/alerts/1",
        "metadata": metadata(ANCHOR, ANCHOR + timedelta(minutes=10)),
        "id": "6F1A2B3C-4D5E-4F60-8172-93A4B5C6D7E8", "importance": "normal",
        "description": "Made-up advisory for tests: light snow, slippery roads.",
        "details": "This alert is fixture data and describes no real event.",
        "date": iso(ANCHOR - timedelta(hours=2)), "issuedDate": iso(ANCHOR - timedelta(hours=2)),
        "onsetTime": iso(ANCHOR + timedelta(hours=1)), "endDate": iso(ANCHOR + timedelta(hours=20)),
        "expirationDate": iso(ANCHOR + timedelta(hours=20)),
    }]


def changes():
    directions = ["increase", "decrease", "steady"]
    items = []
    for i in range(1, 8):
        items.append({"date": iso(DAY0 + timedelta(days=i)),
                      "highTemperature": {directions[i % 3]: {}}, "lowTemperature": {directions[(i + 1) % 3]: {}},
                      "dayPrecipitationAmount": {directions[(i + 2) % 3]: {}},
                      "nightPrecipitationAmount": {"steady": {}}})
    return {"changes": items, "metadata": metadata(ANCHOR, ANCHOR + timedelta(hours=1))}


def trend(value, baseline, deviation, unit):
    return {"baseline": {"kind": {"mean": {}}, "value": unit(baseline), "startDate": "1991-01-01T00:00:00Z"},
            "currentValue": unit(value), "deviation": {deviation: {}}}


def comparisons():
    return {"comparisons": [
        {"highTemperature": {"_0": trend(4.1, 1.5, "higher", celsius)}},
        {"lowTemperature": {"_0": trend(-7.9, -6.0, "normal", celsius)}},
        {"precipitationAmount": {"_0": trend(3.0, 2.4, "normal", mm)}},
        {"snowfallAmount": {"_0": trend(52.0, 20.0, "muchHigher", mm)}},
    ], "metadata": metadata(ANCHOR, ANCHOR + timedelta(hours=6))}


def statistics():
    meta = metadata(ANCHOR, ANCHOR + timedelta(days=1))
    base = "1991-01-01T00:00:00Z"
    daily_t = {"baselineStartDate": base, "metadata": meta, "days": [
        {"day": d, "averageLowTemperature": celsius(-6 + 0.05 * d), "averageHighTemperature": celsius(1 + 0.05 * d)}
        for d in range(1, 32)]}
    daily_p = {"baselineStartDate": base, "metadata": meta, "days": [
        {"day": d, "averagePrecipitationProbability": round(0.3 + 0.01 * (d % 7), 3),
         "averagePrecipitationAmount": mm(2 + 0.1 * (d % 5)), "averageSnowfallAmount": mm(15 + d % 9)}
        for d in range(1, 32)]}
    hourly_t = {"baselineStartDate": base, "metadata": meta, "hours": [
        {"hour": h, "percentiles": {"p10": celsius(-9 + 0.1 * (h % 24)), "p50": celsius(-3 + 0.1 * (h % 24)),
                                    "p90": celsius(3 + 0.1 * (h % 24))}}
        for h in range(313, 361)]}
    monthly_t = {"baselineStartDate": base, "metadata": meta, "months": [
        {"month": mo, "averageLowTemperature": celsius(-6 + 12 * math.sin((mo - 4) / 12 * math.pi)),
         "averageHighTemperature": celsius(1 + 14 * math.sin((mo - 4) / 12 * math.pi))} for mo in range(1, 13)]}
    monthly_p = {"baselineStartDate": base, "metadata": meta, "months": [
        {"month": mo, "averagePrecipitationProbability": round(0.35 + 0.01 * mo, 3),
         "averagePrecipitationAmount": mm(70 + 3 * mo), "averageSnowfallAmount": mm(max(0, 300 - 60 * abs(mo - 1.5)))}
        for mo in range(1, 13)]}
    summary_t = {"metadata": meta, "days": [
        {"date": iso(DAY0 - timedelta(days=k)), "lowTemperature": celsius(-8 + k * 0.3),
         "highTemperature": celsius(2 - k * 0.2)} for k in range(7, 0, -1)]}
    summary_p = {"metadata": meta, "days": [
        {"date": iso(DAY0 - timedelta(days=k)), "precipitationAmount": mm(k % 3),
         "snowfallAmount": mm(10 * (k % 2))} for k in range(7, 0, -1)]}
    return {
        "daily-temperature-statistics.json": daily_t, "daily-precipitation-statistics.json": daily_p,
        "hourly-temperature-statistics.json": hourly_t, "monthly-temperature-statistics.json": monthly_t,
        "monthly-precipitation-statistics.json": monthly_p, "daily-temperature-summary.json": summary_t,
        "daily-precipitation-summary.json": summary_p,
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    files = {
        "fixture.json": {
            "name": "default", "anchorDate": iso(ANCHOR), "timeZone": "UTC", "rebase": "days",
            "defaultExpiration": 3600,
            "expiration": {"currentWeather": 600, "forecastNextHour": 300, "forecastHourly": 3600,
                           "forecastDaily": 3600, "weatherAlerts": 600, "availability": 3600,
                           "weatherChanges": 3600, "historicalComparisons": 21600},
            "weather": "weather.json", "attribution": "attribution.json",
            "legalAttributionText": "Fixture data\nMade-up weather values written by the Ycode project for tests and demos.\nNot a forecast for any real place.",
            "products": {
                "historicalComparisons": "historical-comparisons.json",
                "dailyTemperatureStatistics": "daily-temperature-statistics.json",
                "dailyPrecipitationStatistics": "daily-precipitation-statistics.json",
                "hourlyTemperatureStatistics": "hourly-temperature-statistics.json",
                "monthlyTemperatureStatistics": "monthly-temperature-statistics.json",
                "monthlyPrecipitationStatistics": "monthly-precipitation-statistics.json",
                "dailyTemperatureSummary": "daily-temperature-summary.json",
                "dailyPrecipitationSummary": "daily-precipitation-summary.json",
            },
        },
        "attribution.json": {"storage": {
            "serviceName": "Fixture data",
            "legalPageURL": "https://fixtures.invalid/weatherkit/legal-attribution.html",
            "squareMarkURL": "https://fixtures.invalid/weatherkit/square-mark.png",
            "combinedMarkLightURL": "https://fixtures.invalid/weatherkit/combined-mark-light.png",
            "combinedMarkDarkURL": "https://fixtures.invalid/weatherkit/combined-mark-dark.png",
        }},
        "weather.json": {
            "currentWeather": current(),
            "minuteForecast": minutes(),
            "hourlyForecast": {"forecast": [hour(DAY0 + timedelta(hours=h)) for h in range(72)],
                               "metadata": metadata(ANCHOR, ANCHOR + timedelta(hours=1))},
            "dailyForecast": {"forecast": [day(i) for i in range(10)],
                              "metadata": metadata(ANCHOR, ANCHOR + timedelta(hours=1))},
            "weatherAlerts": alerts(),
            "availability": {"minuteAvailability": "available", "alertAvailability": "available",
                             "airQualityAvailability": "unknown"},
            "weatherChanges": changes(),
        },
        "historical-comparisons.json": comparisons(),
    }
    files.update(statistics())
    for name, content in files.items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as handle:
            json.dump(content, handle, indent=1, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
    print(f"wrote {len(files)} files to {os.path.normpath(OUT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
