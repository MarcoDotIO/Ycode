# HealthKit spec: authorization and privacy

Part of `specs/frameworks/healthkit/`. Level 3 facts come from `HealthProbe` on
iOS 27.1 and 27.0 (identical); level 1 from Apple's public documentation
(our words); key names are interop facts.

## 1. Entitlements (code-signing keys)

| Key | Value | Effect |
|---|---|---|
| `application-identifier` | string (team prefix optional in the simulator) | identifies the app; becomes `HKSource.bundleIdentifier`. Missing → creating the default source raises `NSGenericException` ("Unable to create default source. The bundle identifier of the client is nil") |
| `com.apple.developer.healthkit` | true | required for every store operation; missing → code 4 "Missing com.apple.developer.healthkit entitlement." (availability checks still answer YES) |
| `com.apple.developer.healthkit.background-delivery` | true | required by `enableBackgroundDeliveryForType:…`; missing → code 4 naming the key |
| `com.apple.developer.healthkit.access` | array of strings: `health-records`, `verifiable-health-records` | `health-records` turns `supportsHealthRecords` on and allows requesting clinical types; `verifiable-health-records` gates the verifiable-record query (missing → code 4 "Missing required entitlement identifier: verifiable-health-records"). Without `health-records`, requesting a clinical type raises (§6) |
| `com.apple.developer.healthkit.recalibrate-estimates` | true | gates `recalibrateEstimatesForSampleType:…` (level 1; not probed) |

In the simulator these are read from the app's simulated-entitlements
section (`simulator-baseline.md` §6); on devices from the provisioning
profile–backed signature (level 1).

## 2. Info.plist keys

| Key | Needed when |
|---|---|
| `NSHealthUpdateUsageDescription` | requesting share (write) access; missing → `NSInvalidArgumentException` "NSHealthUpdateUsageDescription must be set in the app's Info.plist in order to request write authorization for the following types: …" |
| `NSHealthShareUsageDescription` | requesting read access (level 1; mirror exception) |
| `NSHealthClinicalHealthRecordsShareUsageDescription` | requesting clinical record types (level 1) |
| `NSHealthRequiredReadAuthorizationTypeIdentifiers` | optional list of types the app cannot work without (level 1; relates to code 10) |

The sheet shows the strings prefixed with "App Explanation:".

## 3. Model

Authorization is per **app (source) × object type × direction**:

- **Share** (write) — the app may save objects of the type and delete its
  own. Status is visible to the app through `authorizationStatusForType:`:
  0 not determined, 1 sharing denied, 2 sharing authorized.
- **Read** — the app may read other sources' objects of the type. Read
  grants are **never disclosed**: `authorizationStatusForType:` reports only
  the share status, so a type the app requested only for reading reports 1
  (sharing denied) whether reading was granted or not, once asked. A denied
  read looks exactly like an empty store (queries return nothing; statistics
  return code 11).
- The app can always read and delete what it wrote itself (level 1; §7 of
  `queries.md`).
- **Request status** (`getRequestStatusForAuthorizationToShareTypes:readTypes:`):
  0 unknown (error, e.g. missing entitlement), 1 should request (some type of
  the given sets was never presented to the user), 2 unnecessary (all were
  presented). It does not reveal answers.
- **Historical range** (27.0+): with each read grant the user chooses how far
  back the app may read (§5).
- **Per-object** types (`requiresPerObjectAuthorization` YES: the vision
  prescription and user-annotated medication types) are authorized per
  sample with `requestPerObjectReadAuthorizationForType:predicate:` (level 1);
  they cannot be requested for reading through the normal call (exception),
  but sharing them uses the normal sheet.

## 4. Request flow

`requestAuthorizationToShareTypes:readTypes:completion:`:

1. Validate synchronously, raising `NSInvalidArgumentException` for: both
   sets empty or nil ("Must request authorization for at least one data
   type"); a type that may not be shared ("Authorization to share the
   following types is disallowed: …": characteristic types, correlation
   types, activity summary, Apple-computed types such as stand hour and
   walking steadiness); a type that may not be read ("Authorization to read
   the following types is disallowed: …": correlation types, clinical types
   without the access entitlement, per-object types); missing usage strings
   (§2).
2. Fail asynchronously with code 4 for missing entitlement.
3. If every requested type was already presented: complete immediately with
   success YES and no UI.
4. Otherwise present the **system sheet** over the app (a remote view from
   `com.apple.HealthPrivacyService`) and complete when the user finishes.
   Completion success YES means "the user answered", not "granted"; NO with
   code 7 means the user cancelled.

### 4.1 The sheet (observed on both runtimes)

| Page | Content | Controls |
|---|---|---|
| 1 "Health Access" | Health icon, arrow(s), app icon (one arrow ← for write-only, ⇄ when read is requested); title naming the app's display name; a subtitle that depends on read/write; "Select All N Topics" / "Deselect N Topics" (N = number of toggles); **Read Access** section: usage string, then one toggle per readable topic grouped under category headings (Activity, Body Measurements, Heart, Mental Wellbeing, Nutrition, Sleep, Vitals, …); **Write Access** section likewise; footer on access-while-open and background refresh | all toggles start **off**; primary button "Allow" (disabled while nothing is on) or "Continue" when any read toggle is on; "Don't Allow" |
| 2 (only if a read toggle is on) | "How much data would you like to share with …?" | two cards: "Past 30 Days and Future Data", "All Recorded Data and Future Data"; "Allow" disabled until a card is chosen; "Don't Allow"; back |
| Clinical (health-records types) | onboarding ("Connect your accounts…"), then "1 of 4 — Share Health Records", "No Accounts Added", "Add Account" | Next, close × (→ code 7) |

Topic labels are Health's display names for types (Steps, Walking + Running
Distance, Workout Routes, Workouts, Height, Weight, Heart Rate, Mindful
Minutes, Dietary Energy, Sleep, Body Temperature, …). Ycode writes its own
labels and artwork.

"Don't Allow" counts as answered: types become presented-and-denied (level 1).

## 5. Historical-data range (new in iOS 27)

- Choosing "Past 30 Days and Future Data" sets, per granted read type, an
  **earliest authorized sample date** = grant time − 30 days.
  `getEarliestAuthorizedSampleDateForTypes:completion:` returns a dictionary
  type → date (observed: grant 2026-10-19 23:55:40 UTC → 2026-09-19
  23:55:40). "All Recorded Data" means no bound.
- Effect (observed): statistics and collection queries ignore samples
  before the bound, **including the app's own**; sample queries still return
  the app's own older samples. Other sources' older samples are hidden from
  all reads (Ycode assumption consistent with the purpose; not separately
  measured).

## 6. What can be requested

| Category | Share | Read |
|---|---|---|
| Quantity and category types | yes, except Apple-computed ones (stand hour, walking steadiness, …) | yes |
| Characteristic types | **no** (exception) | yes (status 1 afterwards) |
| Correlation types | **no** — request the member types | **no** |
| Workout type, workout route series | yes | yes |
| Activity summary type | no | yes |
| Clinical types | no | only with `health-records`; separate records flow |
| Per-object types | yes (normal sheet) | no via normal request (exception); per-object request |
| Document (CDA) type | yes (level 1) | yes (level 1; per-document consent) |

## 7. Changing and revoking

On devices the user edits grants in Settings → Privacy & Security → Health or
in the Health app; changes take effect immediately, reads become empty
(level 1). In the 27.1 simulator there is no Health app; the Settings pane
bundle exists (not exercised). Erasing the device resets everything.

## 8. Background and locked-device access

- Data is only accessible while the device is unlocked (protected store,
  level 1); in the simulator there is no lock, so this is not observable.
- Background delivery needs its entitlement and observer queries
  (`queries.md` §5).
- Apps running a workout session may access data while locked; the system
  announces this once with a banner (observed after our first live session).

## Evidence

| Claim | Level |
|---|---|
| Entitlement effects (application-identifier, healthkit, background-delivery, access/health-records, verifiable) | 3 |
| recalibrate-estimates entitlement, `NSHealthShareUsageDescription` / clinical / required-read keys | 1 |
| Status values, request status values | 3 (+ 4 for raw values) |
| Read non-disclosure, own-data rule | 3 (status 1 for read-only types, empty results for denied reads) + 1 |
| Validation exceptions and their messages' meaning | 3 |
| Sheet pages and controls | 3 (screenshots in `research/dirty/healthkit/`, not committed) |
| Historical range and its effect on statistics | 3 |
| Per-object request API | 1 + 4 (names) |
| Settings/Health-app editing, protection while locked | 1 |
