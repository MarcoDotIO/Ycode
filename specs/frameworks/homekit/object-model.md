# HomeKit spec: object model and interface

Part of `specs/frameworks/homekit/`. The public HomeKit API as an app sees
it: classes, their members, relationships, mutation calls, delegates and
threading. Type and member names are interop facts (level 4, from the iOS
27.1 SDK metadata; no declarations are reproduced). Descriptions are in our
own words from public documentation (level 1) and from our probe (level 3,
marked). Identifier values are in `type-identifiers.md`; errors in
`errors.md`.

Availability notation: "iOS 9" means introduced in iOS 9.0. Unless stated,
everything is available on iOS, iPadOS, Mac Catalyst (14.0+), watchOS and
tvOS and **unavailable on macOS** (native AppKit); on watchOS and tvOS the
mutation calls (add/remove/update/assign) are unavailable, so those
platforms are read-and-control only. visionOS follows iOS where it is
listed. `HMAccessorySetupManager` and its request/result/payload types are
the exception: they are also available on native macOS from macOS 27.

## 1. Shape of the model

    HMHomeManager ──homes──► HMHome ─┬─ rooms ─────► HMRoom ── accessories
                                     ├─ roomForEntireHome (default room)
                                     ├─ zones ─────► HMZone ── rooms
                                     ├─ serviceGroups ► HMServiceGroup ── services
                                     ├─ accessories ─► HMAccessory ─┬─ services ─► HMService ── characteristics ─► HMCharacteristic ── metadata
                                     │                              ├─ profiles (camera, network configuration, …)
                                     │                              └─ bridgedAccessories / room / category
                                     ├─ actionSets ─► HMActionSet ── actions (HMCharacteristicWriteAction)
                                     ├─ triggers ───► HMTimerTrigger | HMEventTrigger ── actionSets, events
                                     └─ currentUser / access control

All model objects are **owned by the framework**: apps never create homes,
rooms, zones, groups, accessories, services, characteristics, users or
action sets directly (their `init` is unavailable or deprecated). Apps
create only value-like objects: events, triggers, write actions, number
ranges, setup requests and payloads. Each persistent object has a
`uniqueIdentifier` (UUID, iOS 9) that stays stable across launches and
across `HMHomeManager` instances. Whether two managers in one process share
object instances is not yet observed (`plan.md` HK-A05); apps must compare
by `uniqueIdentifier`.

Every object is `Sendable` in Swift. Mutations are asynchronous with a
completion handler taking an optional error (Swift: `async throws`
variants, several renamed, e.g. `addHome(named:)`, `addRoom(named:)`).

## 2. `HMHomeManager`

| Member | Behavior |
|---|---|
| `init` | Starts loading the home data from the daemon. The first creation in an app triggers the permission prompt (level 3). |
| `delegate` | Weak. |
| `authorizationStatus` (iOS 13) | Option set: Determined (1), Restricted (2), Authorized (4). Observed values: 0 before an answer, 1 denied, 5 allowed (level 3). |
| `homes` | Array of homes; empty until the first `homeManagerDidUpdateHomes:`. |
| `primaryHome`, `updatePrimaryHome:` | Deprecated (iOS 16.1); no longer supported. |
| `addHomeWithName:` | Creates a home; completion gets the new home or an error. Without iCloud: error 2040 (see `simulator-baseline.md` §5). |
| `removeHome:` | Deletes a home. |
| Vendor category: `findVendorAccessoryWithHAPPublicKey:` (iOS 26.1) | Looks up an accessory owned by the calling vendor from its HAP long-term public key; completion may return nil without error. |

Delegate `HMHomeManagerDelegate` (all optional):
`homeManager:didUpdateAuthorizationStatus:` (iOS 13),
`homeManagerDidUpdateHomes:` (initial load and bulk changes),
`homeManagerDidUpdatePrimaryHome:`, `homeManager:didAddHome:`,
`homeManager:didRemoveHome:`; `homeManager:didReceiveAddAccessoryRequest:`
is unavailable everywhere (a removed iOS 13–15 feature).

## 3. `HMHome`

Properties: `name`, `isPrimary`, `uniqueIdentifier`, `homeHubState`
(iOS 11: NotAvailable 0, Connected 1, Disconnected 2), `delegate`.
`updateName:`.

| Category | Members |
|---|---|
| Accessories | `accessories`; `addAccessory:` (adds an accessory found by `HMAccessoryBrowser`), `removeAccessory:`, `assignAccessory:toRoom:`, `servicesWithTypes:` (all services of the given type strings across the home), `unblockAccessory:`, `addAndSetupAccessoriesWithCompletionHandler:` (deprecated in favor of the setup manager), `addAndSetupAccessoriesWithPayload:` (with a setup payload, returns accessories), `supportsAddingNetworkRouter` (iOS 13.2) |
| Users | `currentUser` (iOS 9), `manageUsersWithCompletionHandler:` (presents system UI), `homeAccessControlForUser:` (gives `HMHomeAccessControl` with `isAdministrator`); `users`, `addUser…`, `removeUser:` are deprecated since iOS 9 |
| Rooms | `rooms` (does not include the default room), `addRoomWithName:`, `removeRoom:`, `roomForEntireHome` (the default room that holds unassigned accessories) |
| Zones | `zones`, `addZoneWithName:`, `removeZone:` |
| Service groups | `serviceGroups`, `addServiceGroupWithName:`, `removeServiceGroup:` |
| Action sets | `actionSets`, `addActionSetWithName:`, `removeActionSet:`, `executeActionSet:` (also on watchOS/tvOS), `builtinActionSetOfType:` (iOS 9; the four built-in scenes wake up, sleep, departure, arrival) |
| Triggers | `triggers`, `addTrigger:`, `removeTrigger:` |
| Matter (iOS 16.1+) | `matterControllerID` (string), `matterControllerXPCConnectBlock` and (iOS 18.2) `matterStartupParametersXPCConnectBlock`: blocks that return an XPC connection for use with Matter.framework's controller, letting an app drive the home's Matter fabric |

`HMHomeDelegate` (all optional) reports changes per object kind:
name and access-control updates; accessory add/remove/room change/unblock/
error; user add/remove; room add/remove/rename; zone add/remove/rename and
room membership; service-group add/remove/rename and membership; action-set
add/remove/rename/actions changed; trigger add/remove/rename/update; home
hub state (iOS 11); supported features (iOS 13.2).

Public documentation describes delegate callbacks as notifications of
changes made **elsewhere** (other apps, other devices, the daemon); the
app's own mutations are reported through their completion handlers (level 1;
level 3 blocked by the account requirement, see `plan.md` HK-A06).

`HMUserFailedAccessoriesKey` is a userInfo key for per-accessory failures
in user management; deprecated in iOS 27.0.

## 4. Rooms, zones, service groups, users

- `HMRoom`: `name`, `accessories`, `uniqueIdentifier`, `updateName:`.
- `HMZone`: `name`, `rooms`, `uniqueIdentifier`, `updateName:`,
  `addRoom:`, `removeRoom:`. A room may be in several zones; the default
  room cannot be placed in a zone (error 24).
- `HMServiceGroup`: `name`, `services`, `uniqueIdentifier`, `updateName:`,
  `addService:`, `removeService:`.
- `HMUser`: `name`, `uniqueIdentifier`. `HMAccessControl` (iOS 11.2) is
  the abstract base of `HMHomeAccessControl`.

## 5. Accessories

`HMAccessory` properties: `name`, `uniqueIdentifier`, `home` (weak, iOS 10),
`room` (weak), `category` (`HMAccessoryCategory`: `categoryType` string and
`localizedDescription`), `services`, `profiles` (iOS 11), `isReachable`,
`isBridged`, `uniqueIdentifiersForBridgedAccessories` (on the bridge; iOS 9),
`bridgedAccessories` (iOS 13), `isBlocked`, `model`, `manufacturer`,
`firmwareVersion` (iOS 11, replacing the deprecated characteristic types of
the same names), `supportsIdentify` (iOS 11.3), `matterNodeID` (iOS 16.1;
refined for Swift as an optional unsigned 64-bit integer), `delegate`.
Vendor additions (iOS 26.1): `isVendorAccessory` and `HAPInstanceID`
(Swift: `hapInstanceID`). Camera category: `cameraProfiles`. Calls:
`updateName:`, `identifyWithCompletionHandler:` (asks the accessory to
identify itself, e.g. blink). `identifier` and
`identifiersForBridgedAccessories` are deprecated since iOS 9.

`HMAccessoryDelegate` (optional): name updated; service name updated;
associated service type updated; services updated; profile added/removed
(iOS 11); reachability updated; **characteristic value updated** (the
notification channel, see §7); firmware version updated (iOS 11).

`HMAccessoryProfile` (iOS 10): `uniqueIdentifier`, `services`, `accessory`.
Subclasses: `HMCameraProfile` (§10), `HMNetworkConfigurationProfile`
(iOS 13: `isNetworkAccessRestricted`, delegate with
`profileDidUpdateNetworkAccessMode:`), and Swift-only
`HMMediaSourceDisplayOrderProfile` (iOS 18 / visionOS 2: an `order` list of
integers, `writeOrder`, delegate).

`HMAccessoryBrowser` (iOS 8; iOS only): `discoveredAccessories`,
`startSearchingForNewAccessories`, `stopSearchingForNewAccessories`,
delegate with "found new" and "removed new" callbacks. It reports
**unpaired** accessories near the device; adding one goes through
`-[HMHome addAccessory:]`, which shows the system pairing UI.

## 6. Services

`HMService`: `accessory` (weak), `serviceType` (UUID string, see
`type-identifiers.md`), `localizedDescription` (iOS 9), `name`,
`associatedServiceType` (user's declared purpose of a generic service, e.g.
an outlet that powers a fan), `characteristics`, `uniqueIdentifier`,
`isUserInteractive` (iOS 9; false for services the UI hides),
`isPrimaryService` (iOS 10), `linkedServices` (iOS 10),
`matterEndpointID` (iOS 18; Swift-refined). Calls: `updateName:`,
`updateAssociatedServiceType:` (error 62 for an invalid type).

## 7. Characteristics

`HMCharacteristic`: `characteristicType` (UUID string),
`localizedDescription`, `service` (weak), `properties` (array of the
property strings: Readable, Writable, SupportsEventNotification, Hidden,
and RequiresAuthorizationData (iOS 18)), `metadata`, `value` (cached last
known value; nil until read or notified), `isNotificationEnabled`,
`uniqueIdentifier`.

| Call | Behavior |
|---|---|
| `readValueWithCompletionHandler:` | Reads from the accessory; on success `value` is updated before the completion runs. Write-only characteristic: error 6. |
| `writeValue:completionHandler:` | Validates against metadata (type, min/max, step, max length, valid values) then writes. Read-only: error 5; wrong type 43; below min 44; above max 45; string too long 46. |
| `enableNotification:completionHandler:` | Subscribes this app to value changes; changes then arrive via `accessory:service:didUpdateValueForCharacteristic:` on the accessory's delegate. Not supported: error 7. |
| `updateAuthorizationData:` | Attaches opaque authorization data sent with writes (characteristics with the RequiresAuthorizationData property). |

`HMCharacteristicMetadata`: `minimumValue`, `maximumValue`, `stepValue`,
`maxLength`, `format` (format string), `units` (unit string),
`manufacturerDescription`, `validValues` (iOS 10). Format and unit strings
are listed in `type-identifiers.md` §4; they mirror HAP's JSON format and
unit names (`accessory-protocols.md` §2.4).

Value representation in the API: Bool formats as `NSNumber` booleans,
integer and float formats as `NSNumber`, strings as `NSString`, TLV8 and
data as `NSData`, and enumerations as `NSNumber` whose values are listed
(per characteristic) as `HMCharacteristicValue…` enums in
`type-identifiers.md` §5.

## 8. Action sets and actions

- `HMAction` (abstract): `uniqueIdentifier`.
- `HMCharacteristicWriteAction` (generic over the target value type):
  created with a characteristic and a target value; `characteristic`,
  `targetValue`, `updateTargetValue:`. An action object belongs to one
  action set; reusing it elsewhere is error 30 (`ActionInAnotherActionSet`).
- `HMActionSet`: `name`, `actions` (a set), `isExecuting`, `actionSetType`
  (user-defined, the four built-ins, or trigger-owned (iOS 10)),
  `uniqueIdentifier`, `lastExecutionDate` (iOS 10), `updateName:`,
  `addAction:`, `removeAction:`. Executing an empty set fails (error 25);
  built-in sets cannot be removed (error 83).

## 9. Triggers and events

- `HMTrigger` (base): `name`, `isEnabled`, `actionSets`,
  `uniqueIdentifier`, `updateName:`, `addActionSet:`, `removeActionSet:`,
  `enable:`. `lastFireDate` deprecated (iOS 17).
- `HMTimerTrigger`: created with a name, fire date and optional recurrence
  (`NSDateComponents`; the time-zone/calendar variant is deprecated since
  iOS 16.4); `fireDate`, `recurrence`, `updateFireDate:`,
  `updateRecurrence:`. Fire dates in the past fail (28); dates and
  recurrences must fall on documented boundaries (errors 42, 69–72).
- `HMEventTrigger`: created with a name, `events`, optional `endEvents`,
  optional `recurrences` (days of week as date components) and an optional
  `NSPredicate` condition; `events`, `endEvents`, `predicate`,
  `recurrences`, `executeOnce`, `triggerActivationState` (Disabled 0,
  DisabledNoHomeHub 1, DisabledNoCompatibleHomeHub 2,
  DisabledNoLocationServicesAuthorization 3, Enabled 4), and an `update…`
  call for each. Event triggers run on a **home hub** (Apple TV / HomePod),
  so without one they stay disabled.
- Predicate builders (class methods): before/after/between significant
  events, before/on/after/between date components, characteristic value
  comparison (operator and value), presence. Key paths used in custom
  predicates: `HMCharacteristicKeyPath`, `HMCharacteristicValueKeyPath`,
  `HMPresenceKeyPath`.
- Events (all `NSCopying`/`NSMutableCopying` with `HMMutable…`
  counterparts since iOS 11): `HMCharacteristicEvent` (characteristic +
  optional trigger value), `HMCharacteristicThresholdRangeEvent`
  (characteristic + `HMNumberRange`), `HMLocationEvent` (`CLRegion`),
  `HMPresenceEvent` (type: every entry 1, every exit 2, first entry 3 =
  at home, last exit 4 = not at home; user type: current user 1, home
  users 2, custom users 3), time events `HMCalendarEvent` (fire date
  components), `HMSignificantTimeEvent` (sunrise/sunset + offset),
  `HMDurationEvent` (end-event duration). `+isSupportedForHome:` reports
  whether the home's hub can run the event kind. Observed copy and
  identity behavior: `simulator-baseline.md` §7.
- `HMNumberRange` (iOS 11): min-only, max-only or both.

## 10. Cameras

`HMCameraProfile` (iOS 10) groups controls: `streamControl`
(`HMCameraStreamControl`: `streamState` Starting 1 / Streaming 2 /
Stopping 3 / NotStreaming 4, `cameraStream`, `startStream`, `stopStream`,
delegate start/stop callbacks), `snapshotControl` (`takeSnapshot`,
`mostRecentSnapshot` with `captureDate`, delegate callbacks),
`settingsControl` (characteristics for night vision, pan/tilt, zoom,
rotation, mirroring), `speakerControl` and `microphoneControl`
(`HMCameraAudioControl` with `mute` and `volume` characteristics).
`HMCameraSource` (abstract, `aspectRatio`) has subclasses `HMCameraStream`
(`audioStreamSetting`: Muted 1, IncomingAudioAllowed 2,
BidirectionalAudioAllowed 3; set and update calls) and `HMCameraSnapshot`.
`HMCameraView` is a `UIView` showing a camera source; `_HomeKit_SwiftUI`
exports a SwiftUI `CameraView` (iOS 14).

## 11. Accessory setup (iOS 15+)

- `HMAccessorySetupManager` (iOS 15; macOS 27): class property
  `isSupported` (iOS 27), `performAccessorySetupUsingRequest:` (iOS 15.4)
  which presents the system setup UI and completes with an
  `HMAccessorySetupResult` (`homeUniqueIdentifier`,
  `accessoryUniqueIdentifiers`) or an error (23 if dismissed).
- `HMAccessorySetupRequest` (copyable): optional `payload`,
  `homeUniqueIdentifier`, `suggestedRoomUniqueIdentifier`,
  `suggestedAccessoryName`, `matterPayload` (Matter.framework's
  `MTRSetupPayload`).
- `HMAccessorySetupPayload`: from a HomeKit setup URL (`X-HM://…`,
  `accessory-protocols.md` §2.6), optionally with an
  `HMAccessoryOwnershipToken` (opaque data from the vendor's cloud).
- `HMAddAccessoryRequest`: iOS 13–15 only; unavailable now.

## 12. Threading and delivery

Completion handlers and delegate callbacks were delivered on the main
queue in every observed case (level 3: manager and auth callbacks, `addHome`
and setup completions). Public documentation says the same for delegate
callbacks. An open implementation should deliver on the main queue by
default.

## Evidence

Level 4: all type and member names, enum values, availability (iOS 27.1
SDK headers, API notes, Swift interfaces and `.tbd`; nothing reproduced).
Level 1: behavioral descriptions in §§2–11 not marked otherwise (Apple's
public HomeKit documentation, summarized). Level 3: authorization values,
error 2040, main-queue delivery, object identity across managers, setup
completion (`simulator-baseline.md`). The statements about delegate
callbacks for own changes, write validation order, home-hub dependency of
event triggers, and the error codes named in §§4–9 are level 1 and still
need level 3 confirmation (`plan.md` §3). No level 5.
