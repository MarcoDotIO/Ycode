# HealthKit spec: errors and exceptions

Part of `specs/frameworks/healthkit/`. HealthKit reports problems two ways:
**programming errors** raise Objective-C exceptions synchronously (the app
crashes unless it catches them), and **runtime conditions** complete with an
`NSError` in domain `com.apple.healthkit` (`HKErrorDomain`). Messages below
are paraphrased or quoted only as far as needed to identify the case; Ycode
writes its own message text (Apple's are localized).

## 1. Error codes (`HKErrorCode`, raw values level 4)

| Code | Name | When (observed = level 3) |
|---|---|---|
| 0 | `HKUnknownError` (alias `HKNoError`, deprecated) | — |
| 1 | `HKErrorHealthDataUnavailable` | device without HealthKit (never in the simulator) |
| 2 | `HKErrorHealthDataRestricted` | restricted by profile (level 1) |
| 3 | `HKErrorInvalidArgument` | observed: deleting an object that is not found / not the app's / already deleted ("Failed to find some objects for deletion."); also invalid metadata reported by the daemon |
| 4 | `HKErrorAuthorizationDenied` | observed: missing entitlement (`com.apple.developer.healthkit`, `…background-delivery`, access identifiers); saving a type the user did not allow to share ("Not authorized") |
| 5 | `HKErrorAuthorizationNotDetermined` | observed: any data call for a type never presented ("Authorization is not determined" / "Authorization not determined"); preferred units with any never-presented type ("…not determined for all types provided.") |
| 6 | `HKErrorDatabaseInaccessible` | protected data while locked (level 1) |
| 7 | `HKErrorUserCanceled` | observed: user closed the clinical-records flow |
| 8 | `HKErrorAnotherWorkoutSessionStarted` | a second session started (level 1) |
| 9 | `HKErrorUserExitedWorkoutSession` | (level 1) |
| 10 | `HKErrorRequiredAuthorizationDenied` | a type listed as required in Info.plist was denied (level 1) |
| 11 | `HKErrorNoData` | observed: statistics query with no matching samples (including when read is denied) |
| 12 | `HKErrorWorkoutActivityNotAllowed` | (level 1) |
| 13 | `HKErrorDataSizeExceeded` | (level 1) |
| 14 | `HKErrorBackgroundWorkoutSessionNotAllowed` | (level 1) |
| 15 | `HKErrorNotPermissibleForGuestUserMode` | visionOS guest mode (level 1) |

Observed `userInfo` of store errors: only `NSLocalizedDescription`. Daemon
log lines show richer internal keys; apps do not see them.

## 2. Completion conventions

- Completion blocks of the store and of queries run on a private HealthKit
  queue, never the main thread.
- Boolean completions: `success == NO` always comes with a non-nil error;
  the request-authorization completion's `success == YES` means "answered".
- Missing-entitlement errors are delivered asynchronously (completion),
  not thrown.

## 3. Exceptions (observed)

| Situation | Exception name | Gist of the reason |
|---|---|---|
| Authorization request with nothing in it | `NSInvalidArgumentException` | must request at least one data type |
| Share of a non-shareable type | `NSInvalidArgumentException` | authorization to share the following types is disallowed: <ids> |
| Read of a non-readable type | `NSInvalidArgumentException` | authorization to read the following types is disallowed: <ids> |
| Share without `NSHealthUpdateUsageDescription` | `NSInvalidArgumentException` | the key must be set … for the following types |
| Sample quantity with the wrong dimension | `_HKObjectValidationFailureException` | <sample> requires unit of type …; incompatible unit: <unit> |
| End date before start date | `_HKObjectValidationFailureException` | startDate cannot occur after endDate |
| Duration above the type maximum | `_HKObjectValidationFailureException` | exceed the maximum allowed duration … maximum duration for type <id> is 345600 |
| Category value outside the type's enum | `_HKObjectValidationFailureException` | value N is not compatible with type <id> |
| Metadata value of an unsupported class | `_HKObjectValidationFailureException` | invalid metadata value … for key … |
| Known metadata key with the wrong value class | `_HKObjectValidationFailureException` | invalid class … for metadata key …; expected NSString |
| Sync identifier without sync version | `_HKObjectValidationFailureException` | sync version must be provided if sync identifier is provided |
| Blood-pressure correlation without exactly one systolic and one diastolic sample | `_HKObjectValidationFailureException` | must have 2 objects … received 1 |
| Statistics option incompatible with the aggregation style | `NSInvalidArgumentException` | option … is not compatible with cumulative/discrete data type … |
| Executing a query object a second time | `NSInvalidArgumentException` | has already been executed and cannot be executed again |
| Converting / comparing incompatible quantities | `NSInvalidArgumentException` | attempt to convert incompatible units: g, m / quantity … has incompatible unit |
| Unparsable unit string | `NSInvalidArgumentException` | unable to parse factorization string <s> |
| Default source without `application-identifier` | `NSGenericException` | unable to create default source; the bundle identifier of the client is nil |
| Walking-steadiness/breathing helpers with an invalid classification | `NSInternalInconsistencyException` | invalid classification: N |

Accepted without exception (observed): negative cumulative quantities
(−5 steps), unknown metadata keys with an `HK` prefix (at construction; the daemon may still reject private keys on save, as its log showed for an internal key), a duration on a
discrete type such as body mass, reading `maximumAllowedDuration` of a type
that is not duration-restricted.

Exception class names are interop-visible (apps may catch by name); the
`_HKObjectValidationFailureException` name is an observed fact (level 3).

## Evidence

Codes and names: level 4. "Observed" rows and the exception table: level 3
(HealthProbe on 27.1 and 27.0). Other "when" descriptions: level 1.
