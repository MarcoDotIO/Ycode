# WeatherKit spec: design of an open implementation

Part of `specs/frameworks/weatherkit/`.

> **Ycode-original design note.** Nothing in this file describes Apple's
> implementation. It is our proposal for an open-source, Linux-buildable
> WeatherKit that is source-compatible with the API in `api.md`, and for how
> Ycode's simulator relates to it.

## 1. Goals and targets

1. **Open WeatherKit for Linux** (and macOS), a Swift package exposing module
   `WeatherKit` with the names, shapes and semantics of `api.md`, so that
   weather code from an iOS app compiles and runs on Linux.
2. **Simulator parity first**: in Ycode's iOS simulator, apps keep using
   **Apple's own** WeatherKit from the runtime; Ycode provides the services of
   `simulator-baseline.md` §6 and `location.md` §6. No replacement framework
   is needed for parity.
3. Optional later: a **guest drop-in** WeatherKit for Ycode's simulator with a
   fixture backend ("simulated weather"), for deterministic UI tests and for
   users without an Apple developer account (`plan.md` R8). It needs Swift
   ABI compatibility (same mangled names, resilient layouts), so it reuses
   target 1's source but is built against the simulator SDK.

Non-goals: Apple's private v2/v3 endpoints, FairPlay, or anything that
impersonates an Apple client. Only the documented REST API is used, and only
with the user's own key.

## 2. Package layout

| Module | Content | Depends on |
|---|---|---|
| `WeatherKit` | public API: `WeatherService`, queries, model, errors, attribution | `WeatherKitCore`, Foundation, `CoreLocation` shim on Linux |
| `WeatherKitCore` | `WeatherBackend` protocol, request planner, cache, coalescing, unit normalization, derivations (§5) | Foundation |
| `WeatherKitAppleREST` | v1 REST client, JWT signer, token providers | swift-crypto (Apache-2.0), AsyncHTTPClient or `URLSession` (FoundationNetworking) |
| `WeatherKitOpenMeteo`, `WeatherKitMETNorway`, `WeatherKitNWS` | open-data backends | Core |
| `WeatherKitFixtures` | backend that serves JSON fixtures (same JSON as `codable.md`) | Core |
| `CoreLocation` (Linux only, tiny) | `CLLocation`, `CLLocationCoordinate2D`, `CLLocationDistance` etc. — only what the API needs; shared with the future Core Location spec | Foundation |

Model values keep Foundation `Measurement` and must encode exactly as
`codable.md`. Public initializers stay non-public (parity), with an
`@_spi(Testing)` or package-level factory for backends.

## 3. Backends and their terms

A backend turns (coordinate, products, ranges, language, time zone,
country) into normalized product values plus an attribution.

| Backend | Coverage | Terms that bind us (level 1, provider pages read 2026-10-19) | Attribution our `attribution` returns |
|---|---|---|---|
| Apple REST (`rest-api.md`) | global; minute forecasts and alerts in select regions | user's **own** Team ID, Services ID and key; Apple's display rules (`behavior.md` §7); 500 000 calls/month included; private key never shipped in apps — support a token-server URL provider | Apple's values from `/attribution/{lang}` |
| Open-Meteo (api.open-meteo.com or self-hosted) | global forecasts, historical archive, climate statistics | data **CC BY 4.0**; the free API is for **non-commercial** use (< 10 000 calls/day, 5 000/hour, 600/min, 300 000/month); commercial use needs a paid plan or self-hosting; the server is **AGPL-3.0** — we call it over HTTP and never vendor its code | "Open-Meteo" + CC BY 4.0 notice and link, plus the national weather services it names |
| MET Norway (api.met.no) | global forecasts (best in Nordics) | data **CC BY 4.0** (and NLOD); identifying `User-Agent` with contact required; obey `Expires`/`If-Modified-Since`; ≤ 4 decimals in coordinates; ≤ 20 requests/s per application; no use of the Yr name/logo | "MET Norway" + licence link |
| US National Weather Service (api.weather.gov) | United States forecasts and **alerts** | free to use for any purpose; identifying `User-Agent` required; unpublished rate limits | "National Weather Service" |
| Fixtures | anything | ours | "Fixture data" |

Selection: by configuration (`WEATHERKIT_BACKEND=apple-rest|open-meteo|met-norway|fixtures`,
or an API for programmatic choice) with a composite backend that fills gaps
(e.g. MET Norway forecasts + NWS alerts in the US). Credentials come only
from user configuration at run time; the package ships none. Other open
sources to evaluate per region (verify licences before use): Environment and
Climate Change Canada (Open Government Licence – Canada), Deutscher
Wetterdienst open data, MeteoAlarm feeds (terms vary by member service).

## 4. Location context

- Round coordinates to 3 decimals for cache keys (parity); each backend may
  round further (MET Norway: 4 decimals max).
- Country code: offline point-in-polygon over **Natural Earth** admin-0
  boundaries (public domain).
- Time zone: from the backend when it reports one (Open-Meteo can resolve
  it); otherwise offline from time-zone boundary data. The common
  `timezone-boundary-builder` dataset is ODbL (share-alike database
  licence) — acceptable as a separately downloaded data file, not compiled
  in; decide in R5.
- No reverse geocoding to place names is needed by WeatherKit itself.

## 5. Derived values (our own algorithms)

| Value | Approach |
|---|---|
| `SunEvents` | compute locally: solar position from the standard published equations (e.g. NOAA's solar calculator method, Meeus); dawn/dusk at −18°, −12°, −6°; sunrise/sunset at −0.833°; nil when the sun does not cross the threshold |
| `MoonEvents` | moon phase from the synodic month and a published new-moon epoch, binned into the eight phases; moonrise/moonset from a low-precision lunar position algorithm |
| `WeatherCondition` | Ycode table from WMO weather codes (Open-Meteo), MET symbol codes, or NWS icons, refined by wind (breezy/windy thresholds) and temperature (hot/frigid thresholds) |
| `symbolName` | Ycode table (condition × daylight → SF Symbols name); align with Apple's choices once W-DATA shows them |
| `apparentTemperature` | from the backend when present, else heat index / wind chill from published formulas |
| `UVIndex.category`, `Wind.compassDirection` | ranges of `api.md` §3.8; 16 sectors of 22.5° centred on north |
| `pressureTrend` | sign of the 3-hour pressure change with a ±1 hPa dead band (Ycode choice) |
| `WeatherChanges` | compare each day with the previous one; thresholds are a Ycode choice, documented in code |
| statistics, summaries, `HistoricalComparisons` | from a historical archive (Open-Meteo archive/climate APIs) over a fixed 30-year baseline; percentiles and means computed locally; `baselineStartDate` = baseline start |
| minute forecasts | only from Apple REST (`forecastNextHour`); open backends report minute availability `unsupported` and return nil |
| alerts | Apple REST or NWS (CAP fields → `WeatherAlert`: headline → `summary`, sender → `source`, area → `region`, severity map); elsewhere availability `unsupported` |

## 6. Service engine

- One request per call, combining all requested products a backend can serve
  together; parameter-pack and tuple overloads are thin wrappers over a
  dynamic list of `AnyWeatherQuery`.
- Cache: per process (or per user on Linux), keyed by backend, product,
  rounded coordinate, language and range; honours `metadata.expirationDate`;
  never returns expired data; persists to a small file store (JSON in the
  `codable.md` format, or SQLite).
- In-flight coalescing of identical requests; cancellation checked before
  network access.
- Errors: authentication failures → `WeatherError.permissionDenied`; other
  service errors → `.unknown`; transport errors passed through
  (`behavior.md` §4). Reversed date ranges trap, as in the reference.
- Localization: Ycode's own string tables for `description` and
  `accessibilityDescription` (English values of `behavior.md` §6 as the
  base).

## 7. Simulator integration

- Parity path (default): nothing replaced; Ycode supplies network, per-app
  XPC services, entitlement sections, GEO, locationd simulation and tccd.
- Ycode's host CLI mirrors `simctl location` (`set`, `start`, `run`,
  `clear`, `list`) with **Ycode-recorded** scenarios and the same
  interpolation rules, and `simctl privacy` for location.
- Optional "simulated weather" (R8): the drop-in framework serves fixtures
  chosen from the host, the way simulated location works.

## 8. Risks

- Apple REST field drift (iOS 18 fields not in v1 docs): keep decoding
  lenient, fill missing fields from derivations.
- Open-data terms change; keep a per-backend licence notice in the package
  and in `attribution`.
- Parity on display strings and symbols needs W-DATA output from an entitled
  run (owner).
