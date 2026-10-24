# HomeKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/homekit/`. This is what a HomeKit app sees in the
reference simulator (Xcode 27.1, iOS 27.1 runtime 24A94401 on iPhone Duo,
and iOS 27.0 runtime 24A434 on iPhone 18 Pro, Apple-silicon Mac) **with no
Apple Account signed in**, which is the state of every freshly created
simulator. Ycode's simulator must behave the same way by default.

Every statement is level 3 (our own probe app,
`research/experiments/homekit/HMProbe`, observations in
`research/notes/homekit-simulator-observations-2026-10-19.md`) unless
marked. **27.0 and 27.1 behaved identically in every probe**; differences
below are only in device type and timing.

## 1. Summary

HomeKit links, loads and talks to a real home daemon in the simulator. The
permission prompt, the authorization states and the daemon connection all
work. But the daemon refuses to create a home when no iCloud account is
signed in, so an app on a fresh simulator sees an authorized manager with
**zero homes**, and every `addHome` fails with an undocumented error code.
Everything below a home (rooms, accessories, characteristics, scenes,
triggers) is unreachable in this state. Accessory discovery finds nothing,
and the system accessory-setup flow ends at once as "cancelled". There is
no Home app in either runtime.

## 2. Requirements on the app

| Requirement | Without it (observed) |
|---|---|
| Entitlement `com.apple.developer.homekit` = true | Prompt still shown; after Allow the status reads 5, but the daemon drops the app's connection, `homeManagerDidUpdateHomes:` never arrives, and later launches read status 0 and get error 47 from `addHome`. |
| `NSHomeKitUsageDescription` in Info.plist | Process aborts (SIGABRT) while creating the first `HMHomeManager`; no prompt. |
| Development team / provisioning | **Not needed in the simulator.** The entitlement must be in the binary's `__TEXT,__entitlements` section and the bundle signed ad hoc *without* signature entitlements (what Xcode's "Sign to Run Locally" does). An ad hoc signature that itself carries the HomeKit entitlement cannot be launched (POSIX error 3). |
| Apple Account (iCloud) signed in on the device | Homes cannot be created: error 2040 (§5). |

## 3. Authorization

| Step | Observation |
|---|---|
| First `HMHomeManager` creation | `authorizationStatus` = 0 (no bits). The system shows an alert over the app; the app's scene resigns active. |
| Alert | Title names the app's display name and the user's Home data; body is the app's usage string; two buttons, deny (left) and allow (right). Ycode writes its own wording. |
| Allow | `homeManager:didUpdateAuthorizationStatus:` with 5 (Determined + Authorized), main thread; then `homeManagerDidUpdateHomes:` about 0.05–0.4 s later; scene becomes active again. |
| Don't Allow | Callback with 1 (Determined only). No homes callback, ever. |
| Later launches after Allow | Status 5 right after `init`; first `homeManagerDidUpdateHomes:` 0.07–0.25 s after creation. |
| Later launches after Don't Allow | Status 1 right after `init`; no homes callback; `addHomeWithName:` fails with 47 (`HMErrorCodeHomeAccessNotAuthorized`) in about 25 ms. |
| `simctl privacy … reset all <bundle>` | Prompt appears again on the next creation. |
| `simctl privacy … grant all <bundle>` | Does **not** cover HomeKit: prompt still shown, status 0. simctl has no HomeKit service name. |
| Restricted bit (2) | Not observed. |

The prompt is driven by the TCC service `kTCCServiceWillow`, requested by
the **app process itself** before it talks to the daemon (level 3, tccd
log). The answer is stored per bundle identifier.

## 4. Home manager and callbacks

- `HMHomeManager` creation: 10–50 ms for the first in a process, under
  1 ms for more. Several managers in one process each get their own
  `homeManagerDidUpdateHomes:`.
- All callbacks observed arrive on the **main queue**, including
  completion handlers of `addHomeWithName:`.
- `homes` is empty before the first callback and after it (fresh device).
- `primaryHome` (deprecated) is nil.

## 5. Creating homes (no account)

`addHomeWithName:completionHandler:` completes in 5–30 ms with
`home == nil` and an error in `HMErrorDomain` with **code 2040**,
`userInfo` holding only a localized description that reads like "unknown
error code 2040" (the code is not in the public `HMErrorCode` enum). The
account check comes **before** name validation: a duplicate name, a
case-folded duplicate, an empty name and a punctuation-only name all give
2040. No delegate callbacks follow. Ycode must return exactly this domain
and code.

## 6. Discovery and setup

| API | Observation |
|---|---|
| `HMAccessoryBrowser` start, 10 s, stop | `discoveredAccessories` stays empty; no delegate callbacks. |
| `HMAccessorySetupManager.isSupported` | YES |
| `performAccessorySetupUsingRequest:` (no home) | Launches the system UI service `com.apple.Home.HomeUIService` as a hosted scene; nothing visible; completion with `HMErrorDomain` 23 (`OperationCancelled`), empty userInfo, main thread; about 4 s on a cold service start, about 0.2 s warm. |
| `addAndSetupAccessoriesWithCompletionHandler:` (deprecated) | Not reachable without a home. |

## 7. Objects that need no home

| Object | Observation |
|---|---|
| Event classes (calendar, significant time, presence, duration, location) | Each instance gets a fresh `uniqueIdentifier` (version nibble 5 in all samples). `copy` gives a new object of the same class, not `isEqual:` to the original, with a new identifier. `mutableCopy` gives the matching `HMMutable…` class. Two equal-content events are not equal. |
| `+[HMEvent isSupportedForHome:]` with nil | NO, except `HMLocationEvent`: YES. |
| `HMNumberRange` | Value equality; min greater than max accepted without exception. |
| Trigger predicates | Built without a home; descriptions compare a `now()` function with date components or with the `sunrise`/`sunset` keyword; offsets appear on the `now()` side with the sign flipped. |
| Unadded `HMEventTrigger` | `enabled` NO, `triggerActivationState` 0, `executeOnce` NO, `endEvents` kept. |
| Unadded `HMTimerTrigger` | `enabled` NO, `timeZone` nil. |
| `HMAccessorySetupPayload initWithURL:` | Object for `X-HM://` + 13 characters; nil for `X-HM://` alone, for an `https` URL, for a Matter `MT:` string, for nil. |
| `HMAccessoryOwnershipToken initWithData:` | Accepts arbitrary bytes. |
| `HMAccessorySetupRequest` | All properties nil by default; a copy is equal to the original. |
| Public string constants | All 255 resolve, values in `type-identifiers.md`, identical in 27.0 and 27.1. |

## 8. What the reference provides underneath (levels 2 and 4)

These are what Ycode's simulator must run or emulate so that the runtime's
own HomeKit stack behaves as above. Names come from the runtime's launchd
plists (level 2) and bundle structure (level 4); "observed" means level 3.

| Component | Facts | Needed for |
|---|---|---|
| `com.apple.homed` | Launch daemon, program `HomeKitDaemon.framework/Support/homed`, user `mobile`, KeepAlive while a relaunch-assertion file exists. Running right after boot (observed). Mach services include `com.apple.homed.xpc` (the client connection, observed), `com.apple.homekit.xpc`, `com.apple.homed.xpc.accessory-setup`, `com.apple.homekit.coredata.xpc`, `com.apple.matter.framework.xpc`, `com.apple.matter.native.xpc`, `com.apple.matter.support.xpc`, plus push, IDS-wake, Spotlight, NFC, paired-sync and app-intents endpoints. Launch events: Apple Account changes, Rapport (`com.apple.home.messaging`), proximity (`HomeAccessorySetupFE25`), notifyd and passd matches. | Everything |
| `com.apple.homeeventsd` | Launch daemon, `HomeKitEvents.framework/Support/homeeventsd`, Mach service `com.apple.homekitevents.xpc`, background upload tasks. Started on demand (observed). | Event history |
| `tccd` with service `kTCCServiceWillow` + SpringBoard alert | Prompt, stored answer (observed). | §3 |
| CloudKit (`cloudd`), Apple Account state | homed checks the CloudKit account at start and refuses home creation without one (observed). | §5 |
| `apsd` | homed receives a push token at start (observed). | Remote updates |
| `rapportd` | Launch-event source for homed; running (observed). | Multi-device |
| `HomeUIService` (`com.apple.Home.HomeUIService`) | System app hosted by SpringBoard for the setup flow (observed). Also present: `HomeControlService`, `HomeCaptiveViewService`, `AccessorySetupUI`. | §6 |
| `HomeKit.framework` app extensions | Intent, diagnostic and customer-diagnostic extensions. | Siri/diagnostics |
| Device data `Library/homed/` | SQLite stores and caches created by homed on first boot (observed, names only). | Persistence |
| Networking | mDNS browsing for `_hap._tcp` (level 1, `accessory-protocols.md`); Bluetooth LE for BLE accessories. Not exercised (no accessories). | Discovery |

The 27.1 runtime supports only the iPhone Duo device type; 27.0 refuses
iPhone Duo. Both ship the same HomeKit bundle version (1493.1.5.1.1), the
same launchd plists for both daemons, the same UI services, and **no Home
app** (no `Home.app` in either runtime).

## 9. Conformance checklist (probe and expected result)

Probe: `HMProbe` built by `build.sh`, launched with `run.sh UDID BUNDLE
NAME OUTDIR SECONDS -mode M`. "Fresh" means a newly created device with no
Apple Account. Ycode passes a check when its output matches the reference
line for line, ignoring times, addresses and UUID values.

| ID | Variant / mode | Precondition | Expected |
|---|---|---|---|
| HK-B01 | `HMProbe` `-mode auth` | fresh | status 0, alert shown, scene resigns active, no callback until answered |
| HK-B02 | same, tap Allow | B01 | callback status 5 on main, then homes callback with 0 homes |
| HK-B03 | same, tap Don't Allow | B01 (after reset) | callback status 1; no homes callback within 20 s |
| HK-B04 | `-mode model` | B03 | status 1 at init; no homes callback in 12 s; `addHome` error 47 |
| HK-B05 | `-mode model` | B02 | status 5 at init; homes callback ≤ 0.5 s; six `addHome` calls all error 2040, no home; probe ends "aborted" |
| HK-B06 | `HMProbeNoUsage` `-mode auth` | fresh | process aborts during manager creation; no alert |
| HK-B07 | `HMProbeNoEnt` `-mode auth`, Allow | fresh | alert shown; status 5 after Allow; never a homes callback |
| HK-B08 | `HMProbeNoEnt` `-mode model` | B07 | status 0; no homes callback in 12 s; `addHome` error 47 |
| HK-B09 | app signed ad hoc with the entitlement in the signature | — | launch fails (no process) |
| HK-B10 | `simctl privacy grant all`, then `-mode auth` | fresh | still status 0 and alert (grant-all does not include HomeKit) |
| HK-B11 | `-mode browse` | B02 | 0 accessories after 10 s, no callbacks; `isSupported` = 1 |
| HK-B12 | `-mode setup` | B02 | `HomeUIService` launched; completion error 23, empty userInfo, main thread |
| HK-B13 | `-mode objects` | any | 35 lines as in the reference file `objects.txt` (§7 values) |
| HK-B14 | `-mode consts` | any | 255 constants, 0 missing, values equal to `type-identifiers.md` |
| HK-B15 | guest `launchctl list` after boot | fresh | `com.apple.homed` running; `com.apple.homeeventsd` loaded |
| HK-B16 | runtime app list | — | no Home app among visible apps |

Checks that need the owner's account or tools are in `plan.md` §3.

## Evidence

Level 3: §§1–7, §8 rows marked observed, §9 (`HMProbe` on
`ycode-test-homekit-271` and `-270`, both deleted after use). Level 2:
launchd plists of both runtimes (§8). Level 4: bundle structure, framework
version, absence of HomeKit Accessory Simulator in `/Applications` (§8).
Level 1: mDNS service type (§8, see `accessory-protocols.md`). No level 5.
