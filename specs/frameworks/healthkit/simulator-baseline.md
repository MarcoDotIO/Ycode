# HealthKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/healthkit/`. This is what a HealthKit app sees in the
reference simulator (Xcode 27.1; iOS 27.1 runtime 24A94401 on an iPhone Duo,
iOS 27.0 runtime 24A434 on an iPhone 18 Pro; Apple-silicon Mac). Ycode's
simulator must behave the same way. Statements are level 3 (our probe app
`research/experiments/healthkit/HealthProbe`, observations in
`research/notes/healthkit-simulator-observations-2026-10-19.md`) unless
marked.

## 1. Summary

HealthKit is **fully functional** in the simulator. Health data is available,
the system authorization sheet appears and works, samples of every kind can
be saved, queried, aggregated, observed and deleted, workouts can be built
and even run as live sessions on the phone, and everything persists across
app restarts, reinstalls and device reboots. No Apple account, team or
provisioning profile is involved.

The two runtimes behave **identically** for every API call we made. The only
differences are data that name the device (model `iPhone19,4` + OS 27.1
versus `iPhone19,2` + 27.0 in `HKDevice.localDevice` and in source
revisions) and the presence of the Health app:

| | iOS 27.1 (24A94401) | iOS 27.0 (24A434) |
|---|---|---|
| `Health.app`, `Fitness.app` | absent (level 2: not in `RuntimeRoot/Applications`) | present; launches; shows data written by apps |
| `healthd` and the other health daemons | present, same launchd jobs (level 2) | same |
| Authorization sheet (`HealthPrivacyService.app`) | present, works | present, identical |
| HealthKit API results | baseline | identical |
| Settings → Privacy → Health pane (`HealthPrivacySettings.bundle`) | present as a bundle (level 2), not exercised | present, not exercised |

Consequence for 27.1: there is **no in-simulator UI to edit characteristics**
(date of birth, sex, blood type…), so they read back as "not set"; and the
only way to change an app's grants after the sheet is to reset the device
(or the Settings pane, untested).

## 2. Availability and capability answers

| Query | Result |
|---|---|
| `HKHealthStore.isHealthDataAvailable` | YES (also for an app without the entitlement) |
| `supportsHealthRecords` | NO, unless the app has the `health-records` access entitlement, then YES |
| `earliestPermittedSampleDate` | 0001-01-01T00:00:00Z (no limit) |
| `HKDevice.localDevice` | name "iPhone", manufacturer "Apple Inc.", model "iPhone", hardware version = the model identifier, software version = OS version, firmware/local identifier/UDI nil |
| `HKSource.defaultSource` | name = app display name, bundle identifier = the `application-identifier` entitlement value (§6) |
| Workout session on iPhone | supported (26.0+ API); states run normally (§4.6) |

## 3. Authorization

See `authorization.md` for the model. Observed baseline:

1. Before any request: every status 0 (not determined); request status 1
   (should request); save, query, statistics and delete fail with code 5;
   characteristic reads fail with code 5; preferred units fail with code 5;
   **background delivery succeeds** (with the entitlement).
2. The request shows the system sheet (`authorization.md` §4) after about
   1.5 s; the completion runs on a private HealthKit queue (not main) only
   when the user finishes.
3. After "Select All" and "Allow": share types status 2; **read-only types
   status 1** (never reveals the read grant); request status 2
   (unnecessary). A second request for the same set completes immediately
   with success and no sheet.
4. A user who leaves a read toggle off is indistinguishable from "no data":
   queries return empty results; statistics return code 11 (no data).
5. Cancelling the clinical-records flow completes with success NO and
   code 7.
6. Grants survive app termination, reinstall (in-place update) and reboot.

## 4. Data behavior

All golden values are in `queries.md` and `plan.md` §3. Summary:

1. Save: completion on a private queue; saving an already-saved object again
   succeeds and does not duplicate it; a sample older than 1900 is accepted;
   a type that was never requested fails with code 5, a read-only type
   granted for reading fails with code 4 ("Not authorized").
2. Queries: sample, anchored, observer, statistics, statistics collection,
   correlation, source, workout route and sample-predicates all work, with
   the interval rules and merge rules of `queries.md`.
3. Observer queries fire once at start and once per committed change (save
   or delete), within about one second, on a private queue; stopped queries
   stop firing and cannot be executed again (exception).
4. Long-running anchored queries deliver additions and deletions; deleted
   objects come as tombstones with UUID and the deleted object's metadata.
5. Deletion: by object (code 3 if not found or already deleted, also for
   another app's object), by type and predicate (success with count 0 when
   nothing matches); deleting a correlation deletes the correlation object
   but leaves its member samples readable.
6. Workout session (live): `initWithHealthStore:configuration:error:`
   succeeds; states go not-started (1) → running (2) → paused (4) → running
   (2) → ended (3); the live data source collects active energy and distance
   (near-zero synthetic values, written under a system source); the finished
   workout appears in the Health app on 27.0. After the first live workout
   the system shows a one-time banner about workout data access while
   locked.
7. Clinical records, verifiable records, medications: no data exists and
   apps cannot create any; the queries answer empty or with the errors of
   `errors.md`.

## 5. Where data lives (level 2, file locations and formats only)

Per device, under `<device>/data/Library/Health/`:

| Path | Format | Role (inferred from name) |
|---|---|---|
| `healthdb.sqlite` (+ `-wal`, `-shm`) | SQLite 3, WAL journal, `user_version` 27006, 47 tables | unprotected store (sources, devices, registrations) |
| `healthdb_secure.sqlite` (+ `-wal`, `-shm`) | SQLite 3, WAL, `user_version` 27025, 152 tables | protected store (samples) |
| `Client/HealthApp.sqlite` | SQLite | Health app support data |
| `ontology/HealthOntology.db` | SQLite | concept ontology (medications etc.) |
| `NanoSync/…health.sync.db` | SQLite | paired-device sync state |
| `Local/SyncIdentityHardwareIdentifier.uuid` | 16 raw bytes | this store's sync identity |
| `Journals/`, `CloudSyncJournals/` | empty directories | write journals, cloud sync |

Preferences in `<device>/data/Library/Preferences/com.apple.private.health.*.plist`
and caches in `Library/Caches/com.apple.healthd`. Ycode does not need to read
or write these formats: its own HealthKit keeps its own store (`design.md`).
It only needs the guest to give `healthd` a writable, persistent
`/var/mobile/Library/Health`.

## 6. Entitlements in the simulator

The simulator enforces entitlements from the app's **simulated-entitlements
section** (`__TEXT,__entitlements`, as Xcode writes for simulator builds), not
from a provisioning profile. Developer entitlements placed in the ad-hoc code
signature instead make the launch fail. Required for a working app:
`application-identifier` (any value; it becomes the source's bundle
identifier) and `com.apple.developer.healthkit`. Without
`application-identifier` the first use of the default source raises
`NSGenericException` and kills the app.

## 7. Processes, services and system UI involved (level 2 + 3)

Launch daemons (property lists in `RuntimeRoot/System/Library/LaunchDaemons`,
identical in both runtimes):

| Job label | Program | Mach services (names) | Seen |
|---|---|---|---|
| `com.apple.healthd` | `HealthKit.framework/healthd` | `com.apple.healthd.server`, `com.apple.healthd.cache-delete`, `com.apple.private.healthd.pairedsync`, three `com.apple.aps.*` push names, three `com.apple.private.alloy.*` IDS names | running from boot; KeepAlive on a path state; many background-task launch events; runs as user `mobile` |
| `com.apple.healthappd` | `HealthPluginHost.framework/healthappd` | `com.apple.healthappd`, `…healthappd.control`, `…healthappd.orchestration` | running (also on 27.1) |
| `com.apple.healthrecordsd` | `HealthRecordServices.framework/healthrecordsd` | `com.apple.healthrecordsd` | started by the clinical-records request |
| `com.apple.healtheventsd` | `HealthEventsDaemonImplementation.framework/healtheventsd` | `com.apple.healtheventsd` | on demand |
| `com.apple.healthcontentd` | `HealthContent.framework/healthcontentd` | `com.apple.healthcontentd` | on demand |
| `com.apple.fitnesscoachingd`, `com.apple.fitnessintelligenced`, `com.apple.finhealthd` | (fitness/finance) | — | running; not needed by HealthKit apps |

System UI:

| Bundle | Identifier | Role |
|---|---|---|
| `Applications/HealthPrivacyService.app` (hidden) | `com.apple.HealthPrivacyService` | remote view service that shows the authorization sheet; its SpringBoard Mach service is `com.apple.uikit.viewservice.com.apple.HealthPrivacyService`; runs as `UIKitApplication:com.apple.HealthPrivacyService` while the sheet is up |
| `Applications/WorkoutRemoteViewService.app` (hidden) | `com.apple.WorkoutRemoteViewService` | workout remote views (not triggered by our probe) |
| `HealthKit.framework/PlugIns/…HealthKitTCCNotificationExtension.appex` | — | notification content for HealthKit privacy notices |
| `PreferenceBundles/Privacy/HealthPrivacySettings.bundle` | — | Settings → Privacy → Health |

The client talks to `healthd` over XPC; the service name the framework uses is
not observed directly (inference: `com.apple.healthd.server`). A Ycode guest
that runs Apple's runtime already gets all of this for free; what it must
provide is listed in `design.md` §2.

On a heavily loaded host `healthd` took about 120 s to finish start-up after
a boot; store calls made in that window waited instead of failing.

## 8. Conformance checklist

Each row: the probe phase (`HealthProbe -phase <p>`, variant in brackets) and
the expected result on the reference. A Ycode simulator (guest with Apple's
runtime) and a Ycode HealthKit implementation must both produce it. Numbers
are exact unless written "≈".

| # | Probe | Expected |
|---|---|---|
| B1 | `basic` | `isHealthDataAvailable=1`, `supportsHealthRecords=0`, earliest permitted date year 1 |
| B2 | `basic` | 407 identifier lines; every type constant yields its class (`identifiers.md`); bogus identifier → nil; category constructor with a quantity identifier → nil |
| B3 | `basic` | unit lines and conversions exactly as `units.md` §6 |
| B4 | `basic` | unauthorized save/query/statistics/delete → code 5; background delivery → success |
| B5 | `basic` | the eleven invalid requests: ten raise `NSInvalidArgumentException` with the messages of `errors.md` §3; share of the vision-prescription type shows the sheet |
| B6 | `basic` | sample validation exceptions of `errors.md` §3 (incompatible unit, end before start, invalid category value, metadata value class, blood-pressure correlation membership) |
| B7 | `basic` | walking-steadiness classes: <0.25 very low (3), 0.25–<0.5 low (2), ≥0.5 OK (1); breathing disturbances elevated (1) from 11 count |
| B8 | `basic` [NoEnt] | every call → code 4 "Missing com.apple.developer.healthkit entitlement."; request status 0 |
| B9 | `basic` [NoUsage] | share request raises `NSInvalidArgumentException` naming `NSHealthUpdateUsageDescription`; background delivery without its entitlement → code 4 |
| A1 | `auth` | sheet appears; after Select All → Continue → Past 30 Days → Allow: completion success; share statuses 2, read-only statuses 1, request status 2 |
| A2 | `auth` again | immediate success, no sheet |
| A3 | `authb` [B] read HR off | B's HR status 1; B's HR statistics → code 11 |
| A4 | `clinical` [Clin] | records onboarding sheet; close → code 7 |
| D1 | `data` | every golden value of `plan.md` §3 (statistics, collections, averages, predicates, anchors, sync identifiers, workout builder) |
| D2 | `data` | observer: 1 call at start + 1 per change; live anchored updates 1 add, then 1 add + 1 delete (sync replacement), then 1 delete |
| D3 | `data` | delete twice → second fails code 3; delete-of-type with empty match → success, 0 |
| X1 | `cross` [B] | merged day sum 4911, per source 1300 (B) and 5111 (A); window [08:00, 08:10] merged 400 |
| S1 | `session` | states 1→2→4→2→3; live builder finishes a workout of ≈ elapsed time |
| P1 | `count` after reboot | same per-type counts as before shutdown |
