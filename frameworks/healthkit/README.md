# ycode-healthkit — open HealthKit (clean room)

A Linux-buildable reimplementation of Apple's HealthKit, written only from
`specs/frameworks/healthkit/` (plus public documentation) under the clean-room
protocol of the repository's `AGENTS.md`. Library module: **`HealthKit`**, so
existing source that says `import HealthKit` compiles against it.

Status: rounds **R2–R5** of `specs/frameworks/healthkit/plan.md`, plus the
Swift query descriptors of R10 that wrap them.

| Round | Scope | Conformance suites |
|---|---|---|
| R2 | Generated type registry, `HKUnit`/`HKQuantity`, object and sample classes, metadata rules, validation exceptions, secure coding | C-UNITS, C-TYPES, C-VALIDATE |
| R3 | SQLite store engine: save/delete transactions (one call = one change set), shared anchor sequence, tombstones with metadata, sync identifiers, sources/revisions/devices, correlations, characteristics, persistence | C-STORE, C-ANCHOR |
| R4 | Predicates (interval rules, metadata, quantity, category, source, device, UUID, workout, correlation, compound/block), sample/anchored/observer/correlation/source queries, sorting, limits, long-running updates | C-QUERY, C-OBSERVE |
| R5 | Statistics and collection queries: whole-sample statistics, prorated buckets, merging by source priority, arithmetic / temporally weighted (duration + 45 s) / equivalent-continuous-level averages, duration as interval union, historical-range clamp | C-STATS, C-COLLECT, C-MERGE |
| R10 (part) | `HKSamplePredicate`, sample/anchored/statistics/collection/source query descriptors, async store methods | C-SWIFT (subset) |

Each test names the spec section it checks; the golden values are those of
`plan.md` §3.2 and `queries.md` / `units.md`.

## Build and test

    swift build && swift test        # macOS 14+ or Linux, Swift 6.4

Linux needs the SQLite development package (`libsqlite3-dev`). Swift Testing's
exit tests are used for two "the public API traps" checks.

## Dependencies

| Dependency | Version | Licence | How |
|---|---|---|---|
| SQLite (system `libsqlite3`) | whatever the OS ships (3.x) | public domain | `CSQLite` system-library target (`Sources/CSQLite`), header + `-lsqlite3` |

No third-party Swift packages.

## Module name on macOS

The library module is named `HealthKit` on every platform. In this package's own
build, SwiftPM puts the package's module directory ahead of the SDK frameworks,
so `import HealthKit` resolves to this module and Apple's framework is never
loaded or linked (checked with Swift 6.4 / macOS 27: the tests import
`HealthKit` and get these types). Per `frameworks/README.md`, the package is
self-contained: do not add it to a target that also uses Apple's HealthKit.
Swift class names are module-qualified (`HealthKit.HKUnit`) and no class is
exported under an Objective-C name, so nothing clashes in the Objective-C runtime.

## Architecture (`design.md` §3–§7)

    HKHealthStore / HKQuery (API, validation, callback queues)
          │  value-type records (Codable), predicate nodes
          ▼
    YcodeHealthDaemon (engine: SQLite store, authorization store, change journal,
                       query back end) ──► StatisticsEngine (pure functions)

- **Objects** are thin immutable wrappers over `Codable` records
  (`Objects/Records.swift`); the same records are the storage form and the
  future wire form. Secure coding archives the record.
- **The engine** (`Store/HealthDaemon.swift`) runs in-process on its own serial
  queue over one SQLite connection (WAL for files). Every entry point takes
  records plus a client identity, so a later round can move it behind a socket
  or XPC daemon without touching the API layer. Predicate nodes are
  serialisable except block predicates (`NSPredicate(block:)`), which a remote
  daemon would evaluate client-side after a coarse server-side filter.
- **Schema** (`Store/Schema.swift`): Ycode's own, after `design.md` §4 —
  objects keyed by their anchor, typed side tables, metadata rows, associations,
  tombstones sharing the anchor sequence, sync identifiers, authorization,
  source priority, background-delivery registrations, settings.
- **Callbacks** never run on the caller's thread: store completions on a private
  serial queue per store, query results on a private serial queue per query.
- **Exceptions** (`errors.md` §3): validation throws an internal typed error;
  the public API turns it into a trap — a real `NSException` with the interop
  name on Darwin, `fatalError` with the same name and reason on Linux.

## Ycode extensions (not Apple API)

| Name | Purpose |
|---|---|
| `YcodeHealthClient` | The app identity (bundle identifier, name, version, product type, OS version) that becomes `HKSource`/`HKSourceRevision`. `.processDefault` comes from `YCODE_HEALTHKIT_BUNDLE_IDENTIFIER` / `YCODE_HEALTHKIT_APP_NAME`, else the main bundle, else `local.<process name>`. |
| `YcodeHealthDaemon` | The engine. `.shared` opens `YCODE_HEALTHKIT_STORE`, else `~/Library/Application Support/ycode-healthkit/healthdb.sqlite` (macOS) or `$XDG_DATA_HOME`/`~/.local/share/ycode-healthkit/healthdb.sqlite` (Linux); `init(databaseURL: nil)` is in memory. |
| `YcodeHealthDaemon.setConsentResponder` | Answers authorization requests (the R6 consent UI does not exist yet). Default: allow everything requested, all recorded data. Return `nil` to cancel (code 7). |
| `setSourcePriority(_:for:)`, `setCharacteristic(_:value:)`, `objectCounts()` | Developer tools: the Health app's source list, characteristics, store census. |
| `HKHealthStore(ycodeDaemon:client:)`, `ycodeClient` | A store acting as a given client on a given engine (tests, tools, multi-app simulations). |
| `ycodeCalendar` on collection queries/descriptors | Calendar for bucket layout (default `Calendar.current`). |

## Differences from the reference to know about

- `HKUnit(from:)` and the type initializers (`HKQuantityType(.stepCount)`)
  return the interned object through protocol-extension initializers
  (`_HKUnitInterning`, `_HKTypeInterning`); quantity-sample initializers return
  the cumulative/discrete subclass the same way.
- Sort descriptors: on Darwin by key (`HKSampleSortIdentifierStartDate`, …); on
  Linux, swift-corelibs-foundation has no key-value coding, so use key paths
  (`NSSortDescriptor(keyPath: \HKSample.startDate, …)`) or `SortDescriptor`
  with the descriptors.
- Plain `NSPredicate(format:)` predicates exist only on Darwin; comparisons on
  `startDate`, `endDate`, `UUID`, `value`, `quantity`, `duration` and
  `metadata.<key>` are translated, anything else matches nothing. Block and
  constant predicates work everywhere. On Linux the predicate constructors that
  take `NSComparisonPredicate.Operator` compile with a deprecation warning
  (corelibs marks the class unsupported; only its operator enum is used).
- No entitlement or Info.plist checks yet (R6); a missing bundle identifier
  falls back to `local.<process name>` instead of raising `NSGenericException`.
- Preferred units: the `en_US` table only (regions are R8).

## Deferred

- **R6** authorization: consent UI and broker, usage-string and entitlement
  checks, required-read types, per-object authorization, clinical records flow.
- **R7** workouts: `HKWorkoutBuilder`, routes, series builders, live sessions,
  `HKWorkout.allStatistics` (the workout object, events, active-time duration,
  totals and `predicateForObjects(from:)` association exist).
- **R8** background launch on change (registrations are stored), preferred units
  by region, activity summaries. **R9** records and medications. **R10** the
  remaining descriptors and `HKAttachment*`. **R11** drop-in guest framework.
- The daemon/IPC split of R3 (the engine is in-process; see Architecture).
- Formatter bridges (`unitFromMassFormatterUnit:` …), walking-steadiness and
  breathing-disturbance classification functions, quantity series samples.

## Open spec questions (choices made here)

1. `unitString` factor order (plan.md §5 Q5): ranked scalar, length, volume,
   time, energy, pressure, other, temperature, mass; ties by symbol.
2. Molar masses: units.md §3 says "shortest round-trip decimal", but its example
   (`180.15588000005408` → `180.1558800000541`) is `%.16g`, not the shortest
   round trip; `%.16g` is implemented.
3. identifiers.md lacks the category type → value enumeration mapping and the
   value class of each metadata key; both are taken from public documentation
   (level 1, listed in `Scripts/gen_types.py` and `Objects/Validation.swift`).
4. Identifier strings of the activity-summary and electrocardiogram singleton
   types are not in identifiers.md (`HKActivitySummaryTypeIdentifier`,
   `HKDataTypeIdentifierElectrocardiogram` used).
5. The sample layouts behind the "day-3 body temperature" golden values are not
   given; 10 °C over 06:46–07:05 plus 20 °C over 07:05–07:15 reproduces all of
   them (avg 15, duration 1740 s, [07:00, 07:05] → 10).
6. Equivalent-continuous-level weights: queries.md (level 1) says duration
   weights, design.md says the temporal weights (duration + 45 s); design.md's
   is implemented.
7. Merging: dedup is done once over the query range (not per bucket);
   touching intervals do not overlap; an instant overlaps an interval that
   contains it. Statistics result ranges use all matching samples.
8. Discrete statistics in collections: a sample belongs to every bucket it
   overlaps (instants: the bucket containing them), with whole-sample weights.
9. Historical range: a sample is excluded when its start precedes the bound.
10. Observer queries with a predicate fire for matching additions and for any
    deletion of the type (plan.md §5 Q7).
11. Anchored queries return tombstones of the type regardless of the predicate.
12. `HKStatistics` quantities use the unit of the most recent contributing
    sample; `statistics(for:)` returns an empty statistics object for an empty
    bucket.
13. Minimum duration "0" means duration must be > 0; `maximumAllowedDuration`
    of an unrestricted type answers 0.
14. Deleting a correlation is allowed for its own source without a share check
    (correlation types cannot be shared); afterwards its members match
    `predicateForObjectsWithNoCorrelation` (queries.md §8 left this open).

## Layout

    Package.swift
    Scripts/gen_types.py          identifiers.md → Sources/HealthKit/Generated/*.swift
    Sources/CSQLite/              system SQLite
    Sources/HealthKit/
      Generated/                  type tables, string constants, enumerations (do not edit)
      Units/ Types/ Objects/      R2
      Store/                      R3 engine and schema
      Queries/                    R4 predicates, queries, descriptors
      Statistics/                 R5
      HKHealthStore.swift
    Tests/HealthKitTests/         one suite per conformance test of plan.md §4
