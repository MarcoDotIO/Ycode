# MapKit spec: implementation rounds and conformance tests

Part of `specs/frameworks/mapkit/`. This plan is Ycode's own. Each round is
sized for one agent. Clean-room agents read only `specs/`, public
documentation and permissively licensed open source; they must not open the
reference tools (the Xcode copy, Ghidra, the IPSW), `research/dirty/` or
Ghidra projects, must not run Apple's Xcode or Simulator, and must not
fetch from Apple's map servers. (Simulator-track rounds run Apple's iOS
runtime inside a Ycode micro-VM by design; that runtime then talks to
Apple's servers exactly as on a Mac. The agents do not inspect that traffic
beyond what this spec records.)

## 1. Targets

1. **Baseline in Ycode's simulator** (`design.md` §2): an unmodified MapKit
   app in a Ycode guest, running Apple's MapKit, behaves as
   `simulator-baseline.md` records. Rounds R1–R6.
2. **Open MapKit** (`design.md` §3): a Linux Swift package and a guest
   drop-in with the same names, built on open data and MapLibre Native.
   Rounds R7–R15.

## 2. Simulator-parity rounds (Target A)

Ordered by dependency. Each round names the checklist rows of
`simulator-baseline.md` §7 that must pass at its end. "Pass" means the same
outputs from `MKProbe` (our own app, `research/experiments/mapkit/MKProbe`,
which an agent may build and run in a Ycode guest) modulo server content,
times and the device's safe area.

| Round | Scope | Baseline sections | Done when |
|---|---|---|---|
| R1 | **Headless MapKit**: MapKit loads in a guest app; `geod` launches on demand in the **user** launchd domain as `mobile` with its three Mach services; writable `Library/Caches/GeoServices` and `Library/Caches/com.apple.geod`; the app's lookups of `com.apple.geod`, `com.apple.geoanalyticsd`, `com.apple.locationd.*` and `com.apple.tccd` succeed; correct wall clock and time zone | §§2.1–2.3, 2.6 | S1 (math mode prints identical digits; it needs no network or GPU) |
| R2 | **Guest internet for `geod`**: DNS, outbound TCP and UDP (QUIC), TLS with the runtime's own trust store, no host allow-list (the host list comes from the downloaded manifest); host proxy settings honored if the host has any | §2.5 | S8–S12 (search, completer, directions, geocoding, Look Around) |
| R3 | **Metal in app processes** (the Metal→Vulkan layer, stage 8a): `com.apple.metal.simulator`, `com.apple.IOSurface.Remote`, `com.apple.MTLCompilerService`; the map's layer composited by Ycode's render server | §3 | S2–S5 (first render, callbacks, every configuration including 3D and globe, annotations drawn) |
| R4 | **Snapshot service**: launching the XPC service bundled in `MapKit.framework/XPCServices` (`com.apple.MapKit.SnapshotService`) for an app, with GPU access | §§2.1, 4.7 | S13 |
| R5 | **Location**: `locationd` with `com.apple.locationd.simulation`; Ycode host commands equivalent to `simctl location set/clear` and `privacy grant location`; the transient error-then-update sequence on a change | §4.8 | S6, S7 |
| R6 | **Input and app switching**: multi-step drags with velocity, double taps within the double-tap interval, long presses through Ycode's HID path; `openURL` routing (27.1 has no Maps app: `maps:` fails, `https://maps.apple.com` goes to Safari); loss of `geod` | §§4.4, 5, 6 | S14, S15, S16 |

Notes for the simulator agents:

- The first map on a fresh device downloads ≈45 MB of resources; a slow
  path must stay under the 60 s request time-out (27.0 logged one −1001
  time-out on a cold device).
- Realistic elevation and the globe grow the app by ≈150 MB; give guest
  apps headroom.
- Do not "fix" the 27.1 absence of Maps (S14 expects failure).
- No account, key or entitlement setup is needed for any round.

## 3. Open-MapKit rounds (Target B, clean room)

| Round | Scope | Done when |
|---|---|---|
| R7 | **Geometry core** (`MKGeometry`): map points and clamps, rect algebra and the 180th-meridian rules, regions from meters and map rects, the meters-per-map-point table, the map-point distance formula, circle/polyline/polygon bounding rects, geodesic densification counts, distance formatter for en_US/en_GB/de_DE/fr_FR/ja_JP | C-GEOM and C-FMT pass bit-exact on Linux (`geometry.md` §§1–5, 11) |
| R8 | **Camera and viewport**: camera value type and constructors, altitude/distance/pitch relations, safe-area viewport, region fitting by aspect, the 30° field of view on the full height, visible map rect, conversions, zoom and boundary clamps, pitch limit by distance | C-CAMERA and C-VIEWPORT pass (`geometry.md` §§6–7) |
| R9 | **Renderer bridge**: MapLibre Native behind `MKMapView` (Metal in the guest, Vulkan/GL on Linux), Ycode styles for standard / muted / imagery / hybrid in light and dark, realistic elevation (terrain + extrusions), globe for imagery at continental distances, attribution view, the empty-grid look for missing data; delegate callback sequences of `interface.md` §3.4 | C-RENDER passes (callbacks, order, no-reload rule; screenshots reviewed by a human for "looks like a map") |
| R10 | **Annotations and overlays**: annotation container, marker view geometry and defaults, selection, clustering with "+N more" subtitles and count glyphs, overlay levels, renderer coordinate space, path renderers, tile overlays with the URL template grammar | C-ANNOT and C-OVERLAY pass |
| R11 | **Services**: `PlaceSearch`, completer (debounced), POI request, `Geocoder` (forward/reverse; `CLGeocoder` compatibility), `Router` (routes, steps, ETA, alternates, preferences), map item model with `MKAddress` formatting and representations, the `forCurrentLocation()` placeholder and its resolution, error mapping of `services.md` §7 | C-SERVICES passes against recorded open-backend fixtures |
| R12 | **SwiftUI `Map`**: content builder, markers/annotations/shapes, `MapCameraPosition` semantics including `.automatic` framing and the user-location fallback order, `onMapCameraChange`, controls, `MapReader`/`MapProxy` | C-SWIFTUI passes (`geometry.md` §10) |
| R13 | **Snapshots and Look Around**: headless snapshot rendering with aspect-fit geometry, size limits and option rules; Look Around returns nil (no open imagery) unless an imagery adapter is configured | C-SNAP passes; C-LOOK returns nil without error |
| R14 | **Opening maps**: `openInMaps`/`openMaps` and `maps:` URLs routed to a Ycode map viewer app or reported as unavailable exactly like 27.1 | C-OPEN passes |
| R15 | **Drop-in switch**: load Ycode's MapKit (and the optional `dev.ycode.geod`) in the guest instead of Apple's for opt-in apps; offline packs | the suite passes with both stacks |

## 4. Conformance tests (clean-room side)

Each test names the spec section with the expected values.

| Id | Test | Expected |
|---|---|---|
| C-GEOM-1 | project/unproject the coordinates of `geometry.md` §§1.1–1.2 | exact x, y and round trips, clamp at ±85°, (−1, −1) for invalid input, x wrap on the inverse |
| C-GEOM-2 | meters-per-map-point table and map-point distances (`geometry.md` §2) | equal to the printed digits, including the polar anomalies |
| C-GEOM-3 | rect algebra cases (`geometry.md` §4) | equal |
| C-GEOM-4 | regions from meters and from map rects (`geometry.md` §3) | equal to 7 decimals |
| C-GEOM-5 | overlay bounding rects and geodesic point counts (`geometry.md` §5) | equal |
| C-FMT | distance formatter tables (`geometry.md` §11) | identical strings |
| C-CAMERA | camera constructors, altitude/distance relations (`geometry.md` §7.1) | equal to 3 decimals |
| C-VIEWPORT | `setRegion`/`regionThatFits`/`setCamera`/conversions on a 466 × 678 view with safe-area insets (0, 0, 34, 84) and on the five inset-free sizes (`geometry.md` §§6, 7.2) | equal to the printed digits |
| C-RENDER | first display, move, return, animated change | callback sequences of `interface.md` §3.4; no render callbacks on return to a loaded area |
| C-ANNOT | three default markers, selection, cluster of 20 | frames/offsets/defaults of `interface.md` §4.1; cluster subtitle "+19 more" |
| C-OVERLAY | renderer `point(for:)`, `rect(for:)`, defaults; tile URL substitution | `interface.md` §4.4, `geometry.md` §8 |
| C-SERVICES | search/complete/geocode/route against fixtures | shapes, counts, ordering rules and error codes of `services.md` |
| C-SWIFTUI | `.automatic` framing of the probe content, position changes | `geometry.md` §10 |
| C-SNAP | 300 × 200 region, mapRect, aspect mismatch, pitched camera, zero and 6000 sizes | `geometry.md` §9; zero size raises; 6000 fails with code 1 |
| C-LOOK | scene requests | nil for uncovered places, error 1 for invalid coordinates |
| C-OPEN | open in Maps without a maps app | completion NO, app stays in front |

## 5. Probe and how to rerun the baseline

`research/experiments/mapkit/MKProbe/` (our own code): `build.sh OUTDIR`
builds `MKProbe.app` (no entitlements), the `svctrace.dylib` service tracer
and the `hidsend` driver; `runall.sh <udid> <build> <out> [modes]` installs,
grants location, sets the simulated location to Apple Park and runs every
mode (`run.sh` drives one mode: screenshots on `SHOT`, input and host
actions on `READY`, a `geod` log stream per mode). On the 27.1 iPhone Duo
set `SHOTDISP=LCD`. Modes: `math map config gesture annot annot:cluster user
search dir geo look snap open:{openInMaps,directions,url,https} sui suicam
offline offline:geodstopped`. The string-constant tool is generated by
`gen_consts.py`. Name inventories: `extract_objc_names.py`,
`extract_swift_names.py`, rendered by `gen_api.py`.

Use devices named `ycode-test-mapkit*` only. `offline:geodstopped` removes
`geod` from the device's launchd until the device reboots.

## Evidence

| Claim | Level |
|---|---|
| Round contents, ordering, test design | Ycode's own plan (no evidence level) |
| Expected values | as cited in the referenced files (levels 2–4) |
