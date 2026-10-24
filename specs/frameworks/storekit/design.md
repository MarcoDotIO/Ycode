# StoreKit spec: what Ycode must provide (Ycode-original design note)

Part of `specs/frameworks/storekit/`. This note is Ycode's own design. It
says what Ycode's simulator and IDE need so that StoreKit apps behave as in
Apple's simulator, and sketches an open StoreKit. The behavior it must
match is in the other files of this directory.

## 1. Two targets

1. **Baseline**: a Ycode guest runs Apple's iOS runtime, so Apple's
   `storekitd`, its test-store engine and `StoreKitUISceneService` do the
   work. Ycode must provide the platform services they rely on, plus the
   IDE-side installation of configurations.
2. **Open StoreKit**: a drop-in StoreKit (and StoreKitTest) for the guest and
   a Linux Swift package with the same names and semantics, backed by
   Ycode's own local store. It replaces Apple's only where the owner opts in.

Both serve the same local test store semantics: there is no App Store
behind either.

## 2. Baseline: guest dependencies

| # | Dependency | Why (where observed) |
|---|---|---|
| G1 | launchd job `com.apple.storekitd` with its three Mach services, on demand, user `mobile` | client API, configuration service, push name (`simulator-baseline.md` §3) |
| G2 | launch angel `com.apple.StoreKitUISceneService` (RunningBoard-managed, hidden app) and the scene-hosting path in SpringBoard/FrontBoard | purchase sheet, alerts, refund, redeem, manage sheets (§6 there) |
| G3 | LaunchServices app-group container `group.com.apple.storekit`, persistent and writable | configurations, signing identity, store database (§5 there) |
| G4 | app data containers with a writable `StoreKit/` directory | StoreKit 1 receipt |
| G5 | LaunchServices registration events (`applicationRegistered`/`Unregistered` distributed notifications) delivered to launchd | the daemon launches on install and deletes an app's test data on uninstall |
| G6 | bundle-id identification of XPC peers (code signature / audit token → bundle id) | the configuration service validates "for X by X" |
| G7 | `trustd`, `securityd` and Security framework ECDSA/X.509 | signing and verifying JWS; the per-device certificate is created on first use |
| G8 | CryptoKit/CommonCrypto randomness | nonces, keys |
| G9 | a wall clock and timers that keep running while the app is in the background or not running | renewals happen at expiry and are delivered at the next launch |
| G10 | network failures must fail fast (no account, no App Store) | the daemon tries account and push services; long hangs delay StoreKit calls |
| G11 | RunningBoard and UIKit remote scenes for the sheets | G2 |
| G12 | `XCTest` frameworks in the runtime's `/Developer/Library/Frameworks` and loadable from an app | `StoreKitTest` asks XCTest for the app under test |

Nothing StoreKit-specific is needed on the host: the store lives entirely in
the guest. The host-side `com.apple.storekitservice.sim2host` endpoint was
unused in our runs; Ycode registers no such service until a probe shows a
use.

## 3. Baseline: IDE side

| # | Need |
|---|---|
| I1 | On Run with a scheme StoreKit configuration, install it for the app's bundle id **before** the app launches. Xcode does this through Apple's developer-tools service in the guest, which the daemon treats as entitled to save configurations for any bundle id (`ide.md` §2.2); that path uses a private request protocol and a privileged identity, so Ycode does not copy it. Ycode's route: **inject an `SKTestSession` creation at app launch** — a launch-time library (loaded with `DYLD_INSERT_LIBRARIES` through the launch environment) that creates a session from a configuration file path passed in the environment and waits until a product request for one configured id answers, then returns control to the app. It uses only the public `StoreKitTest` API and the app's own identity, and it also survives the first-session race (`testing-session.md` §2). With the open StoreKit, Ycode's engine accepts the configuration from the IDE directly. |
| I2 | Keep the installation after the run; reinstall when the file changed |
| I3 | Transaction Manager: drive the store through the same injected component (a control socket in the app process while it runs) or, when the app is not running, through a short-lived helper launch of the app's injected library in a "control only" mode |
| I4 | The configuration editor, template, scheme option and menu items of `ide.md` §6 |

## 4. Open StoreKit: architecture sketch

1. **Catalog**: parser and writer for `.storekit` (`configuration-file.md`),
   tolerant of unknown keys, with the product JSON synthesis of
   `formats.md` §1.
2. **Store engine** (`ycode-storekitd` in the guest, a library on Linux):
   per-app state = configuration copy, overrides, transaction table (the
   fields of `simulator-baseline.md` §5 are a sufficient model: id, product,
   type, state, finished, dates, original id, renewal chain, offer, Ask-to-Buy
   status, revocation, purchase issue, billing retry and grace end dates,
   upgraded flag, quantity, app account token), id counter per app, and a
   subscription scheduler implementing `testing-session.md` §3 (calendar
   periods in the device time zone at real time, fixed periods for the
   1000-series rates, proportional scaling for the 10-series rates).
3. **Signing**: one P-256 key and self-signed certificate per device
   ("StoreKit Testing in Xcode" subject, one-year validity) for JWS; a
   separate fixed Ycode certificate for StoreKit 1 receipts, exported by the
   IDE. Payload builders per `formats.md` §2–§3.
4. **Client framework**: `Product`, `Transaction`, `AppTransaction`,
   `AppStore`, `Storefront`, `VerificationResult` (with real verification
   of the JWS against the leaf key, and the simulated-error hooks), the
   StoreKit 1 classes on top of the same engine.
5. **StoreKitTest**: `SKTestSession` and friends as a thin client of the
   engine's control interface (all operations of `testing-session.md` §2).
6. **UI**: Ycode's own sheets for purchase confirmation, error alerts,
   refund, redeem and manage subscriptions, each showing
   "[Environment: Xcode]" (wording of our own; no Apple assets).
7. **Persistence**: SQLite in the guest's equivalent of the group
   container; uninstall deletes the app's state.

## 5. Choices and open design questions

1. Whether to keep Apple's daemon for the baseline indefinitely (yes for
   parity rounds; the open engine is opt-in).
2. Byte-level parity of JWS payloads: key order is not significant to
   decoders; Ycode writes keys sorted, like the reference.
3. Time rates: implement every raw value of `testing-session.md` §2.1,
   including the deprecated ones mapped to their documented replacements.
4. Promotional-offer signatures: verify with the configuration's key pair
   (`_subscriptionOffersKeyPair`), reject others with the observed alert.

## Evidence

Ycode-original design; requirements trace to the level-2/3 observations
cited in the other files of this directory.
