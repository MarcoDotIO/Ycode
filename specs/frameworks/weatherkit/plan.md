# WeatherKit spec: implementation rounds and conformance tests

Part of `specs/frameworks/weatherkit/`. This plan is Ycode's own. Each round
is sized for one agent. Clean-room agents read only `specs/`, public
documentation and permissively licensed open source; they must not open the
reference tools (the Xcode copy, Ghidra, the IPSW), `research/dirty/`, or
Ghidra projects.

## 1. Rounds

| Round | Owner | Scope | Done when |
|---|---|---|---|
| R0 | KIT-WEATHERKIT (this) | Specification | this directory reviewed and merged |
| R0b | **owner** + dirty room | Entitled reference run: register a bundle ID with WeatherKit (`simulator-baseline.md` §5), run `WKProbe -mode weather` and `-mode codable` with real data; create a WeatherKit key and Services ID for W-REST. Record per-query results, units, symbol names, expiry per product, cache-hit timing, Codable JSON of real values, REST responses for the same location | notes added to `research/notes/`, golden files produced; spec gaps marked "verify" resolved |
| R1 | simulator track | **Baseline in Ycode** with Apple's own framework: guest networking incl. QUIC/UDP 443 and DNS, per-app XPC service launch, `__entitlements` honoured for launch and peer checks, GEO, writable `/Library/Weather`; locationd simulation fed from the host (`set/start/run/clear/list` with Ycode-made scenarios), tccd privacy grant/revoke/reset, location prompt tappable | W-ATTR, W-NOENT, W-ENT, W-ENT-REPEAT, W-LAUNCH-ENT, W-GEO, W-TRAP, W-CODABLE, W-ERRORS and all L-* match the reference goldens |
| R2 | clean room | **Model**: every type of `api.md` with storage, `Codable` exactly as `codable.md` (including non-public keys, preserved), enums with description/accessibility/symbol/abbreviation/range tables, Linux `CoreLocation` shim | C-CODABLE, C-ENUM, C-API pass on Linux and macOS |
| R3 | clean room | **Service engine** with the fixture backend: query planner (single request per call, parameter packs), cache with expiry and coalescing, error mapping, cancellation, attribution plumbing | C-QUERY, C-CACHE, C-ERRORS pass |
| R4 | clean room | **Apple REST backend**: JWT ES256 signer (swift-crypto), token providers (static token, local key file, remote token URL), v1 endpoints, mapping REST → model (`rest-api.md` §6), attribution endpoint | C-JWT passes; W-REST (owner key) passes |
| R5 | clean room | **Open backends**: Open-Meteo, MET Norway (User-Agent, `Expires`, 4-decimal rule), NWS (forecast + alerts); derivations of `design.md` §5 (astronomy, conditions, symbols, trends, changes); country/time-zone resolver; per-backend attribution and licence notices | C-OPEN, C-ASTRO, C-ATTR pass |
| R6 | clean room | **Statistics, summaries, historical comparisons** from an open archive | C-STATS passes |
| R7 | simulator track | Host tooling polish: Ycode's `location` and `privacy` commands documented, GPX import for routes, scenario recorder | L-* pass with imported GPX |
| R8 | clean room + simulator track (optional) | **Guest drop-in WeatherKit** ("simulated weather"): ABI-compatible build of R2–R5 for the simulator SDK with the fixture backend selectable from the host | C-API binary test: an app built against Apple's SDK runs against the drop-in and shows fixture weather |

R1 is independent of R2–R6. R4 needs R0b only for the final W-REST check.

## 2. Conformance tests

Test apps and tools are ours. "Reference" = Apple's simulator (goldens from
WKProbe) or Apple's REST service with the owner's key.

| Test | Does | Expected |
|---|---|---|
| W-* / L-* | `simulator-baseline.md` §7, `location.md` §7 | identical to reference goldens after normalizing times, pids, UUIDs, timings |
| C-API | a source file using every public name of `api.md` (queries, tuples, parameter packs, all fields) compiled against Apple's SDK and against our package | compiles unchanged in both |
| C-CODABLE | decode the reference's encoded JSON (from W-CODABLE and R0b real values) with our package, re-encode, decode again with Apple's framework in the reference simulator | lossless both ways; key sets equal |
| C-ENUM | print every enum's raw values, descriptions, accessibility descriptions, symbol names, abbreviations, UV ranges | equal to the reference output (English) |
| C-QUERY | against a mock backend: each query combination, date ranges (incl. zero-length), reversed range | one backend request per call with exactly the requested products; reversed range traps |
| C-CACHE | repeated calls within and after expiry; failing refresh after expiry; concurrent identical calls | hit before expiry, refetch after, no stale fallback, one request for concurrent duplicates |
| C-ERRORS | backend returns 401/403, malformed data, transport failure; cancelled task | `permissionDenied`, `unknown`, `URLError` passed through, `CancellationError` |
| C-JWT | sign with a locally generated P-256 key; verify with swift-crypto and an independent tool; decode header/claims | header {alg, kid, id}, claims exactly {iss, iat, exp, sub}; valid ES256 signature |
| W-REST (owner) | same location through REST v1 and through the native framework (R0b) | every documented field maps; values equal after unit conversion; documented status codes for bad parameters and bad token |
| C-OPEN | recorded responses from each open provider (recorded once by us, stored as test data under the provider's licence) | mapping produces valid model values; attribution names the provider |
| C-ASTRO | sun and moon events at test points (equator, mid-latitude, polar day, polar night) on fixed dates | within 1 minute of values from a published solar calculator; nil where events do not occur |
| C-ATTR | `attribution` for each backend | non-empty name, legal URL, marks or explicit nil; licence text present |
| C-STATS | statistics/summaries for a fixed location and period from archive fixtures | values equal to an independent computation over the same fixture |

## 3. Deliberate differences from the reference

- Authentication failures surface as `WeatherError.permissionDenied` (the
  reference throws internal errors); tests compare error *kind*, not
  internal domains.
- Cancellation is honoured.
- The cache is per process/user, not device-wide.
- With open backends, minute forecasts, alerts (outside the NWS area) and
  non-public products are unavailable; availability reports `unsupported`.
