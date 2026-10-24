# MapKit in Apple's simulator: observations (dirty-room notes, prose only)

Dates: 2026-10-19 (first pass) and 2026-10-20 (completion). Agent:
KIT-MAPKIT. Reference: Xcode 27.1 (27A9269); iOS 27.1 runtime (24A94401)
on device type iPhone Duo; iOS 27.0 runtime (24A434) on iPhone 18 Pro. No
disassembly or decompilation was used. No IPSW was opened. Raw logs and
screenshots stayed in the git-ignored `research/dirty/mapkit/` and the
session scratch directory; the spec files in `specs/frameworks/mapkit/`
hold the distilled facts.

## Devices

- `ycode-test-mapkit-271` (iOS 27.1, iPhone Duo): created on 2026-10-19,
  used for every mode; rebooted once on 2026-10-20 after the
  `offline:geodstopped` run removed `geod` from its launchd; shut down and
  deleted at the end of the session on 2026-10-20.
- `ycode-test-mapkit-270` (iOS 27.0, iPhone 18 Pro): created, used for
  map, gesture, search, dir, geo, look, snap and open (openInMaps,
  directions, url) modes, then shut down and deleted on 2026-10-20. The
  annot mode was not run there (the host's simulator service stalled on a
  `launchctl list` and the run was stopped).

## How the probe was run

`MKProbe` (our own Swift app, `research/experiments/mapkit/MKProbe`) prints
one line per observation. `run.sh` launches it with our `svctrace.dylib`
interposed (it records Mach lookups, XPC connections and notification
registrations by name only), takes screenshots when the app asks, drives
touches with our `hidsend` tool and runs host actions (`simctl location`,
`launchctl bootout` of `geod`). `runall.sh` also streams `geod`'s unified
log per mode, from which we counted hosts, protocols, request counts and
response sizes. Nothing from Apple's binaries was read beyond names in the
launchd plists and Info.plists of the runtime.

## What we learned, in short

1. Nothing needs an account: an ad-hoc-signed app without entitlements gets
   maps, search, directions, geocoding, Look Around and snapshots.
2. All network traffic is done by `geod` (user `mobile`, demand-launched,
   placed in the user launchd domain), over HTTPS (h2, http/1.1, QUIC) to a
   manifest-driven set of `*.ls.apple.com` hosts and a few `apple.com`
   hosts. The app only talks XPC to `geod`.
3. Tiles, styles and resources are cached on disk by `geod` (≈100 MB after
   the whole suite); a revisited area is drawn with almost no requests.
4. Rendering is Metal in the app process; snapshots use an XPC service
   inside `MapKit.framework`; Metal shaders compile in `MTLCompilerService`.
5. Map geometry is deterministic and identical across runs and runtimes:
   Web Mercator on a 2^28 square with a ±85° latitude clamp, a viewport
   equal to the safe area, a 30° vertical field of view over the full view
   height, and a map-point distance that is a great circle on a sphere of
   radius 6,378,160 − 21,000·|sin φ₁| m (our fit).
6. With `geod` gone or tiles unreachable the map shows an empty grid and
   services fail with `MKErrorDomain` 1; there is no
   `mapViewDidFailLoadingMap` in those cases (it appeared only for a
   time-out on a cold 27.0 device).
7. 27.1 has no Maps app; `openInMaps` fails quietly and
   `https://maps.apple.com` URLs open Safari. 27.0 opens Maps.
8. Our synthetic touches move the map on the 27.0 iPhone 18 Pro but did not
   reach apps on the 27.1 iPhone Duo (SpringBoard did receive them).
9. Requests without a region are biased on the server side by the host's
   real network position, not by the simulated location.

## Open items

- A true network outage (needs the Network Link Conditioner or an admin
  firewall rule; not done without administrator rights).
- Touch routing on the iPhone Duo for app windows.
- The pitch limit curve between 300 m and 100 km, the zoom-range ratio
  (0.80365 on the Duo view), the exact geodesic densification rule and a
  closed form for meters per map point.
- The SwiftUI `Map` viewport (its fitted aspect differs from `MKMapView`'s).
