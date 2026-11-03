# Spec: simulated health data (HealthKit level) for the watchOS and iOS simulators

Status: **draft, round 0** (agent OBS-HEALTH, 2026-10-30); HEALTH-1…3 implemented, §11 (agent HEALTH-SIM, 2026-10-30); open questions 9 and 11 answered in §12 (agent OBS-WATCH3, 2026-10-31); both checked under Ycode in §12.3 (agent WATCH-W7, 2026-10-31). The owner's goal:
send synthetic health data from a simulated Apple Watch (heart rate, ECG,
blood oxygen, steps, sleep, sleep apnea and more) so that a developer can
test how an app handles it through HealthKit. Apps never see raw sensor
data; they see **HealthKit samples**. Ycode therefore simulates health
data at the HealthKit level: it puts samples into the guest's health store
and lets Apple's `healthd`, unchanged in the guest, deliver them to apps,
queries, workout builders and the paired device.

This spec says what Apple's watchOS 27.0 and iOS 27.0 simulators (Xcode
27.1) do with health data, and what Ycode must add. Facts come from files
read as formats (level 2: launchd property lists, the health store's
SQLite schema), black-box runs on the Mac (level 3: our own apps
`research/experiments/health/HealthSim`, `simctl`, guest logs) and bundle
metadata (level 4: names only). No disassembly or decompilation was used.
Raw material is in `research/dirty/health/` (git-ignored); prose in
`research/notes/obs-health-2026-10-30.md`.

Related: `specs/frameworks/healthkit/` (the API, its errors, its
authorization model, the iPhone baseline in `simulator-baseline.md`),
`watchos.md`, `device-pairing.md` (the IDS path that carries sync),
`simulator-features.md` (the guest settings agent and host channel this
design reuses), `sandbox-extensions.md`.

Terms: **DEV** is the device directory (`DEV/data` is the guest's
writable world); **the store** is `DEV/data/Library/Health/`; **system
source** is the device's own HealthKit source (bundle id
`com.apple.health.<UUID>`, name "watchOS Simulator" or "iOS Simulator" on
the device itself, the device name on the paired device).

Every value in this spec, and every value Ycode's tools ship with, is
synthetic. Ycode never imports anyone's real health data.

## 1. Answers in brief

1. **HealthKit works on both simulators.** `healthd` runs from boot on the
   watch and the phone (also on an unpaired watch);
   `isHealthDataAvailable` is true on both. The store is
   `DEV/data/Library/Health/` on both (§2).
2. **Authorization** is HealthKit's own, not TCC: `simctl privacy` has no
   Health service and does not change HealthKit grants. Apps get grants
   only from the system UI — a card and list on the **watch itself** for a
   watch app, the sheet on the phone. Grants are rows in the store's
   `authorization` table, and writing them while the device is shut down
   works (§2.3, §6.4).
3. **Writing**: 26 sample types are read-only for apps, among them ECG,
   AFib burden, sleep apnea events, sleeping breathing disturbances,
   irregular-rhythm, high and low heart-rate events, sleeping wrist
   temperature, exercise/stand/move time and walking heart-rate average.
   Requesting share access to one raises an exception; saving one fails
   with code 4. Everything else the owner listed (heart rate, resting HR,
   HRV, SpO₂, respiratory rate, steps, distance, energy, flights, sleep
   stages, audio exposure, VO₂ max, workouts and routes, mindful minutes,
   heartbeat series) is writable (§3).
4. **Live workout data**: the reference **watch** generates synthetic data
   on its own during a workout session: a sample every 2.56 s of energy,
   distance, steps and the running metrics, and a heart rate every 5 s
   (105–135 bpm), under the watch's system source, tagged with the
   metadata key `HKFakedData`. It keeps generating all-day activity and
   heart rate after the workout ends. The phone's live data source gives
   near-zero values. Another app's samples are **not** collected by a
   live workout builder. Xcode, Device Hub and `simctl` have **no** health
   or workout control (§4).
5. **Sync**: watch and phone sync through one IDS service,
   `com.apple.private.alloy.health.sync.classc`, between the two healthd
   processes. It is event-driven, not per save: phone → watch about 7–40 s
   (the phone's sync timer); watch → phone only when something asks
   (a phone app comes to the foreground: 3.5 s; workout start and end:
   5–8 s). Grants sync as well (§5).
6. **Read-only types**: no reachable built-in path in the reference (a
   demo-data generator exists by name only, §6.1). **Offline seeding**
   works: rows inserted into a shut-down device's store are read back by
   apps through the public API with the right type, value, dates, source
   and device. ECG rows read back, but their voltage data format is
   unknown, so a seeded ECG has no waveform (§6).
7. **Observer and anchored queries** fire 1–2 ms after another process's
   save while the app runs, and deliver a coalesced backlog when it comes
   back to the foreground. **Background delivery never launches or wakes
   an app** in the reference simulator (healthd treats background app
   refresh as unsupported, §7).
8. **For Ycode** (§8): a health guest agent with the HealthKit entitlement
   that writes samples through the public API, pre-seeded grants, a
   `ycode-sim health` command with scenarios and file import, a Device Hub
   section, live heart rate during workouts (Apple's generator for parity,
   Ycode values by opt-in), shut-down seeding for the read-only types, and
   nothing new for sync beyond the existing IDS relay.

## 2. HealthKit in the reference simulators (Q1)

### 2.1 Daemons and availability (level 2 + 3)

| | watchOS 27.0 (24R362) | iOS 27.0 (24A434) |
|---|---|---|
| `com.apple.healthd` | running from boot, paired or not | running from boot |
| Other health jobs | `healtheventsd` (on demand), `fitnesscoachingd`, `fitnessintelligenced`, `sleepd`, `sensorkitd` | `healthappd`, `healthrecordsd`, `healtheventsd`, `healthcontentd`, `fitnesscoachingd`, `fitnessintelligenced`, `finhealthd` (`simulator-baseline.md` §7) |
| healthd Mach services | `com.apple.healthd.server`, `com.apple.healthd.cache-delete`, `com.apple.private.alloy.health.sync.classc-idswake`, `com.apple.private.alloy.healthappnotificationsync-idswake`, `com.apple.aps.ActivitySharing.push`, `com.apple.aps.healthd.cloud.subscription.push` | the watch's set plus `com.apple.private.healthd.pairedsync`, `com.apple.private.alloy.healthapp.messaging`, `com.apple.aps.health.records.push` |
| `HKHealthStore.isHealthDataAvailable` | YES | YES |
| `HKDevice.localDevice` | "Apple Watch", model "Watch", hardware Watch8,3, software 27.0 | "iPhone", "iPhone", iPhone19,2, 27.0 |
| Live-data collectors registered by healthd | a **fake data collector** for 21 types (§4.2) | odometer collectors (motion based, near-zero in the simulator) |

### 2.2 Where the store is (level 2)

Same layout on both: `DEV/data/Library/Health/`

| Path | Role |
|---|---|
| `healthdb.sqlite` (+ WAL files) | unprotected store: sources, devices, **authorization**, sync state; `user_version` 27006 |
| `healthdb_secure.sqlite` (+ WAL files) | protected store: objects and samples; `user_version` 27025 |
| `NanoSync/com.apple.private.alloy.health.sync.db` | paired-device sync state (named after the IDS service) |
| `Local/SyncIdentityHardwareIdentifier.uuid` | 16 bytes: this store's sync identity |
| `Journals/`, `CloudSyncJournals/` | empty |
| phone only: `Client/HealthApp.sqlite`, `ontology/HealthOntology.db` | Health app data, concept ontology |

The watch also keeps per-feature state in
`DEV/data/Library/Preferences/com.apple.private.health.feature-properties.<Feature>.watch.plist`
(names include AFibBurden, ElectrocardiogramRecordingV1,
ElectrocardiogramV2Recording, IrregularRhythmNotificationsV2,
OxygenSaturationRecording, SleepApneaNotifications,
SleepingWristTemperatureMeasurements, CardioFitness,
HypertensionNotifications, MenstrualCycles). Their contents were not read.

### 2.3 Authorization (level 3)

- A **watch app** that requests authorization gets a full-screen card on
  the watch: Health icon, title "Health Access", the text that the app
  "would like to access and update your Health data", a **Review** button
  (which leads to the per-type list) and a close button. Nothing appears on
  the phone. An iPhone app gets the sheet of `authorization.md` §4.1.
- `simctl privacy` lists no Health service. `simctl privacy <dev> reset all
  <bundle>` left the app's HealthKit grants in place; `grant all` added only
  a `kTCCServiceAll` row to the guest's TCC database. **No TCC service
  covers HealthKit.**
- The grants are rows of the store's `authorization` table (§6.4), one per
  (source, type). A request writes the rows at once (status "not
  determined", the "presented" flags of the types asked); the answer
  updates them. Rows written into a shut-down device's store are honoured
  after boot (§6.4).
- A watch app's HealthKit **source is its companion iOS app's bundle id**
  (here `dev.ycode.hs` for the watch app `dev.ycode.hs.watchkitapp`), with
  product type Watch8,3. On the paired phone the same bundle id appears as
  a second source row that came by sync.
- Grants made on one device reach the other by sync (§5.4); each device
  still checks its own row for the local app.
- Nothing about entitlements differs from `simulator-baseline.md` §6: the
  simulated-entitlements section, `application-identifier`,
  `com.apple.developer.healthkit`, the usage strings. A watch app with
  `WKBackgroundModes` = `workout-processing` runs workout sessions.

## 3. Writing: which types an app can save (Q2)

Rule (level 3, identical on both runtimes): a request to **share** any of
26 types raises `NSInvalidArgumentException` "Authorization to share the
following types is disallowed: …" before any UI. Reading them may be
requested. An app that saves one of them anyway gets
`com.apple.healthkit` **code 4 "Not authorized"** (after its read request
was answered) or code 5 (never asked). `HKElectrocardiogram` has no public
initializer at all.

### 3.1 The owner's list and neighbours

| Data | Identifier (suffix) | Kind, store unit | App may save? | Notes |
|---|---|---|---|---|
| Heart rate | `HeartRate` | quantity, count/s (bpm ÷ 60) | **yes** | discrete, temporally weighted |
| Resting heart rate | `RestingHeartRate` | quantity, count/min | **yes** | |
| Walking HR average | `WalkingHeartRateAverage` | quantity, count/min | no (read-only) | |
| HRV (SDNN) | `HeartRateVariabilitySDNN` | quantity, ms | **yes** | |
| HRV (RMSSD) | `HeartRateVariabilityRMSSD` | quantity, ms | **yes** | new in 27.0 |
| HR recovery 1 min | `HeartRateRecoveryOneMinute` | quantity, count/min | **yes** | |
| Heartbeat series | `HKDataTypeIdentifierHeartbeatSeries` | series | **yes** (series builder) | |
| Blood oxygen (SpO₂) | `OxygenSaturation` | quantity, % (0–1) | **yes** | |
| Respiratory rate | `RespiratoryRate` | quantity, count/min | **yes** | |
| Steps | `StepCount` | quantity, count, cumulative | **yes** | |
| Walking + running distance | `DistanceWalkingRunning` | quantity, m, cumulative | **yes** | also cycling, swimming, wheelchair … distances |
| Active energy | `ActiveEnergyBurned` | quantity, kcal, cumulative | **yes** | |
| Basal energy | `BasalEnergyBurned` | quantity, kcal, cumulative | **yes** | |
| Flights climbed | `FlightsClimbed` | quantity, count, cumulative | **yes** | |
| Exercise / stand / move time | `AppleExerciseTime`, `AppleStandTime`, `AppleMoveTime` | quantity, min | no | |
| Stand hour | `HKCategoryTypeIdentifierAppleStandHour` | category | no | |
| Sleep stages | `HKCategoryTypeIdentifierSleepAnalysis` | category: 0 in bed, 1 asleep (unspecified), 2 awake, 3 core, 4 deep, 5 REM | **yes** | |
| Sleep apnea event | `HKCategoryTypeIdentifierSleepApneaEvent` | category | no | |
| Breathing disturbances | `AppleSleepingBreathingDisturbances` | quantity, count | no | the classification helper of `simulator-baseline.md` B7 works on any value |
| ECG | `HKDataTypeIdentifierElectrocardiogram` | ECG sample | no; not even constructible | |
| AFib burden | `AtrialFibrillationBurden` | quantity, % | no | |
| Irregular rhythm notification | `HKCategoryTypeIdentifierIrregularHeartRhythmEvent` | category | no | |
| High / low heart-rate event | `HKCategoryTypeIdentifierHighHeartRateEvent`, `…LowHeartRateEvent` | category (+ threshold metadata) | no | |
| Low cardio fitness event | `HKCategoryTypeIdentifierLowCardioFitnessEvent` | category | no | |
| Hypertension event | `HKCategoryTypeIdentifierHypertensionEvent` | category | no | |
| Wrist temperature (sleeping) | `AppleSleepingWristTemperature` | quantity, degC | no | |
| Body / basal body temperature | `BodyTemperature`, `BasalBodyTemperature` | quantity, degC | **yes** | |
| Environmental audio exposure | `EnvironmentalAudioExposure` | quantity, dBASPL | **yes** | duration ≥ 0.001 s required |
| Headphone audio exposure | `HeadphoneAudioExposure` | quantity, dBASPL | **yes** | duration ≥ 0.001 s |
| Audio exposure events | `HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent` (its value is the older `…AudioExposureEvent` string), `…HeadphoneAudioExposureEvent` | category | no | |
| VO₂ max | `VO2Max` | quantity, ml/(kg·min) | **yes** | |
| Workouts | `HKWorkoutTypeIdentifier` | workout | **yes** | |
| Workout routes | `HKWorkoutRouteTypeIdentifier` | series (locations) | **yes** (route builder, after the workout is saved) | |
| Mindful minutes | `HKCategoryTypeIdentifierMindfulSession` | category | **yes** | |
| State of mind | `HKStateOfMindTypeIdentifier` | state of mind | **yes** | |
| Audiogram | `HKAudiogramSampleType` | audiogram | **yes** | |
| Walking steadiness, its event; walking asymmetry | `AppleWalkingSteadiness`, `…AppleWalkingSteadinessEvent`, `WalkingAsymmetryPercentage` | | no | |
| Running metrics, cycling metrics, effort scores, time in daylight, physical effort, electrodermal activity, perfusion index, falls, water temperature, underwater depth, handwashing, toothbrushing, symptoms | | | **yes** | 161 types saved on the watch in one pass |

### 3.2 The 26 read-only types

`AppleExerciseTime`, `AppleMoveTime`, `AppleStandTime`,
`AppleSleepingWristTemperature`, `AppleSleepingBreathingDisturbances`,
`AppleWalkingSteadiness`, `AtrialFibrillationBurden`,
`WalkingHeartRateAverage`, `WalkingAsymmetryPercentage`, `NikeFuel`
(quantity types); `AppleStandHour`, `AppleWalkingSteadinessEvent`,
`AudioExposureEvent` (= environmental), `HeadphoneAudioExposureEvent`,
`HighHeartRateEvent`, `LowHeartRateEvent`, `IrregularHeartRhythmEvent`,
`LowCardioFitnessEvent`, `HypertensionEvent`, `SleepApneaEvent`,
`InfrequentMenstrualCycles`, `IrregularMenstrualCycles`,
`ProlongedMenstrualPeriods`, `PersistentIntermenstrualBleeding` (category
types); `HKDataTypeIdentifierElectrocardiogram`; the activity summary type.

### 3.3 Validation met while writing (level 3)

Exceptions (`_HKObjectValidationFailureException`) when making the sample,
before any store call: audio exposure quantities with zero duration
("minimum duration … 0.001"); value 0 for the reproductive category types
that start at 1; insulin delivery without its reason metadata ("missing a
required metadata key"); menopausal state longer than its maximum
duration. These are `errors.md` §3's kinds; Ycode's tools must produce
valid samples (§8.3).

## 4. Live data during workouts (Q3)

### 4.1 What the app asks for

`HKLiveWorkoutDataSource` for an outdoor run on the watch lists 11 types to
collect: active and basal energy, walking/running distance, estimated
workout effort score, heart rate, running ground contact time, running
power, running speed, running stride length, running vertical
oscillation, step count. Session states and builder behaviour as in
`interface.md` §5 (states 1 → 2 → 3).

### 4.2 The reference watch's own generator (level 3; names level 4)

At start-up the watch's healthd registers a fake data collector for 21
quantity types: active and basal energy, step count, heart rate, walking/
running distance, the five running metrics, cycling speed, power, cadence
and distance, rowing, paddle-sports, skating and cross-country-skiing
speeds and distances. Its samples:

| Type | Cadence | Duration | Range seen (120 s run) | Total |
|---|---|---|---|---|
| Heart rate | every **5.00 s** | instantaneous | 1.75–2.25 count/s = **105–135 bpm**, mean ≈ 119 | — |
| Step count | every **2.56 s** | 2.56 s | 3–7 | 223 |
| Walking/running distance | 2.56 s | 2.56 s | 6.95–8.43 m | 356 m |
| Active energy | 2.56 s | 2.56 s | 0.014–0.88 kcal | 21.2 kcal |
| Basal energy | 2.56 s | 2.56 s | 0.033 kcal (constant) | 1.52 kcal |
| Running speed | 2.56 s | 2.56 s | 2.72–3.28 m/s | avg 3.0 |
| Running power | 2.56 s | 2.56 s | 153–249 W | avg 201 |
| Ground contact time | 2.56 s | 2.56 s | 151–249 ms | |
| Vertical oscillation | 2.56 s | 2.56 s | 9.9–12.0 cm | |
| Stride length | 2.56 s | 2.56 s | 56–92 **m** (a generator quirk; real strides are about 1 m) | |

- Source: the watch's **system source**; device "Apple Watch", model
  "Watch". Metadata: **`HKFakedData`** on every sample; heart rate also
  `HKMetadataKeyHeartRateMotionContext`.
- The first samples arrive 3 s after `beginCollection`; the builder's
  statistics (sum, average, min, max, most recent) follow the samples.
- The finished workout carries `HKIndoorWorkout` metadata even for an
  outdoor configuration.
- **After the workout** the generator keeps going: heart rate as 5-minute
  quantity-series samples of 61 points (≈ 120 bpm); steps ≈ 1 200 and
  distance ≈ 1 800 m per 10 minutes; active energy ≈ 10 kcal per minute.
  Seen for 17 minutes after the end, until the run stopped. Before the
  first workout of a boot there were none.
- On the **phone**, live sessions collect only near-zero energy and
  distance from its odometer collectors (`simulator-baseline.md` §4.6).

### 4.3 Other sources and the builder

Heart-rate samples that another app saved on the watch during a session
(70–73 bpm, every 10 s) reached the app's queries but **not** its live
builder: the builder's heart-rate minimum stayed at 104 bpm. A live data
source collects only the device's own samples unless the app widens it
with the public `enableCollectionForType:predicate:` (level 1). This
matters for §8.5.

### 4.4 Controls in the reference

None. No string about HealthKit, heart rate, workouts or healthd exists in
Device Hub's executables, SimulatorKit, CoreSimulator, CoreDevice or
`simctl` (level 4, absence), and `simctl` has no health command (level 3).
Apple's public documentation offers no health simulation either (level 1).
Ycode's controls are therefore an extension, not parity.

## 5. Sync between watch and phone (Q4)

### 5.1 Transport

- One IDS service, **`com.apple.private.alloy.health.sync.classc`**,
  between the two healthd processes, through ids_simd and the
  `IDSSimRPC` endpoints of `device-pairing.md` §4. ids_simd adds **no
  delay** for it ("restrictions are currently disabled"). healthd's
  `…health.sync.classc-idswake` Mach service is its wake name.
- Messages in one session: 693, 781–**88 679** bytes (median 1 427). The
  largest is above the 67 KB of `device-pairing.md` §4.3: the relay must
  carry OOL regions of at least 90 KB (more for big backlogs).
- Changes travel as "Changes" requests and responses per sync entity with
  anchors (sample entities, logical-source order, achievements, …).

### 5.2 When it syncs

healthd starts a sync session for a reason it logs:

| Device | Reasons seen |
|---|---|
| watch | remote requested sync; workout samples were associated; syncing after heart rate recovery; user preferences changed; external request from activityawardsd |
| phone | periodic sync timer fired (intervals of 1.5–3 min, and 7 s after a save); client process entered foreground; user characteristics / preferences changed; feature onboarding completed |

### 5.3 Latency (level 3, loaded host)

| Direction | What | Arrived |
|---|---|---|
| watch → phone | app samples saved at rest | **not by themselves** (none within 170 s); 3.5 s after an app on the phone came to the foreground |
| watch → phone | fake workout samples | first two batches 5–7 s after writing; then held until the workout ended; the rest 7 s after the end, the workout object 8 s after |
| phone → watch | app samples (steps, HR, SpO₂) | 16 s (the phone's next timer sync came 7 s after the save) |
| phone → watch | app sleep sample | 37 s |

Synced samples keep their source (the watch app's companion bundle id, or
the watch's system source shown with the watch's device name) and device;
on arrival they fire observer queries like local saves (§7).

### 5.4 Grants sync too

The phone's authorization rows for an app reach the watch as rows of a
second source with the same bundle id (provenance "from the phone"), and
vice versa. Edits made offline to rows that had already synced did not
propagate.

## 6. Read-only types and the store (Q5)

### 6.1 No built-in path

- The reference offers no way to put an ECG, AFib burden, sleep apnea or
  rhythm event into the store: apps cannot save them (§3), the fake
  collector does not make them (§4.2), and there is no simulator control
  (§4.4).
- Level 4 names in the watch runtime show an in-daemon **demo data
  generator** (`HDDemoDataManager`, `HDDemoDataGenerator`, generators for
  heart, sleep, vitals, audio exposure and `HDHRAFibBurdenDemoDataGenerator`,
  among others) and the fake collector (`HDFakeDataCollector`,
  `HDFakeDataGenerator`). How the demo generator is switched on is not
  visible from names; finding it would need level 5, which rule 4 does
  not justify when §6.3 works. Ycode does not depend on it.

### 6.2 The store at the interop level (level 2)

Dates are **seconds since 2001-01-01 00:00 UTC** (REAL). UUIDs are 16-byte
BLOBs. Both files are SQLite in WAL mode and are owned by healthd while the
device runs: Ycode edits them **only while the device is shut down**.

`healthdb.sqlite` (unprotected):

| Table | Columns that matter | Meaning |
|---|---|---|
| `logical_sources` | ROWID, `bundle_id`, `owner_bundle_id` | one per bundle id |
| `sources` | ROWID, `uuid`, `name`, `source_options`, `local_device` (1 = this device's system source), `product_type`, `deleted`, `mod_date`, `provenance`, `sync_anchor`, `logical_source_id`, `sync_identity` | apps, the system source, and sources that came by sync (the same bundle id may have several rows) |
| `source_devices` | name, manufacturer, model, hardware, firmware, software, localIdentifier, FDAUDI, `uuid`, `sync_provenance` | the `HKDevice` values |
| `authorization` | `source_id`, `object_type` (type code), `status`, `request`, `mode`, `date_modified`, `modification_epoch`, `provenance`, `sync_identity`, … ; unique (source_id, object_type) | grants, §6.4 |
| `nano_pairing`, `sync_stores`, `sync_anchors` | | paired-device sync bookkeeping |

`healthdb_secure.sqlite` (protected; not encrypted in the simulator):

| Table | Columns | Meaning |
|---|---|---|
| `objects` | `data_id` (autoincrement), `uuid`, `provenance` → `data_provenances`, `type` (1 = live object; 2 marks a deletion), `creation_date` | every object; `data_id` order is the anchor order |
| `samples` | `data_id`, `start_date`, `end_date`, `data_type` (type code) | every sample |
| `quantity_samples` | `data_id`, `quantity` (in the type's **canonical unit**: heart rate in count/s), `original_quantity`, `original_unit` → `unit_strings` | quantities |
| `category_samples` | `data_id`, `value` | categories |
| `ecg_samples` | `data_id`, `private_classification`, `average_heart_rate` (bpm), `voltage_payload` (BLOB, format unknown), `symptoms_status` | ECGs |
| `quantity_sample_series`, `quantity_series_data` | series key, count; (series, timestamp, value, duration) | series samples (e.g. the generator's 5-minute HR series) |
| `data_provenances` | ROWID, `sync_provenance` (0 = made on this device), origin and local product type and build, `source_id`, `device_id`, `contributor_id`, `source_version`, `tz_name`, origin OS version, `sync_identity`, `derived_flags` | who made a sample, where, with which OS |
| `metadata_keys`, `metadata_values` | key text; (`key_id`, `object_id`, `value_type`, string/number/date/data value) | sample metadata |
| `unit_strings` | unit text | original units |
| `workouts`, `workout_activities`, `workout_events`, `workout_statistics` | | workouts |

### 6.3 Type codes seen (level 3)

| Type | Code | | Type | Code |
|---|---|---|---|---|
| heart rate | 5 | | high heart-rate event | 140 |
| step count | 7 | | ECG | 144 |
| walking/running distance | 8 | | irregular rhythm event | 156 |
| active energy | 10 | | AFib burden | 248 |
| oxygen saturation | 14 | | sleeping wrist temperature | 256 |
| sleep analysis | 63 | | sleeping breathing disturbances | 275 |
| workout | 79 | | sleep apnea event | 276 |

Method (repeatable for any other type): request read access for one type
at a time and read the new `authorization` row's `object_type`.

### 6.4 Authorization encoding (level 3, by writing rows and reading the API back)

| `status` | API status | Effect |
|---|---|---|
| 100 | 0 not determined | saves fail code 5 |
| 101 | 2 sharing authorized | share and read allowed |
| 102 | 2 | share allowed, **read denied** (queries of other sources empty) |
| 103 | 1 sharing denied | read allowed; saves fail code 4 |
| 104 | 1 | both denied |

| `request` | Meaning | Request status |
|---|---|---|
| 0 or 200 | never presented | 1 should request |
| 202 | read presented | read-only request 2, share+read 1 |
| 203 | share and read presented | 2 unnecessary |

Grant-all for an app = its rows with 101/203 for shareable types and
103/202 for the 26 read-only ones, written while the device is shut down.

### 6.5 Offline seeding of samples (level 3)

With the phone shut down, one row each in `objects`, `samples` and the
kind table, with the provenance of the watch's system source, for a sleep
apnea event (category 0), an AFib burden (0.02), an ECG (classification
row, 1.2 bpm, empty payload) and a breathing-disturbances value (5, an
8-hour interval). After boot an app with read access got all four through
the public API: right type, value, dates, source name, device "Apple
Watch", model "Watch", no metadata.

ECG specifics:

- `numberOfVoltageMeasurements` was 0 and `samplingFrequency` nil: an
  empty payload means "no waveform". The payload format is **not known**
  (no ECG producer exists in the simulator to observe one); learning it
  would need level 5.
- Stored → public classification (13 rows): 0→0 not set, 1→5 inconclusive
  poor reading, 2→6 inconclusive other, 3→1 sinus rhythm, 4→2 atrial
  fibrillation, 5→4 inconclusive high HR, 6→3 inconclusive low HR, 7→1,
  8→2, 9→2, 10→4, 11/12/100→0.
- `symptoms_status` 0→0 not set, 1→1 none.

Caveats: seeded rows are not announced to running observers (the device
was off; queries see them at their first run); rows given a provenance that
came from the paired device were **not** synced back to it. Rows with a
local provenance (`sync_provenance` 0) of the device's own system source
are what a real watch would produce; their sync was not tested
(open question 2).

## 7. Observer queries and background delivery (Q6, phone)

| Situation | Result |
|---|---|
| App in the foreground, another app saves | observer and anchored update handlers called 1–2 ms after the save completed |
| App suspended in the background | nothing |
| App back in the foreground | one observer call per changed type and the anchored backlog, within 0.1 s |
| `enableBackgroundDelivery` "immediate" | succeeds; healthd sets 3600 s for step count and heart rate, 1 s for SpO₂ and sleep |
| Matching save while the app is suspended or terminated | healthd logs that it is scheduling launches, then that background app refresh is unsupported on this platform and disabled for the app; **no launch, no resume** |
| Samples arriving by sync | handled like local saves |

`simulator-baseline.md` §4.3 (own saves, ≈1 s) still holds.

## 8. What Ycode must add

Ycode's guests run Apple's own healthd, so the store, the API, observers,
the fake workout generator and the watch–phone sync all come with the
runtime. Ycode adds a way to put synthetic data in, with its own controls.
Requirement ids **H-n**.

### 8.1 Health guest agent

- **H-1** `ycode-health-agent`: a hidden app bundle (`dev.ycode.health`,
  display name "Ycode Health"), built for both iOS and watchOS simulators,
  with `application-identifier`, `com.apple.developer.healthkit` and the
  usage strings in its simulated-entitlements section, installed at cold
  boot like the settings agent (`simulator-features.md` §I.1). A daemon
  client may not get a HealthKit source; an app bundle does (open
  question 1).
- **H-2** It writes samples only through the public API (`saveObjects:`,
  workout and route builders, the heartbeat-series builder), batched (one
  save per batch of up to a few hundred), and sets `HKDevice` values
  ("Apple Watch"/"Watch" on the watch, "iPhone" on the phone, or what the
  file says).
- **H-3** It talks to the host over a host-provided stream socket
  `/private/var/run/dev.ycode.health` with the framing of
  `simulator-features.md` §I.2 (4-byte length + XML plist). Requests:
  `write {samples:[…]}`, `scenario {name, start, options}`, `stream
  {type, values, every}` / `stop`, `delete {source}`, `status`. Replies
  per request with counts and the first HealthKit error. Values are
  validated on the host first (§8.3) so exceptions never reach the agent;
  the agent still catches them.
- **H-4** Samples are attributed to the agent's source. Apps that filter
  on the Apple Watch's system source will not see them: Ycode documents
  this; the read-only types of §8.6 use the system source.

### 8.2 Authorization

- **H-5** At device creation and on `ycode-sim health grant`, while the
  device is shut down, Ycode writes `authorization` rows (§6.4): the agent
  gets 101/203 for every shareable type. Ycode adds the agent's
  `logical_sources`/`sources` rows if healthd has not made them yet
  (otherwise the agent requests once and the rows are updated — open
  question 3).
- **H-6** `ycode-sim health grant <bundle id> [all|<types…>] [--read-only]`
  and `revoke`, for the developer's own app, so tests need no sheet:
  shareable types 101/203, read-only types 103/202, revoke 104. Device
  must be shut down (the command says so and queues the change for the
  next boot like `simulator-features.md` §I.4's pending settings). The
  sheets on both devices stay available for people who want to tap.

### 8.3 Command line and file import

- **H-7** `ycode-sim health …` (the launcher passes words to ycode-simd's
  control socket, as `--ui`/`--location` do):

  | Command | Effect |
  |---|---|
  | `health status` | agent state, grants of the agent, sample counts per type written by Ycode |
  | `health scenario <name> [--date YYYY-MM-DD] [--days N] [--seed S]` | writes a scenario through the agent |
  | `health import <file.json\|file.csv>` | writes the file's samples |
  | `health stream heart-rate --bpm 80..150 [--every 5s] [--for 10m]` | live writes (§8.5) |
  | `health stop` | stops a stream |
  | `health seed <file>` | shut-down seeding of read-only types (§8.6) |
  | `health grant / revoke` | §8.2 |
  | `health clear [--all]` | deletes the agent's samples (public delete API); `--all` erases the store while shut down |

- **H-8** Scenarios (Ycode's own, deterministic for a seed; all values
  plausible and synthetic):

  | Name | Content |
  |---|---|
  | `resting-day` | HR every 5 min 55–75 bpm with a daytime curve, resting HR, HRV SDNN 30–60 ms, respiratory rate 12–16, SpO₂ 95–99 % hourly |
  | `workout` | a 30-min outdoor run (workout + route + HR 120–165 bpm every 5 s + energy/distance/steps every 2.56 s like §4.2) |
  | `night-sleep` | 23:00–07:00 sleep analysis: in bed, then cycles of core/deep/REM with short awake periods (≈ 90-min cycles), plus overnight HR 48–60, respiratory rate, SpO₂ |
  | `spo2-dips` | a night with SpO₂ every 5 min and several dips to 85–89 % (with breathing disturbances seeded when `--with-read-only`) |
  | `step-day` | steps, distance, flights and active/basal energy in hourly blocks summing to a target (`--steps 10000`) |
  | `irregular-heart` | (read-only seed) AFib burden values, an irregular-rhythm event, ECGs classified sinus / AFib |
  | `sleep-apnea` | (read-only seed) breathing disturbances nightly for 30 days, elevated on some nights, and sleep apnea events |

- **H-9** File formats. JSON: `{"version":1, "device":"watch"|"phone",
  "samples":[{"type":"<HK identifier>", "start":"<ISO 8601 or relative
  like -8h>", "end":…, "value":<number>, "unit":"<HKUnit string>",
  "metadata":{…}}], "workouts":[{"activity":"running", "start", "end",
  "energy_kcal", "distance_m", "route":[[lat, lon, time],…]}]}`. CSV:
  header `type,start,end,value,unit` (one sample per line; category
  values as integers or the enum names of `identifiers.md`). The host
  checks each sample against the type table (kind, unit dimension,
  allowed category values, minimum and maximum durations, required
  metadata of §3.3) and refuses read-only types unless `health seed` is
  used. Real health exports are not accepted as such (no Apple Health
  export parser).

### 8.4 IDE

- **H-10** Device Hub ▸ device ▸ Settings gets a **Health** section (Ycode
  only; the reference has none): scenario picker with date, "Import
  file…", "Grant <app> access", "Stream heart rate" with a bpm range
  while running, "Seed read-only data…" (enabled only when the device is
  shut down), and a counter of Ycode-written samples. It drives the same
  commands as H-7. Ycode's own words and icons.

### 8.5 Live data during workouts

- **H-11** Parity: nothing to do. Apple's fake collector runs in Ycode's
  watch guest unchanged and must produce §4.2's data when an app starts a
  session (a conformance test, §9 HEALTH-4).
- **H-12** Developer-chosen live values (`health stream`, opt-in): the
  agent writes HR (and optionally SpO₂, energy) samples at the given
  cadence. Because a live builder ignores other sources (§4.3), the app's
  queries see them but its builder does not. Ycode decision: offer a
  launch option `--health-live-source` that stages a small library into
  the app (the mechanism of `simulator-features.md` §I.6) which, when the
  app creates an `HKLiveWorkoutDataSource`, adds the agent's source to the
  collection predicate through the public `enableCollectionForType:
  predicate:`. The fake collector's own values cannot be changed (open
  question 4); while both run the builder mixes them, so the stream
  command warns.

### 8.6 Read-only types

- **H-13** `health seed` (device shut down): Ycode writes rows into the
  store per §6.2–6.5 for the read-only types (and any other type) with a
  **local provenance of the device's own system source** (creating the
  `data_provenances` row if absent: sync_provenance 0, the device's
  product type and build, the system source, a `source_devices` row
  "Apple Watch"/"Watch"), `objects.type` 1, fresh UUIDs, increasing
  `data_id`. Stored classification values from §6.5's table for ECGs.
- **H-14** ECG waveforms: **documented gap**. Seeded ECGs have
  classification, average HR, symptoms and dates but no voltage
  measurements. Ycode says so in the command's help and in the IDE.
- **H-15** Live insertion of read-only types into a running device is not
  offered (healthd owns the files). Documented gap; the open HealthKit
  target (`specs/frameworks/healthkit/design.md` §10) can lift it later.

### 8.7 Sync to the paired phone

- **H-16** Nothing new: health sync rides the IDS relay of
  `device-pairing.md` (P-6/P-7). The relay must carry OOL regions of at
  least 90 KB (§5.1) and must not add delay.
- **H-17** Ycode's commands write on the device the user names (watch by
  default). Samples written on the watch reach the phone only when the
  phone asks (§5.3), so after a watch import Ycode prints that the phone
  will show them once a phone app comes to the foreground, and `health
  import --open <bundle id>` launches that phone app to trigger the pull.
  Seeded rows sync if their local provenance behaves as on a real watch
  (open question 2); until that is answered, `health seed --both` seeds
  both stores.

### 8.8 Ycode must not

- invent background launches (the reference never wakes apps, §7);
- make the read-only types writable through the API;
- ship or import real health data; scenarios and examples are synthetic.

## 9. Rounds (one clean agent each)

Clean agents read this spec, `specs/frameworks/healthkit/`,
`simulator-features.md` §I and public documentation only. They must not
open the reference tools, Xcode's simulators, `research/dirty/` or Ghidra
projects (`AGENTS.md` rule 3), and must not run Apple's simulator or
Xcode either.

| Round | Name | Work | Depends on | Done when |
|---|---|---|---|---|
| HEALTH-1 | **HEALTH-AGENT** | H-1…H-4, H-5 (agent grants), the host channel, `health status`, `health import` (JSON + CSV, validation of §3.3) | the settings-agent infrastructure; a booting watch and phone guest | under Ycode, `health import` of a 100-sample file shows the samples in a probe app on the watch and on the phone (after the phone app is opened); a read-only type in the file is refused with a clear message |
| HEALTH-2 | **HEALTH-SCENARIOS** | H-7 scenarios of H-8 (writable ones), `health stream`/`stop`, `health clear`, H-6 grant/revoke for any app | HEALTH-1 | each scenario produces the documented sample counts and statistics in a probe app (golden numbers kept in the round's tests); a probe app granted by H-6 reads without a sheet |
| HEALTH-3 | **HEALTH-SEED** | H-13, H-14, H-15: shut-down seeding, the read-only scenarios, ECG classifications | HEALTH-1 | after `health seed` and boot, a probe app reads AFib burden, sleep apnea events, breathing disturbances and ECGs (classification per §6.5) under the watch's source; the gap message is shown for ECG waveforms |
| HEALTH-4 | **HEALTH-LIVE** | H-11 conformance (Apple's generator under Ycode: §4.2's cadences and ranges), H-12 opt-in live source | HEALTH-1, the watch app run destination (`watchos.md` W6) | a probe workout on Ycode's watch shows 2.56 s / 5 s samples with `HKFakedData`; with `--health-live-source` the builder's HR follows `health stream` |
| HEALTH-5 | **HEALTH-IDE** | H-10 Device Hub section; H-17 hints | HEALTH-2 (HEALTH-3 for the seed button) | the IDE drives every command of H-7 and shows counts |

## 10. Open questions

1. Can a launchd daemon (no app bundle) be a HealthKit client with its own
   source? (Decides H-1's packaging; an app bundle is the safe choice.)
2. Do seeded rows with a local provenance (`sync_provenance` 0) of the
   device's own system source sync to the paired device? (Rows with a
   provenance that had come from the peer did not.)
3. Does healthd accept `sources`/`logical_sources` rows that Ycode creates
   before the app has ever connected, or must the app request once first?
   (This round only edited rows healthd had made.)
4. What switches the fake collector on and off, and can its values be
   chosen? (It starts with the first workout of a boot and continued
   after it; its parameters are not public.)
5. ECG voltage payload format (level 5 would be needed; not pursued).
6. How long the post-workout fake activity continues, and whether it
   survives a reboot.
7. Does the watch sync app samples at rest on its own after a longer time
   (we waited 170 s)?
8. Whether `health.sync.classc` backlogs larger than 90 KB occur (a long
   seeded history) and how the relay should size its buffers.
9. On the watch, does a watch app's authorization request write its own
   `authorization` rows before the card is answered (on Ycode only the rows
   synced from the phone existed, and the card still showed after Ycode
   answered them)? Which rows decide a watch app's grant?
   **Answered (§12.1)**: yes, at once (status 100, request 203/202, on a
   local source of the companion's bundle id); the watch's local rows
   decide; answering them offline removes the card.
10. The ECG voltage payload format (as 5): with it Ycode could seed
    waveforms from the note's §6 parameters.
11. What makes the phone's healthd pull the watch's at-rest samples when a
    phone app comes to the foreground (§5.3)? On Ycode the pull did not come
    within 230 s (§11.7), while sync at connection and after workouts works:
    is the trigger a foreground-app notification Ycode's guest does not post
    (FrontBoard/RunningBoard state), or a condition on the app?
    **Answered (§12.2)**: healthd's own process-state monitor; a phone app
    that has run a query entering the foreground makes healthd send a pull
    request (id 2) to the watch, which answers with its changes.

## 11. Ycode implementation (agent HEALTH-SIM, 2026-10-30)

Clean-room: written from §1–§10 of this spec, `specs/frameworks/healthkit/`
(type table, units, enumerations, errors), `simulator-features.md` §I (the
host channel and guest agents), `device-pairing.md` (the relay), the cleared
structural note `research/notes/health-probe-structure.md` (§3–§5, §9 norms,
§10 live-workout cadences) and Apple's public HealthKit headers and
documentation. No Apple binary, simulator or Xcode was read or run. Every
value Ycode writes is synthetic and comes from published population norms.

### 11.1 Rounds

| Round | Status |
|---|---|
| HEALTH-1 agent, channel, grants of the agent, import | **done** |
| HEALTH-2 scenarios, stream/stop, clear, grant/revoke | **done** (grant/revoke answer an app's own request; see §11.4) |
| HEALTH-3 shut-down seeding of read-only types | **done** (ECG without waveform, H-14) |
| HEALTH-4 live (H-11 conformance, H-12 `--health-live-source`) | not started |
| HEALTH-5 Device Hub section | not started (CLI and control socket only) |

### 11.2 The agent (H-1…H-4)

- `ycode/SimGuestAgents/health/ycode-health-agent.m` (Objective-C, public
  HealthKit only), built by `SimGuestAgents/build-health.sh` as
  `out/YcodeHealth.app` (iOS simulator) and `out/watchos/YcodeHealth.app`
  (watchOS simulator): bundle id `dev.ycode.health`, display name "Ycode
  Health", `SBAppTags` hidden, both usage strings, and in
  `__TEXT,__entitlements` `application-identifier` = `dev.ycode.health` and
  `com.apple.developer.healthkit`.
- `ycode-simd` (`HealthAgentStaging.swift`) copies the bundle to
  `DEV/data/Library/Ycode/YcodeHealth.app` at every cold boot and runs its
  executable as a launchd daemon from
  `DEV/data/Library/LaunchDaemons/dev.ycode.simulator.health.plist`
  (`RootedSimulatorPath`, `RunAtLoad`, `KeepAlive`, `ProcessType`
  Interactive; stderr in `DEV/data/tmp/ycode-health-agent.log`), on iOS and
  watchOS runtimes (visionOS: none). Option `--health-agent <app>|none`;
  default `YcodeHealth.app` in the guest tools.
- **Open question 1, answered on Ycode:** a launchd daemon whose executable
  is inside an app bundle with those entitlements *is* a HealthKit client
  with its own source: `HKSource.defaultSource` is "Ycode Health" /
  `dev.ycode.health`; the store's `sources` row is named `YcodeHealth` (the
  name apps see on its samples). The bundle is not installed through
  installd; nothing else was needed. Without the usage strings the share
  request raises `NSInvalidArgumentException` (seen on Ycode).
- Channel (`YcodeSimFeatures/HealthChannel.swift`): the guest path
  `/private/var/run/dev.ycode.health`, served by the VMM
  (`HostStreamSockets.serve`), the settings channel's framing (4-byte length,
  XML plist dictionary) with frames up to 16 MiB; dates are seconds since
  1970 as numbers (an XML plist date keeps whole seconds only). Requests
  `authorize`, `write` (at most 1000 samples a request, saved in batches of
  200), `workout` (`HKWorkoutBuilder`, then `HKWorkoutRouteBuilder`),
  `delete` (`deleteObjectsOfType:predicate:` with the agent's own source),
  `count`, `status`, `ping`; the event `hello`. Every sample carries the
  metadata key `YcodeSynthetic` = 1. The host answers on the control socket
  (`HealthHost.swift`).
- After each hello the host asks the agent to request share and read access
  for every writable type (`HealthTypes.agentShareTypes`, 170 types on the
  27.0 runtimes). From a daemon the request cannot present a sheet: it
  completes with `com.apple.healthkit` code 100 ("Failed to create
  authorization presentation controller") — but healthd has already written
  the agent's rows (status 100, request 203, as §2.3 says for apps).

### 11.3 Grants (H-5, H-6)

- **Ycode decision:** Ycode never creates `sources` or `authorization` rows
  (open question 3 stays open); it only answers rows healthd made for a
  request, as a person tapping Allow would: request 203 → status 101,
  request 202 → status 103; `revoke` → 104 for every row of the bundle id
  (§6.4). Rows of types never asked for are untouched, so the app's own
  request still decides what it has. `YcodeHealthStore/HealthStore.swift`
  (system SQLite) does it with the documented columns only (`status`,
  `request`, `date_modified`), in one transaction, after copying the store's
  `healthdb*` files (with their WAL files) to `DEV/ycode-health-backups/`
  (the newest 5 kept).
- When: at every **cold boot**, before any guest process starts
  (`stageHealthAgent`; never at a snapshot restore, whose healthd has the
  store open), for the agent (when it has rows still waiting) and for the
  queue `DEV/ycode-pending-health.txt`; and at once from
  `ycode-simd --device DEV --health grant|revoke <bundle id>` when the device
  is shut down. On a running device the command queues the change and says
  so. A grant for an app without rows stays queued until the app has asked
  (run it once; the sheet or the watch card opens).
- So a new device needs two boots before the agent writes: the first records
  its request, the second starts granted. Verified (Thor runs r1 → r2): 170
  of 170 rows 101 on both devices at the second boot.
- Developer apps: `health grant dev.ycode.healthcheck` on the shut-down phone
  answered its 17 read requests (17 rows → 103); at the next boot the app's
  read completed at once (`auth requested ok=true`, no sheet) and its
  queries returned data. Grants made on the phone reached the watch's store
  by sync (the watch's rows of the same bundle id were already 103).
- *Superseded by §12.3 (the test app's signature was the cause).*
  **Limit (watch apps):** the watch app's own request on the watch showed the
  Health Access card and left no rows of its own for Ycode to answer (only
  the 17 synced from the phone); the card stayed after the grant. A watch
  app's grant therefore still needs the card (Review → allow) on Ycode. Open
  question 9.

### 11.4 Commands (H-7)

`ycode-simd --device DEV --health <words>` (and the launcher's
`ycode-sim --device DEV --health …`, no boot slot), parsed by
`YcodeSimFeatures/HealthCommand.swift`:

| Command | Device | Effect |
|---|---|---|
| `status` | either | running: agent, authorization, the agent's samples per type (`count`), the stream, the queue; shut down: the agent's rows and the queue |
| `authorize` | running | the agent asks again |
| `import <file.json\|file.csv> [--open <id>]` | running | validated on the host, then written; `--open` prints the phone command that pulls the samples (H-17) |
| `scenario <name> [--date D] [--days N] [--seed S] [--steps N] [--start T] [--with-read-only]` | running | §11.5; without `--date` the last complete day (no sample in the future); `workout` ends now |
| `stream heart-rate\|spo2\|respiratory-rate [--bpm A..B] [--every 5s] [--for 10m]`, `stop` | running | one sample per tick (a slow random walk in the range); on the watch it warns that a live builder ignores other sources (§4.3) |
| `clear` | running | deletes the agent's samples of every type (the public delete API) |
| `grant <id>`, `revoke <id>` | shut down (else queued) | §11.3 |
| `seed <file>`, `seed scenario irregular-heart\|sleep-apnea\|spo2-dips […]` | shut down | §11.6 |

Exit 0 for "ok", 1 for an error, 64 for bad usage, 69 for a command that
needs the other device state.

### 11.5 Import and scenarios (H-8, H-9)

- **Import** (`HealthImport.swift`): §8.3's JSON and CSV. Times: ISO 8601
  (with offset, fractional seconds or a date alone), the export form
  `yyyy-MM-dd HH:mm:ss Z`, seconds since 1970, or relative (`now`, `-8h`,
  `+30m`, `-2d`). Types: identifiers, short names, aliases (`spo2`,
  `sleep`). Category values: integers or enumeration case names (`AsleepCore`,
  `core`). Checks per sample (`HealthValidation`): known type; read-only
  types refused with "… is read-only for apps … seed it into a shut-down
  device instead: ycode-sim --device DEV --health seed <file> (HEALTH-3)";
  unit parses (units.md §2, `HealthUnits.swift`) and is of the type's
  dimension (identifiers.md); percentages as fractions; cumulative values
  not negative; category value allowed; end not before start; maximum
  durations (identifiers.md), the audio-exposure minimum 0.001 s and the
  required metadata of §3.3 (insulin delivery reason; menstrual flow's
  cycle start). Errors name the line or entry. Sample files:
  `ycode/Samples/HealthSamples/` (`hundred-samples.json`, `mixed.csv`,
  `read-only.csv`).
- **Scenarios** (`HealthScenarios.swift`; SplitMix64, deterministic for a
  seed; a per-seed profile inside the norms of the note's §9):

| Name | Content (per day) | Samples (seed 1) |
|---|---|---|
| `resting-day` | HR every 300 ± 45 s (daytime curve, 5–10 bpm lower 23:00–07:00, motion context sedentary), one resting HR, HRV SDNN every ~2 h (60 s windows, 20–80 ms), SpO₂ hourly 95–99 % with barometric pressure, respiratory rate every ~10 min asleep (12–16, half steps), steps/distance/active energy in 10-min windows 07:00–23:00, basal energy hourly | 685 |
| `workout` | a 30-min outdoor run (activity 37): the workout, a 1 801-point route (1 s), HR every 5.00 s (ramp to the plateau in 90 s, 120–165 bpm, motion context active), energy, basal energy, distance and steps every 2.56 s (the simulator collector's grid, §4.2; the note's §10 real-device grid is 2.569 s) | 3 172 + route |
| `night-sleep` | in bed 22:50 → wake + 5 min; 5 cycles of 85–100 min from 23:05–23:15: Core first, Deep early, REM late (first after 60–120 min), awake 2.5–6.5 min between cycles and sometimes inside Core; back-to-back segments with `HKTimeZone`; overnight HR, respiratory rate, SpO₂ every 1 801 s, HRV | 199 |
| `spo2-dips` | 23:00–07:00 SpO₂ every 300 s at 95–99 % with 3–6 dips to 85–89 %; respiratory rate; with `--with-read-only` an elevated breathing-disturbances value for `seed` | 145 |
| `step-day` | hourly steps summing to `--steps` (default the profile's 4 000–10 000), distance, active energy, flights, basal energy | 78 (9 000 steps) |
| `irregular-heart` (seed) | AFib burden for the week, an irregular-rhythm event, ECGs classified sinus / AFib / sinus | 5 |
| `sleep-apnea` (seed) | breathing disturbances per night (8.5 h window; elevated ≥ 11 about one night in four), an apnea event (30-day window) on elevated nights | 36 for 30 days |

### 11.6 Seeding (H-13…H-15)

`YcodeHealthStore/HealthSeed.swift`, in one transaction after a backup: per
sample one row in `objects` (fresh UUID, `type` 1, the provenance),
`samples` (dates since 2001, the §6.3 type code) and the kind table
(`quantity_samples.quantity` in the store unit of §3.1, `category_samples`,
`ecg_samples` with the stored classification of §6.5, the average heart
rate, the symptoms status and an **empty voltage payload**). The provenance
is a local (`sync_provenance` 0) `data_provenances` row of the system source
(`sources.local_device` 1): an existing one is reused (both Thor devices had
one), else a local row is copied whole and given the system source and the
device's `source_devices` row. Only types with a known code are accepted
(§6.3); others are refused with that reason. The command prints the ECG gap
(H-14). Live insertion is not offered (H-15).

Verified (run r3/r4): after `seed scenario irregular-heart` and `seed
read-only.csv` on the shut-down phone and `seed scenario sleep-apnea --days
30` on the shut-down watch, HealthCheck on the phone read AFib burden (2),
breathing disturbances (31), sleep apnea events (7), the irregular-rhythm
event (1) and three ECGs (classification 1/2/1, average 66–92 bpm,
`numberOfVoltageMeasurements` 0) through `HKSampleQuery`. **Open question 2,
answered on Ycode:** the 36 rows seeded on the watch (local provenance of
its system source) reached the phone by sync and show there with device
model Watch and the watch's device name as source.

### 11.7 Sync and the relay (H-16, H-17)

- The relay (`PairingTransportRelay`) already carries out-of-line regions up
  to 1 GiB, one frame up to its 4 MiB chunk, pieces beyond; health sync
  needs nothing new. `PairingTransportRelayTests.healthSyncSizedMessagesCrossInOneFrame`
  sends §5.1's sizes (693 B … 88 679 B) plus 92 160 B and 256 KiB: each
  crosses in one frame, byte for byte, in order, in under 2 s.
- On the Thor (run r2): 3 272 samples written on the watch (the 100-sample
  import, a workout of 3 172 samples) were in the phone's store when its
  `health status` ran, 1.1 s after the watch's workout was saved (the
  workout starts a sync, §5.2), before any phone app had opened; the phone's HealthCheck
  showed them with device model Watch next to the phone's own (run r3:
  heart rate "Watch 687, iPhone 397"). The phone's `clear` and its own
  samples reached the watch the same way.
- The relay carried healthd's sync messages without change: run r6's phone
  received 53 requests from the watch, the largest **91 913 bytes** (one
  frame, one-way median 1.5 ms, none failed).
- *Superseded by §12.3 (the test app's signature was the cause; the pull
  works).* **Finding (Ycode):** watch samples written at rest, with no workout, did
  not reach the phone when a phone app came to the foreground (runs r4–r6:
  HealthCheck sent to the background by Settings and opened again, then
  watched for 230 s; §5.3 has 3.5 s on the reference). They arrived at the
  pair's next boot (r5's 763 at-rest watch samples were on the phone 90 s
  into r6) and with the next workout. Until that is understood (open
  question 11), write a `workout` scenario on the watch, or reboot the pair,
  to push at-rest watch samples to the phone.

### 11.8 Verification (Thor, iPhone 18 Pro iOS 27.0 + Apple Watch Series 12 46 mm watchOS 27.0, paired)

Ycode's reader app `SimGuestAgents/healthcheck/HealthCheck.swift` (iOS app
with its watch app embedded; read access to 17 types; one
`HKObserverQuery` per type, an `HKSampleQuery` per observer call; it logs
counts, sources and device models). Runs `ide-remote/health-sim/runs/r1`–`r5`:

| Check | Result |
|---|---|
| import (100 samples, JSON) on the watch | 100 of 100 in 65–71 ms |
| import of read-only types | refused, one line per sample, pointing to `health seed` |
| scenarios on the phone | resting-day 685 in 391–512 ms, night-sleep 199, spo2-dips 145, step-day 78, workout 1 + 3 172 in 2.2–3.2 s |
| HealthCheck on the phone | every written type read with the agent's source ("YcodeHealth"), metadata `YcodeSynthetic` on all |
| observer while the app runs | `stream heart-rate --every 5s --for 30s`: one observer call and one more sample per write (791 → 797); a workout written while the app ran: anchored growth in steps of 50 |
| user app granted by `health grant` | no sheet at the next boot; reads |
| watch → phone | §11.7: after a workout and at the pair's boot; not on app foreground (finding) |
| read-only seeding | §11.6 |
| `clear` | 8 255 samples deleted on the phone; HealthCheck counts went to 0 |

Screenshots (outside the repository): `.claude/worktrees/health-sim-phone-readonly-and-agent.png`
(seeded read-only types and agent data), `health-sim-phone-watch-synced.png`
(counts per device model), `health-sim-phone-scenarios.png`,
`health-sim-phone-sheet.png` (the app's own permission sheet),
`health-sim-watch-card.png` (the watch app's card).

### 11.9 Not done

- HEALTH-4 (H-11 conformance of Apple's fake collector under Ycode, H-12
  `--health-live-source`), HEALTH-5 (Device Hub section).
- `health import --open` only prints the phone command (the watch's
  ycode-simd cannot launch apps on the phone); `health seed --both` is not
  offered (seeded watch rows sync by themselves, §11.6).
- Watch-app grants without the card (§11.3).

## 12. Dirty-room answers to open questions 9 and 11 (agent OBS-WATCH3, 2026-10-31)

Reference: Xcode 27.1; throwaway `ycode-test-phone3-a` (iPhone 18 Pro, iOS
27.0) paired with `ycode-test-watch3-a` (Series 12 46 mm, watchOS 27.0),
deleted at the end. Our HealthSim probe (watch app `dev.ycode.hs.watchkitapp`,
companion `dev.ycode.hs`; a copy `dev.ycode.hs3` for a fresh identity), the
stores read from copies with `sqlite3`, guest logs at debug level. The
watch's Health Access card was answered with our own Indigo taps after
dtuhidd was kept from starting in that test watch (`watchos.md` §5.2); no
GUI. Notes: `research/notes/obs-watch3-2026-10-31.md`. Level 3.

### 12.1 Open question 9: a watch app's authorization

- **The request writes the watch's own rows at once**, before the card is
  answered: a source for the **companion's** bundle id with provenance 0
  (made on the watch; `local_device` 0), and one `authorization` row per
  type: `status` 100, `request` 203 (share and read) or 202 (read-only
  types), `mode` 0, `provenance` 0, `modification_epoch` 0. healthd logs
  "Enqueuing authorization request for <companion id>", "Marking health as
  in use: Authorization status changed for source <n>" and "prompting for
  authorization"; Carousel presents the card (the alert
  `com.apple.healthkit.AuthorizationAlert`).
- **The same happens when the phone's rows for that bundle id are already
  on the watch** (they arrive by sync as a second source, provenance 1, with
  their own rows): the watch app's request still creates its local source
  and rows, and **only the local rows decide**. Synced rows set to 101 with
  the local rows at 100 → request status 1 and the card again.
- **Allowing on the watch**: Review → "Allow Write Access" (a toggle for all
  requested types) → Next → "Allow Read Access" (same) → Continue → "How
  much historical data do you want to share" (Past 30 Days … Full History)
  → Done. Nothing is written before **Done**; then each row becomes
  `status` **101** (request unchanged), `date_modified` the time of Done,
  `modification_epoch` +1, `deleted_object_anchor` advanced, and, with
  Full History, `object_limit_anchor` 0 and `object_limit_modified` null.
  The app's completion comes at Done with success. Closing the card with ✕
  sets every newly presented row to **104** (epoch +1); the completion
  still reports success.
- **Answering offline works for watch apps**: on a shut-down watch, the
  local rows 100 → 101 (request 203) gave, at the next launch, request
  status 2 and a `requestAuthorization` that completed in 8 ms **without
  the card**, status API 2. The same rows set back to 100 → request status
  1 (the card would show).
- **No non-GUI grant in the reference**: `simctl privacy` (27.1) has no
  Health service, `devicectl` has no health command; the store edit is the
  way.
- The watch's local grant had not reached the phone 2 min later (it
  travels with the next pull, §12.2).

**What Ycode must do** (H-5, H-6 refined):

- Ycode's `grant` is right as designed: answer the rows healthd wrote
  (203 → 101, 202 → 103) on a shut-down device; for a watch app answer the
  **watch's local** rows (provenance 0, the companion's bundle id), never
  only the synced ones.
- Ycode's §11.3 limit (no local rows after the watch app's request) is
  **not** reference behavior: the reference writes them at the request.
  Compare the watch's healthd log under Ycode with the three lines above;
  the request reaches healthd, and healthd looks up the watch app and then
  its companion through LaunchServices (the companion is not installed on
  the watch: "failed to find bundle record", then a companion-bundle
  lookup) before it enqueues. Once the rows exist, `health grant
  <companion id>` on the shut-down watch removes the card.

### 12.2 Open question 11: what pulls the watch's at-rest samples

- **The trigger is a HealthKit client that has run a query entering the
  foreground on the phone.** When an app starts a query, the phone's
  healthd registers a process-state observer for its bundle id ("Registering
  observer <query manager> for process state changes for <bundle id>") and
  follows its application state ("Process <bundle id> (<pid>) state
  changed BKSApplicationState… -> BKSApplicationStateForegroundRunning:
  … foreground 0 -> 1"). On the change to foreground it logs **"syncing
  immediately with reason "client process entered foreground"
  options:'pull request'"**. The registration lasts for the bundle id
  (a relaunch with no query still triggered).
- No pull: our app with no HealthKit use, Settings, and a HealthKit app
  that had only asked for authorization (no query), each brought to the
  foreground; and nothing at rest for 2 min 15 s.
- **The pull on the wire** (`health.sync.classc`, IDS message id **2**): the
  phone sends one "Changes" request (826 B) whose session is Finished with
  no changes and whose status is ChangesRequested. The watch's healthd logs
  "syncing immediately with reason "Remote requested sync"
  options:'requested by remote'", runs a session (40 ms) and sends its
  changes as Changes requests (four, 438–743 B, id 2) about 1.4 s after
  the pull left the phone (ids_simd's link delay); the phone applies them
  and answers each.
- Times: samples on the phone ≤ 3.7 s after the app's first foreground,
  ≤ 5.3 s after a return from the background (BackgroundTaskSuspended →
  ForegroundRunning). Sent to the background (ForegroundRunning →
  BackgroundRunning → BackgroundTaskSuspended) the app causes nothing.

**What Ycode must do** (H-16, H-17 refined):

- Nothing to invent: healthd does all of it. Ycode's guest must deliver
  application-state changes to healthd's monitor as the reference does
  (the application state that RunningBoard and FrontBoard keep for every
  app; `app-launch.md`). The check, in order, on Ycode's phone: the
  registration line when the app's query starts; the "state changed …
  ForegroundRunning" line when it returns; the "client process entered
  foreground" pull; an outgoing request id 2 of about 830 B; on the watch
  "Remote requested sync" and its Changes requests; the samples in the
  phone's store. §11.7's finding stops at the first missing line.
- Until then §11.7's workaround stands (a workout, or the pair's next
  boot); `health import --open` should open a phone app **that runs a
  query** (HealthCheck does).

### 12.3 Ycode implementation (agent WATCH-W7, 2026-10-31)

Clean-room check of §12.1 and §12.2 on Ycode's own simulator (arm64 Linux
host; iPhone 18 Pro on iOS 27.0 paired with an Apple Watch Ultra 4 49 mm
on watchOS 27.0; runs b1–b3; guest `log stream --level debug` of healthd
and the apps; the stores read from copies with SQLite). No Apple simulator,
Xcode or reference tool was run or opened.

**The cause of both §11 limits was Ycode's test app, not the simulator.**
`SimGuestAgents/build-health.sh` linked HealthCheck with the linker's own
ad-hoc signature, whose identifier is the file name ("HealthCheck",
"HealthCheckWatch"), not the bundle id that a real build's signature
carries. healthd keys a client by that identifier:

- **§12.1 (run b1, before):** the watch's healthd looked up an app record
  for "HealthCheckWatch", then enqueued the request for the watch app's
  own id: "Enqueuing authorization request for
  dev.ycode.healthcheck.watchkitapp", "prompting for authorization"; no
  companion lookup. Its rows went to a local source of the watch app's id
  (status 100, request 202), not of the companion, so `health grant
  dev.ycode.healthcheck` found only the synced rows (§11.3's limit).
- **§12.2 (run b1, before):** the phone's healthd logged "Registering
  observer … for process state changes for **HealthCheck**" and never a
  state change for it (no application has that bundle id); system apps'
  state changes were delivered ("Process
  com.apple.Health.HealthBalanceWidgetExtension (350) state changed
  BKSApplicationStateUnknown -> BKSApplicationStateBackgroundRunning …"),
  so Ycode's guest delivers application state to healthd's monitor
  already. No pull followed (§11.7's finding).

**Fix** (test apps only): `build-health.sh` and `build-wcprobe.sh` now sign
each app bundle ad hoc with `codesign --sign - --entitlements …`, the inner
watch app first, so the signature's identifier is the bundle id (the
entitlements stay in `__TEXT,__entitlements` too). Apps built by Xcode,
`xcodebuild` or Ycode's build engines are signed that way already. No
change to `ycode-simd` or the guest was needed for §12.1 and §12.2.

**§12.1 under Ycode after the fix (runs b2, b3):**

| Check | Result |
|---|---|
| watch healthd on the watch app's request | "Enqueuing authorization request for **dev.ycode.healthcheck**", "Added authorization request … to group for dev.ycode.healthcheck", "prompting for authorization for "dev.ycode.healthcheck""; the card shown (`watch-w7-health-watch-card-before-grant.png`). §12.1's "Marking health as in use …" line was not printed at the levels streamed |
| the watch's rows | a new **local source of the companion** (provenance 0, `local_device` 0) with 17 rows status 100, request 202, beside the synced source of the same id (provenance 1) — as §12.1 |
| `ycode-simd --device watch --health grant dev.ycode.healthcheck` (shut down) | "34 types: 0 share and read, 34 read only" (both sources' 17 rows → 103) |
| next boot, the watch app opened | **no card**; the app read its types at once (`watch-w7-health-watch-granted-no-card.png`) |

Ycode decision: `health grant` / `revoke` given a **watch app's** id map it
to its companion's (`WKCompanionAppBundleIdentifier` of the app installed on
that device, `YcodeHealthStore/HealthWatchApps.swift`), with a note; a
watch-only app keeps its own id. Test `HealthWatchAppTests`.

**§12.2 under Ycode after the fix (run b3):** 100 samples written on the
watch at rest (`health watch import`), 30 s later HealthCheck opened on the
phone (its first foreground in that boot). §12.2's lines, in order, with
the phone's and the watch's clocks:

| Time | Device | Line |
|---|---|---|
| 06:49:42.900 | phone | HealthCheck starts (its log) |
| 06:49:43.162 | phone | "Registering observer <HDQueryManager …> for process state changes for dev.ycode.healthcheck" |
| 06:49:43.198 | phone | "Process dev.ycode.healthcheck (406) state changed BKSApplicationStateUnknown -> BKSApplicationStateForegroundRunning: … foreground 0 -> 1" |
| 06:49:43.203 | phone | "syncing immediately with reason "client process entered foreground" options:'pull request'" |
| 06:49:43.355 | phone | "health.sync.classc" outgoing request messageID:2, a "Changes" request with status Finished and no changes |
| 06:49:43.581 | watch | "syncing immediately with reason "Remote requested sync" options:'requested by remote'" |
| 06:49:44.659, 45.659 | phone | the watch's Changes received (1 522 B, 1 043 B, …) |
| 06:49:45.734 | phone | HealthCheck: heart rate 40 → **80**, all "Watch" |

**Samples on the phone 2.8 s after the app's first foreground** (§12.2's
reference: ≤ 3.7 s). Sent to the background (Settings opened: Foreground
→ BackgroundRunning → BackgroundTaskSuspended, no pull), 100 more samples
written on the watch, then HealthCheck opened again: the pull at
06:50:39.650 (0.001 s after the state change) and the samples (80 → 120)
on the phone at 06:50:41.738, **2.1 s** after the return (reference ≤ 5.3
s). Screenshot `watch-w7-health-phone-pulled-watch-samples.png`.

So §11.3's "Limit (watch apps)" and §11.7's "Finding (Ycode)" no longer
hold for correctly signed apps; the `health import` reply on a watch now
says that a phone app running HealthKit queries pulls the samples when it
comes to the foreground.

## Evidence

| Claim | Level | Source |
|---|---|---|
| healthd running, availability, local device (§2.1) | 3 | `launchctl list`, probe `info` on both devices |
| healthd Mach services, other launch daemons (§2.1) | 2 | runtime launchd property lists |
| Fake collector registration and type list (§2.1, §4.2) | 3 | healthd log "Registered <HDFakeDataCollector…>" |
| Store paths, files, user versions, per-feature plists (§2.2) | 2 | device data directory listing, `sqlite3` on copies |
| Watch authorization card; phone sheet (§2.3) | 3 | screenshots (`research/dirty/health/`) |
| `simctl privacy` has no Health service and does not affect grants (§2.3) | 3 | `simctl help privacy`; reset/grant then request status |
| Watch app's source is the companion bundle id (§2.3) | 3 | sources table; sample source on watch and phone |
| The 26 share-disallowed types; codes 4 and 5 (§3) | 3 | probe `auth all`, `write` on both runtimes |
| ECG has no public initializer (§3) | 1 | SDK headers |
| Validation rules met (§3.3) | 3 | probe exceptions |
| Data source types, generator cadence, ranges, metadata, post-workout data (§4.1–4.2) | 3 | probe `workout` (raw samples and builder statistics) |
| Builder ignores other sources (§4.3) | 3 | two watch apps, one in a session |
| `enableCollectionForType:predicate:` (§4.3, H-12) | 1 | public API |
| No health controls in Device Hub, SimulatorKit, CoreSimulator, CoreDevice, simctl (§4.4) | 4 (absence of strings) + 3 (`simctl help`) | string search |
| Sync service name, no delay, sizes (§5.1) | 3 | ids_simd and healthd logs |
| Sync reasons and latencies (§5.2–5.3) | 3 | healthd logs, probe `burst` / `observe` with writer timestamps |
| Grant rows sync (§5.4) | 2 + 3 | store copies before and after |
| Demo data generator and fake collector names (§6.1) | 4 | string search of the watch runtime's shared cache (names only) |
| Table and column names and meanings (§6.2) | 2 | `sqlite3 .schema` on copies; meanings from values seen |
| Type codes (§6.3) | 3 | one-type requests, new rows |
| Authorization encoding (§6.4) | 3 | rows written while shut down, public API read back |
| Offline seeding, ECG mapping, payload gap (§6.5) | 3 | rows inserted while shut down, public API read back |
| Observer timing, suspension, background delivery clamp and no launches (§7) | 3 | probe `observe`, healthd log |
| Everything in §8–§9 | design | Ycode-original |
| Ycode implementation (§11): agent, channel, commands, import, scenarios, grants, seeding | 1 | §1–§10; `specs/frameworks/healthkit/`; Apple's public HealthKit headers (HKHealthStore, HKWorkoutBuilder, HKWorkoutRouteBuilder, HKQuery predicates); SQLite's public C API; population norms of the cleared note's §9 |
| A daemon in an app bundle is a HealthKit client with its own source; the request's code 100 and the rows it writes (§11.2–11.3) | 3 | Ycode runs e1–e3 and r1–r2 on the Thor: the agent's log, `HKSource.defaultSource`, `authorization` rows (documented columns) of the Ycode-booted device (no reference observed) |
| Grants answered offline honoured; read-only seeding read back; watch-seeded rows sync to the phone; watch → phone sync after a workout; observer per write (§11.3–11.8) | 3 | Ycode runs r2–r5: HealthCheck's log and screenshots, `health status` (no reference observed) |
| Relay carries health-sync-sized messages (§11.7) | 1 | `PairingTransportRelayTests` |
| A watch app's request writes local rows at once; local rows decide; what Done and ✕ write; offline answers honoured without the card; no non-GUI grant (§12.1) | 3 | HealthSim (and the `hs3` copy) on a paired test phone and watch; copies of both `healthdb.sqlite` read with `sqlite3` before and after each step; our Indigo taps on the card; healthd and Carousel logs; `simctl privacy` and `devicectl` help |
| The pull's trigger, the process-state lines, the request and the watch's answer, times; the negatives (§12.2) | 3 | HealthSim writing on the watch, apps brought to the phone's foreground with `simctl launch`; copies of the phone's `healthdb_secure.sqlite` counted by sync provenance every 1–5 s; both healthd logs at debug level |
| Requirements from §12 | — | Ycode decisions from the above |
| Ycode runs b1–b3: the signing identifier as healthd's client key, the companion's local rows, the grant without the card, the pull sequence and times (§12.3) | 3 | Ycode's own simulator on the arm64 Linux host: guest `log stream --level debug` of healthd and the apps, copies of `healthdb.sqlite` read with SQLite, HealthCheck's log, `--control screenshot`; `codesign -d` of our own test apps |
| `health grant` of a watch app's id → its companion (§12.3) | — | Ycode decision; `HealthWatchAppTests` |
