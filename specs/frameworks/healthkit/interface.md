# HealthKit spec: interface and object model

Part of `specs/frameworks/healthkit/`. Names are interop facts from the SDK
(level 4; the complete name list with versions is `api-inventory.md`, the
identifier values `identifiers.md`). Descriptions are our own words; behavior
marked (L3) was measured with `HealthProbe` on iOS 27.1 and 27.0.

## 1. The health store (`HKHealthStore`)

One object per app (apps may create several; they share the daemon
connection). Responsibilities:

| Group | Members (names) | Notes |
|---|---|---|
| Availability | `+isHealthDataAvailable`, `supportsHealthRecords`, `earliestPermittedSampleDate` | YES / entitlement-dependent / year 1 in the simulator (L3) |
| Authorization | `authorizationStatusForType:`, `requestAuthorizationToShareTypes:readTypes:completion:`, `getRequestStatusForAuthorizationToShareTypes:readTypes:completion:`, `requestPerObjectReadAuthorizationForType:predicate:completion:`, `handleAuthorizationForExtensionWithCompletion:`, `getEarliestAuthorizedSampleDateForTypes:completion:` (27.0) | `authorization.md` |
| Writing | `saveObject:withCompletion:`, `saveObjects:withCompletion:` | atomic per call (one change set, L3 one observer call) |
| Deleting | `deleteObject:withCompletion:`, `deleteObjects:withCompletion:`, `deleteObjectsOfType:predicate:withCompletion:` | `queries.md` §8 |
| Queries | `executeQuery:`, `stopQuery:` | `queries.md` |
| Characteristics | `dateOfBirthComponentsWithError:`, `biologicalSexWithError:`, `bloodTypeWithError:`, `fitzpatrickSkinTypeWithError:`, `wheelchairUseWithError:`, `activityMoveModeWithError:` (+ deprecated `dateOfBirthWithError:`) | synchronous; §6 |
| Background delivery (category) | `enableBackgroundDeliveryForType:frequency:withCompletion:`, `disableBackgroundDeliveryForType:withCompletion:`, `disableAllBackgroundDeliveryWithCompletion:` | `queries.md` §5 |
| Preferences (category) | `preferredUnitsForQuantityTypes:completion:` | `units.md` §7; posts `HKUserPreferencesDidChangeNotification` on change (L1) |
| Workouts (category) | `recoverActiveWorkoutSessionWithCompletion:` (26.0), `startWatchAppWithWorkoutConfiguration:completion:`, deprecated `addSamples:toWorkout:completion:`; the old start/end/pause session methods are unavailable on iOS | §5 |
| Other categories | `splitTotalEnergy:startDate:endDate:resultsHandler:`, `recalibrateEstimatesForSampleType:atDate:completion:`, `relateWorkoutEffortSample:withWorkout:activity:completion:` / `unrelate…` | L1 |

All asynchronous members complete on a private serial queue (L3).

## 2. Object types

`HKObjectType` is an immutable, interned value: the same identifier always
yields the same instance (L3: identical pointer, equal hash; `description`
is the identifier). Class hierarchy (L4):

    HKObjectType
     ├─ HKCharacteristicType
     ├─ HKActivitySummaryType
     └─ HKSampleType
         ├─ HKQuantityType          (aggregationStyle, isCompatibleWithUnit:)
         ├─ HKCategoryType
         ├─ HKCorrelationType
         ├─ HKWorkoutType
         ├─ HKSeriesType            (workout route, heartbeat series)
         ├─ HKDocumentType          (CDA)
         ├─ HKClinicalType
         ├─ HKAudiogramSampleType, HKElectrocardiogramType
         ├─ HKPrescriptionType      (vision prescription)
         ├─ HKStateOfMindType, HKScoredAssessmentType
         └─ HKMedicationDoseEventType, HKUserAnnotatedMedicationType

- Constructors: `quantityTypeForIdentifier:`, `categoryTypeForIdentifier:`,
  `characteristicTypeForIdentifier:`, `correlationTypeForIdentifier:`,
  `documentTypeForIdentifier:`, `clinicalTypeForIdentifier:`,
  `scoredAssessmentTypeForIdentifier:`, `seriesTypeForIdentifier:` and the
  singletons `workoutType`, `activitySummaryType`, `audiogramSampleType`,
  `electrocardiogramType`, `visionPrescriptionType`, `stateOfMindType`,
  `medicationDoseEventType`, `userAnnotatedMedicationType`. Unknown or
  wrong-kind identifiers return **nil** (no exception, L3).
- Identifier string values: for type identifiers the value equals the
  constant's name (e.g. `HKQuantityTypeIdentifierStepCount`); exceptions
  are the singleton types (`HKWorkoutTypeIdentifier`,
  `HKDataTypeIdentifierAudiogram`, `HKDataTypeStateOfMind`,
  `HKDataTypeUserAnnotatedMedicationConcept`,
  `HKMedicationDoseEventTypeIdentifierMedicationDoseEvent`, …). Full table:
  `identifiers.md`.
- Per sample type (L3): `isMaximumDurationRestricted` /
  `maximumAllowedDuration` (seconds; 166 types 345600 = 4 days, 21
  reproductive-health category types 14 days, a few 8, 10, 28, 31, 85 or
  365 days, menopausal state 0 (instants only); seven category types such as
  pregnancy, lactation and menstrual flow are unrestricted; full list in
  `identifiers.md`), `isMinimumDurationRestricted`
  / `minimumAllowedDuration` (audio exposure types require duration > 0),
  `allowsRecalibrationForEstimates`; `requiresPerObjectAuthorization` on all
  object types (YES for vision prescription and user-annotated medication).
  Reading `maximumAllowedDuration` of an unrestricted type does not raise.
- Quantity types (121 in the 27.1 SDK): an aggregation style
  (0 cumulative, 1 discrete arithmetic, 2 discrete temporally weighted,
  3 discrete equivalent continuous level) and exactly one compatible unit
  dimension. Category types (72): an allowed value set (an enum from
  `identifiers.md`, or only `HKCategoryValueNotApplicable` = 0 for
  "event" types such as mindful session). Characteristics (6),
  correlations (2: blood pressure, food), documents (1: CDA), clinical
  (9), scored assessments (2: GAD-7, PHQ-9).

## 3. Objects and samples

| Class | Adds (names) | Semantics |
|---|---|---|
| `HKObject` | `UUID`, `sourceRevision`, `device`, `metadata` | immutable; UUID assigned at construction; source revision assigned when saved (the app's) |
| `HKSample` | `sampleType`, `startDate`, `endDate`, `hasUndeterminedDuration` | start ≤ end (else exception); duration within the type's limits |
| `HKQuantitySample` | `quantityType`, `quantity`, `count` | constructors `quantitySampleWithType:quantity:startDate:endDate:[device:][metadata:]`; the concrete class is chosen by the type's style |
| `HKCumulativeQuantitySample` | `sumQuantity` | class of samples of cumulative types (L3: step samples) |
| `HKDiscreteQuantitySample` | `minimumQuantity`, `averageQuantity`, `maximumQuantity`, `mostRecentQuantity`, `mostRecentQuantityDateInterval` | class of discrete samples (L3: heart rate, body mass, blood pressure) |
| `HKCategorySample` | `categoryType`, `value` | value validated against the type's enum |
| `HKCorrelation` | `correlationType`, `objects`, `objectsForType:` | groups samples; blood pressure needs exactly one systolic and one diastolic (L3) — saving the correlation saves the members |
| `HKWorkout` | `workoutActivityType`, `workoutEvents`, `workoutActivities`, `duration`, `allStatistics`, `statisticsForType:` (+ deprecated totals) | §5 |
| `HKSeriesSample` → `HKWorkoutRoute`, `HKHeartbeatSeriesSample` | `count` | series data read with their queries |
| `HKQuantitySeriesSample` data | via `HKQuantitySeriesSampleBuilder` / `…Query` | a quantity sample with `count` > 1 |
| `HKDocumentSample` → `HKCDADocumentSample` | `document` (title, patient/author/custodian names, data) | CDA XML documents, validated against the CDA schema |
| `HKClinicalRecord` | `clinicalType`, `displayName`, `FHIRResource` | read-only for apps; created by the Health Records service |
| `HKElectrocardiogram`, `HKAudiogramSample`, `HKVisionPrescription` (glasses, contacts), `HKStateOfMind`, `HKGAD7Assessment`, `HKPHQ9Assessment`, `HKMedicationDoseEvent` | type-specific properties (`api-inventory.md`) | |
| `HKDeletedObject` | `UUID`, `metadata` | tombstone, `queries.md` §4 |

Equality: objects compare by UUID (L1). All objects support secure coding.

## 4. Metadata, sources and devices

- **Metadata**: a dictionary of string keys to `NSString`, `NSNumber`,
  `NSDate` or `HKQuantity` values (L3: those four round-tripped; an
  arbitrary object raised). Keys defined by HealthKit (71 in the 27.1 SDK,
  `identifiers.md`) have fixed value classes (L3: the external-UUID key
  rejected a number). Their string values often differ from the symbol name
  (`HKMetadataKeyExternalUUID` = `HKExternalUUID`), so the value is what is
  stored. App keys are free-form; an unknown `HK`-prefixed key was accepted
  at construction. Values come back as stored (quantities print as "3 m",
  dates as dates).
- **Sync identifier / version** keys give replace-on-higher-version
  semantics (`queries.md` §9).
- **Source** (`HKSource`): `name` (the app's display name) and
  `bundleIdentifier`; `+defaultSource` is the calling app. Sources are
  compared by bundle identifier. System-generated data (e.g. the live
  workout data source) uses a separate system source (L3).
- **Source revision** (`HKSourceRevision`): source, `version` (the app's
  `CFBundleVersion`, L3 "7"), `productType` (device model identifier,
  L3 `iPhone19,4`), `operatingSystemVersion` (L3 27.1.0) — stamped at save.
- **Device** (`HKDevice`): name, manufacturer, model, hardware, firmware,
  software versions, local identifier, UDI device identifier; optional on
  samples (nil when the app passes none, L3); `+localDevice` describes the
  phone (`simulator-baseline.md` §2). Device property keys
  (`HKDevicePropertyKey…`) are used in device predicates.

## 5. Workouts

### 5.1 `HKWorkoutConfiguration`, events and activities

- Configuration: `activityType` (`HKWorkoutActivityType`, 86 cases incl.
  running 37, walking 52, other 3000; two are unavailable on iOS), `locationType` (unknown 1, indoor 2, outdoor 3),
  `swimmingLocationType`, `lapLength`.
- `HKWorkoutEvent`: `type` (`HKWorkoutEventType`: pause 1, resume 2, lap 3,
  marker 4, motion paused 5, motion resumed 6, segment 7, pause or resume
  request 8), `dateInterval`, `metadata`.
- `HKWorkoutActivity` (16.0): a sub-interval with its own configuration,
  events and statistics; a single-activity workout has one activity
  spanning the workout (L3).

### 5.2 `HKWorkoutBuilder` (L3 golden run)

`initWithHealthStore:configuration:device:` → `beginCollectionWithStartDate:`
→ `addSamples:` / `addWorkoutEvents:` / `addMetadata:` / `addWorkoutActivity:`
→ `endCollectionWithEndDate:` → `finishWorkoutWithCompletion:` (or
`discardWorkout`).

- Running 06:00–06:30 with pause 06:10 and resume 06:12: `elapsedTimeAtDate:`
  06:20 = 1080 s, at end = 1680 s; workout `duration` 1680 s (paused time
  excluded); start/end 06:00/06:30; 2 events; 1 activity.
- Added samples are associated with the workout
  (`predicateForObjectsFromWorkout:` finds them) and saved.
- `allStatistics` per added type, **prorated to active time**: active
  energy 300 kcal over 30 min → sum 280 kcal; distance 5000 m → 4666.67 m;
  heart rate (discrete) → average/min/max 2.5 count/s (150/min).
- Builder metadata ends up on the workout (`HKIndoorWorkout` = NO,
  app keys).

### 5.3 Routes and series

`HKWorkoutRouteBuilder` (`initWithHealthStore:device:`, `insertRouteData:`,
`addMetadata:`, `finishRouteWithWorkout:metadata:`) produces an
`HKWorkoutRoute` series sample (L3: count 3) associated with the workout;
`HKWorkoutRouteQuery` returns the `CLLocation` values in time order with
their coordinates, altitude and timestamps (L3 exact round trip of three
points). `HKQuantitySeriesSampleBuilder` and `HKHeartbeatSeriesBuilder`
follow the same insert/finish pattern; `discard` abandons.

### 5.4 Live sessions on iPhone (26.0+)

`HKWorkoutSession` (`initWithHealthStore:configuration:error:`, `prepare`,
`startActivityWithDate:`, `pause`, `resume`, `stopActivityWithDate:`, `end`,
`associatedWorkoutBuilder`, delegate) and `HKLiveWorkoutBuilder` with an
`HKLiveWorkoutDataSource`. States (`HKWorkoutSessionState`): not started 1,
running 2, ended 3, paused 4, prepared 5, stopped 6. L3 transitions:
1→2 on start, 2→4 pause, 4→2 resume, 2→3 end (no visible 6 between stop
and end in our run); delegate callbacks on a private queue; the data source
collects active energy and distance; the finished workout's duration ≈
the elapsed time; `recoverActiveWorkoutSessionWithCompletion:` returns nil
when nothing is active. Workout zones (`HKLiveWorkoutZoneUpdate`, Swift
`HKWorkoutZone…` types) exist in 27.0; the daemon reported no zone
configuration in the simulator.

## 6. Characteristics

Synchronous getters returning wrapper objects (`HKBiologicalSexObject`,
`HKBloodTypeObject`, `HKFitzpatrickSkinTypeObject`, `HKWheelchairUseObject`,
`HKActivityMoveModeObject`) or date components. Before authorization: nil
plus code 5. After authorization in the simulator (no profile data): date of
birth nil without error; sex, blood type, skin type, wheelchair 0 (not set);
move mode 1 (active energy) (L3). Characteristics can be read only, never
written by apps.

## 7. Activity summaries

`HKActivitySummary` (ring values and goals, `paused`,
`dateComponentsForCalendar:`) read with `HKActivitySummaryQuery` using
date-component predicates. Computed by the system from samples; not written
by apps. Not probed beyond authorization (read-only, status 1).

## 8. Clinical, verifiable and medication data

- Clinical records (`HKClinicalRecord`, FHIR resources of releases DSTU2,
  R4 (`HKFHIRRelease…`), resource types in `identifiers.md`): requested only
  with the `health-records` entitlement; the records flow asks the user to
  add provider accounts (`authorization.md` §4.1). The simulator has no
  records; queries without authorization fail with code 5.
- Verifiable records (`HKVerifiableClinicalRecordQuery`, SMART Health Card /
  EU DCC credential types): need `verifiable-health-records`; one-time
  user selection, no persistent authorization (L1).
- Medications (26.0): `HKUserAnnotatedMedication` (nickname, archived,
  schedule, `HKMedicationConcept` with general form and codings) read with
  `HKUserAnnotatedMedicationQuery` (per-object authorization), and
  `HKMedicationDoseEvent` samples. L3: the medication query with no
  authorization completed immediately with no item, `done` YES, no error;
  requesting the medication type through the normal call raises.

## 9. Swift refinements (level 4, names only)

The overlay adds async/await variants of the store methods (imported from
the Objective-C completion-handler methods) and **query descriptors**:
`HKSampleQueryDescriptor`, `HKAnchoredObjectQueryDescriptor`,
`HKStatisticsQueryDescriptor`, `HKStatisticsCollectionQueryDescriptor`,
`HKSourceQueryDescriptor`, `HKActivitySummaryQueryDescriptor`,
`HKElectrocardiogramQueryDescriptor`, `HKHeartbeatSeriesQueryDescriptor`,
`HKQuantitySeriesSampleQueryDescriptor`, `HKWorkoutRouteQueryDescriptor`,
`HKWorkoutEffortRelationshipQueryDescriptor`,
`HKUserAnnotatedMedicationQueryDescriptor`,
`HKVerifiableClinicalRecordQueryDescriptor`; protocols `HKAsyncQuery`
(`result(for:)`) and `HKAsyncSequenceQuery` (`results(for:)` as an async
sequence); `HKSamplePredicate` with static constructors per sample kind
(`quantitySample`, `categorySample`, `workout`, `correlation`,
`heartbeatSeries`, `workoutRoute`, `electrocardiogram`, `audiogram`,
`clinicalRecord`, `stateOfMind`, `visionPrescription`, `phq`, `gad`,
`sample`); `HKCategoryValuePredicateProviding`; `HKAttachmentDataReader`;
workout zone value types (`HKWorkoutZone`, `HKWorkoutZoneConfiguration`,
`HKWorkoutZoneDuration`, `HKWorkoutZoneGroup`). The descriptors wrap the
Objective-C queries with the same semantics.

## Evidence

| Claim | Level |
|---|---|
| Class, member, constant names; hierarchy; enum values | 4 |
| Interning, nil for bad identifiers, duration limits, aggregation styles, sample classes, metadata value classes, source revision fields, builder/route/session behavior, characteristic answers, medication query | 3 |
| Object equality by UUID, CDA validation, verifiable-record consent, preference notification, activity summary computation, category of system-only data | 1 |
