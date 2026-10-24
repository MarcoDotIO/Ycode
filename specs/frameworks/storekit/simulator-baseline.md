# StoreKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/storekit/`. This is what a StoreKit app sees in the
reference simulator (Xcode 27.1; iOS 27.1 runtime 24A94401 on an iPhone Duo
named `ycode-test-storekit-1`; Apple-silicon Mac). Ycode's simulator must
behave the same way. Statements are level 3 (our probe app
`research/experiments/storekit/StoreProbe`) unless marked; process, service
and file names are level 2 (launchd property lists and bundle layout of the
runtime, files on the simulated device) or level 3 (the device's log).

## 1. Summary

In the simulator, StoreKit works **only against a local test store**
("StoreKit Testing in Xcode"): the App Store itself is unreachable without
an Apple account, and the simulator has none.

| Situation | Result |
|---|---|
| No configuration installed for the app | `AppStore.canMakePayments` true; `Storefront.current` nil at first, then `USA` (id 143441, USD) once an update arrives; `Product.products(for:)` returns an empty list (no error); `AppTransaction.shared` throws `StoreKitError.systemError(noAccount)`; all transaction lists empty |
| Configuration installed (by `SKTestSession` in the app or tests, or by Xcode's scheme option) | products, purchases, renewals, refunds, offers, Ask to Buy, failures and the system sheets all work, signed and verifiable, with environment `Xcode`; state persists across launches and reboots until the app is uninstalled |

The local store lives in the StoreKit daemon inside the simulated device;
nothing goes to the host or the network (the daemon still tries the network
for unrelated account and push services and logs failures).

## 2. What works without an account (with a configuration)

| Feature | Works | Notes |
|---|---|---|
| Product loading (StoreKit 2 and `SKProductsRequest`) | yes | unknown ids omitted (SK1 lists them as invalid) |
| Purchases of all four types, quantity, app account token | yes | §6 for the sheet; `testing-session.md` §4 |
| `Transaction.updates`, `all`, `currentEntitlements`, `unfinished`, `latest(for:)`, `finish()` | yes | |
| Auto-renewal with accelerated clock, status and renewal info | yes | `testing-session.md` §3 |
| Introductory offers, promotional offers (test option), offer codes | yes | signed promotional offers need the configuration's key |
| Upgrades, downgrades, crossgrades | yes | |
| Refunds: test API and the refund request sheet | yes | |
| Manage subscriptions sheet | opens and closes (§6) | |
| Offer-code redeem sheet | yes, lists the configured codes | |
| Ask to Buy | yes (test API approves/declines) | |
| Billing retry, grace period, interrupted purchases | yes | |
| Simulated errors per API | yes | `testing-session.md` §9 |
| `AppTransaction` | yes | `receiptType` Xcode |
| `AppStore.sync()` | yes, succeeds immediately | |
| StoreKit 1 payment queue, restore, receipt refresh, receipt file | yes | §7 |
| `SKTestSession.buyProduct` (off-device purchase) | unreliable | `testing-session.md` §2 |
| `requestReview(in:)` | not exercised (open question 4) | |
| Real App Store, sandbox account, server notifications | no | needs an account; out of scope |

## 3. Processes and services (level 2 + 3)

| Component | Where | Role |
|---|---|---|
| `storekitd` | launch daemon `com.apple.storekitd`, program `/System/Library/Frameworks/StoreKit.framework/Support/storekitd`, user `mobile`, launched on demand | the client-facing StoreKit service and, in the simulator, the **local test store** ("Xcode Test Service", logged at start). Mach services: `com.apple.storekitd` (StoreKit client API), `com.apple.storekit.configuration.xpc` (test configuration and test-session control), `com.apple.aps.storekitservice` (push). Launch events on app registration and unregistration and an account-changed notification |
| test-store engine | `ASOctaneSupport.framework` (private, with an XPC service `ASOctaneSupportXPCService.xpc` and a signing-identity resource file) | the "Octane" engine the daemon uses for configurations, transactions and signing |
| `StoreKitUISceneService` | `/Applications/StoreKitUISceneService.app`, launch angel `com.apple.StoreKitUISceneService` managed by RunningBoard, Mach service `com.apple.StoreKitUISceneService` | presents the purchase confirmation, error alerts, refund, manage-subscriptions and redeem sheets as a scene over the app |
| `appstored`, `itunesstored`, `accountsd` | other launch daemons | contacted by `storekitd` for accounts; not needed for the local store |
| developer-tools service | launchd job `com.apple.instruments.deviceservice` (program `DVTInstrumentsFoundation.framework/DTServiceHub`), started in the guest on demand by Xcode | Xcode's channel for installing and deleting a scheme's configuration (`ide.md` §2.2); the daemon trusts its identity (`com.apple.dt.instruments.DVTInstrumentsFoundation`) to act for any bundle id |
| app side | `StoreKit.framework` in the app process, plus `StoreKitTest.framework` when the app or test creates a session | talks to `com.apple.storekitd` and, for the test API, to `com.apple.storekit.configuration.xpc` |

Requests on the configuration service (names from the daemon's log, level 3):
save configuration, delete configuration, fetch transactions, purchase, storefront, fetch and set integer and string values
(the session properties), set simulated error, perform transaction action
(refund, delete, resolve issue…), delete all transactions, expire
subscription, force renewal, change auto-renew status, complete Ask to Buy.
Each is validated against the caller's bundle identifier ("… for
dev.ycode.skprobe by dev.ycode.skprobe"): an app can only control its own
test store. An older path in which Xcode itself hosted the test server over
a port fetched from the daemon is disabled ("no longer supported" in the
log).

The host also registers a `com.apple.storekitservice.sim2host` endpoint in
the guest (`specs/simulator/launchd-sim.md` §6.3); the local store did not
use it in our runs.

## 4. Configuration lifecycle

1. `SKTestSession` creation sends the configuration to the daemon for the
   caller's bundle id; the daemon logs that it creates a new test session
   for the app, stores a copy (`configuration-file.md` §8) and from then on
   initializes that app's StoreKit client with the "XcodeTest" server.
2. Before any configuration the daemon logs "App … doesn't have any StoreKit
   Testing in Xcode data" when the app registers.
3. The configuration and the session overrides persist; a relaunch without
   `SKTestSession` keeps the local store (§1). Uninstall removes the
   configuration copy and the transactions but **not** the app's override
   row: a "dialogs enabled" override set by an earlier session survived an
   uninstall and a reinstall and beat `_disableDialogs` true in the newly
   installed file (the purchase sheet appeared).
4. The first product request right after the first session creation can
   race the installation and return nothing (`testing-session.md` §2).
5. Reinstalling the app (as Xcode's Run does) makes the daemon clear the
   app's cached app transaction; the test-store transactions stay (two
   entitlements survived an Xcode Run that re-saved the configuration; an
   unfinished consumable bought before it was no longer listed afterwards —
   open question 6).

## 5. Where state lives (level 2: names and formats only)

All in the shared app-group container `group.com.apple.storekit`
(`<device>/data/Containers/Shared/AppGroup/<uuid>/`), created by
LaunchServices:

| Path | Format | Content |
|---|---|---|
| `Documents/Persistence/Octane/<bundle id>/Configuration.storekit` | JSON | the app's installed configuration |
| `Documents/Persistence/Octane/cheddar-cert` | 628 bytes: a 10-byte binary prefix, then the base64 text of the DER X.509 certificate (463 bytes decoded) | the device's JWS signing certificate (`formats.md` §2.1), created at the first session on the device |
| `Documents/Persistence/Octane/cheddar-key` | 32 bytes | the matching P-256 private key (raw scalar size; not read) |
| `Library/Caches/storeUser.db` (+ WAL) | SQLite 3 | the daemon's store: storefront per client type, test-store overrides per app (storefront, locale, time rate, Ask to Buy, billing issues, grace, dialogs, simulated errors), the test-store transaction table (one row per transaction with product, type, state, finished flag, dates, offer, renewal chain, Ask-to-Buy status, revocation, purchase issue, billing-retry and grace end dates, upgrade flag), and caches of signed transactions, subscription statuses and app transactions (header, payload and signature stored as text) |

Per app: `<app data container>/StoreKit/receipt` (StoreKit 1 receipt,
`formats.md` §3). The daemon also has ordinary caches under
`<device>/data/Library/Caches/com.apple.storekitd`.

Ycode does not need to read or write these files: a Ycode guest running
Apple's runtime gets them from Apple's daemon, and an open StoreKit keeps
its own store (`design.md`). The guest must provide a writable, persistent
app-group container for `group.com.apple.storekit` and the app's data
container.

## 6. System UI (observed)

All system UI is drawn by `StoreKitUISceneService`; every screen marks the
local store, either with the title "Xcode" (purchase sheet) or with the line
"[Environment: Xcode]" (alerts and the other sheets).

| Trigger | UI |
|---|---|
| `purchase()` with dialogs enabled | a bottom sheet over the app: a close button, the title "Xcode", the product's display name, the app's name and the kind ("In-App Purchase" for a consumable, "Subscription" for an auto-renewable), a card with the price and terms ("$0.99" / "One-time charge"; "$1.99 per month" / "Starting today" for a subscription the customer is not intro-eligible for) and the note "For testing purposes only. You will not be charged for confirming this purchase.", and one button: "Purchase" (in-app) or "Subscribe" (subscription). The purchase result returns when the user confirms (47 s in a manual run) |
| simulated purchase error (`productUnavailable`, `purchaseNotAllowed`, `ineligibleForOffer`, `invalidQuantity`) | an alert titled "Can't Complete This Purchase" with a reason (for `invalidQuantity`: "You can't buy more than 10 of this item at one time.") and an OK button; shown even with dialogs disabled |
| promotional offer with an invalid signature | alert "Unable to Purchase" / "Contact the developer for more information." with OK |
| `Transaction.beginRefundRequest(in:)` | a sheet: placeholder app icon, product name, app name, price paid, "Purchased on <date>", a close button, an "Issue" section with two choices ("Developer Issue", "Other"), the note "You may lose access to refunded items." and a "Request Refund" button (disabled until a choice is made). Completing it refunds the transaction (the app receives the revoked transaction through `Transaction.updates`) and the call returns success |
| `AppStore.presentOfferCodeRedeemSheet(in:)` | a sheet: placeholder icon, "Redeem Code for <app name>", one section per subscription with configured codes listing each code's reference name ("Plus Monthly" → "CODEFREE"), a close button and a "Redeem Code" button (disabled until a code is chosen) |
| `AppStore.showManageSubscriptions(in:)` | a sheet that the user closes; returns normally |

Terminating the app dismisses an open purchase sheet. The redeem sheet,
however, survived its app's termination and even its uninstall until the
device rebooted (it was still on screen the next day and blocked a later
test run).

## 7. StoreKit 1

`SKPaymentQueue.canMakePayments()` true; `SKPaymentQueue.default().storefront`
nil at first; `SKProductsRequest` returns the configured products (price,
`priceLocale` `en_US@currency=USD`, subscription period as units 0 day,
1 week, 2 month, 3 year; introductory price payment modes 0 pay-as-you-go,
1 pay-up-front, 2 free trial; promotional discounts with their ids) and the
unknown id in `invalidProductIdentifiers`. A payment goes `purchasing` (0)
→ `purchased` (1) within about 50 ms with a numeric `transactionIdentifier`
from the same counter as StoreKit 2; `restoreCompletedTransactions` delivers
**new** transactions in state `restored` (3) for each non-consumable and
active subscription, which StoreKit 2 then reports with reason RENEWAL;
`applicationUsername` is accepted. The receipt file appears after StoreKit 1
activity and `SKReceiptRefreshRequest` finishes successfully.

## 8. Conformance checklist

Probe: `StoreProbe -phase <p>` (variant in brackets), app `dev.ycode.skprobe`
with `YcodeProbe.storekit`, dialogs disabled unless noted. A Ycode simulator
running Apple's runtime and an open StoreKit must both produce these. Ids
are relative to the first id of the run (n); dates are relative.

| # | Probe | Expected |
|---|---|---|
| E1 | `env` [no session, fresh install] | canMakePayments 1; 0 products; AppTransaction `systemError(noAccount)`; all lists empty |
| E2 | `env` [B, other bundle, after A installed a configuration] | 0 products (isolation) |
| P1 | `products` | 7 products with the names, prices, display prices, types, family flags, group ids, levels, periods and offers of `plan.md` §3.1; bogus id → 0; empty → 0; intro eligibility true for both groups and an unknown group |
| P2 | `products` | product JSON of `formats.md` §1 for each product |
| U1 | `buy` | coins n (finished); coins n+1 unfinished; pro n+2; pro again → n+2; season n+3; coins with quantity 3 → returns n+1 again (unfinished); coins with token → n+4 with `appAccountToken`; all/entitlements/unfinished = {n+4, n+3, n+2} / {n+3, n+2} / {n+4} |
| U2 | `buy` | every JWS: ES256, kid `Apple_Xcode_Key`, 1 certificate, verifies; payload keys of `formats.md` §2.2 |
| U3 | `buy` | AppTransaction payload of `formats.md` §2.4; no receipt file |
| U4 | `relaunch` [no session] | 7 products; entitlements {season, pro}; nothing unfinished |
| S1 | `sub` [rate 1004] | monthly with free trial, period 10 s, price 0, offer type 1 FREE_TRIAL; eligibility false after; renewals every 10 s with reason RENEWAL, price 3990, same original id, contiguous dates |
| S2 | `sub` | crossgrade to yearly and downgrade to lite return the current transaction and change `autoRenewProductId`; other group starts its own original |
| S3 | `sub` | auto-renew off → state 2, intent 1 after expiry; enable → immediate renewal from the old expiry |
| S4 | `sub` | force renewal of weekly → new transaction now; expire weekly → expiration = call time |
| S5 | `sub` [rate 1004, billing retry] | after the failed renewal: state 2, intent 2, auto-renew 0 |
| S6 | `sub` [rate 1003, billing retry + grace] | state 4, `isInBillingRetryPeriod` true, `gracePeriodExpiresDate` = failed renewal + 30 s; after resolve: state 1 with a renewal at the grace end |
| R1 | `refund` | revocation date and reason 0 on pro, coins, monthly; entitlements empty; monthly status 5; refund of unknown id → `SKServiceErrorDomain` 2 / `SKInternalErrorDomain` 17 |
| A1 | `ask` | both purchases `.pending`; test transactions state 4; approve → delivered purchase; decline → state 2 |
| F1 | `fail` | load-products error → `systemError`; purchase failures → alert (4 cases) then `StoreKitError.unknown`; invalid signature → unverified; status error → empty; AppTransaction and sync errors → `systemError`; interrupted purchase → error + issue, resolved by the test API |
| O1 | `offers` | intro instead of unsigned promo; signed promo with a fake signature → "Unable to Purchase" + error; code offer on active subscription → renewal info offer type 3, renewal price 0; backdated lite → 2 transactions |
| K1 | `sk1` | SK1 product list and transaction states of §7; receipt of `formats.md` §3 |
| G1 | `ui` [buy, dialogs on] | purchase sheet of §6 ("Purchase" for coins, "Subscribe" for lite); confirm → success |
| G2 | `ui` [refund] | refund sheet of §6; request → revoked update and status success |
| G3 | `ui` [redeem] | redeem sheet listing CODEFREE under Plus Monthly |
| G4 | `ui` [manage] | manage sheet; close → returns |

## 9. Open questions

1. The purchase sheet's wording for intro-eligible customers, non-renewing
   subscriptions, quantities above 1 and Ask to Buy.
2. Whether the daemon keeps one test store per app or per app + device user.
3. The manage-subscriptions sheet's content.
4. `requestReview(in:)` in the simulator.
5. The same baseline on the iOS 27.0 runtime.
6. Whether an Xcode Run (re-save plus reinstall) drops unfinished
   consumables.

## Evidence

- §1–§2, §6, §7: level 3 (StoreProbe phases on `ycode-test-storekit-1`,
  screenshots of the sheets and alerts, 2026-10-19/20).
- §3: level 2 (launchd property lists of `storekitd` and
  `StoreKitUISceneService`, runtime bundle layout) and level 3 (Mach service
  names and request names from the device log; no binaries were
  disassembled).
- §4–§5: level 2 (files on the simulated device: names, sizes, SQLite schema
  names as a format) and level 3 (lifecycle observed through the probe and
  `simctl uninstall`).
- §8: level 3.
