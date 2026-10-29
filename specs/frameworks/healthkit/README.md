# HealthKit (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-19; implementation status
below. Reference: the iOS 27.1 SDK in Xcode 27.1 (27A9269), the iOS 27.1
simulator runtime (24A94401) and, for comparison, the iOS 27.0 runtime
(24A434) that still ships the Health app.

Implementation status (2026-10-28): `frameworks/healthkit/` (package
`ycode-healthkit`: library product `HealthKit`, test target
`HealthKitTests`). Rounds R2–R5 of `plan.md` are done, with the Swift query
descriptors of R10; R6–R9, R11 and the rest of R10 are deferred. The package
README lists what is done, deferred and not started.

## Scope

This spec covers the **iOS HealthKit** API that an iPhone app links against:
the health store, the object-type model and its identifiers, units, samples
and their subclasses, metadata, sources and devices, correlations, workouts
(builder, live session, routes), every query kind and its result semantics,
authorization and its privacy rules, background delivery and errors. It also
records what Apple's iOS Simulator does today, which is the baseline Ycode's
simulator must match first — HealthKit is an "easy win": it **works fully in
the reference simulator**, on both runtimes, without any account.

Not covered: watchOS-only behavior (mirrored sessions, `startWatchApp…`
pairing), HealthKitUI's activity-ring view beyond its name, the Health app
itself, and the private sync protocols. The FHIR/CDA payload formats of
clinical records are named but not specified (no records can be created by
an app; see `interface.md` §8).

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | What HealthKit does in Apple's simulator on 27.1 and 27.0; daemons, Mach services and system UI involved; persistence; **conformance checklist** |
| `interface.md` | `HKHealthStore`, the object/type model, samples and their subclasses, metadata, sources and devices, correlations, workouts and routes, characteristics, clinical/medication types, Swift refinements |
| `units.md` | `HKUnit`: the unit-string grammar, prefixes, every base unit, conversions, algebra, golden values |
| `queries.md` | Predicates and their interval rules, sorting, limits, anchors and tombstones, observer and long-running queries, statistics options, merging across sources, collection bucketing and proration, background delivery |
| `authorization.md` | Entitlements, Info.plist keys, the authorization model and status values, read-privacy semantics, the system sheet flow, historical-data range, per-object authorization |
| `errors.md` | `HKErrorDomain` codes, exceptions and when each is raised |
| `design.md` | **Ycode-original design note**: an open implementation (daemon split, SQLite storage engine, query engine, authorization store, statistics engine) |
| `plan.md` | Implementation rounds and the conformance-test plan with measured golden values |
| `identifiers.md` | Generated appendix: every type identifier with string value, aggregation style, unit family and duration limits; metadata keys and other string constants with their values; every enumeration with raw values |
| `api-inventory.md` | Generated appendix: every class, superclass and member name, with introduction versions |

Black-box observations: `research/notes/healthkit-simulator-observations-2026-10-19.md`.
Probe app (our own code): `research/experiments/healthkit/HealthProbe/`.
Generators: `research/experiments/healthkit/{extract_names,gen_tables,gen_api}.py`.

## Framework layout facts (level 4)

- Install name `/System/Library/Frameworks/HealthKit.framework/HealthKit`,
  bundle identifier `com.apple.HealthKit`. The SDK headers are identical for
  device and simulator. Swift refinements live in the overlay module
  (`HealthKit.swiftmodule`, library-evolution interface).
- HealthKitUI (`HKActivityRingView`, a UIKit category on the store) is a
  separate small framework; `WorkoutKit` and `_AppIntents_HealthKit` are
  neighbors, not part of this spec.
- In the simulator runtime the framework bundle also carries the daemon
  executable (`HealthKit.framework/healthd`), a `PlugIns/` folder of
  diagnostic and notification extensions, a `cda_validation` folder, and two
  property lists that map UCUM unit codes to HealthKit unit strings. Ycode
  writes its own data; it does not copy these resources.
- Availability: the API starts at iOS 8.0; members carry their own versions
  (listed in `api-inventory.md`). New in the 27.0 SDK:
  `getEarliestAuthorizedSampleDateForTypes:completion:` (the historical-data
  range, `authorization.md` §5) and `HKLiveWorkoutZoneUpdate`; in 26.0 the
  iPhone gained `HKWorkoutSession`/`HKLiveWorkoutBuilder` and medications.
  The PHQ-9/GAD-7 score-range functions are marked unavailable on iOS.

## Evidence summary

Level 1: Apple's public HealthKit documentation (summarized in our words,
never copied). Level 2: file formats of the store (SQLite, as file names and
sizes only), launchd property lists and app Info.plists in the runtimes.
Level 3: `HealthProbe` on simulators named `ycode-test-healthkit-*` on iOS
27.1 and 27.0. Level 4: public SDK metadata (header and module structure,
names, enum raw values, availability annotations) — never pasted. Level 5
(disassembly/decompilation) was **not** used. The reference tools folder,
`research/dirty/` of other agents and Ghidra were not opened.

## What the owner must provide

Nothing for the simulator work: HealthKit's entitlement checks in the
simulator read the app's simulated-entitlements section, which any local
build can carry (`authorization.md` §1). A **device** run (to confirm
device-only facts and the merge order with the Health app's source list)
needs the owner's development team and a provisioning profile with the
HealthKit capability; that was not attempted.
