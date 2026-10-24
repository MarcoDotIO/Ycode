# MapKit (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-20. Reference: the iOS 27.1 SDK
in Xcode 27.1 (27A9269), the iOS 27.1 simulator runtime (24A94401) and, for
comparison, the iOS 27.0 runtime (24A434) that still ships the Maps app.

## Scope

This spec covers the **iOS MapKit** API an iPhone app links against: the
map view (`MKMapView`) and SwiftUI `Map`, configurations, camera and
viewport, annotations, clustering and overlays with their renderers, tile
overlays, user location (through Core Location), local search and
completion, points-of-interest requests, directions and ETA, geocoding as
used through MapKit (`MKGeocodingRequest`, `MKReverseGeocodingRequest`, and
`CLGeocoder` for comparison), map items and addresses, Look Around,
snapshots, opening Maps, string constants and errors. It records what
Apple's simulator does today — MapKit **works fully there without any
account**, but it **needs the network** (through the `geod` daemon) and
**Metal in the app process** — which is the baseline Ycode's simulator
must match first.

Not covered: MapKit JS, the Maps app itself, the private GeoServices wire
protocol and data formats (we never decode Apple's map data), navigation
(turn-by-turn) and CarPlay, watchOS/macOS-only API.

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | What MapKit does in Apple's simulator on 27.1 and 27.0: processes, Mach/XPC services, launchd jobs, entitlements, network endpoints, caches, rendering path, location interplay, input, opening Maps, offline and failure behavior, what works offline; **conformance checklist S1–S16** |
| `interface.md` | Module layout, value types, `MKMapView` state, configurations, delegate order, ornaments, annotations, clustering, overlays and renderers, camera, user location, SwiftUI `Map`, snapshots, Look Around, opening maps, string constants |
| `geometry.md` | Golden values and our fitted formulas: projection, meters per map point, distances, regions, rect algebra, overlay shapes, viewport fitting and field of view, camera relations and clamps, overlay/annotation placement, snapshot geometry, SwiftUI framing, distance formatter |
| `services.md` | Map items and addresses, local search, completer, directions and ETA, geocoding, errors (`MKErrorDomain` codes and userInfo keys) |
| `design.md` | **Ycode-original design note**: the dependencies of Target A (Apple's MapKit in Ycode's simulator, A1–A12) and the architecture of an open MapKit (MapLibre Native, open data services, licenses) |
| `plan.md` | Simulator-parity rounds R1–R6, open-MapKit rounds R7–R15, conformance tests, how to rerun the probe |
| `api-inventory.md` | Generated appendix: every class, protocol, enumeration, constant, function and SwiftUI/Swift-overlay name with introduction versions |

Black-box observations: `research/notes/mapkit-simulator-observations-2026-10-19.md`.
Probe app (our own code): `research/experiments/mapkit/MKProbe/`.
Generators: `research/experiments/mapkit/{extract_objc_names,extract_swift_names,gen_api,gen_consts}.py`.

## Key findings

1. **No account, key or entitlement** is needed for any MapKit feature in
   the simulator; an ad-hoc-signed app works.
2. **`geod` is the only network client**; it needs outbound HTTPS
   (h2/http1.1/QUIC) to a manifest-driven set of Apple hosts, plus writable
   caches. Without it: an empty grid map and `MKErrorDomain` 1 errors.
3. **Metal in the app process** is mandatory for any map drawing;
   snapshots additionally need the bundled snapshot XPC service.
4. User location is Core Location's simulated fix; services are not biased
   by it (requests without a region are biased by the host's real network
   position on the server side).
5. Geometry is deterministic and fully specified with golden values
   (`geometry.md`), so an open implementation can be tested bit-exact.
6. 27.1 has no Maps app: `openInMaps` fails quietly.

## Evidence summary

Level 1: public documentation (summarized in our words). Level 2: the
runtime's launchd plists and bundle Info.plists read as files. Level 3:
`MKProbe` on `ycode-test-mapkit-271` and `ycode-test-mapkit-270`, `geod`'s
unified log, our `svctrace` interposer in our own app. Level 4: SDK names,
enum raw values and availability, runtime class names of views. Level 5
(disassembly/decompilation) was **not** used; no IPSW was opened; Ghidra was
not used.

## What the owner must provide

Nothing for the simulator work. Open questions that need the owner or
administrator rights: a true network-outage run (Network Link Conditioner
or a firewall rule), and a device run (not attempted; MapKit needs no
capability, so any development team would do).
