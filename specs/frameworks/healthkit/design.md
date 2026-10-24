# HealthKit spec: design note for an open implementation

> **Ycode-original design.** This note is our own proposal, not a description
> of Apple's implementation. It is derived only from the behavior in the
> other files of this directory. Clean-room implementers may follow it or
> improve it; the conformance tests (`plan.md`) are what must pass.

## 1. Two delivery targets

1. **Ycode's iOS simulator with Apple's runtime** (near term). The guest
   runs Apple's own HealthKit, `healthd` and `HealthPrivacyService`; Ycode
   only has to provide the platform services they rely on (§2). This is the
   "easy win": no HealthKit code at all, just host plumbing, then the
   conformance app must produce the reference output.
2. **Open HealthKit** (the open-frameworks track, `docs/FUTURE.md`): a
   Linux-buildable reimplementation with the same API names and semantics,
   usable (a) as a drop-in `HealthKit.framework` for the guest when Ycode
   wants its own (e.g. to seed data or run without Apple's daemon), and (b)
   as a Swift package on Linux for tools and tests. Components §3–§9.

## 2. Ycode simulator dependency list (target 1)

What the guest must provide so that Apple's HealthKit stack works as in
`simulator-baseline.md`. Each item names the observed reason.

| # | Dependency | Why |
|---|---|---|
| G1 | launchd jobs `com.apple.healthd` (run at load, keep-alive on a path), `com.apple.healthappd`, and on-demand `healthrecordsd`, `healtheventsd`, `healthcontentd` with their Mach services registered in the bootstrap namespace | clients look up `com.apple.healthd.server` (and the others) by name; `launchd-sim.md` |
| G2 | Simulated-entitlement lookup for **clients**: `healthd` must be able to read the calling app's entitlements (from the app's `__TEXT,__entitlements` section) through the audit token of the XPC connection | every store call checks `com.apple.developer.healthkit`, the background-delivery key and the access array; the default source comes from `application-identifier` |
| G3 | A writable, persistent `/var/mobile/Library/Health` (and `Library/Caches`, `Library/Preferences`) in the device data directory, surviving app reinstall and device reboot; SQLite with WAL and `fcntl` locking | the store (`simulator-baseline.md` §5); `bsd-locking.md` |
| G4 | Data-protection classes on files report "available" (no lock in the simulator) | `healthd` keeps the sample store in protected files |
| G5 | User `mobile` resolvable by name (uid 501) for `healthd`'s defaults | the reference log showed a failure to resolve it; harmless there, keep it resolvable |
| G6 | UIKit remote view services: SpringBoard/FrontBoard must launch hidden `HealthPrivacyService.app` on demand via `com.apple.uikit.viewservice.com.apple.HealthPrivacyService` and host its view controller over the app | the authorization sheet |
| G7 | LaunchServices records for the hidden system apps (`HealthPrivacyService`, `WorkoutRemoteViewService`) and the HealthKit plug-ins | sheet and notifications |
| G8 | Background-task scheduling launch events (`com.apple.bg.system.task`, `com.apple.alarm`) accepted (may be no-ops) | `healthd`'s launch plist registers many repeating tasks |
| G9 | User notifications banner path | the one-time workout-access banner, Health app notifications |
| G10 | Locale/region services (`en_US` default) | preferred units |
| G11 | Enough patience at first boot: `healthd` start-up took ≈ 120 s on a loaded host; requests must wait, not time out | first-call latency |
| G12 | Touch input and the tap/swipe path of the simulator panel | answering the sheet (Ycode tests drive it the same way) |
| G13 | For workouts: the workout session daemon paths inside `healthd` need no sensors; the live data source produces synthetic values | live session baseline |

None of these is HealthKit-specific code; they are general simulator
features. G2 and G6 are the two that most likely need work.

## 3. Architecture of open HealthKit

    app process                                 ycode-healthd (one per device / per user on Linux)
    ┌──────────────────────────────┐            ┌──────────────────────────────────────────────┐
    │ HealthKit (API layer)        │  XPC /     │ connection: identity → (bundle id, ents)      │
    │  HKObjectType registry       │  local     │ authorization store                           │
    │  HKUnit parser/formatter     │  socket    │ object store (SQLite)                         │
    │  validation (exceptions)     │ ─────────► │ query engine + statistics engine              │
    │  query objects, handlers     │ ◄───────── │ change journal (anchors) → observers           │
    │  private serial callback q   │  events    │ background-delivery registry → launch events  │
    └──────────────────────────────┘            │ consent UI broker → ycode-health-consent app  │
                                                └──────────────────────────────────────────────┘

- **Validation in the client** (all exceptions of `errors.md` §3 happen
  synchronously in the app); **authorization and storage in the daemon**.
- Wire format: a small versioned message protocol (one request → one reply;
  long-running queries get a stream of events keyed by query id). On the
  guest it rides on XPC; on Linux on a Unix socket with peer credentials.
- Callback threading: one private serial queue per store for completions,
  one per query for long-running results (matches "never main").

## 4. Storage engine (SQLite)

One database per device/user, WAL mode, `PRAGMA foreign_keys=ON`. Our own
schema:

| Table | Columns (essentials) |
|---|---|
| `sources` | id, bundle_id (unique), name, kind (app/system/device) |
| `source_revisions` | id, source_id, version, product_type, os_major/minor/patch |
| `devices` | id, name, manufacturer, model, hw, fw, sw, local_id, udi (dedup on all fields) |
| `objects` | rowid = **anchor** (monotonic, never reused), uuid (unique), type_code, source_revision_id, device_id, start, end (UTC seconds as double), created, deleted (0/1) |
| `quantity` | object rowid, value_ref (double in the type's reference unit), count, original_unit |
| `category` | object rowid, value |
| `metadata` | object rowid, key, kind (string/number/date/quantity), text, number, unit |
| `associations` | parent rowid, child rowid, kind (correlation member, workout sample, workout route, activity) |
| `workouts` | object rowid, activity_type, duration, location_type, events (blob), activities (blob) |
| `series_points` | object rowid, seq, time, payload (route location / quantity / heartbeat) |
| `tombstones` | anchor (rowid in a shared sequence), uuid, type_code, source_id, metadata (blob), deleted_at |
| `sync_ids` | source_id, type_code, sync_identifier, version, object rowid |
| `authorization` | bundle_id, type_code, share_status, read_status, presented, earliest_date, decided_at |
| `per_object_auth` | bundle_id, object uuid, granted |
| `source_priority` | type_code, source_id, rank |
| `bg_delivery` | bundle_id, type_code, frequency |
| `settings` | key, value (locale-derived preferred units, characteristics) |

Indexes: `objects(type_code, deleted, start, end)`, `objects(type_code,
rowid)` for anchors, `metadata(key, text|number)`, `sync_ids` unique.

- Values are stored in the type's **reference unit** (§7) so sums and
  comparisons need no conversion; the original unit is kept for display.
- **Anchors**: `objects.rowid` and tombstone anchors come from one shared
  sequence table, so "added and deleted since anchor N" is two range scans
  merged by anchor (tombstones count against the limit, `queries.md` §4).
- **Save** of one call = one transaction = one change set (one observer
  notification). Saving an existing UUID is a no-op success.
- **Sync identifiers**: on save, look up (source, type, sync id); higher
  version → tombstone the old row and insert in the same transaction;
  lower/equal → no-op success.
- Characteristics live in `settings` and are editable through a Ycode
  developer tool (the 27.1 runtime has no UI for them).

## 5. Change journal, observers, background delivery

- After each commit the daemon publishes (anchor range, set of type codes).
  Observer queries registered for any of those types (and whose predicate
  matches at least one changed object, or simply by type — the reference
  fired for every save of the type) get one callback per change set; each
  observer also gets one callback right after it starts.
- Long-running anchored queries re-run "since my last anchor" on each
  matching change set and deliver one update.
- Background delivery: `bg_delivery` rows plus the frequency; when a
  matching change set commits and the app is not running, ask the platform
  to launch it in the background (guest: a launch event; Linux: a callback
  hook). Frequencies coalesce launches (immediate / hourly / daily / weekly).

## 6. Query engine and statistics engine

1. **Predicate compilation**: translate HealthKit predicate shapes (date
   interval with the exact rules of `queries.md` §2.1, UUID sets, source,
   device properties, metadata comparisons, quantity comparisons in the
   reference unit, category values, workout and correlation relations) and
   simple `NSPredicate` comparisons into SQL; anything else is evaluated in
   memory after a coarse SQL filter by type.
2. **Authorization filter**: rows from other sources only if read is
   granted; apply the earliest-authorized date to other sources' rows for
   every query and to all rows for statistics (`queries.md` §6.6).
3. **Statistics** (one engine for statistics, collections and workout
   builders):
   - Cumulative, statistics query: sum of whole values of matching samples.
   - Cumulative, collection bucket: sum over samples of value × overlap /
     duration (instantaneous samples count fully in the bucket that
     contains them).
   - Merging: group matching samples by source; walk sources in priority
     order (`source_priority`, default = most recently authorized app first,
     then system/device sources — to confirm, `plan.md` §5); keep a sample
     only if it does not intersect the union of intervals already kept from
     higher-priority sources; per-source values ignore merging.
   - Discrete arithmetic: plain mean; min, max; most recent = latest end.
   - Discrete temporally weighted: weights (duration + 45 s).
   - Equivalent continuous level: 10·log10(Σ wᵢ·10^(Lᵢ/10) / Σ wᵢ) with the
     same weights (to confirm).
   - Duration option: length of the union of contributing intervals.
   - Workout builder statistics: prorate cumulative samples to the active
     (unpaused) intervals of the workout.
4. **Collections**: compute bucket boundaries with the caller's calendar
   from the anchor date and interval components (Foundation calendar
   arithmetic; on Linux, swift-corelibs-foundation), enumerate lazily.

## 7. Type registry and units

- A generated table (from `identifiers.md`) of every type: identifier,
  kind, aggregation style, dimension and reference unit, allowed category
  values, duration limits, share/read permissions, per-object flag, topic
  label and section for the consent UI.
- A unit library implementing `units.md`: parser (grammar §2), canonical
  formatter (§3), dimension vectors, scale factors and the two affine
  temperature units, a unit cache keyed by canonical string.

## 8. Authorization store and consent UI

- `requestAuthorization…`: client-side validation (§4 of
  `authorization.md`), then the daemon computes the set of types not yet
  presented; if empty, complete immediately; otherwise ask the consent
  broker to show Ycode's own sheet (our layout and words, same structure:
  per-topic toggles, read/write sections, historical-range page), store
  per-type decisions and the earliest date, then complete with success.
- Status answers: share status only; read-only types answer 1 once
  presented; request status from the presented flags.
- Per-object authorization: a separate picker listing the objects matching
  the predicate; grants in `per_object_auth`.
- A developer tool (`ycode health grant/revoke/reset`) edits the store
  without UI for tests, and the consent UI can be bypassed by a test hook
  (recorded answers), so conformance runs need no taps.

## 9. Platform abstraction for Linux

- No UIKit: the consent UI is a separate process with a minimal toolkit or
  a CLI prompt; tests use recorded answers.
- CoreLocation types for routes: a small compatible `CLLocation` value type
  when CoreLocation is unavailable.
- Foundation (`NSPredicate`, `NSCalendar`, `NSDateInterval`,
  `NSSecureCoding`) from swift-corelibs-foundation; predicate evaluation in
  memory must not depend on Objective-C key-value coding there — the
  compiler of §6.1 handles the HealthKit key paths directly.

## 10. Data seeding (Ycode feature)

A Ycode-original side-car (JSON) per device: sources, samples (with units),
workouts and routes, characteristics, authorization decisions. The developer
tool imports it into the store so that apps under test see realistic data —
the simulator has no sensors or Health app on 27.1. Values in examples must
be made up.

## Evidence

This file is a design (no evidence level). Facts it relies on are in the
other files with their levels.
