# OBS-HEALTH observations (agent OBS-HEALTH, 2026-10-30)

Dirty-room notes behind `specs/simulator/health-simulation.md`. Prose
only. Raw logs, store copies, screenshots and string lists stay in
`research/dirty/health/` (git-ignored). No disassembly or decompilation;
Ghidra and the reference tools folder were not opened. Bundle metadata
(level 4) was limited to string searches for names in the installed
Xcode's simulator frameworks, Device Hub and one pass over the watchOS
runtime's shared cache.

Our code: the HealthKit probe `research/experiments/health/HealthSim/`
(Objective-C core + SwiftUI shell, one source for the iPhone app
`dev.ycode.hs`, a second iPhone app `dev.ycode.hs.b` and the watch app
`dev.ycode.hs.watchkitapp`; a copy with bundle `dev.ycode.hs2.watchkitapp`
for one test). Its type table is generated from the SDK header's
identifier comments (names, units, aggregation styles). Every value the
probe wrote is made up.

## Setup

- Xcode 27.1. Devices created for this round only and deleted at the
  end: `ycode-test-health-phone` (iPhone 18 Pro, iOS 27.0 24A434),
  `ycode-test-health-watch` (Apple Watch Series 12 46 mm, watchOS 27.0
  24R362), paired; later `ycode-test-health-watch2` (same type, unpaired)
  for the live-builder source test. At most one phone and one watch
  booted at a time.
- Host load 16–40 at rest, up to about 1000 for a few minutes after each
  paired boot. Times below are upper bounds when they include healthd's
  start-up.
- Logs: `simctl spawn … log stream` at info level for healthd, ids_simd
  and the probe apps on each device.
- No GUI was used. The phone's and the watch's authorization sheets were
  **not answered**: legacy Indigo touches are suppressed on both
  runtimes while CoreDevice's `dtuhidd` is active (its notify state was 1
  on the phone too), the watch gesture path does not press the sheet's
  button, and the simulator-input tool that would have tapped needs the
  owner's per-device consent, which was not given. Grants were therefore
  made by **editing the authorization table of a shut-down device's
  store** (below); that experiment also answers part of Q5.

## Q1: HealthKit in the two simulators

- `healthd` runs from boot on both (`launchctl list`), also on an
  unpaired watch. `HKHealthStore.isHealthDataAvailable` is YES on both.
  `HKDevice.localDevice`: watch "Apple Watch" / "Watch" / Watch8,3 /
  27.0; phone "iPhone" / "iPhone" / iPhone19,2 / 27.0.
- Watch launch daemons with "health" in the name: `com.apple.healthd`,
  `com.apple.healtheventsd`, plus `fitnesscoachingd`,
  `fitnessintelligenced`, `sleepd`, `sensorkitd`. No `healthappd`,
  `healthrecordsd`, `healthcontentd` (the phone has them).
- healthd's Mach services (launchd property lists): phone
  `com.apple.healthd.server`, `…healthd.cache-delete`,
  `com.apple.private.healthd.pairedsync`,
  `com.apple.private.alloy.health.sync.classc-idswake`,
  `…alloy.healthapp.messaging`, `…alloy.healthappnotificationsync-idswake`,
  three `com.apple.aps.*` names; watch the same minus `pairedsync`,
  `healthapp.messaging` and the health-records push name.
- Store on both: `DEV/data/Library/Health/` with `healthdb.sqlite`,
  `healthdb_secure.sqlite` (WAL), `NanoSync/com.apple.private.alloy.health.sync.db`,
  `Local/SyncIdentityHardwareIdentifier.uuid`, empty `Journals/` and
  `CloudSyncJournals/`. The watch has no `Client/` and no `ontology/`.
  Watch `user_version`s 27006 / 27025 (45 and 151 tables), as on the phone.
  The watch also carries per-feature property lists
  `com.apple.private.health.feature-properties.<Feature>.watch.plist`
  (AFibBurden, ElectrocardiogramRecordingV1/V2, IrregularRhythmNotificationsV2,
  OxygenSaturationRecording, SleepApneaNotifications,
  SleepingWristTemperatureMeasurements, CardioFitness, Hypertension…,
  MenstrualCycles…) in `Library/Preferences`.
- Authorization: on the watch the request shows a full-screen card on the
  watch itself ("Health Access", "“HealthSim” would like to access and
  update your Health data.", a "Review" button, a close button). On the
  phone the sheet of `authorization.md` §4.1 (here "Select All 370
  Topics" for 173 share + 199 read types). `simctl privacy` has no Health
  service; `simctl privacy reset all <bundle>` left the HealthKit grants
  unchanged, and `grant all` only wrote a `kTCCServiceAll` row to TCC.
  HealthKit's grants live in healthd's own store, not in TCC.
- The watch app's HealthKit **source is the companion's bundle id**
  (`dev.ycode.hs`, not `dev.ycode.hs.watchkitapp`), on the watch and on
  the phone after sync; product type Watch8,3.

## Q2: writing

- The first request for every sample type raised one exception listing
  the 26 types that may not be shared (identical on both runtimes):
  AppleExerciseTime, AppleMoveTime, AppleStandTime, AppleStandHour,
  AppleSleepingWristTemperature, AppleSleepingBreathingDisturbances,
  AppleWalkingSteadiness, AppleWalkingSteadinessEvent,
  AtrialFibrillationBurden, WalkingHeartRateAverage,
  WalkingAsymmetryPercentage, NikeFuel, Electrocardiogram,
  IrregularHeartRhythmEvent, HighHeartRateEvent, LowHeartRateEvent,
  LowCardioFitnessEvent, HypertensionEvent, SleepApneaEvent,
  AudioExposureEvent (the value of the environmental-audio-exposure-event
  constant), HeadphoneAudioExposureEvent, InfrequentMenstrualCycles,
  IrregularMenstrualCycles, ProlongedMenstrualPeriods,
  PersistentIntermenstrualBleeding, and the activity summary type. Read was
  allowed for all 199 types requested.
- With share granted (seeded) for the rest and read granted for the 26:
  every other type saved on the watch (161 saves, 1–15 ms each) given a
  valid value; the 26 failed with code 4 "Not authorized". Construction
  rules met on the way: audio exposure quantities need a duration of at
  least 0.001 s; reproductive category types reject value 0; insulin
  delivery needs its reason metadata; menopausal state has a maximum
  duration below 5 min. ECG cannot be constructed by an app (no public
  initializer). Workout, workout route (5 points), heartbeat series (10
  beats), audiogram and state of mind saved.

## Q3: live workout data on the watch

- `HKLiveWorkoutDataSource` for outdoor running lists 11 types to collect:
  active and basal energy, walking/running distance, estimated workout
  effort score, heart rate, running ground contact time, power, speed,
  stride length, vertical oscillation, step count.
- The watch's healthd registers a **fake data collector** for 21 quantity
  types at start-up (log: "Registered <HDFakeDataCollector…>"): active
  and basal energy, step count, heart rate, the running metrics, cycling
  speed/power/cadence/distance, rowing, paddle, skating and
  cross-country-skiing speeds and distances. The phone registers odometer
  collectors instead.
- During a 120 s run: one sample every **2.56 s** of every cumulative and
  running type, each 2.56 s long, and a heart-rate sample every **5.00 s**
  (instantaneous). All under the watch's own system source (the device
  source "watchOS Simulator", device "Apple Watch", model "Watch") with
  metadata key **`HKFakedData`**; heart rate also with the motion-context
  key. Values (n=46 per 2.56 s type, 23 HR): HR 105–135 bpm (mean 119);
  steps 3–7 per sample (223 in 120 s); distance 6.95–8.43 m (356 m); active
  energy 0.014–0.88 kcal (21.2 kcal); basal energy 0.033 kcal constant
  (1.52 kcal); speed 2.72–3.28 m/s; power 153–249 W; ground contact
  151–249 ms; vertical oscillation 9.9–12.0 cm; stride length 56–92 **m**
  (the generator's value looks like centimetres stored as metres). The
  builder's statistics followed the samples; the finished workout (act 37,
  120.2 s) carried `HKIndoorWorkout` metadata although the configuration
  said outdoor, and the session ended 2 s after `end`.
- The fake data kept coming **after** the workout ended: heart rate as
  5-minute series samples of 61 points (about 120 bpm), steps about 1 200
  and distance about 1 800 m per 10 minutes, active energy about 10
  kcal/min, for at least 17 minutes (until the run ended). Before the
  first workout of the boot there were no fake samples.
- Another app's heart-rate samples written on the watch during a session
  (70–73 bpm, every 10 s) were seen by the app's queries but **not**
  collected by the live builder (its HR minimum stayed at 104 bpm).
- No health or workout control exists in Device Hub's executables,
  SimulatorKit, CoreSimulator, CoreDevice or `simctl` (no strings with
  HealthKit, heart rate, workout or healthd).

## Q4: sync

- One IDS service carries it: `com.apple.private.alloy.health.sync.classc`
  ("restrictions are currently disabled … so no delay will be added"),
  through the same ids_simd path as `device-pairing.md` §4. 693 messages in
  the session, 781–88 679 bytes (median 1 427).
- healthd logs each sync session with a reason. Watch: "Remote requested
  sync", "user preferences changed", "workout samples were associated",
  "syncing after heart rate recovery", "External request from
  activityawardsd". Phone: "periodic sync timer fired", "client process
  entered foreground", "user characteristics changed", "user preferences
  changed", feature onboarding.
- Watch → phone: app samples saved on the watch at rest were **not** sent
  by themselves (not within 170 s). They arrived 3.5 s after an app on the
  phone came to the foreground (the phone asks, the watch answers "Remote
  requested sync"). Workout data: the first two fake batches reached the
  phone about 5–7 s after they were written, then nothing until the
  workout ended; the remaining 44 samples per type came 7 s after the end
  and the workout object 8 s after.
- Phone → watch: three app samples arrived on the watch 16 s after the
  save (the phone's next "periodic sync timer fired" was 7 s after it), a
  fourth (sleep) 37 s after.
- Authorization records sync too: the watch got the phone app's request
  rows and the second app's grants as a second source row with the same
  bundle id (provenance "from the phone"). Offline edits of rows already
  synced did not propagate. The watch app's own grant on the watch was a
  separate row.

## Q5: read-only types and the store

- Level 4 names in the watch runtime's shared cache (string search only):
  an in-daemon demo data generator (`HDDemoDataManager`,
  `HDDemoDataGenerator` with per-area generators including heart, sleep,
  vitals, audio exposure and `HDHRAFibBurdenDemoDataGenerator`) and the
  fake collector (`HDFakeDataCollector`, `HDFakeDataGenerator`). How the
  demo generator is switched on is not visible from names; finding it
  would need disassembly (level 5), which this round did not do.
- Store tables used (level 2, read with `sqlite3` from copies):
  - `healthdb.sqlite`: `sources` (ROWID, uuid, name, source_options,
    local_device, product_type, provenance, logical_source_id,
    sync_identity …), `logical_sources` (bundle_id, owner_bundle_id),
    `source_devices`, `authorization` (source_id, object_type, status,
    request, mode, date_modified, provenance, sync_identity …),
    `nano_pairing`, `sync_stores`, `sync_anchors`.
  - `healthdb_secure.sqlite`: `objects` (data_id, uuid 16 bytes,
    provenance, type, creation_date), `samples` (data_id, start_date,
    end_date, data_type), `quantity_samples` (quantity, original_quantity,
    original_unit → `unit_strings`), `category_samples` (value),
    `ecg_samples` (private_classification, average_heart_rate,
    voltage_payload, symptoms_status), `binary_samples`,
    `data_provenances` (sync_provenance, origin/local product type and
    build, source_id, device_id, contributor_id, source_version, tz_name,
    origin version, sync_identity, derived_flags), `metadata_keys`,
    `metadata_values`, `quantity_sample_series` / `quantity_series_data`,
    `workouts`, `workout_activities`, `workout_events`,
    `workout_statistics`.
  - Dates are seconds since 2001-01-01 UTC. Quantities are stored in the
    type's canonical unit (heart rate as count/s: 70 bpm stored 1.1667,
    original 70 "count/min").
- Type codes seen: heart rate 5, step count 7, walking/running distance 8,
  active energy 10, oxygen saturation 14, sleep analysis 63, workout 79,
  high heart rate event 140, ECG 144, irregular rhythm event 156, AFib
  burden 248, sleeping wrist temperature 256, sleeping breathing
  disturbances 275, sleep apnea event 276 (found by requesting one type at
  a time and reading the new row).
- Authorization encoding, found by writing values into a shut-down
  phone's table and reading the public API back: `status` 100 not
  determined (API 0), 101 share and read allowed (API 2; reads work), 102
  share allowed, read denied (API 2; reads empty), 103 share denied, read
  allowed (API 1; saves code 4), 104 both denied (API 1); `request` 0 or
  200 never presented (request status 1), 202 read presented (read-only
  request status 2), 203 share and read presented (2).
- Offline sample seeding: with the phone shut down we inserted rows
  (objects + samples + the kind table, provenance = an existing
  provenance of the watch's system source) for a sleep apnea event, an AFib
  burden value, an ECG and a breathing-disturbances value. After boot the
  app read all four through the public API with the right type, value,
  dates, source ("ycode-test-health-watch") and device ("Apple Watch"),
  no metadata. The ECG had 0 voltage measurements and no sampling
  frequency (empty payload); its average heart rate column is in bpm.
  Thirteen more ECG rows mapped the stored classification to the public
  one: 0→0, 1→5, 2→6, 3→1, 4→2, 5→4, 6→3, 7→1, 8→2, 9→2, 10→4, 11/12/100→0.
  Symptoms status 0→0, 1→1. The seeded rows did not reach the watch (they
  carried a provenance that had come from the watch).

## Q6: observers and background delivery (phone)

- Another app's save reached a foreground app's observer and anchored
  queries 1–2 ms after the save completed.
- Once the observing app was moved to the background (suspended), its
  queries got nothing; when it came back, one observer call per type and
  the anchored backlog arrived within 0.1 s.
- `enableBackgroundDelivery` with "immediate" succeeded, but healthd set
  the frequency to 3600 s for step count and heart rate, 1 s for oxygen
  saturation and sleep. On every later save it logged "Scheduling
  launches for …", then "Invoked _isBackgroundAppRefreshDisabled… on an
  unsupported platform" and "BAR is disabled for app". No app was ever
  launched or resumed in the background, whether suspended or terminated.
- Synced samples (watch → phone) fire the phone app's observers like local
  saves.

## Devices

Created: `ycode-test-health-phone`, `ycode-test-health-watch` (paired),
`ycode-test-health-watch2`. All shut down, unpaired and deleted at the end;
no other simulator was touched.
