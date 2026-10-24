# HealthKit spec: implementation rounds and conformance tests

Part of `specs/frameworks/healthkit/`. This plan is Ycode's own. Each round is
sized for one clean-room agent. Clean-room agents read only `specs/`, public
documentation and permissively licensed open source; they must not open the
reference tools (the Xcode copy, Ghidra, the IPSW), `research/dirty/`, or
Ghidra projects.

## 1. Targets

1. **Baseline in Ycode's simulator** with Apple's HealthKit (design §2).
2. **Open HealthKit**: drop-in `HealthKit.framework` for the guest
   (binary-compatible: same install name, class names, selectors, exported
   constants with the string values of `identifiers.md`, enum values, the
   Swift overlay's public declarations) and a Linux Swift package with the
   same names and semantics (design §3–§9).

## 2. Rounds

| Round | Owner | Scope | Done when |
|---|---|---|---|
| R0 | KIT-HEALTHKIT (this) | Specification and probe | this directory reviewed and merged |
| R1 | simulator track | **Baseline in Ycode**: dependencies G1–G13 of `design.md` §2 (entitlement lookup for XPC peers, remote view service for the sheet, persistent `Library/Health`); run `HealthProbe` phases basic → auth → data → cross → session → count, answer the sheet by taps | all rows of `simulator-baseline.md` §8 match (modulo UUIDs, addresses, times, device model) |
| R2 | clean room | **Type registry, units, objects**: generated type table; `HKUnit` parser/formatter/conversions; `HKQuantity`; object and sample classes with validation and secure coding; metadata rules; exceptions of `errors.md` §3 | C-UNITS, C-TYPES, C-VALIDATE pass on Linux and in the guest |
| R3 | clean room | **Store and daemon core**: SQLite schema, save/delete transactions, anchors and tombstones, sync identifiers, sources/revisions/devices, characteristics settings, client↔daemon protocol, callback queues | C-STORE, C-ANCHOR pass |
| R4 | clean room | **Query engine**: predicate compiler and in-memory fallback, sample/anchored/observer/correlation/source queries, sorting and limits, long-running updates | C-QUERY, C-OBSERVE pass |
| R5 | clean room | **Statistics engine**: statistics and collection queries, proration, merging and source priority, all averaging styles, duration, historical-range clamp | C-STATS, C-COLLECT, C-MERGE pass with the golden values below |
| R6 | clean room | **Authorization**: status/request-status rules, validation of requests, consent broker with Ycode's own sheet (read/write sections, topic toggles, historical-range page), test hook for recorded answers, developer CLI, per-object authorization | C-AUTH passes (UI by taps in the guest, by recorded answers on Linux) |
| R7 | clean room | **Workouts**: configuration, events, activities, builder statistics prorated to active time, route and series builders and queries, live session state machine and synthetic live data source | C-WORKOUT, C-SESSION pass |
| R8 | clean room | **Background delivery and launch events**, preferred units by region, activity summaries computed from samples | C-BG passes (with the simulator track's launch-event support) |
| R9 | clean room (optional) | **Records and medications**: clinical record types with FHIR payload storage (seeded only), verifiable-record query plumbing, medications and dose events, CDA documents | C-RECORDS passes against seeded data |
| R10 | clean room | **Swift overlay**: query descriptors, `HKSamplePredicate`, async variants, workout zone types | C-SWIFT compiles against the SDK and links against Ycode's framework |
| R11 | simulator track + clean room | **Drop-in switch and seeding**: load Ycode's framework/daemon in the guest instead of Apple's (opt-in), side-car data seeding | the whole suite passes with both stacks |

## 3. Golden values (measured on the reference, level 3)

### 3.1 Data set (app A = `dev.ycode.healthprobe`, D0 = 2026-10-01T00:00Z)

| Type | Samples |
|---|---|
| steps | 1000 @08:00–08:10; 500 @08:05–08:15; 3000 @12:00–12:30 (metadata `HKExternalUUID`="ycode-s3", `YcodeProbe`="golden", `YcodeNumber`=42, `YcodeQuantity`=3 m, `YcodeDate`=D0); 2000 @D0+1 09:00–09:30; 600 @23:50–D0+1 00:10; plus 1 at −5·10⁹ s from 1970 (1811-07-23) lasting 60 s, 61 @D0−60 12:00–12:01, 4 @D0−10 00:00 – D0−6 00:00; later in the run (after the statistics block) 7/8/9 @20:00–20:01 with sync identifier versions 1/2/1 (deleted again) and 11 @22:00–22:01 |
| heart rate (count/min) | 60 @08:00; 70 @08:30; 90 @09:00; 80 @13:00–13:10; 150 @06:15 (via workout builder) |
| body mass | 70 kg @07:00 (`HKWasUserEntered` YES); 155 lb @D0+1 07:00 |
| sleep | in bed 00:45–06:00; core 01:00–03:00; awake 03:00–03:15; deep 03:15–05:00 |
| mindful | 10:00–10:10 (value 0) |
| blood pressure | correlation 120/80 mmHg @07:30 |
| workout | running 06:00–06:30, pause 06:10, resume 06:12, active energy 300 kcal and distance 5000 m over 06:00–06:30, route 3 points (10.000/20.000/5 m @06:00, 10.001/…/6 m @06:05, 10.002/…/7 m @06:10) |
| app B (`dev.ycode.healthprobe.b`) steps | 400 @08:00–08:10; 900 @15:00–15:10 |

### 3.2 Expected results

| Test | Expected |
|---|---|
| steps statistics day D0 | 5100 (range 08:00 – D0+1 00:10) |
| … strict both | 4500 |
| … day D0+1 | 2600 |
| … two days | 7100, duration 5700 s |
| … all time (A granted "past 30 days" at 2026-10-19 23:55:40Z) | 7104, most recent 2000 @D0+1 09:00–09:30 |
| … [08:00,08:10] / [08:05,08:10] / [12:00,12:15] | 1500 / 1500 / 3000 |
| heart rate day D0 | avg 82.7273, min 60, max 150, most recent 80 @13:00–13:10 |
| heart rate [08:00, 09:00] | avg 65, min 60, max 70 |
| body mass all | avg 70.1534 kg, min 70, max 70.3068, most recent 70.3068 @D0+1 07:00 |
| empty range | nil + code 11 |
| active energy / distance all | 300 kcal / 5 km |
| daily collection anchor D0 | D0: 4800, D0+1: 2300 (and 1 per day D0−10 … D0−7) |
| daily collection anchor 06:00 | D0 06:00 → 5100, D0+1 06:00 → 2000 |
| 6-hourly from D0 | 06–12: 1500, 12–18: 3000, 18–24: 300, D0+1 00–06: 300, 06–12: 2000; 0.25 per bucket for the 4-day sample |
| 5-min around 08:00 | 08:00: 500, 08:05: 750, 08:10: 250 |
| hourly heart rate | 06:00 150; 08:00 65 (60/70); 09:00 90; 13:00 80 |
| arithmetic average (body temperature 10 and 20 in four layouts) | 15 each; [07:00, 07:05] → 10 |
| temporally weighted (heart rate) | 90; 90; 116.087; 100.909; 90; 63.913 (layouts of `queries.md` §6.3) |
| day-3 body temperature | avg 15, min 10, max 20, most recent 20 @07:05–07:15, duration 1740 s |
| cross-source (B) day D0 | merged 4911; B 1300; A 5111 |
| cross-source [08:00, 08:10] | merged 400; A 1500; B 400 |
| B reads heart rate with read denied | code 11 |
| predicates | counts of `queries.md` §2.1–§2.2 |
| anchored, fresh store, limit 2 | values 1000, 500 |
| observer | 1 call at start, then 1 per save/delete change set |
| sync identifier v1 → v2 → v1 | stored v2 (value 8); updates: +1, then +1/−1 |
| workout builder | duration 1680; elapsed at 06:20 = 1080; energy 280 kcal; distance 4666.67 m; HR 2.5 count/s; 1 activity; 2 events |
| preferred units (en_US) | `units.md` §7 |
| earliest authorized date | grant time − 30 days |
| characteristics after grant | DOB nil, sex/blood/skin/wheelchair 0, move mode 1, no errors |

## 4. Conformance tests

All test apps are ours (Objective-C and Swift), in the style of
`research/experiments/healthkit/HealthProbe`: one line per observation,
compared with golden files after normalizing UUIDs, addresses, times and
device model.

| Test | Content | Reference |
|---|---|---|
| C-BASE | `HealthProbe` phases in the order of `simulator-baseline.md` §8 | rows B1–P1 |
| C-UNITS | every unit string, canonical form and conversion of `units.md` | §2–§6 of `units.md` |
| C-TYPES | every identifier: value, class, aggregation, dimension, duration limits, per-object flag | `identifiers.md` |
| C-VALIDATE | every exception of `errors.md` §3, and the accepted cases | names and meanings |
| C-STORE | save/resave/delete/delete-twice/delete-of-type, persistence across daemon restart | `simulator-baseline.md` §4 |
| C-ANCHOR | anchors, tombstones with metadata, limits counting tombstones, sync replacement | `queries.md` §4, §9 |
| C-QUERY | predicates and boundary rules, sorting, limits | `queries.md` §2–§3 |
| C-OBSERVE | observer timing and counts; long-running anchored updates; stop | `queries.md` §5 |
| C-STATS / C-COLLECT / C-MERGE | §3.2 values | §3.2 |
| C-AUTH | status values, request status, read non-disclosure, entitlement and Info.plist failures, sheet flow, historical range | `authorization.md` |
| C-WORKOUT / C-SESSION | builder, routes, live session | `interface.md` §5 |
| C-BG | background delivery registration and launch on change | `queries.md` §5 (design) |
| C-SWIFT | Swift descriptors and async API compile and give the same results | Apple's framework vs Ycode's |

## 5. Open questions (to settle with more probes or a device)

1. Temporal weighting: is the 45 s a pad on every sample or a minimum
   effective duration? Test samples 10 s and 60 s long and instants 10 s
   apart.
2. Source priority default: B (authorized later) beat A. Confirm with a
   third app, with device-generated data, and on a device with the Health
   app's Data Sources list; check whether priority is per type.
3. Merge granularity: is a partly overlapping lower-priority sample always
   dropped whole, or split when it extends beyond the higher-priority
   coverage by more than some threshold? (Observed: dropped whole.)
4. Equivalent-continuous-level average (audio exposure): confirm the
   formula with two samples.
5. Unit factor ordering in `unitString` (length/time before mass in all
   examples).
6. Historical range: confirm that other sources' older samples are hidden
   from sample queries (expected) — needs app B with "past 30 days" reading
   A's old data.
7. Background launch on change in the simulator; observer callbacks after
   predicate filtering (does a save of a non-matching sample fire an
   observer with a predicate?).
8. Collection update handler deliveries and the activity summary values in
   the simulator.
9. Device-only facts (data protection while locked, code 6) need the
   owner's device and team.

## Evidence

Golden values: level 3 (HealthProbe, iOS 27.1 and 27.0; cross-source on
27.1). Rounds and tests: Ycode's plan (no evidence level).
