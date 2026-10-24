# HealthKit spec: queries, statistics and merging

Part of `specs/frameworks/healthkit/`. Query classes and constructor names are
level 4 (`api-inventory.md`); behavior is level 3 from `HealthProbe -phase data`
and `-phase cross`, identical on iOS 27.1 and 27.0, unless marked. All dates
are UTC; D0 = 2026-10-01T00:00:00Z. The test data set is listed in
`plan.md` §3.1.

## 1. Query lifecycle (all query kinds)

- A query is an immutable description built by its initializer, then passed
  to `executeQuery:`; results arrive through blocks on a **private serial
  queue of the store** (never the main thread). `stopQuery:` ends a
  long-running query; a query object can run **once** — executing it again
  raises `NSInvalidArgumentException` ("has already been executed and cannot
  be executed again").
- One-shot queries (sample, statistics, correlation, source, document,
  route, heartbeat series, …) call their handler once (route and series
  queries call it repeatedly with a `done` flag; our three-point route came in
  one call with done YES).
- Long-running queries (observer, anchored object with an update handler,
  statistics collection with an update handler, activity summary with an
  update handler) keep running until stopped or the app exits.
- Authorization gates: before the user answered, sample/statistics/anchored
  queries fail with code 5 ("Authorization not determined"); after the
  user answered, a type whose read access was not granted behaves like an
  empty store: sample queries return no objects, statistics return code 11
  ("No data available for the specified predicate."). The app's own samples
  are always readable (§7).

## 2. Predicates

HealthKit predicates are ordinary `NSPredicate` objects built by class
methods of `HKQuery` (names in `api-inventory.md`), over these key paths
(string values in `identifiers.md`, "Other string constants"): `startDate`,
`endDate`, `UUID`, `source`, `metadata`, `quantity`, `value`, `device`,
`workout`, `duration`, `workoutType`, the workout total key paths,
`correlation`, and others. A plain `NSPredicate` written by the app over the
same key paths also works (`startDate > D0` returned 5 step samples).
Compound predicates (`NSCompoundPredicate` AND/OR/NOT) work.

### 2.1 Date interval predicate (`predicateForSamplesWithStartDate:endDate:options:`)

For a window [W.start, W.end] and a sample [S.start, S.end]:

| Options | Sample matches when |
|---|---|
| none (0) | S.start < W.end **and** S.end ≥ W.start |
| strict start (1) | S.start ≥ W.start and the "none" rule |
| strict end (2) | S.end ≤ W.end and the "none" rule |
| both (3) | S.start ≥ W.start and S.end ≤ W.end |

A nil start or end means unbounded on that side. Golden cases (step samples
of `plan.md` §3.1):

| Window | Options | Count |
|---|---|---|
| [D0, D0+1d] | none | 4 (includes 23:50–00:10) |
| [D0, D0+1d] | strict start | 4 |
| [D0, D0+1d] | strict end | 3 |
| [D0, D0+1d] | both | 3 |
| [08:10, 08:10] (zero length) | none | 2 (the sample ending at 08:10 and the one covering it) |
| [08:15, 09:00] | none | 1 (sample ending exactly at 08:15 matches) |
| [07:00, 08:00] | none | 0 (sample starting exactly at 08:00 does not) |
| [nil, D0 09:00] | none | 5 (includes ancient samples) |

An instantaneous heart-rate sample at 09:00 is **not** in [08:00, 09:00]
(start < end fails) but is in [07:59, 09:01].

### 2.2 Other predicates (golden counts)

| Predicate | Count |
|---|---|
| metadata key `YcodeProbe` in {"golden"} | 1 |
| metadata `YcodeNumber` > 40 (number comparison) | 1 |
| metadata key exists (`HKExternalUUID`) | 1 |
| quantity ≥ 1000 count (step samples) | 3 |
| category value == asleep core (sleep) | 1 |
| category value in the asleep set {1, 3, 4, 5} | 2 |
| from source = default source | all of the app's samples |
| from devices {local device} | 0 (samples saved without a device have none) |
| no correlation (systolic member of a blood-pressure correlation) | 0 of 1 |
| from workout (energy sample added through the builder) | 1 |
| workouts with activity type running | 1 |

## 3. Sorting and limits

- `HKSampleSortIdentifierStartDate`, `…EndDate` (and the others listed in
  `identifiers.md`) sort as expected; unsorted results came back in
  start-date order for our data, but order without sort descriptors is not
  specified — an implementation may return storage order.
- A sort descriptor on a key HealthKit does not index (`quantity`) was
  **accepted** (no exception) and returned all samples.
- `limit` 0 (`HKObjectQueryNoLimit`) means no limit; limit 2 with end date
  descending returned the two latest-ending samples.

## 4. Anchored object queries and tombstones

- Every saved or deleted object advances a store-wide **anchor** (a
  monotonically increasing sequence). An anchored query returns the samples
  added and the objects deleted after the given anchor (nil = from the
  beginning) that match the type and predicate, plus a new anchor.
- **Deleted objects are kept as tombstones** (`HKDeletedObject` with the UUID
  and the deleted sample's metadata) and are returned to anchored queries
  from the beginning: a fresh-anchor query on a store with earlier deletions
  returned "added 8, deleted 29".
- The **limit counts tombstones too**, in anchor order: with 29 earlier
  deletions a limit-2 query returned no samples; on a fresh store it
  returned the first two samples in insertion order (1000, 500).
- The anchor is an opaque object with secure coding (414 bytes archived in
  our run); `anchorFromValue:` builds one from an integer. A Ycode anchor encodes the sequence number.
- With an update handler, the query first reports the delta from its start
  anchor, then one callback per committed change set: a save of one sample
  gave "1 added"; replacing a synced sample gave "1 added, 1 deleted" in
  one callback; deleting gave "1 deleted".

## 5. Observer queries and background delivery

- An observer query calls its handler **once immediately** after start and
  then once per committed change set touching its type and predicate (saves
  and deletes), within about one second (≈ 0.0–1.0 s in the probe). The
  handler receives a completion block the app must call.
- No calls after `stopQuery:`.
- `enableBackgroundDeliveryForType:frequency:` (frequencies 1 immediate, 2
  hourly, 3 daily, 4 weekly) succeeds in the simulator with the entitlement,
  even before authorization; `disable…` succeeds. Whether the app is
  relaunched in the background for new data was not observed (the
  simulator has no other data producers); design treats it as a launch
  event for registered observer queries (`design.md` §5).

## 6. Statistics

### 6.1 Options and compatibility

`HKStatisticsOptions` bits: separate by source 1, discrete average 2, min 4,
max 8, cumulative sum 16, most recent 32, duration 64.

- Cumulative types (aggregation style 0) accept sum, duration, most recent,
  separate by source; asking a discrete option raises
  `NSInvalidArgumentException` ("Statistics option … is not compatible with
  cumulative data type …").
- Discrete types (1, 2, 3) accept average, min, max, most recent, duration,
  separate by source; sum raises the mirror exception.
- Option 0 (none) is allowed: the result carries only the date range.
- No matching samples → the handler gets nil statistics and **code 11**.

### 6.2 Statistics query (`HKStatisticsQuery`)

The result's `startDate`/`endDate` are the earliest start and latest end of
the contributing samples (not the predicate window).

**No proration**: every sample that matches the predicate contributes its
whole value, even if it lies only partly inside the window.

| Window (steps) | Sum | Result range |
|---|---|---|
| day D0 (none) | 5100 | 08:00 – D0+1 00:10 |
| day D0 (strict both) | 4500 | 08:00 – 12:30 |
| day D0+1 | 2600 | D0 23:50 – D0+1 09:30 |
| two days | 7100; duration 5700 s | |
| [08:00, 08:10] | 1500 | 08:00 – 08:15 |
| [08:05, 08:10] | 1500 | 08:00 – 08:15 |
| [12:00, 12:15] over a 3000-step 30-min sample | 3000 | 12:00 – 12:30 |

Same-source overlapping cumulative samples **add up** (1000 + 500 = 1500).
`duration` (option 64) is the length of the union of the contributing
samples' intervals (5700 s = 15 + 30 + 20 + 30 min).

### 6.3 Discrete averages

- **Arithmetic** types (style 1, e.g. body temperature): the plain mean of
  the sample values; sample durations do not matter. Values 10 and 20 gave
  15 for two instants, an instant and a 10-min sample, a 1-min and a 3-min
  sample, and two overlapping 10-min samples.
- **Temporally weighted** types (style 2, e.g. heart rate): weighted mean
  where each sample weighs **its duration plus 45 seconds**. All measured
  cases fit exactly:

| Samples (count/min) | Average |
|---|---|
| 60 @t, 120 @t+30 min (instants) | 90 |
| 60 instant, 120 over 10 min | 116.087 = (60·45 + 120·645)/690 |
| 60 over 1 min, 120 over 3 min | 100.909 = (60·105 + 120·225)/330 |
| 60 over 10 min, 120 over 10 min (adjacent) | 90 |
| 60 over 10 min, 120 instant | 63.913 |
| day D0: 150, 60, 70, 90 instants + 80 over 10 min | 82.7273 = (370·45 + 80·645)/825 |
| instants 60, 70, 90 | 73.3333 |

  Whether 45 s is a pad or a minimum (samples closer than 45 s) is open.
- **Equivalent continuous level** types (style 3, audio exposure, in dBASPL)
  were not measured; level 1 describes an energy-equivalent average
  (10·log10 of the duration-weighted mean of 10^(L/10)). Ycode should
  implement that and confirm.
- min / max / most recent: plain extrema; most recent is the sample with the
  latest end date (its date interval is reported).
- Mixed units: values are converted to the requested unit for output;
  70 kg and 155 lb gave average 70.1534 kg, max 70.3068 kg.

### 6.4 Merging across sources

Option "separate by source" gives per-source values next to the merged
value. The merged value **de-duplicates overlapping data from different
sources**: sources are taken in priority order; a sample from a
lower-priority source that overlaps any interval already covered by a
higher-priority source is dropped **as a whole**; samples from the same
source never de-duplicate each other.

Golden case (A = first app, granted first; B = second app, granted later):

| Data | A | B |
|---|---|---|
| 08:00–08:10 | 1000 | 400 |
| 08:05–08:15 | 500 | |
| 12:00–12:30 | 3000 | |
| 15:00–15:10 | | 900 |
| 22:00–22:01 | 11 | |
| 23:50–00:10 | 600 | |

| Query | Merged | Per source |
|---|---|---|
| sum, day D0 | **4911** = 400 + 900 + 3000 + 11 + 600 | A 5111, B 1300 |
| sum, [08:00, 08:10] | **400** | A 1500, B 400 |
| hourly collection 08:00–09:00 | 400 | |

So in the reference B outranked A. Level 1 says the user orders sources in
the Health app and that new apps are added to the list; the observed order
is consistent with "most recently added app first". Ycode keeps an explicit
priority list per type (`design.md` §6) seeded that way. Discrete types are
not de-duplicated (merge rules apply to cumulative sums; level 1).

### 6.5 Statistics collection (`HKStatisticsCollectionQuery`)

- Buckets are laid out from the **anchor date** in steps of the interval
  date components (calendar arithmetic in the current calendar; our test
  used whole hours and days in UTC so the time zone did not matter).
  Buckets before and after the anchor are generated as needed.
- `statistics` lists only buckets that have data; `enumerateStatisticsFromDate:toDate:`
  visits every bucket in the range, with nil values where empty;
  `statisticsForDate:` returns the bucket containing that date.
- **Cumulative values are prorated** by the fraction of each sample's
  duration that falls into the bucket. Five-minute buckets over the 1000
  (08:00–08:10) and 500 (08:05–08:15) samples: 500, 750, 250. The 600-step
  sample across midnight puts 300 in each day; a 4-step sample spread over 4
  days puts 1 in each day and 0.25 in each 6-hour bucket.
- Discrete statistics are per bucket by sample membership (hourly heart rate:
  06:00 → 150, 08:00 → avg 65/min 60/max 70, 09:00 → 90, 13:00 → 80).
- Golden daily sums with anchor D0 00:00: D0 → 4800, D0+1 → 2300 (the
  midnight sample split 300/300); with anchor D0−5d 06:00 (daily buckets
  from 06:00): D0 06:00–D0+1 06:00 → 5100, next → 2000; six-hourly from D0:
  06–12 → 1500, 12–18 → 3000, 18–24 → 300, D0+1 00–06 → 300, 06–12 → 2000.
- The initial handler runs once; with an update handler, changed buckets
  are re-delivered (not measured).

### 6.6 Historical-range limit

With the "Past 30 Days and Future Data" grant (`authorization.md` §5), the
statistics and collection queries **excluded the app's own samples older
than the earliest authorized date** (sum over all time 7104, without a 61
step sample of D0−60d and a 1811 sample), while sample queries still
returned those own samples. App B, granted "All Recorded Data", saw them in
its collections. Ycode applies the date bound to statistics for every
source and to sample/anchored queries for other sources' data only.

## 7. Own-data visibility

An app can always read and delete the objects it wrote while it holds share
authorization for the type, regardless of read authorization (level 1;
consistent with level 3: app B could not delete A's sample — code 3 "Failed
to find some objects for deletion" — and could read its own steps).

## 8. Deletion semantics

- `deleteObject:` / `deleteObjects:` — fail with code 3 if any object is not
  found or not deletable by this app (another source's object, an
  already-deleted object, an object never saved).
- `deleteObjectsOfType:predicate:` — deletes this app's matching objects;
  success with the count (0 when none match).
- Deleting a correlation removes the correlation object (count 1) but its
  member samples remain (systolic count still 1 afterwards). Before the
  deletion the member did not match `predicateForObjectsWithNoCorrelation`;
  the predicate was not re-checked after it (open).
- Deleting a workout does not delete associated samples (level 1).
- Every deletion produces a tombstone (§4) and fires observers (§5).

## 9. Sync identifiers

Metadata `HKMetadataKeySyncIdentifier` (string) requires
`HKMetadataKeySyncVersion` (number; missing version raises
`_HKObjectValidationFailureException`). Saving a sample with the same sync
identifier from the same source and a **higher** version replaces the old
one (old becomes a tombstone, new one is added, in one change set). A
**lower or equal** version is accepted (success) but ignored: the stored
version stays.

## Evidence

| Claim | Level |
|---|---|
| Query class/initializer/option names and raw values | 4 |
| Interval rules, sort/limit, anchors and tombstones, observer timing, statistics values, averaging weights, proration, merge golden case, historical-range effect, sync replacement, deletion results | 3 (27.1 and 27.0; cross-source on 27.1) |
| Source priority list in the Health app, equivalent-continuous-level formula, own-data rule, workout deletion | 1 |
| 45-second weight interpretation | 3 (fit), rule open |
