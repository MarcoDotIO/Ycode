# StoreKit spec: StoreKit Testing (`SKTestSession`) and the local store's rules

Part of `specs/frameworks/storekit/`. StoreKit Testing is Apple's local test
store: an app (or its tests) loads a `.storekit` configuration, buys made-up
products, and drives renewals, refunds, Ask to Buy and failures, all without
an Apple account or network. In the simulator the store runs inside the
StoreKit daemon (`simulator-baseline.md` §3). This file describes the
control API (`StoreKitTest.framework`) and the rules the local store applies,
with the values our probe measured. Ycode's simulator gets all of this for
free while it runs Apple's runtime; an open StoreKit must reproduce it.

Names are interop facts from the public SDK (level 4); descriptions are ours.
Behavior is level 3 (StoreProbe on `ycode-test-storekit-1`, iOS 27.1) unless
marked.

## 1. The framework

- `StoreKitTest.framework`, installed in the runtime at
  `/Developer/Library/Frameworks/StoreKitTest.framework` (not under
  `/System`); the SDK has it under `Developer/Library/Frameworks` too, so an
  app or test links it with that framework search path. It is normally
  linked by test bundles; an app that links it directly runs fine in the
  simulator.
- At run time it asks XCTest which app is under test, so a plain launch
  needs the platform's XCTest framework findable (StoreProbe's runner sets
  `DYLD_FRAMEWORK_PATH` to the platform `Developer/Library/Frameworks`).
- Public classes: `SKTestSession`, `SKTestTransaction`, the ad-attribution
  helpers `SKAdTestSession`/`SKAdTestPostback` (out of scope), error domain
  `SKTestErrorDomain`. Swift adds `SKTestFailures` (simulated errors) and
  async variants.

## 2. `SKTestSession`

Creation: `init(configurationFileNamed:)` (file name without extension,
searched in the main bundle) or `init(contentsOf:)`; both throw if the file is
missing or invalid (`SKTestErrorCode.fileNotFound` 4, `invalidURL` 3).
Creating a session installs the configuration for the **calling app's**
bundle identifier in the daemon and returns before the daemon has applied it:
in the first launch of an app that never had a configuration, a product
request made 40–540 ms after creation returned an empty list and
`AppTransaction.shared` failed with `noAccount` (seen for both probe
bundles); every later launch got all products within 10–200 ms. Switching an
existing app to another configuration file took effect at once (open
question 1: whether the framework offers a completion).

Properties (all persisted per app by the daemon until
`resetToDefaultState()`; a later launch sees the previous value, observed for
`timeRate`):

| Property | Type | Default | Effect |
|---|---|---|---|
| `storefront` | string (alpha-3) | from the file (`USA`) | storefront of products and transactions |
| `locale` | locale | from the file (`en_US`) | product texts and price formatting |
| `timeRate` | `TimeRate` | from the file (0) | subscription clock (§3) |
| `askToBuyEnabled` | bool | file | purchases return `.pending` (§6) |
| `disableDialogs` | bool | file | skip the purchase confirmation sheet; error alerts still appear (§9) |
| `interruptedPurchasesEnabled` | bool | file | purchases fail with a purchase issue (§8) |
| `shouldEnterBillingRetryOnRenewal` (ObjC `billingRetryOnRenewalEnabled`) | bool | file | renewals fail and the subscription enters billing retry (§3.2) |
| `billingGracePeriodIsEnabled` | bool | file | billing retry starts with grace (no effect unless the previous is on) |
| `failTransactionsEnabled`, `failureError` | bool, error code | — | deprecated (iOS 14–17); replaced by simulated errors |

Methods and observed results:

| Method | Observed |
|---|---|
| `allTransactions()` | every transaction of the app in the local store, including finished consumables and failed or pending ones, in id order (§10) |
| `clearTransactions()` | removes all transactions; the id counter is **not** reset (next id continues) |
| `resetToDefaultState()` | drops all property overrides back to the file's settings |
| `buyProduct(identifier:options:)` (async) | an "off-device" purchase (as if made on another device). It failed with `StoreKitError.unknown` and a log line "Off-device purchase of … failed: Unable to Complete Request" in a plain app launch, but succeeded later in the same kind of launch (offers phase); open question 2. It accepts purchase options, including `.purchaseDate(_:)` to backdate and `codeOffer(referenceName:)` |
| `deleteTransaction(identifier:)` | removes one transaction; it disappears from every list |
| `refundTransaction(identifier:)` | sets the revocation date (now) and reason 0 on the transaction; a refunded subscription's status becomes revoked; `Transaction.updates` delivers the refunded transaction |
| `expireSubscription(productIdentifier:)` | the current period ends now (expiration date set to the call time); in both runs it also left one extra transaction of that subscription in state 2 (failed) with `hasPurchaseIssue` true and a purchase date equal to the expired renewal's, listed by `Transaction.all`; errors for a non-subscription or unknown product, and for a subscription that is not active (§11) |
| `forceRenewalOfSubscription(productIdentifier:)` | an immediate renewal: a new transaction starting now with a full period |
| `disableAutoRenewForTransaction(identifier:)` / `enable…` | renewal info `autoRenewStatus` 0/1; disabling adds `expirationIntent` 1; enabling an expired subscription renews it at once with a new transaction whose purchase date is the old expiration (no gap) |
| `requestPriceIncreaseConsentForTransaction`, `consentToPriceIncrease…`, `declinePriceIncrease…` | failed with the generic invalid-state error in our runs (the configuration has no price increase; open question 3) |
| `approveAskToBuyTransaction(identifier:)` / `decline…` | §6 |
| `resolveIssueForTransaction(identifier:)` | clears a purchase issue (§8) |
| `setSimulatedError(_:forAPI:)` / `simulatedError(forAPI:)` (async) | §9 |

### 2.1 Time rates (`SKTestSession.TimeRate`, raw values)

| Raw | Name | Meaning |
|---|---|---|
| 0 | `realTime` | durations as configured |
| 1–6 | `oneHourIsOneDay`, `thirtyMinutesIsOneDay`, `fiveMinutesIsOneDay`, `oneMinuteIsOneDay`, `thirtySecondsIsOneDay`, `oneSecondIsOneDay` | deprecated (iOS 14.0–15.2) |
| 10–13 | `monthlyRenewalEveryHour`, `…EveryThirtyMinutes`, `…EveryFifteenMinutes`, `…EveryFiveMinutes` | a one-month period lasts the named time; other periods scale proportionally |
| 15 | `monthlyRenewalEveryThirtySeconds` | (14 is unused) |
| 1000–1005 | `oneRenewalEveryFifteenMinutes`, `…EveryFiveMinutes`, `…EveryMinute`, `…EveryThirtySeconds`, `…EveryTenSeconds`, `…EveryTwoSeconds` | **every** period (week, month, year, and offer periods) lasts the named time (iOS 16.4+) |

Observed with 1004: a one-month subscription whose first period is a
one-week free trial, a one-week subscription and a pay-up-front one-month
intro all got periods of exactly 10 s (`expiresDate − purchaseDate` =
10000 ms).

## 3. The subscription clock

1. A purchase at time T with period P has `purchaseDate` T and
   `expiresDate` T + P (scaled by the time rate). With real time, periods are
   calendar periods in the device time zone: one month from 2026-10-05 or
   2026-10-19 gave 31 days **plus one hour** across the end of daylight
   saving time (2682000 s), one month from 2026-09-05 gave 30 days
   (2592000 s), one week 604800 s.
2. A renewal happens at the expiration of the current period: a new
   transaction with `transactionReason` RENEWAL, the same
   `originalTransactionId`, `purchaseDate` = previous `expiresDate` (exactly,
   to the millisecond) and a new period. Renewals were delivered to a
   running app through `Transaction.updates` 1–3 s after the expiration
   (13.3, 24.4, 36.4 and 43.5 s after a purchase at 0.2 s with 10 s periods;
   the delivery jitter grows under host load).
3. Renewal price: the base price after an introductory or promotional
   period (`price` 3990 after a 0 trial).
4. A backdated purchase (test-only option `purchaseDate(_:renewalBehavior:)`,
   behavior `renewUntilNow` by default, the other choice `cancelImmediately`;
   observed with `purchaseDate` 45 days ago and a one-month period) catches up immediately: the first transaction keeps its old dates and one
   renewal transaction covers "now" (only as many renewals as needed to
   reach the present were created: one).

### 3.1 Upgrades, downgrades, crossgrades (one group)

| Action (current: monthly, level 1) | Result |
|---|---|
| Buy yearly (same level 1, different duration) | the purchase returns the **current** transaction unchanged; renewal info `autoRenewProductId` becomes the yearly product — takes effect at the next renewal |
| Buy lite (level 2, a downgrade) | same: current transaction returned, `autoRenewProductId` = lite |
| Buy a product of another group | an independent subscription with its own original transaction |
| (level 4 / level 1) Upgrade to a higher level | immediate: the old transaction gets `isUpgraded` and a new one starts. Observed indirectly: a backdated level-2 subscription bought with the test API while a level-1 subscription of the same group was active had its catch-up renewal reported with `isUpgraded` true |

### 3.2 Status (`Product.SubscriptionInfo.status(for:)`)

One status entry per subscription (original transaction) in the group. The
`state` raw values: 1 subscribed, 2 expired, 3 in billing retry, 4 in grace
period, 5 revoked. Observed sequence for the monthly product:

| Situation | `state` | Renewal info |
|---|---|---|
| after purchase | 1 | `autoRenewStatus` 1, `renewalDate` = expiration, `renewalPrice` 3990, `renewalBillingPlanType` BILLED_UPFRONT |
| auto-renew disabled, then expired | 2 | `autoRenewStatus` 0, `expirationIntent` 1 |
| billing retry on, renewal failed, retry period over | 2 | `autoRenewStatus` 0, `expirationIntent` 2, `isInBillingRetryPeriod` false |
| billing retry **with** grace period on, renewal failed (rate 1003, 30 s periods) | 4 | `autoRenewStatus` 1, `isInBillingRetryPeriod` true, `gracePeriodExpiresDate` = failed renewal date + one period; the status transaction is a renewal transaction whose `expiresDate` is the grace end (the customer keeps access) |
| then `resolveIssueForTransaction` (retry off) | 1 | at the grace end a normal renewal transaction (purchase date = grace end, full period) is delivered; `isInBillingRetryPeriod` false, `gracePeriodExpiresDate` gone |
| refunded | 5 | `autoRenewStatus` 0, an `expirationIntent` |
| a code offer redeemed for the next period | 1 | `offerType` 3, `offerIdentifier` = code reference name, `offerDiscountType` FREE_TRIAL, `offerPeriod`, `renewalPrice` 0 |

State 3 (billing retry without grace) was not caught: with 10 s periods the
retry window had ended before the status read 40 s later (open question 4).

## 4. Purchases of each product type

| Type | First purchase | Buying again |
|---|---|---|
| Consumable | new transaction; appears in `Transaction.all`/`unfinished` until finished | if an **unfinished** transaction for the product exists, the purchase returns that same transaction again (same id, new `signedDate`), even with a different quantity option; otherwise a new transaction |
| Non-consumable | new transaction; a current entitlement | returns the existing transaction (same id), no new one |
| Non-renewing subscription | new transaction without expiration; a current entitlement (as long as not revoked) | not exercised |
| Auto-renewable | new transaction with expiration; the first purchase uses the introductory offer if the customer is eligible | §3.1 |

Purchase options observed: `quantity(n)` (stored as `quantity`; up to 10 per
purchase, more fails with "You can't buy more than 10 of this item at one
time." in the error alert, §9), `appAccountToken(uuid)` (appears as
`appAccountToken`, lower-cased), `custom(key:value:)` (accepted, not
reflected in the transaction), `promotionalOffer(offerID:keyID:nonce:signature:timestamp:)`
(§5), and three options that StoreKitTest adds for local testing:
`promotionalOffer(id:)` (an unsigned promotional offer), `codeOffer(referenceName:)`
(§5) and `purchaseDate(_:renewalBehavior:)` (§3).

## 5. Offers

1. Introductory offer: applied automatically to the first purchase in a
   group by a customer who never had a subscription in that group
   (`isEligibleForIntroOffer(for:)` true before, false right after the
   purchase, and still false after the subscription expired). An unknown
   group id also answers true.
2. Promotional offer with a made-up signature: the purchase fails after an
   "Unable to Purchase / Contact the developer for more information." alert
   with `StoreKitError.unknown`. Promotional offers need a signature made with
   the configuration's subscription-offer key (`configuration-file.md` §6),
   open question 5.
3. A purchase with the unsigned test option `promotionalOffer(id:)` while the
   customer was still eligible for the introductory offer got the
   introductory offer (transaction `offerType` 1, FREE_TRIAL) instead of the
   promotional one.
4. Code offer at purchase time (`codeOffer(referenceName:)`): for a product
   whose group has no such code the purchase succeeded with the product's
   own introductory offer; for an active subscription the code was attached
   to the **next** renewal (renewal info `offerType` 3).
5. Offer codes appear in the system redeem sheet (`simulator-baseline.md` §6).

## 6. Ask to Buy

With `askToBuyEnabled`, `purchase()` returns `.pending` at once. The local
store keeps an `SKTestTransaction` with state 4 (deferred) and
`pendingAskToBuyConfirmation` true; nothing appears in `Transaction.all`.
`approveAskToBuyTransaction` turns it into a normal purchase (state 1)
delivered through `Transaction.updates`; `decline…` marks it failed (state 2),
but the declined consumable was **still delivered** through
`Transaction.updates` and listed in `Transaction.all` and `unfinished` in our
run (open question 6: reproduce; may be a reference bug).

## 7. Refunds and revocation

`refundTransaction` (and the refund sheet, `simulator-baseline.md` §6):
`revocationDate` set, `revocationReason` 0 (other), and in the signed
payload `revocationType` REFUND_FULL with `revocationPercentage` 100000; a refunded non-consumable
leaves `currentEntitlements`; a refunded consumable that was already finished
is gone from `Transaction.all` (as finished consumables always are); the
refunded subscription's status is 5 (revoked). An unknown id fails with the
invalid-state error (§11).

## 8. Interrupted purchases (purchase issues)

With `interruptedPurchasesEnabled` the purchase call fails with
`StoreKitError.unknown`, but the local store records a transaction with
state 2 and `hasPurchaseIssue` true **and** the app already sees it as a
verified transaction in `Transaction.all`, `currentEntitlements` and
`Transaction.updates`. `resolveIssueForTransaction` sets state 1 and clears
the issue; no new transaction is created.

## 9. Simulated errors (`setSimulatedError(_:forAPI:)`)

APIs (each with its own `SKTestFailures` case set): `loadProducts`
(generic `StoreKitError`), `purchase` (generic or `Product.PurchaseError`),
`verification` (`VerificationResult.VerificationError`), `appStoreSync`,
`subscriptionStatus`, `appTransaction`, `manageSubscriptions`,
`offerCodeRedeem` (generic), `refundRequest` (generic or
`Transaction.RefundRequestError`). Passing nil clears the API's error.
Observed:

| API | Simulated error | What the app gets |
|---|---|---|
| `loadProducts` | `.generic(.networkError(notConnectedToInternet))` | `Product.products` throws `StoreKitError.systemError(…unknown)` (code 1). Clearing it restores products |
| `purchase` | `.purchase(.productUnavailable)`, `.purchaseNotAllowed`, `.ineligibleForOffer`, `.invalidQuantity` | a system **alert** first ("Can't Complete This Purchase" with a reason and "[Environment: Xcode]"; OK button), then `purchase()` throws `StoreKitError.unknown` (code 2), regardless of the simulated case. The alert also appears with `disableDialogs` on |
| `purchase` | `.generic(.unknown)`, `.systemError`, `.notEntitled`, `.userCancelled` | `StoreKitError.unknown` at once (no alert) |
| `verification` | `.verification(.invalidSignature)` | the purchase succeeds but the result is `.unverified(…, invalidSignature)`, and its JWS signature really does not verify (checked with an independent verifier) |
| `verification` | `.revokedCertificate`, `.invalidDeviceVerification` | the result was still `.verified` in our run (open question 7) |
| `subscriptionStatus` | `.generic(.networkError(timedOut))` | `status(for:)` returned an empty array, no error |
| `appTransaction` | `.generic(.unknown)` | `AppTransaction.shared` throws `systemError(unknown)` |
| `appStoreSync` | `.generic(.networkError(…))` | `AppStore.sync()` throws `systemError(unknown)`; clearing it, `sync()` succeeds |

## 10. Transaction identifiers and fields in the local store

1. Transaction ids are decimal strings of a per-app counter (per device)
   starting at 0 for a freshly installed app and never reused (not reset by
   `clearTransactions`; a second app on the same device started again at 0
   while the first was at 33). `webOrderLineItemId` equals the transaction id.
2. `originalTransactionId` equals the transaction id for every purchase and
   the original's id for renewals. (`SKTestTransaction.originalTransactionIdentifier`
   reports 0 for most originals — do not rely on it.)
3. `appTransactionId` is "0"; `environment` is "Xcode"; `storeType`
   "CONSUMER"; `inAppOwnershipType` "PURCHASED"; storefront "USA" with id
   "143441"; `currency` "USD"; `price` in milli-units (0.99 → 990).
4. `Transaction.all` lists newest first; finished consumables are omitted.
   `currentEntitlements` lists one entry per non-consumable and active
   subscription (the latest transaction of the subscription).
   `Transaction.unfinished` lists every unfinished transaction including
   each unfinished renewal. `Transaction.latest(for:)` is the newest
   transaction of the product.
5. At app launch the framework replays unfinished transactions through
   `Transaction.updates` (observed at the start of each launch for the
   transactions left unfinished by the previous run).

## 11. Errors of the control API

Most failures of `SKTestSession` methods arrive as `NSError` domain
`SKServiceErrorDomain` code 2 with an underlying `SKInternalErrorDomain`
code 17 and user-info `client-environment-type` = "Xcode" (unknown id,
non-subscription product, expired subscription, price-increase calls). The
public `SKTestErrorCode` values (`errors.md` §3) were not returned by any
call we made.

## 12. Open questions

1. A way to wait until a new session's configuration is active (the first
   launch race).
2. When `buyProduct` (off-device purchase) fails versus succeeds.
3. Price-increase testing requires what in the configuration?
4. Billing retry state 3 and the length of the retry window: poll the status
   every few seconds at rate 1003 without grace.
5. The promotional-offer signing key format in the configuration and a valid
   locally signed offer.
6. Ask-to-Buy decline delivering the transaction.
7. Effects of the `revokedCertificate` and `invalidDeviceVerification`
   simulated errors.

## Evidence

- §1–§2 names, types, raw values, availability: level 4 (public SDK headers
  and Swift interface, as metadata). Framework install location: level 2.
- All behavior and numbers: level 3 (StoreProbe phases `products`, `buy`,
  `sub`, `refund`, `ask`, `fail`, `offers`, `sk1`, `relaunch` on
  `ycode-test-storekit-1`, iOS 27.1 runtime 24A94401, 2026-10-19/20).
- §3.1 immediate upgrades: level 1 (public documentation of subscription
  levels), not directly observed.
- JWS signature check in §9: level 3 with our own verifier
  (`research/experiments/storekit/jws_check.py`).
