# HealthKit in Apple's iOS Simulator: observations (2026-10-19)

Dirty-room notes (prose, no code) behind `specs/frameworks/healthkit/`.
Agent: KIT-HEALTHKIT. Host: the Apple-silicon Mac, Xcode 27.1 (27A9269),
heavily loaded (load average between 12 and 460 during the session).

## Setup

- Probe: `research/experiments/healthkit/HealthProbe/` (our own Objective-C
  app, built with `clang` from the installed Xcode, ad-hoc signed). Five
  variants that differ only in entitlements and Info.plist (see `build.sh`).
- Devices: `ycode-test-healthkit-271` (iPhone Duo, iOS 27.1 24A94401) and
  `ycode-test-healthkit-270` (iPhone 18 Pro, iOS 27.0 24A434). Booted one at
  a time, deleted at the end of the session.
- Raw reports and screenshots: `research/dirty/healthkit/r271/` and
  `r270/` (git-ignored). The SDK name inventory used to generate the
  appendices: `research/dirty/healthkit/inventory.json` (git-ignored; made by
  `extract_names.py`, names and numbers only).
- The authorization sheet was answered with the iOS-simulator tap tool
  (device points; the iPhone Duo cover display is 466 × 678 points at 3×).
  Taps shorter than about 0.1 s were often lost under load; 0.15 s taps
  worked.
- No account was signed in. No real health data was used: every sample is a
  made-up value on 2026-09-21 … 2026-10-05 (UTC) or a deliberately odd date.

## Entitlements without a team

- HealthKit reads the client's entitlements from the code signature's
  simulated-entitlements section. Xcode puts simulator entitlements into a
  `__TEXT,__entitlements` section; putting developer entitlements into the
  ad-hoc **signature** instead made `simctl launch` fail ("did not return a
  process handle"). With the section only, launch works.
- No development team, provisioning profile or Apple account is needed for
  any of this in the simulator.
- `application-identifier` must be present. Without it, the first use of the
  default source throws `NSGenericException` "Unable to create default
  source. The bundle identifier of the client is nil" (uncaught, app dies).
  A plain bundle identifier as value (no team prefix) works; the source's
  bundle identifier is the app's.
- With `application-identifier` but without `com.apple.developer.healthkit`,
  every store call fails with `com.apple.healthkit` code 4 and the message
  "Missing com.apple.developer.healthkit entitlement."; request status
  answers 0 (unknown) with that error; `isHealthDataAvailable` is still YES.
- Background delivery without its entitlement: code 4, "Missing
  com.apple.developer.healthkit.background-delivery entitlement." — even
  before any authorization. With the entitlement it succeeds before
  authorization too.
- `supportsHealthRecords` is NO without `com.apple.developer.healthkit.access`
  containing `health-records`, YES with it. The verifiable-records query
  wants `verifiable-health-records` in the same array (code 4 otherwise).
- Without `NSHealthUpdateUsageDescription`, a request to share throws
  `NSInvalidArgumentException` naming the key and the types.

## 27.1 versus 27.0

Every API observation was identical on both runtimes, apart from the device
model and OS version that appear in sources and `HKDevice.localDevice`
(iPhone19,4 / 27.1 versus iPhone19,2 / 27.0), the earliest-authorized date
(time of the grant) and the order of asynchronous log lines. The 27.1
runtime has no Health app, but HealthKit is complete: `healthd`, the
privacy sheet service and all launch daemons are present and byte-sized the
same in both runtimes; `Applications/Health.app` and `Fitness.app` exist
only in 27.0. The authorization sheet is identical (same pages, same
historical-data page). On 27.0 the Health app opened to Summary and showed
the probe's steps (pinned "Steps 2,000" for Oct 2) and the workout of the
live-session phase ("Walking 0 min 0.07 cal 0 mi"), and asked for
notification permission (not answered).

## Daemons and services seen

- `launchctl list` in the device: `com.apple.healthd` (running from boot),
  `com.apple.healthappd` (running, even on 27.1 without the app),
  `com.apple.healthrecordsd` (started when the clinical request ran),
  `com.apple.fitnesscoachingd`, `com.apple.fitnessintelligenced`,
  `com.apple.finhealthd` (running on 27.0), and on-demand
  `com.apple.healtheventsd`, `com.apple.healthcontentd`. During and after
  the sheet: `UIKitApplication:com.apple.HealthPrivacyService` (the sheet is
  a remote view service).
- On 27.1, `healthd` had a previous exit status of −6 at one point and its
  log reported "End notification of profile ready observers in 120.1
  seconds" — on a heavily loaded host the first store call can wait about
  two minutes for `healthd` to become ready. The probe's first calls did not
  fail; they waited.
- `healthd` log categories seen (subsystem `com.apple.HealthKit`):
  `database`, `daemon_initialization`, `workouts`, `workoutZones`.
- After the live workout session, a system banner appeared: "Health and
  Fitness Data — Apps that start a workout will have access to your Health
  and Fitness data while your device is locked" with OK / Settings.

## Authorization sheet (both runtimes)

1. Page 1 "Health Access": Health icon ⇄ app icon; title "Allow
   "<display name>" to access your Health data?"; subtitle depends on what
   is requested ("…share with this app" with read types, "…be able to add
   to" with share types only); a "Select All N Topics" / "Deselect N
   Topics" row (N = number of distinct read + write toggles: 34 for our
   14-share / 22-read request, 3 for 1 share + 2 read); a "Read Access"
   section with the app's share usage string prefixed "App Explanation:",
   then toggles grouped by category (Activity, Body Measurements, Heart,
   Mental Wellbeing, Nutrition, Sleep, Vitals, …); a "Write Access" section
   with the update usage string and its toggles; footer text about access
   only while the app is open and Background App Refresh; buttons.
   All toggles start off.
2. The primary button reads "Allow" (disabled until a toggle is on) when no
   read toggle is on, and "Continue" once any read toggle is on.
3. Page 2 (only when some read access is granted): "How much data would you
   like to share with "<name>"?" with two cards, "Past 30 Days and Future
   Data" and "All Recorded Data and Future Data"; "Allow" stays disabled
   until a card is chosen; "Don't Allow"; a back button.
4. Characteristic types (date of birth etc.) and `activitySummaryType`
   requested for reading did not appear as toggles we could see; after
   "Select All" they read back as status 1 like every read-only type (status
   never discloses read grants).
5. Requesting only a per-object type to share (vision prescription) showed
   the same sheet with one "Write Access" topic.
6. Clinical record read request (with the access entitlement): an
   onboarding page ("Connect your accounts / View your health records / Your
   privacy…", "Next"), then "1 of 4 — Share Health Records — Add your
   provider accounts…", "No Accounts Added", "Add Account". We closed it
   with ×; completion: NO, code 7 "The user canceled authorization."
7. A second request for an already-answered set completes immediately with
   success and no sheet.

## Golden values

All values below are in `research/dirty/healthkit/r27x/data.txt` and are
reproduced in `specs/frameworks/healthkit/queries.md` and `plan.md`.

- Statistics query (no collection): a sample counts with its **full**
  value if it intersects the predicate interval — no proration
  ([08:05, 08:10] over samples 1000 @08:00–08:10 and 500 @08:05–08:15 gives
  1500). Collections prorate by time overlap (5-minute buckets 500, 750,
  250).
- Same-source overlapping cumulative samples are summed (1500).
- Cross-source: the later-authorized app B (400 @08:00–08:10, 900
  @15:00–15:10) beat app A in the merged sum; A's 1000 and A's 500 (which
  only partly overlaps B's sample) were both dropped from the merged value:
  merged day sum 4911 = 400 + 900 + 3000 + 11 + 600; per-source sums 1300
  (B) and 5111 (A).
- Discrete arithmetic average = plain mean of the samples, no time weight
  (four configurations, all 15 °C for values 10 and 20).
- Discrete temporally weighted average (heart rate): each sample weighs
  (duration + 45 s). Fits six configurations and the day-0 value 82.7273
  exactly. Duration statistic itself excludes the 45 s.
- Interval predicate: a sample matches when start < window end and end ≥
  window start; a zero-length window [t, t] matches samples that cover t or
  end at t.
- Authorization with "Past 30 Days": `getEarliestAuthorizedSampleDate`
  returns grant time − 30 days (2026-09-19 23:55:40 for a grant at
  2026-10-19 23:55:40 UTC). Statistics and collections ignore the app's own
  samples older than that date; sample queries still return them.
  App B with "All Recorded Data" saw everything, including 1811 and
  2026-08-02 samples, in its collections.
- Anchored query with a fresh store and limit 2 returned the first two
  samples in insertion order; with earlier deletions on record, a limit-2
  query returned no samples (tombstones count against the limit).
- Sync identifier: saving version 2 replaced version 1 (the anchored update
  reported 1 added + 1 deleted with the old object's metadata); saving
  version 1 again was accepted (success) but left version 2 in place.
- Workout builder with a 2-minute pause: duration 1680 s of 1800; builder
  statistics are prorated to active time (300 kcal → 280, 5000 m →
  4666.67 m); the heart-rate statistic is an average (2.5 count/s).

## Data at rest (file formats only)

`<device>/data/Library/Health/`: `healthdb.sqlite` (47 tables,
`user_version` 27006) and `healthdb_secure.sqlite` (152 tables,
`user_version` 27025), both SQLite in WAL mode; `Client/HealthApp.sqlite`;
`ontology/HealthOntology.db`; `NanoSync/…sync.db`; `Local/` with a 16-byte
`SyncIdentityHardwareIdentifier.uuid`; empty `Journals/` and
`CloudSyncJournals/`. Data and authorization survived app termination,
app reinstall (update in place) and a device shutdown/boot. Table contents
were not examined.

## Open points

- The +45 s weighting may be a minimum-duration rule rather than a constant
  pad; samples closer together than 45 s were not tested.
- Which source order the merge uses (B, the later-authorized app, won; the
  Health app's "Data Sources & Access" order on device puts new sources
  below the device). Needs a third source and the 27.0 Health app UI to
  confirm.
- After the reboot one heart-rate sample from another source appeared (the
  live workout data source writes its samples under a system source).
- Characteristics could not be given values on 27.1 (no Health app); on
  27.0 the Health app profile was not edited.
