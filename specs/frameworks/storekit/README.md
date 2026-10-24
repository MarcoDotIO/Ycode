# StoreKit (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-20. Reference: Xcode 27.1
(27A9269) with the iOS 27.1 SDK and the iOS 27.1 simulator runtime
(24A94401), on an iPhone Duo simulator named `ycode-test-storekit-1`.

## Scope

StoreKit is how an app sells in-app products and subscriptions. In the
simulator there is no App Store and no account, so this spec covers the
part that works there: **StoreKit Testing**, the local test store driven by
a `.storekit` configuration file. It covers

- the simulator side: StoreKit 2 (`Product`, `Transaction`, purchases,
  subscriptions and their status, entitlements, refunds, offers and offer
  codes, `AppTransaction`, `AppStore.sync`) and StoreKit 1 as still used
  (`SKProductsRequest`, `SKPaymentQueue`, restore, the receipt), how Apple's
  simulator runs the local store (daemon, Mach services, system sheets,
  storage, signing), the control API `SKTestSession`, errors, and golden
  observations from our probe app;
- the IDE side: the `.storekit` file as a format, how a scheme attaches it,
  what Xcode does with it on Run, Xcode's editor and Transaction Manager
  (from documentation, GUI pass pending), and what `xcodebuild`/`simctl`
  expose.

Not covered: the real App Store and sandbox (they need an Apple account),
App Store Server API and notifications beyond the payload formats, StoreKit
views (`StoreView`, `SubscriptionStoreView`) beyond their dependence on the
same store, external purchase and advanced commerce APIs, ad attribution
(`SKAdNetwork`, `SKAdTestSession`).

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | What StoreKit does in Apple's simulator; processes, services, sheets, storage; **conformance checklist** |
| `testing-session.md` | `SKTestSession`, time rates, the local store's purchase, subscription, offer, Ask-to-Buy, refund, issue and simulated-error rules, with measured values |
| `formats.md` | Product JSON, JWS transactions, renewal info and app transaction payloads, signing identity, the StoreKit 1 receipt |
| `configuration-file.md` | The `.storekit` file format and what the daemon does with it |
| `ide.md` | Xcode's StoreKit tooling: scheme option (XML and Run behavior), editor, Transaction Manager, command-line tools, what Ycode's IDE must provide |
| `errors.md` | StoreKit 2, StoreKitTest and StoreKit 1 errors and value sets, with observed mappings |
| `design.md` | **Ycode-original design note**: guest dependencies, IDE installation route, open StoreKit sketch |
| `plan.md` | Implementation rounds (R1…R10), golden values, conformance tests |
| `api-inventory.md` | Generated appendix: every public Swift type of `StoreKit`/`StoreKitTest` with member names, and the Objective-C StoreKit 1 / StoreKitTest classes with selectors and properties |

Probe app (our own code): `research/experiments/storekit/StoreProbe/`
(`build.sh`, `run.sh`, `main.swift`, our configurations
`YcodeProbe.storekit` and `YcodeProbeSettings.storekit`); project generator
for Xcode/xcodebuild runs: `research/experiments/storekit/make_project.py`;
JWS verifier: `research/experiments/storekit/jws_check.py`; inventory
generator: `research/experiments/storekit/gen_api.py`.

## Key findings

1. Without a configuration StoreKit in the simulator returns empty product
   lists and `noAccount` for the app transaction; with one, everything in
   the local store works, signed with a per-device self-signed P-256
   certificate, so Ycode can serve verifiable transactions with its own key.
2. The store lives in the guest's `storekitd` (Mach services
   `com.apple.storekitd`, `com.apple.storekit.configuration.xpc`); system
   sheets come from `StoreKitUISceneService`. Configurations, overrides and
   transactions are per bundle id and persist until uninstall.
3. Xcode's Run installs the scheme's configuration into that same store on
   every Run, before the launch, through the guest's developer-tools service
   (`DTServiceHub`, trusted by the daemon to act for any bundle id), and
   deletes it when the scheme's path does not resolve
   (`LaunchAction/StoreKitConfigurationFileReference[identifier]`, a path
   relative to the project's embedded workspace); there is no `simctl`
   support. Ycode's IDE will instead inject a public-API `SKTestSession` at
   launch (`design.md` §3).
4. `deviceVerification` is SHA-384 of the lower-case nonce followed by the
   lower-case vendor identifier; locale fallback is the product's reference
   name; prices are never converted between storefronts.
5. Accelerated time rates of the 1000 series make every period (week,
   month, year, offer) the same few seconds; real time uses calendar
   periods in the device time zone (a DST change adds an hour).

## Evidence summary

Level 1: Apple's public StoreKit, StoreKit Testing and App Store Server
documentation, in our words. Level 2: file formats (configuration files,
the daemon's copies, the receipt CMS, JWS certificates, SQLite schema names,
launchd property lists, bundle layout). Level 3: StoreProbe on
`ycode-test-storekit-1` (iOS 27.1), and Xcode 27.1 driven through its
scripting interface on our generated project. Level 4: public SDK metadata
(headers, Swift interfaces) and Xcode plug-in registration data (names
only). Level 5 (disassembly/decompilation) was **not** used. Raw logs and
dumps are in `research/dirty/storekit/` (not committed).

## What the owner must provide

- Nothing for the simulator work: no Apple account, team or profile is
  involved.
- A **GUI observation pass** of Xcode's StoreKit editor, template assistant,
  scheme pop-up and Transaction Manager needs a session with screen control
  (this round had none); the standing permission covers it.
- Device runs (StoreKit Testing on a physical device) need the owner's team
  and a device; not attempted.
