# WeatherKit — specification index

Status: **round 0 (specification)**, 2026-10-19. Reference: the iOS 27.1 SDK
in Xcode 27.1 (27A9269) and the iOS 27.1 simulator runtime (24A94401), whose
WeatherKit bundle reports version 1454.5.

## Scope

- The **Swift WeatherKit framework** an iOS app links against:
  `WeatherService`, the query types, the weather data model, units, errors,
  attribution.
- The **WeatherKit REST API** (`weatherkit.apple.com`), as a public interop
  protocol: it is what Apple documents for non-Apple platforms, and it is the
  natural backend for an open implementation.
- The **Core Location** pieces a weather app depends on: authorization,
  simulated locations, update delivery, reverse geocoding. Core Location as a
  whole is a separate framework and gets its own spec later; `location.md`
  covers only what weather apps need and what Ycode's simulator must
  reproduce.

Not covered: the Weather app, its widgets and poster extensions, `weatherd`'s
notification and predicted-location features (not reachable from third-party
apps), non-public data products the service also returns (air quality, news,
marine, tides, highlights — seen only as internal keys, see `codable.md`).

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | What WeatherKit does in Apple's iOS Simulator today (black-box), the request flow, what the owner must provide to test the entitled path, what Ycode's simulator must provide, conformance checklist |
| `location.md` | Core Location for weather apps: authorization states and prompt, `simctl location` semantics, update delivery, live updates, geocoding; Ycode simulator requirements |
| `api.md` | Swift interface: `WeatherService`, `WeatherQuery` and the statistics/summary queries, every model type and enum, units and `Measurement` types, availability by OS version |
| `behavior.md` | Behavior of the Swift API: request composition, location handling, caching and expiry, errors, concurrency, display strings, attribution and display requirements, region limits |
| `codable.md` | The `Codable` archive format of the model types (the only way apps can construct values, so it matters for tests and persistence) |
| `rest-api.md` | WeatherKit REST API: endpoints, developer-token (JWT) format, data sets, JSON objects, units, enums, status codes |
| `design.md` | **Ycode-original design note**: an open WeatherKit for Linux and for Ycode's simulator, with pluggable backends (Apple REST, open data sources) |
| `plan.md` | Implementation rounds and conformance tests |

Black-box observations behind these files are in
`research/notes/weatherkit-simulator-observations-2026-10-19.md`; the probe
app is `research/experiments/weatherkit/WKProbe/` (our own code).

## Framework layout facts (level 4)

- Swift-only framework: the SDK ships a `.swiftinterface` per simulator
  architecture and a `.tbd`, no Objective-C headers. Install name
  `/System/Library/Frameworks/WeatherKit.framework/WeatherKit`, bundle
  identifier `com.apple.weatherkit`, current version 1454.5, built in Swift 6
  language mode with library evolution. It depends on CoreLocation,
  Foundation, Network and os. `CLLocation` in its signatures comes from
  Core Location's lower module `_LocationEssentials`, re-exported by
  `CoreLocation`; a source-compatible implementation just uses
  `CoreLocation.CLLocation`.
- The runtime framework embeds one XPC service,
  `com.apple.weatherkit.authservice` (per-application instance), which
  obtains the app's access token. Data requests run in the app's own process;
  the `weatherd` daemon is not involved for third-party apps (level 3).
- Availability: the core API starts at iOS 16 / macOS 13 / tvOS 16 /
  watchOS 9 (visionOS 1); statistics, summaries, changes, historical
  comparisons, day parts and several fields start at iOS 18 / macOS 15 /
  tvOS 18 / watchOS 11 / visionOS 2. `WeatherAttribution.legalAttributionText`
  starts at iOS 16.4. Sendable conformances of `WeatherCondition` and
  `WeatherAttribution` were added in iOS 26.
- Using the service requires the `com.apple.developer.weatherkit`
  entitlement and an App ID with WeatherKit enabled by a paid developer team
  (level 1, confirmed in part at level 3).

## Evidence summary

Level 1: Apple's public WeatherKit and WeatherKit REST API documentation and
the WeatherKit "get started" and account-help pages, summarized in our own
words; licence and terms pages of open data providers (Open-Meteo, MET
Norway, US National Weather Service). Level 2: the simulator runtime's
launchd plists and Info.plists (service names, keys); the SQLite cache files
the framework writes (table names only). Level 3: `WKProbe` on a simulator
named `ycode-test-weatherkit-1` (created and deleted for this work), with the
system log read while it ran. Level 4: public SDK metadata (module
structure, type and member names, availability annotations, `.tbd` install
name and version). Level 5 (disassembly/decompilation) was **not** used. The
reference tools folder and Ghidra were not opened. No developer account was
signed in to and no credential was used.
