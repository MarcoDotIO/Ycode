# HomeKit (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-19. Reference: the iOS 27.1
SDK in Xcode 27.1 (27A9269), the iOS 27.1 simulator runtime (24A94401) and
the iOS 27.0 runtime (24A434). Both runtimes ship HomeKit bundle version
1493.1.5.1.1 and behaved identically in every probe.

## Scope

The **HomeKit** API that an iPhone or iPad app links against: the home
manager, homes, rooms, zones, service groups, users, accessories, services,
characteristics, action sets, triggers and events, cameras, accessory
setup, and the Matter hooks; the identifiers and errors it exposes; what the
reference simulator does with it; and how an open implementation can reach
accessories over HAP and Matter.

Not covered: watchOS/tvOS differences beyond "read and control only" (noted
per member), the Home app (not in either simulator runtime), Siri/App
Intents integration, HomeKit Secure Video, Matter's own `MTR…` API beyond
the names HomeKit uses, and certification/MFi.

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | What a HomeKit app sees in Apple's iOS Simulator (27.1 vs 27.0), requirements on the app, the daemons/XPC services/system UI underneath, and the **conformance checklist** HK-B01–B16 |
| `object-model.md` | Every public class and its members, relationships, mutation calls, delegates, triggers/events, cameras, setup manager, threading |
| `type-identifiers.md` | Service and characteristic type UUIDs (184), accessory category strings (33), formats, units, properties, action-set types, significant events, characteristic value enumerations |
| `errors.md` | `HMErrorCode` catalog, the errors observed in the simulator (incl. the private 2040), proposed HAP status mapping |
| `accessory-protocols.md` | HAP over IP (discovery, transport, pairing, setup payload, categories), BLE outline, Matter; source licensing |
| `open-design.md` | **Ycode-original design note**: simulator dependencies (Track S), open HomeKit library + daemon (Track O), Ycode accessory simulator |
| `plan.md` | Rounds R1–R9, account-enabled checks HK-A01–A30, owner inputs, open-implementation tests |

Black-box observations: `research/notes/homekit-simulator-observations-2026-10-19.md`.
Probe app (our code): `research/experiments/homekit/HMProbe/`
(`build.sh OUTDIR`, `run.sh UDID BUNDLE NAME OUTDIR SECONDS -mode M`).
Raw logs and screenshots: git-ignored `research/dirty/homekit/`.

## Key findings

1. **HomeKit works in the simulator up to the home.** Permission prompt,
   authorization states and the daemon connection behave as on a device.
2. **No home without iCloud.** On a fresh simulator (no Apple Account),
   `addHomeWithName:` fails with private `HMErrorDomain` code 2040 before
   any name validation. Nothing below a home can be exercised. This is the
   reference baseline Ycode must match.
3. **No development team needed** for simulator builds: the HomeKit
   entitlement goes in the binary's `__entitlements` section with ad hoc
   signing. Putting it in the ad hoc signature makes the app unlaunchable.
4. Missing usage string aborts the app; missing entitlement still prompts
   but the daemon refuses the connection (no homes callback; later 47).
5. `simctl privacy grant all` does not cover HomeKit; the prompt must be
   answered (or Ycode offers its own pre-grant).
6. HomeKit Accessory Simulator is **not installed** on this Mac; no Home
   app exists in either runtime.
7. Ycode's lean boot disables `homed`; HomeKit needs it running
   (`open-design.md` S1). Since 2026-10-27 IDE runs boot every service
   by default (`specs/ide/run.md`), so `homed` runs unless Lean boot is
   turned on.

## Owner inputs

See `plan.md` §4: an Apple Account signed in by the owner on a test
simulator; HomeKit Accessory Simulator (Additional Tools for Xcode);
permission to pair with software accessories on an isolated network.

## Framework layout facts (level 4)

- Install name `/System/Library/Frameworks/HomeKit.framework/HomeKit`,
  bundle identifier `com.apple.HomeKit`, current version 1493.1.5. Swift
  overlay merged into the framework (the `.tbd` records a former
  `libswiftHomeKit`); Swift module in language mode 6. Swift-only API:
  `HMMediaSourceDisplayOrderProfile` and refined `matterNodeID`,
  `matterEndpointID`, `hapInstanceID` accessors.
- `_HomeKit_SwiftUI.framework` exports SwiftUI `CameraView` (iOS 14).
- The runtime bundle carries `DefaultCharacteristics.plist`, 57
  localizations and three app extensions (intent, diagnostic, customer
  diagnostic). Localized strings are Apple's; Ycode writes its own.
- Platform: iOS 8+, watchOS 2+, tvOS 10+, Mac Catalyst 14+, visionOS
  where listed; native macOS only for `HMAccessorySetupManager` and its
  request/result/payload types (macOS 27).

## Evidence summary

Level 1: Apple's public HomeKit documentation (summarized), Apple's
HomeKit ADK (Apache-2.0), connectedhomeip (Apache-2.0) repository facts, CSA
license notices. Level 2: launchd plists in both runtimes. Level 3:
`HMProbe` on `ycode-test-homekit-271` (iPhone Duo, 27.1) and
`ycode-test-homekit-270` (iPhone 18 Pro, 27.0), both deleted after use.
Level 4: SDK header/API-notes/Swift-interface metadata (names, values,
availability; nothing reproduced), bundle structure. Level 5
(disassembly/decompilation) was **not** used. The reference tools folder,
Ghidra and the IPSW were not opened; no account was signed in; no
accessory on the network was paired or controlled.
