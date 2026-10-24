# ycode-weatherkit

An open, Linux-buildable **WeatherKit**, written in the clean room from
`specs/frameworks/weatherkit/` (rounds R2, R3 and R4 of `plan.md`). It contains
no Apple code, resources or SDK declarations; public names come from the
spec's API inventory (`api.md`), archive keys from `codable.md`, behavior
from `behavior.md`, design from `design.md`.

```swift
import CoreLocation   // the system framework on Apple platforms, this package's shim on Linux
import WeatherKit     // this package

let service = WeatherService(backend: try FixtureWeatherBackend.bundled())
let (current, daily) = try await service.weather(
    for: CLLocation(latitude: 41.5, longitude: -81.5), including: .current, .daily)
print(current.condition, daily.count)
```

## Status

| Round | Scope | State |
|---|---|---|
| R2 | Model: every type of `api.md` with storage; `Codable` exactly as `codable.md` (non-public keys decoded, kept, written back); enums with descriptions, accessibility descriptions, symbol names, abbreviations, UV ranges; units; attribution; `WeatherError`; Linux `CoreLocation` shim | done |
| R3 | Service engine: query planner (one backend request per call, tuple overloads 1–6 and parameter packs, statistics and summaries), cache keyed by product + range + coordinate rounded to 3 decimals + language, expiry, no stale fallback, coalescing of in-flight requests, optional persistent store, error mapping, cancellation, attribution caching; fixture backend with bundled made-up data | done |
| R4 | Apple REST backend on the documented v1 API: ES256 developer tokens (swift-crypto), token providers (static token, local `.p8` key, remote token URL), `/api/v1/weather`, `/attribution`, REST → model mapping (`rest-api.md` §5–§6) | done; W-REST (owner key) not run |
| R5–R8 | Open backends, derivations, statistics from archives, guest drop-in | not started |

## Package layout

| Path | Content |
|---|---|
| `Sources/WeatherKit/Model/` | Model types and their archive form (R2) |
| `Sources/WeatherKit/Service/` | `WeatherService`, queries, backend interface, engine (R3) |
| `Sources/WeatherKit/Fixtures/` | `FixtureWeatherBackend` |
| `Sources/WeatherKit/AppleREST/` | `AppleRESTWeatherBackend`, developer tokens, HTTP transport (R4) |
| `Sources/WeatherKit/Resources/Fixtures/default/` | the bundled fixture set (generated) |
| `Sources/CoreLocation/` | the Linux-only Core Location shim |
| `Scripts/generate-fixtures.py` | writes the bundled fixture set (`python3 -I Scripts/generate-fixtures.py`) |
| `Tests/WeatherKitTests/` | conformance tests; each names the spec section it checks |

Deviation from `design.md` §2: one `WeatherKit` module holds the model, the
engine, the fixture backend and the Apple REST backend instead of separate
`WeatherKitCore`, `WeatherKitFixtures` and `WeatherKitAppleREST` modules,
because `WeatherService.shared` selects backends from the environment and a
split would create a dependency cycle. The cost is that `WeatherKit` links
swift-crypto.

## Module names on macOS and Linux

- The library module is named `WeatherKit` (an interop identifier). Inside a
  build of this package, SwiftPM's module search path takes precedence over
  the SDK, so `import WeatherKit` resolves to this package on macOS too; no
  workaround was needed. An Apple-platform target cannot link this package
  and Apple's WeatherKit at the same time.
- `CoreLocation` (the shim) is declared only when the manifest is evaluated on
  a non-Apple host (`#if os(Linux) …` in `Package.swift`), so it never
  shadows the system framework on macOS. It provides only what the WeatherKit
  API needs: `CLLocation` (with the members of `location.md` §1),
  `CLLocationCoordinate2D`, the `CLLocation…` scalar typealiases,
  `CLFloor`, `CLLocationSourceInformation`, `CLLocationCoordinate2DIsValid`,
  `CLLocationCoordinate2DMake`, `kCLLocationCoordinate2DInvalid`,
  `kCLDistanceFilterNone`, `kCLLocationAccuracyBest`. No location manager,
  authorization or geocoding (future Core Location spec). Ycode choices:
  `init(latitude:longitude:)` sets horizontal accuracy 0 and every other
  accuracy and motion value to −1; `distance(from:)` is haversine on the
  mean Earth radius.

## Backends (Ycode extension)

`WeatherService(backend:configuration:)` takes any `WeatherBackend`.
`WeatherService.shared` and `WeatherService()` choose from the environment:

| `WEATHERKIT_BACKEND` | Backend |
|---|---|
| `fixtures` | `FixtureWeatherBackend`: the bundled set, or the directory in `WEATHERKIT_FIXTURES` |
| `apple-rest` | `AppleRESTWeatherBackend` with a token from `WEATHERKIT_TOKEN`, or from the URL in `WEATHERKIT_TOKEN_URL`, or signed locally with the `.p8` key in `WEATHERKIT_KEY_FILE` for `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`, `WEATHERKIT_KEY_ID` |
| unset, `apple-rest` without credentials, or a backend not in this build (`open-meteo`, …) | `UnconfiguredWeatherBackend`: every call throws `WeatherError.permissionDenied` |

`WeatherService.Configuration` sets the language (default: the process's
preferred language in `en-US` form), an optional cache directory (the
persistent store; default memory only) and the clock.

### Fixture sets

A fixture set is a directory with `fixture.json` (manifest), a `Weather`
archive, a `WeatherAttribution` archive and optional product files
(historical comparisons, statistics, summaries). The format of every file is
the `Codable` archive of `codable.md`; dates may be ISO 8601 strings or
numbers. With `"rebase": "days"` (the default) dates move by whole days so
that the set's anchor day is the request's day, and the minute forecast
starts at the request's minute. Every product's metadata gets the request
coordinate, `date` = request time and `expirationDate` = request time + the
manifest's expiration for the product. Hourly and daily forecasts without a
range start at the current hour / day; with a range they hold the elements
whose start lies in `[start, end)`. See the header of
`FixtureWeatherBackend.swift` for the manifest keys.

The bundled set (`Resources/Fixtures/default`) is made up by
`Scripts/generate-fixtures.py`: smooth curves and fixed patterns around an
anchor of 2026-01-15T12:00Z, attributed to "Fixture data" with
`fixtures.invalid` URLs. It describes no real place.

### Apple REST backend

Uses only the documented v1 API with the developer's own credentials, which
come from run-time configuration; the package ships none and the tests use a
scripted transport. One service call is one `GET /api/v1/weather/…` with the
needed `dataSets` (`availability` adds `forecastNextHour` and
`weatherAlerts` and is derived from their presence and
`temporarilyUnavailable` flags); the only exception is a call that asks for
the same product with two different ranges, which needs one request per
range. Ranges go out as ISO 8601 UTC with seconds. The time zone and country
come from a `locationContext` closure; until the offline resolver of
`design.md` §4 exists (R5) the default is the process's time zone and no
country. `weatherChanges` and `historicalComparisons` are not in v1 and come
back nil; statistics and summaries throw (→ `WeatherError.unknown`). HTTP 401
and 403 become `WeatherError.permissionDenied`, other statuses and unreadable
bodies `WeatherError.unknown`; `URLError`s pass through.

Mapping (`rest-api.md` §6): `conditionCode` UpperCamelCase → the
lowerCamelCase case (unknown codes fall back by keyword); `clear` → `none`,
`precipitation` → `rain`; `thirdQuarter` → `lastQuarter`; metric units as
delivered, intensities in a `mm/h` `UnitSpeed`. Swift fields v1 does not
document get Ycode values: cloud cover by altitude 0; visibility extremes 0;
day-level humidity and wind from the day parts; day parts synthesized from
the day (07:00–19:00 and 19:00–07:00 after `forecastStart`) when absent; the
hour's dew point from temperature and humidity (Magnus) when absent; the
hour's snowfall from `snowfallIntensity` × 1 h; the minute summary sentence
written by Ycode ("Snow starting in 20 min."); symbol names from Ycode's
condition × daylight table; alert details link falls back to the collection's
`detailsUrl`, then the alert endpoint. The legal page is
`<base>/legal-attribution.html` and the marks are the `@3x` logos (relative
paths resolved against the base URL).

## Defaults for non-public archive keys

`codable.md` requires some non-public keys that a backend may have no value
for. Until the owner-run W-DATA check shows real values (`plan.md` R0b),
Ycode writes: `airQualityAvailability` = `unknown`; intensity objects =
`{"category": "none", "value": 0}`; zero amounts (millimetres) for the past/next
amounts and amount-by-type objects. Non-public values whose format the spec
leaves open (`minuteSummaries[].precipitationKind`, `minuteConditions[].shift.kind`,
other products of `Weather`) are kept as opaque values and written back
unchanged by the same coder.

## Tests

`swift test` runs the conformance tests of `plan.md` §2 that apply to R2–R3:

| Suite | Spec |
|---|---|
| C-CODABLE | `codable.md` §1–§5: exact key sets of every type, required vs optional keys, Measurement/date/URL/enum forms, non-public keys preserved, lossless round trips |
| C-ENUM | `api.md` §3.8, `behavior.md` §6: raw values, labels, accessibility labels, symbol names, abbreviations, UV ranges |
| C-API | `api.md`: every public member with its type, every call shape (tuples 1–6, packs, statistics), `WeatherError` bridging |
| C-QUERY | `behavior.md` §1–§2: products per query, one request per call, ranges, zero-length ranges, reversed ranges trap (exit tests), coordinate rounding |
| C-CACHE | `behavior.md` §3, `design.md` §6: hits before expiry, refetch after, no stale fallback, coalescing, partial hits, key parts, persistence |
| C-ERRORS | `behavior.md` §4–§5: 401/403 → `permissionDenied`, other failures → `unknown`, `URLError` passed through, cancellation |
| C-JWT | `rest-api.md` §2: header and claim sets, base64url, ES256 signature verified with swift-crypto and with the `openssl` tool when installed; token providers |
| Apple REST backend | `rest-api.md` §1–§6: request shape, range parameters, availability, mapping of every documented object, attribution, status codes, cache by `expireTime` |
| Units, fixture backend, CoreLocation shim | `api.md` §6, `design.md` §2–§3 |

The reference goldens (W-CODABLE, W-DATA) and W-REST come from the owner's
entitled run and key and are not available to the clean room; C-CODABLE
checks against the `codable.md` tables instead, and the REST tests use a
response we wrote from `rest-api.md` §4. No test touches the network.

## Dependencies

Pinned to exact releases (`Package.swift`, `Package.resolved`):

| Package | Version | Licence | Used for |
|---|---|---|---|
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache-2.0 | P-256 ECDSA (ES256) developer tokens |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 (via swift-crypto) | Apache-2.0 | PEM/DER key encoding |

Otherwise only the Swift toolchain (Foundation, FoundationNetworking on
Linux, Swift Testing).
