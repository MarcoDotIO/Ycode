# HomeKit in Apple's iOS Simulator: observations (2026-10-19)

Dirty-room notes by KIT-HOMEKIT. Prose only, no Apple code. Raw probe
output, unified-log extracts and screenshots are in the git-ignored
`research/dirty/homekit/{271,270}/`. The probe app is our own:
`research/experiments/homekit/HMProbe/` (`main.m`, `build.sh`, `run.sh`).

## Setup

- Mac: Xcode 27.1 (27A9269), iOS 27.1 SDK. The host was heavily loaded
  (load average about 180), so absolute timings are upper bounds.
- Runtimes: iOS 27.1 (24A94401) on device type iPhone Duo
  (`ycode-test-homekit-271`), iOS 27.0 (24A434) on iPhone 18 Pro
  (`ycode-test-homekit-270`; iPhone Duo is refused by 27.0 with
  CoreSimulator error 403 "Incompatible device"). One booted at a time;
  both deleted at the end.
- No Apple Account / iCloud is signed in on either device. We did not sign
  in (task rule).
- HomeKit Accessory Simulator is **not installed**: `/Applications` holds
  only `Xcode.app`, Spotlight finds no bundle with that name or bundle
  identifier, and Xcode's `Contents/Applications` does not contain it.
  Nothing was downloaded.

## Build and signing (what Xcode does for "Sign to Run Locally")

- Three variants from one source: `HMProbe` (entitlement
  `com.apple.developer.homekit` = true and `NSHomeKitUsageDescription`),
  `HMProbeNoEnt` (usage string only), `HMProbeNoUsage` (entitlement only).
- The entitlement is placed in the binary's `__TEXT,__entitlements`
  section by the linker and the bundle is signed ad hoc **without**
  entitlements. A fourth variant whose ad hoc *signature* carried the
  HomeKit entitlement could be installed but not launched:
  `simctl launch` failed with POSIX error 3 ("did not return a process
  handle"). Simulator processes run on the host kernel, which refuses a
  restricted entitlement in an ad hoc signature. No development team, no
  provisioning profile and no Apple Account were needed for the simulator.

## Inventory (both runtimes identical)

- `HomeKit.framework` version 1493.1.5.1.1 in both (only
  `DTPlatformVersion`/`MinimumOSVersion` differ). Bundle contains
  `DefaultCharacteristics.plist`, 57 `.lproj` folders and three app
  extensions: `HomeKitIntentExtension`, `HomeKitDiagnosticExtension`,
  `HomeKitCustomerDiagnosticExtension`. The executable lives in the shared
  cache.
- Also present: `Matter.framework`, `MatterSupport.framework`,
  `_HomeKit_SwiftUI.framework`; about 40 private Home* frameworks plus
  `CoreHAP`, `HomeKitMatter`, `MatterPlugin`.
- Launch daemons: `com.apple.homed`
  (`HomeKitDaemon.framework/Support/homed`, user mobile, KeepAlive on a
  path state, many Mach services) and `com.apple.homeeventsd`
  (`HomeKitEvents.framework/Support/homeeventsd`, Mach service
  `com.apple.homekitevents.xpc`, on demand). `homed` was running right
  after boot on both runtimes; `homeeventsd` was started later on 27.0.
- UI apps: `HomeUIService`, `HomeControlService`,
  `HomeCaptiveViewService`, `AccessorySetupUI` (all with executables).
  **No Home app** in either runtime (no `Home.app` directory at all).
- `launchctl list` in the guest also showed `cloudd`, `apsd`, `rapportd`
  running; `homed` logs show it registers for an APS push token and checks
  the CloudKit account at start.
- Device data: `data/Library/homed/` holds SQLite stores (`core`,
  `core-local`, `core-cloudkit`, `core-cloudkit-shared`, `datastore3`,
  `eventstore-beta`, `homeeventsd/homeevents`), `vendor-id-store`,
  `BLECache`, `plain-metadata.config`, `HH1ToHH2PerDeviceMigration`,
  `metricsCounters/`. Names only; contents not examined.

## Authorization

- The prompt appears when the app first creates an `HMHomeManager`
  (first access), on both runtimes. It is a system alert over the app (the
  app's scene resigns active). Title names the app's display name and
  "Home data"; body is the app's usage string; two buttons, deny on the
  left, allow on the right. The TCC service is `kTCCServiceWillow`
  (tccd log). The check is made by the **client process** to tccd; it
  does not go through homed.
- Before an answer: `authorizationStatus` = 0, no callbacks.
- Allow: `homeManager:didUpdateAuthorizationStatus:` with 5
  (determined|authorized) on the main thread, then
  `homeManagerDidUpdateHomes:` about 0.05–0.4 s later.
- Don't Allow (27.0): callback with 1 (determined only); no
  `homeManagerDidUpdateHomes:`. On the next launch the status is 1
  immediately after `init` and still no homes callback (12 s wait).
  `addHomeWithName:` then fails with HMErrorDomain 47 ("Access to home
  data is not authorized.") in about 25 ms.
- `simctl privacy reset all <bundle>` makes the prompt come back.
  `simctl privacy grant all <bundle>` does **not** cover HomeKit: the
  prompt still appears and the status stays 0. There is no simctl service
  name for HomeKit.
- Missing usage string: the process is killed with SIGABRT during
  `HMHomeManager` creation (tccd: "Refusing authorization request for
  service kTCCServiceWillow" because the usage description is null). No
  alert. Both runtimes.
- Missing entitlement: the prompt **still appears** and Allow gives
  status 5 (27.1 run), but homed drops every XPC connection from the app
  (client log: connection interrupted, NSCocoaErrorDomain 4097 for Mach
  service `com.apple.homed.xpc`); `homeManagerDidUpdateHomes:` never
  arrives. On a later launch the status reads 0 and `addHomeWithName:`
  fails with 47.

## Object model without an account

- Authorized manager on a fresh device: 0 homes. Two managers in one
  process each get their own `homeManagerDidUpdateHomes:` (on the main
  queue); creation costs about 10–50 ms for the first, under 1 ms for the
  second.
- `addHomeWithName:` fails in 5–30 ms with HMErrorDomain **2040**, empty
  failure reason, `localizedDescription` "Unknown Error Code: 2040."
  (2040 is not in the public `HMErrorCode` enum). homed's log: no iCloud
  account, creating a home is not allowed. The account check comes first:
  duplicate, case-folded duplicate, empty and punctuation-only names all
  give 2040. Same on 27.0 and 27.1.
- Consequently every home-scoped call (rooms, zones, service groups,
  action sets, triggers, users, accessories) could not be exercised. Our
  probe stops there ("gate-home"). Messages to a nil home never call their
  completion handlers (Objective-C nil messaging; not a HomeKit behavior).
- `HMAccessoryBrowser`: 10 s search found 0 accessories and produced no
  delegate callbacks on both runtimes. (We logged counts only.)
- `HMAccessorySetupManager.isSupported` = YES on both. A
  `performAccessorySetupUsingRequest:` with no home (default request plus
  a suggested name) launches `com.apple.Home.HomeUIService` as a hosted
  scene from SpringBoard, shows nothing visible, and completes with
  HMErrorDomain 23 (operation cancelled), empty userInfo, on the main
  thread: about 3.7–4.0 s on a cold service launch, about 0.2 s warm.

## Objects that need no home (identical on 27.0 and 27.1)

- Event objects (`HMCalendarEvent`, `HMSignificantTimeEvent`,
  `HMPresenceEvent`, `HMDurationEvent`, `HMLocationEvent`): each has a
  fresh `uniqueIdentifier` per creation; the version nibble of all ten
  UUIDs seen was 5. `copy` returns a different object of the same class
  that is not `isEqual:` to the original and has a different identifier;
  `mutableCopy` returns the `HMMutable…` subclass. Two independently made
  sunset events are not equal. `+isSupportedForHome:nil` is NO for all but
  `HMLocationEvent` (YES).
- `HMNumberRange`: value equality; min > max is accepted silently.
- Trigger predicates print as comparisons between a `now()` function and
  date components or the significant-event keyword; an offset is shown on
  the `now()` side with its sign flipped. The presence predicate compares a
  `presence` key path with a presence-event description.
- Unadded `HMEventTrigger`: enabled NO, activation state 0 (disabled),
  `executeOnce` NO, events kept. Unadded `HMTimerTrigger`: enabled NO,
  time zone nil.
- `HMAccessorySetupPayload initWithURL:` returns an object for
  `X-HM://` followed by 13 characters, and nil for `X-HM://` alone (log:
  host is nil), for an `https` URL (log: payload length 11 below minimum
  13), for a Matter `MT:` code (host is nil) and for nil. Internal error
  for the rejections is HMErrorDomain 3 (logged, not returned).
- `HMAccessoryOwnershipToken initWithData:` accepted 3 arbitrary bytes.
- `HMAccessorySetupRequest`: all properties nil by default; a copy is
  `isEqual:` to the original.

## Constants

All 255 public string constants named in the SDK headers resolve at run
time (none missing), with identical values on 27.0 and 27.1. Service and
characteristic types are uppercase UUID strings on the HAP base
`-0000-1000-8000-0026BB765291`; no two constants share a value. Accessory
category types are unrelated random-looking UUIDs. Formats, units,
action-set types, key paths and significant events are short strings (the
property and action-set constants equal their own names). 17 characteristic
short IDs were cross-checked against Apple's HomeKitADK (Apache-2.0): all
match.

## What could not be observed (and why)

- Anything inside a home (needs an iCloud-signed-in simulator).
- Accessories, services, characteristics, reads/writes, notifications,
  camera (needs a home and an accessory; HomeKit Accessory Simulator not
  installed).
- Trigger firing, action-set execution, users/sharing, home hub state.
