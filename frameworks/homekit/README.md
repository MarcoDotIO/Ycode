# ycode-homekit — open HomeKit (clean room)

A Linux-buildable reimplementation of Apple's HomeKit model library, written
only from `specs/frameworks/homekit/` (plus public documentation) under the
clean-room protocol of the repository's `AGENTS.md`. Package `ycode-homekit`,
library module **`HomeKit`**, so `import HomeKit` source compiles against it.

```
swift build && swift test          # macOS 14+ or Linux, Swift 6.4
```

## Status by round (`specs/frameworks/homekit/plan.md`)

| Round | State | What is here |
|---|---|---|
| R3 model library | done | Type catalog generated from `type-identifiers.md` (184 HAP types, 33 categories, formats, units, properties, action-set types, significant events, key paths: 255 constants; 60 value enumerations); characteristic metadata and value validation (43–46 before I/O); `HMError` with every `errors.md` code, the private 2040 and the HAP status mapping; the model objects of `object-model.md` §2–§9 and §11 with delegates on the main queue; an in-memory home store behind the `YcodeHomeStore` protocol (optional JSON persistence); an accessory abstraction shaped after HAP-IP with an in-memory test accessory |
| R4 `ycode-homed` | not started | The store protocol is the seam: Codable requests, replies and events, session-based fan-out. The scheduler (timer firing, solar events) belongs there |
| R5–R9 | not started | HAP-IP controller, `ycode-hap-sim`, setup flow, Matter, cameras/BLE |

## Architecture (`open-design.md` §2)

    HMHomeManager / HMHome / … (client mirrors, main-queue delivery)
          │  YcodeHomeRequest ─►   ◄─ YcodeHomeEvent / reply   (all Codable)
          ▼
    YcodeHomeStore protocol ── YcodeLocalHomeStore (in process, serial queue)
          │                         owns: homes (records), prompt answers,
          │                         sessions, notification subscriptions
          ▼
    YcodeAccessoryEndpoint protocol (attribute database aid/iid, read, write,
          │                          events, identify, HAP status codes)
          ▼
    YcodeTestAccessory (in memory)  │  R5: HAP-IP controller endpoints

- **Records** (`Store/Records.swift`) are the truth and the wire form; model
  objects are mirrors keyed by `uniqueIdentifier` and reconciled from the
  record each event carries, so object identities survive updates.
- **Sessions.** Every `HMHomeManager` (and `HMAccessoryBrowser`) is one
  session. A request's events reach every session, tagged with the
  originator, before the request's reply. The originator applies the change
  without delegate callbacks and reports through the completion; other
  sessions get the delegate callbacks. Completions and callbacks run on
  `DispatchQueue.main` (`object-model.md` §12).
- **Characteristic values** are per client: `value` is nil until this client
  reads, writes or is notified. Notifications go to subscribed sessions:
  accessory-originated changes to all of them, writes to every subscriber
  except the writer (HAP's convention that a controller is not notified of
  its own write).
- **Pairing** in this round: `HMAccessoryBrowser` lists published, unpaired
  endpoints; `HMHome.addAccessory` builds records from the endpoint's
  attribute database (one `HMAccessory` per `aid`, bridge = `aid` 1) without a
  setup code.

## Ycode extensions (not Apple API)

| Name | Purpose |
|---|---|
| `YcodeHomeStore`, `YcodeHomeRequest`, `YcodeHomeResponse`, `YcodeHomeEvent`, `YcodeHomeChange`, records | The store boundary R4 replaces |
| `YcodeLocalHomeStore` (+ `Configuration`) | In-memory store. `.shared` backs `HMHomeManager()`; it persists to the JSON file named by `YCODE_HOMEKIT_STORE` if set. Configuration: `persistenceURL`, `simulateNoAccount` (parity mode, 2040), `hubState` (default connected: the store plays the hub), `ownerName`, `consent` (answers the permission prompt; default allow). `publish(_:)` / `unpublish(endpointID:)` make accessory servers appear and disappear; `resetAuthorization(bundleIdentifier:)`; `homeRecords`; `sync` |
| `YcodeHomeClient` | App identity: bundle identifier, usage string, entitlement. `.processDefault` reads the main bundle's Info.plist or `YCODE_HOMEKIT_BUNDLE_IDENTIFIER` / `YCODE_HOMEKIT_USAGE_DESCRIPTION` / `YCODE_HOMEKIT_ENTITLED=0`; a process without an Info.plist is not held to the requirements |
| `HMHomeManager(ycodeStore:client:)`, `HMAccessoryBrowser(ycodeStore:client:)` | Objects on a given store as a given client (tests, tools, multi-app simulations) |
| `YcodeAccessoryEndpoint`, `YcodeAccessoryEndpointDelegate`, `YcodeAccessoryDatabase`, `YcodeCharacteristicAddress`, `YcodeHAPPermission`, `YcodeHAPStatus`, `YcodeAccessoryFailure` | The accessory abstraction |
| `YcodeTestAccessory` | In-memory accessory server: presets (`lightbulb`, `outlet`, `switch`, `thermostat`, `lock`, `temperatureSensor`, `garageDoor`, `bridge(children:)`), control API (`simulateChange`, `forceStatus`, `isReachable`, `writes`, `subscribedAddresses`, `identifyCount`, `responseDelay`) |
| `YcodeCharacteristicDefaults` | Default characteristic templates for test accessories (see Spec questions 11) |
| `YcodeHomeCatalog` | Catalog tables, lookups, short/full UUID forms, HAP category numbers |
| `YcodeValueValidation`, `YcodeNameRules` | The validation and name rules |
| `HMError.ycodeNoAccountError()`, `HMError.describe(_:)` | The 2040 error; Ycode's description texts |

## Behavior notes and deviations

- **Delegates** are Swift protocols with empty default implementations
  (no `@objc optional` on Linux). **Errors** are `HMError` (a
  `CustomNSError` with `HMError.Code`; `catch HMError.notFound` works); the
  non-public 2040 is a plain `NSError` in `HMErrorDomain`.
- **Lifetime.** As with the system framework, apps must keep their
  `HMHomeManager`: homes and accessories stop receiving updates, and
  mutations fail with 47, once their manager is gone.
- **Event triggers.** Predicates are kept by the creating client only (not
  stored) and the predicate builders are not implemented (Linux Foundation
  has no `NSPredicate(format:)`). Triggers are stored and validated but do
  not fire (R4 scheduler). The store acts as the home hub, so enabled event
  triggers report `.enabled`; with `hubState: .notAvailable` they report
  `.disabledNoHomeHub` (open-design.md §2).
- **Location events** take `CLRegion`; on Linux a minimal Core Location
  shim (`CLRegion`, `CLCircularRegion`, `CLLocationCoordinate2D`) is part of
  this module, on Apple platforms Core Location is re-exported.
- **Not produced in this round:** cameras and profiles (`profiles` is
  empty), Matter fields (`matterNodeID`, `matterEndpointID`,
  `matterControllerID` absent or nil), users other than the local owner,
  `manageUsers` and the deprecated `addAndSetupAccessories` (both complete
  with 48), the setup sheet (`HMAccessorySetupManager` always completes with
  23 and an empty userInfo, as the reference's dismissed flow does), watchOS/
  tvOS read-only restrictions, `primaryHome` (nil) and `updatePrimaryHome`
  (48), as the spec describes them as no longer supported.
- Swift 5 language mode (like the sibling packages); model classes are
  `@unchecked Sendable` and are updated on the main queue only.

## Tests

Swift Testing; each suite and test names the spec section or checklist item
it checks. 62 tests, on macOS and Linux.

| File | Spec |
|---|---|
| `CatalogTests.swift` | T-O1 / HK-B14: counts (255), UUID scheme, golden values, deprecations, short/full forms, HAP categories, value enumerations; on a checkout with `specs/`, every row of `type-identifiers.md` §2–§5 against the catalog |
| `ErrorTests.swift` | `errors.md` §1 code table, §2 shapes (2040, 47, 23), §3 HAP status mapping |
| `ValidationTests.swift` | T-O2: every format, bounds (44/45), length (46), type/step/valid values (43), API value forms |
| `AuthorizationTests.swift` | T-O3 (HK-B01–B04, B07–B08 analogues, per-bundle answers, reset), T-O4 (HK-B05: 2040 before name checks), HK-B06 (usage string abort, exit test) |
| `ModelTests.swift` | Homes and names (HK-A01), rooms (A02), zones (A03), service groups (A04), fan-out and main queue (A05/A06), persistence (A11) |
| `AccessoryTests.swift` | Browsing (HK-B11, A28), paired shape (A20), bridges (A27), accessory/service calls, read/write (A21), permissions (A23), notifications (A22), unreachable (A24), forced HAP statuses (T-H8 mapping part), authorization data |
| `AutomationTests.swift` | Action sets (A07, A25), timer rules (A08), triggers and enable (26), event triggers (A09/A26), T-O5 events (copy classes, identifiers, `isSupported`), number ranges, T-O6 setup payloads, setup manager (HK-B12 analogue) |

`HK-A…` expectations are level 1 guesses in `plan.md` §3 until the R2
reference observations exist; the tests check Ycode's reading of them.

## Generator

`Scripts/gen_catalog.py` reads `type-identifiers.md` and writes
`Sources/HomeKit/Generated/{Constants,Catalog,ValueEnums}.swift` (committed).
Run `python3 -I frameworks/homekit/Scripts/gen_catalog.py` after a spec
change; `--check` fails if the generated files are stale.

## Dependencies

| Dependency | Licence | How |
|---|---|---|
| Foundation, Dispatch, Swift Testing | Apache-2.0 (Swift project) | the toolchain |

No other packages; SQLite is not used this round (optional for R3; the
store's JSON snapshot covers persistence until R4's daemon). Apple's HomeKit
ADK (Apache-2.0) was **not** opened in this round (no network); the HAP
facts used are those in `accessory-protocols.md` and `errors.md`, plus the
default characteristic templates described in Spec questions 11.

## Deferred

- R4: daemon and IPC, SQLite store, multi-user, scheduler (timer, calendar,
  solar, duration events), resync after restart (generation counters),
  name limits (49, 46 for names).
- Event-trigger predicates (storage and builders), trigger-owned action sets.
- R5–R9: HAP-IP, accessory simulator, setup sheet and payload decoding
  (T-H9/T-H10 need the ADK bit layout), Matter, cameras, BLE.
- `HMAccessory.profiles` kinds, `HMNetworkConfigurationProfile`,
  `HMMediaSourceDisplayOrderProfile`, vendor lookup by HAP public key.

## Spec questions (choices made here)

1. **Name rules** (HK-A01/A02/A12): trimmed; empty or not starting with a
   letter/digit → 36; control, format or line-separator characters → 35;
   last character not a letter/digit/`. ) ] ' " ! ? ’` → 60; "similar" =
   case-, diacritic- and width-insensitive with white space collapsed; no
   length limit. A room may share its home's name; accessories and services
   are not checked for similar names.
2. **Validation codes** (T-O2 says 43–46): a value off the step grid
   (measured from the minimum, 1e-6 tolerance), outside `validValues`, or
   nil is 43. Strings without `maxLength` are limited to HAP's default 64,
   counted in characters. A Swift `Bool` is not accepted for numeric formats.
3. **Check order** for writes: writable (5) before format and bounds; for
   reads, readable (6) before reachability (4).
4. **Fan-out** (HK-A05/A06): the originator gets no delegate callbacks; two
   managers in one process are separate sessions with their own objects.
5. **Duplicates:** a room already in a zone, a service already in a group,
   an action set already on a trigger, and a second action for the same
   characteristic in one set are 1 (`AlreadyExists`).
6. **Timer triggers** (HK-A08): fire dates must have zero seconds (70);
   recurrences may use only minute, hour, day and week-of-year (69), at
   least 5 minutes (42) and at most 5 weeks (72); enabling a non-recurring
   trigger whose date has passed is 28.
7. **Event triggers:** no events → 27; an event on a characteristic outside
   the home → 2.
8. **Built-in action sets** exist from home creation, are part of
   `actionSets`, may be renamed, and carry Ycode's own names ("Wake Up",
   "Bedtime", "Leaving Home", "Arriving Home").
9. Enabling notifications twice succeeds (68 is never returned).
10. Removing a room moves its accessories to the default room without
    accessory-room callbacks; removing an accessory removes its actions,
    group memberships and subscriptions.
11. **Characteristic defaults** (open-design.md §5): the spec has no
    per-type metadata table. `Accessory/Defaults.swift` holds Ycode's own
    templates following HAP conventions (formats, permissions, ranges,
    units), written from knowledge of the HAP catalog and not re-checked
    against the ADK in this round. Please add a defaults table (from the
    ADK) to `type-identifiers.md`; validation itself always uses the
    metadata an accessory reports.
12. **Categories:** bridged accessories take their category from their
    primary service (Ycode table); HAP category numbers the ADK enum lacks
    (television, speaker, router, doorbell, …) map to Other.
13. **Events:** identifiers are random with version nibble 5 and the
    RFC 4122 variant (as observed); `copy()` of a mutable event gives the
    immutable class; with a home, `isSupported(forHome:)` is true iff the
    hub is connected (location events included).
14. **Unblocking** a bridged accessory is 81, by analogy with 34.
15. Characteristic values a client caches are its own; the store's cache
    is not shown to clients that never read or subscribed.

## Layout

    Package.swift
    Scripts/gen_catalog.py      type-identifiers.md → Sources/HomeKit/Generated/*.swift
    Sources/HomeKit/
      Generated/                constants, catalog tables, value enumerations (do not edit)
      Core/                     catalog lookups, errors, values, validation, name rules
      Store/                    store protocol, records, in-memory store
      Accessory/                endpoint protocol, test accessory, default templates
      Model/                    HM… classes, delegates, events, setup types
    Tests/HomeKitTests/         one suite per spec area
